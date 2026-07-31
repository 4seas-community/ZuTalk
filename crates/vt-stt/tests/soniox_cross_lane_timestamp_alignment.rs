//! Opt-in real-provider measurement: do two sibling connections fed byte-identical
//! audio report the same timestamp for the same word, and does that survive minutes?
//!
//! Multilingual capture fans one PCM stream out to one canonical connection plus one
//! translating connection per selected language. The binding layer currently assumes
//! their token timestamps drift apart over a long run, and pays for that assumption by
//! failing the whole stream group closed when any single lane reconnects. That
//! assumption has never been measured at token level: the only timestamps the store
//! keeps are per-segment aggregates, and two connections segment differently, so a
//! segment-level comparison reports segmentation divergence as if it were drift.
//!
//! This test measures the token level directly. Both lanes receive the identical
//! chunks in the identical order from one loop, exactly as `try_fanout_pcm` does.
//!
//! Output is counts and millisecond deltas only. Token text is reduced to a
//! non-printed hash used solely to verify the two lanes transcribed the same words.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use tokio_util::sync::CancellationToken;
use vt_stt::{
    SonioxStreamClient, SttConfig, SttStreamControl, SttStreamEvent, SttStreamToken,
    SttStreamTranslationStatus, TranslationConfig, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

const PCM_CHUNK_BYTES: usize = 3_200;
const PCM_BYTES_PER_MILLISECOND: usize = 32;

/// Wider than any plausible provider disagreement, narrower than one repetition
/// of the fixture, so a greedy match can never skip a whole repeat and call two
/// different utterances of the same sentence a pair.
const MATCH_WINDOW_MS: u64 = 3_000;

fn load_api_key() -> Option<String> {
    if let Ok(value) = std::env::var("SONIOX_API_KEY") {
        if !value.trim().is_empty() {
            return Some(value);
        }
    }
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()?
        .parent()?
        .join(".env");
    let contents = std::fs::read_to_string(path).ok()?;
    contents.lines().find_map(|line| {
        line.strip_prefix("SONIOX_API_KEY=")
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    })
}

fn requested_minutes() -> f64 {
    std::env::var("ZULANGUE_ALIGNMENT_MINUTES")
        .ok()
        .and_then(|value| value.trim().parse::<f64>().ok())
        .filter(|value| *value > 0.0)
        .unwrap_or(5.0)
}

fn speech_fixture_pcm() -> Vec<u8> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace crate parent")
        .join("vt-audio/tests/fixtures/test_speech_16k_mono.wav");
    let mut reader = hound::WavReader::open(path).expect("read public synthetic speech fixture");
    let spec = reader.spec();
    assert_eq!(spec.sample_rate, 16_000);
    assert_eq!(spec.channels, 1);
    assert_eq!(spec.bits_per_sample, 16);
    reader
        .samples::<i16>()
        .flat_map(|sample| sample.expect("decode synthetic PCM sample").to_le_bytes())
        .collect()
}

/// Repeats the fixture with an irregular gap so repeats do not land on the same
/// phase. Equal gaps would make every repeat a byte-identical copy at a fixed
/// period, which is exactly the input most likely to hide a phase error.
fn paced_fixture_stream(minutes: f64) -> Vec<u8> {
    let fixture = speech_fixture_pcm();
    let target_bytes = (minutes * 60.0 * 1_000.0) as usize * PCM_BYTES_PER_MILLISECOND;
    let mut pcm = Vec::with_capacity(target_bytes + fixture.len());
    let mut repeat = 0usize;
    while pcm.len() < target_bytes {
        pcm.extend_from_slice(&fixture);
        let gap_ms = 200 + (repeat * 137) % 800;
        pcm.extend(std::iter::repeat_n(0u8, gap_ms * PCM_BYTES_PER_MILLISECOND));
        repeat += 1;
    }
    pcm
}

/// Comparison form for cross-lane word identity, then a non-cryptographic digest.
/// The digest is never printed; it only answers "did both lanes hear this word".
fn word_key(text: &str) -> u64 {
    let normalized: String = text
        .chars()
        .filter(|character| !character.is_whitespace() && !character.is_ascii_punctuation())
        .flat_map(char::to_lowercase)
        .collect();
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in normalized.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[derive(Debug, Clone, Copy)]
struct SourceToken {
    key: u64,
    start_ms: u64,
    end_ms: u64,
}

#[derive(Default)]
struct LaneObservation {
    tokens: Vec<SourceToken>,
    translation_tokens: usize,
    translation_tokens_with_timestamps: usize,
    reconnects: usize,
    connected: bool,
    finished: bool,
    /// How long after a word finished being spoken this lane reported it.
    /// `arrival - end_ms`, both on the capture-wide audio clock, so it is the
    /// number that decides how wide a canvas window has to be to hold every
    /// lane's account of the same moment.
    source_lag_ms: Vec<u64>,
    /// How long after the last finished source word this lane's translation of
    /// it arrived. This is the audience-visible wait for a translated column.
    translation_lag_ms: Vec<u64>,
    last_final_source_end_ms: u64,
    /// Translation tokens per provider response that carried any — the mouthful
    /// size. This is what decides whether a translated column reads as flowing
    /// words or as slabs: the UI can only be as fine-grained as one response.
    translation_batch_sizes: Vec<usize>,
    /// Wall-clock gaps between consecutive translation-carrying responses,
    /// the cadence of those mouthfuls.
    translation_batch_gap_ms: Vec<u64>,
    last_translation_batch_at_ms: u64,
}

impl LaneObservation {
    fn absorb(&mut self, token: &SttStreamToken, arrival_ms: u64) {
        match token.translation_status {
            SttStreamTranslationStatus::Translation => {
                self.translation_tokens += 1;
                if token.start_ms.is_some() || token.end_ms.is_some() {
                    self.translation_tokens_with_timestamps += 1;
                }
                if token.is_final && self.last_final_source_end_ms > 0 {
                    self.translation_lag_ms
                        .push(arrival_ms.saturating_sub(self.last_final_source_end_ms));
                }
            }
            SttStreamTranslationStatus::Original | SttStreamTranslationStatus::None => {
                if !token.is_final {
                    return;
                }
                let (Some(start_ms), Some(end_ms)) = (token.start_ms, token.end_ms) else {
                    return;
                };
                self.tokens.push(SourceToken {
                    key: word_key(&token.text),
                    start_ms,
                    end_ms,
                });
                self.source_lag_ms.push(arrival_ms.saturating_sub(end_ms));
                self.last_final_source_end_ms = self.last_final_source_end_ms.max(end_ms);
            }
            SttStreamTranslationStatus::Unknown(_) => {}
        }
    }
}

fn percentiles(samples: &[u64]) -> (u64, u64, u64) {
    if samples.is_empty() {
        return (0, 0, 0);
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let at = |fraction: f64| {
        sorted[((sorted.len() as f64 * fraction).ceil() as usize)
            .saturating_sub(1)
            .min(sorted.len() - 1)]
    };
    (at(0.5), at(0.95), sorted[sorted.len() - 1])
}

#[derive(Debug, Clone, Copy)]
struct Pairing {
    canonical_start_ms: u64,
    delta_start_ms: i64,
    delta_end_ms: i64,
}

/// Monotone greedy match on equal words within a bounded time window.
///
/// Monotone because both lanes received the same audio in the same order, so a
/// correct pairing can never run backwards; windowed so a repeated sentence
/// cannot pair with a different repetition of itself.
fn pair_lanes(canonical: &[SourceToken], auxiliary: &[SourceToken]) -> Vec<Pairing> {
    let mut pairings = Vec::new();
    let mut cursor = 0usize;
    for left in canonical {
        let mut candidate = None;
        for (offset, right) in auxiliary[cursor..].iter().enumerate() {
            if right.start_ms + MATCH_WINDOW_MS < left.start_ms {
                continue;
            }
            if right.start_ms > left.start_ms + MATCH_WINDOW_MS {
                break;
            }
            if right.key == left.key {
                candidate = Some((cursor + offset, *right));
                break;
            }
        }
        let Some((index, right)) = candidate else {
            continue;
        };
        cursor = index + 1;
        pairings.push(Pairing {
            canonical_start_ms: left.start_ms,
            delta_start_ms: right.start_ms as i64 - left.start_ms as i64,
            delta_end_ms: right.end_ms as i64 - left.end_ms as i64,
        });
    }
    pairings
}

struct MinuteStats {
    minute: u64,
    matched: usize,
    mean_abs_start: f64,
    p95_abs_start: u64,
    max_abs_start: u64,
    max_abs_end: u64,
}

fn per_minute(pairings: &[Pairing]) -> Vec<MinuteStats> {
    let mut buckets: HashMap<u64, Vec<Pairing>> = HashMap::new();
    for pairing in pairings {
        buckets
            .entry(pairing.canonical_start_ms / 60_000)
            .or_default()
            .push(*pairing);
    }
    let mut minutes: Vec<_> = buckets.into_iter().collect();
    minutes.sort_by_key(|(minute, _)| *minute);
    minutes
        .into_iter()
        .map(|(minute, mut items)| {
            items.sort_by_key(|pairing| pairing.delta_start_ms.unsigned_abs());
            let matched = items.len();
            let p95_index = ((matched as f64 * 0.95).ceil() as usize).saturating_sub(1);
            MinuteStats {
                minute,
                matched,
                mean_abs_start: items
                    .iter()
                    .map(|pairing| pairing.delta_start_ms.unsigned_abs() as f64)
                    .sum::<f64>()
                    / matched as f64,
                p95_abs_start: items[p95_index].delta_start_ms.unsigned_abs(),
                max_abs_start: items
                    .iter()
                    .map(|pairing| pairing.delta_start_ms.unsigned_abs())
                    .max()
                    .unwrap_or(0),
                max_abs_end: items
                    .iter()
                    .map(|pairing| pairing.delta_end_ms.unsigned_abs())
                    .max()
                    .unwrap_or(0),
            }
        })
        .collect()
}

/// The four handles one spawned lane hands back: its audio sink, its control
/// sink, the task collecting what the lane observed, and the stream task.
type SpawnedLane = (
    tokio::sync::mpsc::Sender<Vec<u8>>,
    tokio::sync::mpsc::Sender<SttStreamControl>,
    tokio::task::JoinHandle<LaneObservation>,
    tokio::task::JoinHandle<Result<(), vt_stt::SttError>>,
);

fn spawn_lane(
    api_key: String,
    config: SttConfig,
    cancel: CancellationToken,
    started: Instant,
) -> SpawnedLane {
    let runtime = SonioxStreamClient::start(
        CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_endpoint,
        api_key,
        config,
        cancel,
    );
    let vt_stt::SonioxStreamRuntime {
        audio_tx,
        control_tx,
        mut event_rx,
        task,
    } = runtime;
    let collector = tokio::spawn(async move {
        let mut observation = LaneObservation::default();
        while let Some(event) = event_rx.recv().await {
            match event {
                SttStreamEvent::Connected => observation.connected = true,
                SttStreamEvent::Reconnecting { .. } => observation.reconnects += 1,
                SttStreamEvent::Finished => observation.finished = true,
                SttStreamEvent::Tokens(tokens) => {
                    let arrival_ms = started.elapsed().as_millis() as u64;
                    let translation_tokens = tokens
                        .iter()
                        .filter(|token| {
                            token.translation_status == SttStreamTranslationStatus::Translation
                        })
                        .count();
                    if translation_tokens > 0 {
                        observation.translation_batch_sizes.push(translation_tokens);
                        if observation.last_translation_batch_at_ms > 0 {
                            observation.translation_batch_gap_ms.push(
                                arrival_ms.saturating_sub(observation.last_translation_batch_at_ms),
                            );
                        }
                        observation.last_translation_batch_at_ms = arrival_ms;
                    }
                    for token in &tokens {
                        observation.absorb(token, arrival_ms);
                    }
                }
                _ => {}
            }
        }
        observation
    });
    (audio_tx, control_tx, collector, task)
}

#[tokio::test]
#[ignore = "requires an explicitly supplied real Soniox API key and spends provider minutes"]
async fn sibling_connections_agree_on_token_timestamps_over_a_long_run() {
    let api_key = load_api_key()
        .expect("SONIOX_API_KEY must be supplied through the environment or an ignored local .env");
    let minutes = requested_minutes();
    let pcm = paced_fixture_stream(minutes);
    let audio_ms = pcm.len() / PCM_BYTES_PER_MILLISECOND;

    let cancel = CancellationToken::new();
    // The canonical lane: transcription only, language identification on.
    let canonical_config = SttConfig {
        language_hints: vec!["en".to_string(), "zh".to_string()],
        enable_language_identification: true,
        client_reference_id: Some("zulangue-alignment-canonical".to_string()),
        ..Default::default()
    };
    // An auxiliary lane: the same audio, plus a translation target. This is the
    // connection whose segment boundaries are known to disagree with canonical.
    let auxiliary_config = SttConfig {
        language_hints: vec!["en".to_string(), "zh".to_string()],
        enable_language_identification: true,
        translation: Some(TranslationConfig::OneWay {
            target_language: "th".to_string(),
        }),
        client_reference_id: Some("zulangue-alignment-auxiliary".to_string()),
        ..Default::default()
    };

    // One clock for both lanes: the moment capture starts, which is what the
    // provider-reported audio positions are relative to as well.
    let started = Instant::now();
    let (canonical_audio, canonical_control, canonical_collector, canonical_task) =
        spawn_lane(api_key.clone(), canonical_config, cancel.clone(), started);
    let (auxiliary_audio, auxiliary_control, auxiliary_collector, auxiliary_task) =
        spawn_lane(api_key, auxiliary_config, cancel.clone(), started);

    // One loop, one buffer, both lanes — the same fan-out the capture path uses.
    //
    // Paced against a fixed schedule rather than by sleeping between sends: a
    // per-iteration sleep accumulates the send cost, so the feed would fall
    // progressively behind real time and inflate every lag measurement by a
    // growing amount.
    let mut audio_closed = false;
    let feed_started = tokio::time::Instant::now();
    let mut elapsed_audio_ms = 0u64;
    for chunk in pcm.chunks(PCM_CHUNK_BYTES) {
        let canonical_sent = canonical_audio.send(chunk.to_vec()).await.is_ok();
        let auxiliary_sent = auxiliary_audio.send(chunk.to_vec()).await.is_ok();
        if !canonical_sent || !auxiliary_sent {
            audio_closed = true;
            break;
        }
        elapsed_audio_ms += (chunk.len() / PCM_BYTES_PER_MILLISECOND) as u64;
        tokio::time::sleep_until(feed_started + Duration::from_millis(elapsed_audio_ms)).await;
    }
    let feed_overrun_ms = feed_started
        .elapsed()
        .as_millis()
        .saturating_sub(u128::from(elapsed_audio_ms));
    drop(canonical_audio);
    drop(auxiliary_audio);
    let _ = canonical_control.send(SttStreamControl::Finish).await;
    let _ = auxiliary_control.send(SttStreamControl::Finish).await;
    drop(canonical_control);
    drop(auxiliary_control);

    let deadline = Duration::from_secs((minutes * 60.0) as u64 + 120);
    let canonical_result = tokio::time::timeout(deadline, canonical_task)
        .await
        .expect("canonical lane exceeded deadline")
        .expect("canonical stream task panicked");
    let auxiliary_result = tokio::time::timeout(deadline, auxiliary_task)
        .await
        .expect("auxiliary lane exceeded deadline")
        .expect("auxiliary stream task panicked");
    let canonical = canonical_collector.await.expect("canonical collector");
    let auxiliary = auxiliary_collector.await.expect("auxiliary collector");
    cancel.cancel();

    println!("--- cross-lane token timestamp alignment ---");
    println!(
        "audio_ms={audio_ms} audio_channel_closed_early={audio_closed} \
         canonical_ok={} auxiliary_ok={}",
        canonical_result.is_ok(),
        auxiliary_result.is_ok()
    );
    println!(
        "canonical: connected={} finished={} final_source_tokens={} reconnects={}",
        canonical.connected,
        canonical.finished,
        canonical.tokens.len(),
        canonical.reconnects
    );
    println!(
        "auxiliary: connected={} finished={} final_source_tokens={} reconnects={} \
         translation_tokens={} translation_tokens_carrying_timestamps={}",
        auxiliary.connected,
        auxiliary.finished,
        auxiliary.tokens.len(),
        auxiliary.reconnects,
        auxiliary.translation_tokens,
        auxiliary.translation_tokens_with_timestamps
    );

    // Any residual feed overrun is a common offset on every lag figure below.
    println!("feed_overrun_ms={feed_overrun_ms} (added to every lag measurement)");
    for (name, lane) in [("canonical", &canonical), ("auxiliary", &auxiliary)] {
        let (source_p50, source_p95, source_max) = percentiles(&lane.source_lag_ms);
        println!(
            "{name} source lag after the word ended: p50={source_p50}ms p95={source_p95}ms max={source_max}ms"
        );
    }
    let (translation_p50, translation_p95, translation_max) =
        percentiles(&auxiliary.translation_lag_ms);
    println!(
        "auxiliary translation lag after the source word ended: \
         p50={translation_p50}ms p95={translation_p95}ms max={translation_max}ms \
         samples={}",
        auxiliary.translation_lag_ms.len()
    );
    let batch_sizes: Vec<u64> = auxiliary
        .translation_batch_sizes
        .iter()
        .map(|size| *size as u64)
        .collect();
    let (batch_p50, batch_p95, batch_max) = percentiles(&batch_sizes);
    let (gap_p50, gap_p95, gap_max) = percentiles(&auxiliary.translation_batch_gap_ms);
    println!(
        "translation mouthfuls: batches={} tokens_per_batch p50={batch_p50} p95={batch_p95} \
         max={batch_max}; gap_between_batches_ms p50={gap_p50} p95={gap_p95} max={gap_max}",
        batch_sizes.len()
    );

    let pairings = pair_lanes(&canonical.tokens, &auxiliary.tokens);
    assert!(
        !pairings.is_empty(),
        "no word-identical token pairs; lanes returned {} and {} final source tokens",
        canonical.tokens.len(),
        auxiliary.tokens.len()
    );
    println!(
        "paired {} of {} canonical tokens ({:.1}%)",
        pairings.len(),
        canonical.tokens.len(),
        100.0 * pairings.len() as f64 / canonical.tokens.len().max(1) as f64
    );
    println!("minute  matched  mean|dStart|  p95|dStart|  max|dStart|  max|dEnd|");
    for stats in per_minute(&pairings) {
        println!(
            "{:>6}  {:>7}  {:>12.1}  {:>12}  {:>12}  {:>10}",
            stats.minute,
            stats.matched,
            stats.mean_abs_start,
            stats.p95_abs_start,
            stats.max_abs_start,
            stats.max_abs_end
        );
    }

    let overall_max = pairings
        .iter()
        .map(|pairing| pairing.delta_start_ms.unsigned_abs())
        .max()
        .unwrap_or(0);
    let first_minute = per_minute(&pairings)
        .first()
        .map(|stats| stats.mean_abs_start);
    let last_minute = per_minute(&pairings)
        .last()
        .map(|stats| stats.mean_abs_start);
    println!(
        "verdict: max|dStart|={overall_max}ms first_minute_mean={first_minute:?} \
         last_minute_mean={last_minute:?}"
    );
    println!(
        "A growing mean across minutes is drift. A flat mean means the sibling lanes \
         share one audio clock and the segment-level divergence is segmentation, not drift."
    );
}

#[test]
fn pairing_is_monotone_and_cannot_cross_a_repetition_boundary() {
    // The same word spoken three times; the auxiliary lane reports it 40 ms late
    // each time. A correct pairing takes each occurrence in order.
    let key = word_key("repeat");
    let canonical: Vec<_> = [1_000u64, 9_000, 17_000]
        .into_iter()
        .map(|start_ms| SourceToken {
            key,
            start_ms,
            end_ms: start_ms + 300,
        })
        .collect();
    let auxiliary: Vec<_> = [1_040u64, 9_040, 17_040]
        .into_iter()
        .map(|start_ms| SourceToken {
            key,
            start_ms,
            end_ms: start_ms + 300,
        })
        .collect();

    let pairings = pair_lanes(&canonical, &auxiliary);
    assert_eq!(pairings.len(), 3);
    for pairing in &pairings {
        assert_eq!(pairing.delta_start_ms, 40);
    }

    // An auxiliary lane that dropped the middle occurrence must not borrow the
    // third one to fill the gap: it is outside the window.
    let gapped = vec![auxiliary[0], auxiliary[2]];
    let pairings = pair_lanes(&canonical, &gapped);
    assert_eq!(pairings.len(), 2);
    assert_eq!(pairings[0].delta_start_ms, 40);
    assert_eq!(pairings[1].delta_start_ms, 40);
}

#[test]
fn word_key_ignores_exactly_the_punctuation_two_connections_disagree_about() {
    assert_eq!(word_key("Hello,"), word_key("hello"));
    assert_eq!(word_key(" world. "), word_key("World"));
    assert_ne!(word_key("hello"), word_key("hallo"));
}
