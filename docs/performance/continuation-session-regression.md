# 多会话运行后交互迟钝：限定路径诊断

截至 2026-10-16，仅静态读取指定四个文件及其历史；未构建、测试、运行检查、操作应用或生产数据。未修改产品代码。

## 结论与版本边界

在正式版候选基准中，最值得主负责人继续取证的是**保存前的全历史主线程快照**，其次是**追加记录时的全历史差集与时间线缓存键扫描**。两者可以使多个活跃会话争用主线程，也会随每个会话的已加载历史增长，但目前不足以认定为用户现场根因，更没有找到“所有会话停止后仍永久高频工作”的可靠证据。

- 现场为正式版 1.3.8/build25，源码暂对应 `93f0d3394`（Prepare Tivano 1.3.8）。同版本可能重打包，以下“正式版已有”均指该提交，未证明现场二进制与之完全一致。
- 主负责人给出的 Dev 基准为 `4fc87d1ee`，提交标记 dev-1.3.11；本 worktree 指定文件也包含独立 `hasImages` 标志。
- `589738835`（dev-1.3.10）新增图片展示时确实引入工具输出观察扩散；`4fc87d1ee` 随即隔离该依赖。它不在 `93f0d3394`，不能用来解释该正式版现场。
- 优先使用索引 `Users-elijah-air-Universe-Oort-forked-tivano-tivano.dev` 定位 `observe`、`flushDeltas`、`scheduleSave`、`saveNow`、`snapshotForSave`，随后核对 worktree 源码与各提交对象。下文行号采用本 worktree，历史位置用提交和符号定位。

## 1. 正式版已有：保存写入前仍在主线程遍历全部已加载历史

**调用链。** `ThreadRuntime.observe → handle(.messageDelta/.reasoningDelta/.toolOutput) → queueDelta → flushDeltas → TimelineEntry.item → onChange → markTurnDirty`；`flushDeltas → scheduleSave → saveNow → snapshotForSave → DiskWriter.shared.writeThread`。运行时和条目均为 `@MainActor`，`snapshotForSave` 在交给 DiskWriter 前同步执行。位置：`ThreadRuntime.swift:237–258、2604–2611、2727起、3609–3749、4271–4434`；`Timeline.swift` 的 `ThreadDocument/ThreadTurnReference` 定义保存头与完成轮次索引。

**触发与增长。** 有实际变更且历史加载完毕时，运行中按每会话 5–20 秒保存；idle 变更延迟 800ms，轮次结束立即保存。每个快照分配长度为全部 `entries.count` 的 `nextPositions`，反向和正向扫描全部记录，再扫描全部记录分配到 head 或 dirty turns，同时过滤、映射全部 `turns`。即使只有当前行变动，主线程仍承担 O(E + T) 遍历及临时分配；多个会话各自触发时，工作量约按各会话 E、T 相加。成功回调还在主线程遍历完整 `turnIndex` 更新已保存版本。

**保留与停止。** 完成轮次采用独立 StoredTurn 并只写脏轮次，避免每次重写所有正文，但未避免构建快照时扫描旧记录。`finalizeTurn` 不移除旧 `entries/turns`；它追加 turnEnd、切 idle、`saveNow`。成功保存且无新事件后，`saveRevision == lastSavedRevision` 会跳过快照，保存 timer 被清空且不自循环。因此“保留完成会话”本身不能推出持续 CPU。停止后仍可能有一次收尾保存、迟到的命令 diff 更新、后续后台轮次/报告触发的新保存；写失败则按 2/5/15/60 秒重试，属于明确的条件分支，尚无现场失败证据。

**提交与置信度。** 全历史快照机制在 `b64a00ddc`（2026-10-08，上游整合）已出现；`8312cb913` 加共享访问保护，`b6b89ba92`（0.1.4）移除该保护，保留快照主体。`93f0d3394` 和当前 Dev 均有此路径。机制置信度高；解释现场迟钝的置信度中低；没有证据把它定为 1.3.8 新引入回归。保存节流注释仍称“重写整个 thread file”，不能据此否认实际已有的 dirty-turn 拆分。

**最小修复位置与行为边界。** 在 `snapshotForSave` 及条目插入/删除维护处增量维护位置和按 turn 的条目索引，使快照只收集未完成/脏轮次；主线程仍先冻结一致的值快照，再交给写入端。必须保留稳定排序、旧格式迁移、编辑/撤回、完成轮次修订、失败重试和结束必保存语义。不要把活的 Observable 条目直接送到后台读取。

**缺失证据。** 现场每会话 E/T、快照耗时和分配峰值、保存回调密度、是否写失败、主线程采样；DiskWriter 实现不在本次范围，因此不将磁盘编码或写入本身归因到主线程。若现场所有会话完全静默且已保存后仍长期迟钝，该路径单独解释不了。

## 2. 正式版已有：新记录追加仍扫描旧历史，视图窗口不能限制这部分成本

**调用链。** `handle → queueDelta(新 id)/upsertTool → append → entries.append → entries.didSet`：构造 old/new 全部 ID 集合，分别遍历 old/new 条目，给新增条目装 dirty 回调。`runtime.entries` 变化使 `ThreadTimeline.body → TimelineBlockCache.blocks` 重新构造全量身份数组、统计 turnEnd、比较缓存键；追加快路径随后只重建最后 run，但前面的全历史扫描已经发生。位置：`ThreadRuntime.swift:242–258、3578–3584`；`ThreadTimeline.swift:117–143、3292–3336`。

**触发与增长。** 需要新增/删除/重排记录，单纯向已有消息追加文字不会触发数组 didSet。对历史 E 的会话，单次新增至少有 O(E) 集合、数组和比较成本；同一长会话不断追加记录时，累计这部分可达到 O(E²)。多个运行会话的新增记录工作都在主线程串行执行。mounted window 限制实际挂载的视图数量，不裁剪 runtime.entries 或缓存键。设置中的 `showReasoning` 变化也会让该缓存失效并重建全部块；不能由此推断任意设置操作都有同样成本。

**保留与停止。** `finalizeTurn` 保留旧历史，下一轮继续追加时仍扫描它，因而能解释“运行越久、后续操作越重”的一种条件性路径。`TimelineBlockCache` 最多保留 24 个线程缓存，presentation store 最多 32 个；这是有界保留，不能称作无限缓存泄漏。`holdsOnlyPersistedState` 还要求 `session == nil`，完成一个 turn 并不等于可以回收 runtime；但实际 runtime 回收决策在范围外，不能据此断言它永不回收。静默、无新增且无外部观察失效时，这些扫描不会自发继续。

**提交与置信度。** `entries.didSet` 的全量差集在 `b64a00ddc` 已存在；块缓存早在 `ba249c87e` 已有。`4d4508c89`（dev-1.0.15）增加时间线窗口，同时把短流 flush 间隔从 45ms 降为 16ms（中/长流 90→45、150→90ms）；该节奏提高已有条目的更新压力，不能误称每个 flush 都触发数组追加。滚动时最低 160ms，Hydra head 还有 `StreamLoad` 团队预算，普通会话未走该团队预算。`c3785c113`（dev-1.2.7）已加隐藏列 repair/refresh 与计时器门控；`95564b207`（dev-1.3.3）收紧自动跟随并关闭折叠高度动画。这些保护在正式版基准都已存在。机制置信度高；现场归因中低，没有证据证明这些旧路径最近才退化。

**最小修复位置与行为边界。** 在 `append/remove/install/revert` 明确维护新增/删除条目的 dirty 回调，避免每次数组变动全量求差集；在 `TimelineBlockCache.blocks` 用结构版本/增量身份尾部维护替代每次重建全量键。必须覆盖 prepend、sort、撤回、同 ID 替换、turnEnd 折叠、reasoning 设置切换，并保留所有当前视觉和历史访问。流式节奏可另做共享预算评估，但本报告不建议直接降低刷新率或关闭功能。

**缺失证据。** 现场每秒新增行数、历史长度、数组差集与块构建的主线程采样占比、实际挂载列数及 runtime 回收情况。没有这些数据，无法证明其成本足以造成输入和设置明显迟钝。

## 3. 仅 Dev 的已定位回归：图片判断曾将每个工具输出接到整条时间线

**调用链。** `589738835` 的 `ThreadTimeline.body → TimelineBlockCache.blocks → entries.filter(TimelineGroup.hasImages)`；`hasImages` 读取每个 tool 的 `entry.item.content`。工具输出经 `handle → queueDelta/flushDeltas` 或 `applyToolUpdate` 写 `item`，于是观察依赖会使整条 timeline body 再求值。`TurnGroupCache.groups` 和 `TurnFinishedBlock.body` 的图片键也引入同样的读取。无需真的返回图片即可触发，只要有工具条目且其 item 更新。

**触发与增长。** 工具输出每次可见 flush/更新都会导致整体 body 路径重跑，至少重建 O(E) 身份键和图片筛选，即使结果缓存命中；挂载的多个会话会累加。发生 key 变化时才进一步重建分组，不能说每次工具输出都全量重建全部块。停止输出后该触发源停止；完成条目仅被保留不会自己发通知，迟到工具更新仍可能触发。

**提交与置信度。** `93f0d3394` 的 `ToolCall` 没有 `images` 字段，块缓存键没有图片筛选，因此此链不适用于其正式版。`589738835` 为 dev-1.3.10；`4fc87d1ee` 为 dev-1.3.11，在 `TimelineEntry` 增加独立 `hasImages`，并把 `TimelineGroup.hasImages` 改为读取该标志。当前 `TimelineRows.swift` 的图片 DerivedKey 调用同一 helper，已经受此修复覆盖。代码依赖变化置信度高；未经运行测量；现场版本关联仍取决于实际打包来源。

**最小修复位置与行为边界。** 此项最小修复已在 `4fc87d1ee`：保留图片展示、分组和折叠外图片结果，只让图片存在状态变化触发分组观察。标志确切语义是“是否有图”，也可能在图片被移除时翻转；不是严格永远只变一次。主负责人无需用回退图片功能修复正式版问题。

**缺失证据。** 现场二进制提交来源，以及修复前后 body 求值次数/工具输出压力对比。不能将提交说明当作性能验收结果。

## 既往上下文与边界

已按 search-memory 技能使用 Nowledge CLI 做一次定向 thread 搜索：`Tivano 多会话 性能 滚动`，scope 为当前 default，limit 5；返回包含“性能审查与极致性能模式规划”等历史线程。本报告没有读取或援引历史线程正文，全部代码判断来自本次限定源码与 Git 历史。未调查 RootView、WindowChrome、动画组件、打包脚本或外部服务实现；没有运行任何验证命令，也没有创建性能数据。下一步取证与是否修复由主负责人决定。
