//! API 层端到端回归测试
//!
//! 直接对 vt-ffi::ZulangueCore 的公共方法做端到端验证, 跨越所有 11 个 Rust crate
//! 真实链路 (rusqlite + Loro CRDT + aes-gcm + Soniox WebSocket + tokio runtime),
//! 不经过 SwiftUI 客户端.
//!
//! 这个文件验证显式音频导入与异步转录的真实 provider 链路。
//!
//! 运行:
//!   # 真 API (从 .env 读 SONIOX_API_KEY)
//!   cargo nextest run -p vt-ffi --test e2e_pipeline_regression --run-ignored=ignored-only

use std::path::PathBuf;
use std::time::{Duration, Instant};

use tempfile::TempDir;
use vt_ffi::ZulangueCore;

// ============================================================================
// Test helpers
// ============================================================================

/// 从仓库根 .env 加载环境变量 (复用 e2e_real_apis.rs 的模式)
fn load_env() {
    let env_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join(".env");
    let Ok(content) = std::fs::read_to_string(env_path) else {
        return;
    };
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            if std::env::var(k).is_err() {
                std::env::set_var(k, v);
            }
        }
    }
}

fn make_core() -> (TempDir, ZulangueCore) {
    let tmp = TempDir::new().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_str().unwrap().to_string()).unwrap();
    (tmp, core)
}

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("vt-audio/tests/fixtures")
        .join(name)
}

// ============================================================================
// 真 API 测试 (#[ignore], 自动从 .env 读 SONIOX_API_KEY)
// ============================================================================

/// import 音频 → 异步转录 → 权威 token 持久化完整链。
#[test]
#[ignore = "needs SONIOX_API_KEY in .env"]
fn test_e2e_real_audio_to_transcript_via_async_task() {
    load_env();
    let soniox_key = std::env::var("SONIOX_API_KEY").expect("SONIOX_API_KEY required in .env");

    let (_tmp, core) = make_core();

    // Step 1: import the synthetic speech fixture.
    let fixture = fixture_path("test_speech_16k_mono.wav");
    assert!(fixture.exists(), "speech fixture missing");
    let notebook = core
        .create_notebook(Some("E2E import".to_string()))
        .unwrap();
    core.set_api_key("soniox".to_string(), soniox_key).unwrap();
    let import = core
        .import_audio_into_notebook(fixture.to_str().unwrap().to_string(), notebook.id)
        .unwrap();
    eprintln!(
        "[Step 1] Imported: session={} duration={}ms",
        import.session_id, import.duration_ms
    );

    // Step 2: the explicit Transcribe command creates exactly one deterministic
    // durable task receipt. Import alone never uploads audio.
    core.request_notebook_async_transcription(import.session_id.clone())
        .unwrap();
    let tasks = core.list_tasks(None).unwrap();
    assert_eq!(
        tasks.len(),
        1,
        "Notebook import must enqueue exactly one task"
    );
    let task_id = tasks[0].id.clone();
    eprintln!("[Step 2] Task submitted: {task_id}");

    // Step 3: poll the durable task state (90s 给 Soniox 充分余量)
    let started = Instant::now();
    loop {
        let task = core.get_task_status(task_id.clone()).unwrap();
        if task.status == "completed" {
            break;
        }
        assert_ne!(
            task.status, "failed",
            "Notebook async transcription failed: {:?}",
            task.error_msg
        );
        assert!(
            started.elapsed() < Duration::from_secs(90),
            "Notebook async transcription did not complete within 90s"
        );
        std::thread::sleep(Duration::from_millis(100));
    }

    // Step 4: read the authoritative durable token source used by projection.
    let tokens = core
        .session_meta_for_test()
        .get_tokens(&import.session_id)
        .unwrap();
    eprintln!("[Step 4] Persisted tokens: {}", tokens.len());
    for (i, token) in tokens.iter().enumerate() {
        eprintln!("  [{i}] {}", token.text);
    }

    // Step 5: 必须有内容
    assert!(
        !tokens.is_empty(),
        "transcription should persist tokens from real audio"
    );

    let full_text: String = tokens
        .iter()
        .map(|token| token.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    eprintln!("[Step 5] Full text: {full_text}");
    assert!(
        full_text.len() > 10,
        "transcript too short ({}): '{full_text}'",
        full_text.len()
    );

    // Step 6: 防止示例标记进入权威持久化。
    let lower = full_text.to_lowercase();
    assert!(
        !lower.contains("demo_data") && !lower.contains("fake_data"),
        "example marker leaked into real transcript: '{full_text}'"
    );

    // Step 7: 至少含一个真音频里实际有的英文单词
    let has_keyword = [
        "hello",
        "test",
        "voice",
        "transcription",
        "world",
        "the",
        "is",
        "a",
    ]
    .iter()
    .any(|w| lower.contains(w));
    assert!(
        has_keyword,
        "transcript should contain expected English words, got: '{full_text}'"
    );

    // Step 8: token 字段完整性
    for token in &tokens {
        assert!(token.start_ms <= token.end_ms, "start_ms must be <= end_ms");
        assert!(!token.text.is_empty(), "token text should not be empty");
    }
}
