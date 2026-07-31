# 时间线投影设计

多语言实时字幕的对应关系，从「辅助段绑定到 canonical 行」改为「各 lane 各自锚在同一条捕获音频时间轴上，对应关系在读取时由时间区间给出」。

本文只描述实时多语言路径。异步转录、个人笔记、资源不在范围内。

## -1. 同类系统怎么想这个问题

调研对象：whisper_streaming（LocalAgreement）、Google Live Transcribe 与 Cloud STT、
MeetDot（EMNLP 2021 开源多语字幕会议系统）、LiveKit 翻译字幕示例、广播字幕
CEA-608/708、WebVTT/TTML。五个跨系统的共识，逐条对照我们：

**一，全都维护两条流：假设流与承诺流。**whisper_streaming 用 LocalAgreement-2——
连续两个假设的最长公共前缀才算确认；Google Cloud STT 给每个 partial 一个
`stability` 分数；Soniox 用 token 级 `is_final`。我们的「事实层 / 投影层」是同一
思想在持久化维度的推广。**已对齐。**

**二，稳定化全部发生在呈现边缘，不在识别核心。**MeetDot 的手段清单：Translate-t
（限频重译）、Mask-k（末 k 词不显示，实践用 Mask-4；话头用 Mask-0 换首字延迟）、
偏置解码（倾向上一次的译法）、保行断（词不跨行跳）、像素级平滑滚动。全是显示
策略，识别器一个字没改。对我们：这些是阶段二之后的调参空间，**前提是先有指标**。

**三，跨语言对应靠时间或轨道，从不靠 cue 对 cue 绑定。**WebVTT/TTML：每语言一条
track，cue 各自挂在媒体时间轴上；LiveKit：翻译作为该语言自己的 segment 流发布，
按 participant+track 归属；广播 roll-up：传输顺序即时间。**没有一个系统发明过
「把 A 语言的段绑到 B 语言的段」**——这正是我们现在的模型，也是丢内容的来源。

**四，指标先于调参。**MeetDot 定义 normalized erasure（每 n 词被抹掉 m 词，m/n）、
translation lag、initial lag、burstiness（单次更新增删词数），然后才对着指标调
Mask-k 与偏置。Google 的三维是 erasure/lag/quality。我们目前一个都没测。

**五，延迟预算按受众分段。**MeetDot 发现首字延迟比稳态延迟更伤体验，所以话头
Mask-0、话中 Mask-4。对我们：观众栏的「等第一个词」和「等修订稳定」是两个预算，
不该用一个策略。

一个反向结论也重要：视频会议产品（Zoom/Teams/LiveKit 示例）全部按观看者各选一种
语言，**从不同屏并列多语言**——我们的投影幕三栏（SMD）在会议软件里没有先例，
只有字幕标准（WebVTT track 模型）和广播字幕给了可抄的形。

## 0. 这份设计基于的实测

设计的每一条都由测量支撑，不由推断支撑。复现方式见
[soniox_cross_lane_timestamp_alignment.rs](../../crates/vt-stt/tests/soniox_cross_lane_timestamp_alignment.rs)。

| 结论 | 数据 |
|---|---|
| 兄弟连接的 token 时间戳**不随时长漂移** | 8 分钟、2166 词、100% 配对；逐分钟均值 1.5–10.5ms，无趋势；p95 ≤ 60ms（一个 PCM 块） |
| 曾被记为「时钟漂移」的 1.7s/4.0s | 是**分段分歧**的中点距离。真实 run 里一个辅助段横跨两个 canonical 行，中点距离 1.35s 与 4.74s |
| 译文 token **没有时间戳** | 三次运行 5337 个译文 token，携带时间戳的 0 个 |
| 重连**会**重置 token 时间戳 | 替换连接报 2500ms，应为 5500ms，倒退 1500ms |
| canonical 是全组**最慢**的 lane | 源词终稿 p50：canonical 4672ms、辅助 1673ms；译文在辅助流上 p50 813ms 即到 |
| 现行模型的丢内容率 | 43.8 秒 6 行样本：1 行两种译文全为 `unavailable`；另一行挂着 20 倍于自身长度的译文 |

两条推论直接决定设计：

- **时间是可信的对应坐标。**所有 lane 吃同一份 PCM（`ActiveRemoteCapture::try_fanout_pcm`），
  同一个词的位置在各 lane 上一致到 60ms 以内。
- **译文不可能被切开。**没有时间戳就无法把一段译文按时间分给两行。任何试图让译文与源文
  一一对应的模型，在辅助段比 canonical 粗时必然丢内容。

## 1. 现在的形状

事实、持久单位、屏幕上的一行，是同一个东西：供应商的一个段。

`realtime_utterances` 一行存整段的 `source_text` 与聚合的
`source_start_ms`/`source_end_ms`；`SubtitleOverlayController` 渲染
`presentedUtterances.suffix(N)`，每行取 `language_variants` 铺成栏。

译文要可见，必须先成为某个 canonical 行的 variant，也就是必须**绑定成功**。于是：

- 辅助段比 canonical 细 → 第二段绑不上（未提交的 composition 修的是这个方向）
- 辅助段比 canonical 粗 → `align_source_text` 按设计返回 `Unrelated`，被它覆盖的行**永远拿不到译文**
- 译文即使 813ms 就到了，也要等 canonical 行终稿，**平均多等约 3 秒**

## 2. 目标形状

### 事实层

一条 **cue**：某条 lane 在某个时间区间上说了什么。

```
cue(lane, group_epoch, provider_sequence, start_ms, end_ms, text, completion, role)
```

- `start_ms`/`end_ms` 是**捕获音频时间轴**上的位置，不是连接相对位置（见阶段一）。
- 源 cue 的区间来自它自己的 token。
- 译文 cue 没有自己的时间，**继承同段源 cue 的区间**。这是译文无时间戳的直接后果，
  也是本设计承认的精度上限。
- cue 不引用任何其他 cue。没有 `bound_utterance_id`，没有占位检查，没有
  「durably unbound」这种状态。

事实层只记录收到了什么，不解释。语言未知就是 `und`，不猜。

### 投影层

给定一个界面的有序不变量，从 cue 算出它要的样子。对应关系是区间重叠查询，不是一次
会成功或失败的操作。

### 控制台

读的是事实层与投影层之差：哪条 lane 在该时段没有 cue、哪条在重连、哪些 cue 还没终稿。
不需要另造降级信号。

## 3. 关键决定：canonical 行不再拥有译文

这是整个设计里唯一真正的取舍，值得单独说清楚。

现在译文是行的属性（`language_variants`），所以「这段译文属于哪一行」必须有答案，
答不出就丢。改成时间锚定之后，这个问题**不再需要答案**：译文 cue 就待在它自己的时间
区间上，画布按时间取。

代价是诚实的：辅助流分段比 canonical 粗时，译文栏的卡片会**比源文栏更长、更少**。
观众看到的不是逐行对齐的三栏，而是三条各自断句、共享时间轴的栏。

**时间线不是把译文切得更准，是不再假装译文和源文一一对应。** 这正是 WebVTT / TTML /
IMSC 的模型：每种语言一条独立 track，各自的 cue 挂在同一条媒体时间轴上，格式里根本
没有「把 A 语言的 cue 绑到 B 语言的 cue」这个概念。

## 4. 每个界面的有序不变量

顺序本身就是裁决规则：冲突时靠前的赢。

**字幕画布（观众）**

1. 正在说的话必须可见——永不为了等待而空白
2. 同一时刻的各语言必须对得上——可以晚，不可以错配
3. 已经显示的文字不改变位置
4. 画布上永不出现系统话术
5. 画布不遮挡它所覆盖的内容

**持久记录（事后读者）**

1. 永不宣称未经确认的身份
2. 永不丢失已收到的内容
3. 完整优先于时效

**控制台（操作者）**

1. 任何降级必须可见，且只对操作者可见
2. 任何声称已发生的事，必须能自己复验

第 1 条与第 2 条的先后曾是悬案（「看得见的中断」vs「看不见的错位」）。实测把这个冲突
的性质改变了：源侧时间对应误差 p95 = 60ms，**错配不再是一个概率未知的风险**。因此本
设计取「必须可见」在前，并把残余误差限定为一句可陈述的话：译文栏的断句粒度可能粗于
源文栏，但不会张冠李戴。

## 5. 分阶段

每一阶段单独可发布、单独可回退。

### 阶段一 · token 时间戳投回捕获时间轴

[soniox_stream.rs](../../crates/vt-stt/src/soniox_stream.rs) 已经用
`connection_origin_ms` 把 `final_audio_proc_ms` 投回全局时间轴；`emit_response_events`
之前对 token 少加了同一次重基准。补上，并把见证测试
`reconnected_tokens_are_projected_onto_the_capture_wide_timeline` 从 `#[ignore]` 转正。

- 修好：重连后单条 lane 的时间戳倒跳
- 代价：无。这是把已有的重基准用全
- 前置：无。它是后续所有阶段的地基

### 阶段二 · 译文 cue 携带时间区间落库，可见性不再依赖绑定

`realtime_translation_inbox` 已经存了 `source_start_ms`/`source_end_ms`，缺的是让画布
投影直接用它们，而不是等 `bound_utterance_id`。

- 修好：辅助段比 canonical 粗时整行丢译文（实测 17%）；译文可见时间提前约 3 秒
- 代价：译文栏断句粒度与源文栏解耦，卡片长度不再一一对应
- 前置：阶段一

#### 实施细节

实时路径实测（代码追踪）：partial 译文其实**已经进 inbox**（辅助 assembler 的每次
revision 都 upsert，`completion = Partial` 也持久化）。真正的闸门是绑定加上时序：
辅助流比 canonical 快约 3 秒，partial 到达时它要绑的 canonical 行**还不存在**，
绑不上就不可见；等行出现时译文已是 Final 整块。

数据模型（无 schema 变更——inbox 行就是持久 cue）：

```
FfiNotebookCaptureTranslationCue {
    target_language, group_epoch, provider_sequence,   // 身份与序
    source_start_ms, source_end_ms,                    // 时间锚（阶段一后为捕获全局轴）
    text, completion,                                  // partial | complete
    withdrawn,                                         // 撤回墓碑 = 删除指令
    revision,
}
```

发布走**单通道**：cue 是带 revision 的持久 inbox 事实（「SQLite 是机器事实账本」），
partial 与 Final 一样随 `FfiNotebookCaptureEvent` 的 delta 发布，按
`(epoch, provider_sequence, target_language)` upsert，撤回墓碑即删除；全量快照
（含合并邮箱丢帧后的 gap 修复快照）附带该 session 全部 present cue，所以 cue 与
utterance 共用同一套丢帧自愈机制。preview 通道保持原语义不动（只承载 canonical
推测尾巴）。

Swift 侧：

- Store 增加 `translationCues: [language: [CueDTO]]`（durable，按
  `(epoch, provider_sequence)` 去重、按 revision 取新）与 preview 尾巴合并视图，
  排序键 `(group_epoch, source_start_ms, provider_sequence)`。
- **只有字幕画布的观众模式换布局**：行×列 变为 **列×各自的 cue 栈**。
  源文列保持现状（utterance 栈）；每个译文列独立渲染自己的 cue 栈。
  所有列底部锚定——**「现在」永远在底边**，跨语言对应在底边自动成立
  （广播 roll-up 的形）。历史区行对齐让位于「当前 > 过去」既有硬不变量。
  超高 cue 显示能装下的最长后缀（MeetDot 规则，与 ad79556 的「裁读过的头、
  不裁活的尾」一致）。
- 操作者会话视图与转录页**不变**——它们是记录界面，保持行/绑定模型。

边界规则：

1. 跨 epoch 时间不可比：排序先按 epoch，画布按 epoch 顺序渲染，永不跨 epoch 比时间。
2. 无时间锚的 cue（源 token 未到）：排在同 epoch 同 lane 最后一个有时间的 cue 之后，
   按 provider_sequence。
3. 撤回：cue 从列中消失；preview 通道沿用 9ef4469 的撤回即发布规则。
4. 绑定机制**原样保留**，继续喂持久记录（Loro lane、导出、转录页）。画布不再依赖它，
   但记录仍依赖它。「已可见但未入записи」正是控制台要读的两层之差（阶段三）。

#### 指标先行：erasure 基线

改布局之前，先在 preview 合并点埋 erasure 计数（MeetDot 的 normalized erasure）：
每次 preview 发布，按 lane 计算 `len(prev) - len(common_prefix(prev, new))` 累加，
会话结束输出每 lane 的抹除字符数与更新次数。**只有计数，无文本**（隐私门禁）。
没有这个基线，阶段二上线后「译文流出来了还是更闪了」无法回答；Mask-k/偏置等
调参也以它为靶。

### 阶段二·五 · 呈现节拍器（paced reveal）

阶段二让译文在供应商产出后立即可见，但供应商的产出天然是**一口一口**的：
翻译要等足够的源语境才能开译，所以译文 token 按响应成批到达（批的大小与间隔见
实测数字）。画布若「到什么画什么」，译文列就是一口一口贴上去，不是字浮出来。

解法在呈现边缘（先例共识第二条），机制是一个**按语速放字的显示游标**：

- 每张可见卡片持有已到文本的缓冲与一个 reveal 游标；游标以恒定字速前进
  （按文字系统标定：CJK 与拉丁字速不同），新批次只是加长缓冲，不直接上屏。
- **积压自适应**：字速 = 基础速率 + k × 缓冲积压，并对缓冲滞留时间设硬上限
  （数百毫秒级），保证节拍器永远只增加有界延迟。
- **免费的 Mask-k**：落在未 reveal 尾部的供应商改写零成本消化——观众从未见过
  被改的字。reveal 缓冲就是以时间为单位的 masking，而且不像 MeetDot 的 Mask-4
  那样恒定扣词，它只在有积压时才存在。
- 纯 Swift 呈现层改动，Rust 与 FFI 不动；erasure 基线继续在 FFI 口径计量，
  节拍器的上屏收益后续加 Swift 侧计数对照。

### 阶段三 · 单 lane 故障隔离

`(lanes.len() > 1)` 的 `group_cancel` 退役。辅助 lane 重连只降级它自己那段时间，
canonical 断线才整组停。

- 修好：任一条 lane 抖动导致整场字幕停止（选的语言越多越脆）
- 代价：静默降级成为常态，必须同时落地控制台第 1 条不变量
- 前置：阶段一（否则重连后时间戳倒跳，隔离出来的那段会错位）

阶段一二落地后的具体形状：

- vt-stt 每条连接本就自带重连与 replay（3 次退避 + 2s 重叠回放），时间戳重基准
  已实测。隔离只是让 vt-ffi **不再把辅助 lane 的抖动升级成组失败**。
- 新规则：辅助 lane `Reconnecting` → 组继续，该列的 cue 流自然停顿又自然恢复；
  辅助 lane 终态失败 → 只标记该 lane 不可用；**canonical 终态失败才整组停**
  （它是转录记录的权威）。
- 画布侧必须区分「还在追」和「lane 已死」：死 lane 的列不显示等待省略号
  （安静画布规则——等待暗示会来，死 lane 不会来），
  `SubtitleAudienceTimeline.waitingLanguages` 需要 lane 健康输入。
- 事件需带每 lane 健康（现在 `remote_health` 是组级的），操作者 hover chrome
  显示降级徽记；观众永远看不到。

### 阶段四 · canonical Finalize 广播退役

`4bf0c02` 的端点广播存在的唯一理由是「让所有 lane 分得齐，好按行号对应」。对应改由时间
给出后，它只剩副作用：把全组的分段节奏钉在最慢那条 lane 上。

- 修好：辅助流被迫跟随 canonical 断句带来的额外延迟
- 代价：需要先确认没有其他消费方依赖分段一致
- 前置：阶段二

## 6. 需求是怎么被理解的（方法，供后续迭代复用）

这份设计得出的过程本身是个可复用的回路：

1. **症状用用户的原话收集**，不翻译成技术词（「译文一段段蹦」，不是「绑定延迟」）。
2. **每个症状问：谁、在哪个时刻、看着哪个界面体验到它。**答案聚成三个受众
   （观众/操作者/事后读者），它们对同一份数据的要求相反。
3. **每个界面写有序不变量**，顺序即裁决规则。多数「冲突」在排序后自动消解，
   剩下的才是真正要用户拍板的。
4. **推断必须过测量**。「时钟漂移」流传了一周，一次 8 分钟实验就证伪了；
   反而测出了没人猜到的事——canonical 是全组最慢的 lane，译文 813ms 就到了。
   凡是要当设计前提的断言，先写一个能证伪它的实验。
5. **概念模型对照同类系统**。先例把我们的选择分成两类：行业共识
   （假设/承诺分流、呈现边缘稳定化、时间轴对应）和我们独有的负担
   （cue 对 cue 绑定——没有任何先例这么做）。独有的负担优先怀疑。
6. **每个阶段绑一个可观测指标**，上线前有基线，上线后能回答「变好了吗」。

## 7. 不变的部分

- **持久层规则不放宽。**画布允许猜、允许重锚、允许晚到就地更新；导出与记录投影只取已
  确认的内容。同一个问题在两个界面有两个相反的正确答案，这是有序不变量的直接推论，
  不是不一致。
- **机器原文不可变。**provider token 与 utterance 事实继续作为不可变证据保存；用户所有权
  只控制可编辑的 Loro 投影。
- **日志不记转录文本。**本设计新增的任何观测点只输出语言码、毫秒、计数与行号。
