# Tivano 性能手册

这是一本查阅手册，不是操作规程。它汇总了 2026-09 到 2026-11 之间四十多次性能修复、实验和审计：哪些方向做过，哪些有效，哪些撤回，哪些地方反复打补丁，哪些方向还没碰过。它的用途是在十几万行代码里先缩小范围，而不是替代现场测量。

本目录其余文件是单次调查的原始记录，数字和方法以那些文件为准；本文只做索引和归纳。

## 0. 怎么用

| 你遇到的情况 | 先看 |
| --- | --- |
| 又加了一批功能，想做一轮性能 | §2 热区地图 → §6 例行检查清单 → 实测后再选 §3 的手法 |
| 回归踩过的坑：有没有再犯、哪些修法不优雅 | §5 补丁叠补丁的区域 → §4 撤回与不如不修 → §6 |
| 想找没做过的新方向 | §7 欠账与空白 |
| 要测量或证明效果 | §1 测量教训 → §8 工具箱 |
| 查某次历史修复的来龙去脉 | §9 案例索引 |

使用时的几条约束：

- **历史方向只是候选，不是结论。** 每一轮都先在现场测到热点，再回来看历史上是否有同类机制。症状相同不代表根因相同，同一个手法在一个症状上无效，换个症状可能有效（见 §4 “移出窗口”的两次结果）。
- **代码在变。** 3.0 瘦身删了大量代码和探针，引用的符号、行号和探针可能已不存在；动手前先确认机制还在。
- **数字是当时那台机器、那个负载下的观测，不是阈值。** 不要把本文数字写成检查门槛，除非 owner 另行批准。
- **不为性能牺牲外观、交互语义或数据安全。** 历史上几次 no-go 都是因为这个（§4）。

## 1. 先记住的测量教训

这些是历史上代价最高的错误，每一条都导致过结论撤回或白做。

1. **先确认指标口径。** Instruments 的 `hitches-renders` / `hitches-gpu` 统计全屏合成帧，不分进程，空闲的计算器也报 61 帧/秒；只有 `hitches-updates` 按进程统计。2026-10-24 的“空闲 60fps 重绘”就是这样误读后撤回的。主线程心跳间隔是排队延迟，不是 FPS；组件微基准的百分比不是整机收益；进程 CPU 不包含 WindowServer/GPU 合成。
2. **同一二进制交替 A/B/A，噪声内就写噪声内。** 用 `-O` 构建，改前改后交替至少两轮。10-24 的滚动预加载被静态审计评为“高影响”，A/B 后落在噪声内；10-28 侧栏搁置 A/B 也在噪声内；#51（链接长段落反复测量）的修复有 `sample` 依据，但 A/B 没复现原问题，效果至今未证实。
3. **确认两边负载真的一样。** 11-15 perf-squeeze 的 `scroll_and_load_earlier` 场景，前后两版滚到的文档范围不同（docStart 2989 vs 5857），这一项的前后对比不可直接比较。探针要核对动作确实发生（10-16 渲染探针直写 `NSClipView` 被底部跟随覆盖，161/220 次回调错位，整轮作废），也要核对最终文本和增量条数。
4. **`sample` 里全是 SwiftUI 布局，不代表根因是 SwiftUI。** 2.2.6 主线程 98% 的采样里 Tivano 自己的代码只有 4 个样本，真因是 follow-up 入队后立即出队、再放回的死循环在不停改被观察状态。看到布局占满时，先找是谁在改状态。
5. **环境干扰会让整轮数据作废。** 已知的有：锁屏（`CGSSessionScreenIsLocked`）、Stage Manager 把窗口挪走导致点击落到 Release、测量期间有 `xcodebuild` 在跑、App Nap、`sample` 自身扰动计时。Instruments `--launch` 下部分探针参数不生效，要直接启动后 `--attach`。
6. **静态审计会高估，也会错判。** 10-11 大审计经复核撤回了多条缺陷判断；10-18 的“后台 delta 扇出到侧栏”假说查下来不成立（高频 delta 不触发 `threadsRevision`）。审计结论要么实测，要么标明未验证。
7. **整机性能开关不能当实验变量。** 旧 Performance Mode 一次改动背景、玻璃和多处动画，还会持久改写 `clearerBackdrop`，用它做 A/B 无法归因。

## 2. 热区地图

“投入”是历史上相关修复的大致轮数（CHANGELOG 与提交合计），反映的是哪里反复出事，不代表现在一定还有问题。

| 区域 | 投入 | 主要文件 | 反复出问题的机制 | 现有守护 | 状态 |
| --- | --- | --- | --- | --- | --- |
| 时间线滚动与跟随 | 极高（约 20 轮） | `App/Views/Chat/ThreadTimeline.swift`（约 21 个性能提交） | 从 SwiftUI 几何回调推断读者意图；re-pin 阈值反复调整 | `timeline_performance_checks`，`--timeline-stress`，`--held-drag` | 近期刚调过，动之前先读守护检查 |
| 历史上翻加载 | 高（11-11 至 11-16 四个提交） | `ThreadTimeline.swift`（`loadEarlier`、`HistoryAnchorMath`、`ScrollViewProbe`） | 新页增高与滚动补偿不在同一拍 | `timeline_performance_checks`，`--history-scroll`，`--history-flick` | 已收敛到同拍同步补位 |
| 流式渲染（Markdown、淡入、选择） | 高（约 10 轮） | `UI/Markdown/MarkdownView.swift`、`StreamVeil.swift`、`LinkParagraphView.swift`、`ProseRunView.swift` | 每个 token 对整段做全量工作 | `ui_audit_checks`，`markdown_typography_checks`，`selection_redraw_checks` | 主要热点已修；新增渲染路径要重新检查 |
| 切会话与冷打开 | 中高 | `RootView.swift`、`ThreadTimeline.swift`（`TimelineWindow`）、`AppModel.swift` | 首帧构建块数、焦点链遍历、整段重建 | `first_send_checks`；`SwitchLatency` 打点（Dev 与 Preview） | 没有自动化延迟回归检查 |
| 隐藏/遮盖列与后台空转 | 高（打地鼠式） | `RootView.swift`、`ChatView.swift`、各动画视图、`RenderBudget.swift` | 每个新动画或轮询功能都带来一份空转成本 | `weather_window_checks`（仅 Weather） | 新功能最容易在这里回归（§6） |
| 设置页 | 中高 | `App/Views/Settings/*` | 大页面整体构建、窗口级动画、长列表 | 无（`SettingsInteractionProbe` 已退役） | 页面构建 30–130 ms 未解决 |
| 侧栏 | 中 | `App/Views/Sidebar/SidebarView.swift` | 悬停与未读重建整列表、O(N) 扫描 | 无 | 数百会话规模从未测过 |
| 主题、玻璃、Creation | 中 | `UI/Chrome/Chrome.swift`、`ChromeMaterial.swift`、`AppTheme.swift`、`AppIconManager.swift` | 切换主题时视图身份改变；全局通知 × 保留的列 | `weather_window_checks`（部分） | 玻璃的 GPU 成本只测过一次 |
| 存储与持久化 | 中高 | `Services/Store/Storage.swift`、`ThreadRuntime.swift`（`snapshotForSave`）、`TokenLedger.swift` | 主线程同步写、整库编码、O(N) 扫描 | `data_safety_audit_checks`（slow），`runtime_storage_checks`（slow） | 有欠账（§7） |
| Provider 子进程与网络 | 中 | `Services/Providers/*`、`Services/MCP/*` | 每条消息拉起 CLI、无界缓冲、取消后不清理 | `codex_one_shot_checks`，`runtime_audit_checks` | 新接入的 Provider 需要逐个检查 |
| Hydra 运行时 | 高 | `AppModel+Hydra*.swift`、`HydraProgressBar.swift`、`ThreadRuntime.swift` | 队列死循环、逐帧工作、主线程保存 | `hydra_idle_checks` | 新的 Hydra 机制容易引入新循环 |
| Watchdog 与诊断 | 中 | `Core/Support/HangWatchdog.swift` | 诊断自身的开销被算成卡顿 | `runtime_storage_checks` | 稳定 |
| 输入框 | 中低 | `App/Views/Composer/*` | 每次按键重建列表、同步读盘 | `ui_audit_checks`（FileIndex 合并） | 按键延迟从未测过 |
| 启动 | 极低（1 次） | `TivanoApp.swift`、`AppModel.bootstrap` | — | 无 | 空白 |
| 内存增长 | 低 | `Core/Support/MemoryPressure.swift`、`RecentCache.swift` | 缓存无上限、闲置运行时不释放 | 无 | 空白 |

## 3. 行之有效的手法

按手法分类。每类给出适用信号、代表案例和已知的坑。

### A. 收窄观察和失效范围

**信号：** 某个高频字段一变，大范围视图跟着重算。
**案例：**
- `TimelineEntry.hasImages` 独立成标志位，`ThreadTimeline.body` 不再因每次工具输出 flush 重算（`4fc87d1ee`）。
- `controlThreadMembershipRevision` 从 `threadsRevision` 拆出（`2448c7ab4`）；`sidebarPlacementRevision`、未读状态从侧栏列表重建中隔离（`a715d85d8`、`1f7c17492`）。
- `ProviderRegistry` 丢弃无变化的通知并批量更新；悬停只重画背景（10-18 夜间专项）。
- `.equatable()` 边界：`ThreadTimeline`、`ProseRunView`、`SidebarThreadRow`。

**坑：** 收窄后要确认真正需要的更新还能到达（10-21 审计修过 Today 视图来回切换后的重建）。

### B. 看不见就停

**信号：** 被遮盖、隐藏或在后台的界面仍在占 CPU。
**案例：**
- 隐藏的聊天列停掉淡入时钟、计时器、空白修复循环、闪光动画（1.2.7、1.3.0、1.4.0、2.0.0 多轮）。
- 滚轮监视器先检查 `isHiddenOrHasHiddenAncestor`：1 个可见列加 8 个隐藏列时，每个滚轮事件的命中测试从 9 次降到 1 次。
- 后台流式会话的 flush 节流到 1 Hz，打开时追平（2.5.12，`offscreenFlushMilliseconds`）。
- Weather 窗口空闲时整个卸载，模糊从 12 次降到 4 次（`fd81168b5`）。
- Hydra 进度条：逐帧遍历 → 缓存 → 停止逐帧工作 → 改用 Core Animation 图层 → 隐藏时释放 CA 槽位，最终主线程几乎零成本。

**坑：** `isHidden` 不等于被别的窗口遮挡，也不覆盖设为隐藏之前那 0–450 ms 的过渡。把视图移出窗口并不能阻止 SwiftUI 继续计算（§4）。现成的工具有 `RenderBudget` / `ScrollActivity`、`FrontMonitor.isVisible`、`ChatColumnVisibility`（环境里每列一个不变的对象，只读 `isShown` 的视图随显隐重算；不要改回翻转环境值，那会让整列失效）。

### C. 增量代替全量

**信号：** 每次追加都扫描全部历史，代价随会话长度增长。
**案例（数字为组件基准，不是整机收益）：**
- `ThreadRuntime.entries.didSet` 全量比对改为显式 `bindEntry` / `removeEntries`：2 万行时每次追加 61.5 ms → 0.002 ms。
- `snapshotForSave` 缓存位置：2 万行时 27 ms → 5.4 ms。
- `StreamVeil` 只重新切分最后一个字素和新增尾部：CPU 降 72–79%。
- `LinkParagraphView` 前缀与属性都不变时只追加后缀：同一二进制 A/B/A，进程 CPU 降约 20%，选择不丢。
- `DiskWriter` 每次保存只列一次目录：1 万轮时 157 ms → 39 ms。
- `TimelineMeasurements` 用增量均值、前缀和加二分查找替代 O(N) 高度遍历。

**坑：** 增量路径必须有退回全量的严格条件。字体回退（尤其 emoji）会让属性前缀不匹配，此时必须退回全量，不能为跑分放宽。改算法前，先在独立的 `-O` 测试里证明新旧等价（历史上做过 17 万次 Unicode 状态比对、2038 例 TextKit 比对、250 次保存快照比对）。

### D. 缓存和预编译

**信号：** 同样的输入被反复解析、编译或测量。
**案例：**
- 正则字面量放进 `static let`：`hasSentDelegationBlock` 每次约省 13 ms，因为正则字面量每次调用都会重新解析。
- 用 `memmem` 做字节查找：MentionScanner 正文构建 52 ms → 2.5 ms。
- `LinkTextView` 按 4 个宽度缓存高度，文本不变时命中直接返回不碰容器（#51；3.0.19-dev 改由显示栈测有限宽、每视图 `TextHeightMeasurer` 测无限宽）。
- 模型选择器保留裁剪后的列表；`PreparedProseRun`；Dock 图标渲染缓存；Markdown `blockCache` 复用流式解析结果，结束时不再重新解析。

**坑：** 失效条件比命中率重要。工具图片路径缓存改成 2 秒 TTL 加负缓存后反而更慢，还把新生成的图片藏了起来，已撤回。缓存命中时不能有副作用：11-14 一版缓存在命中时改了文本容器宽度，排好的布局因此丢失，lead 当场改掉。缓存要有上限，并接入 `MemoryPressure`。另外，TextKit 复用显示栈时有两处隐蔽开销：`NSTextContainer` 开启 `widthTracksTextView = true` 会让 AppKit 在每次改宽时同步排完整段文字（屏外视图也一样，微基准 340 次改宽 2634 ms，改为在 `setFrameSize` 手动设容器宽仅 0.8 ms）；在显示栈测量时改容器宽会触发 `NSTextView` 以相同尺寸回调 `setFrameSize`，若此处无条件把容器拉回 `bounds.width` 会撤销测量并引发排队重排暴涨（20430 次核对 1021 次不一致、累计 343 s），只在真实宽度变化时对齐即可（`text-display-structure.md`）。核对或自愈里不要对文字变化和外框变化整段 `needsDisplay`：流式回复每块都会长高，整段重画让每块多约 0.34 ms（11-24）。

### E. 移出主线程

**信号：** 主线程上有同步 I/O、编码或解码，或者 Keychain、签名校验这类可能阻塞的调用。
**案例：**
- Token 用量后台写盘，消除约 2 秒一次、随历史变长的周期卡顿（2.2.12）。
- 每个 Hydra head 的首次整库保存改为后台（`997b2a0ac`）。
- 大图缩略与编码移出主线程：主线程阻塞 103 ms → 0.02 ms，载荷 57 MB → 7 MB。
- Keychain 读取 `offMain`，带 5 秒超时；`claude auth status` 缓存 5 分钟；更新签名校验、favicon 处理、`DiffParser` 都已后台化。

**坑：** `@MainActor` 里的非结构化 `Task {}` 会继承主线程。移出主线程可能让总耗时变长（大图案例总时间 103 → 197 ms），只能说主线程不再卡，不能说“更快”。保存顺序与失败回滚要保住（首条消息先显示，保存失败时回滚）。

### F. 合并与节流

**案例：** 流式 `flushDelay` 16/45/90 ms；`StreamLoad` 按并发 head 数调整节奏；整库保存至少间隔 4 秒；`ThemeManager.didChange` 每次切换只发一次；perf-squeeze 后 Hydra 10 head 的面板 flush 间隔中位数 290 → 80 ms。

### G. 窗口化挂载

**案例：** 按身份标识的 `MountedWindow` 加高度占位；`TimelineWindow.initial` 从 24 改为 12（冷打开时第二次约 200 ms 的卡顿基本消失）；`firstPaint = 3`，先画一屏；12 轮分页。

**坑：** 时间线目前用 eager `VStack` 配合自己的窗口化挂载。当时（1.7.0）`LazyVStack` 在某行处于窗口边缘时把整个应用冻住，所以才改成 eager；后来的 1 pt 推挤问题也是旧的 lazy 栈留下的补丁（`timeline-jitter.md`）。如果以后要换别的布局（新的 SwiftUI lazy 容器、AppKit 列表等），可以试，但要用 `--timeline-stress` 和历史上翻探针重新验证三件事：窗口边缘不冻结、没有重排或空白帧、滚动跟随和历史补位行为不变。“分批装载”在 eager 栈上会造成重排，CPU 反而上升，当时已放弃。

### H. 直接删掉工作

**案例：** 跨版本共享库轮询（加上一天后删除）、Token 热力图、Jev 影子测试、`URLCache` 磁盘缓存（75 分钟写入超过 2 GB）、Codex 一次性调用下载插件目录（每次 34–65 MB → 0.72 MB）、会让时间线空白的折叠动画、整窗动画。

**判断：** 删功能的收益通常最确定。先问这项工作是否必要，再问怎么让它变快。

### I. 补偿放进同一拍，必要时下沉到 AppKit

**信号：** SwiftUI 的几何回调晚一拍，补偿总是慢一帧，在补偿上继续叠补偿。
**案例：** 历史加载由 `HistoryAnchorMath.syncShift` 在 documentView 增高的同一次布局中同步补位，滚轮累计量和 clip 基线一起重置；读者意图改由 `ScrollViewProbe` 的滚轮事件和手势阶段判断，不再从几何变化去猜。

## 4. 没用的、撤回的、修了不如不修的

| 尝试 | 结果 | 原因 | 来源 |
| --- | --- | --- | --- |
| SwiftUI `TextRenderer` 绘制透明度做淡入 | CPU 反而 +12.5%，已删 | 绘制路径比重建文本更贵 | `incremental-veil-state.md` |
| 无链接的纯文本改走原生 `LinkParagraphView` | CPU −47%，但 no-go | 48 个排版用例里只有 8 个一致：粗斜体、删除线、emoji 高度都不对 | `native-text-layout-investigation.md` |
| 设置页遮盖时把聊天列移出窗口（10-18） | CPU 1.94 s vs 1.94 s，已撤回 | 视图移出窗口后 SwiftUI 仍在计算 | `overnight-2026-10-18.md` |
| ↳ 同一手法用于切换主题（11-16） | 有效：502 → 123 ms | 症状不同：主题通知让 9 个保留列同步失效 | `8e4a6e86c` |
| 工具图片路径缓存加 TTL 和负缓存 | 更慢，新图片看不到，已撤回 | 原来永久正向缓存的失效条件是对的 | `overnight-2026-10-18.md` |
| 设置页常驻不销毁 | no-go | 约 30 处生命周期依赖、60 处改动，收益只有约 60 ms | 10-24 记录 |
| 时间线分批装载 | 放弃 | eager 栈重排，CPU 上升 | 10-24 记录 |
| 用不透明背景替代玻璃 | 滚动回调 p95 −13% 至 −24%，但 no-go | 改变外观 | `render-cost-probe-review.md` |
| Performance Mode 去掉所有阴影 | 当天恢复了窗口阴影和圆角 | 设置窗口和主窗口糊在一起 | CHANGELOG 1.7.1 → 1.7.3 |
| Performance Mode 关闭 Clearer glass | 后来修正 | 关掉后永久改写了用户设置 | CHANGELOG 1.2.6 → 2.0.0 |
| 跨版本共享库：每秒轮询加主线程三方合并 | 一天后整体删除 | 后来版本库分离，这套机制不再需要 | `8312cb913` → `172225aeb` |
| Claude/Codex CLI 每 12 小时后台静默更新 | 撤回，只读检查版本 | 后台开销和不可控的副作用 | CHANGELOG 1.1.0 |
| 滚动预加载被评为“高影响” | A/B 落在噪声内，评分已下调 | 静态判断高估 | 10-24 记录 |

**Performance Mode 已按 owner 决定移除（3.0）。** 老设置在启动时迁移为 Texture 主题；不要把它当作性能手段恢复，性能改动应作用于默认外观本身。旧键只剩 `AppSettings` 的迁移读取；侧栏放大和设置图标栏阴影的遗留读取已在 11-17 清除。

## 5. 补丁叠补丁的区域

回归时重点看这几处。共同的气味：**同一个症状第三次修，修法还是加阈值、加定时器、加兜底**。这时应该停下来，怀疑信号源或模型本身选错了。

1. **滚动跟随与 re-pin。** 两个产品阶段加起来修了 8 次以上，阈值来回改：48 → ≤1 → 8 → ≤1 pt（`6723c7182`、`95564b207`、`067c1a15b`、`504ae4a41`）。根子在于从 SwiftUI 的异步几何回调推断“读者是不是在滚”。转折点是改用 AppKit 的滚轮事件和手势阶段，加上按住触控板保持拖动状态。现状：向上任意位移立即停止跟随，只有距底部 1 pt 以内才重新贴底。由 `timeline_performance_checks` 守护。
2. **历史上翻加载。** 2.0.22 → 2.5.26（提前一屏预加载）→ 2.5.31（停止一路连锁加载到最早的消息）→ 3.0.0-preview.6（同拍补位）。11-11 的修复 5 分钟后又补了一次：读者一滚动就必须取消待执行的位置校正。现状是同步补位、滚轮累计量和 clip 基线一起重置、一次只加载一页，加上异步兜底。
3. **隐藏列：保留还是释放。** 为了切换快一直保留更多列，代价陆续出现：主题切换时 N 列同步失效（502 ms）、焦点链遍历隐藏列、内存占用。现状：列移出窗口、显示时追平，内存压力时释放。**今后任何全局变化（主题、字体、语言、设置）都要乘上保留列数来评估。**
4. **后台空转打地鼠。** 计时器、淡入、闪光、Skylight、Keepsakes、Weather、Hydra 进度条，几乎每个动画或轮询功能上线后都要补一轮“隐藏时暂停”。这不是修法本身有问题，而是新功能缺一道检查，见 §6 第 2 条。
5. **布局过程中重绘导致中止。** 先给单个视图加保护，崩溃挪到下面的滚动视图；最后泛化成 `DCDisplayCycleGuardedWindow`，捕获后推迟到下一轮执行。它能挡住崩溃，也可能掩盖布局循环。排查卡顿时要看它的 `os_log`（`dev.tivano.Tivano` / `window`）有没有风暴。
6. **Watchdog 干扰自己。** `/usr/bin/sample` 自身的开销被算进下一次卡顿，后来限制为每分钟最多一份报告并重置 CPU 基线。各类超时被反复收窄（Hydra 等待用户、agy 30 分钟），每加一种新的长任务，都要检查 watchdog 的豁免条件。
7. **Hydra 队列与自旋。** 1.7.2 快照自旋、2.2.6 放回队列死循环、2.2.12 泄漏的 0.1 秒检查。共同形态是“入队 → 立即同步出队 → 启动 → 条件不满足再入队”。新增队列或重试逻辑时，确认不满足条件时出队一侧会停下来等，而不是马上重试。

## 6. 例行检查清单

适合在“加了很多新功能，做一轮性能”时扫一遍，也适合时不时瞥一眼。每条都对应历史上真实出过的问题。grep 提示只用来缩小范围，不代表命中就是问题。

| # | 看什么 | 快速定位 | 历史例 |
| --- | --- | --- | --- |
| 1 | 视图 `body` 是否读了流式或高频字段 | 新视图里读 `entry.item.content`、`runtime.` 的流式字段 | `hasImages` 回归（`4fc87d1ee`） |
| 2 | 新动画、计时器、轮询在隐藏、遮盖、滚动、最小化时是否暂停 | `TimelineView(.animation`、`Timer`、`CADisplayLink`、`Task.sleep` 循环；看是否接了 `RenderBudget` / `FrontMonitor` / `ChatColumnVisibility` | §5 第 4 条 |
| 3 | 主线程同步 I/O、整库编码、同步保存 | `writeThreadSynchronously`、视图或 `@MainActor` 里的 `JSONEncoder`、`Data(contentsOf:)`、`FileManager` | Token 用量 2 秒卡顿；首条消息等保存 |
| 4 | 每次调用都重新编译的正则或重新解析 | 非 `static` 的 `Regex` / `NSRegularExpression` / 正则字面量位于热函数里 | `hasSentDelegationBlock` 约 13 ms 一次 |
| 5 | 每个 token 对整段做全量工作 | 流式路径里的 `Array(string)`、`String.count`、整段 `NSTextStorage` 替换、整段正则 | StreamVeil、RichLink、`.textSelection` |
| 6 | 入队后立即同步出队的循环 | `enqueue…` 里直接调用 `flush…` / `drain…` | 2.2.6 主线程 98% |
| 7 | 大范围 `withAnimation` 或整窗动画，尤其折叠展开和设置切换 | `withAnimation` 包住影响整列或整窗的状态 | 树折叠导致时间线空白 |
| 8 | 每条消息或每次打开都拉起子进程、发网络请求、读 Keychain | `Process(`、CLI 调用、`security`、`auth status` | Claude 身份缓存；Codex 一次性调用参数 |
| 9 | 新的全局开关乘以保留列数 | 主题、字体、语言等全局通知的订阅者 | Creation 切换 502 ms |
| 10 | `ForEach($array)` 绑定 | `binding_removal_checks` 会拦截 | #51 崩溃 |
| 11 | 缓存是否有上限、能否在内存压力下释放 | 新的 `[Key: Value]` 静态缓存是否用了 `RecentCache` 或订阅了 `.memoryPressure` | — |
| 12 | `@MainActor` 里的非结构化 `Task {}` 做重活 | `Task {` 后接解析、编码、diff | `DiffParser` 改为 `@concurrent` |
| 13 | 取消、超时、清理是否完整：进程、传输、监听器 | 新的 `addObserver` / `NSEvent.addLocalMonitor` 有没有对应移除；`AsyncStream` 取消 | 10-21 服务审计 |

## 7. 欠账与空白

### 列过但没做，或状态未知

动手前先确认现状，下列条目可能已被后续改动覆盖。

- **整库 JSON 编码**：忙碌时约每 4 秒序列化整个库，开销随 Hydra 任务数增长，从未在真实库上测过（`audit-2026-10-28-core-data.md`）。
- **`snapshotForSave`** 仍会遍历全部条目来构建 head 和脏轮列表，只有位置分配做了缓存；`writeThreadSynchronously` 仍在主线程的若干路径上调用（`AppModel.swift`、`ThreadRuntime.swift`）。
- **侧栏**：`DetailView` 的运行集合仍是 O(N) 扫描（attention 集合与 `MinuteClock` 已在 11-25 处理）。
- **设置页构建**：切页冷启动 30–130 ms，Providers 页最重。General 页剖析结论是：外观不变的前提下最多再省 10–20 ms（系统开关约 2 ms/个）。
- **文件图标和附件预览**的同步小读盘（`FileIcons.icon`、`AttachmentPreview`）。
- **Markdown 预热优先级**：先取前 96 条再过滤已缓存的，较新的可见消息可能错过预热。
- **`WindowChrome.fitTitlebar`** 可能自我重入，只是理论候选，从未证实。
- **每次 shell 命令后对整个仓库做 git 扫描**：11-15 瘦身审计列为三大运行时机会之一，之后有没有处理，未查到记录。

### 从没系统做过的方向

- **冷启动**：只有一次“启动后再加载库”的改动，从未测过启动时间、库解码耗时、Provider 探测成本。
- **内存**：没有长会话的内存增长或泄漏探针，没有缓存峰值的测量。
- **规模**：数百个会话或项目时的侧栏、搜索、归档。
- **输入框按键延迟**：大草稿、大量附件时。
- **内置终端（SwiftTerm）、搜索、diff 面板、Quick Chat、语音**：几乎没有性能记录。
- **玻璃与 WindowServer/GPU 归因**：只做过一次渲染探针，0–450 ms 过渡期没测过。
- **真实触控板物理**：所有滚动探针都用合成事件。

## 8. 工具箱

### 离线检查（`python3 scripts/verify.py`）

| 检查 | 级别 | 守护内容 |
| --- | --- | --- |
| `timeline_performance_checks` | fast | 滚动跟随、读者意图、历史补位数学、`TimelineMeasurements` 2 万次更新、隐藏列抑制 |
| `first_send_checks` | fast | 首条消息先显示再保存；新会话跳过读历史 |
| `codex_one_shot_checks` | fast | Codex 一次性调用不加载插件、apps、遥测 |
| `hydra_idle_checks` | fast | agy 超时与 Hydra watchdog 的放弃条件 |
| `weather_window_checks` | fast | Weather 在有任务、调整尺寸时暂停，帧率 ≤30，昂贵绘制不回来 |
| `runtime_audit_checks` | fast | 发送、中断竞态，32 MB 载荷，MCP 取消 |
| `background_task_checks` | fast | Claude 后台任务期间不关闭会话 |
| `binding_removal_checks` | fast | 拒绝 `ForEach($...)` |
| `ui_audit_checks` | gui | 解码、解析、FileIndex 的过期结果丢弃与按键合并 |
| `selection_redraw_checks` | gui | 选择重绘的脏区范围 |
| `runtime_storage_checks` | slow | HangWatchdog 报告保留与诊断清理 |
| `data_safety_audit_checks` | slow | 保存规模、缺失轮次拒绝 |

slow 和 gui 检查在构建主机上跑（`docs/operations/build-host-ci.md`）。没有任何检查度量真实的 GUI 延迟、CPU 或内存。

### 仓库内的探针（DEBUG 构建，`--website-captures <新目录>`）

`--timeline-stress`、`--history-scroll`、`--history-flick`（外部 HID 驱动）、`--held-drag`，加上环境变量 `TIVANO_TIMELINE_TRACE=<path>`（时间线 JSONL trace）。启动方式见 `docs/operations/product-captures.md`。

**这些探针都要前台窗口和焦点。** 按全局规则，未获本次许可不要在 Artemis 上跑；放到 Thor 或 H8S 上跑。

### 已退役的探针

- `HeavyLoadProbe`（三会话流式回放）、`SettingsInteractionProbe`（设置页加主线程心跳）、`RenderCostProbe`、`TextParityProbe`（48 个排版用例像素比对）、`HeroSwitchProbe` 等：3.0 瘦身时移出仓库，存放在 `<artifact-root>/private-artifacts/retired-probes-20261115/`，`MANIFEST.md` 写明了来源提交 `b877e03cf`。
- `PerfSqueezeBench`（5 个场景：多流切换、滚动加载、重会话切出与释放、设置进出与切页、Hydra 10 head）加前后结果和对比脚本：`private-artifacts/retired-probes-perf-squeeze-20261116/`。
- 历史探针产物：`private-artifacts/perf-probes/`。

这些 runner 是针对当时的代码写的，需要的话从来源提交恢复后再适配，不能直接拿来跑。

### 运行时自带的仪表

- `HangWatchdog`：主队列 4 秒无响应，或主线程 CPU 持续 ≥90% 达 8 秒（活锁），触发 `sample`，报告写入 `~/Library/Logs/<库名>/hang-*.txt`。用户报卡顿时先要这份报告。
- `SwitchLatency`（Dev 与 Preview）：切会话和归档时的 signpost 和阻塞时长；归档另记 `archive steps:` 各步耗时，列构建记 `column …: cached/recycled/made`。
- `DCDisplayCycleGuardedWindow` 的 `os_log` 风暴记录。
- `MemoryPressure`：系统内存压力时释放隐藏列、闲置会话和缓存。

### 测量协议要点

1. 用优化构建测量。探针只在 DEBUG 构建里，所以要加 `SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule`。`package_local.sh` 打的 Dev 包已经是 `-O`，但不含探针。用同一二进制里的开关切换新旧路径，或者用两个同参数的构建。
2. 固定窗口尺寸、显示器、主题、壁纸；关闭 App Nap（启动参数 `-NSAppSleepDisabled YES`，不写进 defaults）；测量期间不跑 `xcodebuild`。
3. A/B/A 交替，至少两轮；锁屏、被 `sample` 扰动、窗口被挪走的轮次直接剔除。
4. 核对负载一致（增量条数、文档范围、实际发生的动作）。
5. Instruments 用 SwiftUI 模板（Update Groups、Cause & Effect）加 Time Profiler；Animation Hitches 只看 `hitches-updates`。
6. 报告写清楚哪些已证实、哪些在噪声内、哪些未验证。

## 9. 案例索引

按时间排列。版本号：2026-09 为 Droppy Code 时期，2026-10-09 起为 Tivano（从 0.2.0 重新计数），2026-11-08 起有 Preview 版本线。

| 日期 | 版本 / 提交 | 区域 | 做了什么 | 结果 | 来源 |
| --- | --- | --- | --- | --- | --- |
| 09-14 ~ 09-18 | Droppy 1.1–1.6 | 时间线、Hydra、设置 | 视口内才构建、流式分块合并、首帧只画 3 块、并发 head 上限 8、进度条缓存 | 有效，奠定基础 | CHANGELOG |
| 09-25 | Droppy 1.7.0 | 时间线、存储 | 改用 eager 布局防止窗口边缘冻结；保存间隔 ≥4 秒；停用 Web 磁盘缓存 | 有效 | CHANGELOG |
| 10-07 | Droppy 1.7.1–1.7.3 | 主题、Hydra | Performance Mode；进度条改用 CA 图层；活锁检测 | 阴影部分当天回退 | CHANGELOG |
| 10-08 ~ 10-09 | `8312cb913` → `172225aeb` | 存储 | 共享库轮询，加上后一天删除 | 撤回 | git |
| 10-11 | `4d4508c89` | 时间线 | `MountedWindow` 加占位；flush 16/45/90 ms | 有效 | git |
| 10-12 | 1.1.13 | 时间线 | 去掉 1 pt 推挤，31 次推挤 → 0 | 有效 | `docs/operations/timeline-jitter.md` |
| 10-13 | `0b4a8b8e4`、`c3785c113` | 时间线 | 树折叠不加动画（空白帧 153 → 0）；隐藏列跳过修复 | 有效 | `t04-f2-tree-blank.md` |
| 10-14 | `37e6d7e3c`、`95564b207` | 流式、其他 | 结束时不再重新解析；favicon、签名校验后台化；退出最多等 30 秒 | 有效 | git |
| 10-16 | `4fc87d1ee` | 时间线 | `hasImages` 解耦 | 有效 | `continuation-session-regression.md` |
| 10-16 | — | 空转 | 怀疑 `fitTitlebar` 循环 | 未证实 | `continuation-window-trigger.md` |
| 10-17 | `6e789700d` | 流式、存储 | `bindEntry`、保存位置缓存、StreamVeil 增量、后缀追加、滚轮监视器 | 有效；TextRenderer 和纯文本改道被否 | `overnight-results.md` 等 |
| 10-18 | `de4d71f64` | 流式、设置 | 流式和淡入期间关闭 `.textSelection`；设置、侧栏、Provider 收窄失效范围 | 心跳 42–72 → 5.1 ms，CPU −55% | `overnight-2026-10-18.md` |
| 10-19 | `0c779cc56` | 空转 | 隐藏列的调整尺寸、动画、输入框刷新加门控 | 有效 | git |
| 10-21 | `64e57cbb6`、`2448c7ab4` | 运行时、服务、侧栏 | 四组静态审计修复；拆分 revision | 未单独测量 | `audit-2026-10-21-*.md` |
| 10-24 | `7e33fefdd`、`a3c9ca97a` | 切换、冷打开 | 前缀和加二分；切换前清焦点；`memmem`；静态正则；initial 24 → 12 | 卡帧 15 → 8–10，CPU −24%；三次结论撤回 | 记忆库 10-24 |
| 10-25 | `147ef23b2` | 设置 | 删除 Token 热力图 | 有效 | git |
| 10-28 | 2.2.0 / `ba439adf0` | 存储、输入框 | 保存只列一次目录；大图后台处理；缩略图失效；运行时释放 | 有效 | `audit-2026-10-28*.md` |
| 10-28 | — | 侧栏 | 搁置区 A/B | 噪声内 | `private-artifacts/perf-probes/20261028T102653-shelf-ab` |
| 10-29 | `7e0fe768c`、`d5dd527a3`、`997b2a0ac` | Hydra、存储 | 放回队列死循环；watchdog 限频；Token 用量后台写盘；head 首次保存后台化 | 修复 2.2.6 的 98% CPU | git、记忆库 |
| 11-02 | `9f0a1f7a1` | Provider | Keychain 后台读取加超时；auth status 缓存 | 有效 | git |
| 11-08 | `4d2c7b89e` | 切换、流式 | 运行中的列保留；后台 1 Hz | 有效 | git |
| 11-11 ~ 11-16 | `2ec80e9b2` → `fcd4e383e` → `90d559cd2` → `8e37d177d` | 历史加载 | 预加载 → 取消校正 → 同拍补位 → 重置累计量 | 收敛；一帧错位已消除 | git、记忆库 |
| 11-14 | `1dc65677e`（2.5.32） | 空转 | 链接段落高度缓存（#51） | 有 `sample` 依据，A/B 未复现 | 记忆库 |
| 11-14 | `067c1a15b`、`504ae4a41` | 时间线 | 向上即停止跟随；re-pin ≤1 pt | 有效 | git |
| 11-15 | `2d8228a00` | 全局 | 3.0 瘦身：退役探针、删除死代码，砍掉空转、流式、存储上的重复工作 | 死代码占比不到 2%，运行时收益更大 | git、记忆库 |
| 11-15 | `a715d85d8`、`1f7c17492`（preview.6、.11） | 切换、侧栏、内存 | 放大不触发重新布局；原生追加；分两阶段冷切换；内存压力释放；复用列 | perf-squeeze：重会话切换 p95 149 → 88 ms，设置打开 109 → 52 ms | `retired-probes-perf-squeeze-20261116` |
| 11-16 | `6c4572295` | 输入框、存储 | 首条消息先显示，保存在后 | 有效 | git |
| 11-16 | `fd81168b5` | 空转 | Weather 空闲时卸载，模糊 12 → 4 | 有效 | git |
| 11-16 | `8e4a6e86c` | 主题 | 视图身份统一；通知只发一次；列移出窗口；Dock 图标延后设置 | 502 → 123 ms | git |
| 11-16 | `dc5baf79f` | Provider | Codex 一次性调用不下载插件目录 | 34–65 MB → 0.72 MB | git |
| 11-17 | preview.26 | 空转、流式、时间线、运行时 | 后台、最小化和不可见时停动画与定时器；流式段落只追加后缀；大纲按索引查找；命令后快照用 FSEvents 屏障替代 `git add -A` | 前台 bench 交替 A/B 落在噪声内（多流 p95 +~3 ms 未定论）；收益在后台，bench 未覆盖 | `private-artifacts/perf-overnight-20261117` |
| 11-17 | preview.28 | 归档、切换、侧栏 | 归档先标记并移走行，选中邻居推迟一帧且不进 `panelSlide` 动画；本体与 helper 一次批量更新（一次 `synchronizeThreads`） | 合成 1669 线程库：按键到行开始消失前主线程占用 184–728 → 48–60 ms；邻居切换单独计 64–200 ms；`archive()` ~15 → ~12 ms | `private-artifacts/archive-latency-261117` |
| 11-17 | preview.29 | Hydra、流式、Git、侧栏、Provider | Hydra 恢复跳过已结算 lead；SSE/MCP 成块读取；`blobs` 改用 `cat-file -Z`；只改 `updatedAt` 等字段不再全量同步；CLI `--version` 与模型列表探测共享 | Hydra 扫描加载 62 → 2 份、33 → 9 ms；SSE 端到端快 3–4 倍；60k 文件仓库 93 → 21 ms；1500 会话库单次更新 p95 36 → 34 ms（剩余开销在侧栏重排） | `private-artifacts/perf-overnight-20261117/thor-r2` |
| 11-17 | preview.43 | 归档、切换、隐藏列 | 预建列在满员时先腾出最旧的已访问列（原先插到队首又从队首裁掉，刚建好就丢）；归档线程的列释放名额；预建等历史加载完再建；`chatColumnIsShown` 环境值改为每列一个 `ChatColumnVisibility` 对象，大视图 body 不再读显隐；去掉隐藏列的 `.disabled`；从未显示过的预建列在后台稳定首次布局不再标记“显示时整栈重测” | 本机隔离实例、200 会话合成库、⇧⌘⌫ 每轮 12 次交替 A/B：选中邻居后主线程阻塞 182–234 → 49 ms，之后 1 s 忙碌约 300 → 103 ms，命中预建列 2/12 → 12/12；按键到行开始消失 ~18 → ~14 ms。消融：只关环境值翻转 195 → 42 ms，`.disabled` 或 `WindowLiveResize` 单独关几乎无变化 | [archive-switch-hidden-columns.md](archive-switch-hidden-columns.md)；`private-artifacts/archive-latency-thor-1117` |
| 11-24 | 3.0.19-dev | 流式、文字显示 | `LinkTextView` frame 主权收归 SwiftUI（关 `isVerticallyResizable` / `widthTracksTextView` / `backgroundLayoutEnabled`），容器宽只在 `setContainerWidth` 一处写入；有限宽在显示栈测并在绘制/命中/真实改宽/核对前还原，无限宽走每视图 `TextHeightMeasurer`；删定时自愈改为事件驱动 `reconcileDisplay`（最多 2 次复核）加 Release `TextDisplayAudit` | `-O` 独立线束 A/B（基线 `6a696b4f5`）：拖动改宽 −0.1%，核对不一致 0/20430；流式追加 −1.0%；整栈重测 −3.5%；FoldReplyRepro 9 场景与 27 轮 0 高度注入全恢复 | [text-display-structure.md](text-display-structure.md)；`private-artifacts/blank-hunt/bench/text_display_bench.py` |
| 11-25 | `tivano/4062f22c`（基于 3.0.22-dev） | 全局：死代码、启动、流式、主线程 IO、编译 | 删 TokenLedger；启动同步活后移；流式原地追加；Pi/Omp 合并；Git/MCP/账户 IO 移出主线程；时间线、侧栏增量缓存；拆类型检查热点 | Thor `--subagent-panel-loop` A/B：大块流式 CPU −10%，其余 −2~−6%；干净编译慢约 6%（未达成）；冷启动未测 | [audit-2026-11-25-sweep.md](audit-2026-11-25-sweep.md)；`private-artifacts/perf-audit-ab-261125T132145` |

## 10. 维护

- 每轮性能工作结束：在 §9 加一行；有新的撤回或 no-go 就写进 §4；欠账做掉就从 §7 移走；某个区域状态变了就更新 §2。详细过程照旧另写一个文件放在本目录，本文只做索引和归纳。
- 新增的教训写成“在什么条件下观察到什么”，不要写成“永远这样做”。
- 修过的 bug 如果能离线检查，按 `AGENTS.md` 的约定补检查，并在 §8 登记。
