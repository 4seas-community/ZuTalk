//! Soniox 真实人声转录测试
//!
//! 用 macOS `say` 生成的英文人声 WAV，验证 Soniox 真的能转录出文字。

use std::time::Duration;

use tokio::sync::{broadcast, mpsc, watch};
use tokio_util::sync::CancellationToken;
use vt_model::{AudioChannel, AudioChunk};
use vt_stt::{ConnectionStatus, SonioxRtClient, SttConfig};

fn load_env_key() -> Option<String> {
    if let Ok(k) = std::env::var("SONIOX_API_KEY") {
        return Some(k);
    }
    let env_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join(".env");
    let content = std::fs::read_to_string(env_path).ok()?;
    for line in content.lines() {
        if let Some(k) = line.strip_prefix("SONIOX_API_KEY=") {
            return Some(k.trim().to_string());
        }
    }
    None
}

fn read_wav_pcm(path: &std::path::Path) -> Vec<u8> {
    // 读 WAV 文件，跳过 44 字节标准头部，返回 PCM s16le 数据
    let bytes = std::fs::read(path).expect("read wav");
    bytes[44..].to_vec()
}

#[tokio::test]
#[ignore = "requires real Soniox API key"]
async fn test_soniox_transcribes_real_speech() {
    let api_key = match load_env_key() {
        Some(k) => k,
        None => {
            eprintln!("SONIOX_API_KEY not set");
            return;
        }
    };

    let fixture_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("vt-audio/tests/fixtures/test_speech_16k_mono.wav");

    if !fixture_path.exists() {
        eprintln!("speech fixture missing: {}", fixture_path.display());
        return;
    }

    let pcm_data = read_wav_pcm(&fixture_path);
    println!(
        "PCM data: {} bytes (~{:.1}s)",
        pcm_data.len(),
        pcm_data.len() as f64 / 32000.0
    );

    let endpoint = "wss://stt-rt.soniox.com/transcribe-websocket";
    let (audio_tx, audio_rx) = mpsc::channel::<AudioChunk>(64);
    let (token_tx, mut token_rx) = broadcast::channel(256);
    let (status_tx, _status_rx) = watch::channel(ConnectionStatus::Reconnecting { attempt: 0 });
    let cancel = CancellationToken::new();

    let config = SttConfig {
        language_hints: vec!["en".to_string()],
        ..Default::default()
    };

    // Spawn 客户端
    let client_handle = {
        let api_key = api_key.clone();
        let config = config.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move {
            SonioxRtClient::run(
                endpoint, &api_key, &config, audio_rx, token_tx, status_tx, cancel,
            )
            .await
        })
    };

    // 分块发送音频（每块 100ms = 3200 bytes）
    let chunk_size = 3200;
    for chunk in pcm_data.chunks(chunk_size) {
        let audio_chunk = AudioChunk {
            pcm_data: chunk.to_vec(),
            channel: AudioChannel::Microphone,
            captured_at_ns: 0,
        };
        if audio_tx.send(audio_chunk).await.is_err() {
            break;
        }
        // 模拟实时（100ms 音频间隔 50ms 发送，更快但仍合理）
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    // 关闭音频通道，触发 finalize
    drop(audio_tx);

    // 收集 token，最多等 15 秒
    let mut tokens = Vec::new();
    let collect_deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let remaining = collect_deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining.min(Duration::from_secs(2)), token_rx.recv()).await {
            Ok(Ok(token)) => {
                println!(
                    "  token: '{}' ({}ms-{}ms, final={})",
                    token.text, token.start_ms, token.end_ms, token.is_final
                );
                tokens.push(token);
            }
            Ok(Err(_)) => break, // channel closed
            Err(_) => continue,  // timeout, keep waiting
        }
    }

    cancel.cancel();
    let _ = client_handle.await;

    // 拼接所有 token（包括 interim — Soniox 的 final 标记需要 segment 结束）
    let all_text: String = tokens.iter().map(|t| t.text.as_str()).collect();
    let final_only: String = tokens
        .iter()
        .filter(|t| t.is_final)
        .map(|t| t.text.as_str())
        .collect();

    println!("\n=== All tokens ===\n{all_text}");
    println!("\n=== Final-only ===\n{final_only}");
    println!(
        "Total: {}, final: {}",
        tokens.len(),
        tokens.iter().filter(|t| t.is_final).count()
    );

    assert!(!tokens.is_empty(), "should receive tokens from real speech");

    // 验证转录包含预期的关键词（用全量 token，包括 interim）
    let lower = all_text.to_lowercase();
    let expected_words = [
        "hello",
        "test",
        "voice",
        "transcription",
        "notebook",
        "audio",
        "english",
    ];
    let found: Vec<&str> = expected_words
        .iter()
        .filter(|w| lower.contains(*w))
        .copied()
        .collect();
    assert!(
        !found.is_empty(),
        "transcript should contain at least one expected word, got: {all_text}"
    );
    println!("Found keywords: {found:?}");
}
