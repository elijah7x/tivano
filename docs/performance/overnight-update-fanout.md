# 后台会话更新向前台扩散：静态调用链调查

## 结论与边界

**没有足够证据认定此范围内存在高置信的持续卡顿根因。** 找到一条源码可闭合、值得由主负责人计数的候选：后台线程元数据或待处理请求改变后，Sidebar 在缓存命中前仍执行随库大小增长的工作。其调用链成立，但现场触发频率、累计主线程耗时均未知，不能仅凭观察整个数组判定明显卡顿。

此次仅阅读源码并写本文；未修改产品代码，未构建、测试、运行检查、采样、操作应用或生产数据。未重新调查保存快照、entries 全历史差集；不对 WindowServer、标题栏循环作结论。下面的频率是源码中的事件对应关系，不是实测每秒次数。

## 更新入口与去重

源码路径均相对仓库根目录，行号对应此次工作副本。

- `Tivano/App/AppModel.swift:33–55`：`threadStorage` 不被观察；读取 `threads` 会读取 `threadsRevision`。结构同步重建 ThreadIndex，按值同步 thread cells 和 child cells，最后递增 revision。
- `AppModel.swift:831–848`：`updateThread` 用位置索引取单条记录，执行闭包后先比较 `thread != previous`。相同值不写 cell、不增 revision、不调度保存；退出时仍 drain 权限降级通知，但空队列立即返回（899–912），没有全库扫描。
- 非结构更新只写目标 thread cell，**仍递增全局 threadsRevision**。`structureChanged`（850–863）包含 updatedAt、活动顺序、折叠、归属等；这些变化才走结构同步。这里没有无条件复制整个数组的语句；Swift 值语义的实际 CoW 成本不能由这一段单独确定。
- `updateThreads`（882–894）先取得数组值，逐 ID 修改；至少一条不同才整批赋回并同步。调用点为排序操作（417、435），不是 Provider 的流式事件入口。不能把它列为三会话持续输出时的高频路径。
- runtime 字典、访问时间、容量调度均 `@ObservationIgnored`（110–113）；`runtime(for:)` 命中只更新访问时间并返回（503–517）。首次创建才安排闲置容量回收；超过 12 个才排序候选（520–529），活跃 runtime 的释放另有保护。创建或访问字典本身不发布一个“全 runtime 集合改变”通知。runtime 各自的可观察字段仍可被视图直接订阅。

### ThreadRuntime 高频事件实际写了什么

`Tivano/App/Runtime/ThreadRuntime.swift:2593–2601` 将当前 session 的 onEvent 交给 `handle`；epoch 拦住旧 session 的事件。

| 事件 | 写入／调用 | 调用 updateThread 的频率 |
| --- | --- | --- |
| messageDelta、reasoningDelta、planDelta、toolOutput | `handle:2748–2769` → queueDelta（3618 起）→ flushDeltas（3735–3761），修改 TimelineEntry、saveRevision、head 活动计数 | 这条增量路径不调用 |
| toolStarted、toolUpdated | upsertTool（3816 起）、applyToolUpdate（3858 起），修改 entry、文件树相关 revision、head 计数 | 这条工具更新路径不调用 |
| usage、contextUsageCleared、tokenSpend | usage/saveRevision；tokenSpend → recordTokenSpend（2877–2892）改 turn 的支出及 head token 计数；usage 还会使 provider 余额缓存失效 | 这几条分支不调用；provider 缓存失效的下游不在本文候选内 |
| modeChanged | interactionMode（2802） | 每个事件调用一次；相同 mode 被 AppModel 值比较拦住 |
| title | title（2808–2813）；仅首轮、非自定义标题且没有本地标题引擎时作为回退 | 满足条件的每个事件一次；相同清理后标题被拦住 |
| sessionReady | recordSessionID（1998–2005）；已有 session ID 才立即写 providerSessionID，否则暂存 | 每个事件至多一次；相同 ID 被拦住 |
| approval、question、requestResolved | approvals/questions 数组增删（2771–2784），attention 通知 | 这些分支不调用；可直接影响 Sidebar 的 runtime 观察 |
| turnStarted | phase = running、更新 turn、saveNow（2729–2741） | 普通已有轮次不直接调用；没有当前轮次时 openBackgroundTurn → rehearseTurn（4552）写线程 |

`startTurn:1409–1416` 与 `rehearseTurn:4552` 写 updatedAt、lastStatus、pendingResultTurnID、hasUnread、unreadRevision，频率跟随**轮次开始**。`finalizeTurn:3005` 在存在恢复锚点时写 providerResumeAt；结束会经 `AppModel.turnFinished:1269–1296` 写 updatedAt、结果/未读字段，且有 lastAttentionTurnID 去重。`appendHydraNote:3562–3566`、`recordVoiceTranscript:4508–4524` 写 updatedAt；标题生成（4265–4279）写初始和异步生成标题。这些不是每个 token 的写入。

因此不能以 flush 的 16/45/90 ms 节奏推导全局 threadsRevision 也以该节奏变化。head 的 `noteHydraHeadEvent:3841–3846` 改的是 runtime 自身的时间/计数，不是 ChatThread。

## 唯一保留候选：Sidebar 缓存前的全库派生工作

**置信度：调用链高；构成现场主要瓶颈低，待计数。**

### 触发、字段和界面

1. 后台 mode/title/session 元数据实际变化，或轮次开始/结束的 updatedAt、未读等字段变化 → `AppModel.updateThread` → threadsRevision 增加 → Sidebar 读取 `model.threads` 的部分失效。
2. 活动布局开启时还有一条不经过 updateThread 的入口：`handle` 的 approval/question/requestResolved 改 approvals/questions → `SidebarView.needsAttention:708–711` → `listItems:545–566` 的 attention 集合。活动布局为每个有 runtime 的线程读取待处理数组；重复同 ID 的 approval/question 会先 remove 再 append，数组有修改，即使“是否需要 attention”这个布尔结果没变。是否被框架合并到一次求值，需要计数，不能按两个数组操作当两次渲染。
3. Sidebar body（73–78）先算 threadPlacements 和 helpers；可见侧栏受影响。全窗口设置时，RootView（19–37）只给 Sidebar opacity/交互/无障碍限制，仍保留该树，故这些派生计算没有由设置覆盖直接切断。它们可能占用设置滚动或会话切换所需的主线程时间；这不等于 SettingsDetail 自身被后台状态重建。

### 缓存命中前仍做的工作

- `threadPlacements:505–507` → `PlacementCache.placements:2303–2308`：先对全部 N 条线程分配并填充 Fingerprint 数组，再做数组相等比较，随后才可能返回缓存。至少 O(N)；标题、mode、session ID 改变时 placement 不变，也要付这一步。
- `helpersByParent` 的缓存比较（2398–2402）及 `SidebarItemCache.Key` 比较（2390–2394）仍需比较 placement 数组。命中并不等于整个调用为 O(1)。若 updatedAt/hasUnread 真变，Fingerprint 和 ThreadPlacement 都包含它们（2263–2351），会使 grouping/list 缓存失效；helpers 分组重扫 N，项目/活动列表的排序成本随项目线程或活动线程数增加。
- 活动布局还在 `items(for:)` 命中判断**之前**，用 `model.threads.filter { needsAttention($0) }.map` 构造 attention 集合（556）。这是 O(N) 的 runtime 查找与请求数组依赖收集；自动隐藏闲置 head 开启时还在判断前遍历 helper 组找运行 head（548–550）。
- 搜索 popover 是另一个条件分支，本文不将其扩大为第二候选；普通主侧栏 query 为空时不应计入搜索成本。

现有 per-thread cells 保护单条聊天和行，但不保护读 threadsRevision 的列表容器。PlacementCache 保护“重建 placement”，ItemCache 保护“重建列表”，两者都不保护生成/比较 key 的扫描。相同 ChatThread 写入去重已经覆盖 mode/title/session 重复赋值，不能声称这些重复事件仍发布 revision；待处理数组与其派生的 attention 布尔并没有同一层的语义去重。

### 保留视觉和功能的最小改法（仅建议）

若计数证明值得修，优先把 placement 的失效依据放在模型维护的独立版本/投影上：只在实际参与 placement 的字段改变时推进，Sidebar 以此作为缓存入口，避免每次元数据变化先重建 N 个 fingerprint。必须包含 hasUnread 及现有排序/归属字段，不能直接用当前 structureChanged 代替（它不含 hasUnread）。行继续从各自 cell 取实时内容。

活动布局的 attention 用“成员是否变化”的投影/版本驱动；更新现有数组内容但空/非空不变时，无需重新扫描所有线程。最小范围可先把 attention 派生隔离成独立观察单元，确认收益后再维护增量集合。请求内容、排序、提示、head 显隐规则和设置覆盖下的状态更新全部保留，不以降低外观、流式速度或功能换取收益。

**停止条件：** 若冻结其他交互的纯流式阶段没有 Sidebar 派生调用增长，或这些调用累计成本很小且不随 N 明显增长，即停止把此候选当作持续卡顿解释；只有轮次边界出现一次扫描不足以解释整段重任务的卡顿。若 attention 入口只在人工审批时出现，也不能解释无人干预的持续卡顿。

## 已审查但未保留为第二候选

`RootView` 本体没有读取 threads 全集；其选中线程判定通过单条 cell（96–97）。不能从 AppModel 是 @Observable 推断任意线程写入都会重建整个窗口。

`DetailView:187–190` 确实对 `model.threads` 全库做 compactMap，并读取各已有 runtime 的 isRunning（ThreadRuntime:875 → phase），构造 running Set。后台元数据 revision 和任意被读 runtime 的 phase 改变都可能使其重新派生，设置覆盖也不切断这个读取。成本 O(N)，但它不读 entries、usage、head 活动时间或 token 计数；phase 写入主要在开始/结束，`.turnStarted` 确有重复赋 running 的可能，源码未证明事件高频。

随后 `ThreadColumns.updateNSView:247–253` 调 cover/show/dropHidden/prebuild。show 同 ID 立即返回（335）；cover 只有覆盖状态变化才改 rootView，已隐藏/已安排隐藏时返回（300–332）；dropHidden 遍历受 keptLimit=8 约束的列，prebuild 有 requested 去重。不能把正常布局或已有 guard 的调用称作循环，也没有证据证明每次 running Set 重算都会重建聊天列。此路径仅留一个对照计数点，不升格为卡顿候选。

`SettingsDetail`（`Tivano/App/Views/Settings/SettingsView.swift:309–339`）仅 archive 分支在入口读取 archivedThreads；`AppModel:456–458` 每次过滤再按 updatedAt 排序，是 archive 页特定依赖。其他设置页入口无线程集合读取，本文未追进无关设置子页，不能宣称所有设置页都被后台线程通知重算。设置覆盖聊天列后还会在 450 ms 后隐藏 pane、停用其 veil scope（RootView:322–332）；未把覆盖期间的渲染成本等同于可见聊天。

## 给主负责人的窄计数方案（未执行）

由主负责人在其授权环境临时添加固定大小聚合计数器；每阶段结束只输出汇总，不逐 token 打日志、不记录消息正文。不开性能模式，不改变外观/功能；相同 provider 工作量分别观察“纯流式无交互”“滚侧栏”“全窗口普通设置页滚动”三个阶段，archive 另算。

1. **源头**：按前台/后台 ID 和事件类别计 handle 次数；updateThread 记录调用数、值相等返回数、结构/非结构发布数及实际变化的字段位集。phase 另记写入数与 old==new 数。用它区分“输出很多但根本没发布线程变化”与“元数据/轮次边界密集”。
2. **候选终点**：分别计 placements 的调用、fingerprint 输入条数/耗时、命中/失配；attention 扫描次数、输入条数/耗时；items/helpers 的命中/重建。按 settingsShown 聚合。仅调用计数不能证明卡顿，须看这些派生函数的累计主线程耗时。
3. **对照终点**：DetailView running 收集次数/耗时、ThreadColumns.updateNSView 次数、实际 make/drop/rootView 替换次数。若 running 扫描增加而实际列操作不增，可将“列重建”排除，单独判断 O(N) 扫描是否有成本。
4. **判别**：delta 很多而 updateThread 发布和 Sidebar/Detail 派生几乎不增，停止此方向；Sidebar 派生主要跟 attention 或元数据发布走、缓存多命中但 key 生成占明显时间，支持唯一候选；仅 Detail running 频繁且列操作仍少，则候选需改为运行集合投影，不能沿用 Sidebar 归因。

若无法使用真实任务，另由负责人提取 Fingerprint/attention 构造的纯函数，以合成 ChatThread 元数据和请求空/非空标志跑 N=100/1,000/10,000 的等频元数据脉冲；分开“placement 不变的标题变化”和“updatedAt 变化”，测缓存前工作与重建工作。该基准只验证增长率和单次成本，不证明 SwiftUI 的实际失效频率，也不需要生产会话历史。

背景检索：按要求做过一次 Nowledge 线程检索（CLI，query=`Tivano updateThread 后台 卡顿`，limit=5），返回 0 条；本文结论仅依据当前副本源码。
