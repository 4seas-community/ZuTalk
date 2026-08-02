//! 验证 SessionInfo 暴露 Library UI 所需字段。
//!
//! 当前 SessionInfo 只有 id/session_type/status，
//! Library 不得不 fallback 显示 "Session abcd1234 / 00:00:00 / —".
//! 本测试验证扩展后的字段都从 SQLite + meta 真实拼装。

use std::path::PathBuf;
use tempfile::TempDir;
use vt_ffi::session_audio_api::ImportResultInfo;
use vt_ffi::ZulangueCore;

fn fixture_wav() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vt-audio/tests/fixtures/test_16k_mono.wav")
}

fn make_core() -> (TempDir, ZulangueCore) {
    let tmp = TempDir::new().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_str().unwrap().to_string()).unwrap();
    (tmp, core)
}

fn import_fixture(core: &ZulangueCore) -> ImportResultInfo {
    let notebook = core
        .create_notebook(Some("Import tests".to_string()))
        .unwrap();
    core.import_audio_into_notebook(fixture_wav().to_str().unwrap().to_string(), notebook.id)
        .unwrap()
}

#[test]
fn test_session_info_after_import_has_real_title_and_duration() {
    let (_tmp, core) = make_core();
    let fixture = fixture_wav();
    assert!(fixture.exists(), "fixture wav must exist for this test");

    let import = import_fixture(&core);

    let result = core
        .query_sessions(None, None, None, Some(50), Some(0))
        .unwrap();
    let session = result
        .sessions
        .iter()
        .find(|s| s.id == import.session_id)
        .expect("imported session must be queryable");

    assert_eq!(session.title, "test_16k_mono", "title from file_stem");
    assert_eq!(session.session_type, "import");
    assert_eq!(session.status, "imported");
    assert!(
        session.duration_ms > 0,
        "duration_ms should be parsed from wav, got {}",
        session.duration_ms
    );
    assert!(
        session.created_at_unix_ms > 0,
        "created_at_unix_ms should be > 0, got {}",
        session.created_at_unix_ms
    );
    assert!(
        session.has_encrypted_audio,
        "import_audio creates encrypted .enc file"
    );
}

#[test]
fn test_session_info_has_encrypted_audio_false_after_local_audio_destroyed() {
    let (_tmp, core) = make_core();

    let session = import_fixture(&core);
    core.destroy_session_audio_and_key(session.session_id.clone())
        .unwrap();
    let info = core.get_session(session.session_id).unwrap();

    assert!(
        !info.has_encrypted_audio,
        "destroyed local audio must not remain visible"
    );
}

#[test]
fn test_session_info_languages_are_equal_lanes_from_import_run_snapshot() {
    let (_tmp, core) = make_core();

    let session = import_fixture(&core);
    let info = core.get_session(session.session_id).unwrap();

    assert!(
        info.source_language.is_empty(),
        "a multilingual session has no configured source language"
    );
    assert_eq!(
        info.target_languages,
        ["en", "zh"],
        "every selected language is an equal output lane"
    );
}

#[test]
fn test_query_sessions_returns_full_info_for_each() {
    let (_tmp, core) = make_core();

    let s1 = import_fixture(&core);
    let s2 = import_fixture(&core);
    let result = core.query_sessions(None, None, None, None, None).unwrap();
    assert_eq!(result.total_count, 2);

    let s1_info = result
        .sessions
        .iter()
        .find(|s| s.id == s1.session_id)
        .unwrap();
    let s2_info = result
        .sessions
        .iter()
        .find(|s| s.id == s2.session_id)
        .unwrap();

    assert_eq!(s1_info.session_type, "import");
    assert_eq!(s2_info.session_type, "import");
    assert!(s2_info.source_language.is_empty());
    assert_eq!(s2_info.target_languages, ["en", "zh"]);
}

/// import_audio → query_sessions 端到端可见性。
///
/// Swift 端 importAudioFile 之后立即 loadSessions()，必须能看到刚导入的 session。
/// 这一组测试验证 SessionQueryStore.insert + query 没有事务/索引漂移。
mod p0_3_import_query_visibility {
    use super::*;

    #[test]
    fn test_import_then_query_returns_session() {
        let (_tmp, core) = make_core();
        let result = import_fixture(&core);

        let query = core
            .query_sessions(None, None, None, Some(50), Some(0))
            .unwrap();

        assert!(
            query.sessions.iter().any(|s| s.id == result.session_id),
            "imported session must be visible in next query call"
        );
        assert!(query.total_count >= 1);
    }

    #[test]
    fn test_import_then_get_session_returns_session() {
        let (_tmp, core) = make_core();
        let result = import_fixture(&core);

        // get_session 应直接返回（不再 fallback 到假数据）
        let info = core.get_session(result.session_id.clone()).unwrap();
        assert_eq!(info.id, result.session_id);
        assert_eq!(info.session_type, "import");
        assert_eq!(info.status, "imported");
        assert!(info.duration_ms > 0);
    }

    #[test]
    fn test_three_imports_all_visible() {
        let (_tmp, core) = make_core();
        let mut ids = vec![];
        for _ in 0..3 {
            let r = import_fixture(&core);
            ids.push(r.session_id);
        }

        let query = core.query_sessions(None, None, None, None, None).unwrap();
        assert_eq!(query.total_count, 3);
        for id in &ids {
            assert!(
                query.sessions.iter().any(|s| s.id == *id),
                "session {id} must be queryable"
            );
        }
    }

    #[test]
    fn test_import_visible_immediately_no_delay() {
        // 这个测试模拟 Swift 端的"导入完成→立即 loadSessions"序列
        let (_tmp, core) = make_core();

        // 导入前 query 是空的
        let before = core.query_sessions(None, None, None, None, None).unwrap();
        assert_eq!(before.total_count, 0);

        // 导入
        let r = import_fixture(&core);

        // 立即 query — 不允许任何延迟
        let after = core.query_sessions(None, None, None, None, None).unwrap();
        assert_eq!(after.total_count, 1);
        assert_eq!(after.sessions[0].id, r.session_id);
    }

    #[test]
    fn test_import_filtered_by_session_type() {
        let (_tmp, core) = make_core();
        import_fixture(&core);

        let imports = core
            .query_sessions(Some("import".to_string()), None, None, None, None)
            .unwrap();
        assert_eq!(imports.total_count, 1);

        let recordings = core
            .query_sessions(Some("recording".to_string()), None, None, None, None)
            .unwrap();
        assert_eq!(recordings.total_count, 0);
    }

    #[test]
    fn test_import_searchable_by_filename_stem() {
        let (_tmp, core) = make_core();
        import_fixture(&core);

        let results = core
            .search_sessions("test_16k_mono".to_string(), 10)
            .unwrap();
        assert_eq!(results.len(), 1);
    }
}

/// 验证 import_audio 使用文件名 stem 作为 SessionRecord.title。
mod p0_2_title_from_filename {
    use super::*;

    fn copy_fixture_to(name: &str) -> (TempDir, PathBuf) {
        let tmp = TempDir::new().unwrap();
        let dest = tmp.path().join(name);
        std::fs::copy(fixture_wav(), &dest).unwrap();
        (tmp, dest)
    }

    fn import_and_get_title(name: &str) -> String {
        let (_src_tmp, src) = copy_fixture_to(name);
        let (_core_tmp, core) = make_core();
        let notebook = core
            .create_notebook(Some("Title import".to_string()))
            .unwrap();
        let import = core
            .import_audio_into_notebook(src.to_str().unwrap().to_string(), notebook.id)
            .unwrap();
        let info = core.get_session(import.session_id).unwrap();
        info.title
    }

    #[test]
    fn test_title_from_simple_filename() {
        assert_eq!(import_and_get_title("interview.wav"), "interview");
    }

    #[test]
    fn test_title_from_filename_with_spaces() {
        assert_eq!(
            import_and_get_title("my interview 2026.wav"),
            "my interview 2026"
        );
    }

    #[test]
    fn test_title_from_filename_with_chinese() {
        assert_eq!(import_and_get_title("会议纪要.wav"), "会议纪要");
    }

    #[test]
    fn test_title_from_filename_with_multiple_dots() {
        assert_eq!(import_and_get_title("audio.v2.final.wav"), "audio.v2.final");
    }

    #[test]
    fn test_title_from_filename_with_dashes() {
        assert_eq!(
            import_and_get_title("interview-sample.wav"),
            "interview-sample"
        );
    }
}
