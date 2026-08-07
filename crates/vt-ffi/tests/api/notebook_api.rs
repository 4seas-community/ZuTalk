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

    let sessions = core.list_notebook_sessions(notebook.id.clone()).unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, imported.session_id);
    let tabs = core.list_notebook_tabs(notebook.id.clone()).unwrap();
    for tab in tabs {
        let projections = core.list_notebook_session_projections(tab.id).unwrap();
        assert_eq!(projections.len(), 1);
        assert_eq!(projections[0].session_id, imported.session_id);
    }
    let run = core
        .get_notebook_capture_session_event(imported.session_id.clone())
        .unwrap();
    assert_eq!(run.session_id, imported.session_id);
    assert_eq!(
        run.capture_state,
        vt_ffi::notebook_capture_api::FfiNotebookCaptureState::Completed
    );
}

#[test]
fn renaming_manual_note_only_changes_its_optional_title() {
    let (_tmp, core) = make_core();
    let notebook = core.create_notebook(Some("Research".into())).unwrap();
    let fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../vt-audio/tests/fixtures/test_16k_mono.wav");
    let imported = core
        .import_audio_into_notebook(fixture.to_string_lossy().into_owned(), notebook.id.clone())
        .unwrap();

    let named = core
        .rename_notebook_manual_note(
            notebook.id.clone(),
            imported.session_id.clone(),
            Some("Interview notes".into()),
        )
        .unwrap();
    assert_eq!(named.section_title.as_deref(), Some("Interview notes"));

    let cleared = core
        .rename_notebook_manual_note(notebook.id, imported.session_id, Some("   ".into()))
        .unwrap();
    assert_eq!(cleared.section_title, None);
    assert_eq!(cleared.id, named.id);
    assert_eq!(cleared.created_at, named.created_at);
}

/// Imports the shared fixture into `notebook_id` and returns the session id.
fn import_session(core: &ZulangueCore, notebook_id: &str) -> String {
    let fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../vt-audio/tests/fixtures/test_16k_mono.wav");
    core.import_audio_into_notebook(
        fixture.to_string_lossy().into_owned(),
        notebook_id.to_string(),
    )
    .unwrap()
    .session_id
}

fn manual_note_tab(core: &ZulangueCore, notebook_id: &str) -> String {
    core.list_notebook_tabs(notebook_id.to_string())
        .unwrap()
        .into_iter()
        .find(|tab| tab.builtin_kind.as_str() == "manual_note")
        .expect("every notebook has a manual note tab")
        .id
}

fn session_ids_in(core: &ZulangueCore, notebook_id: &str) -> Vec<String> {
    let mut ids: Vec<String> = core
        .list_notebook_sessions(notebook_id.to_string())
        .unwrap()
        .into_iter()
        .map(|link| link.session_id)
        .collect();
    ids.sort();
    ids
}

#[test]
fn moving_a_session_relinks_it_and_rebuilds_every_tab_projection_in_the_target() {
    let (_tmp, core) = make_core();
    let source = core.create_notebook(Some("Source".into())).unwrap();
    let target = core.create_notebook(Some("Target".into())).unwrap();
    let session_id = import_session(&core, &source.id);

    core.move_session_to_notebook(session_id.clone(), target.id.clone())
        .unwrap();

    assert!(session_ids_in(&core, &source.id).is_empty());
    assert_eq!(session_ids_in(&core, &target.id), vec![session_id.clone()]);
    for tab in core.list_notebook_tabs(source.id.clone()).unwrap() {
        assert!(
            core.list_notebook_session_projections(tab.id)
                .unwrap()
                .is_empty(),
            "the source notebook keeps no section for a moved session"
        );
    }
    for tab in core.list_notebook_tabs(target.id.clone()).unwrap() {
        let projections = core.list_notebook_session_projections(tab.id).unwrap();
        assert_eq!(projections.len(), 1);
        assert_eq!(projections[0].session_id, session_id);
    }
    // The recording itself is untouched: audio lives in audio/<session_id>/,
    // which no notebook owns.
    let run = core
        .get_notebook_capture_session_event(session_id.clone())
        .unwrap();
    assert_eq!(run.session_id, session_id);
}

/// Writes a note into `tab_id` marked as owned by `session_id` — what the app
/// does when the user types into that session's section of the note tab.
fn write_owned_note(
    core: &ZulangueCore,
    notebook_id: &str,
    tab_id: &str,
    session_id: &str,
    text: &str,
) {
    core.open_editor(notebook_id.to_string(), tab_id.to_string())
        .unwrap();
    let pos = core
        .get_editor_content(notebook_id.to_string(), tab_id.to_string())
        .unwrap()
        .chars()
        .count();
    core.apply_edit(
        notebook_id.to_string(),
        tab_id.to_string(),
        vt_ffi::editor_api::FfiEditOp::Insert {
            pos: pos as u64,
            text: text.to_string(),
        },
    )
    .unwrap();
    core.apply_edit(
        notebook_id.to_string(),
        tab_id.to_string(),
        vt_ffi::editor_api::FfiEditOp::Mark {
            pos: pos as u64,
            len: text.chars().count() as u64,
            key: "session_id".to_string(),
            value_json: format!("\"{session_id}\""),
        },
    )
    .unwrap();
}

#[test]
fn a_moved_note_arrives_in_the_target_and_leaves_the_source() {
    let (_tmp, core) = make_core();
    let source = core.create_notebook(Some("Source".into())).unwrap();
    let target = core.create_notebook(Some("Target".into())).unwrap();
    let session_id = import_session(&core, &source.id);
    let source_note_tab = manual_note_tab(&core, &source.id);
    let target_note_tab = manual_note_tab(&core, &target.id);
    write_owned_note(
        &core,
        &source.id,
        &source_note_tab,
        &session_id,
        "本次会议的手写笔记",
    );

    core.move_session_to_notebook(session_id.clone(), target.id.clone())
        .unwrap();

    core.open_editor(target.id.clone(), target_note_tab.clone())
        .unwrap();
    let arrived = core
        .get_editor_content(target.id.clone(), target_note_tab.clone())
        .unwrap();
    assert_eq!(
        arrived, "本次会议的手写笔记",
        "the user's note must travel with its session"
    );
    let arrived_delta = core
        .get_editor_delta(target.id.clone(), target_note_tab)
        .unwrap();
    assert!(
        arrived_delta.contains(&session_id),
        "the note must arrive still owned by its session: {arrived_delta}"
    );
    assert_eq!(
        core.get_editor_content(source.id.clone(), source_note_tab)
            .unwrap(),
        "",
        "nothing may stay behind in the source notebook"
    );
}

#[test]
fn a_moved_note_lands_between_the_target_notes_by_recording_time() {
    let (_tmp, core) = make_core();
    let source = core.create_notebook(Some("Source".into())).unwrap();
    let target = core.create_notebook(Some("Target".into())).unwrap();
    // The target already holds a note; the moved session was imported after it,
    // so its note belongs after that one.
    let earlier = import_session(&core, &target.id);
    let moved = import_session(&core, &source.id);
    let target_tab = manual_note_tab(&core, &target.id);
    let source_tab = manual_note_tab(&core, &source.id);
    write_owned_note(&core, &target.id, &target_tab, &earlier, "先开的会");
    write_owned_note(&core, &source.id, &source_tab, &moved, "后开的会");

    core.move_session_to_notebook(moved.clone(), target.id.clone())
        .unwrap();

    let combined = core
        .get_editor_content(target.id.clone(), target_tab)
        .unwrap();
    assert_eq!(
        combined, "先开的会后开的会",
        "sections must read in the order the meetings happened"
    );
}

#[test]
fn a_session_cannot_move_into_the_notebook_it_already_belongs_to() {
    let (_tmp, core) = make_core();
    let notebook = core.create_notebook(Some("Only".into())).unwrap();
    let session_id = import_session(&core, &notebook.id);

    assert!(core
        .move_session_to_notebook(session_id, notebook.id)
        .is_err());
}

#[test]
fn moving_a_session_twice_lands_it_in_the_last_notebook_only() {
    let (_tmp, core) = make_core();
    let first = core.create_notebook(Some("First".into())).unwrap();
    let second = core.create_notebook(Some("Second".into())).unwrap();
    let third = core.create_notebook(Some("Third".into())).unwrap();
    let session_id = import_session(&core, &first.id);

    core.move_session_to_notebook(session_id.clone(), second.id.clone())
        .unwrap();
    core.move_session_to_notebook(session_id.clone(), third.id.clone())
        .unwrap();

    assert!(session_ids_in(&core, &first.id).is_empty());
    assert!(session_ids_in(&core, &second.id).is_empty());
    assert_eq!(session_ids_in(&core, &third.id), vec![session_id]);
}

#[test]
fn a_moved_session_survives_a_core_restart_in_its_new_notebook() {
    let tmp = TempDir::new().unwrap();
    let data_dir = tmp.path().to_str().unwrap().to_string();
    let (session_id, target_id) = {
        let core = ZulangueCore::new_for_test(data_dir.clone()).unwrap();
        let source = core.create_notebook(Some("Source".into())).unwrap();
        let target = core.create_notebook(Some("Target".into())).unwrap();
        let session_id = import_session(&core, &source.id);
        core.move_session_to_notebook(session_id.clone(), target.id.clone())
            .unwrap();
        core.shutdown().unwrap();
        (session_id, target.id)
    };

    let reopened = ZulangueCore::new_for_test(data_dir).unwrap();

    assert_eq!(session_ids_in(&reopened, &target_id), vec![session_id]);
}

#[test]
fn a_refused_move_leaves_nothing_of_the_session_in_the_target() {
    let (tmp, core) = make_core();
    let source = core.create_notebook(Some("Source".into())).unwrap();
    let target = core.create_notebook(Some("Target".into())).unwrap();
    let session_id = import_session(&core, &source.id);
    let source_tab = manual_note_tab(&core, &source.id);
    let target_tab = manual_note_tab(&core, &target.id);
    write_owned_note(&core, &source.id, &source_tab, &session_id, "会议笔记");

    // A capture claims the session after the plan is built but before the
    // pointer flip, which is exactly what commit_session_move refuses.
    let connection = rusqlite::Connection::open(tmp.path().join("zulangue.db")).unwrap();
    connection
        .execute_batch(
            "CREATE TRIGGER refuse_session_relink
             BEFORE UPDATE OF notebook_id ON notebook_sessions
             BEGIN
               SELECT RAISE(ABORT, 'injected relink failure');
             END;",
        )
        .unwrap();

    let error = core
        .move_session_to_notebook(session_id.clone(), target.id.clone())
        .unwrap_err();

    assert!(error.to_string().contains("injected relink failure"));
    core.open_editor(target.id.clone(), target_tab.clone())
        .unwrap();
    assert_eq!(
        core.get_editor_content(target.id.clone(), target_tab)
            .unwrap(),
        "",
        "a refused move must not leave a copied section in the target"
    );
    assert_eq!(
        core.get_editor_content(source.id.clone(), source_tab)
            .unwrap(),
        "会议笔记",
        "the source notebook keeps the whole record"
    );
    assert_eq!(session_ids_in(&core, &source.id), vec![session_id]);
    assert!(session_ids_in(&core, &target.id).is_empty());
}
