//! Marks: the listener's own record of which moments mattered.
//!
//! A mark is not a note in a document. It is a point on capture time, stamped
//! while the room is still talking, that later resolves into a passage of
//! transcript. The listener presses one key and keeps listening; everything
//! else about the mark is derived afterward.
//!
//! The one rule that shapes this module: **a mark reaches backward.** Nobody
//! knows a passage mattered until after hearing it, so the interesting range
//! sits behind the keypress, not ahead of it. The range math lives in pure
//! functions here so it can be tested against transcript shapes without a
//! database, and so the FFI layer has nothing to reimplement.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension};

/// A mark as stored: a point in capture time, a resolved backward reach, and
/// whatever the listener typed about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionMark {
    pub id: String,
    pub session_id: String,
    /// When the key went down, in capture milliseconds.
    pub at_ms: u64,
    /// Where the marked passage begins. Always `<= at_ms`.
    pub start_ms: u64,
    /// Where it ends, or `None` while the trailing edge is still "whatever
    /// utterance encloses `at_ms`" — the sentence was unfinished at keypress.
    pub end_ms: Option<u64>,
    /// The listener's own words. Nothing regenerates this.
    pub note: String,
    pub created_at: String,
    pub updated_at: String,
}

/// One transcript row reduced to what range math needs.
///
/// Rows whose provider never supplied timestamps cannot participate; the
/// caller drops them rather than guessing, and the resolver falls back to its
/// fixed reach.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkAnchor {
    pub start_ms: u64,
    pub end_ms: u64,
}

/// How far back a fresh mark reaches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkLookback {
    /// Hard ceiling on the reach. A mark never swallows more than this.
    pub max_ms: u64,
    /// Silence at least this long reads as the start of a passage.
    pub pause_ms: u64,
}

impl Default for MarkLookback {
    /// Thirty seconds is about as far back as a listener can still say what
    /// was being discussed; the pause threshold is long enough to survive the
    /// gaps inside one speaker's sentence and short enough to catch a handoff.
    fn default() -> Self {
        Self {
            max_ms: 30_000,
            pause_ms: 1_200,
        }
    }
}

/// Where a fresh mark starts, given the transcript behind it.
///
/// Walks back from the keypress through contiguous speech and stops at the
/// first real pause, so the mark lands on a passage rather than on an
/// arbitrary stopwatch offset. With no timed transcript to walk, it falls back
/// to the fixed reach — a worse guess, but never a wrong one about content.
pub fn resolve_mark_start(anchors: &[MarkAnchor], at_ms: u64, lookback: MarkLookback) -> u64 {
    let floor = at_ms.saturating_sub(lookback.max_ms);

    // Only rows that actually overlap the reach can bound it. `end_ms >= floor`
    // keeps a row that began before the window but is still being spoken
    // inside it.
    let mut window: Vec<MarkAnchor> = anchors
        .iter()
        .copied()
        .filter(|a| a.start_ms <= at_ms && a.end_ms >= floor)
        .collect();
    window.sort_by_key(|a| (a.start_ms, a.end_ms));

    let Some(last) = window.last().copied() else {
        return floor;
    };

    let mut start = last.start_ms;
    for pair in window.windows(2).rev() {
        let (previous, current) = (pair[0], pair[1]);
        if current.start_ms.saturating_sub(previous.end_ms) >= lookback.pause_ms {
            break;
        }
        start = previous.start_ms;
    }
    start.max(floor)
}

/// Where a mark ends.
///
/// An explicit end wins — that is the listener having dragged the boundary. An
/// unset end means the mark was pressed mid-sentence, so it extends to the end
/// of whatever utterance encloses the keypress and settles once that utterance
/// finalizes.
pub fn resolve_mark_end(mark: &SessionMark, anchors: &[MarkAnchor]) -> u64 {
    if let Some(end_ms) = mark.end_ms {
        return end_ms.max(mark.start_ms);
    }
    anchors
        .iter()
        .filter(|a| a.start_ms <= mark.at_ms && a.end_ms >= mark.at_ms)
        .map(|a| a.end_ms)
        .max()
        .unwrap_or(mark.at_ms)
        .max(mark.at_ms)
}

/// Whether a transcript row falls inside a mark's resolved passage.
///
/// Overlap, not containment: a row straddling either boundary is part of what
/// the listener marked, and dropping it would cut a sentence in half.
pub fn anchor_is_in_mark(anchor: MarkAnchor, start_ms: u64, end_ms: u64) -> bool {
    anchor.start_ms <= end_ms && anchor.end_ms >= start_ms
}

pub struct SessionMarkStore {
    conn: Mutex<Connection>,
}

impl SessionMarkStore {
    pub fn new(db_path: &Path) -> Result<Self, SessionMarkError> {
        let conn = Connection::open(db_path)?;
        crate::migration::run_migrations(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// Records a mark whose backward reach the caller has already resolved.
    ///
    /// Resolution stays outside the store so the keypress path can compute it
    /// from transcript it already holds in memory, without a second read.
    pub fn create(
        &self,
        id: &str,
        session_id: &str,
        at_ms: u64,
        start_ms: u64,
    ) -> Result<SessionMark, SessionMarkError> {
        require_nonempty("id", id)?;
        require_nonempty("session_id", session_id)?;
        if start_ms > at_ms {
            return Err(SessionMarkError::InvalidRange {
                start_ms,
                end_ms: at_ms,
            });
        }
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO session_marks
                 (id, session_id, at_ms, start_ms, end_ms, note, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, NULL, '', datetime('now'), datetime('now'))",
            rusqlite::params![id, session_id, at_ms as i64, start_ms as i64],
        )?;
        self.get_locked(&conn, id)
    }

    /// Marks for one session in capture order. Soft-deleted rows stay hidden.
    pub fn list(&self, session_id: &str) -> Result<Vec<SessionMark>, SessionMarkError> {
        require_nonempty("session_id", session_id)?;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, session_id, at_ms, start_ms, end_ms, note, created_at, updated_at
             FROM session_marks
             WHERE session_id = ?1 AND deleted_at IS NULL
             ORDER BY at_ms, id",
        )?;
        let rows = stmt
            .query_map([session_id], row_to_mark)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn get(&self, id: &str) -> Result<SessionMark, SessionMarkError> {
        let conn = self.conn.lock().unwrap();
        self.get_locked(&conn, id)
    }

    /// Replaces the listener's own text.
    ///
    /// Kept apart from boundary edits: this is the one field that cannot be
    /// recomputed, so it never rides along with a change that can.
    pub fn set_note(&self, id: &str, note: &str) -> Result<SessionMark, SessionMarkError> {
        let conn = self.conn.lock().unwrap();
        let changed = conn.execute(
            "UPDATE session_marks
             SET note = ?2, updated_at = datetime('now')
             WHERE id = ?1 AND deleted_at IS NULL",
            rusqlite::params![id, note],
        )?;
        if changed == 0 {
            return Err(SessionMarkError::NotFound(id.to_string()));
        }
        self.get_locked(&conn, id)
    }

    /// Moves the passage boundaries after the listener drags them.
    ///
    /// Dragging pins both edges: an end that was tracking the enclosing
    /// utterance stops tracking, because the listener has now said where it
    /// ends. `at_ms` never moves — it is the historical fact of the keypress,
    /// and the range may legitimately no longer contain it.
    pub fn set_bounds(
        &self,
        id: &str,
        start_ms: u64,
        end_ms: u64,
    ) -> Result<SessionMark, SessionMarkError> {
        if end_ms < start_ms {
            return Err(SessionMarkError::InvalidRange { start_ms, end_ms });
        }
        let conn = self.conn.lock().unwrap();
        let at_ms: i64 = conn
            .query_row(
                "SELECT at_ms FROM session_marks WHERE id = ?1 AND deleted_at IS NULL",
                [id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or_else(|| SessionMarkError::NotFound(id.to_string()))?;
        // The stored CHECK keeps start_ms behind the keypress; a listener
        // dragging the leading edge forward past it would violate that, so the
        // keypress instant travels with it and the mark stays well-formed.
        let anchored_at = (at_ms as u64).max(start_ms);
        conn.execute(
            "UPDATE session_marks
             SET at_ms = ?2, start_ms = ?3, end_ms = ?4, updated_at = datetime('now')
             WHERE id = ?1 AND deleted_at IS NULL",
            rusqlite::params![id, anchored_at as i64, start_ms as i64, end_ms as i64],
        )?;
        self.get_locked(&conn, id)
    }

    /// Soft-deletes a mark. The row survives so a later sync can carry the
    /// removal, and so an accidental press is undoable.
    pub fn delete(&self, id: &str) -> Result<(), SessionMarkError> {
        let conn = self.conn.lock().unwrap();
        let changed = conn.execute(
            "UPDATE session_marks
             SET deleted_at = datetime('now'), updated_at = datetime('now')
             WHERE id = ?1 AND deleted_at IS NULL",
            [id],
        )?;
        if changed == 0 {
            return Err(SessionMarkError::NotFound(id.to_string()));
        }
        Ok(())
    }

    fn get_locked(&self, conn: &Connection, id: &str) -> Result<SessionMark, SessionMarkError> {
        conn.query_row(
            "SELECT id, session_id, at_ms, start_ms, end_ms, note, created_at, updated_at
             FROM session_marks
             WHERE id = ?1 AND deleted_at IS NULL",
            [id],
            row_to_mark,
        )
        .optional()?
        .ok_or_else(|| SessionMarkError::NotFound(id.to_string()))
    }
}

fn row_to_mark(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionMark> {
    Ok(SessionMark {
        id: row.get(0)?,
        session_id: row.get(1)?,
        at_ms: row.get::<_, i64>(2)? as u64,
        start_ms: row.get::<_, i64>(3)? as u64,
        end_ms: row.get::<_, Option<i64>>(4)?.map(|v| v as u64),
        note: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

fn require_nonempty(field: &str, value: &str) -> Result<(), SessionMarkError> {
    if value.trim().is_empty() {
        return Err(SessionMarkError::MissingField(field.to_string()));
    }
    Ok(())
}

#[derive(Debug, thiserror::Error)]
pub enum SessionMarkError {
    #[error("mark not found: {0}")]
    NotFound(String),

    #[error("missing required field: {0}")]
    MissingField(String),

    #[error("mark range is inverted: {start_ms}..{end_ms}")]
    InvalidRange { start_ms: u64, end_ms: u64 },

    #[error("database error: {0}")]
    DbError(String),
}

impl From<rusqlite::Error> for SessionMarkError {
    fn from(e: rusqlite::Error) -> Self {
        SessionMarkError::DbError(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn anchor(start_ms: u64, end_ms: u64) -> MarkAnchor {
        MarkAnchor { start_ms, end_ms }
    }

    /// The behaviour the whole feature rests on: the passage the listener
    /// wanted is the one that just finished, not the one about to start.
    #[test]
    fn a_mark_reaches_backward_from_the_keypress() {
        let anchors = vec![
            anchor(0, 4_000),
            anchor(4_200, 9_000),
            anchor(9_100, 12_000),
            // Spoken after the keypress: not part of what was marked.
            anchor(13_000, 17_000),
        ];
        let start = resolve_mark_start(&anchors, 12_500, MarkLookback::default());
        assert_eq!(
            start, 0,
            "contiguous speech behind the keypress belongs to the mark"
        );
    }

    /// A pause is where one passage ends and another begins, so the mark stops
    /// there instead of swallowing the previous topic.
    #[test]
    fn a_pause_bounds_the_reach() {
        let anchors = vec![
            anchor(0, 3_000),
            // Five seconds of silence: a different passage.
            anchor(8_000, 11_000),
            anchor(11_200, 14_000),
        ];
        let start = resolve_mark_start(&anchors, 14_500, MarkLookback::default());
        assert_eq!(
            start, 8_000,
            "the mark starts after the silence, not before"
        );
    }

    /// A listener who marks during an unbroken monologue still gets a bounded
    /// passage rather than the whole talk.
    #[test]
    fn the_reach_is_capped_even_without_a_pause() {
        let anchors: Vec<MarkAnchor> = (0..40)
            .map(|i| anchor(i * 2_000, i * 2_000 + 1_900))
            .collect();
        let start = resolve_mark_start(&anchors, 78_000, MarkLookback::default());
        assert_eq!(
            start, 48_000,
            "an unbroken hour cannot become one 60-minute mark"
        );
    }

    /// Provider timestamps are optional upstream. With nothing to walk, the
    /// fixed reach is a worse guess but still a usable one.
    #[test]
    fn an_untimed_transcript_falls_back_to_the_fixed_reach() {
        assert_eq!(
            resolve_mark_start(&[], 45_000, MarkLookback::default()),
            15_000
        );
        assert_eq!(
            resolve_mark_start(&[], 4_000, MarkLookback::default()),
            0,
            "a mark early in the session cannot reach before it began"
        );
    }

    /// The keypress lands mid-sentence far more often than not; the mark
    /// should hold the whole sentence.
    #[test]
    fn an_unset_end_extends_to_the_enclosing_utterance() {
        let mark = SessionMark {
            id: "m1".into(),
            session_id: "s1".into(),
            at_ms: 10_000,
            start_ms: 4_000,
            end_ms: None,
            note: String::new(),
            created_at: String::new(),
            updated_at: String::new(),
        };
        let anchors = vec![anchor(4_000, 8_000), anchor(8_200, 13_500)];
        assert_eq!(resolve_mark_end(&mark, &anchors), 13_500);

        // Nothing encloses the keypress (silence, or a gap in coverage): the
        // mark ends where it was pressed rather than reaching into nothing.
        assert_eq!(resolve_mark_end(&mark, &[anchor(0, 9_000)]), 10_000);
    }

    #[test]
    fn a_dragged_end_wins_over_the_enclosing_utterance() {
        let mark = SessionMark {
            id: "m1".into(),
            session_id: "s1".into(),
            at_ms: 10_000,
            start_ms: 4_000,
            end_ms: Some(11_000),
            note: String::new(),
            created_at: String::new(),
            updated_at: String::new(),
        };
        let anchors = vec![anchor(8_200, 30_000)];
        assert_eq!(resolve_mark_end(&mark, &anchors), 11_000);
    }

    /// Straddling rows stay in: cutting them would hand back half a sentence.
    #[test]
    fn a_passage_keeps_the_rows_that_straddle_its_edges() {
        assert!(anchor_is_in_mark(anchor(3_000, 6_000), 5_000, 9_000));
        assert!(anchor_is_in_mark(anchor(8_000, 12_000), 5_000, 9_000));
        assert!(!anchor_is_in_mark(anchor(0, 4_999), 5_000, 9_000));
        assert!(!anchor_is_in_mark(anchor(9_001, 12_000), 5_000, 9_000));
    }

    fn store() -> (TempDir, SessionMarkStore) {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("marks.db");
        let store = SessionMarkStore::new(&path).unwrap();
        let conn = Connection::open(&path).unwrap();
        conn.execute(
            "INSERT INTO session_records (id, title, status) VALUES ('s1', 'talk', 'recording')",
            [],
        )
        .unwrap();
        (dir, store)
    }

    #[test]
    fn marks_round_trip_and_list_in_capture_order() {
        let (_dir, store) = store();
        store.create("m2", "s1", 20_000, 12_000).unwrap();
        store.create("m1", "s1", 5_000, 0).unwrap();

        let marks = store.list("s1").unwrap();
        assert_eq!(
            marks.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["m1", "m2"],
            "marks read back along the recording, not in the order they were written"
        );
        assert_eq!(marks[0].start_ms, 0);
        assert_eq!(marks[1].end_ms, None);
    }

    #[test]
    fn a_note_survives_a_boundary_drag() {
        let (_dir, store) = store();
        store.create("m1", "s1", 20_000, 12_000).unwrap();
        store.set_note("m1", "他把三条路径混在一起说").unwrap();

        let dragged = store.set_bounds("m1", 8_000, 25_000).unwrap();
        assert_eq!(
            dragged.note, "他把三条路径混在一起说",
            "the one thing nothing can regenerate must not be a casualty of a drag"
        );
        assert_eq!(dragged.end_ms, Some(25_000));
    }

    /// Dragging the leading edge past the keypress is legitimate — the
    /// listener is saying the passage is later than they reacted. The stored
    /// invariant `start_ms <= at_ms` has to travel with it.
    #[test]
    fn dragging_the_start_past_the_keypress_keeps_the_row_well_formed() {
        let (_dir, store) = store();
        store.create("m1", "s1", 20_000, 12_000).unwrap();

        let dragged = store.set_bounds("m1", 22_000, 26_000).unwrap();
        assert_eq!(dragged.start_ms, 22_000);
        assert_eq!(dragged.at_ms, 22_000);
        assert_eq!(store.list("s1").unwrap().len(), 1);
    }

    #[test]
    fn an_inverted_range_is_refused_rather_than_stored() {
        let (_dir, store) = store();
        store.create("m1", "s1", 20_000, 12_000).unwrap();
        assert!(matches!(
            store.set_bounds("m1", 9_000, 5_000),
            Err(SessionMarkError::InvalidRange { .. })
        ));
        assert_eq!(store.get("m1").unwrap().start_ms, 12_000);
    }

    #[test]
    fn a_deleted_mark_leaves_the_list_and_stays_deleted() {
        let (_dir, store) = store();
        store.create("m1", "s1", 20_000, 12_000).unwrap();
        store.delete("m1").unwrap();

        assert!(store.list("s1").unwrap().is_empty());
        assert!(matches!(
            store.delete("m1"),
            Err(SessionMarkError::NotFound(_))
        ));
        assert!(matches!(
            store.get("m1"),
            Err(SessionMarkError::NotFound(_))
        ));
    }
}
