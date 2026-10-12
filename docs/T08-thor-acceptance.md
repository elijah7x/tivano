# T08 当前整合依据（2026-10-12）

本节记录 lead 提供并已审阅的最终证据；下方旧正文完整保留为历史快照。旧正文的 blocked 状态、GUI 授权及 12 轮预算描述属于当时记录，不代表当前结论，也不据此宣称全项验收。

- 目标基线：`128bc3d14a04e4c328aa29bf0f4c1ddcea97963c`（Dev 1.1.15/build58）。按共同祖先 `f7eb10f4a071ff20cdf1847601d9359a07fc7818` 三方 squash 整合精确源提交 `a39559095c15ec6c572135d842045178d873d3b9`，保留新版 dev 功能及副本现有改动；整合版本为 Dev 1.2.0/build59。
- lead 已审 `a39559095c15ec6c572135d842045178d873d3b9`。该提交包含 `eb88ca9d3f2aa886079790e368125719c9a6e9d1` 的 OMP 接入、`300db74dad06d43a421b48b5ca2c0d166ca9cdc7` 的压测收尾及 Thor 修复。
- 五个产品源码文件的哈希与 Thor 最终 Debug `exit 0` 构建一致：`Tivano/App/AppModel.swift`、`Tivano/Core/Support/CaptureRun.swift`、`Tivano/Services/MCP/MCPBridgeSource.swift`、`Tivano/Services/Providers/OmpCLI.swift`、`Tivano/Services/Providers/OmpSession.swift`。此处引用的是源提交的已有构建证据，不是当前三方整合副本的构建结果。
- 核心压测、实际 MCP/Store/runtime、云端 Hydra、Git 副本/文件恢复及真实标题均通过。
- 真实 GLM 英文批准及中文拒绝的 GUI 完整轮次均通过，lead 已实际查看截图。中文最终 turnID `B3CBEE29-1060-43CB-B39E-822A37FEB589` 为 `completed`；实际 assistant 为 `THOR_GLM_GUI_DENIED`，工具为 `declined`，没有目标文件或待审批。
- 旧人工 12 轮上限已获授权撤销；GLM 实际发起 4 条用户请求。超时及中断失败记录保留，不计作通过。
- 完整 TivanoApp 界面矩阵、正式签名及双 edition 活动运行仍未覆盖，不宣称全项验收。当前副本只整合文件；整合后的审阅、所需构建与运行由 lead 完成。

---

## 历史快照（原正文）

# T08 Thor 验收报告

## 结论与交付

**状态：blocked。** Thor 的构建、OMP 18.9.1 兼容回归、真实登录/模型/额度 CLI 路径、本地真实 MCP、实际 App 数据层及无 GUI runtime 工厂链路已取得通过证据。GUI、真实模型 Hydra lead 派头和两种正式 edition 的运行验收仍受启动授权及签名条件阻塞，不能称为完整真机验收通过。

- 执行机器：`Thor.local`；开始于 2026-10-11 16:06 UTC（Thor 本地 2026-10-12）。未在 Artemis 构建或测试，未派子代理。
- 指定 base：`300db74dad06d43a421b48b5ca2c0d166ca9cdc7`，精确对应 `artemis/task/t08-omp-provider`。没有换 base、合当前 dev、rebase 或 reset。
- branch：`thor/t08-acceptance`。
- worktree：`/Volumes/ExHeart/forked/tivano/worktrees/t08-acceptance`。
- 修复及验收支持文件：随本报告合成一个新的普通 commit；准确 hash 见外部报告及 progress JSON，或运行 `git rev-parse thor/t08-acceptance`。不制造空提交。
- ref：`refs/heads/thor/t08-acceptance`，可由 Artemis 的 `git fetch thor` 获取。未 push、建 PR、合 dev/main、改版本、发版、package 或安装到 `/Applications`。
- `origin/main` 核对为 `d13d131dde8a47e78c1dd833fa79b53d7ea2c8e6`。base 与其历史已分叉，`git rev-list --left-right --count BASE...origin/main` 为 `49 12`；main 有 12 个 base 不含的提交。按委托保留原 base。
- 真实模型请求：**1 个用户轮次 / 最多 12 个**。使用已有 DeepSeek 登录、`deepseek/deepseek-flash`、low effort；收到 `THOR_T08_OK`。无工具、无持久会话、未充值或更改服务。其余模型流量均为隔离 HOME 的本地 loopback fixture。

外部交付：

- `/Volumes/ExHeart/forked/tivano/port-tasks/reports/T08-thor-acceptance.md`
- `/Volumes/ExHeart/forked/tivano/port-tasks/reports/T08-thor-progress.json`

本报告以下证据路径均相对 worktree 的 `build.noindex/t08-thor/`；原始输出、合成库、会话和测试文件留在该目录，不提交大产物、账号信息或日志。

## 授权与环境

最终复核 `T08-thor-authorization.json` 仍为 `app_launch_authorized: false`。没有调用 `open`、App/SwiftUI entry、`NSApplication.run`、quick_run、package_local 或 ship；没有退出、替换或操作既有 App/其库和会话。

| 条件 | 实测 |
|---|---|
| macOS | 27.0.1，build 26A434 |
| Xcode / SDK | Xcode 27.0，27A266a；macOS SDK 27.0 |
| 架构 | arm64，Debug |
| Metal | `xcrun --find metal` 成功，官方 Metal Toolchain v27.1.266.1；没有补下载 |
| 签名 | `security find-identity -v -p codesigning`：`0 valid identities found`；没有导入私钥、使用 ad-hoc App 或替换签名条件 |
| OMP | 实测 `omp/18.9.1` |
| 初始 CLI 路径 | `/opt/homebrew/bin/omp` |
| 后续路径变化 | 16:32 UTC 检查时上述链接已不存在；已有 keg `/opt/homebrew/Cellar/omp/18.9.1/bin/omp` 仍可执行且版本相同。后续显式使用这个路径，没有修链接、安装或更新全局 CLI；见 `omp-disappeared.log` |
| 包缓存 | 复用 Thor `/Volumes/ExHeart/forked/tivano/DerivedData/SourcePackages` |
| 构建产物 | 本任务独占 `build.noindex/t08-thor/DerivedData` |

### 构建命令及结果

在本 worktree 串行执行：

```sh
xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build.noindex/t08-thor/DerivedData" \
  -clonedSourcePackagesDirPath /Volumes/ExHeart/forked/tivano/DerivedData/SourcePackages \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build
```

全量首跑 `build.log` 为 `BUILD SUCCEEDED`，但该后台首跑未单独捕获退出码；不据此伪造退出码。随后 `build-verified.log` 与 `serial-results.json` 已捕获 exit **0**。最终修复后的 `build-final-private-settings.log`、`build-final-private-settings-result.json`：exit **0**、`BUILD SUCCEEDED`。首跑与最终日志没有 `error:`，因此不存在需要列出的构建首段原始错误。已有警告未顺手清理。编译成功不等于正式签名 App 的启动通过。

## 证据索引

| ID | 命令/范围 | exit / summary | 路径 |
|---|---|---|---|
| A | 四脚本基线串行回归 | 每个 exit 0，`passed=true` | `serial-results.json`；`adapter/run-soyzyaj5/summary.json`；`gate/run-hzgixesx/summary.json`；`rpc/summary.json`；`native/run-tzrw2aeq/summary.json` |
| B | 修复后 Swift adapter 重测 | 0 / true | `adapter-patched/run-fb7ngjuh/summary.json`、`fake/summary.json`、`kit/real/summary-real.json`；`patch-retest-results.json` |
| C | 修复后 gate 矩阵，rounds 2 | 0 / true，50/50 | `gate-patched/run-se0esfmp/summary.json` |
| D | 实际 App 模块 CLI/Store/TokenLedger/双 root | 各进程 exit 0，各 summary true | `integration/run-w9uutezl/summary.json`、`commands.json`、`cli.log`、`store.log`、`ledger-reload.log`、`second-root.log` |
| E | 实际 App 工厂/runtime → 真实 OMP/MCP → Store | compile 0，runtime 0 / true | `runtime/run-mhzo3w5d/summary.json`、`runtime-integration-summary.json`、`runtime.log`、`model-requests.jsonl` |
| F | 实际编译的 MCPBridge/config + 真实 stdio MCP/gate | 0 / true，17/17；另存旧缺陷复现 | `mcp/run-yw0_0nqu/summary.json`、`baseline/rpc.jsonl`、`fixed/rpc.jsonl`、`failed-bridge-server/stderr.log` |
| G | 已登录低成本模型单轮 | `prompt_result.status=completed`，reply 正确，summary true | `cloud/command.json`、`cloud/rpc.jsonl`、`cloud/stderr.log`、`cloud/summary.json` |
| H | 最终构建、源码与支持文件 | build 0；源码哈希/检查记录 | `build-final-private-settings-result.json`、`final-source-hashes.json`、`final-support-check.log`、`support-results.json` |
| I | 之前本任务专用 preferences 清理 | 13 个任务自建 plist 已备份并移除；保留各命令原退出码 | `task-preferences-cleanup.json`、`previous-task-preferences/`、`preferences-path-probe.log` |

A 的结果：28 个假 CLI 场景、4 worker 共 40 生命周期、12 个真实 OMP adapter 场景；50 gate；4 会话 48 轮完整 Unicode、12 次取消/恢复；15 个独立 native spawn。native 正例 task/eval agent/workpool 分别发起 5/5/4 个子请求，12 个拒绝场景均为 0 子请求。不是只数 `prompt_result`：矩阵同时断言审批 payload、工具结果、文件副作用；RPC 逐字核对 Unicode；native 核对子模型计数。

B/C 重测改动直接影响的 adapter、扩展启动及 gate；D/E/F 在最终 Capture defaults 修复后重测。原来的并发 RPC/native hook 未改变其控制逻辑，没有无因反复跑全套。

## 无 GUI 集成方法及隔离证据

新增 CLI harness 通过 `@testable import Tivano` 链接实际 Xcode Debug 模块 `Tivano Dev.debug.dylib`。它有自己的 CLI `@main`，**不调用 TivanoApp 的入口或 GUI 生命周期**。这不是启动 unsigned/ad-hoc Dev App，也不是用替身库声称集成通过。

D 使用实际 `Library`、`Storage`、`DiskWriter`、`TokenLedger`、`AppModel`、`ThreadRuntime`、`OmpCLI`、`OmpPlanLimits`、`PlanLimitsReader`、`ProviderRegistry`、`CLIUpdates`。其中 `rehearseTurn/rehearse` 为项目已有的 provider-event 注入入口，明确标记为合成事件；TokenLedger 的合成 spend 另由真实 ledger API 保存，并在另一进程重载。E 则走真正的 App session 工厂、`runtime.send/resolve/revert`、真实 OmpSession 和真实 OMP，未替换 Store、ledger、MCP、目录 Shell 或 Hydra 提示依赖。

隔离目录举例：

- D 的 library/thread/ledger/gates/config/bridge：`integration/run-w9uutezl/capture-store/storage/`。
- D 的 defaults：`integration/run-w9uutezl/capture-store/settings.plist`，已检查物理文件存在；另一 Capture root 不读到 `t08-isolation` marker。重载使用同一绝对 preferences domain。
- E 的库及 settings：`runtime/run-mhzo3w5d/capture-runtime/storage/`、同级 `settings.plist`。
- E 的 OMP provider 会话：`runtime/run-mhzo3w5d/home/.omp/agent/sessions/`；项目、MCP marker、tmp 都在该 run 下。
- F 的服务器配置由真实 `MCPProviderConfig.claude` 生成，runner只把 marker目录改到自身新建 run 下，重复执行不会混入旧计数；bridge 和 extension由实际编译的安装函数导出，非 Python 手抄的安装替身。

初版改成独立 suite 名后发现 Foundation 仍把 plist 写进用户 Preferences；仅名称独立不足以满足本任务物理目录边界。绝对 suite-domain 探针实测写入任务目录，最终使用该机制。之前本任务自建的 13 个命名 suite/probe plist 已逐个备份、删除，未清理任何已有 App domain。绝对 domain 的最终测试无需在用户 Preferences 创建任务 settings。

真实账号查询只通过官方 `models --json`、`usage --json`、无会话 RPC `get_state`；未读取 agent.db/凭证数据库或导出登录/Keychain。真实查询可能按官方行为刷新 provider 外部缓存，这不作为 App 数据隔离证据。

## 原始真机清单逐项验收

“通过”仅适用于所列子范围；同一项的 GUI 部分另列“阻塞”。未执行的补充边界明确标为“未覆盖”。

| # | 项目与结论 | 真实路径 / 注入；实测证据 |
|---|---|---|
| 1a | **通过**：登录检测、模型目录、currentModel、effort 数据、App registry 接入 | D：真实已登录 CLI 124 个模型，7 个 provider；当前 `zhipu-coding-plan/glm-5.3` 与 `get_state` 一致。每个模型 id/effort 数组逐项对照官方 fresh HOME 查询，再核对 registry 列表。empty HOME 真实 signedOut/无目录；非零 CLI 和坏 JSON 为故障注入，auth unknown、目录抛错、usage nil。 |
| 1b | **通过**：有效/无效模型与 effort；真实账户可用 | E：真实 OMP 用本地 reasoning 模型/high；实际 HTTP request 的 `model=reasoning`、`reasoning_effort=high` 均正确。无效 live effort、unknown provider/model 被拒绝，模型请求计数为 0；随后有效轮成功。D 拒绝无效初始 selector/effort，不启动进程。G：已有 DeepSeek 登录的一轮真实模型完成。 |
| 1c | **阻塞**：模型/effort GUI 菜单 | 无 App 启动授权、无正式签名；目录数据通过不等于菜单渲染通过。 |
| 2a | **通过**：权限写命令/写文件、审批允许与拒绝、副作用、Plan/final-report gate | A/C：Supervised 写改/命令问询，Auto-accept edits 写改允许但命令仍询问，Full access 允许；拒绝无 marker，Plan 写改/命令拒绝，final-report 全拒绝。E 实际 runtime.resolve 批准 MCP 双层审批、拒绝后无文件，拒绝工具行 `.declined`。 |
| 2b | **阻塞**：实际审批卡与权限菜单的视觉/交互 | E 是实际 runtime API 解析，不是点击 GUI。 |
| 3 | **通过**：gate 失败关闭、运行时缺失/损坏 gate | B：missing-gate/bad-state 启动失败；C：缺失、坏 JSON、数组、未知模式、缺字段、错类型均拒绝，修好后恢复。未破坏别人的 gate。 |
| 4a | **通过**：Auto 降级、提示去重、保存/重载 | D：旧 Auto+OMP 合成 library 由实际 AppModel bootstrap 解码为 Auto-accept edits，首次有 alert；再次设置 Auto 不重复 alert；实际 DiskWriter 保存后新 AppModel 重载保持降级，无第二个提示。 |
| 4b | **阻塞**：可见提示及菜单不显示 Auto | Core/App 路径通过，未看 GUI。 |
| 5a | **通过**：native task/xd task/eval agent/workpool 受 gate、子 spend 不混入 lead | A native 15 场正反例；B 真实 OMP Hydra-on task/eval 拒绝。D 实际 runtime 合成 token 事件验证 lead turn 不收 child agentID；真实 ledger 用合成 spend 保存/进程重载。 |
| 5b | **阻塞**：真实模型 OMP lead hydra block → App 独立副本/头线程 → 收报告 | 未启动 GUI，没有借 native-spawn 或合成事件宣称 T07 Hydra 派头通过。E 为 Hydra-off 真 runtime。 |
| 6a | **通过**：实际 App 回退/fork 路径、重复提示词、继续和保存后恢复 | E：真实 OMP 先完成重复文本轮次，再 `ThreadRuntime.revert` 回退后一个匹配点，产生不同真实 session 文件；App library 保存新路径，下一轮及新 AppModel/runtime 恢复继续成功。最后存 9 个保留轮次。B 另有真实 adapter fork/恢复。 |
| 6b | **未覆盖**：回退含附件、Plan/Hydra 注入的全部匹配组合 | 不把重复文本正例推广为这些组合已通过。GUI 回退按钮与正式 App 重启为阻塞。 |
| 7a | **通过**：备用命名不阻挡下一轮、不覆盖自定义标题 | B 有真实 `/rename`；E 首轮结束后自动请求备用命名，在其可能尚在途时发送下一轮成功；自定义标题保留且保存重载。D 合成 title 事件验证无标题引擎时接受 fallback、用户改名后不覆盖。 |
| 7b | **未覆盖 / 阻塞**：真实 Claude/Codex 标题引擎同时运行、可见改名 UI | 未调用真实标题引擎；实际 GUI 未启动。 |
| 8a | **通过**：todo/xd todo/blocked 映射与实际 checklist 持久化 | E 使用真实 todo `op:init` 生成 3 项；`write xd://todo` 的 done 变为 `.done`，block 变为 `.pending`，实际 runtime/Store 重载仍有 checklist。B 的 todo/fault fixture另覆盖其他状态/拒绝不覆盖。D 真实 runtime 合成事件更新同一轮 checklist，只有一行。 |
| 8b | **阻塞**：checklist 视觉及真实 aborted/final-report todo 的 GUI 显示 | 未看 GUI；abandoned 状态目前为 adapter fixture覆盖，不标成真实 MCP/App 轮已执行。 |
| 9a | **通过**：OmpPlanLimits/PlanLimits 实际 CLI 对照 | D：官方 usage 映射出 11 个 windows，逐项 id/percent/reset 对照，同数据经 PlanLimitsReader dispatch 相等。示例 Kimi 28% / 0% / 27.8%，Cursor 10.5489% / 67.4889%；Gemini 小数比例未误当百分数。6 小时旧 report、重复 provider、clamp、过去 reset 为故障注入。 |
| 9b | **通过（故障注入）**：限额错误识别而非耗尽额度 | B fake `usage` 场景验证真实 Swift adapter 的 OMP 形状/通用限额解析；没有故意烧额度。未声称遭遇真实 quota exhaustion。额度窗口及中英显示为阻塞。 |
| 10 | **通过**：实际本地 stdio MCP 与各模式 gate、错误/失联/注册失败 | F 17 场：Supervised 读写审批/拒绝，Auto edits MCP 不默认放行，Full access 允许，Plan/final-report 拒绝 MCP 读写（保守未知工具策略）；同时核对审批 payload、server call marker、文件、tool isError。MCP isError、JSON-RPC error、server disconnect 均失败，成功内容引用 Error 仍成功；坏服务器有 `tivano mcp: skipping thor:` 诊断且未写文件。E 另证实实际 OmpSession/runtime 将 MCP 错误渲染数据标 `.failed`，不是 completed。 |
| 11 | **通过（只读/私有布局注入）**：CLI 更新归属、版本与 invocation | D：真实 keg 判为 Homebrew omp；任务私有 npm/bun 模拟布局核对官方包 `@oh-my-pi/pi-coding-agent`、prefix/globalDir/binDir、生成命令；unmanaged=nil channel，只查询官方 registry latest=18.9.1。版本比较通过。**未执行**全局 install/upgrade；实际安装完成路径不属于此次授权范围。 |
| 12a | **通过**：Capture root、同会话清理与超过一天活跃 gate | D/E：库/settings/MCP/gate 都在任务目录；E 把实际活跃 gate mtime 改成两天前，新开 peer 仍保留它，停 peer 不删 runtime gate，runtime 停后自己的 gate 清理。实际 fork/session也在任务 HOME。 |
| 12b | **阻塞**：正式 Release/Dev 各自运行时目录及跨 edition 活跃会话 | 只核对源码的默认 `StoragePaths`/AppInfo 路由（Release Tivano，Dev Tivano Dev）；没有读/写生产目录或启动两版来冒充通过。 |
| 13 | **阻塞**：中英文图标、模型/effort/权限菜单、降级提示、审批、拒绝/错误、额度、空态/遮挡 | 没有 GUI 授权和正式签名，因此没有截图或视觉验收；源码/本地化 catalog 和构建不作为看图通过证据。 |

## 本轮修复及失败记录

1. **MCP 失败假报成功**：base OMP extension 仅用 bridge 的 text-only `call()`，MCP `isError=true` 被包装成 `Error: ...` 文本后仍以成功 ToolResult 返回。F 的 baseline 真 OMP 复现 `isError:false`、内容 `Error: THOR_MCP_FAILURE`。新增 bridge `callResult(): {text,isError}`，OMP 对真正错误抛出；Pi/Command Code 保留原 `call()` 文本协议。F 重测 MCP error、RPC error、断连失败及“成功引用 Error”正例；E 验证实际 `.failed` 工具行。
2. **MCP bridge 安装越过 Capture root**：改为 `StoragePaths.directory("MCP")`，正常 edition 路由保持 App libraryName；Capture 跟随其实际 root。D 断言实际安装路径，F 使用该安装产物。
3. **Capture defaults 共用/物理位置问题**：固定 suite 会交叉读写；单独 hash suite虽独立仍写用户 Preferences。最终改为 capture folder 内的绝对 preferences domain。D 的物理 plist/第二 root/进程重载断言通过；I 清理仅本任务早先自建的 named-suite 文件。最终不需要 CryptoKit/hash 依赖。
4. **无效选择被静默忽略**：OmpSession start/send 对 malformed model selector、未知 effort 预先拒绝，复用现有本地化错误 key；未知实际模型仍交官方 RPC拒绝。D/E 验证不启动/零模型请求及恢复。B/C 重测相关适配层/gate。
5. **无 GUI App runtime 入口崩溃**：原始日志为 `Tivano/AppModel.swift:1281: Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value`。AppModel 的可见性、attention、dock badge 改为可选 NSApp 访问，有真实 GUI 时行为不变。D/E 不建立 NSApplication，能走真实 runtime完成/持久化。

失败日志均保留，不计入最终通过：

- `integration/run-9dbbhsqa/store.log`：上述 NSApp 崩溃，exit -5；其 summary明确 false。
- 早期 `store-integration.log` 把 runtime turn-spend 与 adapter负责的 ledger-spend 混为一谈；已修正 harness，真实 ledger另测并跨进程重载。
- 早期 CLI 用不同时间/cwd 的目录/usage快照比较失败；目录由 119 变为 124 个模型。最终使用与 OmpCLI 相同 HOME/cmd 的新官方快照并严格逐项比较，未放松 model/effort/percent/reset 断言。
- `runtime/run-w_2j8oqa/compile.log` 的 harness actor标注错误、`runtime/run-lyuaj74g/summary.json` 的 missing PATH omp、早期无断言的错误 todo输入均不算验收证据。最终用真实 CLI schema的 init/done/block，明确断言 checklist；指定仍存在的 keg，未升级 CLI。

## 权限矩阵与接入边界

| 工具 | Supervised | Auto-accept edits | Full access | Plan | final-report |
|---|---|---|---|---|---|
| 明确只读/报告白名单 | 允许 | 允许 | 允许 | 允许 | 拒绝 |
| 本地文件 write/edit 等 | 询问 | 允许 | 允许 | 拒绝 | 拒绝 |
| bash/eval | 询问 | 询问 | 允许 | 拒绝 | 拒绝 |
| MCP/未知工具/未知 xd device | 询问 | 询问 | 允许 | 拒绝 | 拒绝 |
| task/native spawn | 拒绝 | 拒绝 | 仅 Hydra-off + allowTask 允许 | 拒绝 | 拒绝 |

Hydra-off 的非 Full access native task/spawn **直接拒绝，不转一次父任务审批**，避免子调用继承隐式未审批权限。Hydra-on 禁 native spawn，App 独立头模型未改。

参数保持 `omp --mode rpc-ui --approval-mode yolo --config <session.yml> -e <tivano-gate.ts>`，按需 model/thinking/resume/system prompt。gate handshake 未就绪不开始模型轮；启动文件 `autoResume:false`，bash autoBackground/async关闭，task recursionDepth 1。`TIVANO_OMP_GATE`、有 MCP 时的 `TIVANO_MCP_BRIDGE/TIVANO_MCP_CONFIG` 均指向隔离文件；未记录环境凭证值。

CLI 更新包名和 MCP 均已接入。与 Pi 共用 StoragePaths、MCPBridge/配置、stdio、snapshots、TokenLedger、UsageLimitSignal；OMP 的 RPC-ui、yolo+gate、Auto降级、prompt_result完成、fork/rename/todo为其专有路径。没有移植 Droppy 品牌或 native Hydra事件路由。

## 复现支持

在该 worktree，**构建与压力脚本串行**。当前 PATH link缺失时用仍存在的安装：

```sh
export T08_OMP=/opt/homebrew/Cellar/omp/18.9.1/bin/omp
python3 scripts/t08_thor_checks.py --omp "$T08_OMP"
python3 scripts/t08_thor_integration.py
python3 scripts/t08_thor_runtime.py
# 读取 integration runner 输出的 artifacts，传给 MCP runner：
python3 scripts/t08_thor_mcp.py --integration build.noindex/t08-thor/integration/run-w9uutezl
```

新 runner 为每次运行建独立 run 目录，原始失败日志不覆盖。checks runner 对每个 exit 和 `passed is true` 做核对；不自动发付费模型请求或启动 App。上面 MCP 命令指向这次已生成的具体配置；重新跑 integration 后也可以用其输出的新 artifacts。cloud 已执行的参数见 `cloud/command.json`，输入和回复完整保存在 `cloud/rpc.jsonl`；输入为“Reply exactly THOR_T08_OK. No tools, no explanation.”。外围 Python 执行的工具记录 exit 0；OMP RPC进程在检查到正确 prompt_result 后主动清理，未捕获它的自然退出码，不将 SIGTERM清理说成CLI自然成功退出。若以后另跑必须继续记在12轮预算内，不把本次成功证据重复烧额度。

Swift支持：`scripts/fixtures/omp_adapter/ThorIntegration.swift`；真实私有 stdio server：`thor_mcp_server.py`；已有四 stress脚本及 README保持可用。没有 test target或安装脚本。

## 剩余 blocker 与最小后续条件

1. Owner 在交接目录明确把 `T08-thor-authorization.json` 的 `app_launch_authorized` 设为 true，才可启动 Thor 自己的隔离测试 Dev实例。
2. Thor需要可用的既定 Developer ID signing identity；不能以 unsigned/ad-hoc App替代GUI验收，不从Artemis导私钥。现有账户已足够，不需要充值或新的登录。
3. GUI阶段先确认私有 storage/settings/MCP/CLI session路径，使用经过证明的隔离入口；既有 WebsiteCaptures会驱动合成capture场景，不能拿它的截图冒充真实OMP/Hydra交互。还须核对UI控制权限并实际看图。
4. 正式Release/Dev并行默认目录、真实OMP Hydra block/独立副本/头报告、中英UI及附件/Plan/Hydra回退组合尚未通过。续接只测这些缺口及受影响范围，不在Artemis重跑、不退出或替换已有App。
5. 当前全局 `/opt/homebrew/bin/omp` 链接不在；任务可继续用私有 binaryPath指向已有keg。恢复全局安装链接由owner单独处理，本任务未改它。

任务 worktree和证据保留；没有清理别人的worktree或操作主checkout。
