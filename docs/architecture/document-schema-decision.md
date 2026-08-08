# 文档 Schema 决策：平文本、块列表，还是树

状态：**部分定稿**（2026-08-06）—— 笔记已定 B（macro 递归树，深度借鉴其设计）；
转录稿定为 T3（共用同一树引擎的结构冻结侧写），理由见文末「决定记录」。
本文前半部分的 A/D/E/B 比较保留为决策过程的记录。

## 现状盘点：今天的文档在 Loro 里长什么样

```
LoroDoc
├── LoroText("content")                        ← 全部正文，一条平文本
├── LoroMap(CAPTURE_ANCHOR_STARTS)             ← owner_key → Cursor(二进制)
├── LoroMap(CAPTURE_ANCHOR_ENDS)               ← owner_key → Cursor(二进制)
├── LoroMap(CAPTURE_ANCHOR_SESSIONS)           ← owner_key → capture_session_id
├── LoroMap("zulangue_session_purge_receipts") ← 销毁收据
└── LoroMap("zulangue_document_meta")          ← schema_epoch=1（阶段 1 已落地）
```

必须先说清楚**不在**文档里的东西，因为它们不受本决策影响：

- 说话人、逐句时间戳、语言标签 —— 在 SQLite（`realtime_utterances`、
  `session_speakers`）。
- 实时时间线字幕 —— cue 直达画布，不经过 Loro（0.1.10 架构）。
- 音频 —— 永远不进文档，不进分享（结构性排除，见 vt-share）。

本决策只管一件事：**笔记与转录稿正文**的协同表示。

## 为什么现状是痛的

平文本模型下，「采集拥有区间」靠三张锚点 map 里的 Cursor 撑着，产生了
整个代码库里最难证明正确的两段代码：

1. `resolve_capture_owned_range` —— 锚点部分缺失/损坏时 fail-closed 的解析；
2. `remote_update_touches_capture_owned_range` —— fork → 解析区间 → 导入 →
   diff → 逐段走 TextDelta 判定越界，边界情形（恰好压线的插入、无法判定
   时拒绝）全靠枚举。

痛的根源：**所有权是区间性质的，但载体是位置性质的**。文本一动，区间就
要靠 Cursor 语义漂移；判定一个远端 update 是否触碰区间，只能重放后对比。

## 候选方案

### A. 维持平文本（现状不动）

什么都不改，editor-surface-refactor 只做 UI 状态收敛。

### D. 平文本 + 原生富文本 mark（A 的温和改良）

`LoroText` 在 1.10.8 已支持 Peritext 式 `mark`/`unmark`。把三张锚点 map
换成正文上的一个 `capture_owner` mark：区间随文本自动漂移，锚点解析代码
整个删掉。

- 改良的只有锚点表示；**边界守卫仍然需要 fork+diff 重放**——mark 只是数据,
  恶意 update 可以连 mark 一起改,守卫照旧不可少。
- 迁移极小（同一条 LoroText,历史原位保留,只是锚点换载体）。

### E. 块列表（推荐进入决赛的新形状）

不是 macro 的递归树,是**一层平的块列表**：

```
LoroDoc
├── LoroMovableList("blocks")           ← 块的顺序
│     每项: LoroMap {
│       "id":    稳定块 id（字符串,生成后不变）
│       "kind":  "paragraph" | "utterance" | "heading" | …
│       "owner": "user" | "capture:<session_id>"   ← 所有权是块属性
│       "meta":  LoroMap（预留:说话人引用、时间戳引用、缩进层级）
│       "text":  LoroText（本块正文）
│     }
└── LoroMap("zulangue_session_purge_receipts")   ← 原样保留
```

核心变化：**所有权从「文本上的区间」变成「块上的属性」**。

- 采集投影不再做位置运算——追加/更新自己拥有的块;
- 边界守卫从「重放后走 TextDelta」退化为「这个 update 触碰的容器属于
  哪个块、块的 owner 是谁」——按容器 id 静态判定,**不再需要 fork 重放**;
- 转录稿的天然结构就是逐句(utterance)——块粒度与产品语义对齐,为
  「说话人标签进正文」「逐句评论」「逐句 AI 操作」留了位置;
- 嵌套用 `meta.indent` 表达(macro 同样存 indent),不做递归 children——
  转录稿是线性的,笔记的列表层级用属性够用,树的复杂度不请自来。

### B. macro 式递归块树

E 加上每块一个 `children: LoroMovableList`,可无限嵌套。

macro 需要它,因为 Lexical 的文档模型就是递归节点树,绑定要一一对应。
我们的编辑器是 NSTextView——一条平的 attributed string。递归树对我们
意味着:绑定层要做「树 ↔ 平文本」双向映射,比「列表 ↔ 平文本」多一个
维度的复杂度,却没有多换来任何我们要的功能。

### C. LoroTree（Loro 原生树容器）

原生 move 语义、fractional index。但 macro 用 MovableList-of-Maps 而不用
它是有信号的:loro-mirror 的 schema 系统不覆盖 LoroTree,生态里几乎没有
生产使用案例。转录稿不需要树,评估到此为止。

## 逐维度比较

| 维度 | A 平文本 | D 平文本+mark | E 块列表 | B 递归树 |
|---|---|---|---|---|
| 采集投影写入 | 位置运算 | 位置运算 | **追加自有块** | 追加自有块 |
| 拥有区间守卫 | fork+diff 重放 | fork+diff 重放 | **按容器归属静态判定** | 同 E |
| 守卫可证明性 | 边界情形靠枚举 | 同 A | **判定是结构性的** | 同 E |
| NSTextView 绑定 | 1:1 现成 | 1:1 现成 | 列表↔平文本映射（新写） | 树↔平文本映射（更重） |
| 协同块移动 | 无 | 无 | MovableList 原生 | 原生 |
| 逐句元数据入正文 | 挤不进 | mark 勉强 | **meta 槽现成** | 现成 |
| 逐块评论/AI 操作锚点 | Cursor | mark | **稳定块 id** | 稳定块 id |
| 迁移成本 | 零 | 极小 | 重放迁移（历史保留,已验证可行） | 同 E 且更繁 |
| editor_bridge 改动 | 零 | 锚点段重写 | 投影/守卫/桥全部重写 | 同 E 更多 |
| 分享边界守卫改动 | 零 | 零 | admit 第四步重写（变简单） | 同 E |
| 生态可参照 | — | — | macro（去掉递归）| macro 原样 |

## E 与 B 在用户交互上的真实分歧

单人安静编辑时两者可以渲染得一模一样；分歧全部在结构性操作与并发:

- **拖动带子层级的段落**:B 里子树物理内嵌,原子移动;E 里「子层级」是
  推导(后续缩进更深的连续块),应用层要自己圈选。
- **并发移动 × 并发编辑**:B 里对子块的编辑跟着父块搬家;E 里两个操作
  互不知情,合并正确但结果可能违反直觉(段落脱队成孤儿)。
- **折叠/删除一节**:B 是结构性的;E 靠缩进扫描推导。

判决:分歧只存在于「多人并发编辑深层大纲」一个象限,而下节的双侧写
表明这个象限在本产品中不存在。真需要那天,「给块加 children」是一次
小增量演进(纪元与重放机制届时都是现成的)。

## 双侧写:转录稿与笔记的要求相反,但共用一个引擎

两类文档几乎每个维度都相反——内容来源(机器投影 vs 人写)、结构(时间
序不可重排 vs 自由重排)、历史(产品承诺 vs 尽力而为)、协同形态(广播
+主持人可写 vs 共同编辑+人人可写)。`ShareableKind` 在分享层第一天就分开
了它们,文档层应当跟上。

但要求不同 ≠ 两套 schema。分裂成两个引擎会复制最贵的部分(bridge、
映射层、迁移工具)。定形:**同一个块列表 E,文档根部带 `kind`,守卫按
kind 换规则手册**:

```
kind = "transcript":
  块序不可变(move 一律拒绝——时间序是证据);
  采集块 owner 保护(静态判定);
  用户只能在句块之间插批注块、改自己的块;
  分享默认:主持人可写。

kind = "note":
  move/缩进/重排全放开;
  无采集块,owner 检查为空操作;
  分享默认:人人可写。
```

这使转录稿的准入规则收得更窄(拒绝一切 move + 只准动自己的块),
规则越窄越难绕;也让 E/B 之争的最后一个顾虑(并发重排深层大纲)在
两种 kind 下都不再存在。

## 迁移（A/D → E）

重放迁移,全部 API 已在锁定的 loro 1.10.8 中验证存在:

1. 旧文档 `export_json_updates` 导出全量 oplog（op、peer、时间戳）;
2. 按提交逐条翻译:文本 op 的位置 → 所属块（切块依据:utterance 边界来自
   SQLite,用户段落来自换行）,以原 peer、原时间戳 `commit_with` 进新文档;
3. 终态重导:owner 属性按旧锚点区间赋值,收据 map 原样搬;
4. **逐 frontier 验证**:旧新两边在每个历史时刻分别 checkout,拼出的正文
   必须逐字节一致。不一致即迁移失败,拒绝写回。

新旧纪元不得混流:文档根部写入 `schema_epoch`,分享信封同字段,不匹配
**大声拒绝**。（黄金祖先与纪元字段两个做法抄自 macro,经核实。）

## 推荐

**E（块列表）为目标 schema;分阶段落地,D 不做（它修表象不修根源）。**

判决依据一句话:A/D 把最难证明的代码留在原地,E 把「区间所有权」这个
问题**从代数题变成查表题**——这正是分享准入链上唯一防篡改环节,值得为
它付一次迁移的代价。转录稿逐句成块也与产品的下一步（说话人进正文、
逐句操作）同向。

风险与对冲:

- 最大新增复杂度在「块列表 ↔ NSTextView 平文本」映射层。对冲:这层
  无 I/O、纯函数,可以做成性质测试覆盖（任意块序列 ↔ 平文本往返无损）;
- 迁移是一次性工具 + 逐 frontier 验证器,验证不过不写回,旧文件保留备份;
- 时间线字幕、SQLite 事实层、分享传输层全部不动。

## 阶段划分

1. **纪元字段先行**（半天,**已落地 2026-08-07**）:文档打开即在根部
   `zulangue_document_meta` 补写 `schema_epoch=1`(只补缺,不盖写更高纪元);
   `DocumentUpdatePayload` 带同字段,接收端在归属检查之后、作者判定之前比对,
   不匹配拒收(`SchemaEpochMismatch`),判不出来拒收(`SchemaEpochUnknown`),
   发送侧判不出来不发;
2. 新 schema 的 editor_bridge(块投影、静态守卫)+ 性质测试
   (**部分落地 2026-08-07**:同步引擎整体移植自 loro-mirror,见
   `crates/vt-mirror`;T2/B 两张 schema 表与每 kind 黄金祖先见
   `crates/vt-store/src/document_schema.rs`——八语车道固定成键,语言
   范围长在 schema 里。静态守卫已落地:`crates/vt-store/src/block_guard.rs`
   按 kind 换规则手册——transcript 拒 move/拒删块/远端只准 user 批注块,
   note 全放开,两类共享 meta 与收据不可远端触碰,判不出来一律拒收。
   尚欠:editor_bridge 块投影接线,阶段 3 同场);
3. 块列表 ↔ NSTextView 映射层,EditorSurface 状态收敛同场施工;
4. 重放迁移工具 + 逐 frontier 验证器;首启迁移,旧文件留 `.pre-epoch2` 备份
   (**工具已落地 2026-08-07**:`crates/vt-store/src/replay_migration.rs`——
   逐提交重放,原 peer/原时间戳,逐时刻正文逐字节验证,不一致拒绝写回;
   行块保真与仅线性历史两个 v1 边界在模块头注释里声明。笔记侧宽松迁移
   已上线(块文档打开即迁);转录稿的首启迁移接线等 async 表面与投影
   切到 T2 时同场落地);
5. 分享边界守卫换静态判定,双机清单跑一遍。

---

## 决定记录（2026-08-06）

**笔记 = B,macro 递归树,深度借鉴其设计。** 采纳的 macro 做法:节点形状
`{$: 元数据(稳定 id), text: LoroText, children: LoroMovableList}`、黄金祖先
（所有空文档共享预制快照,让并发创建收敛）、文档内版本字段、
`set_record_timestamp` 撑历史时间轴、Loro UndoManager 当撤销真相源。
不采纳:Lexical/WebView(编辑器保持 NSTextView,树↔平文本映射层自研)、
markdown 重灌迁移(历史会归零,换成重放迁移)。

**转录稿 = T2,独立结构:不可移动的 LoroList 句块。** 比较过程:

- T1(现状):平文本 + 整段锚点。文档只是 SQLite 事实的渲染切片
  (`render_bilingual_capture_section`),增量更新靠位置运算
  (`plan_capture_section_incrementally` + `CaptureDeltaIndex`),
  句子身份熔进纯文本,所有权粒度只有整段。
- T3(一度倾向):转录稿作为树引擎下的结构冻结侧写,单引擎。否决理由:
  「复用」经不起细看——投影、守卫侧写、渲染策略在 T3 下依然各是各的,
  真正共享的只有节点形状;而它把「时间序不可篡改」放在准入代码里而
  不是结构里。
- **T2(定):** 与笔记彻底分开的第二套结构:

  ```
  LoroList("utterances")                ← 普通 List:move 在类型层面不存在
    每项: LoroMap {
      "id":    utterance_id(与 SQLite 事实层对齐)
      "owner": "capture:<session>" | "user"(批注块)
      "text":  LoroText(原文车道)
      "lanes": LoroMap(lane → LoroText, 译文车道,可逐句订正)
    }
  LoroMap("zulangue_session_purge_receipts")   ← 原样保留
  ```

决定性理由与本库家法同构:**结构性排除优于纪律性排除**(vt-share 用
依赖图排除音频,而非靠守卫)。证据级文档的不可重排性质应当长在容器
类型里——普通 LoroList 表达不出 move,守卫无需任何结构规则,只剩
「触碰的块 owner 是谁」一条。

分开后的其余收益:转录稿的编辑器映射近乎平凡(句块线性拼接),不再
搭树映射的便车;两类文档演进节奏解耦(转录稿求稳,笔记跟协作功能快速
迭代);迁移各走各的时间表与严格度。

**两套结构之间仍然共享:** `schema_epoch`、销毁收据 map、分享信封与
准入入口(按 kind 分发)、稳定 id 约定、重放迁移工具骨架、黄金祖先
(各 kind 一份 golden)、`set_record_timestamp`。

## 决定记录补充(2026-08-07):抄 macro,接受 AGPL

「能复制别人代码就不自研」定为执行原则。状态↔CRDT 同步引擎不再设计,
整体移植 macro 内嵌的 loro-mirror(上游 loro-dev/loro-mirror 为 MIT;
macro 仓库整体 AGPL-3.0,**项目明确接受 AGPL**,移植成果所在的
`vt-mirror` crate 按两个血统中较严者声明 AGPL-3.0-or-later,与工作区的
GPL-3.0-or-later 按 GPLv3 §13 合并)。移植纪律:先照译蓝本测试看红,
再照译实现看绿;蓝本怪癖照抄并用测试钉死,一切偏离逐条声明——出处
对应表见 `crates/vt-mirror/THIRD_PARTY.md`。不可移植的部分要么是 JS
生态件(Lexical/immer/微任务),要么是 macro 的「Rust 只当 HTTP 客户端」
架构,均已在盘点中排除。

## 决定记录补充(2026-08-08):块类型是节点级标量,不是文本

笔记行的类型(段落 / 标题 1–3 / 引用 / 任务 / 分隔线)与任务勾选态存进
节点元数据 —— `$.kind` 与 `$.checked`,与 macro 在 Lexical 序列化里的
`type`/`checked` 字段同构。**不进 LoroText**:类型是标量,两人同时把
一行改成不同类型,该有一个赢家(节点级 LWW),而不是把两个标记合进
正文里。段落是缺省,不写 `$.kind` 键;非任务块不写 `$.checked`。

由此定下两条:

- **未知类型按段落渲染,但原样保留。** 老版本打开新版本写的文档,
  `$.kind = "hologram"` 降级显示成段落,数据不丢 —— 跨版本协作里
  「看不懂就删掉」是最坏的处理。
- **行携带的键不受「元数据保留」保护。** 重放整份大纲时,既有节点
  `$` 里行不携带的键(如创建时间)按 id 拷回重建的树;`id`/`kind`/
  `checked` 三个键整体剔除出保留集,否则「把标题降回段落」会被上一版
  的 `$.kind` 立刻冲回去 —— 段落不写键,留存侧也必须跟着消失。

Swift 侧的入口是 Markdown 前缀手势(`# ` `## ` `### ` `> ` `- [ ] `
`--- `,记号当场被吃掉)与右键「转换为」菜单;非段落行的行首退格先降回
段落,第二下才并块。
