//! 第 1 纪元转录稿 → T2 的严格重放迁移(阶段 4)。
//!
//! 决策文档的合同:逐提交重放历史,原 peer、原时间戳进新文档;**每个
//! 历史时刻**新旧两边拼出的正文逐字节一致,任何不一致拒绝写回。转录稿
//! 是证据,这条通道的每一分严格都是给证据性质付的保费——笔记那条宽松
//! 内容迁移(block_document_api)与此无关。
//!
//! 两个落地决定,偏离处大声写明:
//!
//! 1. **行块保真**:旧转录稿文档是渲染切片(`## <session_id>` 节头 +
//!    逐行车道文本),任一历史时刻的「utterance × 车道」结构从文档字节
//!    本身不可恢复(那是 SQLite 的事实)。迁移产物因此以**渲染行**为
//!    句块:每行一块,owner 按节头归段。这保住了逐字节等价这条硬合同;
//!    车道结构的富化(按 SQLite 事实把行合并成带 lanes 的句块)是迁移
//!    之后的独立增量,不在证据合同之内。
//! 2. **只迁线性历史**:每个提交的 deps 必须恰是前一提交的末尾。并发
//!    分叉下「历史时刻」的新旧对照没有无歧义定义(线性化重放的累积态
//!    会包含旧侧祖先闭包之外的提交),v1 对非线性历史**拒绝迁移**,旧
//!    文档原样保留可读。本机转录稿由单进程顺序写入,线性是常态;经
//!    分享合并过远端编辑的文档等富化通道成熟后再议。
//!
//! 块 id 的稳定性靠相邻时刻的行 diff(公共前后缀):行内容变了保 id,
//! 中段增删换新 id。id 稳定性只影响将来的行级操作锚点,不影响本合同
//! ——字节等价由逐时刻验证保证。

use std::collections::HashMap;
use std::ops::ControlFlow;

use loro::{Frontiers, LoroDoc, LoroList, LoroMap, LoroText, LoroValue, ID};

use crate::document_schema::{
    document_kind, new_block_document, DocumentKind, TRANSCRIPT_UTTERANCES,
};
const PURGE_RECEIPTS: &str = "zulangue_session_purge_receipts";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ReplayMigrationError {
    #[error("浅文档没有完整历史,不能重放迁移")]
    ShallowHistory,
    #[error("历史非线性(提交 {peer}:{counter} 的 deps 不是前一提交),v1 拒绝迁移")]
    NonLinearHistory { peer: u64, counter: i32 },
    #[error("历史走查失败: {0}")]
    HistoryTraversal(String),
    #[error("第 {step} 个历史时刻正文不一致:旧 {old_len} 字节,新 {new_len} 字节")]
    FrontierMismatch {
        step: usize,
        old_len: usize,
        new_len: usize,
    },
    #[error("Loro 操作失败: {0}")]
    Loro(String),
}

fn loro_err(error: impl std::fmt::Display) -> ReplayMigrationError {
    ReplayMigrationError::Loro(error.to_string())
}

/// 一个历史时刻:一个 Change 的完成点。
struct HistoryStep {
    peer: u64,
    counter_end: i32,
    timestamp: i64,
    deps: Frontiers,
}

/// 迁移一份第 1 纪元转录稿。成功返回第 2 纪元文档;调用方负责落盘与
/// 旧文件 `.pre-epoch2` 留档(与笔记通道同一套落盘纪律)。
pub fn migrate_transcript_history(legacy: &LoroDoc) -> Result<LoroDoc, ReplayMigrationError> {
    if legacy.is_shallow() {
        return Err(ReplayMigrationError::ShallowHistory);
    }

    let steps = collect_linear_history(legacy)?;

    // 走历史用 fork,不动调用方的文档状态。
    let walker = legacy.fork();

    let target = new_block_document(DocumentKind::Transcript);
    // 禁用 Change 合并:loro 会把同 peer 相邻提交按时间间隔并成一个
    // Change,原时间戳被后者吞掉——重放要的恰是逐提交的历史身份。
    target.set_change_merge_interval(0);
    let mut writer = BlockWriter::new(&target);

    let mut previous_lines: Vec<Line> = Vec::new();
    for (step_index, step) in steps.iter().enumerate() {
        let frontier = Frontiers::from(ID::new(step.peer, step.counter_end));
        walker.checkout(&frontier).map_err(loro_err)?;
        let old_text = walker.get_text("content").to_string();

        let next_lines = track_lines(&previous_lines, &old_text);
        // 原 peer、原时间戳:提交身份随历史走,不随迁移机器走。
        target.set_peer_id(step.peer).map_err(loro_err)?;
        writer.apply(&target, &previous_lines, &next_lines)?;
        target.commit_with(loro::CommitOptions::new().timestamp(step.timestamp));

        // 逐时刻验证:新文档容器态拼出的正文必须与旧侧逐字节一致。
        let new_text = writer.render(&target)?;
        if new_text != old_text {
            return Err(ReplayMigrationError::FrontierMismatch {
                step: step_index,
                old_len: old_text.len(),
                new_len: new_text.len(),
            });
        }
        previous_lines = next_lines;
    }
    walker.checkout_to_latest();

    stamp_owners(&target, &previous_lines, &writer)?;
    copy_receipts(legacy, &target)?;
    target.commit();

    debug_assert_eq!(document_kind(&target), Some(DocumentKind::Transcript));
    Ok(target)
}

/// 收集全量历史并要求线性:按 lamport 排序后,每个提交的 deps 必须恰是
/// 前一提交的末尾。
fn collect_linear_history(legacy: &LoroDoc) -> Result<Vec<HistoryStep>, ReplayMigrationError> {
    let frontiers = legacy.oplog_frontiers();
    let head_ids: Vec<ID> = frontiers.iter().collect();
    if head_ids.is_empty() {
        return Ok(Vec::new());
    }

    let mut metas: HashMap<(u64, i32), (u32, i64, usize, Frontiers)> = HashMap::new();
    legacy
        .travel_change_ancestors(&head_ids, &mut |meta| {
            metas.insert(
                (meta.id.peer, meta.id.counter),
                (meta.lamport, meta.timestamp, meta.len, meta.deps.clone()),
            );
            ControlFlow::Continue(())
        })
        .map_err(|e| ReplayMigrationError::HistoryTraversal(format!("{e:?}")))?;

    let mut steps: Vec<(u32, HistoryStep)> = metas
        .into_iter()
        .map(|((peer, counter), (lamport, timestamp, len, deps))| {
            (
                lamport,
                HistoryStep {
                    peer,
                    counter_end: counter + len as i32 - 1,
                    timestamp,
                    deps,
                },
            )
        })
        .collect();
    // lamport 同值时按 peer 决序,与 ChangeMeta 的 Ord 一致。
    steps.sort_by_key(|(lamport, step)| (*lamport, step.peer));
    let steps: Vec<HistoryStep> = steps.into_iter().map(|(_, step)| step).collect();

    for (index, step) in steps.iter().enumerate() {
        let expected: Option<ID> = if index == 0 {
            None
        } else {
            let previous = &steps[index - 1];
            Some(ID::new(previous.peer, previous.counter_end))
        };
        let deps: Vec<ID> = step.deps.iter().collect();
        let linear = match (expected, deps.as_slice()) {
            (None, []) => true,
            (Some(expected), [only]) => *only == expected,
            _ => false,
        };
        if !linear {
            return Err(ReplayMigrationError::NonLinearHistory {
                peer: step.peer,
                counter: step.counter_end,
            });
        }
    }
    Ok(steps)
}

/// 一行正文与它的稳定块 id。
#[derive(Clone, PartialEq, Eq)]
struct Line {
    id: String,
    text: String,
}

/// 相邻时刻的行身份追踪:公共前缀/后缀保 id,中段整体替换。
fn track_lines(previous: &[Line], text: &str) -> Vec<Line> {
    let new_texts: Vec<&str> = text.split('\n').collect();

    let mut prefix = 0;
    while prefix < previous.len()
        && prefix < new_texts.len()
        && previous[prefix].text == new_texts[prefix]
    {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < previous.len() - prefix
        && suffix < new_texts.len() - prefix
        && previous[previous.len() - 1 - suffix].text == new_texts[new_texts.len() - 1 - suffix]
    {
        suffix += 1;
    }

    let mut lines: Vec<Line> = Vec::with_capacity(new_texts.len());
    lines.extend_from_slice(&previous[..prefix]);
    let middle_old = &previous[prefix..previous.len() - suffix];
    let middle_new = &new_texts[prefix..new_texts.len() - suffix];
    for (offset, text) in middle_new.iter().enumerate() {
        // 中段等长视为原位编辑:保 id 只换文本。不等长则中段换新 id。
        if middle_old.len() == middle_new.len() {
            lines.push(Line {
                id: middle_old[offset].id.clone(),
                text: text.to_string(),
            });
        } else {
            lines.push(Line {
                id: uuid::Uuid::new_v4().to_string(),
                text: text.to_string(),
            });
        }
    }
    lines.extend_from_slice(&previous[previous.len() - suffix..]);
    lines
}

/// 目标文档的块写入器:按行 diff 施加最小容器操作,并维护 id → 文本
/// 容器的登记表(逐时刻验证从容器态直读)。
struct BlockWriter {
    texts: HashMap<String, LoroText>,
}

impl BlockWriter {
    fn new(_target: &LoroDoc) -> Self {
        Self {
            texts: HashMap::new(),
        }
    }

    fn list(target: &LoroDoc) -> LoroList {
        target.get_list(TRANSCRIPT_UTTERANCES)
    }

    fn apply(
        &mut self,
        target: &LoroDoc,
        previous: &[Line],
        next: &[Line],
    ) -> Result<(), ReplayMigrationError> {
        let list = Self::list(target);

        // 删除:旧有新无,按索引降序。
        let next_ids: std::collections::HashSet<&str> =
            next.iter().map(|line| line.id.as_str()).collect();
        for (index, line) in previous.iter().enumerate().rev() {
            if !next_ids.contains(line.id.as_str()) {
                list.delete(index, 1).map_err(loro_err)?;
                self.texts.remove(&line.id);
            }
        }

        // 插入与原位更新(next 序)。
        let previous_ids: std::collections::HashSet<&str> =
            previous.iter().map(|line| line.id.as_str()).collect();
        for (index, line) in next.iter().enumerate() {
            if previous_ids.contains(line.id.as_str()) {
                let text = self
                    .texts
                    .get(&line.id)
                    .expect("登记表与文档同步维护,已存块必有文本容器");
                if text.to_string() != line.text {
                    text.update(&line.text, loro::UpdateOptions::default())
                        .map_err(loro_err)?;
                }
            } else {
                let block = list
                    .insert_container(index, LoroMap::new())
                    .map_err(loro_err)?;
                block.insert("id", line.id.as_str()).map_err(loro_err)?;
                // owner 终态统一赋值;历史时刻先占位 user,不参与验证。
                block.insert("owner", "user").map_err(loro_err)?;
                let text = block
                    .insert_container("text", LoroText::new())
                    .map_err(loro_err)?;
                text.update(&line.text, loro::UpdateOptions::default())
                    .map_err(loro_err)?;
                block
                    .insert_container("lanes", LoroMap::new())
                    .map_err(loro_err)?;
                self.texts.insert(line.id.clone(), text);
            }
        }
        Ok(())
    }

    /// 从容器态直读拼正文(验证专用,不经任何缓存)。
    fn render(&self, target: &LoroDoc) -> Result<String, ReplayMigrationError> {
        let list = Self::list(target);
        let mut lines: Vec<String> = Vec::with_capacity(list.len());
        for index in 0..list.len() {
            let Some(loro::ValueOrContainer::Container(loro::Container::Map(block))) =
                list.get(index)
            else {
                return Err(loro_err("句块不是 Map 容器"));
            };
            let Some(loro::ValueOrContainer::Container(loro::Container::Text(text))) =
                block.get("text")
            else {
                return Err(loro_err("句块缺 text 容器"));
            };
            lines.push(text.to_string());
        }
        Ok(lines.join("\n"))
    }
}

/// 终态 owner:`## <session_id>` 节头起进入该 session 的采集段,直到下一
/// 个节头;节头之前的行归 user。节头行本身属于该 session。
fn stamp_owners(
    target: &LoroDoc,
    lines: &[Line],
    _writer: &BlockWriter,
) -> Result<(), ReplayMigrationError> {
    let list = BlockWriter::list(target);
    let mut owner: Option<String> = None;
    for (index, line) in lines.iter().enumerate() {
        if let Some(session_id) = line.text.strip_prefix("## ") {
            let session_id = session_id.trim();
            if !session_id.is_empty() {
                owner = Some(format!("capture:{session_id}"));
            }
        }
        let Some(loro::ValueOrContainer::Container(loro::Container::Map(block))) = list.get(index)
        else {
            return Err(loro_err("句块不是 Map 容器"));
        };
        let value = owner.clone().unwrap_or_else(|| "user".to_string());
        block.insert("owner", value.as_str()).map_err(loro_err)?;
    }
    Ok(())
}

/// 销毁收据原样搬运(终态)。
fn copy_receipts(legacy: &LoroDoc, target: &LoroDoc) -> Result<(), ReplayMigrationError> {
    let source = legacy.get_map(PURGE_RECEIPTS);
    let destination = target.get_map(PURGE_RECEIPTS);
    if let LoroValue::Map(entries) = source.get_value() {
        for (key, value) in entries.iter() {
            if let LoroValue::Bool(flag) = value {
                destination.insert(key.as_str(), *flag).map_err(loro_err)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript_projection::TranscriptProjection;

    /// 造一份第 1 纪元转录稿:多次提交,机器节 + 用户订正,带时间戳。
    fn legacy_with_history() -> LoroDoc {
        let doc = LoroDoc::new();
        // 旧文档默认按时间间隔合并相邻提交;夹具关掉它,保住逐提交
        // 粒度——迁移器只能保真 oplog 实际保存下来的东西。
        doc.set_change_merge_interval(0);
        let text = doc.get_text("content");
        text.insert(0, "## session-a\n原文第一句\n译文第一句\n")
            .unwrap();
        doc.commit_with(loro::CommitOptions::new().timestamp(1_000));

        text.insert(text.len_unicode(), "原文第二句\n").unwrap();
        doc.commit_with(loro::CommitOptions::new().timestamp(2_000));

        // 用户订正第一句(原位替换)。
        let needle = "原文第一句";
        let content = text.to_string();
        let pos = content.find(needle).unwrap();
        let char_pos = content[..pos].chars().count();
        text.delete(char_pos, needle.chars().count()).unwrap();
        text.insert(char_pos, "原文第一句(订正)").unwrap();
        doc.commit_with(loro::CommitOptions::new().timestamp(3_000));

        doc.get_map(PURGE_RECEIPTS)
            .insert("session-old", true)
            .unwrap();
        doc.commit_with(loro::CommitOptions::new().timestamp(4_000));
        doc
    }

    #[test]
    fn linear_history_migrates_and_final_text_matches() {
        let legacy = legacy_with_history();
        let migrated = migrate_transcript_history(&legacy).unwrap();

        assert_eq!(document_kind(&migrated), Some(DocumentKind::Transcript));

        let projection = TranscriptProjection::open(migrated).unwrap();
        let blocks = projection.blocks();
        let joined: Vec<String> = blocks.iter().map(|b| b.text.clone()).collect();
        assert_eq!(
            joined.join("\n"),
            legacy.get_text("content").to_string(),
            "终态正文逐字节一致"
        );
    }

    #[test]
    fn owners_follow_section_headers() {
        let legacy = LoroDoc::new();
        let text = legacy.get_text("content");
        text.insert(0, "开头的用户笔记\n## session-a\n机器句\n")
            .unwrap();
        legacy.commit();

        let migrated = migrate_transcript_history(&legacy).unwrap();
        let projection = TranscriptProjection::open(migrated).unwrap();
        let blocks = projection.blocks();
        assert_eq!(blocks[0].owner, "user");
        assert_eq!(blocks[1].owner, "capture:session-a");
        assert_eq!(blocks[2].owner, "capture:session-a");
    }

    #[test]
    fn receipts_are_carried_over() {
        let legacy = legacy_with_history();
        let migrated = migrate_transcript_history(&legacy).unwrap();
        let receipts = migrated.get_map(PURGE_RECEIPTS);
        assert_eq!(
            receipts.get("session-old").map(|v| v.get_deep_value()),
            Some(LoroValue::Bool(true))
        );
    }

    /// 提交身份随历史:新文档的每个提交保留原 peer 与原时间戳。
    #[test]
    fn peers_and_timestamps_survive_replay() {
        let legacy = legacy_with_history();
        let legacy_peer = legacy.peer_id();
        let migrated = migrate_transcript_history(&legacy).unwrap();

        let mut timestamps: Vec<i64> = Vec::new();
        let mut peers: std::collections::HashSet<u64> = Default::default();
        let heads: Vec<ID> = migrated.oplog_frontiers().iter().collect();
        migrated
            .travel_change_ancestors(&heads, &mut |meta| {
                timestamps.push(meta.timestamp);
                peers.insert(meta.id.peer);
                ControlFlow::Continue(())
            })
            .unwrap();

        assert!(
            peers.contains(&legacy_peer),
            "原 peer 必须出现在新文档的历史里"
        );
        // 4000 是纯收据提交:不动正文,重放侧无事务可提交,内容按决策
        // 文档「终态原样搬」进入最后的迁移提交。正文提交逐一保留。
        for expected in [1_000, 2_000, 3_000] {
            assert!(
                timestamps.contains(&expected),
                "原时间戳 {expected} 必须保留,实际 {timestamps:?}"
            );
        }
    }

    /// 并发历史(两个 peer 各自分叉再合并)拒绝迁移。
    #[test]
    fn non_linear_history_is_refused() {
        let a = LoroDoc::new();
        a.get_text("content").insert(0, "共同起点\n").unwrap();
        a.commit();
        let b = LoroDoc::new();
        b.import(&a.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        a.get_text("content").insert(0, "甲的分支 ").unwrap();
        a.commit();
        b.get_text("content").insert(0, "乙的分支 ").unwrap();
        b.commit();
        a.import(&b.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        assert!(matches!(
            migrate_transcript_history(&a),
            Err(ReplayMigrationError::NonLinearHistory { .. })
        ));
    }

    /// 空文档:零历史,迁出空转录稿。
    #[test]
    fn empty_legacy_yields_empty_transcript() {
        let legacy = LoroDoc::new();
        let migrated = migrate_transcript_history(&legacy).unwrap();
        let projection = TranscriptProjection::open(migrated).unwrap();
        assert!(projection.blocks().is_empty());
    }
}
