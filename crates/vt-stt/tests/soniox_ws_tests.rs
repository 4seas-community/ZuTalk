use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::{broadcast, mpsc, watch, Mutex};
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;

use vt_model::{AudioChannel, AudioChunk};
use vt_stt::{
    ConnectionStatus, ContextConfig, SonioxRtClient, SttConfig, CURRENT_NOTEBOOK_CAPTURE_ENGINE,
};

/// 启动一个 mock Soniox WebSocket 服务器
async fn start_mock_server() -> (SocketAddr, Arc<Mutex<Option<Value>>>, Arc<Mutex<u32>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let received_config = Arc::new(Mutex::new(None));
    let audio_count = Arc::new(Mutex::new(0u32));

    let cfg = received_config.clone();
    let cnt = audio_count.clone();

    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();

            while let Some(Ok(msg)) = read.next().await {
                match msg {
                    Message::Text(text) => {
                        // 配置消息
                        if let Ok(v) = serde_json::from_str::<Value>(&text) {
                            *cfg.lock().await = Some(v);
                        }
                    }
                    Message::Binary(data) => {
                        if data.is_empty() {
                            // 空帧 = 优雅关闭
                            let finished = json!({ "tokens": [], "finished": true });
                            let _ = write.send(Message::Text(finished.to_string().into())).await;
                            break;
                        }
                        let mut c = cnt.lock().await;
                        *c += 1;
                        // 每个音频帧返回一个 token
                        let response = json!({
                            "tokens": [{
                                "text": format!("word{}", *c),
                                "start_ms": (*c as u64 - 1) * 500,
                                "end_ms": *c as u64 * 500,
                                "is_final": true,
                                "confidence": 0.95
                            }],
                            "finished": false
                        });
                        let _ = write.send(Message::Text(response.to_string().into())).await;
                    }
                    Message::Close(_) => break,
                    _ => {}
                }
            }
        }
    });

    (addr, received_config, audio_count)
}

#[tokio::test]
async fn test_post_stop_connect_and_config_uses_current_engine() {
    let (addr, received_config, _) = start_mock_server().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());

    let (audio_tx, audio_rx) = mpsc::channel(16);
    let (token_tx, _token_rx) = broadcast::channel(16);
    #[allow(unused_mut)]
    let (status_tx, status_rx) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    // 立刻关闭 audio 触发优雅关闭
    drop(audio_tx);

    let stt_config = SttConfig {
        enable_speaker_diarization: true,
        ..Default::default()
    };
    SonioxRtClient::run_post_stop(
        &endpoint,
        "test-api-key",
        &stt_config,
        audio_rx,
        token_tx,
        status_tx,
        cancel,
    )
    .await
    .unwrap();

    // 验证连接状态变为 Connected
    assert_eq!(*status_rx.borrow(), ConnectionStatus::Connected);

    // 验证配置消息已发送
    let config = received_config.lock().await;
    let config = config.as_ref().unwrap();
    let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;
    assert_eq!(config["model"], engine.post_stop_model_id);
    assert_eq!(config["api_key"], "test-api-key");
    assert_eq!(config["audio_format"], engine.audio_format);
    assert_eq!(config["sample_rate"], engine.sample_rate);
    assert_eq!(config["num_channels"], engine.channels);
    assert_eq!(config["enable_speaker_diarization"], true);
    assert_eq!(config["enable_endpoint_detection"], true);
    assert_eq!(config["endpoint_latency_adjustment_level"], 0);
    assert_eq!(config["endpoint_sensitivity"], 0.0);
    assert_eq!(config["max_endpoint_delay_ms"], 2_000);

    // 默认配置没有 language_hints，因此请求必须启用自动语言识别。
    assert_eq!(
        config["enable_language_identification"], true,
        "default config must enable language identification when language_hints is empty"
    );
}

#[tokio::test]
async fn test_context_is_serialized_in_config() {
    let (addr, received_config, _) = start_mock_server().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());

    let (audio_tx, audio_rx) = mpsc::channel(16);
    let (token_tx, _token_rx) = broadcast::channel(16);
    let (status_tx, _status_rx) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    drop(audio_tx);

    let config = SttConfig {
        context: Some(ContextConfig {
            general: vec![
                ("domain".to_string(), "Voice dictation".to_string()),
                ("language".to_string(), "Chinese".to_string()),
            ],
            text: None,
            terms: vec!["浮窗".to_string(), "灵动岛".to_string()],
            translation_terms: Vec::new(),
        }),
        ..Default::default()
    };

    SonioxRtClient::run(
        &endpoint,
        "test-api-key",
        &config,
        audio_rx,
        token_tx,
        status_tx,
        cancel,
    )
    .await
    .unwrap();

    let config = received_config.lock().await;
    let config = config.as_ref().unwrap();
    assert_eq!(config["context"]["general"][0]["key"], "domain");
    assert_eq!(config["context"]["general"][0]["value"], "Voice dictation");
    assert_eq!(config["context"]["terms"][0], "浮窗");
    assert_eq!(config["context"]["terms"][1], "灵动岛");
}

#[tokio::test]
async fn test_send_audio_receive_tokens() {
    let (addr, _, audio_count) = start_mock_server().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());

    let (audio_tx, audio_rx) = mpsc::channel(16);
    let (token_tx, mut token_rx) = broadcast::channel(16);
    let (status_tx, _) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    // 发送 3 个音频帧
    for _ in 0..3 {
        audio_tx
            .send(AudioChunk {
                pcm_data: vec![0u8; 640],
                channel: AudioChannel::Microphone,
                captured_at_ns: 0,
            })
            .await
            .unwrap();
    }
    drop(audio_tx); // 关闭触发优雅结束

    SonioxRtClient::run(
        &endpoint,
        "key",
        &SttConfig::default(),
        audio_rx,
        token_tx,
        status_tx,
        cancel,
    )
    .await
    .unwrap();

    // 验证收到 3 个 token
    let t1 = token_rx.recv().await.unwrap();
    assert_eq!(t1.text, "word1");
    assert!(t1.is_final);

    let t2 = token_rx.recv().await.unwrap();
    assert_eq!(t2.text, "word2");

    let t3 = token_rx.recv().await.unwrap();
    assert_eq!(t3.text, "word3");

    // 验证服务端收到 3 个音频帧
    assert_eq!(*audio_count.lock().await, 3);
}

#[tokio::test]
async fn test_graceful_close() {
    let (addr, _, _) = start_mock_server().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());

    let (audio_tx, audio_rx) = mpsc::channel(16);
    let (token_tx, _) = broadcast::channel(16);
    let (status_tx, _) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    // 不发送任何音频，直接关闭
    drop(audio_tx);

    // 应该正常完成不 panic
    let result = SonioxRtClient::run(
        &endpoint,
        "key",
        &SttConfig::default(),
        audio_rx,
        token_tx,
        status_tx,
        cancel,
    )
    .await;

    assert!(result.is_ok());
}

#[tokio::test]
async fn test_cancel_stops_client() {
    let (addr, _, _) = start_mock_server().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());

    let (audio_tx, audio_rx) = mpsc::channel(16);
    let (token_tx, _) = broadcast::channel(16);
    let (status_tx, _) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    let cancel_clone = cancel.clone();

    let handle = tokio::spawn(async move {
        SonioxRtClient::run(
            &endpoint,
            "key",
            &SttConfig::default(),
            audio_rx,
            token_tx,
            status_tx,
            cancel_clone,
        )
        .await
    });

    // 持续发音频
    let send_handle = tokio::spawn(async move {
        loop {
            if audio_tx
                .send(AudioChunk {
                    pcm_data: vec![0u8; 640],
                    channel: AudioChannel::Microphone,
                    captured_at_ns: 0,
                })
                .await
                .is_err()
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    });

    // 100ms 后取消
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    cancel.cancel();

    let result = handle.await.unwrap();
    assert!(result.is_ok());

    send_handle.abort();
}

#[tokio::test]
async fn test_translation_status_mapping() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();
            // 跳过配置消息
            let _ = read.next().await;
            // 跳过音频帧
            let _ = read.next().await;
            // 返回含翻译状态的 tokens
            let response = json!({
                "tokens": [
                    {"text": "Hello", "is_final": true, "translation_status": "original", "start_ms": 0, "end_ms": 500},
                    {"text": "你好", "is_final": true, "translation_status": "translation", "start_ms": 0, "end_ms": 500}
                ],
                "finished": false
            });
            let _ = write.send(Message::Text(response.to_string().into())).await;
            // 等待空帧
            let _ = read.next().await;
            let finished = json!({"tokens": [], "finished": true});
            let _ = write.send(Message::Text(finished.to_string().into())).await;
        }
    });

    let endpoint = format!("ws://127.0.0.1:{}", addr.port());
    let (audio_tx, audio_rx) = mpsc::channel(16);
    let (token_tx, mut token_rx) = broadcast::channel(16);
    let (status_tx, _) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    let config = SttConfig {
        translation: Some(vt_stt::TranslationConfig::OneWay {
            target_language: "zh".to_string(),
        }),
        ..Default::default()
    };

    audio_tx
        .send(AudioChunk {
            pcm_data: vec![0u8; 640],
            channel: AudioChannel::Microphone,
            captured_at_ns: 0,
        })
        .await
        .unwrap();
    drop(audio_tx);

    SonioxRtClient::run(
        &endpoint, "key", &config, audio_rx, token_tx, status_tx, cancel,
    )
    .await
    .unwrap();

    let t1 = token_rx.recv().await.unwrap();
    assert_eq!(t1.text, "Hello");
    assert_eq!(t1.translation_status, vt_model::TranslationStatus::Original);

    let t2 = token_rx.recv().await.unwrap();
    assert_eq!(t2.text, "你好");
    assert_eq!(
        t2.translation_status,
        vt_model::TranslationStatus::Translation
    );
}

/// SonioxRtToken 的 language 和匿名 speaker 字段必须保留到 vt_model::Token。
#[tokio::test]
async fn test_post_stop_token_language_and_speaker_fields_preserved() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();
            let _ = read.next().await; // 跳过配置
            let _ = read.next().await; // 跳过音频
                                       // Soniox RT 在每个 token 上带 language 代码
            let response = json!({
                "tokens": [
                    {"text": "Hello", "is_final": true, "translation_status": "original",
                     "language": "en", "speaker": "speaker-1", "start_ms": 0, "end_ms": 500},
                    {"text": "你好", "is_final": true, "translation_status": "translation",
                     "language": "zh", "start_ms": 0, "end_ms": 500}
                ],
                "finished": false
            });
            let _ = write.send(Message::Text(response.to_string().into())).await;
            let _ = read.next().await;
            let finished = json!({"tokens": [], "finished": true});
            let _ = write.send(Message::Text(finished.to_string().into())).await;
        }
    });

    let endpoint = format!("ws://127.0.0.1:{}", addr.port());
    let (audio_tx, audio_rx) = mpsc::channel(16);
    let (token_tx, mut token_rx) = broadcast::channel(16);
    let (status_tx, _) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    let config = SttConfig {
        translation: Some(vt_stt::TranslationConfig::OneWay {
            target_language: "zh".to_string(),
        }),
        ..Default::default()
    };

    audio_tx
        .send(AudioChunk {
            pcm_data: vec![0u8; 640],
            channel: AudioChannel::Microphone,
            captured_at_ns: 0,
        })
        .await
        .unwrap();
    drop(audio_tx);

    SonioxRtClient::run_post_stop(
        &endpoint, "key", &config, audio_rx, token_tx, status_tx, cancel,
    )
    .await
    .unwrap();

    let t1 = token_rx.recv().await.unwrap();
    assert_eq!(t1.text, "Hello");
    assert_eq!(
        t1.language, "en",
        "original token must carry source language"
    );
    assert_eq!(t1.speaker.as_deref(), Some("speaker-1"));

    let t2 = token_rx.recv().await.unwrap();
    assert_eq!(t2.text, "你好");
    assert_eq!(
        t2.language, "zh",
        "translation token must carry target language"
    );
    assert_eq!(t2.speaker, None, "missing speaker must remain compatible");
}

// ============================================================
// SonioxRtClient::test_key response paths.
// ============================================================

/// 启动一个返回 normal text 响应的 mock server（模拟 valid key）
async fn mock_server_valid_key() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();
            // 等配置消息
            let _ = read.next().await;
            // 立即回一个空 token 列表（valid key 行为）
            let response = json!({ "tokens": [], "finished": false });
            let _ = write.send(Message::Text(response.to_string().into())).await;
            // 等 client 关闭
            let _ = read.next().await;
        }
    });
    addr
}

/// 启动一个返回 close frame with auth error 的 mock（模拟 invalid key）
async fn mock_server_auth_close() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();
            let _ = read.next().await;
            use tokio_tungstenite::tungstenite::protocol::CloseFrame;
            let _ = write
                .send(Message::Close(Some(CloseFrame {
                    code:
                        tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode::Policy,
                    reason: "invalid api_key".into(),
                })))
                .await;
        }
    });
    addr
}

/// 启动一个返回 error JSON 的 mock
async fn mock_server_error_json() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();
            let _ = read.next().await;
            let err = json!({
                "error_code": 401,
                "error_type": "authentication_error",
                "error_message": "invalid API key",
                "request_id": "req-key-test"
            });
            let _ = write.send(Message::Text(err.to_string().into())).await;
        }
    });
    addr
}

/// 启动一个不响应的 mock（模拟超时 = valid 路径）
async fn mock_server_silent() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            let ws = accept_async(stream).await.unwrap();
            let (_write, mut read) = ws.split();
            let _ = read.next().await;
            // 不响应，等待客户端超时关闭
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        }
    });
    addr
}

/// 审计发现 BUG：run() 不检查 Soniox 的 error JSON，和 test_key 的行为不一致。
///
/// 证据：
/// - test_key 方法（line 166-187）检查了 response 里的 error_code / error 字段
/// - run 方法（line 350）只做 `serde_json::from_str::<SonioxRtResponse>(&text)`
///   由于 SonioxRtResponse 所有字段有 #[serde(default)]，error JSON 被解析成
///   空 response `{tokens: [], finished: false}`，错误被静默吞掉
///
/// 生产后果：Soniox rate limit、quota 超限、auth 过期等错误在 run() 里**不报错**。
/// caller 只知道"转录没产出 token"，看不到 Soniox 的实际错误信息。
#[tokio::test]
async fn test_soniox_error_json_during_run_should_not_be_swallowed() {
    // mock server: 接收配置后返回 error JSON 然后 close
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await {
            let ws = accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws.split();
            // 跳过配置消息
            let _ = read.next().await;
            // 返回 error JSON（Soniox rate limit 格式）
            let error_response = serde_json::json!({
                "error_code": 429,
                "error_type": "limit_exceeded",
                "error_message": "too many requests",
                "request_id": "req-rate-limit"
            });
            let _ = write
                .send(Message::Text(error_response.to_string().into()))
                .await;
            // 然后 close
            let _ = write.send(Message::Close(None)).await;
        }
    });

    let endpoint = format!("ws://127.0.0.1:{}", addr.port());
    let (audio_tx, audio_rx) = mpsc::channel(16);
    let (token_tx, _token_rx) = broadcast::channel(16);
    let (status_tx, _) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    // 发一个音频帧然后关闭
    audio_tx
        .send(AudioChunk {
            pcm_data: vec![0u8; 640],
            channel: AudioChannel::Microphone,
            captured_at_ns: 0,
        })
        .await
        .unwrap();
    drop(audio_tx);

    let result = SonioxRtClient::run(
        &endpoint,
        "key",
        &SttConfig::default(),
        audio_rx,
        token_tx,
        status_tx,
        cancel,
    )
    .await;

    // 期望：Soniox 返回了 error JSON，run 应该返回 Err
    // 实际（有 bug 时）：error JSON 被 serde 解析成空 SonioxRtResponse，
    // run 返回 Ok(())，caller 不知道 Soniox 报了错
    assert!(
        result.is_err(),
        "Soniox 返回 error JSON 时 run() 应返回 Err，而不是静默 Ok"
    );
}

#[tokio::test]
async fn test_test_key_empty_returns_auth_failed() {
    let result = SonioxRtClient::test_key("ws://127.0.0.1:0", "").await;
    assert!(matches!(result, Err(vt_stt::SttError::AuthFailed { .. })));
}

#[tokio::test]
async fn test_test_key_valid_response_returns_ok() {
    let addr = mock_server_valid_key().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());
    let result = SonioxRtClient::test_key(&endpoint, "any-key").await;
    assert!(result.is_ok(), "valid key should return Ok, got {result:?}");
}

#[tokio::test]
async fn test_test_key_close_with_auth_error_returns_auth_failed() {
    let addr = mock_server_auth_close().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());
    let result = SonioxRtClient::test_key(&endpoint, "bad-key").await;
    assert!(
        matches!(result, Err(vt_stt::SttError::AuthFailed { .. })),
        "close with auth error should map to AuthFailed, got {result:?}"
    );
}

#[tokio::test]
async fn test_test_key_error_json_returns_auth_failed() {
    let addr = mock_server_error_json().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());
    let result = SonioxRtClient::test_key(&endpoint, "bad-key").await;
    assert!(
        matches!(
            result,
            Err(vt_stt::SttError::AuthFailed { ref message })
                if message.contains("req-key-test")
        ),
        "error_code in JSON should map to AuthFailed, got {result:?}"
    );
}

#[tokio::test]
async fn test_test_key_silent_server_treated_as_valid() {
    // 服务器接连接但不响应 — 视为 valid（连接成功，服务在等音频）
    let addr = mock_server_silent().await;
    let endpoint = format!("ws://127.0.0.1:{}", addr.port());
    let result = SonioxRtClient::test_key(&endpoint, "key").await;
    assert!(
        result.is_ok(),
        "silent server should be treated as valid (server waiting for audio), got {result:?}"
    );
}

#[tokio::test]
async fn test_test_key_unreachable_server_returns_connection_failed() {
    // 一个肯定没人听的端口
    let result = SonioxRtClient::test_key("ws://127.0.0.1:1", "key").await;
    assert!(
        matches!(result, Err(vt_stt::SttError::ConnectionFailed(_))),
        "unreachable server should map to ConnectionFailed, got {result:?}"
    );
}
