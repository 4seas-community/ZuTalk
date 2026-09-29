//! 加密备份(见 docs/architecture/local-first-sync.md §10):把自己的资料库定期
//! 备份到自己的另一台 Mac,只备文字;需要时恢复到任何一台 Mac。
//!
//! 全部复用同步引擎,一次备份就是一个文档:
//!
//! - **备份空间**:被备份的这台(源)与保管备份的那台(备份机)各一个,用备份码
//!   配对。源的空间里只有一个文档 `backup/<毫秒>` —— 最近一份快照;备份机只收
//!   不给,收到的每一份加密存盘,留最近 [`BACKUPS_KEPT`] 份。引擎的「只拉不推」
//!   正好:备份机缺哪份就拉哪份,已经有的摘要相同就不再传。
//! - **快照**:设备组空间里的全部文档(资料库、主题、录音、笔记与精修稿)的
//!   Loro 快照,不含名单。和一台新 Mac 加入设备组时拉到的是同一批东西,所以音频
//!   同样不在里面。
//! - **恢复**:备份机上为某一份生成恢复码,在要恢复的 Mac 上粘贴。两边各开一个
//!   不落库的临时空间,里面只有这一份 `restore/<毫秒>`;收到后按设备组收到文档
//!   的同一条路合进本机资料库。合并,不覆盖:本机已经有的不动,本机永久删除过的
//!   不会回来。
//! - **加密**:传输是 QUIC 端到端加密;备份机上存盘用一把只为备份生成的密钥
//!   (`BACKUP_KEY_REF`,在备份机的钥匙串里),和任何音频密钥无关。备份文件被
//!   拷走(比如随整个目录进了别的备份)也读不出来。
//!
//! 这是 `library_sync` 的子模块:导出、合并、名单都走同一把闸。

use serde::{Deserialize, Serialize};
use vt_crypto::SessionKey;

use super::*;

/// 快照多久做一次。资料库没变就不做。
const BACKUP_INTERVAL_MS: i64 = 24 * 60 * 60 * 1000;
/// 备份机为每台源留几份。
pub(super) const BACKUPS_KEPT: usize = 10;
const BACKUP_DOC_PREFIX: &str = "backup/";
const RESTORE_DOC_PREFIX: &str = "restore/";
/// 备份机上存盘的密钥。只为备份生成,不是任何一把音频密钥。
const BACKUP_KEY_REF: &str = "sync-backup-at-rest";
const OUTBOX_FILE: &str = "backup-outbox.zbk";
const BACKUP_DIR: &str = "backups";
const INDEX_FILE: &str = "index.json";
const LAST_MADE_STATE: &str = "backup_last_made";
const FINGERPRINT_STATE: &str = "backup_fingerprint";
/// 恢复码与临时空间留多久。
const RESTORE_WINDOW: Duration = Duration::from_secs(15 * 60);
const SNAPSHOT_MAGIC: &[u8] = b"ZTBK1\n";
/// 一份快照的上限,与引擎单个文档的上限一致。
const MAX_SNAPSHOT_BYTES: usize = 256 * 1024 * 1024;

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

// ── 快照的样子 ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct SnapshotHeader {
    pub(super) created_at_ms: i64,
    pub(super) source_id: String,
    pub(super) source_name: String,
    pub(super) recordings: u32,
    pub(super) topics: u32,
}

/// `ZTBK1\n` ‖ 头的长度与 JSON ‖ 每个文档:id 长度、id、内容长度、内容。
/// 长度都是 4 字节小端。
pub(super) fn encode_snapshot(header: &SnapshotHeader, docs: &[(String, Vec<u8>)]) -> Vec<u8> {
    let head = serde_json::to_vec(header).unwrap_or_default();
    let mut out = Vec::with_capacity(
        SNAPSHOT_MAGIC.len()
            + 4
            + head.len()
            + docs
                .iter()
                .map(|(i, d)| 8 + i.len() + d.len())
                .sum::<usize>(),
    );
    out.extend_from_slice(SNAPSHOT_MAGIC);
    out.extend_from_slice(&(head.len() as u32).to_le_bytes());
    out.extend_from_slice(&head);
    for (id, data) in docs {
        out.extend_from_slice(&(id.len() as u32).to_le_bytes());
        out.extend_from_slice(id.as_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(data);
    }
    out
}

pub(super) type SnapshotDocs = Vec<(String, Vec<u8>)>;

pub(super) fn decode_snapshot(bytes: &[u8]) -> Result<(SnapshotHeader, SnapshotDocs), String> {
    let mut rest = bytes
        .strip_prefix(SNAPSHOT_MAGIC)
        .ok_or("不是 ZuTalk 的备份")?;
    fn take<'a>(rest: &mut &'a [u8], len: usize) -> Result<&'a [u8], String> {
        if rest.len() < len {
            return Err("备份不完整".into());
        }
        let (head, tail) = rest.split_at(len);
        *rest = tail;
        Ok(head)
    }
    fn length(rest: &mut &[u8]) -> Result<usize, String> {
        let bytes: [u8; 4] = take(rest, 4)?.try_into().map_err(|_| "备份不完整")?;
        Ok(u32::from_le_bytes(bytes) as usize)
    }
    let head_len = length(&mut rest)?;
    let header: SnapshotHeader =
        serde_json::from_slice(take(&mut rest, head_len)?).map_err(|e| e.to_string())?;
    let mut docs = Vec::new();
    while !rest.is_empty() {
        let id_len = length(&mut rest)?;
        let id = String::from_utf8(take(&mut rest, id_len)?.to_vec()).map_err(|e| e.to_string())?;
        let data_len = length(&mut rest)?;
        docs.push((id, take(&mut rest, data_len)?.to_vec()));
    }
    Ok((header, docs))
}

fn digest_of(bytes: &[u8]) -> VersionDigest {
    Sha256::digest(bytes).into()
}

// ── 源:做快照 ─────────────────────────────────────────────────────────────

/// 源这边此刻给出去的那一份。
pub(super) struct Outgoing {
    doc: String,
    digest: VersionDigest,
    bytes: u64,
}

#[derive(Default)]
pub(super) struct BackupState {
    outgoing: Mutex<Option<Outgoing>>,
    /// 上一次恢复的结果,界面取走一次。
    pub(super) restored: Mutex<Option<FfiBackupRestored>>,
    /// 正在恢复:临时空间 → 恢复码有效到何时。
    transient: Mutex<Vec<(SpaceId, std::time::Instant)>>,
}

impl LibrarySync {
    fn outbox_path(&self) -> PathBuf {
        self.data_dir.join(OUTBOX_FILE)
    }

    fn backup_source_space(&self) -> Option<SpaceId> {
        self.spaces
            .read()
            .unwrap()
            .iter()
            .find(|(_, kind)| **kind == SpaceKind::BackupSource)
            .map(|(id, _)| *id)
    }

    /// 源启动时:接上磁盘上上一次做好的那一份,备份机还没拉到的照样能拉。
    pub(super) fn load_outbox(&self) {
        let Ok(bytes) = std::fs::read(self.outbox_path()) else {
            return;
        };
        let Ok((header, _)) = decode_snapshot(&bytes) else {
            return;
        };
        *self.backup.outgoing.lock().unwrap() = Some(Outgoing {
            doc: format!("{BACKUP_DOC_PREFIX}{}", header.created_at_ms),
            digest: digest_of(&bytes),
            bytes: bytes.len() as u64,
        });
    }

    /// 该做一份了:有备份机、离上一份超过一天。泵每一轮都问。
    pub(super) fn backup_due(&self) -> bool {
        let Some(space) = self.backup_source_space() else {
            return false;
        };
        if self.roster_members(&space).len() < 2 {
            return false;
        }
        let last = self
            .replica
            .read(|conn| facts::state(conn, LAST_MADE_STATE))
            .ok()
            .flatten()
            .and_then(|value| value.parse::<i64>().ok())
            .unwrap_or(0);
        now_ms() - last >= BACKUP_INTERVAL_MS
    }

    /// 先把还没导出的改动都写进文档,快照才是此刻的资料库。
    fn flush_exports(&self) {
        for _ in 0..10_000 {
            let pending = self
                .replica
                .read(|conn| facts::pending_changes(conn, 1))
                .unwrap_or_default();
            if pending.is_empty() {
                return;
            }
            self.pump_once();
        }
    }

    /// 做一份快照。资料库和上一份一样时不做(`force` 也不做 —— 没有新东西可存),
    /// 返回有没有做出新的一份。
    pub(super) fn make_backup(&self) -> Result<bool, CoreError> {
        let space = self
            .backup_source_space()
            .ok_or_else(|| sync_error("no_backup_target"))?;
        let group = self
            .device_group()
            .ok_or_else(|| internal("本机还没有设备组"))?;
        let _ = self.ensure_initial_export();
        self.flush_exports();
        let ids: Vec<String> = self
            .space_docs(&group)
            .into_iter()
            .filter(|id| !matches!(parse_doc(id), Some(DocRef::Roster(_))))
            .collect();
        // 指纹:每个文档的版本摘要。和上一份一样就说明什么都没变。
        let mut hasher = Sha256::new();
        for id in &ids {
            hasher.update(id.as_bytes());
            if let Some((digest, _)) = self.version_of(id) {
                hasher.update(digest);
            }
        }
        let fingerprint = hex::encode(hasher.finalize());
        let previous = self
            .replica
            .read(|conn| facts::state(conn, FINGERPRINT_STATE))
            .ok()
            .flatten();
        let made_at = now_ms();
        if previous.as_deref() == Some(fingerprint.as_str()) && self.outbox_path().exists() {
            self.replica
                .write(|tx| facts::set_state(tx, LAST_MADE_STATE, Some(&made_at.to_string())))
                .map_err(internal)?;
            return Ok(false);
        }
        let mut docs = Vec::with_capacity(ids.len());
        let (mut recordings, mut topics) = (0u32, 0u32);
        for id in ids {
            let bytes = match parse_doc(&id) {
                Some(DocRef::Note(note)) => self.note_updates_since(note, &[]),
                Some(doc_ref) => {
                    match doc_ref {
                        DocRef::Recording(_) => recordings += 1,
                        DocRef::Topic(_) => topics += 1,
                        _ => {}
                    }
                    self.replica
                        .read(|conn| facts::load_document(conn, &id))
                        .ok()
                        .flatten()
                }
                None => None,
            };
            if let Some(bytes) = bytes {
                docs.push((id, bytes));
            }
        }
        let header = SnapshotHeader {
            created_at_ms: made_at,
            source_id: self.device_hex.clone(),
            source_name: self.device_name.lock().unwrap().clone(),
            recordings,
            topics,
        };
        let blob = encode_snapshot(&header, &docs);
        if blob.len() > MAX_SNAPSHOT_BYTES {
            return Err(sync_error("backup_too_large"));
        }
        let temporary = self.outbox_path().with_extension("tmp");
        std::fs::write(&temporary, &blob).map_err(internal)?;
        std::fs::rename(&temporary, self.outbox_path()).map_err(internal)?;
        let doc = format!("{BACKUP_DOC_PREFIX}{made_at}");
        *self.backup.outgoing.lock().unwrap() = Some(Outgoing {
            doc: doc.clone(),
            digest: digest_of(&blob),
            bytes: blob.len() as u64,
        });
        self.replica
            .write(|tx| {
                facts::set_state(tx, LAST_MADE_STATE, Some(&made_at.to_string()))?;
                facts::set_state(tx, FINGERPRINT_STATE, Some(&fingerprint))
            })
            .map_err(internal)?;
        self.engine.notify_changed(&space, &doc);
        Ok(true)
    }

    /// 本机要被备份:还没有备份空间就建一个,本机是源。
    fn ensure_backup_source(self: &Arc<Self>) -> Result<SpaceId, CoreError> {
        if let Some(space) = self.backup_source_space() {
            return Ok(space);
        }
        let space = SpaceId::generate();
        let row = SpaceRow {
            space_id: space.to_hex(),
            kind: "backup".into(),
            role: "owner".into(),
            notebook_id: None,
            label: String::new(),
        };
        {
            let _gate = self.gate.lock().unwrap();
            self.replica
                .write(|tx| {
                    facts::insert_space(tx, &row)?;
                    let roster = self.fact_doc_or_new(tx, &roster_doc(&space))?;
                    docs::put_member(&roster, &self.device_hex, &self.device_name.lock().unwrap())?;
                    self.save_fact_doc(tx, &roster_doc(&space), &roster)
                })
                .map_err(internal)?;
        }
        self.register_space(&row);
        Ok(space)
    }

    /// 备份码:到要保管备份的那台 Mac 上粘贴。
    pub(super) fn create_backup_invite(self: &Arc<Self>) -> Result<String, CoreError> {
        let space = self.ensure_backup_source()?;
        let name = self.device_name.lock().unwrap().clone();
        let ticket = self
            .runtime
            .block_on(
                self.engine
                    .create_invite(&space, InvitePurpose::Backup, &name, "hold"),
            )
            .map_err(internal)?;
        Ok(ticket.to_string())
    }

    /// 源不再备份到某一台:从名单上划掉。一台都不剩就撤掉备份空间。
    pub(super) fn remove_backup_target(&self, device: &str) -> Result<(), CoreError> {
        let space = self
            .backup_source_space()
            .ok_or_else(|| sync_error("no_backup_target"))?;
        if device == self.device_hex {
            return Err(sync_error("cannot_remove_self"));
        }
        self.strike_off(&space, &[device.to_string()])?;
        if self.roster_members(&space).len() < 2 {
            self.drop_space(&space).map_err(internal)?;
            let _ = std::fs::remove_file(self.outbox_path());
            *self.backup.outgoing.lock().unwrap() = None;
            let _ = self.replica.write(|tx| {
                facts::set_state(tx, LAST_MADE_STATE, None)?;
                facts::set_state(tx, FINGERPRINT_STATE, None)
            });
        }
        Ok(())
    }

    // ── 备份机:保管 ──────────────────────────────────────────────────────

    fn held_dir(&self, space: &SpaceId) -> PathBuf {
        self.data_dir.join(BACKUP_DIR).join(space.to_hex())
    }

    fn held_index(&self, space: &SpaceId) -> Vec<HeldBackup> {
        std::fs::read(self.held_dir(space).join(INDEX_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn save_held_index(&self, space: &SpaceId, index: &[HeldBackup]) -> std::io::Result<()> {
        let dir = self.held_dir(space);
        std::fs::create_dir_all(&dir)?;
        let temporary = dir.join("index.json.tmp");
        std::fs::write(&temporary, serde_json::to_vec(index).unwrap_or_default())?;
        std::fs::rename(temporary, dir.join(INDEX_FILE))
    }

    fn backup_key(&self) -> Result<SessionKey, String> {
        let core = self.core.upgrade().ok_or("核心已关闭")?;
        if core.key_store.key_exists(BACKUP_KEY_REF) {
            return core
                .key_store
                .load_key(BACKUP_KEY_REF)
                .map_err(|e| e.to_string());
        }
        let key = SessionKey::generate();
        core.key_store
            .store_key(BACKUP_KEY_REF, &key)
            .map_err(|e| e.to_string())?;
        Ok(key)
    }

    /// 备份机收到一份:校验、加密存盘、只留最近几份。
    fn keep_backup(&self, space: &SpaceId, doc: &str, blob: &[u8]) -> Result<bool, String> {
        let made_at: i64 = doc
            .strip_prefix(BACKUP_DOC_PREFIX)
            .and_then(|ms| ms.parse().ok())
            .ok_or("不是一份备份")?;
        let (header, _) = decode_snapshot(blob)?;
        let digest = digest_of(blob);
        let mut index = self.held_index(space);
        if index.iter().any(|held| held.doc == doc) {
            return Ok(false);
        }
        let key = self.backup_key()?;
        let sealed = vt_crypto::encrypt_chunk(blob, &key).map_err(|e| e.to_string())?;
        let dir = self.held_dir(space);
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let file = format!("{made_at}.zbk");
        std::fs::write(dir.join(&file), sealed).map_err(|e| e.to_string())?;
        index.push(HeldBackup {
            doc: doc.to_string(),
            file,
            made_at_ms: made_at,
            digest: hex::encode(digest),
            bytes: blob.len() as u64,
            recordings: header.recordings,
            topics: header.topics,
        });
        index.sort_by_key(|held| std::cmp::Reverse(held.made_at_ms));
        for old in index.split_off(BACKUPS_KEPT.min(index.len())) {
            let _ = std::fs::remove_file(dir.join(old.file));
        }
        self.save_held_index(space, &index)
            .map_err(|e| e.to_string())?;
        if let Some(listener) = self.listener() {
            listener.on_library_changed();
        }
        Ok(true)
    }

    fn open_held(&self, space: &SpaceId, held: &HeldBackup) -> Result<Vec<u8>, String> {
        let sealed =
            std::fs::read(self.held_dir(space).join(&held.file)).map_err(|e| e.to_string())?;
        let key = self.backup_key()?;
        let blob = vt_crypto::decrypt_chunk(&sealed, &key).map_err(|e| e.to_string())?;
        if hex::encode(digest_of(&blob)) != held.digest {
            return Err("备份文件对不上".into());
        }
        Ok(blob)
    }

    /// 在要保管备份的这台粘贴了备份码。
    pub(super) fn adopt_backup_holder(
        self: &Arc<Self>,
        joined: &vt_sync::Joined,
    ) -> Result<(), CoreError> {
        let row = SpaceRow {
            space_id: joined.space.to_hex(),
            kind: "backup".into(),
            role: "member".into(),
            notebook_id: None,
            label: joined.inviter_name.clone(),
        };
        {
            let _gate = self.gate.lock().unwrap();
            self.replica
                .write(|tx| {
                    facts::insert_space(tx, &row)?;
                    let roster = self.fact_doc_or_new(tx, &roster_doc(&joined.space))?;
                    docs::put_member(&roster, &self.device_hex, &self.device_name.lock().unwrap())?;
                    docs::put_member(&roster, &device_hex(&joined.inviter), &joined.inviter_name)?;
                    self.save_fact_doc(tx, &roster_doc(&joined.space), &roster)
                })
                .map_err(internal)?;
        }
        self.register_space(&row);
        Ok(())
    }

    /// 备份机不再保管一台的备份:撤掉空间,删掉存着的每一份。
    pub(super) fn forget_held(&self, space_hex: &str) -> Result<(), CoreError> {
        let space = SpaceId::from_hex(space_hex).ok_or_else(|| sync_error("backup_missing"))?;
        if self.space_kind(&space) != Some(SpaceKind::BackupHolder) {
            return Err(sync_error("backup_missing"));
        }
        self.drop_space(&space).map_err(internal)?;
        let _ = std::fs::remove_dir_all(self.held_dir(&space));
        Ok(())
    }

    // ── 恢复 ─────────────────────────────────────────────────────────────

    /// 备份机上:为保管的某一份生成恢复码。`made_at_ms` 为空时用最新的一份。
    pub(super) fn create_restore_invite(
        self: &Arc<Self>,
        space_hex: &str,
        made_at_ms: Option<i64>,
    ) -> Result<String, CoreError> {
        let space = SpaceId::from_hex(space_hex).ok_or_else(|| sync_error("backup_missing"))?;
        if self.space_kind(&space) != Some(SpaceKind::BackupHolder) {
            return Err(sync_error("backup_missing"));
        }
        let index = self.held_index(&space);
        let held = match made_at_ms {
            Some(ms) => index.iter().find(|held| held.made_at_ms == ms),
            None => index.first(),
        }
        .ok_or_else(|| sync_error("backup_missing"))?;
        let blob = self.open_held(&space, held).map_err(|error| {
            tracing::warn!(%error, "备份:打开保管的一份失败");
            sync_error("backup_unreadable")
        })?;
        let label = self.spaces_label(&space).unwrap_or_default();
        let restore = SpaceId::generate();
        let doc = format!("{RESTORE_DOC_PREFIX}{}", held.made_at_ms);
        self.spaces
            .write()
            .unwrap()
            .insert(restore, SpaceKind::RestoreServe);
        self.engine.add_space(
            restore,
            Arc::new(RestoreServeStore {
                doc,
                digest: digest_of(&blob),
                blob: Arc::new(blob),
            }),
            Arc::new(TransientRoster::new(vec![self.engine.device_id()])),
        );
        self.expire_later(restore);
        let ticket = self
            .runtime
            .block_on(
                self.engine
                    .create_invite(&restore, InvitePurpose::Backup, &label, "restore"),
            )
            .map_err(internal)?;
        Ok(ticket.to_string())
    }

    /// 备份机上:把保管的某一份直接合进这台自己的资料库(主力 Mac 坏了,在
    /// 保管备份的这台上接着用)。不走网络。
    pub(super) fn restore_here(
        &self,
        space_hex: &str,
        made_at_ms: Option<i64>,
    ) -> Result<FfiBackupRestored, CoreError> {
        let space = SpaceId::from_hex(space_hex).ok_or_else(|| sync_error("backup_missing"))?;
        if self.space_kind(&space) != Some(SpaceKind::BackupHolder) {
            return Err(sync_error("backup_missing"));
        }
        let index = self.held_index(&space);
        let held = match made_at_ms {
            Some(ms) => index.iter().find(|held| held.made_at_ms == ms),
            None => index.first(),
        }
        .ok_or_else(|| sync_error("backup_missing"))?;
        let blob = self.open_held(&space, held).map_err(|error| {
            tracing::warn!(%error, "备份:打开保管的一份失败");
            sync_error("backup_unreadable")
        })?;
        // 一个不存在的空间当来源:合进来的改动照常传给本机的每个空间。
        self.import_snapshot(SpaceId::generate(), &blob)
            .map_err(|error| {
                tracing::warn!(%error, "备份:合并失败");
                sync_error("backup_unreadable")
            })
    }

    fn spaces_label(&self, space: &SpaceId) -> Option<String> {
        self.replica
            .read(facts::spaces)
            .ok()?
            .into_iter()
            .find(|row| row.space_id == space.to_hex())
            .map(|row| row.label)
    }

    /// 临时空间:恢复码失效之后撤掉。
    fn expire_later(self: &Arc<Self>, space: SpaceId) {
        self.backup
            .transient
            .lock()
            .unwrap()
            .push((space, std::time::Instant::now() + RESTORE_WINDOW));
    }

    /// 泵每一轮顺手清掉过期的临时空间。
    pub(super) fn expire_transient(&self) {
        let now = std::time::Instant::now();
        let expired: Vec<SpaceId> = {
            let mut transient = self.backup.transient.lock().unwrap();
            let (gone, kept): (Vec<_>, Vec<_>) =
                transient.drain(..).partition(|(_, until)| *until <= now);
            *transient = kept;
            gone.into_iter().map(|(space, _)| space).collect()
        };
        for space in expired {
            self.drop_transient(&space);
        }
    }

    fn drop_transient(&self, space: &SpaceId) {
        self.engine.remove_space(space);
        self.spaces.write().unwrap().remove(space);
    }

    /// 在要恢复的这台粘贴了恢复码:开一个临时空间,把那一份拉过来。
    pub(super) fn begin_restore(self: &Arc<Self>, joined: &vt_sync::Joined) {
        let space = joined.space;
        self.spaces
            .write()
            .unwrap()
            .insert(space, SpaceKind::RestoreReceive);
        self.engine.add_space(
            space,
            Arc::new(RestoreReceiveStore {
                sync: Arc::downgrade(self),
                space,
            }),
            Arc::new(TransientRoster::new(vec![
                self.engine.device_id(),
                joined.inviter,
            ])),
        );
        self.expire_later(space);
    }

    /// 把一份快照合进本机资料库:和设备组收到文档走同一条路。顺序是资料库、
    /// 主题、录音、笔记 —— 录音要找得到它的主题,录音笔记要找得到它的录音。
    fn import_snapshot(&self, space: SpaceId, blob: &[u8]) -> Result<FfiBackupRestored, String> {
        let (header, mut docs) = decode_snapshot(blob)?;
        let rank = |id: &str| match parse_doc(id) {
            Some(DocRef::Library) => 0,
            Some(DocRef::Topic(_)) => 1,
            Some(DocRef::Recording(_)) => 2,
            Some(DocRef::Note(_)) => 3,
            _ => 4,
        };
        docs.sort_by_key(|(id, _)| rank(id));
        let before: usize = self
            .replica
            .read(facts::all_recording_ids)
            .map(|ids| ids.len())
            .unwrap_or(0);
        for (id, bytes) in docs {
            match parse_doc(&id) {
                None | Some(DocRef::Roster(_)) => continue,
                Some(DocRef::Note(note)) => {
                    *self.session_notes.lock().unwrap() = None;
                    if let Err(error) = self.apply_note(note, &bytes) {
                        tracing::debug!(%error, doc = %id, "恢复:这份笔记没合进来");
                    }
                }
                Some(_) => {
                    if let Err(error) = self.apply(space, &id, &bytes) {
                        tracing::warn!(%error, doc = %id, "恢复:这份文档没合进来");
                    }
                }
            }
        }
        let after: usize = self
            .replica
            .read(facts::all_recording_ids)
            .map(|ids| ids.len())
            .unwrap_or(0);
        // 「来自 X」:备份的主人不一定在本机的名单上。
        let _ = self.replica.write(|tx| {
            facts::set_state(
                tx,
                &format!("{}{}", nearby::PEER_NAME_STATE, header.source_id),
                Some(&header.source_name),
            )
        });
        Ok(FfiBackupRestored {
            source_name: header.source_name,
            made_at_ms: header.created_at_ms,
            recordings_added: after.saturating_sub(before) as u32,
        })
    }

    /// 泵每一轮:清掉过期的临时空间;该做快照了就做一份。
    pub(super) fn backup_tick(&self) {
        self.expire_transient();
        if self.backup_due() {
            if let Err(error) = self.make_backup() {
                tracing::warn!(%error, "备份:做快照失败");
            }
        }
    }

    pub(super) fn backup_status(&self) -> FfiBackupStatus {
        let source = self.backup_source_space();
        let targets = source
            .map(|space| {
                let peers: HashMap<String, vt_sync::PeerStatus> = self
                    .engine
                    .peers(&space)
                    .into_iter()
                    .map(|peer| (device_hex(&peer.device), peer))
                    .collect();
                self.roster(&space)
                    .members()
                    .filter(|(hex, _)| **hex != self.device_hex)
                    .map(|(hex, name)| {
                        let peer = peers.get(hex);
                        FfiSyncDevice {
                            device_id: hex.clone(),
                            name: name.clone(),
                            is_this_device: false,
                            connected: peer.is_some_and(|p| p.connected),
                            via_relay: peer.is_some_and(|p| p.via_relay),
                            last_synced_unix_ms: peer.and_then(|p| p.last_synced_unix_ms),
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();
        let outgoing = self.backup.outgoing.lock().unwrap();
        let held_spaces: Vec<SpaceId> = self
            .spaces
            .read()
            .unwrap()
            .iter()
            .filter(|(_, kind)| **kind == SpaceKind::BackupHolder)
            .map(|(id, _)| *id)
            .collect();
        let held = held_spaces
            .into_iter()
            .map(|space| {
                let index = self.held_index(&space);
                let connected = self.engine.peers(&space).iter().any(|p| p.connected);
                FfiBackupHeld {
                    space_id: space.to_hex(),
                    source_name: self.spaces_label(&space).unwrap_or_default(),
                    connected,
                    copies: index
                        .iter()
                        .map(|held| FfiBackupCopy {
                            made_at_ms: held.made_at_ms,
                            bytes: held.bytes,
                            recordings: held.recordings,
                            topics: held.topics,
                        })
                        .collect(),
                }
            })
            .collect();
        FfiBackupStatus {
            targets,
            last_made_ms: outgoing
                .as_ref()
                .and_then(|o| o.doc.strip_prefix(BACKUP_DOC_PREFIX)?.parse().ok()),
            last_bytes: outgoing.as_ref().map(|o| o.bytes),
            held,
            restoring: self
                .spaces
                .read()
                .unwrap()
                .values()
                .any(|kind| *kind == SpaceKind::RestoreReceive),
        }
    }
}

/// 备份机上存着的一份。文件是加密的,索引是明文:只有时间、大小、数目。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct HeldBackup {
    doc: String,
    file: String,
    made_at_ms: i64,
    digest: String,
    bytes: u64,
    recordings: u32,
    topics: u32,
}

// ── 引擎看到的四种备份空间 ────────────────────────────────────────────────

/// 源:只给出最近一份,什么也不收。
pub(super) struct SourceStore {
    pub(super) sync: Weak<LibrarySync>,
}

impl SourceStore {
    fn outgoing(&self) -> Option<(String, VersionDigest)> {
        let sync = self.sync.upgrade()?;
        let outgoing = sync.backup.outgoing.lock().unwrap();
        outgoing.as_ref().map(|o| (o.doc.clone(), o.digest))
    }
}

impl DocumentStore for SourceStore {
    fn summary(&self) -> Vec<(DocId, VersionDigest)> {
        self.outgoing().into_iter().collect()
    }

    fn digest(&self, doc: &DocId) -> Option<VersionDigest> {
        self.outgoing()
            .filter(|(id, _)| id == doc)
            .map(|(_, digest)| digest)
    }

    fn version(&self, doc: &DocId) -> Option<Vec<u8>> {
        self.digest(doc).map(|digest| digest.to_vec())
    }

    fn updates_since(&self, doc: &DocId, from: &[u8]) -> Option<Vec<u8>> {
        let digest = self.digest(doc)?;
        if from == digest {
            return None;
        }
        let sync = self.sync.upgrade()?;
        let bytes = std::fs::read(sync.outbox_path()).ok()?;
        (digest_of(&bytes) == digest).then_some(bytes)
    }

    fn apply(&self, doc: &DocId, _update: &[u8]) -> Result<bool, StoreError> {
        Err(StoreError::NotAccepted(doc.clone()))
    }

    fn accepts(&self, _doc: &DocId) -> bool {
        false
    }
}

/// 备份机:只收 `backup/…`,收到就加密存盘;什么也不给。
pub(super) struct HolderStore {
    pub(super) sync: Weak<LibrarySync>,
    pub(super) space: SpaceId,
}

impl HolderStore {
    fn held(&self, doc: &str) -> Option<VersionDigest> {
        let sync = self.sync.upgrade()?;
        let held = sync.held_index(&self.space);
        let digest = held.iter().find(|held| held.doc == doc)?.digest.clone();
        hex::decode(digest).ok()?.try_into().ok()
    }
}

impl DocumentStore for HolderStore {
    fn summary(&self) -> Vec<(DocId, VersionDigest)> {
        let Some(sync) = self.sync.upgrade() else {
            return Vec::new();
        };
        sync.held_index(&self.space)
            .into_iter()
            .filter_map(|held| {
                let digest: VersionDigest = hex::decode(held.digest).ok()?.try_into().ok()?;
                Some((held.doc, digest))
            })
            .collect()
    }

    fn digest(&self, doc: &DocId) -> Option<VersionDigest> {
        self.held(doc)
    }

    fn version(&self, doc: &DocId) -> Option<Vec<u8>> {
        self.held(doc).map(|digest| digest.to_vec())
    }

    fn updates_since(&self, _doc: &DocId, _from: &[u8]) -> Option<Vec<u8>> {
        None
    }

    fn apply(&self, doc: &DocId, update: &[u8]) -> Result<bool, StoreError> {
        let sync = self
            .sync
            .upgrade()
            .ok_or_else(|| StoreError::Storage("同步已停止".into()))?;
        if !self.accepts(doc) {
            return Err(StoreError::NotAccepted(doc.clone()));
        }
        sync.keep_backup(&self.space, doc, update)
            .map_err(StoreError::Rejected)
    }

    fn accepts(&self, doc: &DocId) -> bool {
        doc.strip_prefix(BACKUP_DOC_PREFIX)
            .is_some_and(|ms| !ms.is_empty() && ms.bytes().all(|b| b.is_ascii_digit()))
    }
}

/// 备份机上为恢复开的临时空间:只给出那一份。
struct RestoreServeStore {
    doc: String,
    digest: VersionDigest,
    blob: Arc<Vec<u8>>,
}

impl DocumentStore for RestoreServeStore {
    fn summary(&self) -> Vec<(DocId, VersionDigest)> {
        vec![(self.doc.clone(), self.digest)]
    }

    fn digest(&self, doc: &DocId) -> Option<VersionDigest> {
        (*doc == self.doc).then_some(self.digest)
    }

    fn version(&self, doc: &DocId) -> Option<Vec<u8>> {
        self.digest(doc).map(|digest| digest.to_vec())
    }

    fn updates_since(&self, doc: &DocId, from: &[u8]) -> Option<Vec<u8>> {
        if *doc != self.doc || from == self.digest {
            return None;
        }
        Some(self.blob.as_ref().clone())
    }

    fn apply(&self, doc: &DocId, _update: &[u8]) -> Result<bool, StoreError> {
        Err(StoreError::NotAccepted(doc.clone()))
    }

    fn accepts(&self, _doc: &DocId) -> bool {
        false
    }
}

/// 要恢复的这台的临时空间:收下那一份,合进资料库,然后撤掉空间。
struct RestoreReceiveStore {
    sync: Weak<LibrarySync>,
    space: SpaceId,
}

impl DocumentStore for RestoreReceiveStore {
    fn summary(&self) -> Vec<(DocId, VersionDigest)> {
        Vec::new()
    }

    fn digest(&self, _doc: &DocId) -> Option<VersionDigest> {
        None
    }

    fn version(&self, _doc: &DocId) -> Option<Vec<u8>> {
        None
    }

    fn updates_since(&self, _doc: &DocId, _from: &[u8]) -> Option<Vec<u8>> {
        None
    }

    fn apply(&self, doc: &DocId, update: &[u8]) -> Result<bool, StoreError> {
        if !self.accepts(doc) {
            return Err(StoreError::NotAccepted(doc.clone()));
        }
        let sync = self
            .sync
            .upgrade()
            .ok_or_else(|| StoreError::Storage("同步已停止".into()))?;
        let restored = sync
            .import_snapshot(self.space, update)
            .map_err(StoreError::Rejected)?;
        *sync.backup.restored.lock().unwrap() = Some(restored);
        // 在引擎的回调里撤不掉自己这个空间;交给泵的下一轮。
        for (space, until) in sync.backup.transient.lock().unwrap().iter_mut() {
            if *space == self.space {
                *until = std::time::Instant::now();
            }
        }
        if let Some(listener) = sync.listener() {
            listener.on_library_changed();
        }
        sync.wake.notify_one();
        Ok(true)
    }

    fn accepts(&self, doc: &DocId) -> bool {
        doc.starts_with(RESTORE_DOC_PREFIX)
    }
}

/// 临时空间的名单:只在内存里,配对时记下对方。
struct TransientRoster {
    members: Mutex<Vec<EndpointId>>,
}

impl TransientRoster {
    fn new(members: Vec<EndpointId>) -> Self {
        Self {
            members: Mutex::new(members),
        }
    }
}

impl Membership for TransientRoster {
    fn members(&self) -> Vec<EndpointId> {
        self.members.lock().unwrap().clone()
    }

    fn admit(&self, device: EndpointId, _name: &str) -> Result<(), String> {
        let mut members = self.members.lock().unwrap();
        if !members.contains(&device) {
            members.push(device);
        }
        Ok(())
    }
}

// ── FFI ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiBackupCopy {
    pub made_at_ms: i64,
    pub bytes: u64,
    pub recordings: u32,
    pub topics: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiBackupHeld {
    /// 这台保管的某一台的备份(空间 id)。
    pub space_id: String,
    pub source_name: String,
    pub connected: bool,
    /// 新的在前。
    pub copies: Vec<FfiBackupCopy>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiBackupRestored {
    pub source_name: String,
    pub made_at_ms: i64,
    /// 本机多出来的录音。已经有的不算。
    pub recordings_added: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiBackupStatus {
    /// 这台备份到哪几台。
    pub targets: Vec<FfiSyncDevice>,
    /// 最近一份快照做好的时间与大小。
    pub last_made_ms: Option<i64>,
    pub last_bytes: Option<u64>,
    /// 这台替别的 Mac 保管的备份。
    pub held: Vec<FfiBackupHeld>,
    /// 正在从一份备份恢复。
    pub restoring: bool,
}

#[uniffi::export]
impl ZuTalkCore {
    pub fn backup_status(&self) -> FfiBackupStatus {
        match self.library_sync.get() {
            Some(sync) => sync.backup_status(),
            None => FfiBackupStatus {
                targets: Vec::new(),
                last_made_ms: None,
                last_bytes: None,
                held: Vec::new(),
                restoring: false,
            },
        }
    }

    /// 备份码:到要保管备份的那台 Mac 上,在「设置 › 设备」粘贴。
    pub fn backup_create_invite(&self) -> Result<String, CoreError> {
        self.running_sync()?.create_backup_invite()
    }

    /// 马上做一份(资料库没变时不做)。返回有没有做出新的一份。不要在主线程上调。
    pub fn backup_now(&self) -> Result<bool, CoreError> {
        self.running_sync()?.make_backup()
    }

    pub fn backup_remove_target(&self, device_id: String) -> Result<(), CoreError> {
        self.running_sync()?.remove_backup_target(&device_id)
    }

    /// 备份机上:不再保管这一台的备份,删掉存着的每一份。
    pub fn backup_forget_held(&self, space_id: String) -> Result<(), CoreError> {
        self.running_sync()?.forget_held(&space_id)
    }

    /// 备份机上:为保管的某一份生成恢复码,到要恢复的 Mac 上粘贴。15 分钟内有效。
    pub fn backup_restore_invite(
        &self,
        space_id: String,
        made_at_ms: Option<i64>,
    ) -> Result<String, CoreError> {
        self.running_sync()?
            .create_restore_invite(&space_id, made_at_ms)
    }

    /// 备份机上:把保管的某一份直接恢复到这台 Mac。不要在主线程上调。
    pub fn backup_restore_here(
        &self,
        space_id: String,
        made_at_ms: Option<i64>,
    ) -> Result<FfiBackupRestored, CoreError> {
        self.running_sync()?.restore_here(&space_id, made_at_ms)
    }

    /// 取走最近一次恢复的结果(界面提示一次)。
    pub fn backup_take_restored(&self) -> Option<FfiBackupRestored> {
        self.library_sync
            .get()?
            .backup
            .restored
            .lock()
            .unwrap()
            .take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_snapshot_round_trips_and_a_truncated_one_is_refused() {
        let header = SnapshotHeader {
            created_at_ms: 42,
            source_id: "ab".into(),
            source_name: "工作室".into(),
            recordings: 1,
            topics: 2,
        };
        let docs = vec![
            ("library".to_string(), vec![1, 2, 3]),
            ("recording/r1".to_string(), vec![]),
        ];
        let blob = encode_snapshot(&header, &docs);
        assert_eq!(decode_snapshot(&blob).unwrap(), (header, docs));
        assert!(decode_snapshot(&blob[..blob.len() - 1]).is_err());
        assert!(decode_snapshot(b"not a backup").is_err());
    }
}
