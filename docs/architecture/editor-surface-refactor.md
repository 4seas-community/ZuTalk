# DocumentEditorPage 内容区状态建模重构 — 交接说明

日期：2026-07-31（2026-08-03 入库，随库校订）

> 入库时校订：`EditorRouteV2` 已更名为 `EditorRoute`（V2 后缀在全仓收敛后移除）；
> 语言列表更正为实际发布的八种，缅甸语明确不在范围内。文中的成因链、
> 五个状态量、三个 Policy 与路由可选性均已对照当前代码复核，结论不变。
背景 bug：「异步转录」tab 在未选中 session 时渲染为整页空白（纯背景色）。
最小修复已提交（见下），本文档描述背后的结构性问题和建议的结构性解法，供后续实施。

## 1. 已完成的最小修复（现状）

- `macos/Zulangue/Zulangue/Pages/DocumentEditorPage.swift` 的 `documentEditorContent`：
  原本非 manualNote 且非 pending/failed 时兜底返回 `Color.clear`，现在对
  `displayType == .asyncTranscript` 增加了一个 `EmptyState` 分支，
  文案引导用户去「资源」页选择录音。
- 新增本地化 key（8 个语言：en/th/ja/ko/fr/es/de/zh-Hans）：
  - `editor.transcript.async.no_session_title`
  - `editor.transcript.async.no_session_desc`

这只是把漏掉的那一种组合糊上了，生成这类漏洞的机制没有变。

## 2. 空白页的成因链（复盘）

用户在未选中 session 的情况下点开「异步转录」tab 时：

1. `NotebookTranscriptPresentationPolicy.shouldShow`（DocumentEditorPage.swift 约 L49）
   规定 async tab 必须有 `selectedSessionId` 才显示转录层 → `showTranscript = false`。
2. body 的 ZStack 中三个分支全部落空：
   - `AsyncTranscriptView` 分支要求 `effectiveSessionId != nil`；
   - 兜底 `EmptyState` 分支要求 `showTranscript == true`；
   - 只剩 `editorLayer` 以 opacity 1 显示。
3. async tab 不挂 Loro 编辑器（`NotebookDocumentSurfacePolicy.mountsLoroTextEditor`
   仅对 manualNote 为 true），`documentEditorContent` 落进 else 分支 → `Color.clear`
   → 整页空白。

## 3. 结构性诊断

### 3.1 「内容区显示哪个面」没有单一事实来源

决定内容区显示什么的状态散落在至少五个量上：

- `@State showTranscript: Bool`
- `@State isShowingResources: Bool`
- `@State presentedCaptureSettingsNotebookId: String?`
- 派生量 `activeNotebookTab?.displayType`
- 派生量 `effectiveSessionId`

合法的「面」只有六七个（实时转录 / 异步转录 / 笔记编辑器 / 笔记时间线 /
录音设置 / 资源 / 缺文档），但布尔组合空间有几十种。ZStack 里的
`if / else if` 链是在手工枚举这个空间，而 SwiftUI 的条件链没有穷尽性检查——
漏一种组合，编译期无感，运行时空白。

### 3.2 决策逻辑切成三个 Policy，没有一处对「总和完整」负责

- `NotebookTranscriptPresentationPolicy`（transcript 层显不显示）
- `NotebookDocumentSurfacePolicy`（挂不挂 Loro 编辑器）
- `NotebookCaptureSettingsRoutePolicy`（路由复用/交互性）

三者都是否定式规则（「什么时候不显示 X」），没有任何地方回答
「那此时显示什么」。`shouldShow` 返回 false 之后责任凭空消失。
三个 Policy 的存在本身说明作者已经感到状态协调有问题，但一直在旧模型上加规则。

### 3.3 路由层允许表达非法状态

`EditorRoute.selectedSessionID` 是可选的，而 async tab 语义上必须有 session。
这条不变量只活在渲染策略里，导航层不知道，所以 tab 栏可以把用户导航到
内容层无法渲染的路由。

连带症状：pending/failed 的占位 UI 写了两遍
（`PendingDocumentState`/`FailedDocumentState` 在 editor 层；
`AsyncTranscriptView` 内部又有一套 empty-state 分支），因为两层都不确定
对方会不会接住。

## 4. 建议的结构性解法

核心动作：把「内容区显示什么」收敛成一个穷尽枚举 + 一个纯函数。

```swift
enum EditorSurface: Equatable {
    case realtime(notebookId: String, sessionId: String?)
    case asyncTranscript(notebookId: String, sessionId: String,
                         tabId: String, status: NotebookTabStatus)
    case asyncNeedsSession            // 本次 bug 对应的、此前不存在的状态
    case manualNote(notebookId: String, tabId: String)
    case manualTimeline(notebookId: String, tabId: String)
    case captureSettings(notebookId: String)
    case resources(notebookId: String)
    case missingDocument
}

enum EditorSurfacePolicy {
    static func resolve(
        route: EditorRoute?,
        activeTab: NotebookTabViewModel?,
        presentedCaptureSettingsNotebookId: String?,
        isShowingResources: Bool
    ) -> EditorSurface { ... }
}
```

要点：

1. **body 对 `EditorSurface` 做 exhaustive switch**。少写一个 case 编不过；
   「空白页」这类 bug 从运行时问题变成编译期不可能。
2. **每个非法组合被迫获得名字**。写 resolve 时必须回答「async 无 session
   显示什么」——`asyncNeedsSession`。UX 上有两个候选：
   a) 引导去「资源」页（最小修复目前的做法）；
   b) 参照 `ManualNotesTimelineView` 的模式，直接在页内列出该 Notebook
      可转录的录音供点选（少一次跳转，推荐）。
3. **保留 ZStack + opacity 的渲染技巧**。现在用 opacity 而非条件渲染是为了
   切 tab 时保住编辑器的光标、滚动位置和 IME 状态（代码注释有说明）。
   重构时编辑器层继续常驻，但 opacity / allowsHitTesting / accessibilityHidden
   的条件全部从 surface 枚举派生，不再从散落的布尔量派生。
4. **纯函数可单测**。把 (route × tab × status × overlay) 组合表喂进
   resolve 断言输出；现有三个 Policy 的测试可迁移合并。
5. **顺带清理**：
   - `@State showTranscript` 预计可整个删除；
   - `selectNotebookTab` / `showResources` / `showCaptureSettings` 里互相
     清理对方状态的代码会消失（它们存在就是因为布尔量要手工维持互斥）；
   - pending/failed 占位面板收敛到一处（建议收进 asyncTranscript case
     的视图内部，删掉 editor 层的 `PendingDocumentState`/`FailedDocumentState`
     重复实现）。

## 5. 工作量与风险

- 估计半天以内：一个枚举、一个 resolve 函数、body 改 switch、迁移测试。
- 主要风险点：IME/光标保持行为（务必手测中文输入法下切 tab）；
  以及 `NotebookCaptureSettingsRoutePolicy.isDocumentEditorInteractive`
  对编辑器可编辑性的联动，需要在 resolve 之后统一派生。
- 验收标准：任意 (tab, session, task status, overlay) 组合下内容区
  都渲染出一个有名字的面；resolve 函数单测覆盖全组合表。
