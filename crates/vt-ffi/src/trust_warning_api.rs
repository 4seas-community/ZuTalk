use vt_crypto::{
    project_trust_warning, TrustKeyState, TrustSurface, TrustUserAction, TrustWarning,
    TrustWarningError, TrustWarningInput,
};

use crate::{CoreError, ZulangueCore};

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTrustSurface {
    Status,
    Settings,
    Diagnostics,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTrustKeyState {
    ProviderApiKeyHealthy,
    ProviderApiKeyMissing,
    ProviderApiKeyUntested,
    ProviderApiKeyRejected,
    ContentKeyAvailable,
    ContentKeyMissing,
    ContentKeyDestroyed,
    Unknown,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiTrustWarningInput {
    pub surface: FfiTrustSurface,
    pub key_state: FfiTrustKeyState,
    pub provider_display_name: Option<String>,
    pub key_scope: Option<String>,
    pub content_label: Option<String>,
    pub diagnostic_hint: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiTrustUserAction {
    pub action_id: String,
    pub label: String,
    pub action_kind: String,
    pub enabled: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FfiTrustWarning {
    pub severity: String,
    pub state: String,
    pub title: String,
    pub message: String,
    pub is_actionable: bool,
    pub user_actions: Vec<FfiTrustUserAction>,
    pub diagnostic_summary: Option<String>,
}

#[uniffi::export]
impl ZulangueCore {
    pub fn project_trust_warning(
        &self,
        input: FfiTrustWarningInput,
    ) -> Result<FfiTrustWarning, CoreError> {
        project_trust_warning(trust_warning_input(input))
            .map(ffi_trust_warning)
            .map_err(trust_warning_error)
    }
}

fn trust_warning_input(input: FfiTrustWarningInput) -> TrustWarningInput {
    TrustWarningInput {
        surface: trust_surface(input.surface),
        key_state: trust_key_state(input.key_state),
        provider_display_name: input.provider_display_name,
        key_scope: input.key_scope,
        content_label: input.content_label,
        diagnostic_hint: input.diagnostic_hint,
    }
}

fn trust_surface(surface: FfiTrustSurface) -> TrustSurface {
    match surface {
        FfiTrustSurface::Status => TrustSurface::Status,
        FfiTrustSurface::Settings => TrustSurface::Settings,
        FfiTrustSurface::Diagnostics => TrustSurface::Diagnostics,
    }
}

fn trust_key_state(key_state: FfiTrustKeyState) -> TrustKeyState {
    match key_state {
        FfiTrustKeyState::ProviderApiKeyHealthy => TrustKeyState::ProviderApiKeyHealthy,
        FfiTrustKeyState::ProviderApiKeyMissing => TrustKeyState::ProviderApiKeyMissing,
        FfiTrustKeyState::ProviderApiKeyUntested => TrustKeyState::ProviderApiKeyUntested,
        FfiTrustKeyState::ProviderApiKeyRejected => TrustKeyState::ProviderApiKeyRejected,
        FfiTrustKeyState::ContentKeyAvailable => TrustKeyState::ContentKeyAvailable,
        FfiTrustKeyState::ContentKeyMissing => TrustKeyState::ContentKeyMissing,
        FfiTrustKeyState::ContentKeyDestroyed => TrustKeyState::ContentKeyDestroyed,
        FfiTrustKeyState::Unknown => TrustKeyState::Unknown,
    }
}

fn ffi_trust_warning(warning: TrustWarning) -> FfiTrustWarning {
    FfiTrustWarning {
        severity: warning.severity,
        state: warning.state,
        title: warning.title,
        message: warning.message,
        is_actionable: warning.is_actionable,
        user_actions: warning
            .user_actions
            .into_iter()
            .map(ffi_trust_action)
            .collect(),
        diagnostic_summary: warning.diagnostic_summary,
    }
}

fn ffi_trust_action(action: TrustUserAction) -> FfiTrustUserAction {
    FfiTrustUserAction {
        action_id: action.action_id,
        label: action.label,
        action_kind: action.action_kind,
        enabled: action.enabled,
    }
}

fn trust_warning_error(error: TrustWarningError) -> CoreError {
    CoreError::InternalError {
        message: format!("trust warning: {error}"),
    }
}
