# OMP 离线压测

在 T08 checkout 执行。需要 macOS、Xcode、Python 3 和已安装的 `omp`。不启动 Tivano，不使用真实模型额度；模型请求只到本地回环服务器。每次运行生成独立目录，保留日志和 summary，不覆盖前次证据。

调用签名按本机 OMP 18.8.0 的内置 `xd://eval/agents` 说明核对：`agent(...).wait(timeout)` 与 `workpool(...).push/peek`。gate 使用官方扩展的 `before_subagent_spawn` 与 `tool_call`，协议使用 RPC 的 `prompt_result`；参考 [扩展文档](https://github.com/can1357/oh-my-pi/blob/main/docs/extensions.md) 和 [RPC 文档](https://github.com/can1357/oh-my-pi/blob/main/docs/rpc.md)。当前 main 文档可能比本机 CLI 新，实际兼容性由本机压测确定。

按顺序运行，不与全量 App 构建并行，以免编译或 CLI 启动超时：

    python3 scripts/omp_adapter_stress.py
    python3 scripts/omp_gate_stress.py --rounds 2
    python3 scripts/omp_offline_stress.py --rounds 3 --workers 4
    python3 scripts/omp_native_stress.py

可给各命令传 `--output <artifact-directory>`。成功需要退出码为零且 summary 的 `passed` 严格等于 `true`；失败日志应保留，修复后用新目录重跑。适配器可用 `--fake-only` 单独执行故障注入。

| 脚本 | 覆盖 |
|---|---|
| `omp_adapter_stress.py` | 真实 Swift 源码：28 个假 CLI 故障/行为场景、4 worker 共 40 次生命周期、启动文件清理；12 个真实 OMP 场景，含审批、拒绝、会话授权、fork/恢复、Hydra task/eval 拒绝、todo 和命名 |
| `omp_gate_stress.py --rounds 2` | 50 次真实 OMP gate 场景，同时检查审批次数、工具结果和文件副作用；含损坏/缺失 gate、Plan、final-report 与 `xd://` 包装调用的单次审批 |
| `omp_offline_stress.py --rounds 3 --workers 4` | 4 个并发会话、48 轮；长 Unicode 逐字比对，12 次取消及随后恢复 |
| `omp_native_stress.py` | 15 个独立 OMP 进程；task、eval agent、workpool 的允许正例，以及 Full access/Hydra-on、Supervised、Auto-accept edits 的拒绝；直接 task 与 `xd://task` 均覆盖；拒绝必须没有子模型请求 |

真实 OMP 路径使用隔离 HOME 和项目目录，不继承用户凭证。native 场景的进程和模型服务器各自独立，避免前一轮 workpool 的异步请求进入后一轮计数。RPC 清理只终止本脚本创建的进程组。

`prepare.py` 将源码路径和 SHA-256 写入 `sources.json`。Swift harness 使用真实 `OmpSession`、`OmpCLI`、stdio/RPC、权限、快照和限额解析代码；替身仅包括 CaptureRun 存储根、TokenLedger 持久化、Hydra 提示文本、MCP 安装和模型目录的 Shell 调用。没有验证持久化集成、实际 MCP、登录/模型列表、额度接口或 GUI。

直接拒绝、`Error: Declined:` 包装、带堆栈包装、普通错误中引用拒绝文字及成功结果包含拒绝文字，均有独立适配器断言。拒绝首行通过现有本地化 key 查询，后续堆栈保留。命令行 harness 不证明 App 的中文渲染和界面行为。

## T08 App 集成入口

`Integration.swift` 与 `mcp_server.py` 中的 fixture 名称是合成
fixture 标识，不指向真实设备、账户或会话。合成模型仅请求本地回环服务器。

- `scripts/t08_checks.py --build-only` 仅构建，不运行压力场景、不安装或启动 App。
- `T08_OMP`（或支持该选项的 runner 的 `--omp`）指定已安装的 OMP binary。
- `T08_OUTPUT` 指定 artifacts 根，默认是 repository root 下 `build.noindex/t08-acceptance`。
- `T08_DERIVED_DATA` 指定构建/读取 Debug 模块的 DerivedData，默认为 output 根下 `DerivedData`。
- checks 的 `--package-cache` / `T08_PACKAGE_CACHE` 指定 SourcePackages；默认在 output 根下。
- checks 的 `--progress` / `T08_PROGRESS` 可选；未给出时不读取或写入外部报告。

先由 lead 按授权构建，再运行 integration、runtime，最后将 integration 输出的
artifacts 目录传给 MCP runner 的 `--integration`。integration 默认创建私有 HOME
并只继承 PATH 等最小环境，不导入登录 shell、API key 或真实账户缓存。
默认 CLI 场景覆盖空 HOME、失败注入、私有安装布局和无效选择；账户目录、
当前模型、usage、真实安装归属和在线 registry 查询跳过，summary 明示缺口。

真实账户查询必须显式使用：

```sh
python3 scripts/t08_integration.py --real-account --account-home "<account-home>"
```

该模式只使用指定 HOME 与最小环境；依赖额外环境变量凭证的账户不在其范围内。
输出可能包含账户模型、provider 与额度信息，必须保留在私有 artifacts 中，不能提交。
它不授权付费模型请求、全局更新、App 启动或安装。

MCP runner 支持 `--baseline <commit>`。缺少历史 Git 对象时记录
`baseline unavailable`，继续独立当前 case；baseline 的失败另列，当前 summary
的 `passed` 仅代表已执行的当前 case，不代表旧缺陷已复现。
历史记录使用 OMP 18.9.1；其他安装版本与本次参数调整的兼容性由 lead 验证。
以上入口没有 test target，也不构成正式签名 App 的 GUI 验收。
