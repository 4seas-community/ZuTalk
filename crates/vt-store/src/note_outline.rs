//! B 笔记的树 ↔ 大纲行映射:阶段 3 真正的自研层。
//!
//! NSTextView 是一条平的 attributed string,而 B 笔记是递归树。这层把
//! 两边翻译打通的**纯函数核心**:树 flatten 成「(节点 id, 深度, 文本)」
//! 的大纲行序列,大纲行序列(含深度修正)重建回树。无 I/O、无 Loro
//! 依赖——输入输出都是 vt-mirror 状态形状的 `Value`,所以能用性质测试
//! 压「任意树 ↔ 行序列往返无损」,这正是决策文档为这层开出的对冲。
//!
//! 此层没有蓝本(macro 用 Lexical,文档模型天生是节点树,不存在这个
//! 问题),性质测试就是唯一规格:
//!
//! 1. `flatten` ∘ `rebuild` = 恒等(行 → 树 → 行);
//! 2. `rebuild` ∘ `flatten` = 恒等(树 → 行 → 树);
//! 3. 任意(含非法跳深)的行序列经 `rebuild` 后深度合法。
//!
//! 深度修正规则(大纲编辑器的通例):行的合法深度最多比前一行深一级,
//! 首行深度恒为 0;超出的深度收敛到「前一行深度 + 1」。这保证任何
//! 粘贴/拖拽产生的行序列都能落成结构合法的树,不会出现无父的悬空层级。

use serde_json::json;
use vt_mirror::value::Value;

/// 行的块类型。存进节点 `$.kind`(缺省 = 段落,不写键);任务块的勾选
/// 态存 `$.checked`。这与 macro 在 Lexical 序列化里的 `type`/`checked`
/// 字段同构——类型是节点级 LWW 标量,不参与文本 CRDT。
///
/// 未知的 `$.kind` 值按段落渲染但**原样保留**(见 `KIND_*` 常量与
/// flatten 的读取规则):老版本打开新版本的文档,类型降级显示,不丢数据。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OutlineKind {
    #[default]
    Paragraph,
    Heading1,
    Heading2,
    Heading3,
    Quote,
    Task,
    Divider,
}

impl OutlineKind {
    /// `$.kind` 里的持久化字面量。段落返回 None:缺省不写键。
    pub fn as_meta_str(self) -> Option<&'static str> {
        match self {
            Self::Paragraph => None,
            Self::Heading1 => Some("heading1"),
            Self::Heading2 => Some("heading2"),
            Self::Heading3 => Some("heading3"),
            Self::Quote => Some("quote"),
            Self::Task => Some("task"),
            Self::Divider => Some("divider"),
        }
    }

    /// 从 `$.kind` 读回。未知值按段落——渲染降级,数据由元数据保留
    /// 规则负责不丢。
    pub fn from_meta(value: Option<&str>) -> Self {
        match value {
            Some("heading1") => Self::Heading1,
            Some("heading2") => Self::Heading2,
            Some("heading3") => Self::Heading3,
            Some("quote") => Self::Quote,
            Some("task") => Self::Task,
            Some("divider") => Self::Divider,
            _ => Self::Paragraph,
        }
    }
}

/// 一行大纲:Swift 侧渲染与命中都以它为单位。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutlineRow {
    pub id: String,
    /// 0 = 根节点的直接孩子。
    pub depth: usize,
    pub text: String,
    pub kind: OutlineKind,
    /// 只对 `Task` 有意义;其余类型恒 false。
    pub checked: bool,
}

/// 树(B 笔记根节点的状态形状)→ 大纲行,先序深度优先。
///
/// 根节点自身不出行:它是文档的锚,没有可编辑正文语义。
pub fn flatten_note(root: &Value) -> Vec<OutlineRow> {
    let mut rows = Vec::new();
    if let Some(children) = root.get("children").and_then(Value::as_array) {
        for child in children {
            flatten_node(child, 0, &mut rows);
        }
    }
    rows
}

fn flatten_node(node: &Value, depth: usize, rows: &mut Vec<OutlineRow>) {
    let Some(id) = node
        .get("$")
        .and_then(|meta| meta.get("id"))
        .and_then(Value::as_str)
    else {
        // 没有稳定 id 的节点无法参与行级编辑,跳过整棵子树 —— 判不出来
        // 不猜,与守卫同一条家法。
        return;
    };
    let meta = node.get("$");
    rows.push(OutlineRow {
        id: id.to_string(),
        depth,
        text: node
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        kind: OutlineKind::from_meta(meta.and_then(|m| m.get("kind")).and_then(Value::as_str)),
        checked: meta
            .and_then(|m| m.get("checked"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
    });
    if let Some(children) = node.get("children").and_then(Value::as_array) {
        for child in children {
            flatten_node(child, depth + 1, rows);
        }
    }
}

/// 大纲行 → 树(B 笔记根节点的状态形状,根 id 由调用方给)。
///
/// 深度按头注释的规则修正;修正后按「行深度栈」重建父子关系。
pub fn rebuild_note(root_id: &str, rows: &[OutlineRow]) -> Value {
    let mut root = json!({
        "$": {"id": root_id},
        "children": [],
    });
    // 栈里存「到当前行为止,每个深度的节点路径」(以 children 索引表示)。
    let mut path: Vec<usize> = Vec::new();
    let mut previous_depth: usize = 0;

    for row in rows {
        // 深度修正:首行 0,其余最多比前一行深一级。
        let depth = if path.is_empty() {
            0
        } else {
            row.depth.min(previous_depth + 1)
        };
        path.truncate(depth);

        let mut meta = json!({"id": row.id});
        if let Some(kind) = row.kind.as_meta_str() {
            meta["kind"] = json!(kind);
        }
        if row.checked {
            meta["checked"] = json!(true);
        }
        let node = json!({
            "$": meta,
            "text": row.text,
            "children": [],
        });

        // 沿修正后的路径找到父 children 并追加。
        let parent_children = {
            let mut current = &mut root;
            for &index in &path {
                current = &mut current["children"][index];
            }
            current["children"]
                .as_array_mut()
                .expect("本函数构造的节点恒有 children 数组")
        };
        parent_children.push(node);
        path.push(parent_children.len() - 1);
        previous_depth = depth;
    }

    root
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn row(id: &str, depth: usize, text: &str) -> OutlineRow {
        OutlineRow {
            id: id.to_string(),
            depth,
            text: text.to_string(),
            kind: OutlineKind::Paragraph,
            checked: false,
        }
    }

    #[test]
    fn flatten_walks_depth_first_in_document_order() {
        let root = json!({
            "$": {"id": "root"},
            "children": [
                {"$": {"id": "a"}, "text": "一", "children": [
                    {"$": {"id": "a1"}, "text": "一之一", "children": []},
                ]},
                {"$": {"id": "b"}, "text": "二", "children": []},
            ],
        });
        assert_eq!(
            flatten_note(&root),
            vec![row("a", 0, "一"), row("a1", 1, "一之一"), row("b", 0, "二")]
        );
    }

    #[test]
    fn rebuild_clamps_illegal_depth_jumps() {
        // 首行硬给深度 3、次行跳深 5:全部收敛到合法层级。
        let rows = vec![row("a", 3, "甲"), row("b", 5, "乙"), row("c", 0, "丙")];
        let rebuilt = rebuild_note("root", &rows);
        assert_eq!(
            flatten_note(&rebuilt),
            vec![row("a", 0, "甲"), row("b", 1, "乙"), row("c", 0, "丙")]
        );
    }

    #[test]
    fn nodes_without_stable_ids_are_skipped_whole() {
        let root = json!({
            "$": {"id": "root"},
            "children": [
                {"text": "无 id,整棵跳过", "children": [
                    {"$": {"id": "orphan"}, "text": "跟着消失", "children": []},
                ]},
                {"$": {"id": "b"}, "text": "二", "children": []},
            ],
        });
        assert_eq!(flatten_note(&root), vec![row("b", 0, "二")]);
    }

    #[test]
    fn kinds_and_checked_round_trip_through_meta() {
        let rows = vec![
            OutlineRow {
                kind: OutlineKind::Heading1,
                ..row("h", 0, "标题")
            },
            OutlineRow {
                kind: OutlineKind::Task,
                checked: true,
                ..row("t", 0, "待办")
            },
            OutlineRow {
                kind: OutlineKind::Divider,
                ..row("d", 0, "")
            },
            row("p", 0, "普通段落"),
        ];
        let tree = rebuild_note("root", &rows);
        // 段落不写 kind 键;任务写 checked。
        assert!(tree["children"][3]["$"].get("kind").is_none());
        assert_eq!(tree["children"][1]["$"]["checked"], json!(true));
        assert_eq!(flatten_note(&tree), rows);
    }

    #[test]
    fn unknown_kind_values_degrade_to_paragraph_on_read() {
        let root = json!({
            "$": {"id": "root"},
            "children": [
                {"$": {"id": "a", "kind": "hologram"}, "text": "未来类型", "children": []},
            ],
        });
        assert_eq!(flatten_note(&root)[0].kind, OutlineKind::Paragraph);
    }

    // ---- 性质测试:这层的唯一规格 ----

    /// 合法行序列的策略:深度按重建规则生成,天然合法。类型与勾选一并
    /// 随机——往返恒等必须覆盖 `$.kind`/`$.checked` 的写读对称。
    fn legal_rows() -> impl Strategy<Value = Vec<OutlineRow>> {
        let kinds = [
            OutlineKind::Paragraph,
            OutlineKind::Heading1,
            OutlineKind::Heading2,
            OutlineKind::Heading3,
            OutlineKind::Quote,
            OutlineKind::Task,
            OutlineKind::Divider,
        ];
        prop::collection::vec(
            (
                "[a-z]{1,6}",
                0usize..4,
                "[a-z一-鿿]{0,6}",
                0usize..7,
                any::<bool>(),
            ),
            0..16,
        )
        .prop_map(move |raw| {
            let mut rows: Vec<OutlineRow> = Vec::new();
            for (index, (id, depth, text, kind_index, checked)) in raw.into_iter().enumerate() {
                let depth = match rows.last() {
                    None => 0,
                    Some(previous) => depth.min(previous.depth + 1),
                };
                let kind = kinds[kind_index];
                rows.push(OutlineRow {
                    // id 加序号保证唯一:行身份是编辑器的命根。
                    id: format!("{id}-{index}"),
                    depth,
                    text,
                    kind,
                    // checked 只在任务块上有效——非任务块生成 false,
                    // 否则「行 → 树 → 行」会把它归一化掉,恒等不成立。
                    checked: checked && kind == OutlineKind::Task,
                });
            }
            rows
        })
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        /// 行 → 树 → 行 恒等。
        #[test]
        fn rows_survive_a_round_trip(rows in legal_rows()) {
            let rebuilt = rebuild_note("root", &rows);
            prop_assert_eq!(flatten_note(&rebuilt), rows);
        }

        /// 树 → 行 → 树 恒等(树由合法行生成,覆盖任意形状)。
        #[test]
        fn trees_survive_a_round_trip(rows in legal_rows()) {
            let tree = rebuild_note("root", &rows);
            let rebuilt = rebuild_note("root", &flatten_note(&tree));
            prop_assert_eq!(rebuilt, tree);
        }

        /// 任意(含非法)深度序列重建后必合法:首行 0,逐行至多深一级。
        #[test]
        fn arbitrary_depths_normalize_to_legal_structure(
            raw in prop::collection::vec(("[a-z]{1,6}", 0usize..12, "[a-z]{0,4}"), 0..16)
        ) {
            let rows: Vec<OutlineRow> = raw
                .into_iter()
                .enumerate()
                .map(|(index, (id, depth, text))| OutlineRow {
                    id: format!("{id}-{index}"),
                    depth,
                    text,
                    kind: OutlineKind::Paragraph,
                    checked: false,
                })
                .collect();
            let flattened = flatten_note(&rebuild_note("root", &rows));
            prop_assert_eq!(flattened.len(), rows.len(), "行不增不减");
            for (index, current) in flattened.iter().enumerate() {
                if index == 0 {
                    prop_assert_eq!(current.depth, 0);
                } else {
                    prop_assert!(current.depth <= flattened[index - 1].depth + 1);
                }
            }
        }
    }
}
