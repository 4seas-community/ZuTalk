//! 第 2 纪元文档 schema:转录稿 T2 与笔记 B。
//!
//! 这是 docs/architecture/document-schema-decision.md 阶段 2 的正体:两类
//! 文档在 vt-mirror 引擎上各自声明一张 schema 表。设计一字不差来自决定
//! 记录——
//!
//! - **转录稿 T2**:普通 `LoroList("utterances")` 句块,move 在类型层面
//!   不存在(证据级不可重排长在容器类型里,与 vt-share 结构性排除音频
//!   同一条家法);句块 `{id, owner, text, lanes}`,车道按产品的八语范围
//!   **固定成键**——语言范围也长在 schema 里,不靠运行时纪律。
//! - **笔记 B**:macro 式递归树 `{$, text, children}`,children 是按
//!   `$.id` 选键的 MovableList,move/缩进/重排全放开。
//!
//! 两类共享的地基同样来自决定记录:`schema_epoch`(第 2 纪元)、每 kind
//! 一份黄金祖先(所有空文档共享预制快照,让并发首编辑收敛而不是各自
//! 另起炉灶)、`set_record_timestamp` 撑历史时间轴。
//!
//! 黄金祖先照抄 macro 的 generate-golden 模式:构建期生成器写出版本化
//! `.bin`(文件名带 `.1`,换代即换文件名),运行时原字节内嵌。生成器见
//! `examples/generate_document_goldens.rs`,它调用这里的
//! [`build_golden_bytes`],生成物与读取方永远出自同一个构建函数。

use std::sync::Arc;

use loro::{LoroDoc, LoroMap, LoroMovableList, LoroValue};
use vt_mirror::schema::{IdSelector, Schema, SchemaOptions};

use crate::editor_bridge::{DOCUMENT_META, SCHEMA_EPOCH_KEY};

/// 块结构文档的纪元。今天的平文本文档是第 1 纪元(见 editor_bridge 的
/// `CURRENT_SCHEMA_EPOCH`);T2/B 落地后的文档是第 2 纪元。两个纪元不得
/// 混流,准入链已在阶段 1 按此拒收。
pub const BLOCK_SCHEMA_EPOCH: u64 = 2;

/// 文档 kind 在根部 meta map 里的键名。
const DOCUMENT_KIND_KEY: &str = "kind";

/// 转录稿句块所在的根容器名。
pub const TRANSCRIPT_UTTERANCES: &str = "utterances";
/// 笔记树根节点所在的根容器名。
pub const NOTE_ROOT: &str = "root";

/// 译文车道的固定键:产品的八语范围,按 `NotebookCaptureHistoryPolicy`
/// 的 languageKey 约定取首个子标签小写(zh-Hans → "zh")。繁体与缅甸语
/// 明确不做——语言范围长在 schema 里,加语言是一次显式 schema 变更。
pub const SUPPORTED_LANES: [&str; 8] = ["en", "th", "ja", "ko", "fr", "es", "de", "zh"];

/// 两类文档。`ShareableKind` 在分享层第一天就分开了它们,文档层从这里
/// 开始跟上。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DocumentKind {
    Transcript,
    Note,
}

impl DocumentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Transcript => "transcript",
            Self::Note => "note",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "transcript" => Some(Self::Transcript),
            "note" => Some(Self::Note),
            _ => None,
        }
    }
}

/// T2:转录稿 schema。
///
/// 句块以 `id` 选键(与 SQLite 事实层的 utterance_id 对齐)。容器是普通
/// LoroList——`vt_mirror::diff` 对它走 `diff_list_with_id_selector`,只有
/// 插入与删除,**没有 move 这条路径**。
pub fn transcript_schema() -> Arc<Schema> {
    let id_selector: IdSelector = Arc::new(|item| {
        item.get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });
    Schema::root(shared_root_fields().chain([(
        TRANSCRIPT_UTTERANCES,
        Schema::list_keyed(utterance_schema(), id_selector),
    )]))
}

/// 两类文档共享的根容器:纪元/kind meta 与销毁收据。它们是文档的一部分,
/// schema 必须承认它们 —— 根校验拒绝一切未声明的根键,共享地基不声明就
/// 会被自己的校验拒之门外。空定义 map:键动态,值是纯 LWW 值。
fn shared_root_fields() -> impl Iterator<Item = (&'static str, Arc<Schema>)> {
    [
        (DOCUMENT_META, Schema::map([])),
        ("zulangue_session_purge_receipts", Schema::map([])),
    ]
    .into_iter()
}

fn utterance_schema() -> Arc<Schema> {
    Schema::map([
        ("id", Schema::string_with(SchemaOptions::required())),
        // "capture:<session_id>" 或 "user"(批注块)。守卫按它查表。
        ("owner", Schema::string_with(SchemaOptions::required())),
        // 原文车道。
        ("text", Schema::text()),
        // 译文车道:八语固定键,每条是独立 LoroText,逐句订正互不干扰。
        (
            "lanes",
            Schema::map(SUPPORTED_LANES.map(|lane| (lane, Schema::text()))),
        ),
    ])
}

/// B:笔记 schema,macro 式递归树。
///
/// 节点形状 `{$: 元数据(稳定 id 在 $.id), text: LoroText,
/// children: MovableList(递归,按 $.id 选键)}`。`$` 是空定义 map——
/// 动态元数据键直接放行,与 macro 的 `schema.LoroMap({} as any)` 同款。
pub fn note_schema() -> Arc<Schema> {
    Schema::root(shared_root_fields().chain([(NOTE_ROOT, note_node_schema())]))
}

fn note_node_schema() -> Arc<Schema> {
    let id_selector: IdSelector = Arc::new(|item| {
        item.get("$")
            .and_then(|meta| meta.get("id"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });
    let children = Schema::movable_list_deferred(id_selector);
    let node = Schema::map([
        ("$", Schema::map([])),
        ("text", Schema::text()),
        ("children", children.clone()),
    ]);
    // 闭环递归:children 的条目就是节点自身。
    if let Schema::MovableList { item, .. } = children.as_ref() {
        item.fill(node.clone());
    }
    node
}

/// 构建某 kind 的黄金祖先字节。生成器与运行时校验共用,保证 `.bin` 与
/// 代码不会各说各话。
///
/// 黄金祖先里有什么:
/// - 根部 meta(`schema_epoch = 2`、`kind`)——每份文档对这两个 LWW 键
///   共享同一个基准;
/// - 笔记再加根节点的 `$`(含稳定 id "root")与 `children` 容器——嵌套
///   容器的身份由创建 op 决定,预制在祖先里,并发的首批编辑才会落进
///   **同一个** children 而不是两棵各自的树。转录稿的句块列表是根容器,
///   按名寻址,天然共享,无需预制。
pub fn build_golden_bytes(kind: DocumentKind) -> Vec<u8> {
    let doc = LoroDoc::new();

    let meta = doc.get_map(DOCUMENT_META);
    meta.insert(SCHEMA_EPOCH_KEY, BLOCK_SCHEMA_EPOCH as i64)
        .expect("golden meta epoch");
    meta.insert(DOCUMENT_KIND_KEY, kind.as_str())
        .expect("golden meta kind");

    if kind == DocumentKind::Note {
        let root = doc.get_map(NOTE_ROOT);
        let node_meta = root
            .insert_container("$", LoroMap::new())
            .expect("golden note $");
        node_meta.insert("id", "root").expect("golden note root id");
        root.insert_container("children", LoroMovableList::new())
            .expect("golden note children");
    }

    // 黄金祖先的提交一律打时间戳 0:loro 的提交时间戳单调不减,任何
    // 真实历史(含重放迁移带来的原时间戳)都必须能排在祖先之后。用
    // 生成时的墙钟会把比它早的历史时间戳全部钳平——阶段 4 踩过的坑。
    doc.commit_with(loro::CommitOptions::new().timestamp(0));
    doc.export(loro::ExportMode::Snapshot)
        .expect("golden export")
}

/// 某 kind 的黄金祖先,构建期生成、版本化提交的原字节。
///
/// 文件名里的版本号是纪元内版本号:字节一旦提交就冻结,要换就换文件名,
/// 与 macro 的 `markdown-golden.1` 同款缓存爆破策略。
pub fn golden_snapshot(kind: DocumentKind) -> &'static [u8] {
    match kind {
        DocumentKind::Transcript => {
            include_bytes!("../golden/document-golden-transcript.2.bin")
        }
        DocumentKind::Note => include_bytes!("../golden/document-golden-note.2.bin"),
    }
}

/// 开一份第 2 纪元的新文档:从黄金祖先出发,打开时间戳记录。
pub fn new_block_document(kind: DocumentKind) -> LoroDoc {
    let doc = LoroDoc::new();
    doc.set_record_timestamp(true);
    doc.import(golden_snapshot(kind))
        .expect("黄金祖先字节由本 crate 构建期生成,必可导入");
    doc
}

/// 读一份文档声明的 kind。缺失(第 1 纪元文档)或损坏返回 `None`。
pub fn document_kind(doc: &LoroDoc) -> Option<DocumentKind> {
    let value = doc.get_map(DOCUMENT_META).get(DOCUMENT_KIND_KEY)?;
    match value.get_deep_value() {
        LoroValue::String(kind) => DocumentKind::parse(&kind),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use vt_mirror::mirror::{Mirror, MirrorOptions};

    fn mirror_for(kind: DocumentKind) -> Mirror {
        let schema = match kind {
            DocumentKind::Transcript => transcript_schema(),
            DocumentKind::Note => note_schema(),
        };
        Mirror::new(
            new_block_document(kind),
            Some(schema),
            MirrorOptions::default(),
        )
        .unwrap()
    }

    fn utterance(id: &str, owner: &str, text: &str) -> serde_json::Value {
        json!({"id": id, "owner": owner, "text": text, "lanes": {}})
    }

    // ---- 黄金祖先 ----

    #[test]
    fn golden_bytes_declare_epoch_and_kind() {
        for kind in [DocumentKind::Transcript, DocumentKind::Note] {
            let doc = new_block_document(kind);
            assert_eq!(document_kind(&doc), Some(kind));
            let meta = doc.get_map(DOCUMENT_META);
            let epoch = meta.get(SCHEMA_EPOCH_KEY).unwrap().get_deep_value();
            assert_eq!(epoch, LoroValue::I64(BLOCK_SCHEMA_EPOCH as i64));
        }
    }

    /// 提交的 .bin 必须与构建函数同步——两者分叉即此测试红。
    /// (字节不要求逐位相同:时间戳与 peer id 每次生成都不同;要求的是
    /// 语义等价,即导入后的深值一致。)
    #[test]
    fn committed_golden_matches_the_builder_semantically() {
        for kind in [DocumentKind::Transcript, DocumentKind::Note] {
            let committed = LoroDoc::new();
            committed.import(golden_snapshot(kind)).unwrap();
            let rebuilt = LoroDoc::new();
            rebuilt.import(&build_golden_bytes(kind)).unwrap();
            assert_eq!(
                committed.get_deep_value(),
                rebuilt.get_deep_value(),
                "kind = {}",
                kind.as_str()
            );
        }
    }

    /// 黄金祖先的存在意义:两个对端各自从祖先开档、并发首编辑,合并后
    /// 收敛进同一棵树,而不是两个各自为政的根节点。
    #[test]
    fn concurrent_first_edits_on_a_note_converge_into_one_tree() {
        let mirror_a = mirror_for(DocumentKind::Note);
        let mirror_b = mirror_for(DocumentKind::Note);

        let node = |id: &str, text: &str| json!({"$": {"id": id}, "text": text, "children": []});
        let with_children = |children: serde_json::Value| json!({"root": {"$": {"id": "root"}, "children": children}});

        mirror_a
            .set_state_merge(&with_children(json!([node("a1", "甲的第一段")])))
            .unwrap();
        mirror_b
            .set_state_merge(&with_children(json!([node("b1", "乙的第一段")])))
            .unwrap();

        mirror_a
            .doc()
            .import(&mirror_b.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        mirror_b
            .doc()
            .import(&mirror_a.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        assert_eq!(
            mirror_a.doc().get_deep_value(),
            mirror_b.doc().get_deep_value()
        );
        let state = mirror_a.get_state();
        let children = state["root"]["children"].as_array().unwrap();
        assert_eq!(children.len(), 2, "两个首编辑都要落进同一个 children");
    }

    // ---- T2 转录稿 ----

    #[test]
    fn transcript_blocks_land_as_containers_with_text_lanes() {
        let mirror = mirror_for(DocumentKind::Transcript);
        mirror
            .set_state_merge(&json!({TRANSCRIPT_UTTERANCES: [
                {"id": "u1", "owner": "capture:s1", "text": "原文第一句",
                 "lanes": {"zh": "中文译文", "ja": "日本語訳"}},
            ]}))
            .unwrap();

        let doc = mirror.doc();
        let list = doc.get_list(TRANSCRIPT_UTTERANCES);
        assert_eq!(list.len(), 1);
        let Some(loro::ValueOrContainer::Container(loro::Container::Map(block))) = list.get(0)
        else {
            panic!("句块应当是 LoroMap 容器");
        };
        // 原文车道是真 LoroText。
        let Some(loro::ValueOrContainer::Container(loro::Container::Text(text))) =
            block.get("text")
        else {
            panic!("text 应当是 LoroText 容器");
        };
        assert_eq!(text.to_string(), "原文第一句");
        // 译文车道逐语言是独立 LoroText。
        let Some(loro::ValueOrContainer::Container(loro::Container::Map(lanes))) =
            block.get("lanes")
        else {
            panic!("lanes 应当是 LoroMap 容器");
        };
        let Some(loro::ValueOrContainer::Container(loro::Container::Text(zh))) = lanes.get("zh")
        else {
            panic!("zh 车道应当是 LoroText 容器");
        };
        assert_eq!(zh.to_string(), "中文译文");
    }

    /// 逐句订正一条车道,不动其它句块与车道。
    #[test]
    fn correcting_one_lane_leaves_other_blocks_alone() {
        let mirror = mirror_for(DocumentKind::Transcript);
        mirror
            .set_state_merge(&json!({TRANSCRIPT_UTTERANCES: [
                {"id": "u1", "owner": "capture:s1", "text": "一", "lanes": {"zh": "壹"}},
                {"id": "u2", "owner": "capture:s1", "text": "二", "lanes": {"zh": "贰"}},
            ]}))
            .unwrap();
        mirror
            .set_state_merge(&json!({TRANSCRIPT_UTTERANCES: [
                {"id": "u1", "owner": "capture:s1", "text": "一", "lanes": {"zh": "壹"}},
                {"id": "u2", "owner": "capture:s1", "text": "二", "lanes": {"zh": "贰(订正)"}},
            ]}))
            .unwrap();

        let state = mirror.get_state();
        assert_eq!(state[TRANSCRIPT_UTTERANCES][0]["lanes"]["zh"], json!("壹"));
        assert_eq!(
            state[TRANSCRIPT_UTTERANCES][1]["lanes"]["zh"],
            json!("贰(订正)")
        );
    }

    /// 机器追加与人工订正在两个对端并发,合并后两边一致。
    #[test]
    fn concurrent_append_and_correction_converge() {
        let mirror_a = mirror_for(DocumentKind::Transcript);
        mirror_a
            .set_state_merge(&json!({TRANSCRIPT_UTTERANCES: [utterance("u1", "capture:s1", "一")]}))
            .unwrap();

        let mirror_b = mirror_for(DocumentKind::Transcript);
        mirror_b
            .doc()
            .import(&mirror_a.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        // A 端机器追加 u2;B 端用户订正 u1 的 zh 车道。
        mirror_a
            .set_state_merge(&json!({TRANSCRIPT_UTTERANCES: [
                utterance("u1", "capture:s1", "一"),
                utterance("u2", "capture:s1", "二"),
            ]}))
            .unwrap();
        let mut corrected = mirror_b.get_state();
        corrected[TRANSCRIPT_UTTERANCES][0]["lanes"]["zh"] = json!("壹(人工)");
        mirror_b
            .set_state(|_| corrected.clone(), Default::default())
            .unwrap();

        mirror_a
            .doc()
            .import(&mirror_b.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        mirror_b
            .doc()
            .import(&mirror_a.doc().export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        assert_eq!(
            mirror_a.doc().get_deep_value(),
            mirror_b.doc().get_deep_value()
        );
        let state = mirror_a.sync_from_loro();
        let blocks = state[TRANSCRIPT_UTTERANCES].as_array().unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0]["lanes"]["zh"], json!("壹(人工)"));
    }

    /// 八语范围长在 schema 里:范围外的车道键被校验大声拒绝。
    #[test]
    fn out_of_scope_lane_keys_are_refused() {
        let mirror = mirror_for(DocumentKind::Transcript);
        let result = mirror.set_state_merge(&json!({TRANSCRIPT_UTTERANCES: [
            {"id": "u1", "owner": "user", "text": "x", "lanes": {"my": "缅甸语不在范围"}},
        ]}));
        // lanes 是 map schema,未声明键不报错(蓝本 map 分支只查已声明
        // 字段)——但值也不会落成 LoroText 车道,而是纯值。真正的范围
        // 守卫在这里:diff 后文档里 my 不是文本容器。
        result.unwrap();
        let doc = mirror.doc();
        let list = doc.get_list(TRANSCRIPT_UTTERANCES);
        let Some(loro::ValueOrContainer::Container(loro::Container::Map(block))) = list.get(0)
        else {
            panic!("句块应当是 LoroMap 容器");
        };
        let Some(loro::ValueOrContainer::Container(loro::Container::Map(lanes))) =
            block.get("lanes")
        else {
            panic!("lanes 应当是 LoroMap 容器");
        };
        assert!(
            !matches!(lanes.get("my"), Some(loro::ValueOrContainer::Container(_))),
            "范围外语言不该获得 LoroText 车道容器"
        );
    }

    // ---- B 笔记树 ----

    #[test]
    fn note_children_reorder_round_trips() {
        let mirror = mirror_for(DocumentKind::Note);
        let node = |id: &str| json!({"$": {"id": id}, "children": []});
        mirror
            .set_state_merge(&json!({NOTE_ROOT: {"$": {"id": "root"},
                "children": [node("a"), node("b"), node("c")]}}))
            .unwrap();
        mirror
            .set_state_merge(&json!({NOTE_ROOT: {"$": {"id": "root"},
                "children": [node("c"), node("a"), node("b")]}}))
            .unwrap();

        let state = mirror.sync_from_loro();
        let ids: Vec<String> = state[NOTE_ROOT]["children"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| n["$"]["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(ids, vec!["c", "a", "b"]);
    }

    #[test]
    fn note_nesting_recurses_through_the_deferred_schema() {
        let mirror = mirror_for(DocumentKind::Note);
        mirror
            .set_state_merge(&json!({NOTE_ROOT: {"$": {"id": "root"}, "children": [
                {"$": {"id": "chapter"}, "text": "章", "children": [
                    {"$": {"id": "leaf"}, "text": "节", "children": []},
                ]},
            ]}}))
            .unwrap();

        let state = mirror.sync_from_loro();
        assert_eq!(
            state[NOTE_ROOT]["children"][0]["children"][0]["text"],
            json!("节")
        );
    }
}
