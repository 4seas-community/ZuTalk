//! 设备之间同步的「事实」:从 SQLite 读出该同步的部分,把收到的写回 SQLite。
//!
//! 设计见 docs/architecture/local-first-sync.md。这里只管 SQLite 这一侧:
//!
//! - [`read_recording`] / [`read_topic`] / [`read_library`] 读出一场录音、一个主题、
//!   人名名单里**该同步的列**。本机专有的列(音频路径与密钥、投影水位、任务
//!   状态、`updated_at` 这类本机时钟)不在里面。
//! - [`apply_recording`] / [`apply_topic`] / [`apply_library`] 把收到的事实写回,
//!   只写与现状不同的行,所以重复写入不会惊动触发器,也不会改动任何时间戳。
//!
//! 行一律表示成「列名 → JSON 值」的 [`Row`]。同步文档里存的就是它,两台设备
//! 比较的也是它:同一个值在两边是同一串字节。
//!
//! **物化与导出是同一种形状。** 读出来的事实写回另一台设备,再读出来,应当原样
//! 相等 —— 否则那台设备会把差异当成用户的改动再写回文档,两边来回改个不停。
//! 测试 `a_recording_round_trips_to_a_replica_unchanged` 守的就是这个。

use std::collections::BTreeMap;

use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Transaction};
use serde_json::{Map, Value as Json};

/// 一行:列名 → 值。
pub type Row = Map<String, Json>;

#[derive(Debug, thiserror::Error)]
pub enum ReplicaError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error("同步事实不完整: {0}")]
    Invalid(String),
    #[error(transparent)]
    Document(#[from] crate::replica_docs::ReplicaDocError),
    /// 调用方在事务里做别的事时出的错,原样带出来。
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, ReplicaError>;

pub use rusqlite::{Connection as ReplicaConnection, Transaction as ReplicaTransaction};

/// 同步自己的一条数据库连接。物化与导出都在它的立即事务里做:导入对方的
/// 改动、写回行、存下文档快照,要么一起提交,要么一起不发生。
pub struct ReplicaStore {
    conn: std::sync::Mutex<Connection>,
}

impl ReplicaStore {
    pub fn new(db_path: &std::path::Path) -> Result<Self> {
        let conn = Connection::open(db_path)?;
        // 与录音同一个等待上限:物化一场长录音的事务不短,不能让它在录音写库时
        // 一秒就放弃。
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        crate::migration::run_migrations(&conn)?;
        crate::migration::use_write_ahead_log(&conn);
        Ok(Self {
            conn: std::sync::Mutex::new(conn),
        })
    }

    pub fn read<R>(&self, f: impl FnOnce(&Connection) -> Result<R>) -> Result<R> {
        let conn = self.conn.lock().unwrap();
        f(&conn)
    }

    /// 在一个立即事务里做完 `f`;`f` 出错就整个回滚。
    pub fn write<R>(&self, f: impl FnOnce(&Transaction) -> Result<R>) -> Result<R> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let value = f(&tx)?;
        tx.commit()?;
        Ok(value)
    }
}

// ── 列清单 ────────────────────────────────────────────────────────────────
//
// 清单是封闭的:不在这里的列不同步。音频路径、密钥引用、上下文包密文、投影
// 修订号、本机任务 id 之外的队列状态,都**故意**不在。

const RECORD_COLUMNS: &[&str] = &["session_type", "status", "duration_ms", "created_at"];
const META_COLUMNS: &[&str] = &[
    "privacy_level",
    "sample_rate",
    "channels",
    "sample_format",
    "tokens_json",
];
const RUN_COLUMNS: &[&str] = &[
    "id",
    "profile_revision",
    "profile_snapshot_json",
    "realtime_provider_id",
    "realtime_model_id",
    "post_stop_provider_id",
    "post_stop_model_id",
    "capture_state",
    "provider_error_type",
    "sample_rate",
    "sample_format",
    "channels",
    "captured_frames",
    "created_at",
    "completed_at",
    "async_task_state",
    "async_authorized_at_ms",
    "async_language_hint",
    "async_task_id",
    "async_task_payload_sha256",
    "async_provider_output_sha256",
    "async_provider_result_json",
    "async_provider_completed_at",
];
const UTTERANCE_COLUMNS: &[&str] = &[
    "id",
    "session_id",
    "sequence",
    "session_speaker_id",
    "source_language",
    "source_text",
    "source_start_ms",
    "source_end_ms",
    "translated_language",
    "translated_text",
    "revision",
    "completion",
    "alignment",
    "created_at",
    "updated_at",
];
const VARIANT_COLUMNS: &[&str] = &[
    "utterance_id",
    "language",
    "role",
    "text",
    "state",
    "completion",
    "revision",
    "created_at",
    "updated_at",
];
const OVERRIDE_COLUMNS: &[&str] = &[
    "utterance_id",
    "lane",
    "lane_language",
    "text",
    "machine_utterance_revision",
    "machine_variant_revision",
    "edit_revision",
    "created_at",
    "updated_at",
];
/// 说话人关联到哪个人名不在这里:人名名单属于本机的资料库,见 [`LibraryFacts`]。
const SPEAKER_COLUMNS: &[&str] = &[
    "id",
    "session_id",
    "provider_session_epoch",
    "provider",
    "provider_label",
    "local_display_name",
    "created_at",
    "updated_at",
];
const MARK_COLUMNS: &[&str] = &[
    "id",
    "session_id",
    "at_ms",
    "start_ms",
    "end_ms",
    "note",
    "created_at",
    "updated_at",
    "deleted_at",
];
const GAP_COLUMNS: &[&str] = &[
    "id",
    "session_id",
    "start_frame",
    "end_frame",
    "reason",
    "repair_state",
    "created_at",
    "updated_at",
];
const NOTEBOOK_COLUMNS: &[&str] = &["id", "title", "created_at", "deleted_at"];
const TAB_COLUMNS: &[&str] = &[
    "id",
    "notebook_id",
    "builtin_kind",
    "title",
    "doc_id",
    "position",
    "created_at",
    "updated_at",
    "deleted_at",
];
const PROFILE_COLUMNS: &[&str] = &[
    "remote_realtime_enabled",
    "capture_mode",
    "language_a",
    "language_b",
    "left_language",
    "right_language",
    "selected_languages_json",
    "common_caption_language",
    "subtitle_only_languages_json",
    "privacy_level",
    "send_context_to_soniox",
];
const PARTICIPANT_COLUMNS: &[&str] = &["id", "display_name", "created_at", "updated_at"];

// ── 事实 ──────────────────────────────────────────────────────────────────

/// 一场录音该同步的全部事实。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RecordingFacts {
    pub session_id: String,
    /// 只有录音的那台设备写的部分。
    pub origin: RecordingOriginFacts,
    /// 标题。任何设备都能改,后写者胜。
    pub title: String,
    /// 所在主题。`None` 是「未归入主题」—— 每台设备各有一个,不同步它本身。
    pub topic: Option<String>,
    /// 放进回收站的时间。
    pub trashed_at: Option<String>,
    /// 各内置标签页里这场录音那一节的标题:标签页类型 → 标题。
    pub section_titles: BTreeMap<String, Option<String>>,
    /// 订正:`<句子 id>/<语言>` → 行。
    pub overrides: BTreeMap<String, Row>,
    pub speakers: BTreeMap<String, Row>,
    pub marks: BTreeMap<String, Row>,
}

/// 录音那台设备写入即定的部分。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RecordingOriginFacts {
    pub record: Row,
    pub meta: Row,
    pub run: Option<Row>,
    pub utterances: BTreeMap<String, Row>,
    /// `<句子 id>/<语言>` → 行。
    pub variants: BTreeMap<String, Row>,
    pub gaps: BTreeMap<String, Row>,
}

/// 一个主题该同步的事实。「未归入主题」不同步。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TopicFacts {
    pub notebook: Row,
    pub tabs: BTreeMap<String, Row>,
    pub profile: Option<Row>,
}

/// 只在自己的设备之间同步的资料库事实:人名名单,以及哪位说话人是哪个人。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct LibraryFacts {
    pub participants: BTreeMap<String, Row>,
    /// 说话人 id → `{session_id, participant_id, participant_linked_at}`。
    pub speaker_links: BTreeMap<String, Row>,
}

// ── 通用的行读写 ──────────────────────────────────────────────────────────

fn to_json(value: Value) -> Result<Json> {
    Ok(match value {
        Value::Null => Json::Null,
        Value::Integer(i) => Json::from(i),
        Value::Real(f) => serde_json::Number::from_f64(f)
            .map(Json::Number)
            .ok_or_else(|| ReplicaError::Invalid("非有限浮点数".into()))?,
        Value::Text(s) => Json::String(s),
        Value::Blob(_) => return Err(ReplicaError::Invalid("同步的列里出现了二进制".into())),
    })
}

fn to_sql(value: &Json) -> Result<Value> {
    Ok(match value {
        Json::Null => Value::Null,
        Json::Bool(b) => Value::Integer(i64::from(*b)),
        Json::Number(n) => match n.as_i64() {
            Some(i) => Value::Integer(i),
            None => Value::Real(
                n.as_f64()
                    .ok_or_else(|| ReplicaError::Invalid("数值越界".into()))?,
            ),
        },
        Json::String(s) => Value::Text(s.clone()),
        _ => return Err(ReplicaError::Invalid("行里出现了嵌套结构".into())),
    })
}

/// 按列清单读若干行。`sql_tail` 是 `FROM ... WHERE ...` 部分,列前缀由它的别名决定。
fn read_rows(
    conn: &Connection,
    alias: &str,
    columns: &[&str],
    sql_tail: &str,
    param: &str,
) -> Result<Vec<Row>> {
    let select = columns
        .iter()
        .map(|column| format!("{alias}.{column}"))
        .collect::<Vec<_>>()
        .join(", ");
    let mut stmt = conn.prepare(&format!("SELECT {select} {sql_tail}"))?;
    let mut rows = stmt.query([param])?;
    let mut out = Vec::new();
    while let Some(row) = rows.next()? {
        let mut map = Row::new();
        for (index, column) in columns.iter().enumerate() {
            map.insert((*column).to_string(), to_json(row.get::<_, Value>(index)?)?);
        }
        out.push(map);
    }
    Ok(out)
}

fn read_one(
    conn: &Connection,
    alias: &str,
    columns: &[&str],
    sql_tail: &str,
    param: &str,
) -> Result<Option<Row>> {
    Ok(read_rows(conn, alias, columns, sql_tail, param)?
        .into_iter()
        .next())
}

fn keyed(rows: Vec<Row>, key: impl Fn(&Row) -> String) -> BTreeMap<String, Row> {
    rows.into_iter().map(|row| (key(&row), row)).collect()
}

fn text(row: &Row, column: &str) -> String {
    row.get(column)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_string()
}

fn opt_text(row: &Row, column: &str) -> Option<String> {
    row.get(column).and_then(Json::as_str).map(str::to_string)
}

fn pair_key(row: &Row, first: &str, second: &str) -> String {
    format!("{}/{}", text(row, first), text(row, second))
}

/// 插入或更新一行,只在有列不同时才真的写。返回是否写了。
fn upsert(tx: &Transaction, table: &str, key: &[&str], row: &Row) -> Result<bool> {
    let columns: Vec<&String> = row.keys().collect();
    let placeholders = (1..=columns.len())
        .map(|i| format!("?{i}"))
        .collect::<Vec<_>>()
        .join(", ");
    let names = columns
        .iter()
        .map(|c| c.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    let updates: Vec<String> = columns
        .iter()
        .filter(|c| !key.contains(&c.as_str()))
        .map(|c| format!("{c} = excluded.{c}"))
        .collect();
    let changed: Vec<String> = columns
        .iter()
        .filter(|c| !key.contains(&c.as_str()))
        .map(|c| format!("{table}.{c} IS NOT excluded.{c}"))
        .collect();
    let sql = if updates.is_empty() {
        format!(
            "INSERT INTO {table} ({names}) VALUES ({placeholders})
             ON CONFLICT({}) DO NOTHING",
            key.join(", ")
        )
    } else {
        format!(
            "INSERT INTO {table} ({names}) VALUES ({placeholders})
             ON CONFLICT({}) DO UPDATE SET {} WHERE {}",
            key.join(", "),
            updates.join(", "),
            changed.join(" OR ")
        )
    };
    let values = row.values().map(to_sql).collect::<Result<Vec<_>>>()?;
    Ok(tx.execute(&sql, params_from_iter(values))? > 0)
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}

// ── 读 ────────────────────────────────────────────────────────────────────

/// 这场录音现在能不能导出:不在录音中、没有排队的永久删除。
///
/// 录音中的那一场录完才出现在其他设备上 —— 半截的句子会不停被改写,同步它
/// 只是把抖动传过去。
pub fn is_exportable(conn: &Connection, session_id: &str) -> Result<bool> {
    let capturing: bool = conn.query_row(
        "SELECT EXISTS(
             SELECT 1 FROM notebook_capture_runs
             WHERE session_id = ?1 AND capture_state IN ('recording', 'paused', 'draining'))
         OR EXISTS(SELECT 1 FROM session_records WHERE id = ?1 AND status = 'recording')
         OR EXISTS(SELECT 1 FROM session_purge_jobs WHERE session_id = ?1)",
        [session_id],
        |row| row.get(0),
    )?;
    Ok(!capturing)
}

/// 读出一场录音该同步的事实。录音已经不在了(被永久删除)时为 `None`。
///
/// `unfiled_notebook` 是本机的「未归入主题」:在它里面的录音,主题记作 `None`。
pub fn read_recording(
    conn: &Connection,
    session_id: &str,
    unfiled_notebook: &str,
) -> Result<Option<RecordingFacts>> {
    let Some(record) = read_one(
        conn,
        "r",
        &[
            "title",
            "deleted_at",
            "session_type",
            "status",
            "duration_ms",
            "created_at",
        ],
        "FROM session_records r WHERE r.id = ?1",
        session_id,
    )?
    else {
        return Ok(None);
    };
    let meta = read_one(
        conn,
        "m",
        META_COLUMNS,
        "FROM session_meta m WHERE m.session_id = ?1",
        session_id,
    )?
    .unwrap_or_default();
    let run = read_one(
        conn,
        "c",
        RUN_COLUMNS,
        "FROM notebook_capture_runs c WHERE c.session_id = ?1",
        session_id,
    )?;
    let utterances = keyed(
        read_rows(
            conn,
            "u",
            UTTERANCE_COLUMNS,
            "FROM realtime_utterances u WHERE u.session_id = ?1",
            session_id,
        )?,
        |row| text(row, "id"),
    );
    let variants = keyed(
        read_rows(
            conn,
            "v",
            VARIANT_COLUMNS,
            "FROM realtime_utterance_variants v
             JOIN realtime_utterances u ON u.id = v.utterance_id
             WHERE u.session_id = ?1",
            session_id,
        )?,
        |row| pair_key(row, "utterance_id", "language"),
    );
    let gaps = keyed(
        read_rows(
            conn,
            "g",
            GAP_COLUMNS,
            "FROM realtime_transcript_gaps g WHERE g.session_id = ?1",
            session_id,
        )?,
        |row| text(row, "id"),
    );
    let overrides = keyed(
        read_rows(
            conn,
            "o",
            OVERRIDE_COLUMNS,
            "FROM realtime_utterance_overrides o
             JOIN realtime_utterances u ON u.id = o.utterance_id
             WHERE u.session_id = ?1",
            session_id,
        )?,
        |row| pair_key(row, "utterance_id", "lane_language"),
    );
    let speakers = keyed(
        read_rows(
            conn,
            "s",
            SPEAKER_COLUMNS,
            "FROM session_speakers s WHERE s.session_id = ?1",
            session_id,
        )?,
        |row| text(row, "id"),
    );
    let marks = keyed(
        read_rows(
            conn,
            "k",
            MARK_COLUMNS,
            "FROM session_marks k WHERE k.session_id = ?1",
            session_id,
        )?,
        |row| text(row, "id"),
    );

    // 还在等主题的录音,按它要去的主题算;否则按它现在在哪。
    let deferred: Option<String> = conn
        .query_row(
            "SELECT notebook_id FROM sync_deferred_membership WHERE session_id = ?1",
            [session_id],
            |row| row.get(0),
        )
        .optional()?;
    let linked: Option<String> = conn
        .query_row(
            "SELECT notebook_id FROM notebook_sessions WHERE session_id = ?1",
            [session_id],
            |row| row.get(0),
        )
        .optional()?;
    let topic = deferred
        .or(linked)
        .filter(|notebook| notebook != unfiled_notebook)
        .filter(|notebook| !is_internal_notebook(conn, notebook).unwrap_or(false));

    let mut section_titles = BTreeMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT t.builtin_kind, p.section_title
             FROM notebook_session_projections p
             JOIN notebook_tabs t ON t.id = p.tab_id
             WHERE p.session_id = ?1 AND p.deleted_at IS NULL",
        )?;
        let rows = stmt.query_map([session_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        for row in rows {
            let (kind, title) = row?;
            if title.is_some() {
                section_titles.insert(kind, title);
            }
        }
    }

    let mut record_origin = Row::new();
    for column in RECORD_COLUMNS {
        record_origin.insert((*column).to_string(), record[*column].clone());
    }
    Ok(Some(RecordingFacts {
        session_id: session_id.to_string(),
        origin: RecordingOriginFacts {
            record: record_origin,
            meta,
            run,
            utterances,
            variants,
            gaps,
        },
        title: text(&record, "title"),
        topic,
        trashed_at: opt_text(&record, "deleted_at"),
        section_titles,
        overrides,
        speakers,
        marks,
    }))
}

/// 读出一个主题该同步的事实。主题不存在时为 `None`。
pub fn read_topic(conn: &Connection, notebook_id: &str) -> Result<Option<TopicFacts>> {
    let Some(notebook) = read_one(
        conn,
        "n",
        NOTEBOOK_COLUMNS,
        "FROM notebooks n WHERE n.id = ?1",
        notebook_id,
    )?
    else {
        return Ok(None);
    };
    let tabs = keyed(
        read_rows(
            conn,
            "t",
            TAB_COLUMNS,
            "FROM notebook_tabs t WHERE t.notebook_id = ?1",
            notebook_id,
        )?,
        |row| text(row, "id"),
    );
    let profile = read_one(
        conn,
        "p",
        PROFILE_COLUMNS,
        "FROM notebook_capture_profiles p WHERE p.notebook_id = ?1",
        notebook_id,
    )?;
    Ok(Some(TopicFacts {
        notebook,
        tabs,
        profile,
    }))
}

pub fn read_library(conn: &Connection) -> Result<LibraryFacts> {
    let participants = keyed(
        read_rows(
            conn,
            "p",
            PARTICIPANT_COLUMNS,
            "FROM participants p WHERE ?1 = ?1",
            "",
        )?,
        |row| text(row, "id"),
    );
    let speaker_links = keyed(
        read_rows(
            conn,
            "s",
            &[
                "id",
                "session_id",
                "participant_id",
                "participant_linked_at",
            ],
            "FROM session_speakers s WHERE s.participant_id IS NOT NULL AND ?1 = ?1",
            "",
        )?,
        |row| text(row, "id"),
    )
    .into_iter()
    .map(|(id, mut row)| {
        row.remove("id");
        (id, row)
    })
    .collect();
    Ok(LibraryFacts {
        participants,
        speaker_links,
    })
}

/// 保留标题的内部笔记本(「未归入主题」、遗留的收件箱)不同步:它们每台设备各有
/// 一个,放在里面的录音按「未归入」算。
pub const INTERNAL_NOTEBOOK_TITLE_PREFIX: &str = "__zutalk_internal_";

pub fn is_internal_notebook(conn: &Connection, notebook_id: &str) -> Result<bool> {
    Ok(conn
        .query_row(
            "SELECT title FROM notebooks WHERE id = ?1",
            [notebook_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .is_some_and(|title| title.starts_with(INTERNAL_NOTEBOOK_TITLE_PREFIX)))
}

/// 本机所有录音与主题的 id。第一次同步、或加入设备组时全量导出用。
pub fn all_recording_ids(conn: &Connection) -> Result<Vec<String>> {
    let mut stmt = conn.prepare("SELECT id FROM session_records ORDER BY created_at, id")?;
    let ids = stmt
        .query_map([], |row| row.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(ids)
}

pub fn all_topic_ids(conn: &Connection, unfiled_notebook: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT id FROM notebooks WHERE id <> ?1 AND title NOT LIKE ?2 ORDER BY created_at, id",
    )?;
    let ids = stmt
        .query_map(
            params![
                unfiled_notebook,
                format!("{INTERNAL_NOTEBOOK_TITLE_PREFIX}%")
            ],
            |row| row.get(0),
        )?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(ids)
}

// ── 写回 ──────────────────────────────────────────────────────────────────

/// 物化一场录音时需要知道的本机情况。
#[derive(Debug, Clone)]
pub struct ApplyContext<'a> {
    /// 本机的设备 id(hex)。
    pub local_device: &'a str,
    /// 录音那台设备的 id(hex)。
    pub origin_device: &'a str,
    /// 本机的「未归入主题」。
    pub unfiled_notebook: &'a str,
    /// 资料库里的说话人关联。协作主题里没有资料库,为 `None`。
    pub speaker_links: Option<&'a BTreeMap<String, Row>>,
}

/// 物化一场录音之后,调用方还要做什么。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RecordingOutcome {
    /// 本机第一次有这场录音。
    pub created: bool,
    /// 现在所在的主题(本机 id)。
    pub notebook: String,
    /// 从哪个主题移过来的。本机的实时转录投影要跟着挪。
    pub moved_from: Option<String>,
    /// 实时转录的句子或订正变了,要重新投影、重建搜索。
    pub transcript_changed: bool,
    /// 精修结果这次才到。
    pub refined_arrived: bool,
    /// 主题还没到,先放在「未归入主题」。
    pub deferred: bool,
    /// 本机正在永久删除它,什么也没写。
    pub skipped: bool,
}

fn notebook_exists(tx: &Transaction, notebook_id: &str) -> Result<bool> {
    Ok(tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM notebooks WHERE id = ?1 AND deleted_at IS NULL)",
        [notebook_id],
        |row| row.get(0),
    )?)
}

/// 把一场录音的事实写进本机。只写与现状不同的行。
pub fn apply_recording(
    tx: &Transaction,
    facts: &RecordingFacts,
    ctx: &ApplyContext<'_>,
) -> Result<RecordingOutcome> {
    let session_id = facts.session_id.as_str();
    let replica = ctx.origin_device != ctx.local_device;
    let mut outcome = RecordingOutcome::default();

    let purging: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM session_purge_jobs WHERE session_id = ?1)",
        [session_id],
        |row| row.get(0),
    )?;
    if purging {
        outcome.skipped = true;
        return Ok(outcome);
    }

    // 目标主题:没到的先放「未归入主题」,记下来等它。
    let target = match facts.topic.as_deref() {
        None => {
            tx.execute(
                "DELETE FROM sync_deferred_membership WHERE session_id = ?1",
                [session_id],
            )?;
            ctx.unfiled_notebook.to_string()
        }
        Some(topic) if notebook_exists(tx, topic)? => {
            tx.execute(
                "DELETE FROM sync_deferred_membership WHERE session_id = ?1",
                [session_id],
            )?;
            topic.to_string()
        }
        Some(topic) => {
            tx.execute(
                "INSERT INTO sync_deferred_membership (session_id, notebook_id) VALUES (?1, ?2)
                 ON CONFLICT(session_id) DO UPDATE SET notebook_id = excluded.notebook_id",
                params![session_id, topic],
            )?;
            outcome.deferred = true;
            ctx.unfiled_notebook.to_string()
        }
    };
    outcome.notebook = target.clone();

    // 录音目录。
    let existed: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM session_records WHERE id = ?1)",
        [session_id],
        |row| row.get(0),
    )?;
    outcome.created = !existed;
    let mut record = Row::new();
    record.insert("id".into(), Json::from(session_id));
    record.insert("title".into(), Json::from(facts.title.as_str()));
    for column in RECORD_COLUMNS {
        let value = facts
            .origin
            .record
            .get(*column)
            .cloned()
            .ok_or_else(|| ReplicaError::Invalid(format!("录音 {session_id} 缺少 {column}")))?;
        record.insert((*column).to_string(), value);
    }
    record.insert(
        "deleted_at".into(),
        facts.trashed_at.as_deref().map_or(Json::Null, Json::from),
    );
    upsert(tx, "session_records", &["id"], &record)?;

    if replica {
        // 元数据与分词结果:分词结果写入即定,已经有了就不再碰(本机的触发器也
        // 不允许在精修回执之后改它)。
        let mut meta = facts.origin.meta.clone();
        meta.insert("session_id".into(), Json::from(session_id));
        let existing_tokens: Option<Option<String>> = tx
            .query_row(
                "SELECT tokens_json FROM session_meta WHERE session_id = ?1",
                [session_id],
                |row| row.get(0),
            )
            .optional()?;
        if matches!(existing_tokens, Some(Some(_))) {
            meta.remove("tokens_json");
        }
        if meta.len() > 1 {
            upsert(tx, "session_meta", &["session_id"], &meta)?;
        }
        if let Some(run) = &facts.origin.run {
            outcome.refined_arrived = apply_replica_run(tx, session_id, &target, run)?;
        }
    }

    // 归属。
    let linked: Option<String> = tx
        .query_row(
            "SELECT notebook_id FROM notebook_sessions WHERE session_id = ?1",
            [session_id],
            |row| row.get(0),
        )
        .optional()?;
    match linked {
        None => attach(tx, session_id, &target)?,
        Some(current) if current != target => {
            move_pointers(tx, session_id, &current, &target)?;
            outcome.moved_from = Some(current);
        }
        Some(_) => {}
    }

    // 说话人在句子前面:句子引用说话人。
    for row in facts.speakers.values() {
        upsert(tx, "session_speakers", &["id"], row)?;
    }
    if let Some(links) = ctx.speaker_links {
        apply_speaker_links(tx, links, Some(session_id))?;
    }

    if replica {
        let existing = keyed(
            read_rows(
                tx,
                "u",
                UTTERANCE_COLUMNS,
                "FROM realtime_utterances u WHERE u.session_id = ?1",
                session_id,
            )?,
            |row| text(row, "id"),
        );
        let mut stamped_utterances = Vec::new();
        for (id, row) in &facts.origin.utterances {
            if existing.get(id) != Some(row) {
                upsert(tx, "realtime_utterances", &["id"], row)?;
                if text(row, "completion") == "complete" {
                    stamped_utterances.push(id.clone());
                }
                outcome.transcript_changed = true;
            }
        }
        let existing_variants = keyed(
            read_rows(
                tx,
                "v",
                VARIANT_COLUMNS,
                "FROM realtime_utterance_variants v
                 JOIN realtime_utterances u ON u.id = v.utterance_id
                 WHERE u.session_id = ?1",
                session_id,
            )?,
            |row| pair_key(row, "utterance_id", "language"),
        );
        let mut stamped_variants = Vec::new();
        for (key, row) in &facts.origin.variants {
            if existing_variants.get(key) != Some(row) {
                upsert(
                    tx,
                    "realtime_utterance_variants",
                    &["utterance_id", "language"],
                    row,
                )?;
                if text(row, "state") == "ready" {
                    stamped_variants.push((text(row, "utterance_id"), text(row, "language")));
                }
                outcome.transcript_changed = true;
            }
        }
        if !stamped_utterances.is_empty() || !stamped_variants.is_empty() {
            stamp_projection(tx, session_id, &stamped_utterances, &stamped_variants)?;
        }
        for row in facts.origin.gaps.values() {
            upsert(tx, "realtime_transcript_gaps", &["id"], row)?;
        }
    }

    // 订正:谁写的都一样,后写者胜。句子还没到的先跳过,等句子到了再来一遍。
    for row in facts.overrides.values() {
        let utterance_here: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM realtime_utterances WHERE id = ?1)",
            [text(row, "utterance_id")],
            |r| r.get(0),
        )?;
        if utterance_here
            && upsert(
                tx,
                "realtime_utterance_overrides",
                &["utterance_id", "lane_language"],
                row,
            )?
        {
            outcome.transcript_changed = true;
        }
    }
    for row in facts.marks.values() {
        upsert(tx, "session_marks", &["id"], row)?;
    }
    for (kind, title) in &facts.section_titles {
        tx.execute(
            "UPDATE notebook_session_projections
             SET section_title = ?1, updated_at = ?2
             WHERE session_id = ?3
               AND tab_id IN (SELECT id FROM notebook_tabs WHERE builtin_kind = ?4)
               AND section_title IS NOT ?1",
            params![title, now(), session_id, kind],
        )?;
    }

    if replica {
        tx.execute(
            "INSERT INTO sync_recording_origins (session_id, origin_device) VALUES (?1, ?2)
             ON CONFLICT(session_id) DO UPDATE SET origin_device = excluded.origin_device
             WHERE sync_recording_origins.origin_device IS NOT excluded.origin_device",
            params![session_id, ctx.origin_device],
        )?;
    }
    Ok(outcome)
}

/// 另一台设备录的录音,在本机建一行不带音频的 run,或把已有的往前推。
///
/// 精修状态只能按 none → pending → reserved → enqueued → completed 一步步走
/// (本机的触发器守着),所以这里在一个事务里一步步走过去;中间状态从不提交,
/// 启动时的补偿逻辑永远看不到它们。返回精修结果是不是这次才到。
fn apply_replica_run(
    tx: &Transaction,
    session_id: &str,
    notebook: &str,
    run: &Row,
) -> Result<bool> {
    let terminal = matches!(
        text(run, "capture_state").as_str(),
        "completed" | "interrupted" | "failed"
    );
    if !terminal {
        return Err(ReplicaError::Invalid(format!(
            "录音 {session_id} 还没录完,不该出现在同步里"
        )));
    }
    let completed = text(run, "async_task_state") == "completed"
        && run
            .get("async_provider_output_sha256")
            .is_some_and(|v| !v.is_null());

    let exists: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM notebook_capture_runs WHERE session_id = ?1)",
        [session_id],
        |row| row.get(0),
    )?;
    let value = |column: &str| run.get(column).cloned().unwrap_or(Json::Null);
    let values = |columns: &[&str]| -> Result<Vec<Value>> {
        columns.iter().map(|c| to_sql(&value(c))).collect()
    };

    if !exists {
        let base = [
            "id",
            "profile_revision",
            "profile_snapshot_json",
            "realtime_provider_id",
            "realtime_model_id",
            "post_stop_provider_id",
            "post_stop_model_id",
            "capture_state",
            "provider_error_type",
            "sample_rate",
            "sample_format",
            "channels",
            "captured_frames",
            "created_at",
            "completed_at",
        ];
        let mut sql_values = values(&base)?;
        let mut columns: Vec<&str> = base.to_vec();
        if completed {
            let receipt = [
                "async_task_state",
                "async_authorized_at_ms",
                "async_language_hint",
                "async_task_id",
                "async_task_payload_sha256",
                "async_provider_output_sha256",
                "async_provider_result_json",
                "async_provider_completed_at",
            ];
            sql_values.extend(values(&receipt)?);
            columns.extend(receipt);
            // 本机不渲染精修稿(它随文档同步过来),只建自己的搜索。
            columns.push("async_projection_state");
            sql_values.push(Value::Text("ready".into()));
            columns.push("async_search_projection_state");
            sql_values.push(Value::Text("pending".into()));
        }
        let fixed = [
            ("notebook_id", Value::Text(notebook.to_string())),
            ("session_id", Value::Text(session_id.to_string())),
            ("remote_health", Value::Text("off".into())),
            ("projection_state", Value::Text("pending".into())),
            ("updated_at", Value::Text(now())),
        ];
        for (column, v) in fixed {
            columns.push(column);
            sql_values.push(v);
        }
        let placeholders = (1..=columns.len())
            .map(|i| format!("?{i}"))
            .collect::<Vec<_>>()
            .join(", ");
        tx.execute(
            &format!(
                "INSERT INTO notebook_capture_runs ({}) VALUES ({placeholders})",
                columns.join(", ")
            ),
            params_from_iter(sql_values),
        )?;
        return Ok(completed);
    }

    // 已有:可变的只有这些。
    tx.execute(
        "UPDATE notebook_capture_runs
         SET capture_state = ?2, provider_error_type = ?3, captured_frames = ?4,
             completed_at = ?5, updated_at = ?6
         WHERE session_id = ?1
           AND (capture_state IS NOT ?2 OR provider_error_type IS NOT ?3
                OR captured_frames IS NOT ?4 OR completed_at IS NOT ?5)",
        params_from_iter([
            Value::Text(session_id.to_string()),
            to_sql(&value("capture_state"))?,
            to_sql(&value("provider_error_type"))?,
            to_sql(&value("captured_frames"))?,
            to_sql(&value("completed_at"))?,
            Value::Text(now()),
        ]),
    )?;
    if !value("post_stop_provider_id").is_null() {
        tx.execute(
            "UPDATE notebook_capture_runs SET post_stop_provider_id = ?2, post_stop_model_id = ?3
             WHERE session_id = ?1 AND post_stop_provider_id IS NULL",
            params_from_iter([
                Value::Text(session_id.to_string()),
                to_sql(&value("post_stop_provider_id"))?,
                to_sql(&value("post_stop_model_id"))?,
            ]),
        )?;
    }
    if !completed {
        return Ok(false);
    }
    let state: String = tx.query_row(
        "SELECT async_task_state FROM notebook_capture_runs WHERE session_id = ?1",
        [session_id],
        |row| row.get(0),
    )?;
    if state != "none" {
        // 本机从不跑别人录音的精修任务;不是 none 就是已经推过了。
        return Ok(false);
    }
    let sid = Value::Text(session_id.to_string());
    tx.execute(
        "UPDATE notebook_capture_runs
         SET async_task_state = 'pending', async_authorized_at_ms = ?2, async_language_hint = ?3
         WHERE session_id = ?1",
        params_from_iter([
            sid.clone(),
            to_sql(&value("async_authorized_at_ms"))?,
            to_sql(&value("async_language_hint"))?,
        ]),
    )?;
    tx.execute(
        "UPDATE notebook_capture_runs
         SET async_task_state = 'reserved', async_task_id = ?2, async_task_payload_sha256 = ?3
         WHERE session_id = ?1",
        params_from_iter([
            sid.clone(),
            to_sql(&value("async_task_id"))?,
            to_sql(&value("async_task_payload_sha256"))?,
        ]),
    )?;
    for next in ["enqueued", "completed"] {
        tx.execute(
            "UPDATE notebook_capture_runs SET async_task_state = ?2 WHERE session_id = ?1",
            params![session_id, next],
        )?;
    }
    tx.execute(
        "UPDATE notebook_capture_runs
         SET async_provider_output_sha256 = ?2, async_provider_result_json = ?3,
             async_provider_completed_at = ?4, async_search_projection_state = 'pending'
         WHERE session_id = ?1",
        params_from_iter([
            sid,
            to_sql(&value("async_provider_output_sha256"))?,
            to_sql(&value("async_provider_result_json"))?,
            to_sql(&value("async_provider_completed_at"))?,
        ]),
    )?;
    for next in ["pending", "projecting", "ready"] {
        tx.execute(
            "UPDATE notebook_capture_runs SET async_projection_state = ?2 WHERE session_id = ?1",
            params![session_id, next],
        )?;
    }
    Ok(true)
}

/// 句子变了:像录音时一样把期望修订号加一,盖在变了的句子与语言栏上,
/// 本机的投影器据此把它们投进实时转录文档,之后这些栏才能订正。
fn stamp_projection(
    tx: &Transaction,
    session_id: &str,
    utterances: &[String],
    variants: &[(String, String)],
) -> Result<()> {
    tx.execute(
        "UPDATE notebook_capture_runs
         SET realtime_loro_desired_revision = realtime_loro_desired_revision + 1,
             projection_state = 'pending'
         WHERE session_id = ?1",
        [session_id],
    )?;
    let revision: i64 = tx.query_row(
        "SELECT realtime_loro_desired_revision FROM notebook_capture_runs WHERE session_id = ?1",
        [session_id],
        |row| row.get(0),
    )?;
    for id in utterances {
        tx.execute(
            "UPDATE realtime_utterances SET source_projection_revision = ?1 WHERE id = ?2",
            params![revision, id],
        )?;
    }
    for (utterance, language) in variants {
        tx.execute(
            "UPDATE realtime_utterance_variants SET projection_revision = ?1
             WHERE utterance_id = ?2 AND language = ?3",
            params![revision, utterance, language],
        )?;
    }
    Ok(())
}

/// 把录音挂进主题,建好它在三个内置标签页里的投影行。
fn attach(tx: &Transaction, session_id: &str, notebook_id: &str) -> Result<()> {
    let tabs = builtin_tabs(tx, notebook_id)?;
    let now = now();
    tx.execute(
        "INSERT INTO notebook_sessions (notebook_id, session_id, created_at) VALUES (?1, ?2, ?3)",
        params![notebook_id, session_id, now],
    )?;
    for tab_id in tabs.values() {
        tx.execute(
            "INSERT INTO notebook_session_projections
             (id, notebook_id, tab_id, session_id, section_title, created_at, updated_at, deleted_at)
             VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?5, NULL)
             ON CONFLICT(tab_id, session_id) DO UPDATE SET deleted_at = NULL",
            params![uuid::Uuid::new_v4().to_string(), notebook_id, tab_id, session_id, now],
        )?;
    }
    Ok(())
}

/// 另一台设备把录音挪了主题:本机只挪指针。同步的文档里各节已经由挪的那台
/// 设备搬好了,本机再搬一次就是两份;本机自己的实时转录投影由调用方挪。
fn move_pointers(tx: &Transaction, session_id: &str, from: &str, to: &str) -> Result<()> {
    let target_tabs = builtin_tabs(tx, to)?;
    let now = now();
    tx.execute(
        "UPDATE notebook_sessions SET notebook_id = ?1 WHERE session_id = ?2",
        params![to, session_id],
    )?;
    tx.execute(
        "UPDATE notebook_capture_runs SET notebook_id = ?1 WHERE session_id = ?2",
        params![to, session_id],
    )?;
    let source_tabs = builtin_tabs(tx, from)?;
    for (kind, target_tab) in &target_tabs {
        let Some(source_tab) = source_tabs.get(kind) else {
            continue;
        };
        tx.execute(
            "UPDATE notebook_session_projections
             SET notebook_id = ?1, tab_id = ?2, updated_at = ?3
             WHERE tab_id = ?4 AND session_id = ?5",
            params![to, target_tab, now, source_tab, session_id],
        )?;
    }
    Ok(())
}

/// 主题的三个内置标签页:类型 → 标签页 id。
fn builtin_tabs(tx: &Transaction, notebook_id: &str) -> Result<BTreeMap<String, String>> {
    let mut stmt = tx.prepare(
        "SELECT builtin_kind, id FROM notebook_tabs
         WHERE notebook_id = ?1 AND deleted_at IS NULL",
    )?;
    let tabs = stmt
        .query_map([notebook_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<BTreeMap<_, _>>>()?;
    if tabs.len() != 3 {
        return Err(ReplicaError::Invalid(format!(
            "主题 {notebook_id} 应当恰好有三个内置标签页"
        )));
    }
    Ok(tabs)
}

/// 物化一个主题之后,调用方还要做什么。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TopicOutcome {
    pub created: bool,
    /// 先到、一直在等这个主题的录音。调用方把它们的文档再物化一遍。
    pub waiting_recordings: Vec<String>,
}

pub fn apply_topic(tx: &Transaction, facts: &TopicFacts) -> Result<TopicOutcome> {
    let notebook_id = text(&facts.notebook, "id");
    if notebook_id.is_empty() {
        return Err(ReplicaError::Invalid("主题缺少 id".into()));
    }
    let mut outcome = TopicOutcome::default();
    let exists: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM notebooks WHERE id = ?1)",
        [&notebook_id],
        |row| row.get(0),
    )?;
    let now = now();
    if !exists {
        let mut notebook = facts.notebook.clone();
        notebook.insert("updated_at".into(), Json::from(now.as_str()));
        upsert(tx, "notebooks", &["id"], &notebook)?;
        outcome.created = true;
    } else {
        tx.execute(
            "UPDATE notebooks SET title = ?2, deleted_at = ?3, updated_at = ?4
             WHERE id = ?1 AND (title IS NOT ?2 OR deleted_at IS NOT ?3)",
            params_from_iter([
                Value::Text(notebook_id.clone()),
                to_sql(&facts.notebook["title"])?,
                to_sql(facts.notebook.get("deleted_at").unwrap_or(&Json::Null))?,
                Value::Text(now.clone()),
            ]),
        )?;
    }
    for (tab_id, row) in &facts.tabs {
        let here: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM notebook_tabs WHERE id = ?1)",
            [tab_id],
            |r| r.get(0),
        )?;
        if !here {
            upsert(tx, "notebook_tabs", &["id"], row)?;
        }
    }
    if let Some(profile) = &facts.profile {
        let current = read_one(
            tx,
            "p",
            PROFILE_COLUMNS,
            "FROM notebook_capture_profiles p WHERE p.notebook_id = ?1",
            &notebook_id,
        )?;
        match current {
            None => {
                let mut row = profile.clone();
                row.insert("notebook_id".into(), Json::from(notebook_id.as_str()));
                row.insert("revision".into(), Json::from(0));
                row.insert("created_at".into(), Json::from(now.as_str()));
                row.insert("updated_at".into(), Json::from(now.as_str()));
                upsert(tx, "notebook_capture_profiles", &["notebook_id"], &row)?;
            }
            Some(current) if &current != profile => {
                let assignments = PROFILE_COLUMNS
                    .iter()
                    .enumerate()
                    .map(|(i, c)| format!("{c} = ?{}", i + 2))
                    .collect::<Vec<_>>()
                    .join(", ");
                let mut values = vec![Value::Text(notebook_id.clone())];
                for column in PROFILE_COLUMNS {
                    values.push(to_sql(profile.get(*column).unwrap_or(&Json::Null))?);
                }
                values.push(Value::Text(now.clone()));
                tx.execute(
                    &format!(
                        "UPDATE notebook_capture_profiles
                         SET {assignments}, revision = revision + 1, updated_at = ?{}
                         WHERE notebook_id = ?1",
                        PROFILE_COLUMNS.len() + 2
                    ),
                    params_from_iter(values),
                )?;
            }
            Some(_) => {}
        }
    }
    let mut stmt = tx.prepare(
        "SELECT session_id FROM sync_deferred_membership WHERE notebook_id = ?1 ORDER BY session_id",
    )?;
    outcome.waiting_recordings = stmt
        .query_map([&notebook_id], |row| row.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(outcome)
}

/// 物化资料库:人名名单与说话人关联。名单里没有的人名是别的设备删掉的。
///
/// 调用方保证在导入对方的改动之前,已经把本机的改动写进了文档 —— 所以这里
/// 看到的「没有」只可能是对方删的,不会是本机刚加、还没导出的。
pub fn apply_library(tx: &Transaction, facts: &LibraryFacts) -> Result<()> {
    for row in facts.participants.values() {
        upsert(tx, "participants", &["id"], row)?;
    }
    let mut stmt = tx.prepare("SELECT id FROM participants")?;
    let local = stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);
    for id in local {
        if !facts.participants.contains_key(&id) {
            tx.execute("DELETE FROM participants WHERE id = ?1", [&id])?;
        }
    }
    apply_speaker_links(tx, &facts.speaker_links, None)?;
    Ok(())
}

/// 说话人关联:本机有这位说话人、也有那个人名时才关联;关联里没有、本机却
/// 关联着的,是别的设备取消了。`only_session` 限定一场录音。
fn apply_speaker_links(
    tx: &Transaction,
    links: &BTreeMap<String, Row>,
    only_session: Option<&str>,
) -> Result<()> {
    for (speaker, row) in links {
        if only_session.is_some_and(|session| text(row, "session_id") != session) {
            continue;
        }
        tx.execute(
            "UPDATE session_speakers
             SET participant_id = ?2, participant_linked_at = ?3
             WHERE id = ?1
               AND EXISTS(SELECT 1 FROM participants WHERE id = ?2)
               AND (participant_id IS NOT ?2 OR participant_linked_at IS NOT ?3)",
            params_from_iter([
                Value::Text(speaker.clone()),
                to_sql(row.get("participant_id").unwrap_or(&Json::Null))?,
                to_sql(row.get("participant_linked_at").unwrap_or(&Json::Null))?,
            ]),
        )?;
    }
    let mut stmt =
        tx.prepare("SELECT id, session_id FROM session_speakers WHERE participant_id IS NOT NULL")?;
    let linked = stmt
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);
    for (speaker, session) in linked {
        if only_session.is_some_and(|only| only != session) {
            continue;
        }
        if !links.contains_key(&speaker) {
            tx.execute(
                "UPDATE session_speakers SET participant_id = NULL, participant_linked_at = NULL
                 WHERE id = ?1",
                [&speaker],
            )?;
        }
    }
    Ok(())
}

/// 一条说话人关联在本机能不能落地:说话人与人名都在本机。落不了地的关联不能
/// 被当成「本机取消了」写回文档。
pub fn speaker_link_applicable(conn: &Connection, speaker: &str, link: &Row) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM session_speakers WHERE id = ?1)
            AND EXISTS(SELECT 1 FROM participants WHERE id = ?2)",
        params![speaker, text(link, "participant_id")],
        |row| row.get(0),
    )?)
}

// ── 同步自己的表 ──────────────────────────────────────────────────────────

/// 本机改动过、还没写进同步文档的事实范围。
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum ChangedScope {
    Recording(String),
    Topic(String),
    Library,
}

pub fn pending_changes(conn: &Connection, limit: usize) -> Result<Vec<ChangedScope>> {
    let mut stmt =
        conn.prepare("SELECT scope, key FROM sync_changes ORDER BY scope, key LIMIT ?1")?;
    let rows = stmt
        .query_map([limit as i64], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows
        .into_iter()
        .filter_map(|(scope, key)| match scope.as_str() {
            "recording" => Some(ChangedScope::Recording(key)),
            "topic" => Some(ChangedScope::Topic(key)),
            "library" => Some(ChangedScope::Library),
            _ => None,
        })
        .collect())
}

pub fn clear_change(tx: &Transaction, scope: &ChangedScope) -> Result<()> {
    let (scope, key) = match scope {
        ChangedScope::Recording(key) => ("recording", key.as_str()),
        ChangedScope::Topic(key) => ("topic", key.as_str()),
        ChangedScope::Library => ("library", ""),
    };
    tx.execute(
        "DELETE FROM sync_changes WHERE scope = ?1 AND key = ?2",
        params![scope, key],
    )?;
    Ok(())
}

pub fn mark_changed(conn: &Connection, scope: &ChangedScope) -> Result<()> {
    let (scope, key) = match scope {
        ChangedScope::Recording(key) => ("recording", key.as_str()),
        ChangedScope::Topic(key) => ("topic", key.as_str()),
        ChangedScope::Library => ("library", ""),
    };
    conn.execute(
        "INSERT INTO sync_changes (scope, key) SELECT ?1, ?2
         WHERE NOT EXISTS (SELECT 1 FROM sync_changes WHERE scope = ?1 AND key = ?2)",
        params![scope, key],
    )?;
    Ok(())
}

pub fn load_document(conn: &Connection, doc_id: &str) -> Result<Option<Vec<u8>>> {
    Ok(conn
        .query_row(
            "SELECT snapshot FROM sync_documents WHERE doc_id = ?1",
            [doc_id],
            |row| row.get(0),
        )
        .optional()?)
}

pub fn save_document(tx: &Transaction, doc_id: &str, snapshot: &[u8]) -> Result<()> {
    tx.execute(
        "INSERT INTO sync_documents (doc_id, snapshot, updated_at) VALUES (?1, ?2, ?3)
         ON CONFLICT(doc_id) DO UPDATE SET snapshot = excluded.snapshot,
                                           updated_at = excluded.updated_at",
        params![doc_id, snapshot, now()],
    )?;
    Ok(())
}

pub fn delete_document(tx: &Transaction, doc_id: &str) -> Result<()> {
    tx.execute("DELETE FROM sync_documents WHERE doc_id = ?1", [doc_id])?;
    Ok(())
}

pub fn document_ids(conn: &Connection) -> Result<Vec<String>> {
    let mut stmt = conn.prepare("SELECT doc_id FROM sync_documents ORDER BY doc_id")?;
    let ids = stmt
        .query_map([], |row| row.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(ids)
}

/// 这场录音是从哪台设备来的;本机录的为 `None`。
pub fn recording_origin(conn: &Connection, session_id: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT origin_device FROM sync_recording_origins WHERE session_id = ?1",
            [session_id],
            |row| row.get(0),
        )
        .optional()?)
}

pub fn state(conn: &Connection, key: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT value FROM sync_state WHERE key = ?1",
            [key],
            |row| row.get(0),
        )
        .optional()?)
}

pub fn set_state(conn: &Connection, key: &str, value: Option<&str>) -> Result<()> {
    match value {
        Some(value) => conn.execute(
            "INSERT INTO sync_state (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?,
        None => conn.execute("DELETE FROM sync_state WHERE key = ?1", [key])?,
    };
    Ok(())
}

/// 本机在同步的一个空间。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpaceRow {
    /// 空间 id(hex)。
    pub space_id: String,
    /// `devices` / `topic` / `backup`。
    pub kind: String,
    /// `owner` / `member`。
    pub role: String,
    pub notebook_id: Option<String>,
    pub label: String,
}

pub fn spaces(conn: &Connection) -> Result<Vec<SpaceRow>> {
    let mut stmt = conn.prepare(
        "SELECT space_id, kind, role, notebook_id, label FROM sync_spaces ORDER BY created_at",
    )?;
    let rows = stmt
        .query_map([], |row| {
            Ok(SpaceRow {
                space_id: row.get(0)?,
                kind: row.get(1)?,
                role: row.get(2)?,
                notebook_id: row.get(3)?,
                label: row.get(4)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub fn insert_space(tx: &Transaction, row: &SpaceRow) -> Result<()> {
    tx.execute(
        "INSERT INTO sync_spaces (space_id, kind, role, notebook_id, label, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            row.space_id,
            row.kind,
            row.role,
            row.notebook_id,
            row.label,
            now()
        ],
    )?;
    Ok(())
}

pub fn delete_space(tx: &Transaction, space_id: &str) -> Result<()> {
    tx.execute("DELETE FROM sync_spaces WHERE space_id = ?1", [space_id])?;
    Ok(())
}

pub fn removed_devices(conn: &Connection, space_id: &str) -> Result<Vec<String>> {
    let mut stmt =
        conn.prepare("SELECT device_id FROM sync_removed_devices WHERE space_id = ?1")?;
    let rows = stmt
        .query_map([space_id], |row| row.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(rows)
}

pub fn mark_removed(tx: &Transaction, space_id: &str, device_id: &str) -> Result<()> {
    tx.execute(
        "INSERT INTO sync_removed_devices (space_id, device_id, removed_at) VALUES (?1, ?2, ?3)
         ON CONFLICT(space_id, device_id) DO NOTHING",
        params![space_id, device_id, now()],
    )?;
    Ok(())
}

/// 本机该不该自己渲染这场录音的精修稿。
///
/// 别的设备录的、又在同步中的主题里:精修稿随主题的文档同步过来,本机再渲染
/// 一份,合并后就是两份。在本机「未归入主题」里的照常渲染 —— 那份文档每台
/// 设备各有一份,不同步。`unfiled_title` 是「未归入主题」的保留标题。
pub fn renders_refined_locally(
    conn: &Connection,
    session_id: &str,
    unfiled_title: &str,
) -> Result<bool> {
    let replica_in_synced_topic: bool = conn.query_row(
        "SELECT EXISTS(
             SELECT 1 FROM sync_recording_origins o
             JOIN notebook_sessions s ON s.session_id = o.session_id
             JOIN notebooks n ON n.id = s.notebook_id
             WHERE o.session_id = ?1 AND n.title <> ?2)",
        params![session_id, unfiled_title],
        |row| row.get(0),
    )?;
    Ok(!replica_in_synced_topic)
}

/// 同 [`renders_refined_locally`],按数据库路径开一条只读的连接。给没有
/// 同步连接可用的渲染器用。
pub fn renders_refined_locally_at(
    db_path: &std::path::Path,
    session_id: &str,
    unfiled_title: &str,
) -> Result<bool> {
    let conn = Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let has_table: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name = 'sync_recording_origins')",
        [],
        |row| row.get(0),
    )?;
    if !has_table {
        return Ok(true);
    }
    renders_refined_locally(&conn, session_id, unfiled_title)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::run_migrations;

    const UNFILED: &str = "unfiled-here";

    fn database() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    fn topic(conn: &Connection, id: &str, title: &str) {
        conn.execute_batch(&format!(
            "INSERT INTO notebooks (id, title, created_at, updated_at)
                 VALUES ('{id}', '{title}', 't0', 't0');
             INSERT INTO notebook_tabs (id, notebook_id, builtin_kind, title, doc_id, position,
                                        created_at, updated_at)
             VALUES ('{id}-rt', '{id}', 'realtime_transcript', '实时', '{id}-rt-doc', 0, 't0', 't0'),
                    ('{id}-as', '{id}', 'async_transcript', '精修', '{id}-as-doc', 1, 't0', 't0'),
                    ('{id}-mn', '{id}', 'manual_note', '笔记', '{id}-mn-doc', 2, 't0', 't0');"
        ))
        .unwrap();
    }

    /// 一台设备上录完、精修过、订正过、有标记的一场录音。
    fn recorded(conn: &Connection, topic_id: &str) -> String {
        let sid = "rec-1".to_string();
        let sha = "a".repeat(64);
        conn.execute_batch(&format!(
            "INSERT INTO session_records (id, title, session_type, status, duration_ms, created_at)
                 VALUES ('{sid}', '周一例会', 'recording', 'completed', 61000, '2026-09-29 10:00:00');
             INSERT INTO session_meta (session_id, encrypted_path, key_id, tokens_json,
                                       privacy_level, sample_rate, channels, sample_format)
                 VALUES ('{sid}', 'audio/rec-1/audio.enc', 'key-ref', '[{{\"text\":\"hi\"}}]',
                         'standard', 16000, 1, 's16');
             INSERT INTO notebook_capture_runs
                 (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                  realtime_provider_id, realtime_model_id, post_stop_provider_id, post_stop_model_id,
                  capture_state, audio_path, audio_key_ref, sample_rate, sample_format, channels,
                  captured_frames, created_at, updated_at, completed_at,
                  async_task_state, async_authorized_at_ms, async_language_hint, async_task_id,
                  async_task_payload_sha256, async_provider_output_sha256,
                  async_provider_result_json, async_provider_completed_at,
                  async_projection_state, async_search_projection_state,
                  realtime_loro_desired_revision, realtime_loro_applied_revision)
             VALUES ('run-1', '{topic_id}', '{sid}', 1, '{{\"languages\":[\"en\",\"zh\"]}}',
                     'soniox', 'stt-rt-v5', 'soniox', 'stt-async-v5',
                     'completed', 'audio/rec-1/audio.wav', 'key-ref', 16000, 's16', 1,
                     976000, 't1', 't9', 't2',
                     'completed', 5, 'en', 'task-1', '{sha}', '{sha}',
                     '{{\"full_text\":\"hi\"}}', 't3', 'ready', 'ready', 4, 4);
             INSERT INTO notebook_sessions (notebook_id, session_id, created_at)
                 VALUES ('{topic_id}', '{sid}', 't1');
             INSERT INTO notebook_session_projections
                 (id, notebook_id, tab_id, session_id, section_title, created_at, updated_at)
             VALUES ('p1', '{topic_id}', '{topic_id}-rt', '{sid}', NULL, 't1', 't1'),
                    ('p2', '{topic_id}', '{topic_id}-as', '{sid}', NULL, 't1', 't1'),
                    ('p3', '{topic_id}', '{topic_id}-mn', '{sid}', '开场', 't1', 't1');
             INSERT INTO participants (id, display_name, created_at, updated_at)
                 VALUES ('person-1', '小林', 't1', 't1');
             INSERT INTO session_speakers
                 (id, session_id, provider_session_epoch, provider, provider_label,
                  local_display_name, participant_id, participant_linked_at, created_at, updated_at)
             VALUES ('spk-1', '{sid}', 0, 'soniox', '1', '主持人', 'person-1', 't2', 't1', 't2');
             INSERT INTO realtime_utterances
                 (id, session_id, sequence, session_speaker_id, source_language, source_text,
                  source_start_ms, source_end_ms, translated_language, translated_text,
                  revision, completion, alignment, created_at, updated_at, source_projection_revision)
             VALUES ('u1', '{sid}', 0, 'spk-1', 'en', 'Hello team', 0, 1200, 'zh', '大家好',
                     2, 'complete', 'paired', 't1', 't1', 3);
             INSERT INTO realtime_utterance_variants
                 (utterance_id, language, role, text, state, completion, revision,
                  created_at, updated_at, projection_revision)
             VALUES ('u1', 'en', 'source', 'Hello team', 'ready', 'complete', 2, 't1', 't1', 3),
                    ('u1', 'zh', 'translation', '大家好', 'ready', 'complete', 1, 't1', 't1', 4);
             INSERT INTO realtime_utterance_overrides
                 (utterance_id, lane, lane_language, text, machine_utterance_revision,
                  machine_variant_revision, edit_revision, created_at, updated_at)
             VALUES ('u1', 'translated', 'zh', '各位好', 2, 1, 1, 't5', 't5');
             INSERT INTO realtime_transcript_gaps
                 (id, session_id, start_frame, end_frame, reason, repair_state, created_at, updated_at)
             VALUES ('gap-1', '{sid}', 100, 200, 'network_discontinuity', 'repaired', 't1', 't3');
             INSERT INTO session_marks (id, session_id, at_ms, start_ms, end_ms, note,
                                        created_at, updated_at)
             VALUES ('mark-1', '{sid}', 900, 0, 1200, '这句要跟进', 't1', 't1');"
        ))
        .unwrap();
        sid
    }

    fn apply_all(
        conn: &mut Connection,
        facts: &RecordingFacts,
        topic_facts: Option<&TopicFacts>,
        library: Option<&LibraryFacts>,
    ) -> RecordingOutcome {
        let tx = conn.transaction().unwrap();
        if let Some(topic_facts) = topic_facts {
            apply_topic(&tx, topic_facts).unwrap();
        }
        if let Some(library) = library {
            apply_library(&tx, library).unwrap();
        }
        let ctx = ApplyContext {
            local_device: &"b".repeat(64),
            origin_device: &"a".repeat(64),
            unfiled_notebook: UNFILED,
            speaker_links: library.map(|l| &l.speaker_links),
        };
        let outcome = apply_recording(&tx, facts, &ctx).unwrap();
        tx.commit().unwrap();
        outcome
    }

    #[test]
    fn a_recording_round_trips_to_a_replica_unchanged() {
        let origin = database();
        topic(&origin, "topic-1", "周会");
        topic(&origin, UNFILED, "__zutalk_internal_quick_capture__");
        let sid = recorded(&origin, "topic-1");
        let facts = read_recording(&origin, &sid, UNFILED).unwrap().unwrap();
        let topic_facts = read_topic(&origin, "topic-1").unwrap().unwrap();
        let library = read_library(&origin).unwrap();
        assert_eq!(facts.topic.as_deref(), Some("topic-1"));
        assert_eq!(library.speaker_links.len(), 1);

        let mut replica = database();
        topic(
            &replica,
            "local-unfiled",
            "__zutalk_internal_quick_capture__",
        );
        let outcome = apply_all(&mut replica, &facts, Some(&topic_facts), Some(&library));
        assert!(outcome.created);
        assert!(outcome.transcript_changed);
        assert!(outcome.refined_arrived);
        assert_eq!(outcome.notebook, "topic-1");

        // 读回来与原样相等:否则副本会把差异当成用户改动写回去。
        let back = read_recording(&replica, &sid, UNFILED).unwrap().unwrap();
        assert_eq!(back, facts);
        assert_eq!(
            read_topic(&replica, "topic-1").unwrap().unwrap(),
            topic_facts
        );
        assert_eq!(read_library(&replica).unwrap(), library);

        // 音频与密钥没有跟过来;来源记下了。
        let (path, key): (Option<String>, Option<String>) = replica
            .query_row(
                "SELECT audio_path, audio_key_ref FROM notebook_capture_runs WHERE session_id = ?1",
                [&sid],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!((path, key), (None, None));
        let encrypted: Option<String> = replica
            .query_row(
                "SELECT encrypted_path FROM session_meta WHERE session_id = ?1",
                [&sid],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(encrypted, None);
        assert_eq!(
            recording_origin(&replica, &sid).unwrap(),
            Some("a".repeat(64))
        );
        // 句子盖上了投影修订号,本机投影器会把它们投出来。
        let (desired, applied): (i64, i64) = replica
            .query_row(
                "SELECT realtime_loro_desired_revision, realtime_loro_applied_revision
                 FROM notebook_capture_runs WHERE session_id = ?1",
                [&sid],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!((desired, applied), (1, 0));

        // 再写一遍什么也不变,也不留下待导出的改动。
        replica.execute("DELETE FROM sync_changes", []).unwrap();
        let again = apply_all(&mut replica, &facts, Some(&topic_facts), Some(&library));
        assert!(!again.created && !again.transcript_changed && !again.refined_arrived);
        let pending: i64 = replica
            .query_row("SELECT count(*) FROM sync_changes", [], |row| row.get(0))
            .unwrap();
        assert_eq!(pending, 0, "没变的事实不该惊动触发器");
    }

    #[test]
    fn a_refinement_that_finishes_later_steps_the_replica_forward() {
        let origin = database();
        topic(&origin, "topic-1", "周会");
        let sid = recorded(&origin, "topic-1");
        let finished = read_recording(&origin, &sid, UNFILED).unwrap().unwrap();
        // 先到的版本还没精修。
        let mut early = finished.clone();
        let run = early.origin.run.as_mut().unwrap();
        for column in [
            "async_authorized_at_ms",
            "async_language_hint",
            "async_task_id",
            "async_task_payload_sha256",
            "async_provider_output_sha256",
            "async_provider_result_json",
            "async_provider_completed_at",
        ] {
            run.insert(column.into(), Json::Null);
        }
        run.insert("async_task_state".into(), Json::from("none"));

        let mut replica = database();
        topic(&replica, UNFILED, "__zutalk_internal_quick_capture__");
        let topic_facts = read_topic(&origin, "topic-1").unwrap().unwrap();
        let first = apply_all(&mut replica, &early, Some(&topic_facts), None);
        assert!(!first.refined_arrived);
        let later = apply_all(&mut replica, &finished, None, None);
        assert!(later.refined_arrived);
        let (state, projection): (String, String) = replica
            .query_row(
                "SELECT async_task_state, async_projection_state
                 FROM notebook_capture_runs WHERE session_id = ?1",
                [&sid],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            (state.as_str(), projection.as_str()),
            ("completed", "ready")
        );
    }

    #[test]
    fn a_recording_whose_topic_has_not_arrived_waits_in_unfiled() {
        let origin = database();
        topic(&origin, "topic-1", "周会");
        let sid = recorded(&origin, "topic-1");
        let facts = read_recording(&origin, &sid, UNFILED).unwrap().unwrap();

        let mut replica = database();
        topic(&replica, UNFILED, "__zutalk_internal_quick_capture__");
        let outcome = apply_all(&mut replica, &facts, None, None);
        assert!(outcome.deferred);
        assert_eq!(outcome.notebook, UNFILED);
        // 等待期间读出来的主题仍是它要去的那个,不会被当成「挪进了未归入」。
        assert_eq!(
            read_recording(&replica, &sid, UNFILED)
                .unwrap()
                .unwrap()
                .topic,
            Some("topic-1".into())
        );

        let tx = replica.transaction().unwrap();
        let arrived = apply_topic(&tx, &read_topic(&origin, "topic-1").unwrap().unwrap()).unwrap();
        tx.commit().unwrap();
        assert_eq!(arrived.waiting_recordings, vec![sid.clone()]);
        let moved = apply_all(&mut replica, &facts, None, None);
        assert_eq!(moved.moved_from.as_deref(), Some(UNFILED));
        assert_eq!(moved.notebook, "topic-1");
    }

    #[test]
    fn a_link_to_someone_this_library_does_not_know_is_left_alone() {
        let origin = database();
        topic(&origin, "topic-1", "周会");
        let sid = recorded(&origin, "topic-1");
        let facts = read_recording(&origin, &sid, UNFILED).unwrap().unwrap();
        let library = read_library(&origin).unwrap();

        // 协作的同事:没有我的人名名单。
        let mut colleague = database();
        topic(&colleague, UNFILED, "__zutalk_internal_quick_capture__");
        let topic_facts = read_topic(&origin, "topic-1").unwrap().unwrap();
        apply_all(&mut colleague, &facts, Some(&topic_facts), None);
        assert!(read_library(&colleague).unwrap().speaker_links.is_empty());
        let (speaker, link) = library.speaker_links.iter().next().unwrap();
        assert!(!speaker_link_applicable(&colleague, speaker, link).unwrap());
    }
}
