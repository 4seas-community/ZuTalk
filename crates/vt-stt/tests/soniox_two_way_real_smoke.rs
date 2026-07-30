//! Opt-in real-provider smoke for the Notebook bilingual stream.
//!
//! The test deliberately never prints or persists audio, transcript tokens,
//! context, or credentials. Its only output is protocol metadata suitable for
//! a local-gate record.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio_util::sync::CancellationToken;
use vt_stt::{
    SonioxStreamClient, SttConfig, SttError, SttStreamControl, SttStreamError, SttStreamEvent,
    SttStreamTranslationStatus, TranslationConfig, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

const PCM_BYTES_PER_FRAME: usize = 2;

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
    assert_eq!(spec.sample_format, hound::SampleFormat::Int);
    reader
        .samples::<i16>()
        .flat_map(|sample| sample.expect("decode synthetic PCM sample").to_le_bytes())
        .collect()
}

#[derive(Default)]
struct SmokeEvidence {
    connected: bool,
    finished: bool,
    source_tokens: usize,
    translation_tokens: usize,
    provider_error_type: Option<String>,
    provider_request_id: Option<String>,
}

fn safe_task_failure_kind(error: &SttError) -> &'static str {
    match error {
        SttError::ConnectionFailed(_) => "connection_failed",
        SttError::ReadTimeout(_) => "read_timeout",
        SttError::ServerClosed { .. } => "server_closed",
        SttError::AuthFailed { .. } => "auth_failed",
        SttError::QuotaExhausted { .. } => "quota_exhausted",
        SttError::RateLimited => "rate_limited",
        SttError::ParseError(_) => "parse_error",
        SttError::ServerError { .. } => "server_error",
        SttError::ApiError { .. } => "api_error",
        SttError::TranscriptionFailed { .. } => "transcription_failed",
        SttError::HttpError(_) => "http_error",
        SttError::Timeout { .. } => "timeout",
        SttError::Cancelled => "cancelled",
        SttError::UploadFailed { .. } => "upload_failed",
    }
}

fn safe_provider_metadata(value: Option<String>) -> Option<String> {
    value.map(|value| {
        value
            .chars()
            .take(128)
            .map(|character| {
                if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                    character
                } else {
                    '_'
                }
            })
            .collect()
    })
}

#[tokio::test]
#[ignore = "requires an explicitly supplied real Soniox API key"]
async fn soniox_v5_two_way_real_smoke_redacts_content() {
    let api_key = load_api_key()
        .expect("SONIOX_API_KEY must be supplied through the environment or ignored local .env");

    let client_reference_id = format!(
        "zulangue-bilingual-smoke-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock")
            .as_millis()
    );
    let config = SttConfig {
        language_hints: vec!["en".to_string(), "zh".to_string()],
        enable_language_identification: true,
        translation: Some(TranslationConfig::TwoWay {
            language_a: "en".to_string(),
            language_b: "zh".to_string(),
        }),
        client_reference_id: Some(client_reference_id.clone()),
        ..Default::default()
    };
    let cancel = CancellationToken::new();
    let runtime = SonioxStreamClient::start(
        CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_endpoint,
        api_key,
        config,
        cancel.clone(),
    );
    let vt_stt::SonioxStreamRuntime {
        audio_tx,
        control_tx,
        mut event_rx,
        task,
    } = runtime;

    let collector = tokio::spawn(async move {
        let mut evidence = SmokeEvidence::default();
        while let Some(event) = event_rx.recv().await {
            match event {
                SttStreamEvent::Connected => evidence.connected = true,
                SttStreamEvent::Reconnecting { .. } => {}
                SttStreamEvent::RecoveryStarted { .. } => {}
                SttStreamEvent::AudioProgress { .. } => {}
                SttStreamEvent::Tokens(tokens) => {
                    for token in tokens {
                        match token.translation_status {
                            SttStreamTranslationStatus::Translation => {
                                evidence.translation_tokens += 1;
                                assert!(
                                    token.start_ms.is_none() && token.end_ms.is_none(),
                                    "translation tokens must not acquire timestamps"
                                );
                            }
                            SttStreamTranslationStatus::Original
                            | SttStreamTranslationStatus::None => {
                                evidence.source_tokens += 1;
                            }
                            SttStreamTranslationStatus::Unknown(_) => {}
                        }
                    }
                }
                SttStreamEvent::Finished => evidence.finished = true,
                SttStreamEvent::Error(SttStreamError::Provider(error)) => {
                    evidence.provider_error_type = safe_provider_metadata(Some(error.error_type));
                    evidence.provider_request_id = safe_provider_metadata(error.request_id);
                }
                SttStreamEvent::Error(error) => {
                    evidence.provider_error_type = Some(
                        match error {
                            SttStreamError::Transport { .. } | SttStreamError::Closed { .. } => {
                                "transport_error"
                            }
                            SttStreamError::Protocol { .. } => "protocol_error",
                            SttStreamError::Timeout { .. } => "timeout",
                            SttStreamError::Provider(_) => unreachable!("handled above"),
                        }
                        .to_string(),
                    );
                }
                SttStreamEvent::Endpoint | SttStreamEvent::Finalized => {}
            }
        }
        evidence
    });

    let pcm = speech_fixture_pcm();
    let mut audio_channel_closed = false;
    for chunk in pcm.chunks(3_200) {
        if audio_tx.send(chunk.to_vec()).await.is_err() {
            audio_channel_closed = true;
            break;
        }
        // Stream at capture speed so the fixed five-second product drain tests
        // a realistic provider tail instead of an artificially queued backlog.
        let frames = chunk.len() / PCM_BYTES_PER_FRAME;
        tokio::time::sleep(Duration::from_secs_f64(
            frames as f64 / f64::from(CURRENT_NOTEBOOK_CAPTURE_ENGINE.sample_rate),
        ))
        .await;
    }
    drop(audio_tx);
    let _ = control_tx.send(SttStreamControl::Finish).await;
    drop(control_tx);

    let task_result = tokio::time::timeout(Duration::from_secs(30), task)
        .await
        .expect("real smoke exceeded deadline")
        .expect("stream task panicked");
    let evidence = collector.await.expect("collector panicked");
    if let Err(error) = task_result {
        cancel.cancel();
        panic!(
            "Soniox stream failed: task_kind={} connected={} finished={} source_tokens={} translation_tokens={} provider_type={:?} request_id={:?}",
            safe_task_failure_kind(&error),
            evidence.connected,
            evidence.finished,
            evidence.source_tokens,
            evidence.translation_tokens,
            evidence.provider_error_type,
            evidence.provider_request_id
        );
    }

    assert!(
        !audio_channel_closed,
        "stream closed while sending fixture audio"
    );
    assert!(evidence.connected, "stream never connected");
    assert!(evidence.finished, "stream did not acknowledge finished");
    assert!(evidence.source_tokens > 0, "no source tokens returned");
    assert!(
        evidence.translation_tokens > 0,
        "two-way mode returned no translation tokens"
    );
    assert!(
        evidence.provider_error_type.is_none(),
        "provider error type={:?} request_id={:?}",
        evidence.provider_error_type,
        evidence.provider_request_id
    );
    println!(
        "model={} result=pass provider_request_id=not_returned_on_success",
        CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id
    );
}

#[test]
fn smoke_failure_metadata_never_contains_remote_payloads() {
    let secret = "remote detail with credential-shaped text";
    let variants = [
        SttError::ConnectionFailed(secret.to_string()),
        SttError::ServerClosed {
            code: 1008,
            reason: secret.to_string(),
        },
        SttError::AuthFailed {
            message: secret.to_string(),
        },
        SttError::ParseError(secret.to_string()),
        SttError::HttpError(secret.to_string()),
    ];

    for error in variants {
        let kind = safe_task_failure_kind(&error);
        assert!(!kind.contains("remote"));
        assert!(!kind.contains("credential"));
    }

    assert_eq!(
        safe_provider_metadata(Some("bad type\nsecret=value".to_string())).as_deref(),
        Some("bad_type_secret_value")
    );
}
