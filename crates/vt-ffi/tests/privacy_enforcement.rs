//! 验证隐私等级执行效果。
//!
//! 验证：
//! - set_privacy_default / get_privacy_default round-trip
//! - import 时把当前默认等级写到 session
//! - apply_privacy_after_transcription 在 high/maximum 下真的删物理音频 chunk
//! - destroy_session_audio 手动触发销毁
//! - destroy_session_audio_and_key 同时销毁 key

use std::path::PathBuf;
use tempfile::TempDir;
use vt_ffi::ZulangueCore;

fn fixture_wav() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vt-audio/tests/fixtures/test_16k_mono.wav")
}

fn make_core() -> (TempDir, ZulangueCore) {
    let tmp = TempDir::new().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_str().unwrap().to_string()).unwrap();
    (tmp, core)
}

fn import_fixture(core: &ZulangueCore) -> vt_ffi::session_audio_api::ImportResultInfo {
    let notebook = core
        .create_notebook(Some("Privacy tests".to_string()))
        .unwrap();
    core.import_audio_into_notebook(fixture_wav().to_str().unwrap().to_string(), notebook.id)
        .unwrap()
}

fn import_fixture_with_privacy(
    core: &ZulangueCore,
    privacy_level: &str,
) -> vt_ffi::session_audio_api::ImportResultInfo {
    let notebook = core
        .create_notebook(Some("Privacy tests".to_string()))
        .unwrap();
    let mut profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .unwrap();
    profile.privacy_level = privacy_level.to_string();
    core.update_notebook_capture_profile(profile).unwrap();
    core.import_audio_into_notebook(fixture_wav().to_str().unwrap().to_string(), notebook.id)
        .unwrap()
}

fn retained_chunk_paths(core: &ZulangueCore, session_id: &str) -> Vec<PathBuf> {
    let chunks = core
        .list_audio_retention_chunks(session_id.to_string())
        .unwrap();
    assert!(
        !chunks.is_empty(),
        "session should have physical audio chunks"
    );
    chunks
        .into_iter()
        .filter(|chunk| chunk.encrypted)
        .map(|chunk| PathBuf::from(chunk.local_path))
        .collect()
}

fn assert_chunk_files_exist(paths: &[PathBuf]) {
    assert!(
        !paths.is_empty(),
        "expected at least one retained audio chunk"
    );
    for path in paths {
        assert!(
            path.exists(),
            "expected encrypted audio chunk to exist: {}",
            path.display()
        );
    }
}

fn assert_chunk_files_deleted(paths: &[PathBuf]) {
    for path in paths {
        assert!(
            !path.exists(),
            "expected encrypted audio chunk to be deleted: {}",
            path.display()
        );
    }
}

fn assert_current_audio_ownership(core: &ZulangueCore, session_id: &str) -> String {
    let run = core
        .get_notebook_capture_session_event(session_id.to_string())
        .expect("Notebook import must have a current capture run");
    assert_eq!(run.session_id, session_id);
    let ledger = core
        .list_audio_retention_chunks(session_id.to_string())
        .expect("current audio ledger");
    assert!(ledger.iter().any(|chunk| chunk.encrypted && !chunk.deleted));
    let key_ref = core
        .session_meta_for_test()
        .get_meta(session_id)
        .expect("current session audio metadata")
        .key_id
        .expect("current opaque audio key reference");
    assert!(core.key_exists_for_test(&key_ref));
    key_ref
}

#[test]
fn test_privacy_default_starts_as_standard() {
    let (_tmp, core) = make_core();
    assert_eq!(core.get_privacy_default(), "standard");
}

#[test]
fn test_set_privacy_default_roundtrip() {
    let (_tmp, core) = make_core();
    core.set_privacy_default("high".to_string()).unwrap();
    assert_eq!(core.get_privacy_default(), "high");

    core.set_privacy_default("maximum".to_string()).unwrap();
    assert_eq!(core.get_privacy_default(), "maximum");

    core.set_privacy_default("standard".to_string()).unwrap();
    assert_eq!(core.get_privacy_default(), "standard");
}

#[test]
fn test_set_privacy_default_invalid_fails() {
    let (_tmp, core) = make_core();
    let result = core.set_privacy_default("ultra".to_string());
    assert!(result.is_err());
    // 默认值不应被覆盖
    assert_eq!(core.get_privacy_default(), "standard");
}

#[test]
fn test_import_carries_current_privacy_level() {
    let (tmp, core) = make_core();
    let r = import_fixture_with_privacy(&core, "high");

    let chunk_paths = retained_chunk_paths(&core, &r.session_id);
    assert_chunk_files_exist(&chunk_paths);
    let legacy_enc = tmp.path().join(format!("{}.enc", r.session_id));
    assert!(
        !legacy_enc.exists(),
        "import should not create legacy full-session .enc"
    );

    // The Notebook profile, not the legacy global default, freezes retention.
    let meta = core
        .session_meta_for_test()
        .get_meta(&r.session_id)
        .unwrap();
    assert_eq!(meta.privacy_level.as_deref(), Some("high"));
    let info = core.get_session(r.session_id.clone()).unwrap();
    assert!(info.has_encrypted_audio);
}

#[test]
fn test_destroy_session_audio_removes_chunk_files() {
    let (_tmp, core) = make_core();
    let r = import_fixture(&core);

    let chunk_paths = retained_chunk_paths(&core, &r.session_id);
    assert_chunk_files_exist(&chunk_paths);

    core.destroy_session_audio(r.session_id.clone()).unwrap();

    assert_chunk_files_deleted(&chunk_paths);
    let chunks = core
        .list_audio_retention_chunks(r.session_id.clone())
        .unwrap();
    assert!(chunks.iter().all(|chunk| chunk.deleted));

    let info = core.get_session(r.session_id).unwrap();
    assert!(
        !info.has_encrypted_audio,
        "session_info should reflect destroyed audio"
    );
}

#[test]
fn test_destroy_session_audio_idempotent() {
    let (_tmp, core) = make_core();
    let r = import_fixture(&core);

    core.destroy_session_audio(r.session_id.clone()).unwrap();
    // 第二次调用不应失败
    core.destroy_session_audio(r.session_id).unwrap();
}

#[test]
fn test_destroy_unknown_session_returns_not_found() {
    let (_tmp, core) = make_core();
    let result = core.destroy_session_audio("never-existed".to_string());
    assert!(result.is_err());
}

#[test]
fn test_destroy_session_audio_and_key_removes_both() {
    // 这个测试用 maximum 级别，并验证 key 也被删了
    let (_tmp, core) = make_core();
    let r = import_fixture(&core);

    let chunk_paths = retained_chunk_paths(&core, &r.session_id);
    assert_chunk_files_exist(&chunk_paths);
    let key_ref = assert_current_audio_ownership(&core, &r.session_id);

    core.destroy_session_audio_and_key(r.session_id.clone())
        .unwrap();

    assert_chunk_files_deleted(&chunk_paths);
    assert!(!core.key_exists_for_test(&key_ref));
    let ledger = core
        .list_audio_retention_chunks(r.session_id.clone())
        .unwrap();
    assert!(ledger.iter().all(|chunk| chunk.deleted));
    let meta = core
        .session_meta_for_test()
        .get_meta(&r.session_id)
        .unwrap();
    assert!(meta.encrypted_path.is_none());
    assert!(meta.key_id.is_none());
    let error = core.get_audio_segment(r.session_id, 0, 1000).unwrap_err();
    assert!(
        error.to_string().contains("session audio not found"),
        "destroyed audio must be explicitly unavailable, got: {error}"
    );
}

#[test]
fn test_audio_retention_worker_deletes_due_chunk_and_preserves_transcript() {
    use vt_model::{Token, TranslationStatus};

    let (tmp, core) = make_core();
    let sid = "s-retention-worker";
    let audio_path = tmp.path().join("chunk-0.enc");
    std::fs::write(&audio_path, vec![7_u8; 64]).unwrap();
    core.session_meta_for_test()
        .set_encrypted_path(sid, audio_path.to_str().unwrap(), "key-retention")
        .unwrap();
    core.session_meta_for_test()
        .set_tokens(
            sid,
            &[Token {
                text: "transcript survives".to_string(),
                start_ms: 0,
                end_ms: 1_000,
                is_final: true,
                language: "en".to_string(),
                speaker: None,
                confidence: 1.0,
                translation_status: TranslationStatus::None,
            }],
        )
        .unwrap();
    core.record_audio_retention_chunk(
        sid.to_string(),
        "s-retention-worker:audio:00000".to_string(),
        0,
        60_000,
        audio_path.to_str().unwrap().to_string(),
        true,
        10,
    )
    .unwrap();

    let result = core.run_audio_retention_once(11).unwrap();

    assert_eq!(result.scanned_count, 1);
    assert_eq!(result.deleted_count, 1);
    assert_eq!(result.failed_count, 0);
    assert!(!audio_path.exists());
    let chunks = core.list_audio_retention_chunks(sid.to_string()).unwrap();
    assert_eq!(chunks.len(), 1);
    assert!(chunks[0].deleted);
    assert!(chunks[0].delete_error.is_none());
    let tokens = core.session_meta_for_test().get_tokens(sid).unwrap();
    assert_eq!(tokens[0].text, "transcript survives");
    let status = core
        .get_transcription_source_status(sid.to_string())
        .unwrap();
    assert_eq!(status.state, "audio_deleted_after_transcript");
}

#[test]
fn test_audio_retention_delete_failure_is_observable() {
    let (tmp, core) = make_core();
    let sid = "s-retention-failure";
    let chunk_dir = tmp.path().join("chunk-dir.enc");
    std::fs::create_dir(&chunk_dir).unwrap();
    core.session_meta_for_test()
        .set_encrypted_path(sid, chunk_dir.to_str().unwrap(), "key-retention")
        .unwrap();
    core.record_audio_retention_chunk(
        sid.to_string(),
        "s-retention-failure:audio:00000".to_string(),
        0,
        60_000,
        chunk_dir.to_str().unwrap().to_string(),
        true,
        10,
    )
    .unwrap();

    let result = core.run_audio_retention_once(11).unwrap();

    assert_eq!(result.scanned_count, 1);
    assert_eq!(result.deleted_count, 0);
    assert_eq!(result.failed_count, 1);
    assert_eq!(result.failure_messages.len(), 1);
    let chunks = core.list_audio_retention_chunks(sid.to_string()).unwrap();
    assert!(!chunks[0].deleted);
    assert!(chunks[0]
        .delete_error
        .as_deref()
        .unwrap_or("")
        .contains("file destroy failed"));
    let status = core
        .get_transcription_source_status(sid.to_string())
        .unwrap();
    assert_eq!(status.state, "delete_failed");
}

/// 直接测试 enforcement helper（绕过真实 transcribe）
#[test]
fn test_high_privacy_destroys_audio_after_transcribe_simulation() {
    let (_tmp, core) = make_core();
    core.set_privacy_default("high".to_string()).unwrap();

    let r = import_fixture(&core);
    let chunk_paths = retained_chunk_paths(&core, &r.session_id);
    assert_chunk_files_exist(&chunk_paths);

    // 手动触发销毁（模拟 transcribe 完成）
    core.destroy_session_audio(r.session_id.clone()).unwrap();
    assert_chunk_files_deleted(&chunk_paths);
}

#[test]
fn test_apply_privacy_high_after_transcription_removes_chunks() {
    let (_tmp, core) = make_core();
    let r = import_fixture_with_privacy(&core, "high");
    let chunk_paths = retained_chunk_paths(&core, &r.session_id);
    assert_chunk_files_exist(&chunk_paths);

    // 模拟转录完成
    core.apply_privacy_after_transcription(&r.session_id)
        .unwrap();

    assert_chunk_files_deleted(&chunk_paths);

    let info = core.get_session(r.session_id).unwrap();
    assert!(!info.has_encrypted_audio);
}

#[test]
fn test_apply_privacy_standard_keeps_everything() {
    let (tmp, core) = make_core();
    core.set_privacy_default("standard".to_string()).unwrap();

    let r = import_fixture(&core);
    let chunk_paths = retained_chunk_paths(&core, &r.session_id);

    core.apply_privacy_after_transcription(&r.session_id)
        .unwrap();

    assert_chunk_files_exist(&chunk_paths);
    let legacy_enc = tmp.path().join(format!("{}.enc", r.session_id));
    assert!(
        !legacy_enc.exists(),
        "standard should not create legacy .enc"
    );
    let info = core.get_session(r.session_id).unwrap();
    assert!(info.has_encrypted_audio);
}

#[test]
fn test_apply_privacy_maximum_removes_chunks_and_key() {
    let (_tmp, core) = make_core();
    let r = import_fixture_with_privacy(&core, "maximum");
    let chunk_paths = retained_chunk_paths(&core, &r.session_id);
    assert_chunk_files_exist(&chunk_paths);
    let key_ref = assert_current_audio_ownership(&core, &r.session_id);

    core.apply_privacy_after_transcription(&r.session_id)
        .unwrap();

    assert_chunk_files_deleted(&chunk_paths);
    assert!(!core.key_exists_for_test(&key_ref));
    let ledger = core
        .list_audio_retention_chunks(r.session_id.clone())
        .unwrap();
    assert!(ledger.iter().all(|chunk| chunk.deleted));
    let error = core.get_audio_segment(r.session_id, 0, 1000).unwrap_err();
    assert!(error.to_string().contains("session audio not found"));
}

#[test]
fn test_standard_privacy_allows_manual_chunk_destroy() {
    // standard 等级下，destroy_session_audio 仍然会删（因为是用户手动触发）
    let (_tmp, core) = make_core();
    core.set_privacy_default("standard".to_string()).unwrap();

    let r = import_fixture(&core);
    let chunk_paths = retained_chunk_paths(&core, &r.session_id);
    assert_chunk_files_exist(&chunk_paths);

    // 手动 destroy 仍然有效
    core.destroy_session_audio(r.session_id).unwrap();
    assert_chunk_files_deleted(&chunk_paths);
}
