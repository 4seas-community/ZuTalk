# ZuTalk 用户访谈与研究资料工作台：UI/UX 竞品研究底稿

- 受众：ZuTalk 产品、设计、macOS 客户端与本地数据/AI 工程团队
- 日期：2026-08-24
- 文档性质：研究底稿，不是已经批准的产品规格、视觉稿或发布承诺
- 核心问题：在不牺牲本地优先、隐私边界、来源追溯与录音转录主流程的前提下，ZuTalk 应如何承接多次用户访谈的整理、跨会话分析、证据沉淀与洞察输出？

## 1. 范围与假设

### 1.1 研究范围

本轮优先研究四个以用户访谈、定性研究分析和研究仓库为核心的产品：

1. Dovetail
2. Condens
3. Looppanel
4. Notably

同时用 Granola、Otter、Plaud、Gemini Notebook（原 NotebookLM）和 Fathom 校验会议录音、
长列表、导入、跨录音作用域、图片上下文、引用和失败恢复模式。它们不是完整研究仓库，
但能揭示“录音工具如何进入研究工作流”的邻近机会与反模式。

研究问题集中在：

- 它们如何组织 `Project/Study → Session/Interview → Transcript/Highlight/Insight`；
- 如何完成跨会话与跨项目分析；
- 标签、结构化字段、搜索、媒体片段、图片/截图、状态和首页入口如何设计；
- 哪些模式适合本地优先的 macOS ZuTalk，哪些模式会造成不必要的企业仓库复杂度。

官方产品帮助文档和官方产品页是功能现状的主要证据；G2 用户评论只作为独立的使用感受与风险信号，不用来替代产品事实。所有“AI 准确”“节省时间”“完全可引用”等性能表达，除非有独立测试，否则均标记为供应商声明。

### 1.2 ZuTalk 工作假设

以下是本底稿用于做产品映射的假设，需在进入实现前与当前代码和真实用户路径复核：

- ZuTalk 是本地优先的 macOS 应用，录音、音频、转录、笔记和衍生分析首先属于用户本机。
- 当前 `Notebook` 可以承接竞品中的 Study/Project 语义；一次录音或访谈承接 Session/Interview 语义。
- 用户的首要任务仍是“开始/继续录音，查看转录、音频和笔记”，而不是先学习研究仓库术语。
- AI 产物是可审核、可撤销、可追溯的衍生层，不应覆盖原始录音、最终转录或人工笔记。
- 分享、多人协作、参与者 CRM、利益相关者门户和企业级权限，不是本轮 IA 的默认前提。

### 1.3 对象术语归一化

| 通用研究对象 | Dovetail | Condens | Looppanel | Notably | ZuTalk 建议映射 |
| --- | --- | --- | --- | --- | --- |
| 一项研究/主题 | Project | Project | Project（近似文件夹） | Project | Notebook |
| 一次访谈 | Data object：recording + transcript | Session | File / Call | 公开资料未确认独立 Session 对象 | Recording / Session（界面优先显示“录音/访谈”） |
| 原始资料 | Data、recording、document、survey | Session notes、transcript、image、file、media | transcript、notes、audio/video、CSV、PDF | video、audio、transcript、document | 音频、转录、笔记、截图/附件 |
| 原子证据 | Highlight | Highlight | Note + quote/clip | Highlight / digital sticky note | Evidence / Highlight（界面可显示“证据”） |
| 编码 | Project tag / workspace tag；field 描述整条资料 | Project tag / global tag；information field 描述对象 | Tag；Metadata 描述文件/参与者 | Tag、theme、sentiment | Tag 标记证据；Metadata 描述 Notebook/录音 |
| 综合产物 | 当前文档称 Doc，旧文档称 Insight | Artifact：Finding、Report、Persona、Whiteboard 等 | Insight + Insights Summary report | Atomic Insight / report | Insight / Finding（界面可显示“发现/洞察”） |

## 2. 直接结论

1. **ZuTalk 应采用一条清晰证据链，而不是复制完整企业研究仓库。** 推荐主链路是：`独立录音 →（可选）Topic / Session → 转录/笔记/截图 → 证据 → 发现/洞察`。Condens 对研究链路表达最清楚；ZuTalk 额外保留无需先建研究对象的快速录音入口。

2. **首屏以全局录音 / Session 时间清单为主，并提供一个无需选择 Topic 的录音按钮。** 这既支持随手记录，也能追踪每一次访谈；导入仍要求明确 Topic，研究分析在 Topic 内渐进出现。

3. **一次访谈的工作区应以音频/转录为主、证据与洞察为辅。** 最值得借鉴的是 Condens 的分屏和 Looppanel 的右侧 Insights 面板：主区域保持上下文，右侧窄栏收集 Highlight、Tag 和洞察草稿。

4. **跨访谈分析只需先做三个入口：按问题、按标签、搜索。** Looppanel 的 Question View、Tag View、Find 是最适合小团队/个人工具的低认知负担组合。Canvas、Charts 和复杂 Dashboard 可后置。

5. **必须区分 Metadata 与 Tag。** Metadata 描述整个 Notebook/录音，如研究方法、日期、参与者、处理状态；Tag 标记转录中的具体证据。Dovetail 和 Condens 都明确采用这一区分。

6. **截图、图片和附件应成为一等证据。** Looppanel 官方文档承认：当关键信息只在视频画面而不在 transcript 中，AI Notes 会降低准确性。ZuTalk 不应把分析限制在文本；截图应可锚定时间点或转录范围、加标签并被洞察引用。

7. **AI 必须是“建议—审核—接受”的辅助层。** Condens 明确表示 AI 标签不会自动应用；这比 Dovetail 默认开启且不能在 workspace 层完全禁用 AI 的方式更适合本地优先产品的信任模型。

8. **搜索必须持续显示作用域和来源。** 建议明确区分“本次录音 / 当前 Notebook / 全部本地资料”，默认先给确定性的关键词结果与过滤器，AI 总结作为可选第二步，并列出可回跳的引用。

9. **状态不应只存在于模糊文案中。** 至少需要 Notebook 状态，以及录音/转录任务的 `录音中、收尾中、处理中、待审核、完成、失败` 等真实状态和恢复动作。Condens 的结构化 Status/Start Date/End Date 比其他产品更可借鉴。

10. **不要把云端传播模型带入第一阶段。** 默认公开链接、利益相关者 Magazine、企业级 workspace taxonomy、参与者 CRM、Recruit、Channel、Dashboard 都不是 ZuTalk 本轮大改版的必要条件。

## 3. 竞品对照

### 3.1 总览

| 维度 | Dovetail | Condens | Looppanel | Notably | 对 ZuTalk 的含义 |
| --- | --- | --- | --- | --- | --- |
| 研究层级 | Workspace/Folder → Project → Data → Highlight → Tag → Doc/Chart | Folder → Project → Session → Highlight → Chart/Artifact | Project → File/Call → Transcript/Notes → Question/Tag → Insight report | Folder → Project → raw data → highlight/tag → synced views → Insight | 采用 Notebook → 录音 → 证据 → 洞察；不增加 Workspace 层级 |
| 单次访谈分析 | transcript 中选择片段形成 Highlight | transcript/notes/media/image 可形成 Highlight | transcript + AI/manual Notes，右侧组织洞察 | highlight/tag，sticky note 可回跳视频 | 转录主视图 + 右侧证据/洞察栏 |
| 跨会话分析 | Project views、tags、charts、Search/Chat | Highlights 汇总、Global Tags、全库 Search、右侧 Artifact 拖放 | Question View、Tag View、Find | table/canvas/charts 同步、AI clustering | 第一阶段只做问题/标签/搜索 |
| 跨项目分析 | Workspace tags、Search/Chat 多上下文 | Global Tags、全库 Search、跨项目 Artifact/Highlight | Workspace Global Search | Repository search by keyword/participant/tag | 第二阶段做全本地库搜索；全局标签后置 |
| 标签治理 | project tags + workspace tag boards；需治理 | project tags + global tags；AI 只建议 | project tags；workspace metadata | suggested tags、themes、sentiment | 先项目本地标签；允许以后提升为全局 |
| 素材/截图 | 可存 images/photos/PDF，图片预览与项目封面；未明确截图锚点 | 可直接标记 images/files/media，并纳入 Artifact | 主分析面向音视频/转录/笔记；官方承认不能理解只存在于画面的上下文 | 可存 documents；Insight 支持生成式图片 | 采用 Condens 式可引用图片证据；禁止把生成图当证据 |
| 状态 | Overview 可放 status；archive；Insight 有 published status | 默认结构化 Status/Start/End；Home 有 recent/favorite/new | 未找到明确 project lifecycle/归档文档 | 未找到当前状态模型 | 明确建模 Notebook 与处理任务状态 |
| 入口 | 新 Home：Chat、Pinned、For You、Browse；`⌘K` | Home：全库搜索、资源、最近/收藏/最新项目 | Homepage：Projects、Search、Calendar/上传 | 公开资料以 Projects/Repository 为主 | 首页保持录音与恢复优先，搜索其次 |
| 主要风险 | 2026 导航/命名迁移、标签治理重、AI 默认强 | Artifact/Whiteboard/Repository 能力过多 | Note/Highlight 边界弱、屏幕上下文缺失、状态能力不足 | 公开资料较旧，帮助中心无法核验 | 组合借鉴，不复制任何一个完整产品 |

### 3.2 Dovetail

#### 供应商可见设计

- Project 被定义为一项 study 和独立数据库。一次访谈是一个包含录音与转录的 Data object。
- Highlight 从原始数据中提取，Tag 把多个 Highlight 聚合为主题，Doc/Insight 负责形成叙事，Chart 负责可视化模式。
- Project 内数据可切换 Grid、Board、Table、Canvas、List；Workspace Tags 用于跨项目共用主题。
- Search 兼具 `⌘K` 快速导航、Explore、自然语言 Magic Summary 和过滤；Chat 可在一个问题中引用多个项目、文档或 Channel。
- 2026 新 Home 把 Chat、Pinned、For You 和 Browse 汇集到一个入口，侧栏可折叠以保持工作区专注。
- 图片、照片、PDF、音视频可作为原始资料，项目 Overview 图片可成为项目卡片封面。

#### 独立证据与冲突

G2 的 Dovetail 页面在本轮检索中汇总 167 条评论。2026 年 4 月的评论肯定其集中保存多种研究资料、转录、Tag 和多来源洞察，但也直接抱怨频繁的功能/UI 改动、标签效率和 AI 质量。这与官方 2026 大规模导航重构形成需要重视的张力：灵活不等于稳定。

#### 对 ZuTalk 的取舍

- 借鉴：层级搜索、作用域、字段与 Tag 的分工、可折叠侧栏、证据引用。
- 不照搬：Channel、Dashboard、Recruit、五种视图同时上线、企业 Workspace Tag Board、AI 默认主导首页。

### 3.3 Condens

#### 供应商可见设计

- Project 内固定分为 Overview、Sessions、Highlights、Charts、Artifacts。
- Highlight 是证据基元：在 transcript、notes、images、files、audio/video 上选择内容或片段即可形成 Highlight；转录选区可自动对应媒体 clip。
- Artifact 是综合层，可是原子 Finding、Report、Persona，也可以是 Affinity Map/Whiteboard。
- 最有辨识度的交互是右侧 Artifact 分屏：用户阅读原始资料时，可把 Highlight、Chart、Tag group、搜索结果或其他 Artifact 拖入当前综合产物。
- 搜索明确区分 Session、Project、Workspace、Participant、Highlights 和 Published Artifacts；Global Tags 串联不同研究。
- Project 默认拥有 Status、Start Date、End Date；Home 提供全库搜索、最近/收藏/最新项目。
- AI 可以建议 Tag，但不会自动应用，最终由研究者接受或拒绝。

#### 独立证据与冲突

G2 的 Condens 页面在本轮检索中有 99 条评论。2026 年评论特别肯定“原始访谈与分析/白板同屏”、视频片段和较低的学习成本；聚合反馈仍出现少量转录、界面和标签学习问题。供应商关于“好用”和“准确”的表达不能视为独立性能证明，但其分屏工作流获得了相对一致的外部支持。

#### 对 ZuTalk 的取舍

- 强烈借鉴：证据基元、时间/素材回链、分屏、AI 建议需确认、结构化状态。
- 暂不照搬：Artifact 类型选择器、Whiteboard、Magazine、Participant Pool、全企业 Global Tags。

### 3.4 Looppanel

#### 供应商可见设计

- Project 更像容纳访谈资料的文件夹；File/Call 内同时显示 transcript 与 AI/manual Notes。
- Discussion Guide 可把多次访谈的回答按相同问题排列；Analysis 主入口是 Question View、Tag View、Find。
- Find 可按 Tags、Questions、Files、Metadata 过滤，返回 AI Summary、相关 Notes、视频片段和 transcript 引用；Workspace Global Search 再把范围扩大到多个 Projects。
- 多条 Note 可以组合为 Insight；右侧 Insights Summary panel 用于编辑叙事、增删证据、排序与分享。
- Tag 用于主题，Metadata 用于参与者/公司/地区等文件级属性。

#### 独立证据与冲突

G2 的 Looppanel 页面在本轮检索中有 26 条评论。用户普遍肯定 AI Notes 的速度和单一路径，但也有上传后编辑、搜索、定制和归档能力不足的反馈。样本较小，不能把供应商的“fully cited”或准确性主张当作独立验证。

#### 对 ZuTalk 的取舍

- 借鉴：问题/标签/搜索三入口、右侧洞察面板、简单的一条分析路径。
- 修正：Discussion Guide 保持可选；修改后允许用户明确重跑旧会话；截图/屏幕上下文不能只依赖 transcript。

### 3.5 Notably

#### 供应商可见设计

- 官方产品页描述 Folder、Project、raw videos/audio/transcripts/documents、highlight/tag、atomic Insight 和 participant tracking。
- 分析可在 table、canvas/sticky notes 和 charts 之间同步；sticky note 可回到视频中的原始上下文。
- AI 可自动 highlight/tag、按 tag/theme/project 生成 Insight，并提供研究模板与聚类。
- Insight 可以生成配图，面向更具叙事性的报告展示。

#### 独立证据与冲突

Notably 官网可访问，但首页可见最新文章仍为 2024-10-16，本轮无法访问其 Help Center 来核验 2026 的现行对象、状态和导航。G2 仅有 3 条、且全部来自 2023 年的评论，其中出现 Tag 在不同视图间消失和 sticky note 组织有限的反馈。它只能提供概念参考，不能作为当前实现基准。

#### 对 ZuTalk 的取舍

- 可远期参考：同一证据在表格/空间/图表中的同步投影。
- 不作为当前基线：Canvas-first、多视图同时上线、生成式洞察配图、未经核验的自动工作流。

### 3.6 会议录音与资料型工具的校验

- **Granola** 把日历标题、最近会议和 Folder 多集合组织做得很轻，但不支持预录音导入、
  不保留音视频，不能作为完整研究档案基线。它的 Chat 能显式选择单场、多场、Folder、
  People/Company 或全部会议，证明“作用域先于提问”是稳定模式。
- **Otter** 的录音导入、可编辑转录、Folder/Conversation 组合上下文和来源回跳成熟；自动
  Slide Capture 也证明图片可以锚定到 transcript。反面是删除 Folder 可能连带删除会话，
  ZuTalk 不应让 Topic 删除改变全局 Session 所有权。
- **Plaud** 最接近录音资产库：保留原始创建时间、支持导入/移动/恢复，单文件 Ask 用可点击
  时间戳引用，跨文件 Ask 至少标出来源录音。其官方导入时长上限文档互相冲突，限制值不能照抄。
- **Gemini Notebook** 的多源研究与内联引用规范，但 Notebook 之间隔离，公开文档也未证明
  原音频时间轴回放；适合参考来源治理，不适合作为会议主页。
- **Fathom** 只接受实时会议、不支持外部录音，Ask 历史离页丢失，删除也难恢复；这些都是
  ZuTalk 应避免的恢复与资料连续性反模式。

## 4. ZuTalk 的机会

### 4.1 第一屏：从“仓库”回到“我要继续做什么”

建议首页只回答四个问题：

1. 我今天有哪些 Session，它们分别属于什么 Topic、处于什么状态？
2. 如何快速找到一个 Topic、录音或转录中的一句话？
3. 我能否立刻开始录音，并在导入或之后归档时明确选择 Topic？
4. 有没有处理失败或需要恢复的内容？

推荐模块顺序：

1. 全局 Session 时间清单 + 搜索 + Topic filter
2. One-click Record / explicit Import / New Topic
3. Topic 工作区
4. 失败与恢复状态

不要把 AI 对话框、图表或研究模板作为空白首页的唯一主角。

### 4.2 单次访谈：媒体上下文与证据收集同屏

建议桌面工作区：

- 左/中主区：时间同步音频与转录，支持说话人、搜索和人工笔记；
- 右侧可收起栏：证据、Tags、洞察草稿；
- 选中转录文字后出现最小操作：`保存为证据`、`加标签`、`加入发现`；
- 点击任意证据始终回到原音频时间点和完整上下文；
- 截图、照片、文件可作为与文字并列的证据，并保存来源、时间、文件指纹/本地路径引用。

### 4.3 跨会话分析：三个入口覆盖大部分任务

Notebook 内的 Analysis 第一阶段只提供：

- 按问题：把各次访谈对同一提纲问题的回答并列；
- 按标签：查看某一主题在不同访谈中的证据；
- 搜索：关键词、短语和过滤器，结果可选进入 AI 总结。

过滤器优先级：录音、日期、参与者/说话人、Tag、提纲问题、处理/审核状态。所有统计数量都应是可点击的证据集合，不把频次直接解释为重要性。

### 4.4 证据到洞察：保持原子性与可逆性

建议数据语义：

- Evidence/Highlight：指向原始转录范围、音频范围、截图或附件的稳定引用；
- Tag：主题编码，可多选，可人工调整；
- Insight/Finding：可编辑叙事，引用一条或多条 Evidence；
- Report/Export：洞察的外部呈现，不反过来改变证据。

删除或移动证据时，应显示它被哪些洞察引用；转录被修订时，证据应保留稳定定位或明确进入“引用需复核”状态。

### 4.5 AI：建议、引用、审核与失败恢复

AI 不应静默改变用户资料。每一种自动能力至少应显示：

- 输入作用域；
- 处理中/已完成/失败状态；
- 生成时间和生成方式；
- 引用的录音/转录/证据；
- 接受、编辑、拒绝、重新生成；
- 离线、无权限、模型不可用时的退化路径。

优先能力：会话摘要、候选 Highlight、候选 Tag、按问题抽取回答、带引用的跨会话摘要。后置能力：自动聚类、Persona、情感分析、趋势 Dashboard。

## 5. 明确不做项

本轮 UI/UX 大改版不应默认纳入：

- 企业级 Workspace、部门 Folder 权限和复杂角色矩阵；
- 招募、激励、参与者 CRM 或 Participant Pool；
- 持续接入客服工单/NPS 的 Channel；
- Stakeholder Magazine、无需登录的默认公开仓库；
- 同时提供 Grid、Board、Table、Canvas、List 五种视图；
- 需要专人治理的全局 Tag Board；
- AI 自动应用 Tag、自动发布 Insight 或默认上传全部资料；
- 生成式图片混入研究证据；
- 用出现次数、情感值或 AI 排名替代研究者判断；
- 把 Discussion Guide 设为开始录音的硬前置条件。

## 6. 分阶段信息架构（IA）

### Phase 0：录音与资料恢复骨架

目标：先把第一屏、状态、返回路径和错误恢复做对，不引入新的研究术语负担。

```text
ZuTalk
├── Home
│   ├── 全部 Session（按录制时间）
│   │   ├── 标题 / Topic / 类型 / 语言搜索
│   │   ├── 本地转录全文搜索
│   │   └── Topic 筛选
│   └── 一键录音（可暂不归入 Topic）
├── Topics（左侧一级入口）
│   ├── 搜索 / 新建 Topic
│   └── Topic
│       ├── Resources（多场 Session）
│       │   ├── 音频与真实资源状态
│       │   ├── Live transcript
│       │   └── Processed transcript
│       ├── Topic Notes（一份共享文档）
│       └── Capture setup
└── Session
    ├── Live transcript（一个 Section）
    ├── Processed transcript
    ├── Notes（本场独立正文）
    └── Settings（录音快照、音频与导出）
```

关键交付：全局录音 / Session 台账、可选 Topic 归属、真实资源状态、处理进度、失败原因、
重试/恢复、按 Session 隔离的 durable Notes 与不可变设置快照，以及只有存在 active capture 时才
回到录音现场。本阶段不承诺截图/附件或一等 Evidence。

### Phase 1：证据与 Notebook 内分析

目标：完成从单次访谈到跨访谈发现的最小闭环。

```text
Notebook
├── 概览
│   ├── 目标 / 说明
│   ├── 状态
│   └── 日期 / 可选元数据
├── 录音
│   └── 单次访谈工作区
│       ├── 转录与媒体
│       └── 右侧栏：证据 / Tags / 发现草稿
├── 分析
│   ├── 按问题
│   ├── 按标签
│   └── 搜索
└── 发现
    ├── 洞察正文
    └── 引用证据
```

关键交付：稳定 Evidence ID、时间回跳、Tag 与 Metadata 分离、带引用的 AI 建议、人工审核。

### Phase 2：全库复用与安全输出

目标：在本地证据链成熟后，支持跨 Notebook 复用和显式分享。

```text
全部本地资料
├── 全局搜索
│   ├── 关键词 / 精确短语
│   ├── 过滤
│   └── 可选 AI 总结 + 引用
├── 全局标签（可选）
│   └── 从 Notebook 标签提升，而非默认全局
├── 已完成 / 已归档 Notebook
└── 导出 / 分享
    ├── Markdown / 文档
    ├── 证据清单
    └── 显式选择是否包含音频、截图、参与者信息
```

关键交付：跨 Notebook 作用域、全局标签治理最小化、隐私检查、可移植导出和引用完整性。

### Phase 3：只在验证后考虑

- Canvas/affinity mapping；
- Charts 与研究覆盖趋势；
- Participant timeline；
- 团队协作、评论与权限；
- 受控的公开链接或 stakeholder portal；
- 外部研究源同步。

进入条件：Phase 1/2 已通过真实研究任务验证，并有清楚的多人或组织需求，不能仅因为竞品具备而建设。

## 7. 当前代码核对与本轮实现收敛

本轮已对 Swift/Rust 代码、路由、Session 查询、Topic membership、转录任务、Topic/Session Notes、
资源状态和导出边界做只读核对，并据此完成第一阶段实现。这里区分“已经实现”和“需要新模型”：

| 项目 | 本轮状态 | 证据边界 |
| --- | --- | --- |
| Home 全局 Recording / Session 清单、稳定分页、Topic filter、状态和元数据搜索 | 已实现 | 本地目录，未声称是 AI 搜索 |
| Home 一键录音 | 已实现；0 个研究 Topic 也可用，不弹 Topic picker，直接复用唯一录音协调器；进行中改为返回入口 | 单独的保留内部 owner 是技术恢复边界，不按标题猜测、不迁移旧“默认”Topic；有效且启用的邀请码构成 realtime 授权，否则 quick-capture profile 强制回到 local-only |
| 转录全文搜索 | 已接入既有本地 `searchSessions`，含 debounce、单飞合并、旧请求隔离、有界命中片段和失败 warning | 限 5000 个匹配；需大库性能 QA |
| 冷启动落点 | 已改为 Home；只有真实 active capture 自动恢复编辑器 | 不代表跨进程录音恢复已重新验证 |
| 一级“主题”与 Topic 卡落点 | 已增加独立侧栏入口、搜索、新建和 Resources 工作台；进入子页面时保持父级选中 | Record 仍复用唯一 Capture Toolbar |
| 导入 | Home 明确选择 Topic + 文件；Topic 内也可导入 | 后台导入成功/失败可见；未新增云端分析 |
| Session 默认路由 | 按 active capture、import 和真实异步任务选择 Live/Processed | projection 的存在不再误判“已转录” |
| Session 身份和转录边界 | 显示时间、可选标题、Topic、状态；一页只挂载目标 Session 的一个 Section，移除 Topic-wide history rail 和 sibling 摘要 | 未新增 rename 契约；当前仍先读 Topic 级轻量 summary 后只 hydrate 目标正文 |
| Topic / Session Notes | Topic 保留一份共享研究笔记；每个 Session 另有按 `session_id` 隔离的 durable note document，支持关闭重开与永久删除清理 | 两类正文不互相回退；后台任务不能无交互改写人工笔记 |
| Session Settings | 显示本场开始时冻结的语言、realtime、会后处理、上下文发送快照，以及真实音频资源状态 | 历史快照不可被 Topic 当前默认值覆盖；音频销毁受 active capture、pending task 和删除后验证保护 |
| 未归档 Recording / Session 恢复 | Home 可显式归入 Topic；capture-inbox 录音走完整 move，真正 orphan 走原子首次 attach；归属未成功载入时明确显示 unknown | owner commit 后的转写投影失败标记 deferred，打开单条 Processed Transcript 时本地惰性修复；不覆盖人工编辑，也不与永久删除竞态 |
| Topic 多选研究集合 | 可复制按时间排序、带 `session_id` 的本地转录包；实时内容不存在时回退到处理后转录；单条为空不阻塞其他条目 | 是确定性导出，不是联合 AI 分析；资料包会列出被略过的来源 ID |
| Audio 入口 | Session Settings 中按真实可用性打开 ExportSheet，不再假装播放器 | 播放器仍需音频格式/seek 状态契约 |
| 并发与崩溃一致性 | 已实现跨视图录音启动 single-flight；新 Session/run/owner/三个 projections 原子提交；启动幂等修旧 membership 缺口 | 本轮验证本地状态机与存储边界，不声称已完成 provider 端到端验收 |
| 自动化与本机门禁 | 标准 Swift 全量测试通过；`vt-store` 与 `vt-ffi` 全量/集成测试通过；8 语言键值保持同批更新；macOS 12.5 deployment target 的无 Git archive App 构建与 release 静态门禁通过 | 本地链接仍提示当前调试 `libvt_ffi.a` 由 15.5 构建，正式兼容产物必须用 12.5 target 重建并在 Monterey 真机验收；测试也不等同于真实 provider、麦克风和超长录音压测 |
| Evidence/Tag/Insight/截图锚定 | 未实现 | 当前无稳定的一等数据模型，禁止 UI 假装完成 |

## 8. 限制与待验证问题

1. 本轮没有登录四个竞品的真实工作区，因此对布局和状态的判断主要来自公开帮助文档中的文字、截图说明和产品页，不等同于端到端可用性测试。
2. Dovetail 在 2026 年经历导航重构；当前 `Docs` 与旧文档 `Insights` 的命名存在冲突，说明部分公开资料处于迁移期。
3. Notably 的 Help Center 本轮无法访问，官网最新可见文章停留在 2024-10-16；其 2026 当前 IA、状态和产品活跃度证据不足。
4. 供应商关于转录准确率、AI 准确率、节省时间和“全部引用”的声明没有在本轮独立复现。
5. G2 评论存在选择偏差、激励评论和平台 AI 汇总偏差；Condens、Looppanel、尤其 Notably 的样本量不足以支持普遍性结论。
6. 已用隔离 bundle 标识的 QA 副本在代表性本机目录复验 Home 全局目录、一级“主题”、包含多条
   Session 的 Resources 工作区，以及一场代表性 Session 的实时稿/处理后稿。Session 页只挂载该场 Section，无 Topic-wide
   history rail；Topic 父级持续选中，Session → Topic → Topics 返回链路成立。内部 quick-capture
   owner 未出现在 Topic 列表。为避免写入真实数据，本轮没有点击录音、导入或编辑转录。仍未完成
   900px 最小窗口、完整 VoiceOver 任务流、长音频、截图存储模型和 provider 端到端性能验收。
7. “Insight/洞察”“Finding/发现”“Evidence/证据”最终中文命名需要通过 5–8 名目标用户的一轮任务测试，不应仅按研究行业术语决定。
8. 需要进一步验证的关键任务：首次录音、暂停/恢复、处理失败、修订转录、从原话创建证据、跨三次访谈找共同点、从洞察回到原音频、隐私安全导出。

## 9. Claim-to-source ledger

说明：`官方帮助`可作为供应商对功能和交互的直接说明，但不能独立证明性能；`官方产品页`更偏营销；`独立评论`只用于交叉验证体验与风险。

| ID | Claim | 证据性质 | 来源标题 / 发布者 / 日期 | 完整 URL | 置信度与边界 |
| --- | --- | --- | --- | --- | --- |
| DOV-01 | Project 代表一项 study；一次访谈是 recording + transcript data object；Project 包含 Data、Highlights、Tags、Docs/Insights、Charts | 官方帮助 | Projects / Dovetail / 无页面日期，检索于 2026-08-24 | [https://docs.dovetail.com/help/projects](https://docs.dovetail.com/help/projects) | 高；当前页称 Docs，旧索引曾称 Insights |
| DOV-02 | Project 支持 Grid、Board、Table、Canvas、List，并可按字段/Tag 过滤分组 | 官方帮助 | Project views / Dovetail / 无页面日期 | [https://docs.dovetail.com/help/views](https://docs.dovetail.com/help/views) | 高；不能证明哪种视图实际最常用 |
| DOV-03 | Workspace tags 跨项目，Project tags 局部；需明确 owner 与治理 | 官方 Academy | Intro to workspace tags / Dovetail / 无页面日期 | [https://docs.dovetail.com/academy/intro-to-workspace-tags](https://docs.dovetail.com/academy/intro-to-workspace-tags) | 高；部分能力受套餐限制 |
| DOV-04 | Search 提供 `⌘K`、Explore、自然语言总结和作用域/时间/字段过滤 | 官方帮助 | Search / Dovetail / 无页面日期 | [https://docs.dovetail.com/help/search](https://docs.dovetail.com/help/search) | 高；默认排除部分对象，需防 scope 误解 |
| DOV-05 | Chat 可在 Session/Project/Workspace 等不同范围工作，并引用多个上下文 | 官方帮助 | Chat / Dovetail / 无页面日期 | [https://docs.dovetail.com/help/chat](https://docs.dovetail.com/help/chat) | 高；AI 答案质量仍是供应商能力声明 |
| DOV-06 | 2026 新 Home 集成 Chat、Pinned、For You、Browse；旧体验保留至 2026-06-05 | 官方帮助 | New Dovetail experience / Dovetail / 2026 迁移说明 | [https://docs.dovetail.com/help/new-dovetail-experience](https://docs.dovetail.com/help/new-dovetail-experience) | 高；页面本身无明确发布日期 |
| DOV-07 | Dovetail 可存 text、images、audio、video、files、photographs 等研究材料 | 官方安全说明 | Security information / Dovetail / 无页面日期 | [https://docs.dovetail.com/help/security-information](https://docs.dovetail.com/help/security-information) | 高；未证明截图可直接锚定 transcript |
| DOV-08 | 用户肯定集中存储、转录与多来源洞察，同时反馈 UI 变化、标签效率和 AI 质量问题 | 独立评论 | Dovetail Pros and Cons / G2 / 页面含 2026-04 评论 | [https://www.g2.com/products/dovetail-research-pty-ltd-dovetail/reviews?qs=pros-and-cons](https://www.g2.com/products/dovetail-research-pty-ltd-dovetail/reviews?qs=pros-and-cons) | 中；167 条评论但有选择/激励偏差 |
| CON-01 | Project 固定包含 Overview、Sessions、Highlights、Charts、Artifacts；Home 是入口 | 官方帮助 | Getting started / Condens / 无页面日期，检索于 2026-08-24 | [https://condens.io/help/-/getting-started/](https://condens.io/help/-/getting-started/) | 高 |
| CON-02 | Transcript、notes、images、files、audio/video 都能被标记成 Highlight；转录 Tag 可形成媒体 clip | 官方帮助 | Structuring data with highlights and tags / Condens / 无页面日期 | [https://condens.io/help/using-condens/structuring-and-analyzing/structuring-data-with-tags/](https://condens.io/help/using-condens/structuring-and-analyzing/structuring-data-with-tags/) | 高 |
| CON-03 | Artifact 可承载原子 Finding、Report、Persona、Affinity Map/Whiteboard，并引用 Highlight/Chart/image | 官方帮助 | Using Artifacts for research outcomes / Condens / 无页面日期 | [https://condens.io/help/using-condens/sharing-findings/using-artifacts-for-research-outcomes/](https://condens.io/help/using-condens/sharing-findings/using-artifacts-for-research-outcomes/) | 高 |
| CON-04 | 右侧 Artifact 分屏支持跨屏拖入 Highlight、Tag、搜索结果和其他项目 Artifact | 官方帮助 | Analyze across projects / Condens / 无页面日期 | [https://condens.io/help/how-to-guides/best-practices/analyze-across-projects/](https://condens.io/help/how-to-guides/best-practices/analyze-across-projects/) | 高 |
| CON-05 | AI/精确搜索分别覆盖 Session、Project、Workspace、Participant、Highlights、Published Artifacts | 官方帮助 | Using AI search and analysis in Condens / Condens / 无页面日期 | [https://condens.io/help/how-to-guides/best-practices/ai-search-and-analysis/](https://condens.io/help/how-to-guides/best-practices/ai-search-and-analysis/) | 高；AI 质量未独立测试 |
| CON-06 | Ask your Session/Highlights/Repository 从原始会话或已审核 Highlight 中返回建议与引用 | 官方产品更新 | Ask your Repository: Analyze Research Data with AI Questions / Condens / 2026-03-24 | [https://condens.io/product-updates/analyze-research-data-with-ai-questions/](https://condens.io/product-updates/analyze-research-data-with-ai-questions/) | 高（存在该能力）；中（效果） |
| CON-07 | Project 默认有 Status、Start Date、End Date，可用于排序过滤 | 官方帮助 | Project information fields / Condens / 无页面日期 | [https://condens.io/help/using-condens/research-repository-functionality/project-information/](https://condens.io/help/using-condens/research-repository-functionality/project-information/) | 高 |
| CON-08 | Home 提供全库搜索、recent/favorite/new projects 和 pinned resources | 官方帮助 | Home / Condens / 无页面日期 | [https://condens.io/help/using-condens/research-repository-functionality/home/](https://condens.io/help/using-condens/research-repository-functionality/home/) | 高；受套餐和角色限制 |
| CON-09 | 用户外部反馈支持分屏、片段与低学习成本，也存在少量转录/界面/标签问题 | 独立评论 | Condens Pros and Cons / G2 / 页面含 2026-04 评论 | [https://www.g2.com/products/condens/reviews?qs=pros-and-cons](https://www.g2.com/products/condens/reviews?qs=pros-and-cons) | 中高；99 条评论，仍有评论平台偏差 |
| LOO-01 | Project 像用户研究资料文件夹，容纳 transcript、notes、tags | 官方帮助 | How to Create a Project / Looppanel / Akash Tandon，2025-04-02 | [https://help.looppanel.com/en/articles/8185104-how-to-create-a-project](https://help.looppanel.com/en/articles/8185104-how-to-create-a-project) | 高 |
| LOO-02 | Project Analysis 的主要入口是 Question View、Tag View、Search/Find | 官方帮助 | How to Analyze Data on Looppanel / Looppanel / Akash Tandon，2025-04-02 | [https://help.looppanel.com/en/articles/8099624-how-to-analyze-data-on-looppanel](https://help.looppanel.com/en/articles/8099624-how-to-analyze-data-on-looppanel) | 高 |
| LOO-03 | Find 可按 Tags、Questions、Files、Metadata 过滤，返回 AI Summary、Notes、视频片段和 transcript 引用 | 官方帮助 | How to Find Quotes, Data Points in a Project / Looppanel / Akash Tandon，2025-10-17 | [https://help.looppanel.com/en/articles/11010069-how-to-find-quotes-data-points-in-a-project-on-looppanel](https://help.looppanel.com/en/articles/11010069-how-to-find-quotes-data-points-in-a-project-on-looppanel) | 高（交互）；中（AI 效果为供应商声明） |
| LOO-04 | Global Search 跨 Projects，支持 Tags、Projects、Metadata | 官方帮助 | How to Search Across Your Entire Workspace / Looppanel / Akash Tandon，2025-04-01 | [https://help.looppanel.com/en/articles/11010188-how-to-search-across-your-entire-workspace-on-looppanel](https://help.looppanel.com/en/articles/11010188-how-to-search-across-your-entire-workspace-on-looppanel) | 高（功能）；供应商称所有洞察有引用，未独立复验 |
| LOO-05 | Discussion Guide 可组织 AI Notes，但修改不会自动重组已上传旧会话；视频画面上下文不会被 transcript AI 读取 | 官方帮助 | How to Add a Discussion Guide / Looppanel / Akash Tandon，2025-04-02 | [https://help.looppanel.com/en/articles/8146331-how-to-add-a-discussion-guide-to-a-project-on-looppanel](https://help.looppanel.com/en/articles/8146331-how-to-add-a-discussion-guide-to-a-project-on-looppanel) | 高；直接支持截图一等证据的机会判断 |
| LOO-06 | 支持音视频、transcript、notes、CSV；PDF 可存储/搜索，但图片不是其公开主分析流 | 官方帮助 | How to Upload Different File Types / Looppanel / Akash Tandon，2025-04-02 | [https://help.looppanel.com/en/articles/11010105-how-to-upload-different-file-types-in-looppanel](https://help.looppanel.com/en/articles/11010105-how-to-upload-different-file-types-in-looppanel) | 高；未找到截图编码工作流 |
| LOO-07 | Insight Summary 右侧面板可编辑、排序、增删证据并分享 | 官方帮助 | How to Use the Insights Summary Panel / Looppanel / Akash Tandon，2025-08-13 | [https://help.looppanel.com/en/articles/11010042-how-to-use-the-insights-summary-panel-on-looppanel](https://help.looppanel.com/en/articles/11010042-how-to-use-the-insights-summary-panel-on-looppanel) | 高 |
| LOO-08 | 用户评论肯定 AI Notes 和单一路径，同时报告编辑、搜索、定制、归档不足 | 独立评论 | Looppanel Reviews / G2 / 检索于 2026-08-24 | [https://www.g2.com/products/looppanel/reviews](https://www.g2.com/products/looppanel/reviews) | 中低；仅 26 条评论 |
| NOT-01 | 官方公开模型含 Folder、Project、raw data、repository search、participant、atomic Insights | 官方产品页 | Research Repository for Qualitative Data / Notably / 无页面日期 | [https://www.notably.ai/features/research-repository](https://www.notably.ai/features/research-repository) | 中；营销页，未确认独立 Session 对象 |
| NOT-02 | AI 可从 tags/themes/project 生成 Insight，并提供 suggested tags、sentiment、custom templates | 官方产品页 | AI Powered Qualitative Research / Notably / 无页面日期 | [https://www.notably.ai/features/notably-ai-research](https://www.notably.ai/features/notably-ai-research) | 中；效果和当前界面未独立验证 |
| NOT-03 | Transcript highlight 可通过 digital sticky note 回跳视频上下文 | 官方产品页 | Interview Transcription Software / Notably / 无页面日期 | [https://www.notably.ai/features/video-transcription](https://www.notably.ai/features/video-transcription) | 中 |
| NOT-04 | 官网可访问，但最新可见博客为 2024-10-16 | 官方站点可见状态 | Notably homepage / Notably / 最新可见文章 2024-10-16 | [https://www.notably.ai/](https://www.notably.ai/) | 中；不能据此断言产品停止，仅表示公开资料新鲜度不足 |
| NOT-05 | 少量评论提到 Tag 跨视图丢失与 sticky note 组织有限 | 独立评论 | Notably Reviews / G2 / 3 条评论均为 2023-09 | [https://www.g2.com/products/notably/reviews](https://www.g2.com/products/notably/reviews) | 低；样本极小且陈旧，只作为风险信号 |
| GRA-01 | Chat 可在单场、多选会议、Folder、People/Company 或全部会议范围工作 | 官方帮助 | Chatting with your meetings / Granola / 无页面日期 | [https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings) | 高（范围能力）；引用精度未统一证明 |
| GRA-02 | Granola 只在会议开始录制后生成记录，不支持 MP3 等预录音导入，也不保留音视频 | 官方帮助 | How transcription works / Granola / 无页面日期 | [https://docs.granola.ai/help-center/taking-notes/transcription](https://docs.granola.ai/help-center/taking-notes/transcription) | 高；说明它不适合作为完整资产库 |
| OTT-01 | AI Chat 可组合 Conversation、Channel、Folder，并提供来源链接回到原会话 | 官方帮助 | Otter AI Chat: Add Context / Otter / 2026-03-09 | [https://help.otter.ai/hc/en-us/articles/26467932629783-Otter-AI-Chat-Add-Context-Channels-Conversations-or-Folders](https://help.otter.ai/hc/en-us/articles/26467932629783-Otter-AI-Chat-Add-Context-Channels-Conversations-or-Folders) | 高；未证明所有模式都精确到句级时间戳 |
| OTT-02 | 自动 Slide Capture 把会议共享画面插入 transcript | 官方帮助 | Automated Slide Capture Overview / Otter / 2026-04-24 | [https://help.otter.ai/hc/en-us/articles/5093321813911-Automated-Slide-Capture-Overview](https://help.otter.ai/hc/en-us/articles/5093321813911-Automated-Slide-Capture-Overview) | 高；跨会话图片分析另有限制 |
| PLA-01 | 单文件 Ask 回答包含可点击时间戳；跨文件 Ask 标出来源录音 | 官方帮助 | Ask Based on a Single File / Plaud / 2026-08-13；Ask Across All Files / Plaud / 2026-06-05 | [https://support.plaud.ai/hc/en-us/articles/50636602977817-Ask-Based-on-a-Single-File](https://support.plaud.ai/hc/en-us/articles/50636602977817-Ask-Based-on-a-Single-File)；[https://support.plaud.ai/hc/en-us/articles/50810294218137-Ask-Across-All-Files](https://support.plaud.ai/hc/en-us/articles/50810294218137-Ask-Across-All-Files) | 高（交互）；回答质量为供应商能力 |
| GNB-01 | Notebook 支持 audio、images、PDF、网页和 Office 等来源；音频导入后转成文本 Source | 官方帮助 | Add or discover new sources / Gemini Notebook / 无页面日期 | [https://support.google.com/gemininotebook/answer/16215270?co=GENIE.Platform%3DDesktop&hl=en-GB](https://support.google.com/gemininotebook/answer/16215270?co=GENIE.Platform%3DDesktop&hl=en-GB) | 高；未证明原音频时间轴回放 |
| FAT-01 | 不支持上传外部录音，当前只记录 Zoom/Meet/Teams 实时会议 | 官方帮助 | Upload externally recorded calls / Fathom / 2025-08-22 | [https://help.fathom.video/en/articles/6049729](https://help.fathom.video/en/articles/6049729) | 高；roadmap 是意图，不是当前能力 |

## 10. 下一步研究门槛

这份底稿足以确定 IA 方向，但不足以直接宣布设计完成。进入详细交互和实现前，应完成：

1. 用 6–8 个真实 Topic 验证 Home、单次访谈、Topic 多选和导入四条关键路径；
2. 在 13/14/16 英寸窗口完成 Resources 工作台、Session header 和长转录 Section 的视觉/键盘/VoiceOver QA；
3. 为 Evidence/Tag/Insight/截图附件补数据模型与迁移提案，再画 `转录 + 右栏` 和 `转录 + 底部抽屉` 两套低保真方案；
4. 用同一组 3 次访谈完成“按问题找回答—保存证据—写一条洞察—回到原音频”的端到端可用性测试；
5. 确认本地 AI、远程 AI、完全关闭 AI 三种模式的状态与退化体验；
6. 在迁移、自动化测试和真实应用表面均验证后，再把 Phase 1 行为升级为发布承诺。
