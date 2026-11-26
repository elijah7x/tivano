# 2026-11-25 全量性能扫查（四批）

基线 dev `8f69adc47`（3.0.22-dev），分支 `tivano/4062f22c`，四批提交加一个 rebase 修正。

## 做了什么

| 批 | 方向 | 主要改动 |
| --- | --- | --- |
| 1 | 死代码、启动、流式 | 删 `TokenLedger` 整套（改为 provider 发 `.tokenSpend` 事件，`TokenSpendTracker` 汇总）与 Genie 等死符号；DeepSeek key 观察推到 Keychain 读完后；WhatsNew 只解析一次且异步；App 图标首帧后再设、TIFF 后台编码并按签名跳过；Keepsake 并发加载；Remote MCP 启动改异步加 5 s 超时，去掉 `semaphore.wait`；`TimelineEntry.appendStreamed` 原地追加；StreamMend 不再整段复制；ProseRunView 已完成资源缓存；面板拖动、命令面板、输入框占位符、FileMention 收窄失效 |
| 2 | 重复实现、主线程 IO | `PiRPCSession` 合并 Pi/Omp；`CLIProbeCache` 泛型 actor；Codex/ACP 单消费者事件队列；Git、WorkingTreeWatch、TokenTaken 改 `@concurrent`；`LoginEnvironment.which` 正缓存；时间线 `resolvedBlocks` 带代数缓存、`turnsStructureRevision`、隐藏时取消 `keepAnchor`；侧栏 attention 集合增量维护；`MinuteClock` 不活跃时暂停；Dock badge 只在变化时写 |
| 3 | 存储、Provider、设置 | `MCPStore` 异步加载（`ensureReady`）、写入按代合并；MCPHub 并发列工具；`StdioProcess` 共享子孙进程扫描；孤儿附件清理单次解码加 24 h 预检；ProviderAccountStore 按 mtime/size/inode 缓存；目录持久化去抖；Hydra 路径与日期格式化去重；设置页 hover 状态下沉、图表滚动时暂停 |
| 4 | 编译 | 拆开 >1 s 的类型检查热点；`moveThreadAsync` 把历史检查移出主线程；删 11 个陈旧 xcstrings 键 |

## 验收

- 本机 `verify.py --base dev --slow`：51 PASS。Thor `--all`：51 PASS；`--gui` 四项 PASS。
- Thor A/B（`private-artifacts/perf-audit-ab-261125T132145`），`-O` WMO DEBUG 构建，`--subagent-panel-loop`，base/new 交替两轮，`-NSAppSleepDisabled YES`，测量期间无 xcodebuild：

| 场景 | base CPU % | new CPU % | 变化 |
| --- | --- | --- | --- |
| panel-400-fast | 33.0 / 34.3 | 32.8 / 33.0 | −2%（噪声边缘） |
| panel-400-large-chunks | 48.8 / 46.7 | 42.8 / 43.1 | **−10%**，两轮一致 |
| panel-520-fast | 34.1 / 35.2 | 33.3 / 33.2 | −4% |
| parent-control-400-fast | 39.7 / 40.1 | 37.6 / 37.5 | −6% |
| 空闲、quiet | 11.0–11.1 / 2.0–2.3 | 10.4–11.9 / 1.9–2.0 | 噪声内 |

  四轮都没有 long gap，chunk 全部送达。`maxGapMs` 是单次最大值，parent-control 一项 new 两轮（44 / 39 ms）高于 base（31 / 22 ms），未定论，需更多轮次。

- 编译：Thor 干净 Debug 构建 base 58.1 / 53.9 s，new 60.6 / 58.1 s，**new 慢约 6%**。本机早先测到的 112.7 → 84.2 s 没有在 Thor 上复现，应视为本机噪声（当时有其他构建在跑）。类型检查 >150 ms 的告警从 91 降到 72、>1 s 从 16 降到 12，对改动这些文件的增量构建有帮助，但干净构建没有收益。

## 未验证

- 冷启动时间：没有探针，启动路径的改动只有代码层面的依据（同步 IO、`semaphore.wait` 已移除）。
- MCP、账户、Git 移出主线程的效果：负载探针不覆盖。
- 侧栏规模（数百会话）下 attention 增量维护的收益。

## 没做的

模块拆分、AppModel 拆分（剩余约 2 s 的类型检查热点都是首次引用 AppModel 的成本，属结构问题）；关 `ENABLE_TESTABILITY`（T08 线束依赖 `@testable import`）；Captures 编译开关；sidebar-shelf 资源；约 320 个手工 xcstrings 键；库同步写盘（仅做了 `moveThread` 一处）。
