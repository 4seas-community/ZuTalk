use vt_ffi::diagnostics_api::{
    FfiDiagnosticArea, FfiDiagnosticAreaInput, FfiDiagnosticDetailInput, FfiDiagnosticSeverity,
    FfiDiagnosticsProjectionInput,
};
use vt_ffi::ZulangueCore;

#[test]
fn p0_diagnostics_api_separates_summary_from_detail() {
    let tmp = tempfile::tempdir().unwrap();
    let core = ZulangueCore::new_for_test(tmp.path().to_string_lossy().to_string()).unwrap();

    let projection = core
        .project_diagnostics(FfiDiagnosticsProjectionInput {
            areas: vec![
                FfiDiagnosticAreaInput {
                    area: FfiDiagnosticArea::Runtime,
                    severity: FfiDiagnosticSeverity::Warning,
                    label: "Runtime".to_string(),
                    user_summary: "Local service needs attention".to_string(),
                    details: vec![
                        detail("core_health", "App core health", "degraded"),
                        detail("heartbeat_age_ms", "Heartbeat age", "2500"),
                    ],
                },
                FfiDiagnosticAreaInput {
                    area: FfiDiagnosticArea::Provider,
                    severity: FfiDiagnosticSeverity::Info,
                    label: "Soniox provider".to_string(),
                    user_summary: "Soniox is configured".to_string(),
                    details: vec![
                        detail("provider", "Provider", "Soniox"),
                        detail("model", "Model", "stt-rt-v5"),
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
        vec!["runtime", "provider"]
    );
    assert!(projection
        .normal_summary
        .contains("Local service needs attention"));
    assert!(!projection.normal_summary.contains("heartbeat_age_ms"));
    assert!(!projection.normal_summary.contains("stt-rt-v5"));

    let detail_pairs = projection
        .detail_groups
        .iter()
        .flat_map(|group| group.details.iter())
        .map(|detail| format!("{}={}", detail.key, detail.value))
        .collect::<Vec<_>>();

    assert!(detail_pairs
        .iter()
        .any(|pair| pair == "heartbeat_age_ms=2500"));
    assert!(detail_pairs.iter().any(|pair| pair == "provider=Soniox"));
    assert!(detail_pairs.iter().any(|pair| pair == "model=stt-rt-v5"));
}

fn detail(key: &str, label: &str, value: &str) -> FfiDiagnosticDetailInput {
    FfiDiagnosticDetailInput {
        key: key.to_string(),
        label: label.to_string(),
        value: value.to_string(),
    }
}
