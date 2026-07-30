//! Fixed Notebook capture engine contract for the minimal MVP.
//!
//! This is deliberately a singular build-time descriptor, not a provider
//! registry or a user-selectable model catalogue. Realtime capture and the
//! post-stop replay path have separate model roles even though both currently
//! use the same Soniox model.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PostStopExecution {
    RealtimeRestream,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotebookCaptureEngine {
    pub provider_id: &'static str,
    pub provider_display_name: &'static str,
    pub credential_scope: &'static str,
    pub realtime_model_id: &'static str,
    pub post_stop_model_id: &'static str,
    pub realtime_endpoint: &'static str,
    pub audio_format: &'static str,
    pub sample_rate: u32,
    pub channels: u8,
    pub supports_realtime_transcription: bool,
    pub supports_two_way_translation: bool,
    pub supports_context: bool,
    pub supports_post_stop_transcription: bool,
    pub post_stop_execution: PostStopExecution,
}

pub const CURRENT_NOTEBOOK_CAPTURE_ENGINE: NotebookCaptureEngine = NotebookCaptureEngine {
    provider_id: "soniox",
    provider_display_name: "Soniox",
    credential_scope: "soniox",
    realtime_model_id: "stt-rt-v5",
    post_stop_model_id: "stt-rt-v5",
    realtime_endpoint: "wss://stt-rt.soniox.com/transcribe-websocket",
    audio_format: "pcm_s16le",
    sample_rate: 16_000,
    channels: 1,
    supports_realtime_transcription: true,
    supports_two_way_translation: true,
    supports_context: true,
    supports_post_stop_transcription: true,
    post_stop_execution: PostStopExecution::RealtimeRestream,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_notebook_capture_engine_is_fixed_soniox_v5() {
        let engine = CURRENT_NOTEBOOK_CAPTURE_ENGINE;

        assert_eq!(engine.provider_id, "soniox");
        assert_eq!(engine.provider_display_name, "Soniox");
        assert_eq!(engine.credential_scope, "soniox");
        assert_eq!(engine.realtime_model_id, "stt-rt-v5");
        assert_eq!(engine.post_stop_model_id, "stt-rt-v5");
        assert_eq!(
            engine.realtime_endpoint,
            "wss://stt-rt.soniox.com/transcribe-websocket"
        );
        assert_eq!(engine.audio_format, "pcm_s16le");
        assert_eq!(engine.sample_rate, 16_000);
        assert_eq!(engine.channels, 1);
        assert!(engine.supports_realtime_transcription);
        assert!(engine.supports_two_way_translation);
        assert!(engine.supports_context);
        assert!(engine.supports_post_stop_transcription);
        assert_eq!(
            engine.post_stop_execution,
            PostStopExecution::RealtimeRestream
        );
    }
}
