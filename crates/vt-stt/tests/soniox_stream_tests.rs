use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;
use vt_stt::{
    SonioxStreamClient, SttConfig, SttStreamControl, SttStreamEvent, SttStreamTranslationStatus,
    TranslationConfig, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

#[derive(Debug, PartialEq)]
enum ClientFrame {
    Text(Value),
    Audio(Vec<u8>),
    Finish,
}

#[tokio::test]
async fn v5_two_way_stream_preserves_order_and_optional_timestamps() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let (frame_tx, mut frame_rx) = mpsc::channel(16);

    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let ws = accept_async(stream).await.unwrap();
        let (mut write, mut read) = ws.split();
        while let Some(Ok(message)) = read.next().await {
            match message {
                Message::Text(text) if text.is_empty() => {
                    frame_tx.send(ClientFrame::Finish).await.unwrap();
                    // A tail token in the same response as finished must be consumed first.
                    write
                        .send(Message::Text(
                            json!({
                                "tokens": [{
                                    "text": "。",
                                    "is_final": true,
                                    "translation_status": "translation",
                                    "language": "zh",
                                    "source_language": "en"
                                }],
                                "finished": true
                            })
                            .to_string()
                            .into(),
                        ))
                        .await
                        .unwrap();
                    break;
                }
                Message::Text(text) => {
                    let value: Value = serde_json::from_str(&text).unwrap();
                    frame_tx
                        .send(ClientFrame::Text(value.clone()))
                        .await
                        .unwrap();
                    if value == json!({"type": "finalize"}) {
                        write
                            .send(Message::Text(
                                json!({
                                    "tokens": [{"text": "<fin>", "is_final": true}],
                                    "finished": false
                                })
                                .to_string()
                                .into(),
                            ))
                            .await
                            .unwrap();
                    }
                }
                Message::Binary(bytes) => {
                    frame_tx
                        .send(ClientFrame::Audio(bytes.to_vec()))
                        .await
                        .unwrap();
                    // One spoken token maps to two translated tokens. They have no timestamps and
                    // must not be associated or deduplicated by the source timestamp.
                    write
                        .send(Message::Text(
                            json!({
                                "tokens": [
                                    {
                                        "text": "Hello",
                                        "start_ms": 120,
                                        "end_ms": 480,
                                        "is_final": true,
                                        "translation_status": "original",
                                        "language": "en",
                                        "speaker": "1",
                                        "confidence": 0.98
                                    },
                                    {"text": "<end>", "is_final": true},
                                    {
                                        "text": "你",
                                        "is_final": true,
                                        "translation_status": "translation",
                                        "language": "zh",
                                        "source_language": "en"
                                    },
                                    {
                                        "text": "好",
                                        "is_final": true,
                                        "translation_status": "translation",
                                        "language": "zh",
                                        "source_language": "en"
                                    }
                                ],
                                "finished": false
                            })
                            .to_string()
                            .into(),
                        ))
                        .await
                        .unwrap();
                }
                _ => {}
            }
        }
    });

    let config = SttConfig {
        language_hints: vec!["en".to_string(), "zh".to_string()],
        enable_language_identification: true,
        enable_speaker_diarization: true,
        translation: Some(TranslationConfig::TwoWay {
            language_a: "en".to_string(),
            language_b: "zh".to_string(),
        }),
        client_reference_id: Some("capture-run-42".to_string()),
        ..Default::default()
    };
    let mut runtime =
        SonioxStreamClient::start(endpoint, "test-key", config, CancellationToken::new());

    assert_eq!(
        runtime.event_rx.recv().await,
        Some(SttStreamEvent::Connected)
    );
    let config_frame = frame_rx.recv().await.unwrap();
    let ClientFrame::Text(config_json) = config_frame else {
        panic!("first client frame must be JSON configuration");
    };
    let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
    assert_eq!(config_json["model"], engine.realtime_model_id);
    assert_eq!(config_json["audio_format"], engine.audio_format);
    assert_eq!(config_json["sample_rate"], engine.sample_rate);
    assert_eq!(config_json["num_channels"], engine.channels);
    assert_eq!(config_json["client_reference_id"], "capture-run-42");
    assert_eq!(config_json["enable_speaker_diarization"], true);
    assert_eq!(config_json["enable_endpoint_detection"], true);
    assert_eq!(config_json["endpoint_latency_adjustment_level"], 0);
    assert_eq!(config_json["endpoint_sensitivity"], 0.0);
    assert_eq!(config_json["max_endpoint_delay_ms"], 2_000);
    assert_eq!(
        config_json["translation"],
        json!({"type": "two_way", "language_a": "en", "language_b": "zh"})
    );
    assert!(config_json["translation"].get("target_language").is_none());

    runtime.push_pcm(vec![1, 2, 3, 4]).await.unwrap();
    assert!(matches!(
        frame_rx.recv().await,
        Some(ClientFrame::Audio(bytes)) if bytes == vec![1, 2, 3, 4]
    ));
    let SttStreamEvent::Tokens(tokens) = runtime.event_rx.recv().await.unwrap() else {
        panic!("expected ordered token batch");
    };
    assert_eq!(tokens.len(), 3);
    assert_eq!(tokens[0].text, "Hello");
    assert_eq!(tokens[0].start_ms, Some(120));
    assert_eq!(tokens[0].end_ms, Some(480));
    assert_eq!(tokens[0].speaker.as_deref(), Some("1"));
    assert_eq!(
        tokens[0].translation_status,
        SttStreamTranslationStatus::Original
    );
    assert_eq!(tokens[1].text, "你");
    assert_eq!(tokens[1].start_ms, None);
    assert_eq!(tokens[1].end_ms, None);
    assert_eq!(tokens[1].speaker, None);
    assert_eq!(tokens[2].text, "好");
    assert_eq!(tokens[2].start_ms, None);
    assert_eq!(tokens[2].end_ms, None);
    assert_eq!(
        tokens[2].translation_status,
        SttStreamTranslationStatus::Translation
    );
    assert_eq!(
        runtime.event_rx.recv().await,
        Some(SttStreamEvent::Endpoint)
    );

    runtime
        .send_control(SttStreamControl::Finalize)
        .await
        .unwrap();
    assert_eq!(
        frame_rx.recv().await,
        Some(ClientFrame::Text(json!({"type": "finalize"})))
    );
    assert_eq!(
        runtime.event_rx.recv().await,
        Some(SttStreamEvent::Finalized)
    );

    runtime
        .send_control(SttStreamControl::Finish)
        .await
        .unwrap();
    assert!(matches!(frame_rx.recv().await, Some(ClientFrame::Finish)));
    let SttStreamEvent::Tokens(tail) = runtime.event_rx.recv().await.unwrap() else {
        panic!("tail token must be delivered before finished");
    };
    assert_eq!(tail[0].text, "。");
    assert_eq!(tail[0].start_ms, None);
    assert_eq!(
        runtime.event_rx.recv().await,
        Some(SttStreamEvent::Finished)
    );
    assert!(runtime.task.await.unwrap().is_ok());
}

#[tokio::test]
async fn provider_error_event_retains_numeric_code_type_and_request_id() {
    const HOSTILE_REMOTE_MESSAGE: &str =
        "credential-shaped provider detail api_key=stream-fixture-never-log";
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let ws = accept_async(stream).await.unwrap();
        let (mut write, mut read) = ws.split();
        let _ = read.next().await;
        write
            .send(Message::Text(
                json!({
                    "tokens": [],
                    "error_code": 422,
                    "error_type": "invalid_request",
                    "error_message": HOSTILE_REMOTE_MESSAGE,
                    "request_id": "req-stream-422"
                })
                .to_string()
                .into(),
            ))
            .await
            .unwrap();
    });

    let mut runtime = SonioxStreamClient::start(
        endpoint,
        "test-key",
        SttConfig::default(),
        CancellationToken::new(),
    );
    assert_eq!(
        runtime.event_rx.recv().await,
        Some(SttStreamEvent::Connected)
    );
    let Some(SttStreamEvent::Error(vt_stt::SttStreamError::Provider(error))) =
        runtime.event_rx.recv().await
    else {
        panic!("expected typed provider error");
    };
    assert_eq!(error.error_code, 422);
    assert_eq!(error.error_type, "invalid_request");
    assert_eq!(error.error_message, "provider request failed");
    assert!(!error.error_message.contains(HOSTILE_REMOTE_MESSAGE));
    assert_eq!(error.request_id.as_deref(), Some("req-stream-422"));
    let task_error = runtime
        .task
        .await
        .unwrap()
        .expect_err("provider response must fail the stream task");
    let visible_error = task_error.to_string();
    assert!(!visible_error.contains(HOSTILE_REMOTE_MESSAGE));
    assert!(!visible_error.contains("stream-fixture-never-log"));
}

#[tokio::test]
async fn pause_and_finish_fence_audio_accepted_before_control() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let (frame_tx, mut frame_rx) = mpsc::channel(16);
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let ws = accept_async(stream).await.unwrap();
        let (mut write, mut read) = ws.split();
        while let Some(Ok(message)) = read.next().await {
            match message {
                Message::Text(text) if text.is_empty() => {
                    frame_tx.send(ClientFrame::Finish).await.unwrap();
                    write
                        .send(Message::Text(
                            json!({"tokens": [], "finished": true}).to_string().into(),
                        ))
                        .await
                        .unwrap();
                    break;
                }
                Message::Text(text) => {
                    frame_tx
                        .send(ClientFrame::Text(serde_json::from_str(&text).unwrap()))
                        .await
                        .unwrap();
                }
                Message::Binary(bytes) => {
                    frame_tx
                        .send(ClientFrame::Audio(bytes.to_vec()))
                        .await
                        .unwrap();
                }
                _ => {}
            }
        }
    });

    let mut runtime = SonioxStreamClient::start(
        endpoint,
        "test-key",
        SttConfig::default(),
        CancellationToken::new(),
    );
    assert_eq!(
        runtime.event_rx.recv().await,
        Some(SttStreamEvent::Connected)
    );
    assert!(matches!(frame_rx.recv().await, Some(ClientFrame::Text(_))));

    runtime.audio_tx.try_send(vec![1, 2]).unwrap();
    runtime
        .control_tx
        .try_send(SttStreamControl::Pause)
        .unwrap();
    assert_eq!(frame_rx.recv().await, Some(ClientFrame::Audio(vec![1, 2])));
    assert_eq!(
        frame_rx.recv().await,
        Some(ClientFrame::Text(json!({"type": "finalize"})))
    );

    runtime
        .control_tx
        .try_send(SttStreamControl::Resume)
        .unwrap();
    runtime.audio_tx.try_send(vec![3, 4]).unwrap();
    runtime
        .control_tx
        .try_send(SttStreamControl::Finish)
        .unwrap();
    assert_eq!(frame_rx.recv().await, Some(ClientFrame::Audio(vec![3, 4])));
    assert_eq!(frame_rx.recv().await, Some(ClientFrame::Finish));
    assert_eq!(
        runtime.event_rx.recv().await,
        Some(SttStreamEvent::Finished)
    );
    assert!(runtime.task.await.unwrap().is_ok());
}
