//! Manual, non-biometric speaker naming and cross-session indexing.
//!
//! Soniox speaker labels are anonymous and scoped to one provider session.
//! This API stores only user-entered names and explicit relationships. It does
//! not store audio samples, embeddings, voiceprints, or automatic match data.

use crate::{CoreError, ZulangueCore};
use vt_store::notebook_capture_store::{NotebookCaptureStoreError, Participant, SessionSpeaker};

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSpeakerParticipant {
    pub id: String,
    pub display_name: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSessionSpeaker {
    pub id: String,
    pub session_id: String,
    pub provider_session_epoch: u64,
    pub provider: String,
    pub provider_label: String,
    pub local_display_name: Option<String>,
    pub participant_id: Option<String>,
}

impl From<Participant> for FfiSpeakerParticipant {
    fn from(value: Participant) -> Self {
        Self {
            id: value.id,
            display_name: value.display_name,
        }
    }
}

impl From<SessionSpeaker> for FfiSessionSpeaker {
    fn from(value: SessionSpeaker) -> Self {
        Self {
            id: value.id,
            session_id: value.session_id,
            provider_session_epoch: value.provider_session_epoch,
            provider: value.provider,
            provider_label: value.provider_label,
            local_display_name: value.local_display_name,
            participant_id: value.participant_id,
        }
    }
}

#[uniffi::export]
impl ZulangueCore {
    pub fn list_speaker_participants(&self) -> Result<Vec<FfiSpeakerParticipant>, CoreError> {
        self.notebook_capture_store
            .list_participants()
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(speaker_store_error)
    }

    pub fn create_speaker_participant(
        &self,
        display_name: String,
    ) -> Result<FfiSpeakerParticipant, CoreError> {
        let display_name = normalized_required_name(&display_name)?;
        self.notebook_capture_store
            .create_participant(display_name)
            .map(Into::into)
            .map_err(speaker_store_error)
    }

    pub fn rename_speaker_participant(
        &self,
        participant_id: String,
        display_name: String,
    ) -> Result<FfiSpeakerParticipant, CoreError> {
        let display_name = normalized_required_name(&display_name)?;
        self.notebook_capture_store
            .rename_participant(&participant_id, display_name)
            .map(Into::into)
            .map_err(speaker_store_error)
    }

    pub fn list_notebook_session_speakers(
        &self,
        session_id: String,
    ) -> Result<Vec<FfiSessionSpeaker>, CoreError> {
        self.notebook_capture_store
            .list_session_speakers(&session_id)
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(speaker_store_error)
    }

    /// Set a session-only label. Blank text clears the override.
    pub fn rename_notebook_session_speaker(
        &self,
        session_speaker_id: String,
        local_display_name: Option<String>,
    ) -> Result<FfiSessionSpeaker, CoreError> {
        let normalized = local_display_name
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty());
        self.notebook_capture_store
            .rename_session_speaker(&session_speaker_id, normalized)
            .map(Into::into)
            .map_err(speaker_store_error)
    }

    pub fn link_notebook_session_speaker(
        &self,
        session_speaker_id: String,
        participant_id: String,
    ) -> Result<FfiSessionSpeaker, CoreError> {
        self.notebook_capture_store
            .link_session_speaker(&session_speaker_id, &participant_id)
            .map(Into::into)
            .map_err(speaker_store_error)
    }

    pub fn unlink_notebook_session_speaker(
        &self,
        session_speaker_id: String,
    ) -> Result<FfiSessionSpeaker, CoreError> {
        self.notebook_capture_store
            .unlink_session_speaker(&session_speaker_id)
            .map(Into::into)
            .map_err(speaker_store_error)
    }
}

fn normalized_required_name(value: &str) -> Result<&str, CoreError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(CoreError::ValidationFailed {
            message: "speaker display name must not be empty".to_string(),
        });
    }
    Ok(value)
}

fn speaker_store_error(error: NotebookCaptureStoreError) -> CoreError {
    match error {
        NotebookCaptureStoreError::NotFound(message) => CoreError::NotFound { message },
        NotebookCaptureStoreError::Validation(message)
        | NotebookCaptureStoreError::Conflict(message) => CoreError::ValidationFailed { message },
        other => CoreError::InternalError {
            message: other.to_string(),
        },
    }
}
