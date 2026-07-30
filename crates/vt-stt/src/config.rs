//! STT 配置类型
//! 权威定义：TYPE_SYSTEM.md §2.2-2.3

/// STT 配置
// Deliberately not `Debug`: Notebook capture may embed the exact private
// Context Pack payload in this configuration.
#[derive(Clone)]
pub struct SttConfig {
    pub language_hints: Vec<String>,
    pub language_hints_strict: bool,
    pub enable_language_identification: bool,
    pub enable_speaker_diarization: bool,
    /// Soniox semantic endpoint latency profile (official range: 0..=3).
    /// `0` is the balanced quality/latency default.
    pub endpoint_latency_adjustment_level: u8,
    /// Soniox endpoint sensitivity (official range: -1.0..=1.0).
    /// `0.0` keeps the neutral balanced default.
    pub endpoint_sensitivity: f32,
    /// Optional compatibility override for Soniox `max_endpoint_delay_ms`.
    /// `None` resolves to the balanced default of 2000 ms and is still sent
    /// explicitly on transcription connections.
    pub endpoint_delay_ms: Option<u32>,
    pub translation: Option<TranslationConfig>,
    pub context: Option<ContextConfig>,
    pub client_reference_id: Option<String>,
}

pub const BALANCED_ENDPOINT_LATENCY_ADJUSTMENT_LEVEL: u8 = 0;
pub const BALANCED_ENDPOINT_SENSITIVITY: f32 = 0.0;
pub const BALANCED_MAX_ENDPOINT_DELAY_MS: u32 = 2_000;

impl SttConfig {
    pub(crate) fn resolved_max_endpoint_delay_ms(&self) -> u32 {
        self.endpoint_delay_ms
            .unwrap_or(BALANCED_MAX_ENDPOINT_DELAY_MS)
    }
}

impl Default for SttConfig {
    fn default() -> Self {
        Self {
            language_hints: Vec::new(),
            language_hints_strict: false,
            enable_language_identification: false,
            enable_speaker_diarization: false,
            endpoint_latency_adjustment_level: BALANCED_ENDPOINT_LATENCY_ADJUSTMENT_LEVEL,
            endpoint_sensitivity: BALANCED_ENDPOINT_SENSITIVITY,
            endpoint_delay_ms: None,
            translation: None,
            context: None,
            client_reference_id: None,
        }
    }
}

#[derive(Debug, Clone)]
pub enum TranslationConfig {
    OneWay {
        target_language: String,
    },
    TwoWay {
        language_a: String,
        language_b: String,
    },
}

#[derive(Clone)]
pub struct ContextConfig {
    pub general: Vec<(String, String)>,
    pub text: Option<String>,
    pub terms: Vec<String>,
    pub translation_terms: Vec<(String, String)>,
}

/// WebSocket 连接状态
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionStatus {
    Connected,
    Reconnecting { attempt: u32 },
    BufferOverflow { lost_duration_ms: u64 },
    Failed { error: String },
}

#[cfg(test)]
mod tests {
    use super::{
        SttConfig, BALANCED_ENDPOINT_LATENCY_ADJUSTMENT_LEVEL, BALANCED_ENDPOINT_SENSITIVITY,
        BALANCED_MAX_ENDPOINT_DELAY_MS,
    };

    #[test]
    fn speaker_diarization_is_opt_in() {
        assert!(!SttConfig::default().enable_speaker_diarization);
    }

    #[test]
    fn endpoint_detection_defaults_to_balanced_profile() {
        let config = SttConfig::default();
        assert_eq!(
            config.endpoint_latency_adjustment_level,
            BALANCED_ENDPOINT_LATENCY_ADJUSTMENT_LEVEL
        );
        assert_eq!(config.endpoint_sensitivity, BALANCED_ENDPOINT_SENSITIVITY);
        assert_eq!(
            config.resolved_max_endpoint_delay_ms(),
            BALANCED_MAX_ENDPOINT_DELAY_MS
        );
    }

    #[test]
    fn endpoint_delay_override_remains_compatible() {
        let config = SttConfig {
            endpoint_delay_ms: Some(1_250),
            ..Default::default()
        };
        assert_eq!(config.resolved_max_endpoint_delay_ms(), 1_250);
    }
}
