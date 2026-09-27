//! Opt-in real-provider measurement: how a multilingual capture's lane plan
//! holds up at real-time pace.
//!
//! Three-language capture opens one transcription-only connection plus one
//! translating connection per language, all fed the same audio. Recordings
//! made that way fell behind — lanes at about 0.8x real time, translation
//! minutes late — and three-language recordings on this machine left 37–52%
//! of rows without a translation from the first minutes on. Before changing
//! the plan, this measures the alternatives on identical audio:
//!
//! - `current`: transcription + one-way to each of three languages (4 lanes)
//! - `pair_plus_third`: two-way between the two spoken languages + one-way to
//!   the third (2 lanes)
//! - `pair_only`: the two-way lane alone (1 lane), the baseline two-language
//!   capture already runs on
//!
//! Input is a 16 kHz mono 16-bit WAV named by `ZUTALK_PLAN_WAV`; use synthetic
//! speech, never a real recording. Output is counts and milliseconds only.

use std::time::{Duration, Instant};

use tokio_util::sync::CancellationToken;
use vt_stt::{
    SonioxStreamClient, SttConfig, SttStreamControl, SttStreamEvent, SttStreamTranslationStatus,
    TranslationConfig, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

const PCM_CHUNK_BYTES: usize = 3_200;
const PCM_BYTES_PER_MILLISECOND: usize = 32;

fn wav_pcm() -> Vec<u8> {
    let path = std::env::var("ZUTALK_PLAN_WAV").expect("ZUTALK_PLAN_WAV names the input WAV");
    let mut reader = hound::WavReader::open(path).expect("read input WAV");
    let spec = reader.spec();
    assert_eq!(spec.sample_rate, 16_000);
    assert_eq!(spec.channels, 1);
    assert_eq!(spec.bits_per_sample, 16);
    reader
        .samples::<i16>()
        .flat_map(|sample| sample.expect("decode PCM sample").to_le_bytes())
        .collect()
}

fn lane_plan(name: &str) -> Vec<(&'static str, Option<TranslationConfig>)> {
    let one_way = |target: &str| {
        Some(TranslationConfig::OneWay {
            target_language: target.to_string(),
        })
    };
    let two_way = || {
        Some(TranslationConfig::TwoWay {
            language_a: "zh".to_string(),
            language_b: "en".to_string(),
        })
    };
    match name {
        "current" => vec![
            ("transcription", None),
            ("one_way:en", one_way("en")),
            ("one_way:zh", one_way("zh")),
            ("one_way:th", one_way("th")),
        ],
        "pair_plus_third" => vec![("two_way:zh-en", two_way()), ("one_way:th", one_way("th"))],
        "pair_only" => vec![("two_way:zh-en", two_way())],
        other => panic!("unknown lane plan {other}"),
    }
}

#[derive(Default)]
struct Lane {
    reconnects: usize,
    failed: bool,
    source_final_lag_ms: Vec<(u64, u64)>,
    translation_lag_ms: Vec<(u64, u64)>,
    translation_tokens_by_language: std::collections::BTreeMap<String, usize>,
    last_final_source_end_ms: u64,
    last_total_audio_proc_ms: u64,
    last_reported_lag_ms: Vec<(u64, u64)>,
    endpoints: usize,
}

fn percentile(values: &mut [u64], p: f64) -> u64 {
    if values.is_empty() {
        return 0;
    }
    values.sort_unstable();
    values[((values.len() - 1) as f64 * p).round() as usize]
}

fn by_minute(samples: &[(u64, u64)]) -> String {
    let mut minutes = std::collections::BTreeMap::<u64, Vec<u64>>::new();
    for (at, value) in samples {
        minutes.entry(at / 60_000).or_default().push(*value);
    }
    minutes
        .into_iter()
        .map(|(minute, mut values)| format!("{minute}:{}", percentile(&mut values, 0.5)))
        .collect::<Vec<_>>()
        .join(" ")
}

#[tokio::test]
#[ignore = "requires a real Soniox API key and spends provider minutes"]
async fn multilingual_lane_plans_at_real_time_pace() {
    let api_key = std::env::var("SONIOX_API_KEY").expect("SONIOX_API_KEY");
    let plan_name = std::env::var("ZUTALK_LANE_PLAN").unwrap_or_else(|_| "current".into());
    let plan = lane_plan(&plan_name);
    let pcm = wav_pcm();
    let audio_ms = (pcm.len() / PCM_BYTES_PER_MILLISECOND) as u64;
    let cancel = CancellationToken::new();
    let started = Instant::now();

    let mut senders = Vec::new();
    let mut collectors = Vec::new();
    for (index, (name, translation)) in plan.iter().enumerate() {
        let config = SttConfig {
            language_hints: vec!["zh".into(), "en".into(), "th".into()],
            enable_language_identification: true,
            enable_speaker_diarization: true,
            translation: translation.clone(),
            client_reference_id: Some(format!("zutalk-lane-plan-{plan_name}-{index}")),
            ..Default::default()
        };
        let runtime = SonioxStreamClient::start(
            CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_endpoint,
            api_key.clone(),
            config,
            cancel.child_token(),
        );
        let vt_stt::SonioxStreamRuntime {
            audio_tx,
            control_tx,
            mut event_rx,
            task,
        } = runtime;
        senders.push((audio_tx, control_tx));
        let name = name.to_string();
        collectors.push(tokio::spawn(async move {
            let mut lane = Lane::default();
            while let Some(event) = event_rx.recv().await {
                let now = started.elapsed().as_millis() as u64;
                match event {
                    SttStreamEvent::Reconnecting { .. } => lane.reconnects += 1,
                    SttStreamEvent::Error(_) => lane.failed = true,
                    SttStreamEvent::Endpoint => lane.endpoints += 1,
                    SttStreamEvent::AudioProgress {
                        total_audio_proc_ms,
                        lag_ms,
                        ..
                    } => {
                        lane.last_total_audio_proc_ms = total_audio_proc_ms;
                        lane.last_reported_lag_ms.push((now, lag_ms));
                    }
                    SttStreamEvent::Tokens(tokens) => {
                        let mut had_translation = false;
                        for token in &tokens {
                            match &token.translation_status {
                                SttStreamTranslationStatus::Translation => {
                                    had_translation = true;
                                    *lane
                                        .translation_tokens_by_language
                                        .entry(token.language.clone().unwrap_or_else(|| "?".into()))
                                        .or_default() += 1;
                                }
                                _ if token.is_final => {
                                    if let Some(end) = token.end_ms {
                                        lane.source_final_lag_ms
                                            .push((now, now.saturating_sub(end)));
                                        lane.last_final_source_end_ms =
                                            lane.last_final_source_end_ms.max(end);
                                    }
                                }
                                _ => {}
                            }
                        }
                        if had_translation && lane.last_final_source_end_ms > 0 {
                            lane.translation_lag_ms
                                .push((now, now.saturating_sub(lane.last_final_source_end_ms)));
                        }
                    }
                    _ => {}
                }
            }
            (name, lane, task)
        }));
    }

    let feed_started = tokio::time::Instant::now();
    let mut fed_ms = 0u64;
    for chunk in pcm.chunks(PCM_CHUNK_BYTES) {
        for (audio, _) in &senders {
            let _ = audio.try_send(chunk.to_vec());
        }
        fed_ms += (chunk.len() / PCM_BYTES_PER_MILLISECOND) as u64;
        tokio::time::sleep_until(feed_started + Duration::from_millis(fed_ms)).await;
    }
    for (audio, control) in senders {
        drop(audio);
        let _ = control.send(SttStreamControl::Finish).await;
    }

    println!(
        "plan={plan_name} lanes={} audio_s={}",
        plan.len(),
        audio_ms / 1_000
    );
    for collector in collectors {
        let (name, lane, task) = tokio::time::timeout(Duration::from_secs(180), collector)
            .await
            .expect("lane drained")
            .expect("collector");
        let _ = tokio::time::timeout(Duration::from_secs(30), task).await;
        let mut source: Vec<u64> = lane.source_final_lag_ms.iter().map(|(_, v)| *v).collect();
        let mut translation: Vec<u64> = lane.translation_lag_ms.iter().map(|(_, v)| *v).collect();
        let mut reported: Vec<u64> = lane.last_reported_lag_ms.iter().map(|(_, v)| *v).collect();
        println!(
            "lane={name} processed_s={} of {} reconnects={} failed={} endpoints={} \
             source_final_lag_ms p50={} p95={} max={} | translation_lag_ms p50={} p95={} | \
             provider_lag_ms p50={} p95={} max={} | translation_tokens={:?}",
            lane.last_total_audio_proc_ms / 1_000,
            audio_ms / 1_000,
            lane.reconnects,
            lane.failed,
            lane.endpoints,
            percentile(&mut source, 0.5),
            percentile(&mut source, 0.95),
            source.iter().max().copied().unwrap_or(0),
            percentile(&mut translation, 0.5),
            percentile(&mut translation, 0.95),
            percentile(&mut reported, 0.5),
            percentile(&mut reported, 0.95),
            reported.iter().max().copied().unwrap_or(0),
            lane.translation_tokens_by_language,
        );
        println!(
            "lane={name} source_final_lag_p50_by_minute {}",
            by_minute(&lane.source_final_lag_ms)
        );
        println!(
            "lane={name} provider_lag_p50_by_minute {}",
            by_minute(&lane.last_reported_lag_ms)
        );
    }
    cancel.cancel();
}
