# T2 采集产线切换战役（阶段 3/4 收尾 + 阶段 5 完成）

状态：**宪章**（2026-08-07）。守卫分发已落地；产线切换按下述分片推进，
每片独立绿、独立可回滚。笔记侧已整体完成（大纲编辑器 + 宽松迁移),
本文只管**转录稿**。

## 为什么必须原子、为什么可以分片

转录稿的首启迁移接线不能先于产线改写单独进 main:块文档一旦成为 tab
的真身,旧产线(平文本投影)再写就是数据分叉。但「原子」的单位是
**每份文档的切换时刻**,不是整个代码库——代码可以分片落地,只要切换
开关(打开路径走谁)最后一片才拨。

## 侦察结论:现有产线的事务协议(必须逐条对齐)

1. **实时投影**(notebook_capture_api ~8790):开文档 → 快照回滚点 →
   CaptureDeltaIndex 定位段 → 增量 plan → `apply_projection_batch`
   (文本 + 所有权标记 + 投影收据同批)→ 快照落盘 → SQLite 水位推进
   (`commit_projection_ack`)→ 失败回滚快照。收据的空操作路径承担
   崩溃重放的幂等。
2. **用户订正**(`replace_notebook_utterance_lane` ~6537):SQLite
   乐观锁暂存(`stage_utterance_variant_replacement`,expectedRevision)
   → 实时 tab 文档上按 delta 标记定位车道区间 → Replace + 用户变更收据
   (`apply_user_mutation_batch`,崩溃重放靠收据比对)→ SQLite 覆盖
   提交;任何一步失败走 `cancel_projection_mutation_after_error`。
3. **停止后投影**(~10117 同族):与 1 同构,另有 stt-async-v5 的远端
   删除前置与启动扫尾(见记忆/代码,不受本切换影响)。

## T2 等价物(设计定案)

- **投影写**:`TranscriptProjection::machine_upsert_block`——upsert 按
  id 天然幂等,**文档内投影收据整族退役**(崩溃重放=重放 upsert,终态
  相同);SQLite 水位推进与 ack 原样保留(水位是 SQLite 事实,与文档
  形状无关)。frozen_lanes 来自 SQLite 车道 edit revision(>0 即用户
  接管)。
- **用户订正**:SQLite 暂存/乐观锁协议原样保留;文档侧从「delta 定位
  区间 + Replace + 用户收据」换成 `user_replace_lane/text`(按块 id
  直达,无定位、无区间、无用户收据——同样由 upsert 语义承担重放)。
- **迁移**:打开路径上,旧平文本快照存在且无块文档 → 严格重放迁移
  (`replay_migration`,非线性拒绝并把投影态标 failed,旧文件不动);
  成功则旧文件 `.pre-epoch2` 留档。
- **守卫**:已完成——`EditorBridge::epoch2_admission_refuses` 按文档
  自声明的纪元分发,第 2 纪元走 block_guard,第 1 纪元维持 fork+重放。

## 分片序列(每片一个 PR 粒度,gate 全绿才进下一片)

1. ✅ 守卫按纪元分发(2026-08-07)。
2. ✅ **T2 产线并行实现**(2026-08-08):notebook_capture_api 内新增
   T2 写路径(投影 upsert + 订正动词 + 水位 ack),12 个镜像单测覆盖;
   不接管打开路径,无人调用即无行为变化。实现期两项设计定案的修正:
   - **乱序 Final 的块序**:旧产线靠整段重渲染保证「产物=按 sequence
     排序」(乱序收敛测试钉死),追加式 upsert 做不到。门面新增
     `insert_before` 锚点参数(写入时按 id 解析),产线按 sequence 算
     锚点:区域内插在首个更大序号块前;区域尾跳过尾随批注、停在下一个
     session 区域之前;无区域则追加(与旧渲染的新 section 落点一致)。
   - **frozen_lanes 必须来自可见覆盖层**:投影快照的
     `machine_utterances` 是裸机器事实(edit_revision 恒 0,收据摘要
     依赖这一点,不能动)。新增
     `load_realtime_loro_projection_if_pending_visible`(同一事务、
     合并用户覆盖),T2 投影改用它——冻结车道带真实 edit revision,
     被覆盖的源车道重放写的是覆盖本身的字节。
3. **读端切换准备**(Swift):NotebookTranscriptProjectionStore 增加
   块文档读路径(transcript_blocks / 事件),按 feature 判断走哪边;
   Delta 解析路径保留至切换完成。
4. **拨闸**:转录稿 tab 打开路径换 `open-or-migrate`(块文档优先,
   旧快照就地严格迁移),产线写路径同 commit 切到 T2;双机清单跑一遍
   (阶段 5 的验收项)。**前置补课(分片 2 侦察发现)**:T2 的销毁链
   动词还不存在——schema 已带 `zulangue_session_purge_receipts`,但
   「删除 session 所属全部句块 + 落收据」尚无实现(门面刻意没有删块
   函数,purge 需要一个绕过门面动词集的专用入口),必须在拨闸 commit
   之前落地。
5. **退役**:第三层旧代码负行数下线——resolve_capture_owned_range、
   remote_update_touches_capture_owned_range、render/plan/CaptureDeltaIndex、
   三张锚点 map、投影/用户收据族、LoroDeltaParser(Swift 读端跟着换后)。
   同时删 `TranscriptWritePath::Epoch1Flat` 分发与
   `load_realtime_loro_projection_if_pending`(裸机器版,收据族的唯一
   消费者)。

## 不变量(每片都要守)

- 水位语义不变:UI 车道解锁仍看 SQLite applied watermark;
- 乐观锁不变:expectedRevision 冲突行为逐字不变;
- 销毁链不变:收据 map 在两纪元同名同义;
- 八语范围、机器让人、批注 owner 恒 user——已在 vt-store 门面层钉死。
