use vt_store::{
    project_diagnostics_projection, DiagnosticArea, DiagnosticAreaInput, DiagnosticDetailGroup,
    DiagnosticDetailInput, DiagnosticDetailItem, DiagnosticSeverity, DiagnosticSummaryItem,
    DiagnosticsProjection, DiagnosticsProjectionError, DiagnosticsProjectionInput,
};

use crate::{CoreError, ZulangueCore};

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiagnosticArea {
    Runtime,
    Provider,
    Audio,
    Key,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDiagnosticSeverity {
    Info,
    Warning,
    Blocked,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiDiagnosticDetailInput {
    pub key: String,
    pub label: String,
    pub value: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiDiagnosticAreaInput {
    pub area: FfiDiagnosticArea,
    pub severity: FfiDiagnosticSeverity,
    pub label: String,
    pub user_summary: String,
    pub details: Vec<FfiDiagnosticDetailInput>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiDiagnosticsProjectionInput {
    pub areas: Vec<FfiDiagnosticAreaInput>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiDiagnosticSummaryItem {
    pub area_id: String,
    pub label: String,
    pub severity: String,
    pub user_summary: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiDiagnosticDetailItem {
    pub key: String,
    pub label: String,
    pub value: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiDiagnosticDetailGroup {
    pub area_id: String,
    pub label: String,
    pub severity: String,
    pub user_summary: String,
    pub details: Vec<FfiDiagnosticDetailItem>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiDiagnosticsProjection {
    pub title: String,
    pub normal_summary: String,
    pub summary_items: Vec<FfiDiagnosticSummaryItem>,
    pub detail_groups: Vec<FfiDiagnosticDetailGroup>,
}

#[uniffi::export]
impl ZulangueCore {
    pub fn project_diagnostics(
        &self,
        input: FfiDiagnosticsProjectionInput,
    ) -> Result<FfiDiagnosticsProjection, CoreError> {
        project_diagnostics_projection(diagnostics_input(input))
            .map(ffi_diagnostics_projection)
            .map_err(diagnostics_error)
    }
}

fn diagnostics_input(input: FfiDiagnosticsProjectionInput) -> DiagnosticsProjectionInput {
    DiagnosticsProjectionInput {
        areas: input.areas.into_iter().map(diagnostic_area_input).collect(),
    }
}

fn diagnostic_area_input(input: FfiDiagnosticAreaInput) -> DiagnosticAreaInput {
    DiagnosticAreaInput {
        area: diagnostic_area(input.area),
        severity: diagnostic_severity(input.severity),
        label: input.label,
        user_summary: input.user_summary,
        details: input
            .details
            .into_iter()
            .map(diagnostic_detail_input)
            .collect(),
    }
}

fn diagnostic_detail_input(input: FfiDiagnosticDetailInput) -> DiagnosticDetailInput {
    DiagnosticDetailInput {
        key: input.key,
        label: input.label,
        value: input.value,
    }
}

fn diagnostic_area(area: FfiDiagnosticArea) -> DiagnosticArea {
    match area {
        FfiDiagnosticArea::Runtime => DiagnosticArea::Runtime,
        FfiDiagnosticArea::Provider => DiagnosticArea::Provider,
        FfiDiagnosticArea::Audio => DiagnosticArea::Audio,
        FfiDiagnosticArea::Key => DiagnosticArea::Key,
        FfiDiagnosticArea::Unknown => DiagnosticArea::Unknown,
    }
}

fn diagnostic_severity(severity: FfiDiagnosticSeverity) -> DiagnosticSeverity {
    match severity {
        FfiDiagnosticSeverity::Info => DiagnosticSeverity::Info,
        FfiDiagnosticSeverity::Warning => DiagnosticSeverity::Warning,
        FfiDiagnosticSeverity::Blocked => DiagnosticSeverity::Blocked,
    }
}

fn ffi_diagnostics_projection(projection: DiagnosticsProjection) -> FfiDiagnosticsProjection {
    FfiDiagnosticsProjection {
        title: projection.title,
        normal_summary: projection.normal_summary,
        summary_items: projection
            .summary_items
            .into_iter()
            .map(ffi_diagnostic_summary_item)
            .collect(),
        detail_groups: projection
            .detail_groups
            .into_iter()
            .map(ffi_diagnostic_detail_group)
            .collect(),
    }
}

fn ffi_diagnostic_summary_item(item: DiagnosticSummaryItem) -> FfiDiagnosticSummaryItem {
    FfiDiagnosticSummaryItem {
        area_id: item.area_id,
        label: item.label,
        severity: item.severity.as_str().to_string(),
        user_summary: item.user_summary,
    }
}

fn ffi_diagnostic_detail_group(group: DiagnosticDetailGroup) -> FfiDiagnosticDetailGroup {
    FfiDiagnosticDetailGroup {
        area_id: group.area_id,
        label: group.label,
        severity: group.severity.as_str().to_string(),
        user_summary: group.user_summary,
        details: group
            .details
            .into_iter()
            .map(ffi_diagnostic_detail_item)
            .collect(),
    }
}

fn ffi_diagnostic_detail_item(item: DiagnosticDetailItem) -> FfiDiagnosticDetailItem {
    FfiDiagnosticDetailItem {
        key: item.key,
        label: item.label,
        value: item.value,
    }
}

fn diagnostics_error(error: DiagnosticsProjectionError) -> CoreError {
    CoreError::InternalError {
        message: format!("diagnostics: {error}"),
    }
}
