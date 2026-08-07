//! 第 2 纪元文档的远端更新守卫:按 kind 换规则手册的静态判定。
//!
//! 决策文档承诺的收益在这里兑现:第 1 纪元的守卫
//! (`remote_update_touches_capture_owned_range`)必须重放后逐段走
//! TextDelta 判定区间越界,边界情形靠枚举;块结构下所有权是**块的属性**,
//! 判定退化为查表——「这份更新碰了哪些容器 → 容器属于哪个块 → 块的
//! owner 是谁」。副本上试导入仍然要做(不导入无从知道碰了什么),但
//! 裁决本身是结构性的,不再有位置运算。
//!
//! 规则手册(docs/architecture/document-schema-decision.md「双侧写」):
//!
//! - `kind = transcript`:块序不可变(move 一律拒绝);句块不可远端删除;
//!   远端只能**插 owner = "user" 的批注块**、**改 owner = "user" 的块**、
//!   **订正采集块的车道内容**(text 与 lanes 子树——协作订正的人类层);
//!   采集块的 map 本身(owner / id / 容器替换)与块的存在、顺序,远端
//!   一个字节都不能动。谁有资格订正由准入链的写入策略把关,宿主自己的
//!   机器投影则在 vt-share 准入层按「宿主即机器」豁免边界。
//! - `kind = note`:move/缩进/重排全放开,无采集块,owner 检查为空操作。
//! - 两类共享:根部 meta(纪元/kind)与销毁收据 map 是本机事实,远端
//!   更新不得触碰。
//!
//! 与准入链其它环节同一条家法:**判不出来一律拒收**。

use loro::event::{Diff, ListDiffItem};
use loro::{ContainerID, ContainerTrait, LoroDoc, LoroValue, ValueOrContainer};
use std::sync::{Arc, Mutex};

use crate::document_schema::{DocumentKind, NOTE_ROOT, TRANSCRIPT_UTTERANCES};
use crate::editor_bridge::DOCUMENT_META;

const PURGE_RECEIPTS: &str = "zulangue_session_purge_receipts";
/// 批注块的所有者标记。其余(`capture:<session>`)都是机器块。
const USER_OWNER: &str = "user";

/// 拒收理由。区分开是为了让上层能分别计数与告警(与 AdmissionDenial
/// 同一精神)。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum BlockAdmissionDenial {
    #[error("转录稿的块序是证据,move 一律拒绝")]
    MoveRefused,
    #[error("句块不可远端删除")]
    BlockDeleted,
    #[error("远端只能插入批注块(owner = \"user\")")]
    NonUserBlockInserted,
    #[error("改动落在非批注块上(owner = {owner:?})")]
    ForeignBlockTouched { owner: String },
    #[error("根部 meta 与销毁收据是本机事实,远端更新不得触碰")]
    FoundationTouched,
    #[error("更新无法解码或归属判不出来")]
    Undecidable,
}

/// 一条事件的静态摘要:回调里把借用的 DiffEvent 摘成可持有的事实。
struct TouchedContainer {
    target: ContainerID,
    /// 从根到 target 父级的祖先链(容器 id 序列)。
    ancestors: Vec<ContainerID>,
    /// 列表 diff 里的删除数。
    list_deletes: usize,
    /// 列表 diff 里是否有 move 产生的插入。
    has_move_insert: bool,
    /// 列表 diff 插入的条目(深值)。
    list_inserted: Vec<serde_json::Value>,
}

fn loro_value_to_json(value: &LoroValue) -> serde_json::Value {
    // 守卫只读 owner 字段与插入块的形状,serde 转换足够;失败按判不出来。
    serde_json::to_value(value).unwrap_or(serde_json::Value::Null)
}

/// 判一份远端更新能否合入 `kind` 文档。`current` 不会被改动,试导入发生
/// 在 fork 出来的副本上。
pub fn admit_block_update(
    current: &LoroDoc,
    kind: DocumentKind,
    update: &[u8],
) -> Result<(), BlockAdmissionDenial> {
    let fork = current.fork();
    let touched: Arc<Mutex<Vec<TouchedContainer>>> = Arc::new(Mutex::new(Vec::new()));

    let sink = touched.clone();
    // Subscription 存活期即观察期;守卫结束一起释放。
    let _subscription = fork.subscribe_root(Arc::new(move |event| {
        let mut sink = sink.lock().unwrap();
        for container_diff in &event.events {
            let mut summary = TouchedContainer {
                target: container_diff.target.clone(),
                ancestors: container_diff
                    .path
                    .iter()
                    .map(|(cid, _)| cid.clone())
                    .collect(),
                list_deletes: 0,
                has_move_insert: false,
                list_inserted: Vec::new(),
            };
            if let Diff::List(items) = &container_diff.diff {
                for item in items {
                    match item {
                        ListDiffItem::Delete { delete } => summary.list_deletes += delete,
                        ListDiffItem::Insert { insert, is_move } => {
                            if *is_move {
                                summary.has_move_insert = true;
                            }
                            for inserted in insert {
                                summary
                                    .list_inserted
                                    .push(loro_value_to_json(&inserted.get_deep_value()));
                            }
                        }
                        ListDiffItem::Retain { .. } => {}
                    }
                }
            }
            sink.push(summary);
        }
    }));

    if fork.import(update).is_err() {
        return Err(BlockAdmissionDenial::Undecidable);
    }

    let touched = touched.lock().unwrap();
    for event in touched.iter() {
        // 归属链规范化:根 → … → target,与 path 是否含 target 无关。
        let mut chain: Vec<&ContainerID> = event.ancestors.iter().collect();
        if chain.last() != Some(&&event.target) {
            chain.push(&event.target);
        }
        let root = chain[0];
        let root_name = match root {
            ContainerID::Root { name, .. } => name.to_string(),
            // 根不是 Root 容器:归属判不出来,拒收。
            _ => return Err(BlockAdmissionDenial::Undecidable),
        };

        // 共享地基:两类文档一致,远端不得触碰。
        if root_name == DOCUMENT_META || root_name == PURGE_RECEIPTS {
            return Err(BlockAdmissionDenial::FoundationTouched);
        }

        match kind {
            // 笔记:move/重排/增删全放开,无 owner 检查。
            DocumentKind::Note => {
                if root_name != NOTE_ROOT {
                    // 笔记文档里出现未知根容器:判不出来,拒收。
                    return Err(BlockAdmissionDenial::Undecidable);
                }
            }
            DocumentKind::Transcript => {
                if root_name != TRANSCRIPT_UTTERANCES {
                    return Err(BlockAdmissionDenial::Undecidable);
                }
                if event.has_move_insert {
                    return Err(BlockAdmissionDenial::MoveRefused);
                }

                let target_is_root_list = chain.len() == 1;
                if target_is_root_list {
                    // 根句块列表本身:删除即销毁证据,拒绝;插入只准批注块。
                    if event.list_deletes > 0 {
                        return Err(BlockAdmissionDenial::BlockDeleted);
                    }
                    for inserted in &event.list_inserted {
                        let owner = inserted.get("owner").and_then(|v| v.as_str());
                        if owner != Some(USER_OWNER) {
                            return Err(BlockAdmissionDenial::NonUserBlockInserted);
                        }
                    }
                } else {
                    // 块内改动:块容器是规范化链上根列表的直接孩子;target
                    // 自己是块(块的 map diff)或块的后代(text/lanes)。
                    //
                    // owner 从**导入前的本机文档**读:从 fork(导入后)读
                    // 等于让这份 update 自己给自己发通行证——先把 owner 改
                    // 成 "user" 再动内容就能冒充批注块。本机没有这个块时
                    // 才落到 fork(新插入的块,其 owner 已在根列表的插入
                    // 检查里核过)。
                    let block_cid = chain[1];
                    let block = if current.has_container(block_cid) {
                        current.get_map(block_cid.clone())
                    } else {
                        fork.get_map(block_cid.clone())
                    };
                    let owner = block.get("owner").map(|value| value.get_deep_value());
                    match owner {
                        Some(LoroValue::String(owner)) if owner.as_str() == USER_OWNER => {}
                        Some(LoroValue::String(owner)) => {
                            // 采集块:证据性质锁的是**存在、顺序与归属**——
                            // 块本身的 map(owner / id / 容器替换)远端不得
                            // 触碰。车道内容(text 与 lanes 子树)是可协作
                            // 订正的人类层,放行;写入策略(HostOnly)在
                            // 准入链上一格把关。
                            let lane_subtree = chain.get(2).is_some_and(|child| {
                                ["text", "lanes"].iter().any(|key| {
                                    matches!(
                                        block.get(key),
                                        Some(ValueOrContainer::Container(handler))
                                            if handler.id() == **child
                                    )
                                })
                            });
                            if !lane_subtree {
                                return Err(BlockAdmissionDenial::ForeignBlockTouched {
                                    owner: owner.to_string(),
                                });
                            }
                        }
                        // owner 缺失或不是字符串:判不出来,拒收。
                        _ => return Err(BlockAdmissionDenial::Undecidable),
                    }
                }
            }
        }
    }

    // 顺带用到一次 ValueOrContainer 的类型名,避免编译器对导入报闲话。
    let _: Option<ValueOrContainer> = None;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document_schema::{
        new_block_document, note_schema, transcript_schema, DocumentKind,
    };
    use serde_json::json;
    use vt_mirror::mirror::{Mirror, MirrorOptions};

    /// 建一份带内容的文档,返回(本机文档, 远端镜像)。远端从本机快照
    /// 分叉,之后在远端上做的改动导出成 update 给守卫判。
    fn pair(kind: DocumentKind, state: serde_json::Value) -> (LoroDoc, Mirror) {
        let schema = match kind {
            DocumentKind::Transcript => transcript_schema(),
            DocumentKind::Note => note_schema(),
        };
        let local = new_block_document(kind);
        let mirror = Mirror::new(
            local.clone(),
            Some(schema.clone()),
            MirrorOptions::default(),
        )
        .unwrap();
        mirror.set_state_merge(&state).unwrap();

        let remote_doc = LoroDoc::new();
        remote_doc
            .import(&local.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        let remote = Mirror::new(remote_doc, Some(schema), MirrorOptions::default()).unwrap();
        (local, remote)
    }

    fn update_since(local: &LoroDoc, remote: &Mirror) -> Vec<u8> {
        remote
            .doc()
            .export(loro::ExportMode::updates(&local.oplog_vv()))
            .unwrap()
    }

    fn block(id: &str, owner: &str, text: &str) -> serde_json::Value {
        json!({"id": id, "owner": owner, "text": text, "lanes": {}})
    }

    fn transcript_state() -> serde_json::Value {
        json!({TRANSCRIPT_UTTERANCES: [
            block("u1", "capture:s1", "机器写的第一句"),
            block("n1", "user", "用户的批注"),
        ]})
    }

    #[test]
    fn lane_corrections_on_capture_blocks_are_admitted() {
        // 车道内容(text 与 lanes 子树)是可协作订正的人类层。
        let (local, remote) = pair(DocumentKind::Transcript, transcript_state());
        let mut state = remote.get_state();
        state[TRANSCRIPT_UTTERANCES][0]["text"] = json!("远端订正机器句");
        state[TRANSCRIPT_UTTERANCES][0]["lanes"]["zh"] = json!("远端订正译文");
        remote
            .set_state(|_| state.clone(), Default::default())
            .unwrap();

        assert_eq!(
            admit_block_update(
                &local,
                DocumentKind::Transcript,
                &update_since(&local, &remote)
            ),
            Ok(())
        );
    }

    #[test]
    fn tampering_with_a_capture_blocks_identity_is_refused() {
        // 块的 map 本身(owner 等归属字段)仍然一个字节不能动。
        let (local, remote) = pair(DocumentKind::Transcript, transcript_state());
        let mut state = remote.get_state();
        state[TRANSCRIPT_UTTERANCES][0]["owner"] = json!("user");
        remote
            .set_state(|_| state.clone(), Default::default())
            .unwrap();

        assert_eq!(
            admit_block_update(
                &local,
                DocumentKind::Transcript,
                &update_since(&local, &remote)
            ),
            Err(BlockAdmissionDenial::ForeignBlockTouched {
                owner: "capture:s1".into()
            }),
            "owner 按导入前的本机文档判,update 无法自己给自己发通行证"
        );
    }

    #[test]
    fn editing_a_user_annotation_block_is_admitted() {
        let (local, remote) = pair(DocumentKind::Transcript, transcript_state());
        let mut state = remote.get_state();
        state[TRANSCRIPT_UTTERANCES][1]["text"] = json!("批注修订");
        remote
            .set_state(|_| state.clone(), Default::default())
            .unwrap();

        assert_eq!(
            admit_block_update(
                &local,
                DocumentKind::Transcript,
                &update_since(&local, &remote)
            ),
            Ok(())
        );
    }

    #[test]
    fn inserting_a_user_annotation_between_blocks_is_admitted() {
        let (local, remote) = pair(DocumentKind::Transcript, transcript_state());
        let mut state = remote.get_state();
        let items = state[TRANSCRIPT_UTTERANCES].as_array_mut().unwrap();
        items.insert(1, block("n2", "user", "插在句块之间的批注"));
        remote
            .set_state(|_| state.clone(), Default::default())
            .unwrap();

        assert_eq!(
            admit_block_update(
                &local,
                DocumentKind::Transcript,
                &update_since(&local, &remote)
            ),
            Ok(())
        );
    }

    #[test]
    fn inserting_a_capture_block_remotely_is_refused() {
        let (local, remote) = pair(DocumentKind::Transcript, transcript_state());
        let mut state = remote.get_state();
        state[TRANSCRIPT_UTTERANCES]
            .as_array_mut()
            .unwrap()
            .push(block("u9", "capture:s9", "冒充机器的句块"));
        remote
            .set_state(|_| state.clone(), Default::default())
            .unwrap();

        assert_eq!(
            admit_block_update(
                &local,
                DocumentKind::Transcript,
                &update_since(&local, &remote)
            ),
            Err(BlockAdmissionDenial::NonUserBlockInserted)
        );
    }

    #[test]
    fn deleting_a_block_remotely_is_refused() {
        let (local, remote) = pair(DocumentKind::Transcript, transcript_state());
        let mut state = remote.get_state();
        state[TRANSCRIPT_UTTERANCES]
            .as_array_mut()
            .unwrap()
            .remove(0);
        remote
            .set_state(|_| state.clone(), Default::default())
            .unwrap();

        assert_eq!(
            admit_block_update(
                &local,
                DocumentKind::Transcript,
                &update_since(&local, &remote)
            ),
            Err(BlockAdmissionDenial::BlockDeleted)
        );
    }

    #[test]
    fn tampering_with_the_meta_map_is_refused_for_both_kinds() {
        for kind in [DocumentKind::Transcript, DocumentKind::Note] {
            let local = new_block_document(kind);
            let remote = LoroDoc::new();
            remote
                .import(&local.export(loro::ExportMode::Snapshot).unwrap())
                .unwrap();
            remote
                .get_map(DOCUMENT_META)
                .insert("schema_epoch", 99i64)
                .unwrap();
            remote.commit();
            let update = remote
                .export(loro::ExportMode::updates(&local.oplog_vv()))
                .unwrap();
            assert_eq!(
                admit_block_update(&local, kind, &update),
                Err(BlockAdmissionDenial::FoundationTouched),
                "kind = {}",
                kind.as_str()
            );
        }
    }

    #[test]
    fn note_reorder_and_free_edits_are_admitted() {
        let node = |id: &str, text: &str| json!({"$": {"id": id}, "text": text, "children": []});
        let (local, remote) = pair(
            DocumentKind::Note,
            json!({NOTE_ROOT: {"$": {"id": "root"}, "children": [
                node("a", "一"), node("b", "二"), node("c", "三"),
            ]}}),
        );
        // 重排 + 改文本,随后单独删一个:笔记侧全放开。分两次提交是蓝本
        // 的已知局限(删除与 move 同批时 move 用陈旧索引,见 diff.rs 头
        // 注释),产品语义上两者本就是两次手势。
        let mut state = remote.get_state();
        state[NOTE_ROOT]["children"] = json!([
            {"$": {"id": "c"}, "text": "三(改)", "children": []},
            {"$": {"id": "a"}, "text": "一", "children": []},
            {"$": {"id": "b"}, "text": "二", "children": []},
        ]);
        remote
            .set_state(|_| state.clone(), Default::default())
            .unwrap();
        let mut state = remote.get_state();
        state[NOTE_ROOT]["children"].as_array_mut().unwrap().pop();
        remote
            .set_state(|_| state.clone(), Default::default())
            .unwrap();

        assert_eq!(
            admit_block_update(&local, DocumentKind::Note, &update_since(&local, &remote)),
            Ok(())
        );
    }

    #[test]
    fn garbage_updates_are_undecidable() {
        let local = new_block_document(DocumentKind::Transcript);
        assert_eq!(
            admit_block_update(&local, DocumentKind::Transcript, b"not-an-update"),
            Err(BlockAdmissionDenial::Undecidable)
        );
    }
}
