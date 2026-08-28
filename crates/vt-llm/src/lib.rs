//! The language model ZuTalk sends marked passages to.
//!
//! Like the capture engine, this is a single build-time descriptor rather than
//! a provider registry: one provider, one credential scope, one default model.
//! A catalogue would be a product decision nobody has made, and every extra
//! choice here is a choice the user has to understand before they can use the
//! feature at all.
//!
//! What this crate must never do is decide *what* leaves the device. It knows
//! how to reach the provider and whether a key works; the callers decide what
//! text is worth sending, and the user decides whether any of it goes at all.

use std::time::Duration;

pub mod digest;
pub mod engine;

pub use digest::{
    digest_passage, is_worth_digesting, source_fingerprint, PassageDigestRequest, PassageLine,
};
pub use engine::{LanguageModelEngine, CURRENT_LANGUAGE_MODEL_ENGINE};

/// Failures a credential check can produce, in the shapes the app can act on.
///
/// The distinction that matters to a user is "your key is wrong" versus
/// "the network or the service is having a moment" — the first is their
/// problem to fix, the second is a reason to try again later.
#[derive(Debug, thiserror::Error)]
pub enum LanguageModelError {
    #[error("credential rejected")]
    InvalidCredential,

    #[error("credit balance or quota exhausted")]
    QuotaExhausted,

    #[error("rate limited")]
    RateLimited,

    #[error("network unavailable: {0}")]
    NetworkUnavailable(String),

    #[error("service unavailable: HTTP {status}")]
    ServiceUnavailable { status: u16 },

    #[error("api key is empty")]
    EmptyCredential,

    #[error("model returned nothing")]
    EmptyResponse,
}

/// Checks a credential without spending anything or leaving a trace.
///
/// Listing models is the cheapest authenticated call the provider offers: it
/// costs no tokens, creates nothing, and answers the only question Settings
/// needs answered. Verification deliberately does not send any user content —
/// a key check must never be the thing that first ships a transcript off the
/// device.
pub async fn verify_credential(
    engine: LanguageModelEngine,
    api_key: &str,
) -> Result<(), LanguageModelError> {
    let api_key = api_key.trim();
    if api_key.is_empty() {
        return Err(LanguageModelError::EmptyCredential);
    }

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| LanguageModelError::NetworkUnavailable(error.to_string()))?;

    let response = client
        .get(format!("{}/v1/models", engine.api_base_url))
        .header("x-api-key", api_key)
        .header("anthropic-version", engine.api_version)
        .send()
        .await
        .map_err(|error| {
            // Credential material can appear in a reqwest URL error's display
            // form; the message is rebuilt from the failure kind so a key can
            // never reach a log through this path.
            LanguageModelError::NetworkUnavailable(describe_transport_failure(&error))
        })?;

    classify(response.status().as_u16())
}

pub(crate) fn classify(status: u16) -> Result<(), LanguageModelError> {
    match status {
        200..=299 => Ok(()),
        401 | 403 => Err(LanguageModelError::InvalidCredential),
        402 => Err(LanguageModelError::QuotaExhausted),
        429 => Err(LanguageModelError::RateLimited),
        status => Err(LanguageModelError::ServiceUnavailable { status }),
    }
}

pub(crate) fn describe_transport_failure(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        "timeout".to_string()
    } else if error.is_connect() {
        "connect failed".to_string()
    } else if error.is_request() {
        "request failed".to_string()
    } else {
        "transport failed".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An empty key must not become a network request. Settings can reach this
    /// path while the field is still being typed into.
    #[tokio::test]
    async fn an_empty_credential_is_refused_without_a_request() {
        let result = verify_credential(CURRENT_LANGUAGE_MODEL_ENGINE, "   ").await;
        assert!(matches!(result, Err(LanguageModelError::EmptyCredential)));
    }

    /// The split a user acts on: their key is wrong, versus the service is
    /// busy. Collapsing these would tell someone to re-enter a key that was
    /// fine all along.
    #[test]
    fn status_codes_split_into_what_the_user_can_do_about_them() {
        assert!(classify(200).is_ok());
        assert!(matches!(
            classify(401),
            Err(LanguageModelError::InvalidCredential)
        ));
        assert!(matches!(
            classify(403),
            Err(LanguageModelError::InvalidCredential)
        ));
        assert!(matches!(
            classify(402),
            Err(LanguageModelError::QuotaExhausted)
        ));
        assert!(matches!(
            classify(429),
            Err(LanguageModelError::RateLimited)
        ));
        assert!(matches!(
            classify(500),
            Err(LanguageModelError::ServiceUnavailable { status: 500 })
        ));
        assert!(matches!(
            classify(404),
            Err(LanguageModelError::ServiceUnavailable { status: 404 })
        ));
    }
}
