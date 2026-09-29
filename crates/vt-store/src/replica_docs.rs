//! 同步文档的形状:[`crate::library_replica`] 的事实怎样放进 Loro 文档。
//!
//! 每份文档是几张根 Map,每个条目是一行事实序列化成的 JSON 字符串。Map 的
//! 同一个键两台设备同时写,Loro 按 Lamport 时序取后写者 —— 这正是标题、订正、
//! 标记、说话人名字要的「后写者胜」。
//!
//! 写入一律「只写不同的」:值没变就不产生操作,文档的版本也就不动,不会为
//! 无事发生去打扰对端。
//!
//! | 文档 | 根 Map | 谁写 |
//! |---|---|---|
//! | `recording/<id>` | `meta`(来源设备)、`origin`、`utterances`、`variants`、`gaps` | 只有录音那台 |
//! | | `shared`(标题、主题、回收站)、`sections`、`overrides`、`speakers`、`marks` | 任何设备 |
//! | `topic/<id>` | `topic`(主题行、录音设置)、`tabs` | 任何设备 |
//! | `library` | `participants`、`speaker_links`、`purged` | 自己的设备 |
//! | `roster/<空间>` | `devices`、`removed` | 空间成员 |

use std::collections::BTreeMap;

use loro::{LoroDoc, LoroMap, LoroValue, ValueOrContainer};
use serde_json::Value as Json;

use crate::library_replica::{LibraryFacts, RecordingFacts, RecordingOriginFacts, Row, TopicFacts};

#[derive(Debug, thiserror::Error)]
pub enum ReplicaDocError {
    #[error("同步文档里的一行解析不了: {0}")]
    Corrupt(String),
    #[error("写同步文档失败: {0}")]
    Loro(String),
}

type Result<T> = std::result::Result<T, ReplicaDocError>;

fn loro_err(error: impl std::fmt::Display) -> ReplicaDocError {
    ReplicaDocError::Loro(error.to_string())
}

fn get_string(map: &LoroMap, key: &str) -> Option<String> {
    match map.get(key)? {
        ValueOrContainer::Value(LoroValue::String(s)) => Some(s.to_string()),
        _ => None,
    }
}

/// 设成 `value`(`None` 写成 null)。值没变返回假,也不产生操作。
fn set(map: &LoroMap, key: &str, value: Option<&str>) -> Result<bool> {
    let current = match map.get(key) {
        None => None,
        Some(ValueOrContainer::Value(LoroValue::Null)) => Some(None),
        Some(ValueOrContainer::Value(LoroValue::String(s))) => Some(Some(s.to_string())),
        Some(_) => Some(Some(String::new())),
    };
    if current == Some(value.map(str::to_string)) {
        return Ok(false);
    }
    match value {
        Some(value) => map.insert(key, value).map_err(loro_err)?,
        None => map.insert(key, LoroValue::Null).map_err(loro_err)?,
    }
    Ok(true)
}

fn row_json(row: &Row) -> String {
    serde_json::to_string(row).expect("一行事实总能序列化")
}

fn parse_row(text: &str) -> Result<Row> {
    match serde_json::from_str::<Json>(text) {
        Ok(Json::Object(row)) => Ok(row),
        _ => Err(ReplicaDocError::Corrupt(text.chars().take(80).collect())),
    }
}

/// 一张 Map 里所有的行。null 条目(被清掉的)不算。
fn read_rows(map: &LoroMap) -> Result<BTreeMap<String, Row>> {
    let mut rows = BTreeMap::new();
    let mut error = None;
    map.for_each(|key, value| {
        if error.is_some() {
            return;
        }
        if let ValueOrContainer::Value(LoroValue::String(text)) = value {
            match parse_row(&text) {
                Ok(row) => {
                    rows.insert(key.to_string(), row);
                }
                Err(e) => error = Some(e),
            }
        }
    });
    match error {
        Some(error) => Err(error),
        None => Ok(rows),
    }
}

/// 把这些行写进 Map:新的、变了的写,没变的不动。**不删除**:同步的事实里
/// 能删的只有永久删除,那走墓碑。
fn upsert_rows(map: &LoroMap, rows: &BTreeMap<String, Row>) -> Result<bool> {
    let mut changed = false;
    for (key, row) in rows {
        changed |= set(map, key, Some(&row_json(row)))?;
    }
    Ok(changed)
}

fn opt_row_json(row: Option<&Row>) -> Option<String> {
    row.map(row_json)
}

// ── 录音 ──────────────────────────────────────────────────────────────────

/// 把一场录音的事实写进它的文档。返回文档是否变了。
///
/// `origin` 为真表示本机就是录音的那台:只有它写 `origin`、`utterances`、
/// `variants`、`gaps` 这些写入即定的部分。别的设备只写人人可改的部分。
pub fn write_recording(
    doc: &LoroDoc,
    facts: &RecordingFacts,
    local_device: &str,
    origin: bool,
) -> Result<bool> {
    let mut changed = false;
    if origin {
        let meta = doc.get_map("meta");
        if get_string(&meta, "origin_device").is_none() {
            changed |= set(&meta, "origin_device", Some(local_device))?;
            changed |= set(&meta, "session_id", Some(&facts.session_id))?;
        }
        let head = doc.get_map("origin");
        changed |= set(&head, "record", Some(&row_json(&facts.origin.record)))?;
        changed |= set(&head, "meta", Some(&row_json(&facts.origin.meta)))?;
        changed |= set(
            &head,
            "run",
            opt_row_json(facts.origin.run.as_ref()).as_deref(),
        )?;
        changed |= upsert_rows(&doc.get_map("utterances"), &facts.origin.utterances)?;
        changed |= upsert_rows(&doc.get_map("variants"), &facts.origin.variants)?;
        changed |= upsert_rows(&doc.get_map("gaps"), &facts.origin.gaps)?;
    }
    let shared = doc.get_map("shared");
    changed |= set(&shared, "title", Some(&facts.title))?;
    changed |= set(&shared, "topic", facts.topic.as_deref())?;
    changed |= set(&shared, "trashed_at", facts.trashed_at.as_deref())?;

    let sections = doc.get_map("sections");
    for (kind, title) in &facts.section_titles {
        changed |= set(&sections, kind, title.as_deref())?;
    }
    // 清掉的节标题:文档里还有值、本机已经没有了。
    let mut cleared = Vec::new();
    sections.for_each(|kind, value| {
        if matches!(value, ValueOrContainer::Value(LoroValue::String(_)))
            && !facts.section_titles.contains_key(kind)
        {
            cleared.push(kind.to_string());
        }
    });
    for kind in cleared {
        changed |= set(&sections, &kind, None)?;
    }

    changed |= upsert_rows(&doc.get_map("overrides"), &facts.overrides)?;
    changed |= upsert_rows(&doc.get_map("speakers"), &facts.speakers)?;
    changed |= upsert_rows(&doc.get_map("marks"), &facts.marks)?;
    if changed {
        doc.commit();
    }
    Ok(changed)
}

/// 读出文档里的一场录音和它的来源设备。录音那台的部分还没到时为 `None`。
pub fn read_recording(doc: &LoroDoc) -> Result<Option<(RecordingFacts, String)>> {
    let meta = doc.get_map("meta");
    let (Some(origin_device), Some(session_id)) = (
        get_string(&meta, "origin_device"),
        get_string(&meta, "session_id"),
    ) else {
        return Ok(None);
    };
    let head = doc.get_map("origin");
    let Some(record) = get_string(&head, "record") else {
        return Ok(None);
    };
    let origin = RecordingOriginFacts {
        record: parse_row(&record)?,
        meta: get_string(&head, "meta")
            .map(|m| parse_row(&m))
            .transpose()?
            .unwrap_or_default(),
        run: get_string(&head, "run")
            .map(|r| parse_row(&r))
            .transpose()?,
        utterances: read_rows(&doc.get_map("utterances"))?,
        variants: read_rows(&doc.get_map("variants"))?,
        gaps: read_rows(&doc.get_map("gaps"))?,
    };
    let shared = doc.get_map("shared");
    let mut section_titles = BTreeMap::new();
    doc.get_map("sections").for_each(|kind, value| {
        if let ValueOrContainer::Value(LoroValue::String(title)) = value {
            section_titles.insert(kind.to_string(), Some(title.to_string()));
        }
    });
    Ok(Some((
        RecordingFacts {
            session_id,
            origin,
            title: get_string(&shared, "title").unwrap_or_default(),
            topic: get_string(&shared, "topic"),
            trashed_at: get_string(&shared, "trashed_at"),
            section_titles,
            overrides: read_rows(&doc.get_map("overrides"))?,
            speakers: read_rows(&doc.get_map("speakers"))?,
            marks: read_rows(&doc.get_map("marks"))?,
        },
        origin_device,
    )))
}

// ── 主题 ──────────────────────────────────────────────────────────────────

pub fn write_topic(doc: &LoroDoc, facts: &TopicFacts) -> Result<bool> {
    let topic = doc.get_map("topic");
    let mut changed = set(&topic, "notebook", Some(&row_json(&facts.notebook)))?;
    changed |= set(
        &topic,
        "profile",
        opt_row_json(facts.profile.as_ref()).as_deref(),
    )?;
    changed |= upsert_rows(&doc.get_map("tabs"), &facts.tabs)?;
    if changed {
        doc.commit();
    }
    Ok(changed)
}

pub fn read_topic(doc: &LoroDoc) -> Result<Option<TopicFacts>> {
    let topic = doc.get_map("topic");
    let Some(notebook) = get_string(&topic, "notebook") else {
        return Ok(None);
    };
    Ok(Some(TopicFacts {
        notebook: parse_row(&notebook)?,
        tabs: read_rows(&doc.get_map("tabs"))?,
        profile: get_string(&topic, "profile")
            .map(|p| parse_row(&p))
            .transpose()?,
    }))
}

// ── 资料库 ────────────────────────────────────────────────────────────────

/// 把本机的资料库写进文档。人名删了就从文档里删;说话人关联取消了也删 ——
/// 但只删在本机「落得了地」的(`applicable`):本机根本没有那位说话人或那个
/// 人名时,文档里的关联不是本机取消的。
pub fn write_library(
    doc: &LoroDoc,
    facts: &LibraryFacts,
    applicable: impl Fn(&str, &Row) -> bool,
) -> Result<bool> {
    let participants = doc.get_map("participants");
    let mut changed = upsert_rows(&participants, &facts.participants)?;
    for (id, _) in read_rows(&participants)? {
        if !facts.participants.contains_key(&id) {
            participants.delete(&id).map_err(loro_err)?;
            changed = true;
        }
    }
    let links = doc.get_map("speaker_links");
    changed |= upsert_rows(&links, &facts.speaker_links)?;
    for (speaker, link) in read_rows(&links)? {
        if !facts.speaker_links.contains_key(&speaker) && applicable(&speaker, &link) {
            links.delete(&speaker).map_err(loro_err)?;
            changed = true;
        }
    }
    if changed {
        doc.commit();
    }
    Ok(changed)
}

pub fn read_library(doc: &LoroDoc) -> Result<LibraryFacts> {
    Ok(LibraryFacts {
        participants: read_rows(&doc.get_map("participants"))?,
        speaker_links: read_rows(&doc.get_map("speaker_links"))?,
    })
}

/// 永久删除的墓碑:录音 id → 删除时间。任何一台删了,所有设备都删,之后再来的
/// 这场录音的内容一律丢弃。
pub fn add_tombstone(doc: &LoroDoc, session_id: &str, at: &str) -> Result<bool> {
    let purged = doc.get_map("purged");
    if get_string(&purged, session_id).is_some() {
        return Ok(false);
    }
    purged.insert(session_id, at).map_err(loro_err)?;
    doc.commit();
    Ok(true)
}

pub fn tombstones(doc: &LoroDoc) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    doc.get_map("purged").for_each(|key, value| {
        if let ValueOrContainer::Value(LoroValue::String(at)) = value {
            out.insert(key.to_string(), at.to_string());
        }
    });
    out
}

// ── 空间名单 ──────────────────────────────────────────────────────────────

/// 一个空间的成员。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Roster {
    /// 设备 id(hex)→ 名字。
    pub devices: BTreeMap<String, String>,
    /// 设备 id(hex)→ 移除时间。**移除是永久的**:同一个 id 之后再出现在
    /// `devices` 里也不算成员,要重新配对只能换一个身份。
    pub removed: BTreeMap<String, String>,
}

impl Roster {
    pub fn is_member(&self, device: &str) -> bool {
        self.devices.contains_key(device) && !self.removed.contains_key(device)
    }

    pub fn members(&self) -> impl Iterator<Item = (&String, &String)> {
        self.devices
            .iter()
            .filter(|(device, _)| !self.removed.contains_key(*device))
    }
}

pub fn read_roster(doc: &LoroDoc) -> Roster {
    let mut roster = Roster::default();
    doc.get_map("devices").for_each(|key, value| {
        if let ValueOrContainer::Value(LoroValue::String(name)) = value {
            roster.devices.insert(key.to_string(), name.to_string());
        }
    });
    doc.get_map("removed").for_each(|key, value| {
        if let ValueOrContainer::Value(LoroValue::String(at)) = value {
            roster.removed.insert(key.to_string(), at.to_string());
        }
    });
    roster
}

/// 记一台设备(或改它的名字)。已经移除的不会因此复活。
pub fn put_member(doc: &LoroDoc, device: &str, name: &str) -> Result<bool> {
    let changed = set(&doc.get_map("devices"), device, Some(name))?;
    if changed {
        doc.commit();
    }
    Ok(changed)
}

pub fn remove_member(doc: &LoroDoc, device: &str, at: &str) -> Result<bool> {
    let removed = doc.get_map("removed");
    if get_string(&removed, device).is_some() {
        return Ok(false);
    }
    removed.insert(device, at).map_err(loro_err)?;
    doc.commit();
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library_replica::{
        apply_library, apply_recording, apply_topic, read_library as read_library_facts,
        read_recording as read_recording_facts, read_topic as read_topic_facts, ApplyContext,
    };
    use crate::migration::run_migrations;
    use rusqlite::Connection;

    fn database() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        conn.execute_batch(
            "INSERT INTO notebooks (id, title, created_at, updated_at)
                 VALUES ('unfiled', '__zutalk_internal_quick_capture__', 't0', 't0');
             INSERT INTO notebook_tabs (id, notebook_id, builtin_kind, title, doc_id, position,
                                        created_at, updated_at)
             VALUES ('u-rt', 'unfiled', 'realtime_transcript', '', 'u-rt-doc', 0, 't0', 't0'),
                    ('u-as', 'unfiled', 'async_transcript', '', 'u-as-doc', 1, 't0', 't0'),
                    ('u-mn', 'unfiled', 'manual_note', '', 'u-mn-doc', 2, 't0', 't0');",
        )
        .unwrap();
        conn
    }

    /// 一场导入的录音:没有实时转录,只有说话人、标记和一个节标题。
    fn imported(conn: &Connection) {
        conn.execute_batch(
            "INSERT INTO session_records (id, title, session_type, status, duration_ms, created_at)
                 VALUES ('rec', '导入的访谈', 'import', 'imported', 5000, '2026-09-29 09:00:00');
             INSERT INTO notebook_capture_runs
                 (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                  capture_state, created_at, updated_at, completed_at)
             VALUES ('run', 'unfiled', 'rec', 0, '{}', 'completed', 't1', 't1', 't1');
             INSERT INTO notebook_sessions (notebook_id, session_id, created_at)
                 VALUES ('unfiled', 'rec', 't1');
             INSERT INTO notebook_session_projections
                 (id, notebook_id, tab_id, session_id, section_title, created_at, updated_at)
             VALUES ('p1', 'unfiled', 'u-rt', 'rec', NULL, 't1', 't1'),
                    ('p2', 'unfiled', 'u-as', 'rec', '访谈', 't1', 't1'),
                    ('p3', 'unfiled', 'u-mn', 'rec', NULL, 't1', 't1');
             INSERT INTO session_marks (id, session_id, at_ms, start_ms, end_ms, note,
                                        created_at, updated_at)
             VALUES ('m1', 'rec', 10, 0, 10, '开头', 't1', 't1');",
        )
        .unwrap();
    }

    const ORIGIN: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const REPLICA: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    #[test]
    fn a_recording_document_round_trips_between_devices() {
        let origin = database();
        imported(&origin);
        let facts = read_recording_facts(&origin, "rec", "unfiled")
            .unwrap()
            .unwrap();

        let doc = LoroDoc::new();
        assert!(write_recording(&doc, &facts, ORIGIN, true).unwrap());
        assert!(
            !write_recording(&doc, &facts, ORIGIN, true).unwrap(),
            "写同样的事实不产生操作"
        );

        // 只凭字节到另一台设备。
        let bytes = doc.export(loro::ExportMode::Snapshot).unwrap();
        let received = LoroDoc::new();
        received.import(&bytes).unwrap();
        let (back, from) = read_recording(&received).unwrap().unwrap();
        assert_eq!(back, facts);
        assert_eq!(from, ORIGIN);

        let mut replica = database();
        let tx = replica.transaction().unwrap();
        apply_recording(
            &tx,
            &back,
            &ApplyContext {
                local_device: REPLICA,
                origin_device: ORIGIN,
                unfiled_notebook: "unfiled",
                speaker_links: None,
            },
        )
        .unwrap();
        tx.commit().unwrap();
        let there = read_recording_facts(&replica, "rec", "unfiled")
            .unwrap()
            .unwrap();
        assert_eq!(there, facts);
        // 副本把自己的事实写回文档:什么也不变。
        assert!(!write_recording(&received, &there, REPLICA, false).unwrap());
    }

    #[test]
    fn concurrent_edits_on_two_devices_settle_on_the_same_values() {
        let origin = database();
        imported(&origin);
        let facts = read_recording_facts(&origin, "rec", "unfiled")
            .unwrap()
            .unwrap();
        let a = LoroDoc::new();
        write_recording(&a, &facts, ORIGIN, true).unwrap();
        let b = LoroDoc::new();
        b.import(&a.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        // 甲改标题,乙改标记的备注,同时。
        let mut on_a = facts.clone();
        on_a.title = "甲改的标题".into();
        write_recording(&a, &on_a, ORIGIN, true).unwrap();
        let mut on_b = facts.clone();
        on_b.marks
            .get_mut("m1")
            .unwrap()
            .insert("note".into(), Json::from("乙补的备注"));
        write_recording(&b, &on_b, REPLICA, false).unwrap();

        a.import(&b.export(loro::ExportMode::all_updates()).unwrap())
            .unwrap();
        b.import(&a.export(loro::ExportMode::all_updates()).unwrap())
            .unwrap();
        let (on_a, _) = read_recording(&a).unwrap().unwrap();
        let (on_b, _) = read_recording(&b).unwrap().unwrap();
        assert_eq!(on_a, on_b);
        assert_eq!(on_a.title, "甲改的标题");
        assert_eq!(on_a.marks["m1"]["note"], Json::from("乙补的备注"));
    }

    #[test]
    fn a_topic_and_the_library_round_trip() {
        let origin = database();
        origin
            .execute_batch(
                "INSERT INTO notebooks (id, title, created_at, updated_at)
                     VALUES ('t', '周会', 't0', 't0');
                 INSERT INTO notebook_tabs (id, notebook_id, builtin_kind, title, doc_id,
                                            position, created_at, updated_at)
                 VALUES ('t-rt', 't', 'realtime_transcript', '', 't-rt-doc', 0, 't0', 't0'),
                        ('t-as', 't', 'async_transcript', '', 't-as-doc', 1, 't0', 't0'),
                        ('t-mn', 't', 'manual_note', '', 't-mn-doc', 2, 't0', 't0');
                 INSERT INTO notebook_capture_profiles (notebook_id, created_at, updated_at)
                     VALUES ('t', 't0', 't0');
                 INSERT INTO participants (id, display_name, created_at, updated_at)
                     VALUES ('p', '小林', 't0', 't0');",
            )
            .unwrap();
        let topic = read_topic_facts(&origin, "t").unwrap().unwrap();
        let library = read_library_facts(&origin).unwrap();
        let topic_doc = LoroDoc::new();
        write_topic(&topic_doc, &topic).unwrap();
        let library_doc = LoroDoc::new();
        write_library(&library_doc, &library, |_, _| true).unwrap();

        let mut replica = database();
        let tx = replica.transaction().unwrap();
        apply_topic(&tx, &read_topic(&topic_doc).unwrap().unwrap()).unwrap();
        apply_library(&tx, &read_library(&library_doc).unwrap()).unwrap();
        tx.commit().unwrap();
        assert_eq!(read_topic_facts(&replica, "t").unwrap().unwrap(), topic);
        assert_eq!(read_library_facts(&replica).unwrap(), library);

        // 甲删了人名:文档里也删。
        origin.execute("DELETE FROM participants", []).unwrap();
        assert!(write_library(
            &library_doc,
            &read_library_facts(&origin).unwrap(),
            |_, _| true
        )
        .unwrap());
        assert!(read_library(&library_doc).unwrap().participants.is_empty());
    }

    #[test]
    fn removal_from_a_roster_is_permanent() {
        let doc = LoroDoc::new();
        put_member(&doc, ORIGIN, "工作室").unwrap();
        put_member(&doc, REPLICA, "笔记本").unwrap();
        assert!(read_roster(&doc).is_member(REPLICA));
        remove_member(&doc, REPLICA, "t9").unwrap();
        // 被移除的设备把自己的名字再写一遍,也回不来。
        put_member(&doc, REPLICA, "笔记本(改名)").unwrap();
        let roster = read_roster(&doc);
        assert!(!roster.is_member(REPLICA));
        assert_eq!(roster.members().count(), 1);
    }

    #[test]
    fn a_tombstone_is_written_once() {
        let doc = LoroDoc::new();
        assert!(add_tombstone(&doc, "rec", "t1").unwrap());
        assert!(!add_tombstone(&doc, "rec", "t2").unwrap());
        assert_eq!(tombstones(&doc)["rec"], "t1");
    }
}
