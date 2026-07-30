#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiagnosticArea {
    Runtime,
    Provider,
    Audio,
    Key,
    Unknown,
}

impl DiagnosticArea {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Runtime => "runtime",
            Self::Provider => "provider",
            Self::Audio => "audio",
            Self::Key => "key",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiagnosticSeverity {
    Info,
    Warning,
    Blocked,
}

impl DiagnosticSeverity {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warning => "warning",
            Self::Blocked => "blocked",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticDetailInput {
    pub key: String,
    pub label: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticAreaInput {
    pub area: DiagnosticArea,
    pub severity: DiagnosticSeverity,
    pub label: String,
    pub user_summary: String,
    pub details: Vec<DiagnosticDetailInput>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticsProjectionInput {
    pub areas: Vec<DiagnosticAreaInput>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticSummaryItem {
    pub area_id: String,
    pub label: String,
    pub severity: DiagnosticSeverity,
    pub user_summary: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticDetailItem {
    pub key: String,
    pub label: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticDetailGroup {
    pub area_id: String,
    pub label: String,
    pub severity: DiagnosticSeverity,
    pub user_summary: String,
    pub details: Vec<DiagnosticDetailItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticsProjection {
    pub title: String,
    pub normal_summary: String,
    pub summary_items: Vec<DiagnosticSummaryItem>,
    pub detail_groups: Vec<DiagnosticDetailGroup>,
}

pub fn project_diagnostics_projection(
    input: DiagnosticsProjectionInput,
) -> Result<DiagnosticsProjection, DiagnosticsProjectionError> {
    let mut summary_items = Vec::with_capacity(input.areas.len());
    let mut detail_groups = Vec::with_capacity(input.areas.len());

    for area in input.areas {
        let label = clean_required("label", area.label)?;
        let user_summary = clean_required("user_summary", area.user_summary)?;
        let area_id = area.area.as_str().to_string();
        let details = area
            .details
            .into_iter()
            .map(clean_detail)
            .collect::<Result<Vec<_>, _>>()?;

        summary_items.push(DiagnosticSummaryItem {
            area_id: area_id.clone(),
            label: label.clone(),
            severity: area.severity,
            user_summary: user_summary.clone(),
        });
        detail_groups.push(DiagnosticDetailGroup {
            area_id,
            label,
            severity: area.severity,
            user_summary,
            details,
        });
    }

    let normal_summary = if summary_items.is_empty() {
        "No diagnostics available".to_string()
    } else {
        summary_items
            .iter()
            .map(|item| item.user_summary.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    };

    Ok(DiagnosticsProjection {
        title: "Diagnostics".to_string(),
        normal_summary,
        summary_items,
        detail_groups,
    })
}

fn clean_detail(
    input: DiagnosticDetailInput,
) -> Result<DiagnosticDetailItem, DiagnosticsProjectionError> {
    let key = clean_required("detail.key", input.key)?;
    let label = clean_required("detail.label", input.label)?;
    let value = clean_required("detail.value", input.value)?;
    Ok(DiagnosticDetailItem {
        value: redact_if_secret(&key, &value),
        key,
        label,
    })
}

fn clean_required(
    field: &'static str,
    value: String,
) -> Result<String, DiagnosticsProjectionError> {
    let value = value.trim().to_string();
    if value.is_empty() {
        Err(DiagnosticsProjectionError::Projection(format!(
            "{field} is required"
        )))
    } else {
        Ok(value)
    }
}

fn redact_if_secret(key: &str, value: &str) -> String {
    let key = key.to_ascii_lowercase();
    let value_lower = value.to_ascii_lowercase();
    if key == "key"
        || key.contains("api_key")
        || key.contains("apikey")
        || key.contains("private_key")
        || key.contains("secret_key")
        || (key.ends_with("_key") && !key.ends_with("_key_state"))
        || key.contains("token")
        || key.contains("secret")
        || key.contains("password")
        || key.contains("credential")
        || key.contains("authorization")
        || key == "auth"
        || value_lower.starts_with("sk-")
        || value_lower.starts_with("bearer ")
        || value_lower.contains("api_key=")
        || value_lower.contains("access_token=")
        || value_lower.contains("refresh_token=")
        || value_lower.contains("token=")
        || value_lower.contains("authorization:")
        || value_lower.contains("authorization=")
        || value_lower.contains("password=")
        || value_lower.contains("secret=")
    {
        "[redacted]".to_string()
    } else {
        value.to_string()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DiagnosticsProjectionError {
    #[error("diagnostics projection error: {0}")]
    Projection(String),
}
