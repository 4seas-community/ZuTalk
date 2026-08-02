use vt_ffi::trust_warning_api::{FfiTrustKeyState, FfiTrustSurface, FfiTrustWarningInput};
use vt_ffi::ZulangueCore;

fn input(key_state: FfiTrustKeyState) -> FfiTrustWarningInput {
    FfiTrustWarningInput {
        surface: FfiTrustSurface::Status,
        key_state,
        provider_display_name: Some("Soniox".to_string()),
        key_scope: Some("soniox".to_string()),
        content_label: Some("Notebook audio".to_string()),
        diagnostic_hint: Some("key_scope=soniox".to_string()),
    }
}

#[test]
fn p0_trust_warning_dto_distinguishes_info_warning_blocked() {
    let tmp = tempfile::tempdir().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_string_lossy().to_string()).unwrap();

    let info = core
        .project_trust_warning(input(FfiTrustKeyState::ContentKeyAvailable))
        .unwrap();
    assert_eq!(info.severity, "info");
    assert_eq!(info.state, "content_key_available");
    assert!(!info.is_actionable);
    assert!(info.user_actions.is_empty());

    let warning = core
        .project_trust_warning(input(FfiTrustKeyState::ProviderApiKeyUntested))
        .unwrap();
    assert_eq!(warning.severity, "warning");
    assert_eq!(
        warning
            .user_actions
            .iter()
            .map(|action| action.action_id.as_str())
            .collect::<Vec<_>>(),
        vec!["test_api_key", "open_provider_settings"]
    );
    assert!(!warning.message.contains("soniox"));

    let blocked = core
        .project_trust_warning(input(FfiTrustKeyState::ProviderApiKeyMissing))
        .unwrap();
    assert_eq!(blocked.severity, "blocked");
    assert!(blocked.is_actionable);
    assert_eq!(
        blocked
            .user_actions
            .iter()
            .map(|action| action.action_id.as_str())
            .collect::<Vec<_>>(),
        vec!["add_api_key", "open_provider_settings"]
    );
    assert!(blocked
        .diagnostic_summary
        .as_deref()
        .unwrap_or_default()
        .contains("key_scope=soniox"));
}
