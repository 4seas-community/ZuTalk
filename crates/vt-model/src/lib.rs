//! Shared data primitives used by the active capture and transcription paths.

use serde::{Deserialize, Serialize};

/// Local privacy policy applied before any remote provider is used.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PrivacyLevel {
    Standard,
    High,
    Maximum,
}

/// Timestamped token emitted by the post-recording transcription adapter.
///
/// Live bilingual capture uses `vt_stt::SttStreamToken`, whose timestamps are
/// optional. Provider speaker labels are anonymous and scoped to the provider
/// session; they do not contain a persistent identity or voiceprint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Token {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub is_final: bool,
    pub language: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    pub confidence: f32,
    pub translation_status: TranslationStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TranslationStatus {
    None,
    Original,
    Translation,
}

/// PCM S16LE, 16 kHz, mono audio pushed into an STT adapter.
#[derive(Debug, Clone)]
pub struct AudioChunk {
    pub pcm_data: Vec<u8>,
    pub channel: AudioChannel,
    pub captured_at_ns: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AudioChannel {
    Microphone,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_roundtrip_preserves_anonymous_speaker_label() {
        let token = Token {
            text: "Hello".into(),
            start_ms: 1_000,
            end_ms: 1_500,
            is_final: true,
            language: "en".into(),
            speaker: Some("1".into()),
            confidence: 0.95,
            translation_status: TranslationStatus::Original,
        };

        let json = serde_json::to_string(&token).unwrap();
        assert!(json.contains(r#""speaker":"1""#));
        let decoded: Token = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.text, token.text);
        assert_eq!(decoded.start_ms, token.start_ms);
        assert_eq!(decoded.speaker, token.speaker);
    }

    #[test]
    fn token_without_speaker_remains_backward_compatible() {
        let decoded: Token = serde_json::from_str(
            r#"{
                "text":"Hello",
                "start_ms":1000,
                "end_ms":1500,
                "is_final":true,
                "language":"en",
                "confidence":0.95,
                "translation_status":"Original"
            }"#,
        )
        .unwrap();

        assert_eq!(decoded.speaker, None);
    }

    #[test]
    fn privacy_level_values_remain_stable() {
        assert_eq!(
            serde_json::to_string(&PrivacyLevel::Maximum).unwrap(),
            "\"Maximum\""
        );
    }
}
