use vt_store::{
    project_diagnostics_projection, DiagnosticArea, DiagnosticAreaInput, DiagnosticDetailInput,
    DiagnosticSeverity, DiagnosticsProjectionInput,
};

#[test]
fn p0_diagnostics_projection_includes_runtime_provider_audio_key_details() {
    let projection = project_diagnostics_projection(DiagnosticsProjectionInput {
        areas: vec![
            DiagnosticAreaInput {
                area: DiagnosticArea::Runtime,
                severity: DiagnosticSeverity::Warning,
                label: "Runtime".to_string(),
                user_summary: "Local service needs attention".to_string(),
                details: vec![
                    detail("core_health", "App core health", "degraded"),
                    detail("owner_kind", "Owner", "app_process"),
                    detail("heartbeat_age_ms", "Heartbeat age", "2500"),
                ],
            },
            DiagnosticAreaInput {
                area: DiagnosticArea::Provider,
                severity: DiagnosticSeverity::Info,
                label: "Soniox provider".to_string(),
                user_summary: "Soniox is configured".to_string(),
                details: vec![
                    detail("provider", "Provider", "Soniox"),
                    detail("model", "Model", "stt-rt-v5"),
                    detail("last_error", "Last error", "none"),
                ],
            },
            DiagnosticAreaInput {
                area: DiagnosticArea::Audio,
                severity: DiagnosticSeverity::Blocked,
                label: "Audio source".to_string(),
                user_summary: "Audio source is no longer available".to_string(),
                details: vec![
                    detail("source_state", "Source state", "deleted"),
                    detail("session_id", "Session", "session-42"),
                    detail("retained_bytes", "Retained bytes", "0"),
                ],
            },
            DiagnosticAreaInput {
                area: DiagnosticArea::Key,
                severity: DiagnosticSeverity::Warning,
                label: "Keys".to_string(),
                user_summary: "A key needs attention".to_string(),
                details: vec![
                    detail("provider_key_state", "Provider key", "missing"),
                    detail("content_key_state", "Content key", "present"),
                ],
            },
        ],
    })
    .unwrap();

    assert_eq!(projection.title, "Diagnostics");
    assert_eq!(
        projection
            .summary_items
            .iter()
            .map(|item| item.area_id.as_str())
            .collect::<Vec<_>>(),
        vec!["runtime", "provider", "audio", "key"]
    );
    assert_eq!(
        projection
            .summary_items
            .iter()
            .map(|item| item.severity.as_str())
            .collect::<Vec<_>>(),
        vec!["warning", "info", "blocked", "warning"]
    );
    assert!(projection
        .normal_summary
        .contains("Local service needs attention"));
    assert!(projection
        .normal_summary
        .contains("Audio source is no longer available"));

    for internal_detail in ["heartbeat_age_ms", "stt-rt-v5", "provider_key_state"] {
        assert!(
            !projection.normal_summary.contains(internal_detail),
            "normal summary must not expose diagnostics detail: {internal_detail}"
        );
    }

    let diagnostic_text = projection
        .detail_groups
        .iter()
        .flat_map(|group| group.details.iter())
        .map(|detail| format!("{}={}", detail.key, detail.value))
        .collect::<Vec<_>>()
        .join("\n");

    for expected_detail in [
        "heartbeat_age_ms=2500",
        "owner_kind=app_process",
        "provider=Soniox",
        "source_state=deleted",
        "provider_key_state=missing",
        "content_key_state=present",
    ] {
        assert!(
            diagnostic_text.contains(expected_detail),
            "diagnostics detail should include {expected_detail}"
        );
    }
    assert!(!diagnostic_text.contains("sk-"));
}

#[test]
fn p0_diagnostics_projection_redacts_secret_like_details() {
    let projection = project_diagnostics_projection(DiagnosticsProjectionInput {
        areas: vec![DiagnosticAreaInput {
            area: DiagnosticArea::Provider,
            severity: DiagnosticSeverity::Warning,
            label: "Soniox provider".to_string(),
            user_summary: "Soniox key needs attention".to_string(),
            details: vec![
                detail("access_token", "Access token", "token-visible"),
                detail("refresh_token", "Refresh token", "refresh-visible"),
                detail("authorization", "Authorization", "Bearer sk-visible"),
                detail("password", "Password", "secret-visible"),
                detail("credential_scope", "Credential scope", "soniox"),
            ],
        }],
    })
    .unwrap();

    let diagnostic_text = projection.detail_groups[0]
        .details
        .iter()
        .map(|detail| format!("{}={}", detail.key, detail.value))
        .collect::<Vec<_>>()
        .join("\n");

    for leaked in [
        "token-visible",
        "refresh-visible",
        "Bearer sk-visible",
        "secret-visible",
        "soniox",
    ] {
        assert!(
            !diagnostic_text.contains(leaked),
            "diagnostics detail leaked secret-like value: {leaked}"
        );
    }
    assert_eq!(diagnostic_text.matches("[redacted]").count(), 5);
}

fn detail(key: &str, label: &str, value: &str) -> DiagnosticDetailInput {
    DiagnosticDetailInput {
        key: key.to_string(),
        label: label.to_string(),
        value: value.to_string(),
    }
}
