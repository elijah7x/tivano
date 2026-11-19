# T08 OMP 匿名验收记录

> 已归档：本文使用的脚本和 App 内探针已于 2026-11-15 移出仓库，存放在 artifact root（长期 checkout 的上一级目录）下的 `private-artifacts/retired-probes-20261115/`，Git 历史中 `slim/3.0-pre` 之前的提交也可找回。以下内容作为历史记录保留。


## 来源与证据边界

本记录整理既有 T08 验收，不是本次脱敏修复的验证结果。任务副本起点为
`2613cbd1f`；当前编辑没有执行构建、检查脚本或 App。

- 原始基线：`300db74dad06d43a421b48b5ca2c0d166ca9cdc7`。
- OMP 接入来源：`eb88ca9d3f2aa886079790e368125719c9a6e9d1`。
- lead 已审来源：`a39559095c15ec6c572135d842045178d873d3b9`，包含接入、压测收尾与后续修复。
- 原始环境：arm64 Debug、macOS 27.0.1、Xcode/SDK 27.0、OMP 18.9.1。
- 来源中的最终 Debug 构建记录为 exit 0、`BUILD SUCCEEDED`。以下五个产品文件的哈希与该来源构建一致：`Tivano/App/AppModel.swift`、`Tivano/Core/Support/CaptureRun.swift`、`Tivano/Services/MCP/MCPBridgeSource.swift`、`Tivano/Services/Providers/OmpCLI.swift`、`Tivano/Services/Providers/OmpSession.swift`。这不是当前整合树或本次脱敏后的构建证据。

历史初期快照为 blocked：无 App 启动授权、缺既定 Developer ID 签名条件，仅完成无 GUI 范围。随后获得授权的补充证据覆盖云端 Hydra、Git 副本/文件恢复、真实标题及英文批准/中文拒绝 GUI 轮次；lead 已查看对应截图。超时、中断仍保留为失败，不计作通过。补充范围通过不等于完整 App 界面矩阵、正式签名及双 edition 活动运行通过。

公开记录省略账户组合、当前模型、配额、登录/付费状态、用户轮次账户细节、机器身份、私有路径及可附着会话标识。没有用虚构数据替换真实账户数字。离线 fixture 的模型、工具、消息、token spend 和 fixture 标记均为明确合成测试数据；真实 CLI 协议不等于真实账户或付费模型测试。

未导出登录凭证、Keychain 或 provider 凭证数据库；历史账户查询仅使用官方 CLI 接口。CLI 查询可能按其自身行为刷新外部缓存，不能据此证明 App 数据隔离。私有原始日志、会话、快照和账户输出不随本文公开；本次修改不代表旧公开 Git 历史已清除。

## 已有验收范围

| 范围 | 历史证据与限制 |
|---|---|
| 构建 | 最终 Debug exit 0；首轮只记录 `BUILD SUCCEEDED`，未独立捕获退出码，不补造退出码。编译不证明正式签名或启动。 |
| Swift adapter / gate | 假 CLI 故障注入、真实 OMP 离线 adapter、审批 payload、允许/拒绝、副作用、损坏/缺失 gate 的失败关闭及恢复。Supervised、Auto-accept edits、Full access、Plan、final-report 均有覆盖。 |
| RPC / native spawn | 并发会话、Unicode 逐字比较、取消/恢复；task、xd task、eval agent、workpool 正反例核对子模型请求。拒绝场景没有子请求。 |
| 模型与 effort | 官方 CLI 目录、当前选择和 effort 的一致性曾在私有记录中核对；隔离 HOME 与坏 JSON/非零 CLI 为故障注入。loopback 请求验证有效 model/effort 生效、无效选择拒绝且不启动模型请求。公开记录不保留账户数据。 |
| App 数据层 | CLI harness 以 `@testable import Tivano` 加载实际 `Tivano Dev.debug.dylib`，不调用 TivanoApp/SwiftUI 入口或 GUI 生命周期。使用实际 Library、Storage、DiskWriter、TokenLedger、AppModel、ThreadRuntime、registry 与 CLI dispatch。rehearse 事件和 ledger spend 明确为合成。 |
| Auto 降级 | 合成旧 library 由实际 AppModel bootstrap 降级为 Auto-accept edits；提示去重、保存和重载有证据。完整可见提示/菜单矩阵未覆盖。 |
| token 归属 | 合成 child agentID 不混入 lead turn；实际 ledger 保存并在新进程重载。该证据不代表真实账户用量。 |
| runtime / fork / resume | 实际 App 工厂 → OmpSession → OMP/MCP → Store，loopback 模型；重复提示词回退后创建不同 session，保存及进程恢复继续；活跃旧 gate 不被 peer 清除。附件、Plan/Hydra 注入的全部匹配组合未覆盖。 |
| 标题 / todo | runtime 备用命名不阻挡下一轮、不覆盖自定义标题；todo init/done/block 映射并持久化。adapter fixture 覆盖其他状态，不能称为全部真实 App GUI 状态通过。后续真实标题证据仅适用于其已执行范围。 |
| 用量解析 | 曾逐项对照官方 usage 的窗口、percent/reset 和 PlanLimitsReader dispatch；旧 report、重复 provider、clamp、过去 reset、限额错误均有故障注入。未故意耗尽真实额度，不宣称真实 quota exhaustion。 |
| MCP | 使用实际编译的 bridge/config 与本地 stdio server；检查双层审批、server call marker、文件、tool isError。MCP isError、JSON-RPC error、断连失败；成功内容引用 Error 仍成功；注册失败有诊断且无写文件。实际 runtime 错误工具行标为 `.failed`。 |
| CLI 更新归属 | 只读安装归属识别、私有 npm/bun 布局注入、unmanaged 边界、版本比较及官方 registry 查询。未执行全局 install/upgrade，不代表完整安装流程验收。 |
| Capture 隔离 | library/settings/MCP/gate/CLI session 位于各 run 的私有 root/HOME。绝对 preferences domain 的物理文件及第二 root 隔离、进程重载有证据；仅清理本任务早期自建 preferences，保留备份。 |
| 补充 GUI / Hydra | 来源补充记录的批准/拒绝完整轮次及云端 Hydra、独立副本/报告、Git 恢复通过；不推广为全部权限、全部语言或正式双 edition 生命周期通过。 |

历史离线矩阵规模保留如下，不涉及真实账户用量：28 个假 CLI 场景、
4 worker 共 40 次生命周期、12 个真实 OMP 离线 adapter 场景、50 个 gate 场景、
4 会话共 48 轮 Unicode 与 12 次取消/恢复、15 个独立 native spawn 进程。
native 正例 task/eval agent/workpool 分别为 5/5/4 个合成子模型请求，
12 个拒绝场景均为零子请求。MCP 当前来源矩阵为 17 个场景，另留旧基线复现。
这些都是来源记录的覆盖数量，不是本次修改后的实测数量。

## 已有修复与失败记录

1. MCP text-only bridge 将 `isError=true` 包装成文本后假报成功；原基线有复现。新增 `callResult(): {text,isError}` 后，OMP 真错误抛出；Pi/Command Code 保留文本 `call()` 协议。后续来源重测了错误与成功引用 Error 正例。
2. bridge 安装越过 Capture root；来源修复为 `StoragePaths.directory("MCP")`，正常 edition 路由保留，Capture 跟随其 root。
3. Capture defaults 的固定 suite 会交叉读写；hash suite 仍写用户 Preferences。来源最终改用 capture folder 内绝对 preferences domain，并验证物理位置与重载。
4. 无效模型 selector/effort 被静默忽略；来源在 start/send 前拒绝 malformed selector 和未知 effort，未知实际模型交官方 RPC 拒绝。
5. 无 GUI runtime 入口触发 `Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value`；来源将 NSApp 可见性、attention、dock badge 访问改为可选，随后无 GUI runtime 完成并持久化。

早期 NSApp 崩溃（exit -5）、harness actor 标注错误、CLI 不在 PATH、错误 todo 输入、快照时序不一致及错误地混同 runtime turn-spend 与 adapter ledger-spend 的运行均为失败，不计入最终通过。最终来源改用同 HOME/command 的新官方快照逐项比较，不放松断言。CLI 安装链接变化没有触发全局重装/更新；仅显式选取已有 binary。

## 权限与授权边界

| 工具 | Supervised | Auto-accept edits | Full access | Plan | final-report |
|---|---|---|---|---|---|
| 明确只读/报告白名单 | 允许 | 允许 | 允许 | 允许 | 拒绝 |
| 本地 write/edit | 询问 | 允许 | 允许 | 拒绝 | 拒绝 |
| bash/eval | 询问 | 询问 | 允许 | 拒绝 | 拒绝 |
| MCP/未知工具/未知 xd device | 询问 | 询问 | 允许 | 拒绝 | 拒绝 |
| task/native spawn | 拒绝 | 拒绝 | 仅 Hydra-off + allowTask 允许 | 拒绝 | 拒绝 |

Hydra-off 的非 Full access native spawn 直接拒绝；Hydra-on 禁 native spawn。gate handshake 未就绪不开始模型轮。`autoResume:false`、bash autoBackground/async 关闭、task recursionDepth 1；gate/MCP 环境变量只指向隔离文件，不记录凭证值。

初期无 GUI harness 不启动 App；后续 GUI 只在单独获得启动授权后执行。启动、退出、安装、打包、发布、push 与额度使用各有授权边界。缺既定 Developer ID 条件时不能用 unsigned/ad-hoc App 冒充 GUI 验收，也不导出 owner host 私钥。

## 复现参数与未验证边界

以下是供 lead 按授权运行的入口，本次没有执行：

```sh
export T08_OMP="<installed-omp-binary>"
# 默认输出与 DerivedData 位于 repository root 下 build.noindex/t08-acceptance。
python3 scripts/t08_checks.py --build-only
python3 scripts/t08_checks.py --omp "$T08_OMP"
python3 scripts/t08_integration.py
python3 scripts/t08_runtime.py
python3 scripts/t08_mcp.py --integration "<integration-artifacts>"
```

`T08_OUTPUT` 和 `T08_DERIVED_DATA` 可指定输出根与既有构建产物。
checks 的 `--package-cache`/`T08_PACKAGE_CACHE` 指定包缓存；`--progress`/`T08_PROGRESS` 可选，未给出时不读写私有进度报告。`--build-only` 只构建，不运行 CLI 场景或安装。

integration 默认使用新建 HOME、最小环境，不查询真实账户 models/usage/current state。
只有显式 `--real-account --account-home "<account-home>"` 才执行官方账户查询；
其原始输出留在私有 artifacts，禁止提交。其他 CLI 故障/空 HOME、Store/ledger/第二 root 场景仍独立执行。
MCP runner 以 `--baseline <commit>` 指定历史基线；若 Git 对象缺失，记录
`baseline unavailable` 并继续当前独立 case，不伪称基线通过。当前 case 通过不代表缺失基线已复现。

完整 TivanoApp 界面矩阵、正式签名与 Release/Dev 同时活动的目录隔离仍未完成；附件/Plan/Hydra 回退组合等超出已有范围的边界需单独验收。支持脚本及本次脱敏修改均待 lead 验证。文件名与合成 fixture 标记只是 fixture 标识，不是实际设备信息。
