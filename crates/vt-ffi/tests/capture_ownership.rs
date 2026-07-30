use tempfile::TempDir;
use vt_ffi::notebook_capture_api::{
    FfiNotebookCaptureCallback, FfiNotebookCaptureEvent, FfiNotebookCaptureState,
    FfiNotebookRemoteHealth,
};
use vt_ffi::ZulangueCore;

struct NoopCaptureCallback;

impl FfiNotebookCaptureCallback for NoopCaptureCallback {
    fn on_capture_event(&self, _event: FfiNotebookCaptureEvent) {}
}

#[test]
fn default_notebook_capture_starts_without_a_soniox_key_and_stays_remote_off() {
    let tmp = TempDir::new().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_str().unwrap().to_string()).unwrap();
    let notebook = core
        .create_notebook(Some("Local-only default".into()))
        .unwrap();
    let profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .unwrap();
    assert!(!profile.remote_realtime_enabled);
    assert!(!core.has_api_key("soniox".into()));

    let capture = core
        .start_notebook_capture_session(
            notebook.id,
            profile.revision,
            None,
            Box::new(NoopCaptureCallback),
        )
        .unwrap();
    assert_eq!(capture.remote_health, FfiNotebookRemoteHealth::Off);
    assert!(!core.has_api_key("soniox".into()));
    core.stop_notebook_capture_session(capture.session_id)
        .unwrap();
}

#[test]
fn invalid_local_audio_interrupts_durably_and_releases_capture_ownership() {
    let tmp = TempDir::new().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_str().unwrap().to_string()).unwrap();
    let notebook = core
        .create_notebook(Some("Local persistence failure".into()))
        .unwrap();
    let profile = core
        .get_notebook_capture_profile(notebook.id.clone())
        .unwrap();
    let first = core
        .start_notebook_capture_session(
            notebook.id.clone(),
            profile.revision,
            None,
            Box::new(NoopCaptureCallback),
        )
        .unwrap();
    let journal_path = tmp
        .path()
        .join(format!("{}.capture-journal.enc", first.session_id));

    core.push_notebook_capture_session(first.session_id.clone(), vec![0_u8; 3_200])
        .unwrap();

    let push_error = core
        .push_notebook_capture_session(first.session_id.clone(), vec![0_u8; 1])
        .unwrap_err();
    assert!(push_error.to_string().contains("persist capture audio"));
    let interrupted = core
        .get_notebook_capture_session_event(first.session_id.clone())
        .unwrap();
    assert_eq!(
        interrupted.capture_state,
        FfiNotebookCaptureState::Interrupted
    );
    assert_eq!(
        interrupted.provider_error_type.as_deref(),
        Some("local_persistence")
    );
    assert_eq!(interrupted.post_stop_async_state, "none");
    let session = core.get_session(first.session_id.clone()).unwrap();
    assert_eq!(session.status, "interrupted");
    assert_eq!(session.duration_ms, 100);
    assert!(session.has_encrypted_audio);
    let chunks = core
        .list_audio_retention_chunks(first.session_id.clone())
        .unwrap();
    assert!(!chunks.is_empty());
    assert!(chunks.iter().all(|chunk| chunk.encrypted));
    assert_eq!(
        core.get_audio_segment(first.session_id.clone(), 0, 100)
            .unwrap()
            .len(),
        1_600 * 4,
        "the audio accepted before interruption must remain decryptable"
    );
    assert!(
        !journal_path.exists(),
        "the finalized interrupted journal must be removed only after its indexes commit"
    );
    assert!(core
        .push_notebook_capture_session(first.session_id, vec![0_u8; 2])
        .is_err());

    let second = core
        .start_notebook_capture_session(
            notebook.id,
            profile.revision,
            None,
            Box::new(NoopCaptureCallback),
        )
        .expect("failed push must release the sole active owner");
    core.stop_notebook_capture_session(second.session_id)
        .unwrap();
}
