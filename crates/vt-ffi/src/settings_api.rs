//! Notebook session export FFI.

use std::collections::HashMap;

use vt_export::{
    export_clipboard_text, export_zip, ClipboardTranscript, ClipboardUtterance, ExportData,
    ExportLanguageVariant, ExportOptions, ExportToken, ExportTranscript, ExportUtterance,
};
use vt_store::notebook_capture_store::{
    CaptureMode, NotebookCaptureProfile, UtteranceVariantRole, UtteranceVariantState,
};

use crate::{CoreError, ZulangueCore};

// MARK: - Export options

/// 导出 zip 选项（FFI DTO）
#[derive(uniffi::Record)]
pub struct ExportZipOptions {
    pub include_audio: bool,
    pub include_markdown: bool,
    pub include_srt: bool,
    pub include_vtt: bool,
    pub include_txt: bool,
}

// MARK: - ZulangueCore impls

#[uniffi::export]
impl ZulangueCore {
    /// Format one durable capture session for the local macOS clipboard.
    ///
    /// Rust owns transcript selection, speaker-name precedence, and language
    /// ordering. The Swift boundary only publishes this returned string to the
    /// system pasteboard after an explicit user action.
    pub fn get_session_transcript_clipboard_text(
        &self,
        session_id: String,
    ) -> Result<String, CoreError> {
        let record =
            self.session_store
                .get_session(&session_id)
                .map_err(|_| CoreError::NotFound {
                    message: format!("session not found: {session_id}"),
                })?;
        let run = self
            .notebook_capture_store
            .get_run_for_session(&session_id)
            .map_err(|error| CoreError::InternalError {
                message: format!("load capture run for clipboard: {error}"),
            })?
            .ok_or_else(|| CoreError::NotFound {
                message: format!("capture transcript not found: {session_id}"),
            })?;
        let profile: NotebookCaptureProfile = serde_json::from_str(&run.profile_snapshot_json)
            .map_err(|error| CoreError::InternalError {
                message: format!("invalid immutable capture profile snapshot: {error}"),
            })?;
        let utterances = self
            .notebook_capture_store
            .list_utterances(&session_id)
            .map_err(|error| CoreError::InternalError {
                message: format!("load realtime utterances for clipboard: {error}"),
            })?;

        let participant_names = self
            .notebook_capture_store
            .list_participants()
            .map_err(|error| CoreError::InternalError {
                message: format!("load speaker participants for clipboard: {error}"),
            })?
            .into_iter()
            .filter_map(|participant| {
                normalized_owned(&participant.display_name)
                    .map(|display_name| (participant.id, display_name))
            })
            .collect::<HashMap<_, _>>();
        let speaker_names = self
            .notebook_capture_store
            .list_session_speakers(&session_id)
            .map_err(|error| CoreError::InternalError {
                message: format!("load session speakers for clipboard: {error}"),
            })?
            .into_iter()
            .map(|speaker| {
                let display_name = speaker
                    .local_display_name
                    .as_deref()
                    .and_then(normalized_owned)
                    .or_else(|| {
                        speaker
                            .participant_id
                            .as_deref()
                            .and_then(|id| participant_names.get(id).cloned())
                    })
                    .or_else(|| {
                        normalized_owned(&speaker.provider_label)
                            .map(|label| format!("Speaker {label}"))
                    });
                (speaker.id, display_name)
            })
            .collect::<HashMap<_, _>>();

        let utterances = utterances
            .into_iter()
            .map(|utterance| ClipboardUtterance {
                start_ms: utterance.source_start_ms,
                speaker_name: utterance
                    .session_speaker_id
                    .as_deref()
                    .and_then(|id| speaker_names.get(id))
                    .cloned()
                    .flatten(),
                source_language: utterance.source_language,
                source_text: utterance.source_text,
                translated_language: utterance.translated_language,
                translated_text: utterance.translated_text,
                language_variants: ready_translation_variants(utterance.variants),
            })
            .collect::<Vec<_>>();
        if !utterances.iter().any(|utterance| {
            !utterance.source_text.trim().is_empty()
                || utterance
                    .translated_text
                    .as_deref()
                    .is_some_and(|text| !text.trim().is_empty())
        }) {
            return Err(CoreError::NotFound {
                message: format!("transcript content not found: {session_id}"),
            });
        }

        Ok(export_clipboard_text(&ClipboardTranscript {
            title: normalized_owned(&record.title),
            language_columns: clipboard_language_columns(&profile),
            utterances,
        }))
    }

    /// 导出会话为 zip
    ///
    /// 流程：
    /// 1. 从 immutable capture run 选择事实源：realtime utterances 或 async tokens
    /// 2. 如果 include_audio：按 retention ledger 顺序严格解密全部音频块
    /// 3. 调用 vt-export::export_zip
    /// 4. 写入 output_path
    pub fn export_session_zip(
        &self,
        session_id: String,
        output_path: String,
        options: ExportZipOptions,
    ) -> Result<u64, CoreError> {
        let record =
            self.session_store
                .get_session(&session_id)
                .map_err(|_| CoreError::NotFound {
                    message: format!("session not found: {session_id}"),
                })?;

        let export_data = ExportData {
            title: record.title,
            transcript: export_transcript(self, &session_id)?,
            // The minimal MVP exports captured facts only. It has no automatic
            // summary/polish producer and therefore no synthetic summary field.
            summary: None,
        };

        let export_options = ExportOptions {
            include_audio: options.include_audio,
            include_markdown: options.include_markdown,
            include_srt: options.include_srt,
            include_vtt: options.include_vtt,
            include_txt: options.include_txt,
        };

        // 解密音频（如果需要）
        let audio_bytes: Option<Vec<u8>> = if options.include_audio {
            Some(decrypt_session_audio(self, &session_id)?)
        } else {
            None
        };

        let zip_bytes =
            export_zip(&export_data, &export_options, audio_bytes.as_deref()).map_err(|e| {
                CoreError::InternalError {
                    message: format!("export zip: {e}"),
                }
            })?;

        std::fs::write(&output_path, &zip_bytes).map_err(|e| CoreError::InternalError {
            message: format!("write zip: {e}"),
        })?;

        Ok(zip_bytes.len() as u64)
    }
}

fn normalized_owned(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn clipboard_language_columns(profile: &NotebookCaptureProfile) -> Vec<String> {
    let selected = profile
        .selected_languages
        .iter()
        .filter_map(|language| normalized_owned(language))
        .collect::<Vec<_>>();
    if !selected.is_empty() {
        return selected;
    }

    [&profile.left_language, &profile.right_language]
        .into_iter()
        .filter_map(|language| normalized_owned(language))
        .fold(Vec::new(), |mut columns, language| {
            if !columns
                .iter()
                .any(|column| column.eq_ignore_ascii_case(&language))
            {
                columns.push(language);
            }
            columns
        })
}

fn export_transcript(core: &ZulangueCore, session_id: &str) -> Result<ExportTranscript, CoreError> {
    let run = core
        .notebook_capture_store
        .get_run_for_session(session_id)
        .map_err(|error| CoreError::InternalError {
            message: format!("load capture run for export: {error}"),
        })?;

    if let Some(run) = run {
        let profile: NotebookCaptureProfile = serde_json::from_str(&run.profile_snapshot_json)
            .map_err(|error| CoreError::InternalError {
                message: format!("invalid immutable capture profile snapshot: {error}"),
            })?;
        let utterances = core
            .notebook_capture_store
            .list_utterances(session_id)
            .map_err(|error| CoreError::InternalError {
                message: format!("load realtime utterances for export: {error}"),
            })?;
        if !utterances.is_empty() {
            let utterances = utterances
                .into_iter()
                .map(|utterance| ExportUtterance {
                    source_language: utterance.source_language,
                    source_text: utterance.source_text,
                    source_start_ms: utterance.source_start_ms,
                    source_end_ms: utterance.source_end_ms,
                    translated_language: utterance.translated_language,
                    translated_text: utterance.translated_text,
                    language_variants: ready_translation_variants(utterance.variants),
                })
                .collect();
            return Ok(notebook_capture_export(profile, utterances));
        }
        if run.async_task_state != vt_store::notebook_capture_store::AsyncTaskState::Completed {
            return Ok(notebook_capture_export(profile, Vec::new()));
        }
    }

    let tokens = core
        .session_meta
        .get_tokens(session_id)
        .unwrap_or_default()
        .into_iter()
        .map(|token| ExportToken {
            text: token.text,
            start_ms: token.start_ms,
            end_ms: token.end_ms,
        })
        .collect();
    Ok(ExportTranscript::AsyncTokens(tokens))
}

fn ready_translation_variants(
    variants: Vec<vt_store::notebook_capture_store::RealtimeUtteranceVariant>,
) -> Vec<ExportLanguageVariant> {
    variants
        .into_iter()
        .filter(|variant| {
            variant.role == UtteranceVariantRole::Translation
                && variant.state == UtteranceVariantState::Ready
        })
        .filter_map(|variant| {
            variant.text.map(|text| ExportLanguageVariant {
                language: variant.language,
                text,
            })
        })
        .collect()
}

fn notebook_capture_export(
    profile: NotebookCaptureProfile,
    utterances: Vec<ExportUtterance>,
) -> ExportTranscript {
    if profile.capture_mode == CaptureMode::MultilingualOneWay {
        ExportTranscript::NotebookCaptureLanguageColumns {
            language_columns: profile.selected_languages,
            common_caption_language: profile.common_caption_language,
            utterances,
        }
    } else {
        ExportTranscript::NotebookCapture {
            left_language: profile.left_language,
            right_language: (profile.capture_mode == CaptureMode::TwoWay)
                .then_some(profile.right_language),
            utterances,
        }
    }
}

/// 解密 session 的加密音频，返回**可播放的 WAV 字节流**（带 RIFF 头）。
///
/// The capture run owns format/frame facts; the retention ledger owns ordered
/// encrypted chunk locations. Any mismatch fails the whole requested export.
fn decrypt_session_audio(core: &ZulangueCore, session_id: &str) -> Result<Vec<u8>, CoreError> {
    let run = core
        .notebook_capture_store
        .get_run_for_session(session_id)
        .map_err(|error| CoreError::InternalError {
            message: format!("load capture run for audio export: {error}"),
        })?
        .ok_or_else(|| CoreError::NotFound {
            message: format!("capture audio run not found: {session_id}"),
        })?;
    let key_id = run
        .audio_key_ref
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CoreError::NotFound {
            message: format!("capture audio key not found: {session_id}"),
        })?;
    let sample_rate =
        run.sample_rate
            .filter(|value| *value > 0)
            .ok_or_else(|| CoreError::InternalError {
                message: format!("capture audio sample rate is missing: {session_id}"),
            })?;
    let channels =
        run.channels
            .filter(|value| *value > 0)
            .ok_or_else(|| CoreError::InternalError {
                message: format!("capture audio channel count is missing: {session_id}"),
            })?;
    if run.captured_frames == 0 {
        return Err(CoreError::NotFound {
            message: format!("capture audio is empty: {session_id}"),
        });
    }

    let key = core
        .key_store
        .load_key(key_id)
        .map_err(|error| CoreError::InternalError {
            message: format!("load capture audio key: {error}"),
        })?;
    let chunks = core
        .session_meta
        .list_audio_retention_chunks(session_id)
        .map_err(|error| CoreError::InternalError {
            message: format!("load audio retention ledger: {error}"),
        })?;
    let frames_per_chunk = u64::from(sample_rate).saturating_mul(60);
    let expected_chunk_count = run.captured_frames.div_ceil(frames_per_chunk) as usize;
    if chunks.len() != expected_chunk_count {
        return Err(CoreError::InternalError {
            message: format!(
                "audio retention ledger is incomplete for {session_id}: expected {expected_chunk_count} chunks, found {}",
                chunks.len()
            ),
        });
    }

    use std::io::Read;
    let mut pcm_bytes = Vec::new();
    let bytes_per_frame = usize::from(channels).saturating_mul(4);
    for (index, chunk) in chunks.iter().enumerate() {
        let start_frame = (index as u64).saturating_mul(frames_per_chunk);
        let end_frame = run
            .captured_frames
            .min(start_frame.saturating_add(frames_per_chunk));
        let expected_start_ms = start_frame.saturating_mul(1_000) / u64::from(sample_rate);
        let expected_end_ms =
            (end_frame.saturating_mul(1_000) / u64::from(sample_rate)).max(expected_start_ms + 1);
        if chunk.deleted
            || !chunk.encrypted
            || chunk.start_ms != expected_start_ms
            || chunk.end_ms != expected_end_ms
        {
            return Err(CoreError::InternalError {
                message: format!(
                    "invalid audio retention ledger chunk {} for {session_id}",
                    chunk.chunk_id
                ),
            });
        }
        let path = std::path::Path::new(&chunk.local_path);
        if !path.is_file() {
            return Err(CoreError::NotFound {
                message: format!("audio chunk is missing: {}", path.display()),
            });
        }
        let mut reader = vt_crypto::DecryptReader::new(path, &key).map_err(|error| {
            CoreError::InternalError {
                message: format!("open encrypted audio chunk {}: {error}", chunk.chunk_id),
            }
        })?;
        let mut plaintext = Vec::new();
        reader
            .read_to_end(&mut plaintext)
            .map_err(|error| CoreError::InternalError {
                message: format!("decrypt audio chunk {}: {error}", chunk.chunk_id),
            })?;
        let expected_bytes = usize::try_from(end_frame - start_frame)
            .ok()
            .and_then(|frames| frames.checked_mul(bytes_per_frame))
            .ok_or_else(|| CoreError::InternalError {
                message: "capture audio byte length exceeds platform limits".to_string(),
            })?;
        if plaintext.len() != expected_bytes {
            return Err(CoreError::InternalError {
                message: format!(
                    "audio chunk {} is incomplete: expected {expected_bytes} bytes, found {}",
                    chunk.chunk_id,
                    plaintext.len()
                ),
            });
        }
        pcm_bytes.extend_from_slice(&plaintext);
    }

    let samples = vt_pipeline::recording::bytes_to_f32_samples(&pcm_bytes);
    vt_audio::encode::encode_wav_bytes(&samples, sample_rate, channels).map_err(|error| {
        CoreError::InternalError {
            message: format!("encode capture audio WAV: {error}"),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_core() -> (TempDir, ZulangueCore) {
        let tmp = TempDir::new().unwrap();
        let core = ZulangueCore::new(tmp.path().to_str().unwrap().to_string()).unwrap();
        (tmp, core)
    }

    #[test]
    fn test_export_session_zip_not_found() {
        let (tmp, core) = make_core();
        let output = tmp.path().join("out.zip");
        let result = core.export_session_zip(
            "nonexistent".to_string(),
            output.to_str().unwrap().to_string(),
            ExportZipOptions {
                include_audio: false,
                include_markdown: true,
                include_srt: false,
                include_vtt: false,
                include_txt: false,
            },
        );
        assert!(result.is_err());
    }

    #[test]
    fn clipboard_transcript_requires_a_real_capture_session() {
        let (_tmp, core) = make_core();
        assert!(matches!(
            core.get_session_transcript_clipboard_text("nonexistent".into()),
            Err(CoreError::NotFound { .. })
        ));
    }

    #[test]
    fn test_export_session_zip_after_import() {
        use std::path::PathBuf;
        let (tmp, core) = make_core();

        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("vt-audio/tests/fixtures/test_16k_mono.wav");
        if !fixture.exists() {
            return;
        }

        // 导入音频
        let notebook = core.create_notebook(Some("Export test".into())).unwrap();
        let import = core
            .import_audio_into_notebook(fixture.to_str().unwrap().to_string(), notebook.id)
            .unwrap();

        // 导出 zip（不含音频，避免长测试）
        let output = tmp.path().join("session.zip");
        let bytes_written = core
            .export_session_zip(
                import.session_id,
                output.to_str().unwrap().to_string(),
                ExportZipOptions {
                    include_audio: false,
                    include_markdown: true,
                    include_srt: true,
                    include_vtt: false,
                    include_txt: false,
                },
            )
            .unwrap();

        assert!(bytes_written > 0);
        assert!(output.exists());
        let metadata = std::fs::metadata(&output).unwrap();
        assert_eq!(metadata.len(), bytes_written);
    }

    fn read_zip_entry(zip_bytes: &[u8], name: &str) -> Option<Vec<u8>> {
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip_bytes)).ok()?;
        let mut file = archive.by_name(name).ok()?;
        use std::io::Read;
        let mut buf = Vec::new();
        file.read_to_end(&mut buf).ok()?;
        Some(buf)
    }

    fn seed_session_with_tokens(core: &ZulangueCore, sid: &str, tokens: &[vt_model::Token]) {
        use vt_store::SessionRecord;
        core.session_store
            .insert_session(&SessionRecord {
                id: sid.to_string(),
                title: "seeded".to_string(),
                session_type: "recording".to_string(),
                status: "completed".to_string(),
                duration_ms: 1000,
                created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                deleted_at: None,
            })
            .unwrap();
        core.session_meta.set_tokens(sid, tokens).unwrap();
    }

    fn seed_two_way_capture(core: &ZulangueCore, sid: &str) -> String {
        use vt_model::{Token, TranslationStatus};
        use vt_store::notebook_capture_store::{
            CaptureMode, NewNotebookCaptureRun, NewRealtimeUtterance, NotebookCaptureProfileUpdate,
            RemoteHealth, UtteranceAlignment, UtteranceCompletion, UtteranceVariantState,
        };

        let notebook = core
            .create_notebook(Some("Bilingual export".into()))
            .unwrap();
        let initial = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let profile = core
            .notebook_capture_store
            .update_profile(
                &notebook.id,
                initial.revision,
                &NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: true,
                    capture_mode: CaptureMode::TwoWay,
                    language_a: "en".into(),
                    language_b: "zh".into(),
                    left_language: "en".into(),
                    right_language: "zh".into(),
                    selected_languages: vec!["en".into(), "zh".into()],
                    common_caption_language: None,
                    privacy_level: "standard".into(),
                    send_context_to_soniox: false,
                },
            )
            .unwrap();
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: sid.into(),
                title: "Bilingual facts".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 2_000,
                created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                deleted_at: None,
            })
            .unwrap();
        core.notebook_capture_store
            .create_run(
                &NewNotebookCaptureRun {
                    id: format!("run-{sid}"),
                    notebook_id: notebook.id,
                    session_id: sid.into(),
                    remote_health: RemoteHealth::Connecting,
                    audio_journal_path: format!("/{sid}.journal"),
                    audio_key_ref: format!("key-{sid}"),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        core.notebook_capture_store
            .claim_provider_provenance(
                sid,
                vt_store::notebook_capture_store::CaptureProviderRole::Realtime,
                vt_stt::CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                vt_stt::CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id,
            )
            .unwrap();
        let first_speaker = core
            .notebook_capture_store
            .ensure_session_speaker(sid, 0, "soniox", "1")
            .unwrap();
        for (sequence, source_language, source_text, translated_language, translated_text) in [
            (0, "en", "Realtime source", "zh", "实时原文"),
            (1, "zh", "第二句话", "en", "Second sentence"),
        ] {
            core.notebook_capture_store
                .upsert_utterance(
                    &NewRealtimeUtterance {
                        id: format!("utterance-{sid}-{sequence}"),
                        session_id: sid.into(),
                        sequence,
                        session_speaker_id: (sequence == 0).then(|| first_speaker.id.clone()),
                        source_language: source_language.into(),
                        source_text: source_text.into(),
                        source_start_ms: Some(sequence * 1_000),
                        source_end_ms: Some(sequence * 1_000 + 900),
                        translated_language: None,
                        translated_text: None,
                        completion: UtteranceCompletion::Complete,
                        alignment: UtteranceAlignment::TranslationPending,
                    },
                    None,
                )
                .unwrap();
            core.notebook_capture_store
                .upsert_translation_variant(
                    sid,
                    sequence,
                    translated_language,
                    Some(translated_text),
                    UtteranceVariantState::Ready,
                    Some(UtteranceCompletion::Complete),
                )
                .unwrap();
        }

        // This stale provider payload must never override realtime facts.
        core.session_meta
            .set_tokens(
                sid,
                &[Token {
                    text: "STALE ASYNC TEXT".into(),
                    start_ms: 0,
                    end_ms: 100,
                    is_final: true,
                    language: "en".into(),
                    speaker: None,
                    confidence: 1.0,
                    translation_status: TranslationStatus::None,
                }],
            )
            .unwrap();
        first_speaker.id
    }

    fn seed_multilingual_one_way_capture(core: &ZulangueCore, sid: &str) {
        use vt_store::notebook_capture_store::{
            CaptureMode, NewNotebookCaptureRun, NewRealtimeUtterance, NotebookCaptureProfileUpdate,
            RemoteHealth, UtteranceAlignment, UtteranceCompletion, UtteranceVariantState,
        };

        let notebook = core
            .create_notebook(Some("Multilingual export".into()))
            .unwrap();
        let initial = core
            .notebook_capture_store
            .get_or_create_profile(&notebook.id)
            .unwrap();
        let profile = core
            .notebook_capture_store
            .update_profile(
                &notebook.id,
                initial.revision,
                &NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: true,
                    capture_mode: CaptureMode::MultilingualOneWay,
                    language_a: "en".into(),
                    language_b: "zh".into(),
                    left_language: "en".into(),
                    right_language: "zh".into(),
                    selected_languages: vec!["en".into(), "zh".into(), "th".into()],
                    common_caption_language: None,
                    privacy_level: "standard".into(),
                    send_context_to_soniox: false,
                },
            )
            .unwrap();
        core.session_store
            .insert_session(&vt_store::SessionRecord {
                id: sid.into(),
                title: "Multilingual facts".into(),
                session_type: "recording".into(),
                status: "completed".into(),
                duration_ms: 1_000,
                created_at: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                deleted_at: None,
            })
            .unwrap();
        core.notebook_capture_store
            .create_run(
                &NewNotebookCaptureRun {
                    id: format!("run-{sid}"),
                    notebook_id: notebook.id,
                    session_id: sid.into(),
                    remote_health: RemoteHealth::Connecting,
                    audio_journal_path: format!("/{sid}.journal"),
                    audio_key_ref: format!("key-{sid}"),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        core.notebook_capture_store
            .claim_provider_provenance(
                sid,
                vt_store::notebook_capture_store::CaptureProviderRole::Realtime,
                vt_stt::CURRENT_NOTEBOOK_CAPTURE_ENGINE.provider_id,
                vt_stt::CURRENT_NOTEBOOK_CAPTURE_ENGINE.realtime_model_id,
            )
            .unwrap();
        core.notebook_capture_store
            .upsert_utterance(
                &NewRealtimeUtterance {
                    id: format!("utterance-{sid}-0"),
                    session_id: sid.into(),
                    sequence: 0,
                    session_speaker_id: None,
                    source_language: "th".into(),
                    source_text: "สวัสดี".into(),
                    source_start_ms: Some(0),
                    source_end_ms: Some(900),
                    translated_language: None,
                    translated_text: None,
                    completion: UtteranceCompletion::Complete,
                    alignment: UtteranceAlignment::TranslationPending,
                },
                None,
            )
            .unwrap();
        core.notebook_capture_store
            .upsert_translation_variant(
                sid,
                0,
                "en",
                Some("Hello"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
        core.notebook_capture_store
            .upsert_translation_variant(
                sid,
                0,
                "zh",
                Some("你好"),
                UtteranceVariantState::Ready,
                Some(UtteranceCompletion::Complete),
            )
            .unwrap();
    }

    #[test]
    fn test_export_contains_transcript_without_speaker_labels() {
        use vt_model::{Token, TranslationStatus};
        let (tmp, core) = make_core();

        let tokens = vec![
            Token {
                text: "Hello from Speaker A.".to_string(),
                start_ms: 0,
                end_ms: 1000,
                is_final: true,
                language: "en".to_string(),
                speaker: None,
                confidence: 1.0,
                translation_status: TranslationStatus::None,
            },
            Token {
                text: "Speaker B replies.".to_string(),
                start_ms: 1000,
                end_ms: 2000,
                is_final: true,
                language: "en".to_string(),
                speaker: None,
                confidence: 1.0,
                translation_status: TranslationStatus::None,
            },
        ];
        seed_session_with_tokens(&core, "s-bug-a", &tokens);

        let output = tmp.path().join("out.zip");
        core.export_session_zip(
            "s-bug-a".to_string(),
            output.to_str().unwrap().to_string(),
            ExportZipOptions {
                include_audio: false,
                include_markdown: true,
                include_srt: true,
                include_vtt: false,
                include_txt: true,
            },
        )
        .unwrap();

        let zip_bytes = std::fs::read(&output).unwrap();

        let md = read_zip_entry(&zip_bytes, "transcript.md").unwrap();
        let md = String::from_utf8(md).unwrap();
        assert!(md.contains("Hello from Speaker A."));
        assert!(md.contains("Speaker B replies."));
        assert!(!md.contains("Unknown:"));

        let srt = read_zip_entry(&zip_bytes, "transcript.srt").unwrap();
        let srt = String::from_utf8(srt).unwrap();
        assert!(srt.contains("Hello from Speaker A."));
        assert!(srt.contains("Speaker B replies."));
    }

    #[test]
    fn realtime_export_and_home_preview_use_utterances_not_stale_tokens() {
        let (tmp, core) = make_core();
        let _ = seed_two_way_capture(&core, "capture-facts");

        let output = tmp.path().join("capture-facts.zip");
        core.export_session_zip(
            "capture-facts".into(),
            output.to_string_lossy().into_owned(),
            ExportZipOptions {
                include_audio: false,
                include_markdown: true,
                include_srt: true,
                include_vtt: true,
                include_txt: true,
            },
        )
        .unwrap();

        let zip_bytes = std::fs::read(output).unwrap();
        let markdown =
            String::from_utf8(read_zip_entry(&zip_bytes, "transcript.md").unwrap()).unwrap();
        assert!(markdown.contains("| en | zh |"));
        assert!(markdown.contains("| Realtime source | 实时原文 |"));
        assert!(markdown.contains("| Second sentence | 第二句话 |"));
        assert!(!markdown.contains("STALE ASYNC TEXT"));

        let subtitles =
            String::from_utf8(read_zip_entry(&zip_bytes, "transcript.srt").unwrap()).unwrap();
        assert!(subtitles.contains("Realtime source"));
        assert!(subtitles.contains("第二句话"));
        assert!(!subtitles.contains("实时原文"));
        assert!(!subtitles.contains("Second sentence"));

        let session = core.get_session("capture-facts".into()).unwrap();
        assert!(session.preview.contains("Realtime source"));
        assert!(session.preview.contains("实时原文"));
        assert!(!session.preview.contains("STALE ASYNC TEXT"));

        let utterances = core
            .notebook_capture_store
            .list_utterances("capture-facts")
            .unwrap();
        core.rebuild_capture_search_index("capture-facts", &utterances)
            .unwrap();
        assert_eq!(
            core.search_sessions("Realtime".into(), 10).unwrap()[0].session_id,
            "capture-facts"
        );
        assert_eq!(
            core.search_sessions("实时原文".into(), 10).unwrap()[0].session_id,
            "capture-facts"
        );
        assert!(core.search_sessions("STALE".into(), 10).unwrap().is_empty());
    }

    #[test]
    fn clipboard_transcript_uses_durable_facts_and_manual_speaker_names() {
        let (_tmp, core) = make_core();
        let session_id = "clipboard-facts";
        let speaker_id = seed_two_way_capture(&core, session_id);

        let participant = core
            .notebook_capture_store
            .create_participant("Cross-session host")
            .unwrap();
        core.notebook_capture_store
            .link_session_speaker(&speaker_id, &participant.id)
            .unwrap();
        core.notebook_capture_store
            .rename_session_speaker(&speaker_id, Some("Session host"))
            .unwrap();

        let text = core
            .get_session_transcript_clipboard_text(session_id.into())
            .unwrap();
        assert!(text.starts_with(
            "Bilingual facts\n\n[00:00:00.000] Session host\nen: Realtime source\nzh: 实时原文"
        ));
        assert!(text.contains("[00:00:01.000]\nen: Second sentence\nzh: 第二句话"));
        assert!(!text.contains("STALE ASYNC TEXT"));
        assert!(!text.contains("---"));

        core.notebook_capture_store
            .rename_session_speaker(&speaker_id, None)
            .unwrap();
        let text = core
            .get_session_transcript_clipboard_text(session_id.into())
            .unwrap();
        assert!(text.contains("[00:00:00.000] Cross-session host"));
    }

    #[test]
    fn multilingual_export_preserves_every_ready_language_column() {
        let (tmp, core) = make_core();
        seed_multilingual_one_way_capture(&core, "multilingual-facts");

        let output = tmp.path().join("multilingual-facts.zip");
        core.export_session_zip(
            "multilingual-facts".into(),
            output.to_string_lossy().into_owned(),
            ExportZipOptions {
                include_audio: false,
                include_markdown: true,
                include_srt: true,
                include_vtt: false,
                include_txt: true,
            },
        )
        .unwrap();

        let zip_bytes = std::fs::read(output).unwrap();
        let markdown =
            String::from_utf8(read_zip_entry(&zip_bytes, "transcript.md").unwrap()).unwrap();
        assert!(!markdown.contains("公共字幕"));
        assert!(markdown.contains("| en | zh | th |"));
        assert!(markdown.contains("| Hello | 你好 | สวัสดี |"));

        let text =
            String::from_utf8(read_zip_entry(&zip_bytes, "transcript.txt").unwrap()).unwrap();
        assert!(text.contains("en\tzh\tth"));
        assert!(text.contains("Hello\t你好\tสวัสดี"));

        let subtitles =
            String::from_utf8(read_zip_entry(&zip_bytes, "transcript.srt").unwrap()).unwrap();
        assert!(subtitles.contains("สวัสดี"));
        assert!(!subtitles.contains("Hello"));
    }

    #[test]
    fn clipboard_transcript_preserves_selected_multilingual_order_without_empty_lanes() {
        let (_tmp, core) = make_core();
        seed_multilingual_one_way_capture(&core, "clipboard-multilingual");

        let text = core
            .get_session_transcript_clipboard_text("clipboard-multilingual".into())
            .unwrap();
        assert_eq!(
            text,
            "Multilingual facts\n\n[00:00:00.000]\nen: Hello\nzh: 你好\nth: สวัสดี"
        );
    }

    fn write_long_audio_fixture(path: &std::path::Path) {
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 100,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        };
        let mut writer = hound::WavWriter::create(path, spec).unwrap();
        for frame in 0..6_100 {
            writer.write_sample((frame % 100) as f32 / 100.0).unwrap();
        }
        writer.finalize().unwrap();
    }

    fn import_long_audio(core: &ZulangueCore, tmp: &TempDir) -> String {
        let source = tmp.path().join("sixty-one-seconds.wav");
        write_long_audio_fixture(&source);
        let notebook = core.create_notebook(Some("Long audio".into())).unwrap();
        core.import_audio_into_notebook(source.to_string_lossy().into_owned(), notebook.id)
            .unwrap()
            .session_id
    }

    #[test]
    fn audio_export_decrypts_every_ledger_chunk_beyond_sixty_seconds() {
        let (tmp, core) = make_core();
        let session_id = import_long_audio(&core, &tmp);
        let chunks = core
            .session_meta
            .list_audio_retention_chunks(&session_id)
            .unwrap();
        assert_eq!(chunks.len(), 2, "61 seconds must materialize two chunks");

        let output = tmp.path().join("long-audio.zip");
        core.export_session_zip(
            session_id,
            output.to_string_lossy().into_owned(),
            ExportZipOptions {
                include_audio: true,
                include_markdown: false,
                include_srt: false,
                include_vtt: false,
                include_txt: false,
            },
        )
        .unwrap();

        let wav = read_zip_entry(&std::fs::read(output).unwrap(), "audio.wav").unwrap();
        let reader = hound::WavReader::new(std::io::Cursor::new(wav)).unwrap();
        assert_eq!(reader.spec().sample_rate, 100);
        assert_eq!(reader.duration(), 6_100);
    }

    #[test]
    fn requested_audio_export_fails_closed_for_missing_or_corrupt_chunk() {
        let (tmp, core) = make_core();
        let session_id = import_long_audio(&core, &tmp);
        let chunks = core
            .session_meta
            .list_audio_retention_chunks(&session_id)
            .unwrap();
        std::fs::remove_file(&chunks[1].local_path).unwrap();
        let missing_output = tmp.path().join("missing.zip");
        assert!(core
            .export_session_zip(
                session_id.clone(),
                missing_output.to_string_lossy().into_owned(),
                ExportZipOptions {
                    include_audio: true,
                    include_markdown: false,
                    include_srt: false,
                    include_vtt: false,
                    include_txt: false,
                },
            )
            .is_err());
        assert!(!missing_output.exists());

        let second_session = import_long_audio(&core, &tmp);
        let corrupt_chunk = core
            .session_meta
            .list_audio_retention_chunks(&second_session)
            .unwrap()
            .remove(0);
        let mut ciphertext = std::fs::read(&corrupt_chunk.local_path).unwrap();
        let last = ciphertext.len() - 1;
        ciphertext[last] ^= 1;
        std::fs::write(&corrupt_chunk.local_path, ciphertext).unwrap();
        let corrupt_output = tmp.path().join("corrupt.zip");
        assert!(core
            .export_session_zip(
                second_session,
                corrupt_output.to_string_lossy().into_owned(),
                ExportZipOptions {
                    include_audio: true,
                    include_markdown: false,
                    include_srt: false,
                    include_vtt: false,
                    include_txt: false,
                },
            )
            .is_err());
        assert!(!corrupt_output.exists());
    }

    // ===================== Exported audio.wav validation =====================

    /// Helper: 从 zip 取 audio.wav,用 hound 解 spec。
    /// 返回 (format_tag, channels, sample_rate, bits_per_sample, data_len)
    /// format_tag: 1=PCM int, 3=IEEE float
    fn read_wav_fmt_from_zip(zip_bytes: &[u8]) -> (u16, u16, u32, u16, usize) {
        let wav = read_zip_entry(zip_bytes, "audio.wav").expect("audio.wav must be in zip");
        assert!(wav.len() > 44, "WAV too short: {}", wav.len());

        // 用 hound 的 WavReader 做可靠解析(上面 windows(4) 扫 "fmt"/"data"
        // 会在音频数据区意外撞到这些字节,返回假位置)。
        let reader = hound::WavReader::new(std::io::Cursor::new(&wav))
            .expect("hound must parse exported WAV");
        let spec = reader.spec();
        let format_tag: u16 = match spec.sample_format {
            hound::SampleFormat::Int => 1,
            hound::SampleFormat::Float => 3,
        };
        // data_len = frames × block_align
        let data_len = reader.duration() as usize
            * spec.channels as usize
            * (spec.bits_per_sample / 8) as usize;
        (
            format_tag,
            spec.channels,
            spec.sample_rate,
            spec.bits_per_sample,
            data_len,
        )
    }

    #[test]
    fn test_export_audio_has_valid_wav_header() {
        use std::path::PathBuf;
        let (tmp, core) = make_core();

        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("vt-audio/tests/fixtures/test_16k_mono.wav");
        if !fixture.exists() {
            return;
        }

        let notebook = core.create_notebook(Some("Export test".into())).unwrap();
        let import = core
            .import_audio_into_notebook(fixture.to_str().unwrap().to_string(), notebook.id)
            .unwrap();

        let output = tmp.path().join("with_audio.zip");
        core.export_session_zip(
            import.session_id,
            output.to_str().unwrap().to_string(),
            ExportZipOptions {
                include_audio: true,
                include_markdown: false,
                include_srt: false,
                include_vtt: false,
                include_txt: false,
            },
        )
        .unwrap();

        let zip_bytes = std::fs::read(&output).unwrap();
        let (fmt_tag, ch, sr, bits, data_len) = read_wav_fmt_from_zip(&zip_bytes);
        // IEEE float (3) or PCM (1). We use IEEE float f32.
        assert!(fmt_tag == 3 || fmt_tag == 1, "fmt_tag = {fmt_tag}");
        assert_eq!(ch, 1, "16k_mono fixture must map to mono in export");
        assert_eq!(sr, 16000, "16k_mono fixture must stay 16kHz");
        assert_eq!(bits, 32, "f32 PCM = 32 bits/sample");
        assert!(data_len > 0);
    }

    /// 导入非 16kHz 或非 mono 音频时，导出 WAV 头必须保留真实
    /// sample_rate 和 channels。
    #[test]
    fn test_export_audio_preserves_sample_rate_and_channels_from_import() {
        use std::path::PathBuf;
        let (tmp, core) = make_core();

        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("vt-audio/tests/fixtures/test_48k_stereo.wav");
        if !fixture.exists() {
            return;
        }

        let notebook = core.create_notebook(Some("Export test".into())).unwrap();
        let import = core
            .import_audio_into_notebook(fixture.to_str().unwrap().to_string(), notebook.id)
            .unwrap();
        assert_eq!(import.sample_rate, 48000, "import must detect 48kHz");
        assert_eq!(import.channels, 2, "import must detect stereo");

        let output = tmp.path().join("with_audio.zip");
        core.export_session_zip(
            import.session_id,
            output.to_str().unwrap().to_string(),
            ExportZipOptions {
                include_audio: true,
                include_markdown: false,
                include_srt: false,
                include_vtt: false,
                include_txt: false,
            },
        )
        .unwrap();

        let zip_bytes = std::fs::read(&output).unwrap();
        let (_, ch, sr, _, _) = read_wav_fmt_from_zip(&zip_bytes);
        assert_eq!(
            sr, 48000,
            "exported WAV sample_rate must match import (was hardcoded 16000)"
        );
        assert_eq!(
            ch, 2,
            "exported WAV channels must match import (was hardcoded 1 → mono chipmunks)"
        );
    }
}
