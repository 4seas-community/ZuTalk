use vt_crypto::{project_trust_warning, TrustKeyState, TrustSurface, TrustWarningInput};

fn input(key_state: TrustKeyState) -> TrustWarningInput {
    TrustWarningInput {
        surface: TrustSurface::Status,
        key_state,
        provider_display_name: Some("Soniox".to_string()),
        key_scope: Some("soniox".to_string()),
        content_label: Some("Notebook audio".to_string()),
        diagnostic_hint: Some("key_scope=soniox".to_string()),
    }
}

#[test]
fn p0_trust_key_states_map_to_user_actions() {
    let ready = project_trust_warning(input(TrustKeyState::ContentKeyAvailable)).unwrap();
    assert_eq!(ready.severity, "info");
    assert_eq!(ready.state, "content_key_available");
    assert!(!ready.is_actionable);
    assert!(ready.user_actions.is_empty());

    let missing = project_trust_warning(input(TrustKeyState::ProviderApiKeyMissing)).unwrap();
    assert_eq!(missing.severity, "blocked");
    assert!(missing.is_actionable);
    assert_eq!(
        missing
            .user_actions
            .iter()
            .map(|action| action.action_id.as_str())
            .collect::<Vec<_>>(),
        vec!["add_api_key", "open_provider_settings"]
    );
    assert!(!missing.message.contains("soniox"));
    assert!(missing
        .diagnostic_summary
        .as_deref()
        .unwrap_or_default()
        .contains("key_scope=soniox"));

    let untested = project_trust_warning(input(TrustKeyState::ProviderApiKeyUntested)).unwrap();
    assert_eq!(untested.severity, "warning");
    assert_eq!(
        untested
            .user_actions
            .iter()
            .map(|action| action.action_id.as_str())
            .collect::<Vec<_>>(),
        vec!["test_api_key", "open_provider_settings"]
    );

    let missing_content_key =
        project_trust_warning(input(TrustKeyState::ContentKeyMissing)).unwrap();
    assert_eq!(missing_content_key.severity, "blocked");
    assert_eq!(
        missing_content_key
            .user_actions
            .iter()
            .map(|action| action.action_id.as_str())
            .collect::<Vec<_>>(),
        vec!["restore_content_key", "open_diagnostics"]
    );
}
