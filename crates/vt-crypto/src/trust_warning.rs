#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustSurface {
    Status,
    Settings,
    Diagnostics,
}

impl TrustSurface {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::Settings => "settings",
            Self::Diagnostics => "diagnostics",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustKeyState {
    ProviderApiKeyHealthy,
    ProviderApiKeyMissing,
    ProviderApiKeyUntested,
    ProviderApiKeyRejected,
    ContentKeyAvailable,
    ContentKeyMissing,
    ContentKeyDestroyed,
    Unknown,
}

impl TrustKeyState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ProviderApiKeyHealthy => "provider_api_key_healthy",
            Self::ProviderApiKeyMissing => "provider_api_key_missing",
            Self::ProviderApiKeyUntested => "provider_api_key_untested",
            Self::ProviderApiKeyRejected => "provider_api_key_rejected",
            Self::ContentKeyAvailable => "content_key_available",
            Self::ContentKeyMissing => "content_key_missing",
            Self::ContentKeyDestroyed => "content_key_destroyed",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustWarningInput {
    pub surface: TrustSurface,
    pub key_state: TrustKeyState,
    pub provider_display_name: Option<String>,
    pub key_scope: Option<String>,
    pub content_label: Option<String>,
    pub diagnostic_hint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustUserAction {
    pub action_id: String,
    pub label: String,
    pub action_kind: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustWarning {
    pub severity: String,
    pub state: String,
    pub title: String,
    pub message: String,
    pub is_actionable: bool,
    pub user_actions: Vec<TrustUserAction>,
    pub diagnostic_summary: Option<String>,
}

pub fn project_trust_warning(input: TrustWarningInput) -> Result<TrustWarning, TrustWarningError> {
    let provider_name = clean_label(input.provider_display_name.as_deref())
        .unwrap_or_else(|| "Selected provider".to_string());
    let content_label = clean_label(input.content_label.as_deref())
        .unwrap_or_else(|| "Private content".to_string());

    let projection = match input.key_state {
        TrustKeyState::ProviderApiKeyHealthy => Projection {
            severity: "info",
            title: format!("{provider_name} API key ready"),
            message: "This provider can be used from this Mac.".to_string(),
            actions: Vec::new(),
        },
        TrustKeyState::ProviderApiKeyMissing => Projection {
            severity: "blocked",
            title: format!("Add {provider_name} API key"),
            message: "Add an API key before using this provider.".to_string(),
            actions: vec![
                action("add_api_key", "Add API key", "settings"),
                action("open_provider_settings", "Open Soniox settings", "settings"),
            ],
        },
        TrustKeyState::ProviderApiKeyUntested => Projection {
            severity: "warning",
            title: format!("Test {provider_name} API key"),
            message: "Test this API key before relying on it for new work.".to_string(),
            actions: vec![
                action("test_api_key", "Test API key", "settings"),
                action("open_provider_settings", "Open Soniox settings", "settings"),
            ],
        },
        TrustKeyState::ProviderApiKeyRejected => Projection {
            severity: "blocked",
            title: format!("Update {provider_name} API key"),
            message: "The provider rejected this API key. Update it before running new work."
                .to_string(),
            actions: vec![
                action("update_api_key", "Update API key", "settings"),
                action("open_provider_settings", "Open Soniox settings", "settings"),
            ],
        },
        TrustKeyState::ContentKeyAvailable => Projection {
            severity: "info",
            title: "Private content is available".to_string(),
            message: format!("{content_label} can be opened on this Mac."),
            actions: Vec::new(),
        },
        TrustKeyState::ContentKeyMissing => Projection {
            severity: "blocked",
            title: "Private content key missing".to_string(),
            message: format!("{content_label} needs its content key before it can open."),
            actions: vec![
                action("restore_content_key", "Restore content key", "recovery"),
                action("open_diagnostics", "Open diagnostics", "diagnostics"),
            ],
        },
        TrustKeyState::ContentKeyDestroyed => Projection {
            severity: "blocked",
            title: "Private content key was destroyed".to_string(),
            message: format!("{content_label} cannot be opened with the current local keys."),
            actions: vec![action(
                "open_diagnostics",
                "Open diagnostics",
                "diagnostics",
            )],
        },
        TrustKeyState::Unknown => Projection {
            severity: "warning",
            title: "Key status unknown".to_string(),
            message: "Open diagnostics to inspect key status.".to_string(),
            actions: vec![action(
                "open_diagnostics",
                "Open diagnostics",
                "diagnostics",
            )],
        },
    };

    Ok(TrustWarning {
        severity: projection.severity.to_string(),
        state: input.key_state.as_str().to_string(),
        title: projection.title,
        message: projection.message,
        is_actionable: projection.actions.iter().any(|action| action.enabled),
        user_actions: projection.actions,
        diagnostic_summary: Some(diagnostic_summary(&input)),
    })
}

struct Projection {
    severity: &'static str,
    title: String,
    message: String,
    actions: Vec<TrustUserAction>,
}

fn action(action_id: &str, label: &str, action_kind: &str) -> TrustUserAction {
    TrustUserAction {
        action_id: action_id.to_string(),
        label: label.to_string(),
        action_kind: action_kind.to_string(),
        enabled: true,
    }
}

fn clean_label(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn diagnostic_summary(input: &TrustWarningInput) -> String {
    let provider = input.provider_display_name.as_deref().unwrap_or("none");
    let key_scope = input.key_scope.as_deref().unwrap_or("none");
    let content_label = input.content_label.as_deref().unwrap_or("none");
    let diagnostic_hint = input.diagnostic_hint.as_deref().unwrap_or("none");
    format!(
        "surface={}; state={}; provider={}; key_scope={}; content={}; hint={}",
        input.surface.as_str(),
        input.key_state.as_str(),
        provider,
        key_scope,
        content_label,
        diagnostic_hint
    )
}

#[derive(Debug, thiserror::Error)]
pub enum TrustWarningError {
    #[error("trust warning projection error: {0}")]
    Projection(String),
}
