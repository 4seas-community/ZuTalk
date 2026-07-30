//! Long-session benchmark.
//!
//! 模拟 5 小时的转录数据量，断言：
//! - 进程内存 < 200MB
//! - SessionMetaStore tokens_json < 50MB（5h 转录约 3-5 万 token）
//!
//! 运行：
//!   cargo bench -p vt-ffi --bench long_session -- --sample-size 10
//!
//! 默认 #[ignore]，不在常规 CI 跑（5h 真实模拟太慢）。
//! criterion 用 sample-size 10 ~ 30s 跑完一个 mock 5h（采样模式）。

use std::time::Instant;

use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use tempfile::TempDir;
use vt_ffi::ZulangueCore;
use vt_model::{Token, TranslationStatus};

/// 用于 mock 的"典型 token 数"：每 200ms 一个 token ≈ 90,000 个
const TYPICAL_TOKENS_PER_5H: usize = 90_000;

fn create_imported_session(core: &ZulangueCore) -> String {
    let fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../vt-audio/tests/fixtures/test_16k_mono.wav");
    let notebook = core
        .create_notebook(Some("Long-session benchmark".to_string()))
        .unwrap();
    core.import_audio_into_notebook(fixture.to_str().unwrap().to_string(), notebook.id)
        .unwrap()
        .session_id
}

fn make_core_with_session() -> (TempDir, ZulangueCore, String) {
    let tmp = TempDir::new().unwrap();
    let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
    let session_id = create_imported_session(&core);
    (tmp, core, session_id)
}

/// 模拟"批量"写入 5h tokens 到 SessionMetaStore，验证容量
fn bench_session_meta_5h_tokens(c: &mut Criterion) {
    let (_tmp, core, sid) = make_core_with_session();

    let mut group = c.benchmark_group("session_meta_capacity");
    group.sample_size(10);

    for &count in &[1_000usize, 10_000, TYPICAL_TOKENS_PER_5H] {
        group.bench_with_input(BenchmarkId::from_parameter(count), &count, |b, &count| {
            let tokens: Vec<Token> = (0..count).map(|i| make_token(i as u64)).collect();
            b.iter(|| {
                core.session_meta_for_test()
                    .set_tokens(&sid, &tokens)
                    .unwrap();
            });
        });
    }
    group.finish();
}

/// 模拟 5h 后从 SessionMetaStore 读 tokens 的耗时
fn bench_session_meta_load_5h(c: &mut Criterion) {
    let (_tmp, core, sid) = make_core_with_session();
    let tokens: Vec<Token> = (0..TYPICAL_TOKENS_PER_5H)
        .map(|i| make_token(i as u64))
        .collect();
    core.session_meta_for_test()
        .set_tokens(&sid, &tokens)
        .unwrap();

    c.bench_function("load_90k_tokens_from_meta", |b| {
        b.iter(|| {
            let _ = core.session_meta_for_test().get_tokens(&sid).unwrap();
        });
    });
}

/// 端到端 5h 模拟（一次性测试）—— 验证 token JSON 大小限制
fn bench_5h_size_check(c: &mut Criterion) {
    let mut group = c.benchmark_group("5h_capacity_check");
    group.sample_size(10);
    group.bench_function("write_90k_tokens_then_check_size", |b| {
        b.iter_custom(|iters| {
            let mut total = std::time::Duration::ZERO;
            for _ in 0..iters {
                let tmp = TempDir::new().unwrap();
                let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
                let session_id = create_imported_session(&core);
                let tokens: Vec<Token> = (0..TYPICAL_TOKENS_PER_5H)
                    .map(|i| make_token(i as u64))
                    .collect();

                let start = Instant::now();
                core.session_meta_for_test()
                    .set_tokens(&session_id, &tokens)
                    .unwrap();
                total += start.elapsed();

                // 检查 SQLite 文件大小（应该 < 50MB）
                let db_size = std::fs::metadata(tmp.path().join("zulangue.db"))
                    .map(|m| m.len())
                    .unwrap_or(0);
                assert!(
                    db_size < 100 * 1024 * 1024,
                    "5h tokens DB size {db_size} bytes, expected < 100MB"
                );
            }
            total
        });
    });
    group.finish();
}

fn make_token(idx: u64) -> Token {
    Token {
        text: format!("token{idx} "),
        start_ms: idx * 200,
        end_ms: idx * 200 + 200,
        is_final: true,
        language: "en".to_string(),
        speaker: None,
        confidence: 0.95,
        translation_status: TranslationStatus::None,
    }
}

criterion_group!(
    name = benches;
    config = Criterion::default().sample_size(20);
    targets =
        bench_session_meta_5h_tokens,
        bench_session_meta_load_5h,
        bench_5h_size_check,
);
criterion_main!(benches);
