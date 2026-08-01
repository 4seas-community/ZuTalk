//! Opt-in real-provider latency measurement using an existing encrypted
//! Zulangue capture.
//!
//! The test selects the newest completed capture with the richest observed
//! language set, decrypts at most `ZULANGUE_MEASURE_SECONDS` into memory, and
//! fans byte-identical PCM to one canonical plus en/zh/th auxiliary streams.
//! It never prints token text, identifiers, paths, credentials, or plaintext
//! audio and never writes decrypted audio to disk.

use std::collections::HashMap;
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use tokio_util::sync::CancellationToken;
use vt_audio::canonicalize_for_soniox;
use vt_crypto::{DecryptReader, FileKeyStore, KeyProvider};
use vt_stt::{
    SonioxStreamClient, SttConfig, SttStreamControl, SttStreamEvent, SttStreamToken,
    SttStreamTranslationStatus, TranslationConfig, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

const PCM_CHUNK_BYTES: usize = 3_200;
const PCM_BYTES_PER_MILLISECOND: usize = 32;
const MATCH_WINDOW_MS: u64 = 3_000;
const TARGET_LANGUAGES: [&str; 3] = ["en", "zh", "th"];

#[derive(Deserialize)]
struct ProviderCredentialDocument {
    version: u32,
    credentials: HashMap<String, String>,
}

#[derive(Debug)]
struct CaptureCandidate {
    session_id: String,
    audio_key_ref: String,
    sample_rate: u32,
    channels: u16,
    captured_frames: i64,
    observed_language_count: i64,
}

#[derive(Debug)]
struct AudioChunk {
    start_ms: i64,
    end_ms: i64,
    local_path: PathBuf,
}

#[derive(Debug, Clone, Copy)]
struct SourceToken {
    key: u64,
    start_ms: u64,
}

#[derive(Default)]
struct LaneObservation {
    connected: bool,
    finished: bool,
    failed: bool,
    reconnects: usize,
    source_tokens: Vec<SourceToken>,
    source_lag_ms: Vec<u64>,
    translation_tokens: usize,
    translation_tokens_with_timestamps: usize,
    translation_batch_sizes: Vec<u64>,
    translation_batch_gap_ms: Vec<u64>,
    translation_batch_lag_ms: Vec<u64>,
    last_final_source_end_ms: u64,
    last_translation_batch_at_ms: Option<u64>,
}

impl LaneObservation {
    fn absorb_response(&mut self, tokens: &[SttStreamToken], arrival_ms: u64) {
        for token in tokens {
            match token.translation_status {
                SttStreamTranslationStatus::Original | SttStreamTranslationStatus::None
                    if token.is_final =>
                {
                    let (Some(start_ms), Some(end_ms)) = (token.start_ms, token.end_ms) else {
                        continue;
                    };
                    self.source_tokens.push(SourceToken {
                        key: word_key(&token.text),
                        start_ms,
                    });
                    self.source_lag_ms.push(arrival_ms.saturating_sub(end_ms));
                    self.last_final_source_end_ms = self.last_final_source_end_ms.max(end_ms);
                }
                _ => {}
            }
        }

        let translation_tokens = tokens
            .iter()
            .filter(|token| token.translation_status == SttStreamTranslationStatus::Translation)
            .collect::<Vec<_>>();
        if translation_tokens.is_empty() {
            return;
        }
        self.translation_tokens += translation_tokens.len();
        self.translation_tokens_with_timestamps += translation_tokens
            .iter()
            .filter(|token| token.start_ms.is_some() || token.end_ms.is_some())
            .count();
        self.translation_batch_sizes
            .push(translation_tokens.len() as u64);
        if let Some(previous) = self.last_translation_batch_at_ms {
            self.translation_batch_gap_ms
                .push(arrival_ms.saturating_sub(previous));
        }
        self.last_translation_batch_at_ms = Some(arrival_ms);
        if self.last_final_source_end_ms > 0 {
            self.translation_batch_lag_ms
                .push(arrival_ms.saturating_sub(self.last_final_source_end_ms));
        }
    }
}

type SpawnedLane = (
    tokio::sync::mpsc::Sender<Vec<u8>>,
    tokio::sync::mpsc::Sender<SttStreamControl>,
    tokio::task::JoinHandle<LaneObservation>,
    tokio::task::JoinHandle<Result<(), vt_stt::SttError>>,
);

fn data_dir() -> PathBuf {
    std::env::var_os("ZULANGUE_DATA_DIR")
        .map(PathBuf::from)
        .expect("ZULANGUE_DATA_DIR must explicitly identify the approved local profile")
}

fn requested_seconds() -> u64 {
    std::env::var("ZULANGUE_MEASURE_SECONDS")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value >= 30)
        .unwrap_or(180)
}

fn load_provider_key(data_dir: &Path) -> String {
    let path = data_dir.join("Secrets/provider-credentials.json");
    let metadata = std::fs::symlink_metadata(&path).expect("inspect provider credential document");
    assert!(
        metadata.file_type().is_file(),
        "provider credential path must be a file"
    );
    assert_eq!(
        metadata.mode() & 0o777,
        0o600,
        "provider credential file must be mode 0600"
    );
    assert_eq!(
        metadata.uid(),
        unsafe { libc::geteuid() },
        "provider credential owner mismatch"
    );
    let bytes = std::fs::read(path).expect("read provider credential document");
    let document: ProviderCredentialDocument =
        serde_json::from_slice(&bytes).expect("decode provider credential document");
    assert_eq!(
        document.version, 1,
        "unsupported provider credential version"
    );
    document
        .credentials
        .get("soniox")
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .expect("saved Soniox credential is missing")
}

fn select_capture(conn: &Connection) -> CaptureCandidate {
    conn.query_row(
        "SELECT r.session_id,
                r.audio_key_ref,
                r.sample_rate,
                r.channels,
                r.captured_frames,
                (SELECT COUNT(DISTINCT lower(trim(u.source_language)))
                 FROM realtime_utterances u
                 WHERE u.session_id = r.session_id) AS observed_language_count
         FROM notebook_capture_runs r
         WHERE r.capture_state = 'completed'
           AND r.audio_key_ref IS NOT NULL
           AND r.sample_rate > 0
           AND r.channels > 0
           AND r.captured_frames >= r.sample_rate * 60
           AND EXISTS (
               SELECT 1 FROM audio_retention_chunks c
               WHERE c.session_id = r.session_id
                 AND c.encrypted = 1
                 AND c.deleted = 0
           )
         ORDER BY observed_language_count DESC, r.created_at DESC
         LIMIT 1",
        [],
        |row| {
            Ok(CaptureCandidate {
                session_id: row.get(0)?,
                audio_key_ref: row.get(1)?,
                sample_rate: row.get(2)?,
                channels: row.get(3)?,
                captured_frames: row.get(4)?,
                observed_language_count: row.get(5)?,
            })
        },
    )
    .expect("no completed retained Zulangue capture is available")
}

fn load_chunks(conn: &Connection, session_id: &str) -> Vec<AudioChunk> {
    let mut statement = conn
        .prepare(
            "SELECT start_ms, end_ms, local_path
             FROM audio_retention_chunks
             WHERE session_id = ?1 AND encrypted = 1 AND deleted = 0
             ORDER BY start_ms, chunk_id",
        )
        .expect("prepare retained audio query");
    statement
        .query_map([session_id], |row| {
            Ok(AudioChunk {
                start_ms: row.get(0)?,
                end_ms: row.get(1)?,
                local_path: PathBuf::from(row.get::<_, String>(2)?),
            })
        })
        .expect("query retained audio")
        .collect::<Result<Vec<_>, _>>()
        .expect("decode retained audio rows")
}

fn decrypt_canonical_pcm(
    data_dir: &Path,
    candidate: &CaptureCandidate,
    chunks: &[AudioChunk],
    seconds: u64,
) -> Vec<u8> {
    let key_store =
        FileKeyStore::new(data_dir.join("Secrets/content-keys.json")).expect("open content keys");
    let key = key_store
        .load_key(&candidate.audio_key_ref)
        .expect("load capture content key");
    let captured_frames =
        u64::try_from(candidate.captured_frames).expect("capture frame count must be non-negative");
    let requested_frames =
        captured_frames.min(seconds.saturating_mul(u64::from(candidate.sample_rate)));
    let requested_bytes = usize::try_from(requested_frames)
        .ok()
        .and_then(|frames| frames.checked_mul(usize::from(candidate.channels)))
        .and_then(|samples| samples.checked_mul(std::mem::size_of::<f32>()))
        .expect("requested capture range exceeds platform limits");

    let mut f32le = Vec::with_capacity(requested_bytes);
    for chunk in chunks {
        assert!(
            chunk.end_ms >= chunk.start_ms,
            "invalid retained audio interval"
        );
        assert!(
            chunk.local_path.is_file(),
            "retained audio chunk is missing"
        );
        let mut reader = DecryptReader::new(&chunk.local_path, &key).expect("open audio chunk");
        let remaining = requested_bytes.saturating_sub(f32le.len());
        if remaining == 0 {
            break;
        }
        let mut plaintext = Vec::new();
        reader
            .read_to_end(&mut plaintext)
            .expect("decrypt audio chunk");
        let take = remaining.min(plaintext.len());
        f32le.extend_from_slice(&plaintext[..take]);
        plaintext.fill(0);
    }
    assert_eq!(
        f32le.len(),
        requested_bytes,
        "retained capture range is incomplete"
    );
    assert_eq!(f32le.len() % 4, 0, "capture f32 PCM is misaligned");

    let mut samples = f32le
        .chunks_exact(4)
        .map(|bytes| f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
        .collect::<Vec<_>>();
    f32le.fill(0);
    let canonical = canonicalize_for_soniox(&samples, candidate.sample_rate, candidate.channels)
        .expect("canonicalize retained capture");
    samples.fill(0.0);

    canonical
        .into_iter()
        .flat_map(|sample| {
            let value = if sample <= -1.0 {
                i16::MIN
            } else {
                (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
            };
            value.to_le_bytes()
        })
        .collect()
}

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
                SttStreamEvent::Tokens(tokens) => {
                    observation.absorb_response(&tokens, started.elapsed().as_millis() as u64);
                }
                SttStreamEvent::Finished => observation.finished = true,
                SttStreamEvent::Error(_) | SttStreamEvent::InputDiscontinuity => {
                    observation.failed = true;
                }
                _ => {}
            }
        }
        observation
    });
    (audio_tx, control_tx, collector, task)
}

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

fn paired_timestamp_deltas(canonical: &[SourceToken], auxiliary: &[SourceToken]) -> Vec<u64> {
    let mut deltas = Vec::new();
    let mut cursor = 0usize;
    for left in canonical {
        let mut match_at = None;
        for (offset, right) in auxiliary[cursor..].iter().enumerate() {
            if right.start_ms + MATCH_WINDOW_MS < left.start_ms {
                continue;
            }
            if right.start_ms > left.start_ms + MATCH_WINDOW_MS {
                break;
            }
            if right.key == left.key {
                match_at = Some((cursor + offset, right));
                break;
            }
        }
        let Some((index, right)) = match_at else {
            continue;
        };
        cursor = index + 1;
        deltas.push(right.start_ms.abs_diff(left.start_ms));
    }
    deltas
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

fn report_lane(name: &str, lane: &LaneObservation, canonical: &[SourceToken]) {
    let (source_p50, source_p95, source_max) = percentiles(&lane.source_lag_ms);
    let (translation_p50, translation_p95, translation_max) =
        percentiles(&lane.translation_batch_lag_ms);
    let (gap_p50, gap_p95, gap_max) = percentiles(&lane.translation_batch_gap_ms);
    let (batch_p50, batch_p95, batch_max) = percentiles(&lane.translation_batch_sizes);
    let deltas = paired_timestamp_deltas(canonical, &lane.source_tokens);
    let (_, timestamp_p95, timestamp_max) = percentiles(&deltas);
    println!(
        "lane={name} connected={} finished={} failed={} reconnects={} source_tokens={} \
         source_lag_ms[p50={source_p50},p95={source_p95},max={source_max}] \
         translation_tokens={} translation_batches={} \
         translation_lag_ms[p50={translation_p50},p95={translation_p95},max={translation_max}] \
         batch_gap_ms[p50={gap_p50},p95={gap_p95},max={gap_max}] \
         tokens_per_batch[p50={batch_p50},p95={batch_p95},max={batch_max}] \
         paired_source_tokens={} timestamp_delta_ms[p95={timestamp_p95},max={timestamp_max}]",
        lane.connected,
        lane.finished,
        lane.failed,
        lane.reconnects,
        lane.source_tokens.len(),
        lane.translation_tokens,
        lane.translation_batch_sizes.len(),
        deltas.len(),
    );
}

#[tokio::test]
#[ignore = "uses a private retained capture and spends real Soniox provider minutes"]
async fn measures_saved_capture_across_three_translation_targets_without_content_output() {
    let data_dir = data_dir();
    let api_key = load_provider_key(&data_dir);
    let conn = Connection::open_with_flags(
        data_dir.join("zulangue.db"),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .expect("open Zulangue database read-only");
    let candidate = select_capture(&conn);
    let chunks = load_chunks(&conn, &candidate.session_id);
    let requested_seconds = requested_seconds();
    let mut pcm = decrypt_canonical_pcm(&data_dir, &candidate, &chunks, requested_seconds);
    let audio_ms = pcm.len() / PCM_BYTES_PER_MILLISECOND;
    println!(
        "capture_audio_ms={audio_ms} source_sample_rate={} source_channels={} \
         observed_language_count={} target_languages=en,zh,th",
        candidate.sample_rate, candidate.channels, candidate.observed_language_count
    );

    let run_nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock")
        .as_millis();
    let cancel = CancellationToken::new();
    let started = Instant::now();
    let canonical_config = SttConfig {
        language_hints: TARGET_LANGUAGES
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        enable_language_identification: true,
        client_reference_id: Some(format!("zulangue-saved-latency-{run_nonce}-canonical")),
        ..Default::default()
    };
    let canonical = spawn_lane(api_key.clone(), canonical_config, cancel.clone(), started);
    let mut auxiliaries = TARGET_LANGUAGES
        .iter()
        .map(|target| {
            let config = SttConfig {
                language_hints: TARGET_LANGUAGES
                    .iter()
                    .map(|value| (*value).to_string())
                    .collect(),
                enable_language_identification: true,
                translation: Some(TranslationConfig::OneWay {
                    target_language: (*target).to_string(),
                }),
                client_reference_id: Some(format!(
                    "zulangue-saved-latency-{run_nonce}-target-{target}"
                )),
                ..Default::default()
            };
            (
                (*target).to_string(),
                spawn_lane(api_key.clone(), config, cancel.clone(), started),
            )
        })
        .collect::<Vec<_>>();
    drop(api_key);

    let feed_started = tokio::time::Instant::now();
    let mut elapsed_audio_ms = 0u64;
    let mut send_failed = false;
    for chunk in pcm.chunks(PCM_CHUNK_BYTES) {
        if canonical.0.send(chunk.to_vec()).await.is_err() {
            send_failed = true;
            break;
        }
        for (_, lane) in &auxiliaries {
            if lane.0.send(chunk.to_vec()).await.is_err() {
                send_failed = true;
            }
        }
        if send_failed {
            break;
        }
        elapsed_audio_ms += (chunk.len() / PCM_BYTES_PER_MILLISECOND) as u64;
        tokio::time::sleep_until(feed_started + Duration::from_millis(elapsed_audio_ms)).await;
    }
    pcm.fill(0);
    assert!(
        !send_failed,
        "a provider lane closed while feeding approved capture audio"
    );

    let (canonical_audio_tx, canonical_control_tx, canonical_collector, canonical_task) = canonical;
    drop(canonical_audio_tx);
    let _ = canonical_control_tx.send(SttStreamControl::Finish).await;
    drop(canonical_control_tx);

    let mut pending_auxiliaries = Vec::with_capacity(auxiliaries.len());
    for (target, (audio_tx, control_tx, collector, task)) in auxiliaries.drain(..) {
        drop(audio_tx);
        let _ = control_tx.send(SttStreamControl::Finish).await;
        drop(control_tx);
        pending_auxiliaries.push((target, collector, task));
    }

    let canonical_result = tokio::time::timeout(Duration::from_secs(90), canonical_task)
        .await
        .expect("canonical lane exceeded finish deadline")
        .expect("canonical lane task panicked");
    let canonical_observation = canonical_collector
        .await
        .expect("canonical collector panicked");
    assert!(canonical_result.is_ok(), "canonical provider task failed");
    assert!(canonical_observation.connected && canonical_observation.finished);
    assert!(!canonical_observation.failed);
    assert!(!canonical_observation.source_tokens.is_empty());
    report_lane(
        "canonical",
        &canonical_observation,
        &canonical_observation.source_tokens,
    );

    let mut any_translation = false;
    for (target, collector, task) in pending_auxiliaries {
        let result = tokio::time::timeout(Duration::from_secs(90), task)
            .await
            .expect("auxiliary lane exceeded finish deadline")
            .expect("auxiliary lane task panicked");
        let observation = collector.await.expect("auxiliary collector panicked");
        assert!(result.is_ok(), "target-{target} provider task failed");
        assert!(
            observation.connected && observation.finished,
            "target-{target} did not finish"
        );
        assert!(!observation.failed, "target-{target} emitted an error");
        assert_eq!(
            observation.translation_tokens_with_timestamps, 0,
            "target-{target} translation tokens acquired timestamps"
        );
        any_translation |= observation.translation_tokens > 0;
        report_lane(
            &format!("target-{target}"),
            &observation,
            &canonical_observation.source_tokens,
        );
    }
    cancel.cancel();
    assert!(
        any_translation,
        "no auxiliary translation tokens were returned"
    );
}
