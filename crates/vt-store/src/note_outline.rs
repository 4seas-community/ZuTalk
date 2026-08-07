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

/// 一行大纲:Swift 侧渲染与命中都以它为单位。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutlineRow {
    pub id: String,
    /// 0 = 根节点的直接孩子。
    pub depth: usize,
    pub text: String,
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
    rows.push(OutlineRow {
        id: id.to_string(),
        depth,
        text: node
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
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

        let node = json!({
            "$": {"id": row.id},
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

    // ---- 性质测试:这层的唯一规格 ----

    /// 合法行序列的策略:深度按重建规则生成,天然合法。
    fn legal_rows() -> impl Strategy<Value = Vec<OutlineRow>> {
        prop::collection::vec(("[a-z]{1,6}", 0usize..4, "[a-z一-鿿]{0,6}"), 0..16).prop_map(|raw| {
            let mut rows: Vec<OutlineRow> = Vec::new();
            for (index, (id, depth, text)) in raw.into_iter().enumerate() {
                let depth = match rows.last() {
                    None => 0,
                    Some(previous) => depth.min(previous.depth + 1),
                };
                rows.push(OutlineRow {
                    // id 加序号保证唯一:行身份是编辑器的命根。
                    id: format!("{id}-{index}"),
                    depth,
                    text,
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
