//! T2 转录稿的投影门面:机器与用户对句块文档的全部写入走这里。
//!
//! 阶段 3 的 T2 侧(决策文档「转录稿的编辑器映射近乎平凡」):转录稿 UI
//! 是行式渲染,块状态 ↔ 行直连,不经过平文本层——这层门面就是那个直连
//! 的 Rust 端。它把 vt-mirror 的通用 set_state 收窄成转录稿仅有的几个
//! 动词,动词之外的操作(重排、删块、改 owner)在这层**没有函数**,
//! 结构性排除优于纪律性排除。
//!
//! 「机器让人」的策略刻意不在这里:谁的车道被用户接管是 SQLite 事实层
//! (车道 edit revision)知道的事,调用方把结论作为 `frozen_lanes` 显式
//! 传进来,本层只负责「冻结的车道机器绝不覆盖」这一条执行。策略与执行
//! 分开,才能各自单测。

use std::collections::{BTreeMap, BTreeSet};

use loro::LoroDoc;
use serde_json::json;
use vt_mirror::mirror::{Mirror, MirrorError, MirrorOptions, SetStateOptions};
use vt_mirror::value::Value;

use crate::document_schema::{transcript_schema, SUPPORTED_LANES, TRANSCRIPT_UTTERANCES};

/// 批注块的 owner 值,与 block_guard 的判定一致。
pub const USER_OWNER: &str = "user";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TranscriptProjectionError {
    #[error("车道 {0:?} 不在八语范围内")]
    LaneOutOfScope(String),
    #[error("句块 {0:?} 不存在")]
    BlockNotFound(String),
    #[error("句块 id 不可为空")]
    EmptyBlockId,
    #[error("镜像层错误: {0}")]
    Mirror(String),
}

impl From<MirrorError> for TranscriptProjectionError {
    fn from(error: MirrorError) -> Self {
        Self::Mirror(error.to_string())
    }
}

/// 一个句块的类型化视图。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UtteranceBlock {
    pub id: String,
    pub owner: String,
    pub text: String,
    /// 只含实际存在的车道。
    pub lanes: BTreeMap<String, String>,
}

/// 机器投影的一次句块写入。
#[derive(Debug, Clone)]
pub struct MachineBlockWrite {
    pub id: String,
    /// "capture:<session_id>"
    pub owner: String,
    pub text: String,
    pub lanes: BTreeMap<String, String>,
}

/// T2 文档句柄。克隆共享同一底层镜像。
#[derive(Clone)]
pub struct TranscriptProjection {
    mirror: Mirror,
}

impl TranscriptProjection {
    /// 打开(或接管)一份 T2 文档。文档应当出自
    /// [`crate::document_schema::new_block_document`] 或同纪元的快照。
    pub fn open(doc: LoroDoc) -> Result<Self, TranscriptProjectionError> {
        let mirror = Mirror::new(doc, Some(transcript_schema()), MirrorOptions::default())?;
        Ok(Self { mirror })
    }

    pub fn doc(&self) -> &LoroDoc {
        self.mirror.doc()
    }

    /// 当前句块序列(文档序)。
    pub fn blocks(&self) -> Vec<UtteranceBlock> {
        let state = self.mirror.get_state();
        let Some(items) = state.get(TRANSCRIPT_UTTERANCES).and_then(Value::as_array) else {
            return Vec::new();
        };
        items
            .iter()
            .filter_map(|item| {
                Some(UtteranceBlock {
                    id: item.get("id")?.as_str()?.to_string(),
                    owner: item
                        .get("owner")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    text: item
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    lanes: item
                        .get("lanes")
                        .and_then(Value::as_object)
                        .map(|lanes| {
                            lanes
                                .iter()
                                .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                                .collect()
                        })
                        .unwrap_or_default(),
                })
            })
            .collect()
    }

    /// 对端同步进来的改动落到状态里(Mirror 的 import 回流是被动的;
    /// 主动读取前调用方可用它强制收敛)。
    pub fn refresh(&self) -> Vec<UtteranceBlock> {
        self.mirror.sync_from_loro();
        self.blocks()
    }

    /// 机器投影:按 id 追加或更新一个采集句块。
    ///
    /// - 块不存在:插到 `insert_before` 指向的块之前;`None` 则追加到
    ///   文档尾。锚点在**写入时**按 id 解析,对并发到达的远端块免疫;
    ///   锚点块不存在按 [`TranscriptProjectionError::BlockNotFound`] 大声
    ///   拒绝。排序**策略**(按 sequence 找锚点)是调用方的事,本层只
    ///   执行——与 frozen_lanes 同一分工;
    /// - 块已存在:更新 `text` 与未冻结的车道,位置不动(重排在这层
    ///   没有函数)。`frozen_lanes` 里的车道**原样保留**——那是用户接管
    ///   的内容,机器从此不碰;
    /// - 机器写入永远不减少车道:写入里缺席的既有车道保留。
    pub fn machine_upsert_block(
        &self,
        write: MachineBlockWrite,
        frozen_lanes: &BTreeSet<String>,
        insert_before: Option<&str>,
    ) -> Result<(), TranscriptProjectionError> {
        if write.id.is_empty() {
            return Err(TranscriptProjectionError::EmptyBlockId);
        }
        validate_lanes(write.lanes.keys())?;

        let mut state = self.mirror.get_state();
        let items = ensure_items(&mut state);

        match items
            .iter_mut()
            .find(|item| item.get("id").and_then(Value::as_str) == Some(write.id.as_str()))
        {
            Some(existing) => {
                existing["text"] = json!(write.text);
                let lanes = existing["lanes"]
                    .as_object_mut()
                    .expect("schema 保证 lanes 是对象");
                for (lane, text) in &write.lanes {
                    if frozen_lanes.contains(lane) {
                        continue; // 机器让人:用户接管的车道机器绝不覆盖
                    }
                    lanes.insert(lane.clone(), json!(text));
                }
            }
            None => {
                let block = json!({
                    "id": write.id,
                    "owner": write.owner,
                    "text": write.text,
                    "lanes": write.lanes,
                });
                match insert_before {
                    None => items.push(block),
                    Some(anchor) => {
                        let Some(index) = items.iter().position(|item| {
                            item.get("id").and_then(Value::as_str) == Some(anchor)
                        }) else {
                            return Err(TranscriptProjectionError::BlockNotFound(
                                anchor.to_string(),
                            ));
                        };
                        items.insert(index, block);
                    }
                }
            }
        }

        self.commit(state, "machine")
    }

    /// 用户订正一条车道(本地编辑自由:任何块的任何在范围车道)。
    pub fn user_replace_lane(
        &self,
        block_id: &str,
        lane: &str,
        text: &str,
    ) -> Result<(), TranscriptProjectionError> {
        validate_lanes([&lane.to_string()])?;
        self.mutate_block(block_id, "user", |item| {
            item["lanes"][lane] = json!(text);
        })
    }

    /// 用户订正原文车道。
    pub fn user_replace_text(
        &self,
        block_id: &str,
        text: &str,
    ) -> Result<(), TranscriptProjectionError> {
        self.mutate_block(block_id, "user", |item| {
            item["text"] = json!(text);
        })
    }

    /// 用户在句块之间插一个批注块(owner 恒为 "user",这层没有别的
    /// 选项)。`index` 越界时按追加处理。
    pub fn insert_annotation(
        &self,
        index: usize,
        id: &str,
        text: &str,
    ) -> Result<(), TranscriptProjectionError> {
        if id.is_empty() {
            return Err(TranscriptProjectionError::EmptyBlockId);
        }
        let mut state = self.mirror.get_state();
        let items = ensure_items(&mut state);
        let annotation = json!({
            "id": id,
            "owner": USER_OWNER,
            "text": text,
            "lanes": {},
        });
        let index = index.min(items.len());
        items.insert(index, annotation);
        self.commit(state, "user")
    }

    /// 销毁链专用入口:删除 `session_id` 采集所属的全部句块,返回删除数。
    ///
    /// 门面的动词集刻意没有删块函数——结构性排除机器与用户的删除;销毁
    /// 是隐私义务,是唯一例外,所以它绕开动词集、按 owner 整族删除:
    /// - 只删 `owner == "capture:<session_id>"` 的块;
    /// - 用户批注与其它 session 的块原样保留;
    /// - 幂等:没有目标块时是空操作(崩溃重放的空操作路径,收据判定
    ///   仍由调用方的销毁收据 map 承担,两纪元同名同义)。
    pub fn purge_session_blocks(
        &self,
        session_id: &str,
    ) -> Result<usize, TranscriptProjectionError> {
        let owner = format!("capture:{session_id}");
        let mut state = self.mirror.get_state();
        let items = ensure_items(&mut state);
        let before = items.len();
        items.retain(|item| item.get("owner").and_then(Value::as_str) != Some(owner.as_str()));
        let removed = before - items.len();
        if removed == 0 {
            return Ok(0);
        }
        self.commit(state, "purge")?;
        Ok(removed)
    }

    fn mutate_block(
        &self,
        block_id: &str,
        origin: &str,
        mutate: impl FnOnce(&mut Value),
    ) -> Result<(), TranscriptProjectionError> {
        let mut state = self.mirror.get_state();
        let items = ensure_items(&mut state);
        let Some(item) = items
            .iter_mut()
            .find(|item| item.get("id").and_then(Value::as_str) == Some(block_id))
        else {
            return Err(TranscriptProjectionError::BlockNotFound(
                block_id.to_string(),
            ));
        };
        mutate(item);
        self.commit(state, origin)
    }

    fn commit(&self, state: Value, origin: &str) -> Result<(), TranscriptProjectionError> {
        self.mirror.set_state(
            |_| state.clone(),
            SetStateOptions {
                tags: Some(vec![origin.to_string()]),
            },
        )?;
        Ok(())
    }
}

fn ensure_items(state: &mut Value) -> &mut Vec<Value> {
    if !state
        .get(TRANSCRIPT_UTTERANCES)
        .is_some_and(Value::is_array)
    {
        state[TRANSCRIPT_UTTERANCES] = json!([]);
    }
    state[TRANSCRIPT_UTTERANCES]
        .as_array_mut()
        .expect("上面刚保证过是数组")
}

fn validate_lanes<'a>(
    lanes: impl IntoIterator<Item = &'a String>,
) -> Result<(), TranscriptProjectionError> {
    for lane in lanes {
        if !SUPPORTED_LANES.contains(&lane.as_str()) {
            return Err(TranscriptProjectionError::LaneOutOfScope(lane.clone()));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document_schema::{new_block_document, DocumentKind};
    use proptest::prelude::*;

    fn projection() -> TranscriptProjection {
        TranscriptProjection::open(new_block_document(DocumentKind::Transcript)).unwrap()
    }

    fn machine(id: &str, text: &str, lanes: &[(&str, &str)]) -> MachineBlockWrite {
        MachineBlockWrite {
            id: id.to_string(),
            owner: "capture:s1".to_string(),
            text: text.to_string(),
            lanes: lanes
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }

    #[test]
    fn machine_appends_in_arrival_order() {
        let projection = projection();
        projection
            .machine_upsert_block(machine("u1", "一", &[]), &BTreeSet::new(), None)
            .unwrap();
        projection
            .machine_upsert_block(machine("u2", "二", &[]), &BTreeSet::new(), None)
            .unwrap();
        let ids: Vec<_> = projection.blocks().into_iter().map(|b| b.id).collect();
        assert_eq!(ids, vec!["u1", "u2"]);
    }

    #[test]
    fn machine_update_respects_frozen_lanes() {
        let projection = projection();
        projection
            .machine_upsert_block(machine("u1", "一", &[("zh", "壹")]), &BTreeSet::new(), None)
            .unwrap();
        projection
            .user_replace_lane("u1", "zh", "壹(人工)")
            .unwrap();

        // 机器带着新译文回来,但 zh 已被用户接管。
        let frozen: BTreeSet<String> = ["zh".to_string()].into();
        projection
            .machine_upsert_block(
                machine("u1", "一(修订)", &[("zh", "壹(机器v2)"), ("ja", "壱")]),
                &frozen,
                None,
            )
            .unwrap();

        let block = &projection.blocks()[0];
        assert_eq!(block.text, "一(修订)", "原文车道机器照常推进");
        assert_eq!(block.lanes["zh"], "壹(人工)", "冻结车道机器绝不覆盖");
        assert_eq!(block.lanes["ja"], "壱", "未冻结车道正常落地");
    }

    #[test]
    fn machine_never_removes_existing_lanes() {
        let projection = projection();
        projection
            .machine_upsert_block(
                machine("u1", "一", &[("zh", "壹"), ("ja", "壱")]),
                &BTreeSet::new(),
                None,
            )
            .unwrap();
        // 第二次写入只带 zh:ja 必须保留。
        projection
            .machine_upsert_block(
                machine("u1", "一", &[("zh", "壹v2")]),
                &BTreeSet::new(),
                None,
            )
            .unwrap();
        let block = &projection.blocks()[0];
        assert_eq!(block.lanes["ja"], "壱");
        assert_eq!(block.lanes["zh"], "壹v2");
    }

    #[test]
    fn annotations_insert_between_blocks_with_user_owner() {
        let projection = projection();
        projection
            .machine_upsert_block(machine("u1", "一", &[]), &BTreeSet::new(), None)
            .unwrap();
        projection
            .machine_upsert_block(machine("u2", "二", &[]), &BTreeSet::new(), None)
            .unwrap();
        projection.insert_annotation(1, "n1", "这里说错了").unwrap();

        let blocks = projection.blocks();
        assert_eq!(
            blocks.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec!["u1", "n1", "u2"]
        );
        assert_eq!(blocks[1].owner, USER_OWNER);
    }

    #[test]
    fn machine_insert_before_places_a_late_block_at_its_anchor() {
        let projection = projection();
        projection
            .machine_upsert_block(machine("u0", "零", &[]), &BTreeSet::new(), None)
            .unwrap();
        projection
            .machine_upsert_block(machine("u2", "二", &[]), &BTreeSet::new(), None)
            .unwrap();
        // 迟到的 u1 按锚点插到 u2 之前,而不是尾部。
        projection
            .machine_upsert_block(machine("u1", "一", &[]), &BTreeSet::new(), Some("u2"))
            .unwrap();
        let ids: Vec<_> = projection.blocks().into_iter().map(|b| b.id).collect();
        assert_eq!(ids, vec!["u0", "u1", "u2"]);

        // 已存在的块再带锚点只更新,位置不动。
        projection
            .machine_upsert_block(machine("u0", "零(修订)", &[]), &BTreeSet::new(), Some("u2"))
            .unwrap();
        let blocks = projection.blocks();
        assert_eq!(blocks[0].id, "u0");
        assert_eq!(blocks[0].text, "零(修订)");
    }

    #[test]
    fn machine_insert_before_missing_anchor_is_a_named_error() {
        let projection = projection();
        assert_eq!(
            projection.machine_upsert_block(
                machine("u1", "一", &[]),
                &BTreeSet::new(),
                Some("ghost")
            ),
            Err(TranscriptProjectionError::BlockNotFound("ghost".into()))
        );
        assert!(projection.blocks().is_empty(), "拒绝的写入不落任何状态");
    }

    #[test]
    fn out_of_scope_lanes_are_refused_at_the_api() {
        let projection = projection();
        projection
            .machine_upsert_block(machine("u1", "一", &[]), &BTreeSet::new(), None)
            .unwrap();
        assert_eq!(
            projection.user_replace_lane("u1", "my", "缅甸语"),
            Err(TranscriptProjectionError::LaneOutOfScope("my".into()))
        );
        assert_eq!(
            projection.machine_upsert_block(
                machine("u2", "二", &[("yue", "粤")]),
                &BTreeSet::new(),
                None
            ),
            Err(TranscriptProjectionError::LaneOutOfScope("yue".into()))
        );
    }

    #[test]
    fn missing_block_is_a_named_error() {
        let projection = projection();
        assert_eq!(
            projection.user_replace_lane("ghost", "zh", "x"),
            Err(TranscriptProjectionError::BlockNotFound("ghost".into()))
        );
    }

    #[test]
    fn purge_removes_only_the_target_sessions_machine_blocks() {
        let projection = projection();
        projection
            .machine_upsert_block(machine("u1", "一", &[("zh", "壹")]), &BTreeSet::new(), None)
            .unwrap();
        projection.insert_annotation(1, "n1", "批注").unwrap();
        let mut other = machine("b1", "乙", &[]);
        other.owner = "capture:s2".into();
        projection
            .machine_upsert_block(other, &BTreeSet::new(), None)
            .unwrap();

        assert_eq!(projection.purge_session_blocks("s1").unwrap(), 1);
        let remaining: Vec<_> = projection.blocks().into_iter().map(|b| b.id).collect();
        assert_eq!(remaining, vec!["n1", "b1"], "批注与他 session 的块保留");

        // 幂等:再销毁一次是空操作。
        assert_eq!(projection.purge_session_blocks("s1").unwrap(), 0);
    }

    /// 两端并发:A 机器追加,B 用户订正,交换后一致。
    #[test]
    fn two_projections_converge() {
        let a = projection();
        a.machine_upsert_block(machine("u1", "一", &[("zh", "壹")]), &BTreeSet::new(), None)
            .unwrap();

        let doc_b = new_block_document(DocumentKind::Transcript);
        doc_b
            .import(&a.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        let b = TranscriptProjection::open(doc_b).unwrap();

        a.machine_upsert_block(machine("u2", "二", &[]), &BTreeSet::new(), None)
            .unwrap();
        b.user_replace_lane("u1", "zh", "壹(人工)").unwrap();

        a.doc()
            .import(&b.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        b.doc()
            .import(&a.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        assert_eq!(a.doc().get_deep_value(), b.doc().get_deep_value());
        let blocks = a.refresh();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].lanes["zh"], "壹(人工)");
    }

    // ---- 性质测试:门面与参照模型逐步等价 ----

    /// 参照模型:一个普通 Vec,按同样的规则演算。
    #[derive(Default, Clone)]
    struct Model {
        blocks: Vec<UtteranceBlock>,
    }

    impl Model {
        fn machine_upsert(&mut self, write: &MachineBlockWrite, frozen: &BTreeSet<String>) {
            match self.blocks.iter_mut().find(|b| b.id == write.id) {
                Some(block) => {
                    block.text = write.text.clone();
                    for (lane, text) in &write.lanes {
                        if !frozen.contains(lane) {
                            block.lanes.insert(lane.clone(), text.clone());
                        }
                    }
                }
                None => self.blocks.push(UtteranceBlock {
                    id: write.id.clone(),
                    owner: write.owner.clone(),
                    text: write.text.clone(),
                    lanes: write.lanes.clone(),
                }),
            }
        }

        fn user_lane(&mut self, id: &str, lane: &str, text: &str) {
            if let Some(block) = self.blocks.iter_mut().find(|b| b.id == id) {
                block.lanes.insert(lane.to_string(), text.to_string());
            }
        }

        fn annotate(&mut self, index: usize, id: &str, text: &str) {
            let index = index.min(self.blocks.len());
            self.blocks.insert(
                index,
                UtteranceBlock {
                    id: id.to_string(),
                    owner: USER_OWNER.to_string(),
                    text: text.to_string(),
                    lanes: BTreeMap::new(),
                },
            );
        }
    }

    #[derive(Debug, Clone)]
    enum Op {
        MachineUpsert {
            id: u8,
            text: String,
            lane_text: String,
            freeze_zh: bool,
        },
        UserLane {
            id: u8,
            text: String,
        },
        Annotate {
            index: u8,
            id: u8,
            text: String,
        },
    }

    fn op_strategy() -> impl Strategy<Value = Op> {
        prop_oneof![
            (0u8..6, "[a-z一-鿿]{0,8}", "[a-z一-鿿]{0,8}", any::<bool>()).prop_map(
                |(id, text, lane_text, freeze_zh)| Op::MachineUpsert {
                    id,
                    text,
                    lane_text,
                    freeze_zh
                }
            ),
            (0u8..6, "[a-z一-鿿]{0,8}").prop_map(|(id, text)| Op::UserLane { id, text }),
            (0u8..8, 0u8..6, "[a-z一-鿿]{0,8}").prop_map(|(index, id, text)| Op::Annotate {
                index,
                id,
                text
            }),
        ]
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        /// 任意操作序列下,门面读出的块序列与参照模型逐步一致。
        #[test]
        fn projection_matches_reference_model(ops in prop::collection::vec(op_strategy(), 1..24)) {
            let projection = projection();
            let mut model = Model::default();

            for (step, op) in ops.iter().enumerate() {
                match op {
                    Op::MachineUpsert { id, text, lane_text, freeze_zh } => {
                        let id = format!("u{id}");
                        let frozen: BTreeSet<String> = if *freeze_zh {
                            ["zh".to_string()].into()
                        } else {
                            BTreeSet::new()
                        };
                        let write = MachineBlockWrite {
                            id: id.clone(),
                            owner: "capture:s1".into(),
                            text: text.clone(),
                            lanes: [("zh".to_string(), lane_text.clone())].into(),
                        };
                        projection.machine_upsert_block(write.clone(), &frozen, None).unwrap();
                        model.machine_upsert(&write, &frozen);
                    }
                    Op::UserLane { id, text } => {
                        let id = format!("u{id}");
                        let result = projection.user_replace_lane(&id, "zh", text);
                        if result.is_ok() {
                            model.user_lane(&id, "zh", text);
                        } else {
                            prop_assert_eq!(
                                result,
                                Err(TranscriptProjectionError::BlockNotFound(id.clone()))
                            );
                        }
                    }
                    Op::Annotate { index, id, text } => {
                        // 批注 id 独立命名空间,且允许重复 upsert 语义之外:
                        // 用 step 保证唯一。
                        let id = format!("n{id}-{step}");
                        projection.insert_annotation(*index as usize, &id, text).unwrap();
                        model.annotate(*index as usize, &id, text);
                    }
                }
                prop_assert_eq!(projection.blocks(), model.blocks.clone());
            }
        }
    }
}
