# 窗口布局重复触发调查

## 结论与证据边界

未定位已证实的持续布局循环。仅保留一条有明确重复条件的候选：AppKit 将标题栏容器高度压回原值，`titlebarFrameDidChange` 异步排队，`fitTitlebar` 再将容器拉高。是否因这次写入又触发 AppKit 压回，现有采样不能回答；不能把正常窗口布局栈当作死循环，也不能据此归因于 WindowServer 自身故障。

现场为正式版 1.3.8/build25、PID 59554、macOS 27.0.1 (26A434)。`/tmp/tivano-59554-continuation-20261016.sample.txt` 于 2026-10-16 22:55:57 +0800 开始，约三秒、10ms 间隔；主线程全部 258 次样本均在 `NSApplication` 取事件 → `__CFRunLoopServiceMachPort` → `mach_msg2_trap` 等待，没有捕获 `fitTitlebar`、SwiftUI 布局或持续占用主线程。先前瞬时 ps 的 Tivano 94%、WindowServer 110%，以及随后 Tivano 约 3%，来自任务提供的观察，不能与这段等待采样拼成同一段持续高负载。退出后其他 App 加速、重开后变慢值得继续查，但本报告不能确认因果机制。

范围仅为 `Tivano/UI/Chrome/WindowChrome.swift` 与 `Tivano/App/Views/RootView.swift` 的窗口通知、状态和尺寸回写；未调查运行时、时间线或动画组件，未采集现场、操作进程、构建或测试。

## 候选：标题栏高度在系统值与自定义值之间反复回写

- **具体符号**：`WindowChromeProbeView.viewDidMoveToWindow`（WindowChrome.swift:50–94）开启标题栏容器的 `postsFrameChangedNotifications` 并订阅 frame 通知；`titlebarFrameDidChange`（123–137）排队；`WindowChrome.fitTitlebar`（237–249）写 `container.frame`。目标高度为 `Chrome.sheetInset + Chrome.chromeTopPadding + Chrome.capsuleHeight`（220–222）。
- **触发条件**：probe 已挂入非全屏窗口，收到容器 frame 通知，容器实际高度小于目标高度，且本 probe 没有待执行 fit。窗口调整尺寸是源码注释明确预期的系统重排来源；切换 App 或设置是否触发同样重排，尚无证据。
- **为何能重复**：回调只合并待执行期间的通知。MainActor task 在调用 fit **之前**将 `titlebarFitPending` 清为 false；fit 达标后若 AppKit 下一轮又将高度压低，就能再次入队。这里没有跨轮次上限或冲突检测。成立所必需的额外边是“自定义高度写入后，AppKit 再压低并发通知”，它不在这两个文件的实现中，尚未观测到。
- **停止条件**：高度稳定在目标或更高时，回调与 fit 的 `< titlebarHeight` guard 都会停止工作；进入全屏、probe 离开窗口并解除订阅、或容器不可取得也停止。fit 自己写成目标高度所发的通知会被高度 guard 拦住，因此不是无条件自递归。异步排队也避免了直接在通知栈里反复改 frame，但不排除跨轮次往返。
- **版本覆盖**：按两个文件各自历史读取，WindowChrome.swift 在基准前最近提交为 `17e42b007`；带异步合并与全屏处理的路径已出现在 `b64a00ddc` 的该文件差异中。RootView.swift 在基准前最近提交为 `b0ec957d4`，`173120dcd` 引入全窗口设置页对 configurator 的接线。对 `93f0d3394` 与 `4fc87d1ee` 仅比较这两个文件，差异为空：正式版基准与当前 dev 具备同一条源码路径。此结论是基准源码覆盖，不是对已安装二进制逐字节溯源。
- **已有证据**：实际文件存在订阅、异步恢复和 frame 写入，索引 `Users-elijah-air-Universe-Oort-forked-tivano-tivano.dev` 的 `search_code` 返回同样实现。它不依赖正在运行的会话；RootView:104 的 configurator 不随设置页显示而移除，所以全窗口设置场景也保留这条路径。
- **缺失证据**：卡顿时每秒通知/实际 fit 写入次数、同一容器高度是否交替、谁执行压低、重复持续时间及与 CPU/输入延迟的时间关系。续采样未捕获这条路径，不能称它为已定位热点。

## 已追踪但不保留为独立候选的路径

`RootView:20–23` 的尺寸报告进入 `SidebarLayout.noteLaidOutWidth`（WindowChrome.swift:417–422），只更新 `lastLaidOutWidth` 与必要时的 `holdsTrafficLights`。前者是 `@ObservationIgnored`；重复宽度立即返回，后者仅在跨越 `trafficLightsFitWidth` 时写入。它没有把测量结果回写 `width`、`renderedWidth` 或窗口尺寸。因此“测量 → 状态 → 同一宽度自振荡”在限定源码内没有闭合。

`holdsTrafficLights` 经 RootView:104 传给 `sidebarVisible`；只有 Bool 改变才排队 `scheduleTrafficLightPlacement`。队列会合并请求，`placeTrafficLights`（277–345）也只在约束实际改变时调用 `layoutSubtreeIfNeeded`。在全窗口设置显示时，`settingsShown || sidebar.holdsTrafficLights` 恒为 true，宽度阈值变化不会改变这个输入。拖动反复跨阈值可以反复放置按钮，但没有证据说明静止窗口也在跨阈值。

`viewDidMoveToWindow` 会重新注册通知、调用 `setPerformanceMode`（无条件 `invalidateShadow`）并安排按钮放置；同一 probe 注册前会移除旧订阅，deinit 也移除全部订阅，`configure` 则按窗口弱表只执行一次。现有文件没有从这些动作返回 `viewDidMoveToWindow` 的明确闭环，也未订阅 key/resign-key 通知；不能从“切换 App 卡”直接推导通知堆叠或焦点死循环。`windowDidEndLiveResize` / `windowDidExitFullScreen` 在放置后再次调用 fit，若第一次已达标第二次立即返回。

## 供主负责人执行的最小观测方案（本次未执行）

在主负责人另行授权的诊断构建中，只给上述两个文件加聚合计数，避免逐通知打印和断点暂停改变时序。每秒记录窗口/probe/容器身份、`viewDidMoveToWindow` 次数、frame 通知次数、通过 guard 的排队次数、实际 frame 写入次数、fit 前后高度、`inLiveResize` / 全屏状态，以及 `noteLaidOutWidth` 的阈值跨越次数和按钮约束实际改变次数。保留一小段有界的高度变化时间序列，不采集会话内容。

在相同窗口和固定尺寸下，对照静置、打开设置、切换到另一 App 再返回的短时间段，并与主负责人已有的卡顿时间标记对齐。判读标准：静止且不在过渡时，同一容器若连续数秒反复出现“低于目标 → fit 写到目标 → 再低于目标”，再针对压低的那次 frame setter 取调用来源；仅有一次恢复、没有实际写入的通知，或与操作同步的有限布局都不能算循环。若卡顿期间这些计数接近零，应降低本候选优先级，不继续凭布局栈归因。

历史背景检索使用 `nmem` CLI thread search，查询 `Tivano WindowServer fitTitlebar 卡顿`，返回 0 条；未采用此前 WindowServer 故障判断。
