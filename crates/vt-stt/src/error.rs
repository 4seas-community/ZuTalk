//! STT 错误类型
//! 权威定义：TYPE_SYSTEM.md §2.4
//!
//! Display 走 [`vt_i18n`] — 运行时 locale 切换会立即影响用户可见消息。

use std::time::Duration;
use vt_i18n::t_args;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SonioxQuotaKind {
    OrganizationBalance,
    OrganizationMonthlyBudget,
    ProjectMonthlyBudget,
    Other,
}

impl SonioxQuotaKind {
    pub(crate) fn from_error_type(error_type: Option<&str>) -> Self {
        match error_type.unwrap_or_default().to_ascii_lowercase().as_str() {
            "organization_balance_exhausted" => Self::OrganizationBalance,
            "organization_monthly_budget_exhausted" => Self::OrganizationMonthlyBudget,
            "project_monthly_budget_exhausted" => Self::ProjectMonthlyBudget,
            _ => Self::Other,
        }
    }
}

#[derive(Debug)]
pub enum SttError {
    ConnectionFailed(String),
    ReadTimeout(Duration),
    ServerClosed {
        code: u16,
        reason: String,
    },
    AuthFailed {
        message: String,
    },
    QuotaExhausted {
        kind: SonioxQuotaKind,
        message: String,
    },
    RateLimited,
    ParseError(String),
    ServerError {
        status: u16,
        message: String,
    },
    ApiError {
        status: u16,
        error_type: String,
        message: String,
    },
    TranscriptionFailed {
        error_type: String,
        message: String,
    },
    HttpError(String),
    Timeout {
        operation: String,
        elapsed: Duration,
    },
    Cancelled,
    UploadFailed {
        message: String,
    },
}

impl std::fmt::Display for SttError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::ConnectionFailed(msg) => t_args("error.stt.ws_failed", &[("detail", msg)]),
            Self::ReadTimeout(d) => {
                t_args("error.stt.read_timeout", &[("duration", &format!("{d:?}"))])
            }
            Self::ServerClosed { code, reason } => t_args(
                "error.stt.server_closed",
                &[("code", &code.to_string()), ("reason", reason)],
            ),
            Self::AuthFailed { message } => t_args("error.stt.auth_failed", &[("detail", message)]),
            Self::QuotaExhausted { message, .. } => {
                t_args("error.stt.quota_exhausted", &[("detail", message)])
            }
            Self::RateLimited => vt_i18n::t("error.stt.rate_limited"),
            Self::ParseError(msg) => t_args("error.stt.parse", &[("detail", msg)]),
            Self::ServerError { status, message } => t_args(
                "error.stt.server_error",
                &[("status", &status.to_string()), ("detail", message)],
            ),
            Self::ApiError {
                status,
                error_type,
                message,
            } => t_args(
                "error.stt.api_error",
                &[
                    ("status", &status.to_string()),
                    ("kind", error_type),
                    ("detail", message),
                ],
            ),
            Self::TranscriptionFailed {
                error_type,
                message,
            } => t_args(
                "error.stt.transcription_failed",
                &[("kind", error_type), ("detail", message)],
            ),
            Self::HttpError(msg) => t_args("error.stt.http", &[("detail", msg)]),
            Self::Timeout { operation, elapsed } => t_args(
                "error.stt.timeout",
                &[
                    ("operation", operation),
                    ("duration", &format!("{elapsed:?}")),
                ],
            ),
            Self::Cancelled => vt_i18n::t("error.stt.cancelled"),
            Self::UploadFailed { message } => {
                t_args("error.stt.upload_failed", &[("detail", message)])
            }
        };
        f.write_str(&s)
    }
}

impl std::error::Error for SttError {}

impl SttError {
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            Self::ReadTimeout(_)
                | Self::ConnectionFailed(_)
                | Self::RateLimited
                | Self::ServerError { .. }
        )
    }

    pub fn is_auth_error(&self) -> bool {
        matches!(self, Self::AuthFailed { .. } | Self::QuotaExhausted { .. })
    }
}

#[cfg(test)]
mod tests {
    // 这些测试验证本项目的错误分类逻辑。
    use super::*;

    #[test]
    fn test_is_retryable_true_cases() {
        assert!(SttError::ReadTimeout(Duration::from_secs(1)).is_retryable());
        assert!(SttError::ConnectionFailed("x".into()).is_retryable());
        assert!(SttError::RateLimited.is_retryable());
        assert!(SttError::ServerError {
            status: 500,
            message: "x".into(),
        }
        .is_retryable());
    }

    #[test]
    fn test_is_retryable_false_cases() {
        assert!(!SttError::AuthFailed {
            message: "x".into(),
        }
        .is_retryable());
        assert!(!SttError::QuotaExhausted {
            kind: SonioxQuotaKind::Other,
            message: "x".into(),
        }
        .is_retryable());
        assert!(!SttError::Cancelled.is_retryable());
        assert!(!SttError::ParseError("x".into()).is_retryable());
        assert!(!SttError::ApiError {
            status: 400,
            error_type: "x".into(),
            message: "x".into(),
        }
        .is_retryable());
        assert!(!SttError::HttpError("x".into()).is_retryable());
    }

    #[test]
    fn test_is_auth_error_true_cases() {
        assert!(SttError::AuthFailed {
            message: "x".into(),
        }
        .is_auth_error());
        assert!(SttError::QuotaExhausted {
            kind: SonioxQuotaKind::Other,
            message: "x".into(),
        }
        .is_auth_error());
    }

    #[test]
    fn test_is_auth_error_false_cases() {
        assert!(!SttError::ConnectionFailed("x".into()).is_auth_error());
        assert!(!SttError::RateLimited.is_auth_error());
        assert!(!SttError::Cancelled.is_auth_error());
        assert!(!SttError::ServerError {
            status: 500,
            message: "x".into(),
        }
        .is_auth_error());
    }
}
