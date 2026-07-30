use tempfile::TempDir;
use vt_store::{BuiltinNotebookTab, NotebookStore};

fn make_store() -> (TempDir, NotebookStore) {
    let tmp = TempDir::new().unwrap();
    let db = tmp.path().join("test.db");
    let store = NotebookStore::new(&db).unwrap();
    (tmp, store)
}

#[test]
fn creating_a_notebook_bootstraps_builtin_tabs() {
    let (_tmp, store) = make_store();

    let notebook = store.create_notebook(Some("Research Notebook")).unwrap();

    let tabs = store.list_tabs(&notebook.id).unwrap();
    assert_eq!(tabs.len(), 3);
    assert_eq!(
        tabs.iter()
            .map(|tab| tab.builtin_kind.clone())
            .collect::<Vec<_>>(),
        vec![
            BuiltinNotebookTab::RealtimeTranscript,
            BuiltinNotebookTab::AsyncTranscript,
            BuiltinNotebookTab::ManualNote,
        ]
    );
    assert!(tabs.iter().all(|tab| !tab.doc_id.is_empty()));
}

#[test]
fn a_session_can_only_belong_to_one_notebook() {
    let (_tmp, store) = make_store();
    let one = store.create_notebook(Some("One")).unwrap();
    let two = store.create_notebook(Some("Two")).unwrap();

    store.attach_session(&one.id, "session-a").unwrap();
    let err = store.attach_session(&two.id, "session-a").unwrap_err();

    let message = err.to_string();
    assert!(message.contains("session-a"));
    assert!(message.contains(&one.id));
}

#[test]
fn listing_notebooks_returns_recent_first() {
    let (_tmp, store) = make_store();
    let first = store.create_notebook(Some("First")).unwrap();
    let second = store.create_notebook(Some("Second")).unwrap();

    let notebooks = store.list_notebooks().unwrap();
    assert_eq!(notebooks.len(), 2);
    assert_eq!(notebooks[0].id, second.id);
    assert_eq!(notebooks[1].id, first.id);
}

#[test]
fn ensuring_session_projection_is_idempotent_per_tab_and_session() {
    let (_tmp, store) = make_store();
    let notebook = store.create_notebook(Some("Transcript")).unwrap();

    let first = store
        .ensure_session_projection(
            &notebook.id,
            BuiltinNotebookTab::RealtimeTranscript,
            "session-1",
            Some("First live pass"),
        )
        .unwrap();
    let second = store
        .ensure_session_projection(
            &notebook.id,
            BuiltinNotebookTab::RealtimeTranscript,
            "session-1",
            Some("Retitled live pass"),
        )
        .unwrap();

    assert_eq!(first.id, second.id);
    assert_eq!(second.section_title.as_deref(), Some("Retitled live pass"));

    let tabs = store.list_tabs(&notebook.id).unwrap();
    let realtime = tabs
        .iter()
        .find(|tab| tab.builtin_kind == BuiltinNotebookTab::RealtimeTranscript)
        .unwrap();
    let projections = store.list_session_projections(&realtime.id).unwrap();
    assert_eq!(projections.len(), 1);
    assert_eq!(projections[0].session_id, "session-1");
}

#[test]
fn same_session_can_project_into_realtime_and_async_tabs_separately() {
    let (_tmp, store) = make_store();
    let notebook = store.create_notebook(Some("Transcript")).unwrap();

    let realtime = store
        .ensure_session_projection(
            &notebook.id,
            BuiltinNotebookTab::RealtimeTranscript,
            "session-1",
            Some("Live"),
        )
        .unwrap();
    let async_projection = store
        .ensure_session_projection(
            &notebook.id,
            BuiltinNotebookTab::AsyncTranscript,
            "session-1",
            Some("Async"),
        )
        .unwrap();

    assert_ne!(realtime.id, async_projection.id);
    assert_eq!(realtime.session_id, async_projection.session_id);
    assert_ne!(realtime.tab_id, async_projection.tab_id);
}

#[test]
fn linked_session_can_resolve_its_notebook() {
    let (_tmp, store) = make_store();
    let notebook = store.create_notebook(Some("Transcript")).unwrap();

    store
        .attach_session(&notebook.id, "session-lookup")
        .unwrap();

    let linked = store.get_linked_notebook_id("session-lookup").unwrap();
    assert_eq!(linked.as_deref(), Some(notebook.id.as_str()));
    assert!(store.get_linked_notebook_id("missing").unwrap().is_none());
}

#[test]
fn notebook_can_list_linked_sessions_in_created_order() {
    let (_tmp, store) = make_store();
    let notebook = store.create_notebook(Some("Transcript")).unwrap();

    store.attach_session(&notebook.id, "session-1").unwrap();
    store.attach_session(&notebook.id, "session-2").unwrap();

    let sessions = store.list_linked_sessions(&notebook.id).unwrap();
    assert_eq!(sessions.len(), 2);
    assert_eq!(sessions[0].session_id, "session-1");
    assert_eq!(sessions[1].session_id, "session-2");
}
