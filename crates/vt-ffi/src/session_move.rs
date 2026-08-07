//! Moving one recording, with everything it owns, into another Notebook.
//!
//! A session owns four resources: its realtime transcript, its async
//! transcript, its manual note, and its audio. All four follow the session,
//! because they are one meeting's record — splitting them across Notebooks
//! would leave a section that cannot be read next to the audio it describes.
//!
//! Audio needs no work: since encrypted audio lives in `audio/<session_id>/`,
//! no Notebook owns it. The other three are sections inside per-tab documents,
//! so each one is lifted out of the source Notebook's document and spliced into
//! the target's, positioned by **recording time** so a Notebook always reads in
//! the order its meetings happened.
//!
//! ## Order of operations
//!
//! Write the target, flip the pointers, then clear the source. Every
//! intermediate state therefore still holds the content: a crash between
//! phases can duplicate a section, never lose one, and both the copy and the
//! clear are idempotent so a replay converges. The single authoritative
//! moment is the SQLite commit in the middle.

use vt_store::transcript_projection::UtteranceBlock;
use vt_store::{BuiltinNotebookTab, EditOp, SessionMovePlan, SessionMoveTarget};

use crate::editor_api::TextRange;
use crate::notebook_capture_api::{legacy_session_section_range, store_error};
use crate::{CoreError, ZulangueCore};

/// A flat-text section lifted out of a document: its characters plus the marks
/// that make it a section — session ownership, heading, any user styling.
struct FlatSection {
    text: String,
    marks: Vec<FlatMark>,
}

struct FlatMark {
    /// Offset from the start of the section, in characters.
    pos: usize,
    len: usize,
    key: String,
    value_json: String,
}

impl ZulangueCore {
    /// Moves `session_id` into `target_notebook_id`, carrying its transcripts,
    /// its note, and the annotations the user wrote alongside them.
    pub(crate) fn move_session_to_notebook_inner(
        &self,
        session_id: &str,
        target_notebook_id: &str,
    ) -> Result<(), CoreError> {
        let plan = self
            .notebook_store
            .plan_session_move(session_id, target_notebook_id)
            .map_err(store_error)?;
        let _mutation_guard = crate::editor_api::editor_document_mutation_guard();

        // Phase 1 and 2 are undone together on failure: until the pointers
        // flip, the source Notebook is still the whole truth, so a half-copied
        // move must leave nothing of this session behind in the target.
        let copied = (|| -> Result<(), CoreError> {
            for target in &plan.targets {
                self.copy_section_into_target(&plan, target)?;
            }
            // The one authoritative instant. Re-validates the plan under the
            // write lock, so a capture or purge that started while the copies
            // ran refuses the move with every document still readable from the
            // Notebook it came from.
            self.notebook_store
                .commit_session_move(&plan)
                .map_err(store_error)
        })();
        if let Err(error) = copied {
            self.roll_back_copied_sections(&plan);
            return Err(error);
        }

        for target in &plan.targets {
            self.clear_section_from_source(&plan, target)?;
        }
        Ok(())
    }

    /// Removes whatever the copy phase managed to write into the target. Best
    /// effort by design: the caller is already returning the original failure,
    /// and a rollback that cannot finish leaves a duplicate section rather than
    /// a missing one — the same direction every phase of this move fails in.
    fn roll_back_copied_sections(&self, plan: &SessionMovePlan) {
        for target in &plan.targets {
            let undo = match target.builtin_kind {
                BuiltinNotebookTab::RealtimeTranscript => self
                    .with_transcript(&target.target_doc_id, |projection| {
                        projection
                            .remove_session_slice(&plan.session_id)
                            .map_err(store_error)
                    })
                    .map(|_| ())
                    .and_then(|_| self.persist_block_document(&target.target_doc_id)),
                BuiltinNotebookTab::AsyncTranscript | BuiltinNotebookTab::ManualNote => {
                    self.remove_flat_section(&target.target_doc_id, &plan.session_id)
                }
            };
            if let Err(error) = undo {
                tracing::warn!(
                    session_id = plan.session_id,
                    doc_id = target.target_doc_id,
                    %error,
                    "roll back a partially copied session section"
                );
            }
        }
    }

    fn copy_section_into_target(
        &self,
        plan: &SessionMovePlan,
        target: &SessionMoveTarget,
    ) -> Result<(), CoreError> {
        match target.builtin_kind {
            BuiltinNotebookTab::RealtimeTranscript => self.copy_transcript_slice(plan, target),
            BuiltinNotebookTab::AsyncTranscript | BuiltinNotebookTab::ManualNote => {
                self.copy_flat_section(plan, target)
            }
        }
    }

    fn clear_section_from_source(
        &self,
        plan: &SessionMovePlan,
        target: &SessionMoveTarget,
    ) -> Result<(), CoreError> {
        match target.builtin_kind {
            BuiltinNotebookTab::RealtimeTranscript => {
                self.open_transcript_block_document(&target.source_doc_id)?;
                let removed = self.with_transcript(&target.source_doc_id, |projection| {
                    projection
                        .remove_session_slice(&plan.session_id)
                        .map_err(store_error)
                })?;
                if removed == 0 {
                    return Ok(());
                }
                self.persist_block_document(&target.source_doc_id)
            }
            BuiltinNotebookTab::AsyncTranscript | BuiltinNotebookTab::ManualNote => {
                self.remove_flat_section(&target.source_doc_id, &plan.session_id)
            }
        }
    }

    /// Deletes a session's contiguous flat-text section from one document.
    /// Idempotent: an absent section is a no-op, so both the clear phase and a
    /// rollback can run twice without touching a neighbouring section.
    fn remove_flat_section(&self, doc_id: &str, session_id: &str) -> Result<(), CoreError> {
        crate::editor_api::open_editor_session_strict(&self.data_dir, &self.editor_bridge, doc_id)?;
        let delta = self.editor_bridge.get_delta(doc_id).map_err(store_error)?;
        let Some(range) = legacy_session_section_range(&delta, session_id)? else {
            return Ok(());
        };
        if range.len == 0 {
            return Ok(());
        }
        self.editor_bridge
            .apply(
                doc_id,
                EditOp::Delete {
                    pos: range.pos,
                    len: range.len,
                },
            )
            .map_err(store_error)?;
        crate::editor_api::flush_snapshot_to_disk_result(
            &self.data_dir,
            &self.editor_bridge,
            doc_id,
        )
        .map_err(|message| CoreError::InternalError { message })
    }

    /// The realtime transcript is a block document, so the section is the
    /// session's contiguous block slice — its machine blocks together with the
    /// annotations written among and after them.
    fn copy_transcript_slice(
        &self,
        plan: &SessionMovePlan,
        target: &SessionMoveTarget,
    ) -> Result<(), CoreError> {
        self.open_transcript_block_document(&target.source_doc_id)?;
        let slice = self.with_transcript(&target.source_doc_id, |projection| {
            projection
                .session_slice(&plan.session_id)
                .map_err(store_error)
        })?;
        if slice.is_empty() {
            return Ok(());
        }

        self.open_transcript_block_document(&target.target_doc_id)?;
        let inserted = self.with_transcript(&target.target_doc_id, |projection| {
            let anchor = first_later_capture_block(&projection.blocks(), &target.later_session_ids);
            projection
                .splice_session_slice(&slice, anchor.as_deref())
                .map_err(store_error)
        })?;
        if inserted == 0 {
            return Ok(());
        }
        self.persist_block_document(&target.target_doc_id)
    }

    /// The async transcript and the manual note are flat text, so the section
    /// is the contiguous run of characters marked with this session's id.
    fn copy_flat_section(
        &self,
        plan: &SessionMovePlan,
        target: &SessionMoveTarget,
    ) -> Result<(), CoreError> {
        crate::editor_api::open_editor_session_strict(
            &self.data_dir,
            &self.editor_bridge,
            &target.source_doc_id,
        )?;
        let source_delta = self
            .editor_bridge
            .get_delta(&target.source_doc_id)
            .map_err(store_error)?;
        let Some(range) = legacy_session_section_range(&source_delta, &plan.session_id)? else {
            return Ok(());
        };
        if range.len == 0 {
            return Ok(());
        }
        let section = flat_section_from_delta(&source_delta, range)?;

        crate::editor_api::open_editor_session_strict(
            &self.data_dir,
            &self.editor_bridge,
            &target.target_doc_id,
        )?;
        let target_delta = self
            .editor_bridge
            .get_delta(&target.target_doc_id)
            .map_err(store_error)?;
        // Idempotent replay: the section is already here, so a crash between
        // copying and clearing must not append it a second time.
        if legacy_session_section_range(&target_delta, &plan.session_id)?
            .is_some_and(|existing| existing.len > 0)
        {
            return Ok(());
        }

        let insert_pos = match flat_anchor_position(&target_delta, &target.later_session_ids)? {
            Some(position) => position,
            None => self
                .editor_bridge
                .get_content(&target.target_doc_id)
                .map_err(store_error)?
                .chars()
                .count(),
        };
        self.editor_bridge
            .apply(
                &target.target_doc_id,
                EditOp::Insert {
                    pos: insert_pos,
                    text: section.text,
                },
            )
            .map_err(store_error)?;
        for mark in section.marks {
            self.editor_bridge
                .apply(
                    &target.target_doc_id,
                    EditOp::Mark {
                        pos: insert_pos + mark.pos,
                        len: mark.len,
                        key: mark.key,
                        value_json: mark.value_json,
                    },
                )
                .map_err(store_error)?;
        }
        crate::editor_api::flush_snapshot_to_disk_result(
            &self.data_dir,
            &self.editor_bridge,
            &target.target_doc_id,
        )
        .map_err(|message| CoreError::InternalError { message })
    }
}

/// The block the moved slice must land in front of: the first block belonging
/// to a session recorded later than the moved one. Blocks are in document
/// order and sections are in recording order, so the first hit is the earliest
/// later section — and anchoring on its *capture* block leaves the previous
/// section's trailing annotations where they belong.
fn first_later_capture_block(
    blocks: &[UtteranceBlock],
    later_session_ids: &[String],
) -> Option<String> {
    blocks
        .iter()
        .find(|block| {
            later_session_ids
                .iter()
                .any(|session_id| block.owner == format!("capture:{session_id}"))
        })
        .map(|block| block.id.clone())
}

/// Where the moved section starts in a flat-text document: the start of the
/// earliest later section that actually has content. A section can own a
/// projection row and still be empty — an async transcript that was never
/// produced — so the first candidate that resolves wins.
fn flat_anchor_position(
    delta_json: &str,
    later_session_ids: &[String],
) -> Result<Option<usize>, CoreError> {
    for session_id in later_session_ids {
        if let Some(range) = legacy_session_section_range(delta_json, session_id)? {
            if range.len > 0 {
                return Ok(Some(range.pos));
            }
        }
    }
    Ok(None)
}

/// Lifts `range` out of an editor Delta, keeping every attribute run intact so
/// the section arrives in the target document styled and owned exactly as it
/// left. Offsets are in characters, matching the Delta walk that produced the
/// range.
fn flat_section_from_delta(delta_json: &str, range: TextRange) -> Result<FlatSection, CoreError> {
    let value: serde_json::Value =
        serde_json::from_str(delta_json).map_err(|error| CoreError::ValidationFailed {
            message: format!("invalid editor Delta JSON: {error}"),
        })?;
    let segments = value
        .as_array()
        .ok_or_else(|| CoreError::ValidationFailed {
            message: "editor Delta must be an array".to_string(),
        })?;

    let section_end = range.pos.saturating_add(range.len);
    let mut text = String::new();
    let mut marks = Vec::new();
    let mut cursor = 0_usize;
    for segment in segments {
        let segment_text = segment
            .get("insert")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| CoreError::ValidationFailed {
                message: "editor Delta text insert must be a string".to_string(),
            })?;
        let chars: Vec<char> = segment_text.chars().collect();
        let segment_start = cursor;
        let segment_end = cursor + chars.len();
        cursor = segment_end;
        if segment_end <= range.pos || segment_start >= section_end {
            continue;
        }

        let take_from = range.pos.saturating_sub(segment_start);
        let take_to = chars.len().min(section_end - segment_start);
        let taken: String = chars[take_from..take_to].iter().collect();
        let mark_pos = text.chars().count();
        let mark_len = take_to - take_from;
        text.push_str(&taken);

        if let Some(attributes) = segment
            .get("attributes")
            .filter(|attributes| !attributes.is_null())
            .and_then(serde_json::Value::as_object)
        {
            for (key, value) in attributes {
                marks.push(FlatMark {
                    pos: mark_pos,
                    len: mark_len,
                    key: key.clone(),
                    value_json: value.to_string(),
                });
            }
        }
    }

    Ok(FlatSection { text, marks })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn delta(segments: &[(&str, Option<&str>)]) -> String {
        let items: Vec<serde_json::Value> = segments
            .iter()
            .map(|(text, session)| match session {
                Some(session) => serde_json::json!({
                    "insert": text,
                    "attributes": { "session_id": session },
                }),
                None => serde_json::json!({ "insert": text }),
            })
            .collect();
        serde_json::to_string(&items).unwrap()
    }

    #[test]
    fn a_lifted_section_keeps_its_text_and_every_attribute_run() {
        let source = delta(&[
            ("before", None),
            ("alpha", Some("s1")),
            ("beta", Some("s1")),
            ("after", Some("s2")),
        ]);
        let range = legacy_session_section_range(&source, "s1")
            .unwrap()
            .unwrap();

        let section = flat_section_from_delta(&source, range).unwrap();

        assert_eq!(section.text, "alphabeta");
        let owned: Vec<_> = section
            .marks
            .iter()
            .filter(|mark| mark.key == "session_id")
            .map(|mark| (mark.pos, mark.len, mark.value_json.as_str()))
            .collect();
        assert_eq!(owned, vec![(0, 5, "\"s1\""), (5, 4, "\"s1\"")]);
    }

    #[test]
    fn lifting_preserves_styling_marks_alongside_ownership() {
        let source = serde_json::to_string(&vec![
            serde_json::json!({
                "insert": "bolded",
                "attributes": { "session_id": "s1", "bold": true },
            }),
            serde_json::json!({ "insert": "plain", "attributes": { "session_id": "s1" } }),
        ])
        .unwrap();
        let range = legacy_session_section_range(&source, "s1")
            .unwrap()
            .unwrap();

        let section = flat_section_from_delta(&source, range).unwrap();

        assert_eq!(section.text, "boldedplain");
        assert!(
            section
                .marks
                .iter()
                .any(|mark| mark.key == "bold" && mark.pos == 0 && mark.len == 6),
            "user styling must survive the move"
        );
    }

    #[test]
    fn a_section_is_lifted_by_characters_not_bytes() {
        let source = delta(&[("前言", None), ("会议记录", Some("s1")), ("尾", None)]);
        let range = legacy_session_section_range(&source, "s1")
            .unwrap()
            .unwrap();

        let section = flat_section_from_delta(&source, range).unwrap();

        assert_eq!(section.text, "会议记录");
        assert_eq!(section.marks[0].pos, 0);
        assert_eq!(section.marks[0].len, 4);
    }

    #[test]
    fn the_anchor_is_the_earliest_later_section_that_has_content() {
        let target = delta(&[("march", Some("march-session"))]);

        // "february-empty" owns a projection row but never produced content,
        // so the anchor falls through to the next later section.
        let anchor = flat_anchor_position(
            &target,
            &["february-empty".to_string(), "march-session".to_string()],
        )
        .unwrap();

        assert_eq!(anchor, Some(0));
    }

    #[test]
    fn no_later_section_means_append() {
        let target = delta(&[("january", Some("january-session"))]);

        assert_eq!(flat_anchor_position(&target, &[]).unwrap(), None);
        assert_eq!(
            flat_anchor_position(&target, &["never-projected".to_string()]).unwrap(),
            None
        );
    }

    #[test]
    fn the_transcript_anchor_skips_the_previous_sections_trailing_annotation() {
        let blocks = vec![
            UtteranceBlock {
                id: "early-a".into(),
                owner: "capture:early".into(),
                text: String::new(),
                lanes: Default::default(),
            },
            UtteranceBlock {
                id: "early-note".into(),
                owner: "user".into(),
                text: String::new(),
                lanes: Default::default(),
            },
            UtteranceBlock {
                id: "late-a".into(),
                owner: "capture:late".into(),
                text: String::new(),
                lanes: Default::default(),
            },
        ];

        let anchor = first_later_capture_block(&blocks, &["late".to_string()]);

        assert_eq!(
            anchor.as_deref(),
            Some("late-a"),
            "the earlier session keeps the annotation written after it"
        );
        assert_eq!(first_later_capture_block(&blocks, &[]), None);
    }
}
