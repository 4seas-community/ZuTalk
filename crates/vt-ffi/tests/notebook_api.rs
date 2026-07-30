use tempfile::TempDir;
use vt_ffi::ZulangueCore;

fn make_core() -> (TempDir, ZulangueCore) {
    let tmp = TempDir::new().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_str().unwrap().to_string()).unwrap();
    (tmp, core)
}

#[test]
fn create_notebook_exposes_exact_builtin_tabs_over_ffi() {
    let (_tmp, core) = make_core();

    let notebook = core.create_notebook(Some("Research".into())).unwrap();

    let notebooks = core.list_notebooks().unwrap();
    assert_eq!(notebooks.len(), 1);
    assert_eq!(notebooks[0].id, notebook.id);

    let tabs = core.list_notebook_tabs(notebook.id).unwrap();
    assert_eq!(tabs.len(), 3);
    assert_eq!(
        tabs.iter()
            .map(|tab| tab.builtin_kind.as_str())
            .collect::<Vec<_>>(),
        vec!["realtime_transcript", "async_transcript", "manual_note",]
    );
}

#[test]
fn notebook_audio_import_creates_the_only_public_session_link_path() {
    let (_tmp, core) = make_core();
    let notebook = core.create_notebook(Some("Research".into())).unwrap();
    let fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../vt-audio/tests/fixtures/test_16k_mono.wav");

    let imported = core
        .import_audio_into_notebook(fixture.to_string_lossy().into_owned(), notebook.id.clone())
        .unwrap();

    let sessions = core.list_notebook_sessions(notebook.id).unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, imported.session_id);
    let run = core
        .get_notebook_capture_session_event(imported.session_id.clone())
        .unwrap();
    assert_eq!(run.session_id, imported.session_id);
    assert_eq!(
        run.capture_state,
        vt_ffi::notebook_capture_api::FfiNotebookCaptureState::Completed
    );
}
