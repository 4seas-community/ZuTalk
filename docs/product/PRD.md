# ZuTalk 产品说明

ZuTalk 是面向访谈、会议与多语言研究的 macOS 本地工作台。它把现场录音、实时理解、
会后转录、研究笔记和多次访谈的整理放在同一条可恢复、可追溯的路径里。

数据默认保存在这台 Mac。只有用户在具体 Session 中明确开启远端转录或分析时，
对应内容才进入所选择的服务。

## 用户对象

- **Topic（内部仍为 Notebook）**：一个研究主题、项目或持续沟通场景的长期容器。
- **Recording**：一次从 Home 直接开始的录音，可以暂时不属于任何研究 Topic，也不要求用户
  先创建研究 Session。
- **Session**：被放进研究语境的一次录音或音频导入，是全局目录中的稳定研究对象。
  当前存储仍为每条 Recording 建立技术 `session_record`，用于加密音频、状态、恢复和来源 ID；
  这不是要求用户先填写 Session。
- **Transcript**：同一 Session 的实时记录或处理后版本，不是两条不同 Session。
- **Topic Notes**：当前 Topic 共用的一份研究笔记，用于跨 Session 的研究整理。
- **Session Notes**：每个 Session 独立持久化的笔记正文；关闭、重开和永久删除均遵守
  Session 生命周期，不能借用 Topic Notes 或其他 Session 的内容。
- **Session Settings / Files**：本场录音的不可变配置快照、加密音频、转录投影和资源状态。
- **Evidence / Insight**：带来源的证据和跨 Session 发现；这是下一阶段的数据模型，
  在稳定 ID、时间范围、截图附件与引用完整性落地前，不提供虚假的 AI 按钮。

## 当前主流程

1. 冷启动进入 Home 的全局 Recording / Session 清单；记住的 Topic 只作为上下文，不绕过 Home。
   如果确有进行中的录音，才自动返回对应实时工作区。
2. Home 以录制时间倒序显示全部 Recording / Session，并支持 Topic 筛选、元数据搜索和本地
   转录全文搜索。Home 的“开始录音”一键进入真实录音状态，不先弹 Topic 选择。
3. 快速录音先显示为“未归入主题”，之后可显式归档；导入音频仍要选择 Topic，不能继承
   一个看不见的隐式目标。
4. 左侧一级“主题”进入 Topic 列表；打开 Topic 后进入资源工作台，可搜索、录制、导入、
   查看状态、维护 Topic Notes 和录音默认设置。
5. 打开 Session 后保留 Topic → Session 身份，但页面只呈现这一场 Session 的一个 Section，
   在 Live transcript、Processed transcript、Notes 和 Settings 之间切换；音频与导出入口从
   Settings 的真实资源状态进入。
6. Topic 内可选择多条 Session，复制一份按时间排列、保留 `session_id` 的本地研究材料；
   这是未来联合分析的显式输入集合，不会自动上传或生成结论。

## 信息架构

```text
ZuTalk
├── Home
│   └── All recordings / Sessions（全局、按录制时间）
│       ├── Search（标题/Topic/类型/语言 + 本地全文）
│       └── Topic filters
├── Topics（左侧一级入口）
│   └── Topic workspace
│       ├── Resources（多场 Session 的音频与转录版本）
│       ├── Topic notes
│       └── Capture setup
└── Session
    ├── Live transcript（一个 Section）
    ├── Processed transcript（同一 Session 的另一版本）
    ├── Notes（本场独立正文）
    └── Settings（不可变录音快照、音频与导出）
```

### Home

- 全局录音 / Session 清单是首页唯一主体；Topic 管理位于独立的一级“主题”入口。
- Session 行至少显示录制时间、标题或内容预览、Topic、类型、语言、时长和真实处理状态。
- Home 提供一个不要求 Topic 的“开始录音”主按钮。实现上由隐藏的本地 capture inbox 承载
  profile、加密音频和崩溃恢复，UI 不把它展示为研究 Topic；进行中的录音把按钮切换为“返回录音”。
  这个技术容器使用保留内部身份单独创建，不按“默认”标题猜测，也不迁移或隐藏用户已有的
  “默认”Topic。因此全新用户可以在 0 个研究 Topic 时直接录音，旧 Topic 的 Notes/Context Pack
  仍保持可达。
- Home 一键录音先提交已排队的录音配置。已兑换、启用且仍有效的邀请码构成该入口使用实时
  转录的明确授权；没有有效邀请码时，隐藏的 quick-capture profile 必须回到 local-only，不能沿用
  上一次远端开关。Topic 工作区内的显式实时转录入口仍按自身配置执行。所有开始入口共享同一条
  跨视图 single-flight gate，避免双击或页面切换创建两条录音/占用两份临时凭据。
- 未归属 Topic 的 Recording 标为未归档但仍可打开。归档 capture-inbox 录音时使用完整 move，
  音频与转录一起移动；真正没有任何存储归属的历史 Session 使用原子首次 attach。Core 均拒绝
  覆盖既有研究 Topic、垃圾箱条目或进行中的录音。
- “未归入主题”只能在一次完整 membership snapshot 成功后判定。首次载入失败时显示“主题归属
  尚未载入”、隐藏未归档筛选并禁止归档动作；刷新失败则保留上一次可信 snapshot。
- 搜索失败保留元数据结果和上一次可信目录，并显示 Retry；不能把后端错误显示成“无结果”。
- Start Recording、New Topic 与 Import Audio 都是显式主动作；只有导入前必须确认 Topic 与文件。

### Topics / Topic workspace

- “主题”页提供搜索、新建和 Topic 卡；内部 quick-capture owner 与 shared inbox 不进入列表。
- Topic 卡进入 Resources，而不是直接进入麦克风控制或暗示录音已开始。
- Resources 组织多场 Session；Session 以时间为主要识别信息，标题、预览、状态和时长是辅助信息。
- Record 只进入现有 Capture Toolbar，真正开始/暂停/停止仍由唯一录音状态机负责。
- Import 在后台执行，成功、失败和重复点击均有可见反馈。
- 刷新失败保留最后一次完整快照；Topic 超过 500 条 Session 仍必须完整加载。
- 多选产生明确的研究集合。目前可复制带来源 ID 的本地转录包；未来 Analysis 必须复用同一
  集合语义和引用边界。单条没有可用转录时保留其他成功条目，并在资料包中列出被略过的
  `session_id`；全部为空时不覆盖剪贴板。

### Session workspace

- Breadcrumb、日期时间、可选标题、Topic 和状态共同构成稳定身份；切换 tab 不丢失 Session。
- 正在录音时默认打开 Live transcript。
- 导入音频但尚无任务时默认打开 Processed transcript，展示明确的“开始处理”动作。
- 存在 pending/failed/ready 异步任务时打开 Processed transcript。
- 普通已结束录音且没有异步任务时打开 Live transcript，避免因空 projection 误入空页面。
- Live transcript 只装载路由中明确指定的 Session Section；不显示 Topic 内其他 Session 的
  左栏、摘要，也不在目标缺失时回退到同 Topic 的最新或第一份转录。
- Session 主名称使用录制日期时间；可选标题是辅助信息，不显示裸 UUID。
- Notes 打开按 `session_id` 隔离的 durable block document；失焦、切换 tab 或关闭页面前要完成
  draft flush，写入失败保留可恢复状态。
- Settings 只显示本场开始时冻结的语言、远端实时、会后处理和上下文发送快照；不得用 Topic 当前
  默认值重写历史。Audio 只有在可导出时才可点击，销毁入口必须通过进行中录音、待处理任务和
  删除后验证三重保护；导出打开真实 ExportSheet，不伪装成不存在的播放器。
- 转录编辑只有在持久化成功后才退出编辑；失败保留 draft 并给出反馈。

### Topic notes 与 Session notes

- 当前实现是一份 Topic 级 durable manual-note document。
- 每个 Session 另有独立 durable note document；两类文档不能互相回退或借用正文。
- Session 永久删除同时清除对应笔记文件；普通关闭/重开保持正文。
- 后台任务不能无交互改写 Topic Notes。
- 后台任务也不能无交互改写 Session Notes；未来跨 Session 引用必须保留来源和冲突规则。

## 状态与恢复

- Session 至少区分 recording、completed/imported、interrupted、failed。
- 异步转录至少区分未开始、等待/处理中、可用、失败，并显示可执行的恢复动作。
- 资源读取错误是 unknown，不等于 missing。
- Session owner、三个资源 projection 与新录音 run 在一个 SQLite transaction 中建立；启动时会
  幂等修复旧版本可能遗留的 run/membership 缺口。
- 历史 orphan 归档的 owner commit 是成功边界。后续可编辑转写文档若暂时写入失败，会返回
  deferred 而不是把已提交的归档误报为失败；用户打开该 Session 的 Processed Transcript 时
  本地惰性重试。重试只补不存在的带 `session_id` 段落，不覆盖人工编辑，并与永久删除共用
  ownership gate，不能把已销毁内容写回来。
- 首次加载失败显示全页错误与 Retry；刷新失败保留旧内容并显示 warning。
- Trash、音频安全销毁与删除验证保持现有审计语义。

## 下一阶段：研究证据闭环

目标链路是：

```text
Topic → Session → Transcript / Note / Screenshot → Evidence → Tag → Insight
```

进入实现前必须具备：

- Evidence 的稳定 ID、来源 `session_id`、转录范围或音频时间范围；
- 截图/附件的本地引用、内容指纹、删除与移动规则；
- Tag 与 Session metadata 的明确区分；
- Insight 对多条 Evidence 的引用和反向依赖检查；
- 单场 / 已选 Session / 当前 Topic / 全部本地资料四种显式作用域；
- AI 只生成可审核建议，列出来源并支持接受、编辑、拒绝和重试。

## 数据与隐私边界

- Topic、Session、录音、转录、Topic Notes、Session Notes、设置快照和研究集合以本机数据为准。
- 麦克风音频只在用户开始对应录音后发送给已配置的转录服务。
- 导入音频保存在目标 Topic；只有用户明确发起远端处理后才发送。
- Context Pack 在预览并确认后才附加到服务请求。
- 凭据只用于建立服务连接，不自动授权任何音频、文本、截图或笔记传输。
- 远程服务不可用时，本地录音仍继续并被可靠保存。
- 复制研究集合只写入本机剪贴板，内容包含来源 Session ID；它不是 AI 分析或外部分享。

## 文档写入

用户编辑和确定性的转录投影是文档的写入来源。后台处理不能在没有明确产品交互的情况下
改写用户笔记。

转录文档使用同一条主动编辑边界：

- 尚未完成的临时 utterance 由自动转录拥有，可以继续修正，不开放编辑。
- 已完成并落盘的 utterance 可以由用户主动编辑，即使本次录音仍在继续。
- Soniox `is_final = true` 的内容不会再由实时投影改写；完整 utterance 写入 Loro 后即可编辑。
- 用户第一次提交某个语言 lane 的修改后，该 lane 的 Loro 内容转为用户所有。
- Provider token 和机器结果作为不可变事实继续保存；用户所有权只控制可编辑 Loro 投影。
- 迟到的跨流结果只能补充尚不存在的翻译 lane，不能重写已经写入 Loro 的 finalized lane。

## macOS 范围

当前仓库只提供 macOS 应用。界面和系统集成位于 Swift；业务规则、持久化、转录协议、
加密和导出位于 Rust。
