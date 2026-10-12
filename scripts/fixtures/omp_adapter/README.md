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
| `omp_gate_stress.py --rounds 2` | 50 次真实 OMP gate 场景，同时检查审批次数、工具结果和文件副作用；含损坏/缺失 gate、Plan、final-report 与 `xd://` 双层审批 |
| `omp_offline_stress.py --rounds 3 --workers 4` | 4 个并发会话、48 轮；长 Unicode 逐字比对，12 次取消及随后恢复 |
| `omp_native_stress.py` | 15 个独立 OMP 进程；task、eval agent、workpool 的允许正例，以及 Full access/Hydra-on、Supervised、Auto-accept edits 的拒绝；直接 task 与 `xd://task` 均覆盖；拒绝必须没有子模型请求 |

真实 OMP 路径使用隔离 HOME 和项目目录，不继承用户凭证。native 场景的进程和模型服务器各自独立，避免前一轮 workpool 的异步请求进入后一轮计数。RPC 清理只终止本脚本创建的进程组。

`prepare.py` 将源码路径和 SHA-256 写入 `sources.json`。Swift harness 使用真实 `OmpSession`、`OmpCLI`、stdio/RPC、权限、快照和限额解析代码；替身仅包括 CaptureRun 存储根、TokenLedger 持久化、Hydra 提示文本、MCP 安装和模型目录的 Shell 调用。没有验证持久化集成、实际 MCP、登录/模型列表、额度接口或 GUI。

直接拒绝、`Error: Declined:` 包装、带堆栈包装、普通错误中引用拒绝文字及成功结果包含拒绝文字，均有独立适配器断言。拒绝首行通过现有本地化 key 查询，后续堆栈保留。命令行 harness 不证明 App 的中文渲染和界面行为。
