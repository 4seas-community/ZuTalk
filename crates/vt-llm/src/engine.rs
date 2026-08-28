//! The fixed language-model contract.
//!
//! Deliberately singular, for the same reason the capture engine is: a model
//! picker is a question the product would be asking the user instead of
//! answering for them, and nobody configuring ZuTalk wants to research
//! context windows before they can clean up a marked passage.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LanguageModelEngine {
    pub provider_id: &'static str,
    pub provider_display_name: &'static str,
    /// Where the credential is filed. Separate from the capture provider's
    /// scope: they are different accounts, billed separately, and either one
    /// can be configured without the other.
    pub credential_scope: &'static str,
    pub api_base_url: &'static str,
    pub api_version: &'static str,
    /// The model that cleans up a marked passage and writes from materials.
    pub model_id: &'static str,
    /// Where a user obtains a key, shown in Settings so the answer to "where
    /// do I get one" is not a search.
    pub console_url: &'static str,
}

pub const CURRENT_LANGUAGE_MODEL_ENGINE: LanguageModelEngine = LanguageModelEngine {
    provider_id: "anthropic",
    provider_display_name: "Anthropic",
    credential_scope: "anthropic",
    api_base_url: "https://api.anthropic.com",
    api_version: "2023-06-01",
    model_id: "claude-sonnet-5",
    console_url: "https://console.anthropic.com/settings/keys",
};

#[cfg(test)]
mod tests {
    use super::*;

    /// The capture credential and the model credential are different accounts.
    /// If these scopes ever collided, configuring one would silently overwrite
    /// the other in the store, and a user would lose transcription by adding a
    /// model key.
    #[test]
    fn the_model_credential_scope_is_not_the_capture_one() {
        assert_eq!(CURRENT_LANGUAGE_MODEL_ENGINE.credential_scope, "anthropic");
        assert_ne!(CURRENT_LANGUAGE_MODEL_ENGINE.credential_scope, "soniox");
    }

    #[test]
    fn the_engine_names_a_reachable_endpoint_and_a_current_model() {
        let engine = CURRENT_LANGUAGE_MODEL_ENGINE;
        assert!(engine.api_base_url.starts_with("https://"));
        assert!(engine.console_url.starts_with("https://"));
        assert!(!engine.model_id.is_empty());
        assert!(!engine.api_version.is_empty());
    }
}
