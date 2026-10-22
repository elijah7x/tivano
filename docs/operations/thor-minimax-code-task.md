# Thor：安装 MiniMax Code 并接入 Tivano

## 派发状态

- 任务标识：`minimax-code-20261021-hank-69deb4b2`。
- 2026-10-21：已通过 SSH 向 Thor 实际提交全文，tmux 创建成功，任务标识见上。此状态不代表实现或验收完成。
- 本机 SSH 配置：`thor` → `thor.tail84df1a.ts.net`，用户 `elijah`；实际返回 `Thor.local`、`/Users/elijah`。未使用历史 IP。
- 远端仓库：`/Volumes/ExHeart/forked/tivano/tivano.dev`；owner remote 当前为 `artemis:/Users/elijah-air/Universe/Oort/forked/tivano/tivano`，origin 为 GitHub Tivano，两者 push URL 均禁用。
- 现有执行入口：`/Users/elijah/.local/bin/thor-pi-sol61`，固定 Pi / `openai-codex` / `gpt-6.1-sol` / `xhigh`；沿用其路由，不读取账户或凭证。
- 任务资料目录：`/Volumes/ExHeart/forked/tivano/port-tasks/runs/minimax-code-20261021-hank-69deb4b2`。
- 预定任务分支：`build/minimax-code-20261021-hank-69deb4b2`；预定工作目录：`/Volumes/ExHeart/forked/tivano/worktrees/minimax-code-20261021-hank-69deb4b2`。以远端 startup 回执为实际创建证据。
- 本次准备 fetch 均成功（2026-10-21）：`owner/dev = 64e57cbb641a5a8a2b190af043273641caad2ccc`；`origin/main = c79838b9505d371e7b2748e5de25a0948a473136`。执行者仍须在任务开始 fetch 并回执实际基线；若 owner/dev 已变化，明确记录而非静默替换。
- Jupiter 的 `tasks/README.md` 与 `bin/task-worker.sh` 已读取。该旧入口会 push Jupiter 并发通知，本任务不用它，不写 Jupiter 状态或队列、不创建 LaunchAgent。
- 历史背景：主线程通过 Nowledge 检索到线程 `codex-01a158c5-56fa-7db1-96df-d9df23d3e560`，其中先前派发曾因只传标题而失败。派发 head 另以 nmem 定向检索 `MiniMax Thor`（无命中）；本次已传递本任务单全文。

## 完整执行指令（发给 Thor 的正文）

你是 Thor 本地实现者。用户明确授权只在 Thor 安装官方 MiniMax Code CLI，并给 Tivano 新增独立服务商接入。先读目标仓库 AGENTS.md、source-grounded 技能、现有 CLI adapter 和 session factory。直接完成下述范围，不再派给其他 Agent，不把 MiniMax API 或 Claude Code 的 MiniMax 后端配置当成此产品。

本任务特别限制优先于仓库的一般验证惯例：你和派发 head 都不得运行 build、test、lint、typecheck、性能脚本、GUI 验收或任何验收命令。不要运行 xcodebuild、quick_run.sh、package_local.sh、ship.sh，不打包、安装或启动 Tivano，不合入 dev、不 push、不发布、不触碰其他任务。只做官方 CLI 安装、资料/源码阅读、必要产品编辑和按下述约定提交。安装阶段读取包元数据记录版本和路径，不把 CLI 安装器退出成功当作功能验收。

### 1. 基线和任务隔离

1. 在上述远端仓库先 fetch origin（带 prune），再 fetch owner。网络失败立即写阻塞回执，不用缓存 ref 或 origin/main 替代 owner/dev。
2. 从这次取得的 `owner/dev` 建上述独立 worktree / `build/` 分支，记录完整 SHA、origin/main SHA、fetch 结果与时间。若 owner/dev 落后 origin/main 的实际代码树则报告，不能猜基线；历史已 squash 导致的非祖先关系不等同于代码树落后，说明判断证据。
3. 不在长期源 checkout 编辑。若同名 worktree/分支已存在，先报告，不 reset、不清除、不接管其他任务。不要改版本、CHANGELOG 或集成分支。
4. 当前主线程可能还有未合入 owner/dev 的适配相关差异。派发 head 未用 Git 检查其 worktree；不能宣称它与 owner/dev 相同。若遇缺失调用契约/前置改动，记录具体文件、符号和缺口给主线程，不猜测或混入其他分支。

### 2. 官方产品、安装和协议依据

资料读取日期：2026-10-21。官方资料会更新，安装后必须以包元数据版本及对应官方文档/源码对齐。网页中的 source preview、历史 npm 观察版本与 latest 可能不同，不把旧版本数字写死为当前安装结果。

- 产品：MiniMax Code 的独立终端 CLI，包 `@minimax-ai/code`，命令 `mcode`；官方仓库 [MiniMax-AI/minimax-code](https://github.com/MiniMax-AI/minimax-code)，与 `MiniMax-AI/cli` 通用多媒体工具不同。
- 官方 [Quick Start](https://agent.minimax.io/docs/cli/quick-start) 给出 macOS 安装器 `https://filecdn.minimax.chat/public/install.sh`，无需 sudo；官方 [README](https://github.com/MiniMax-AI/minimax-code/blob/main/README.md) 给出安装目录 `~/.minimax-code`、启动器 `bin/mcode`。只在 Thor 安装，先读下载的官方安装脚本，再按官方流程执行。不要安装猜测包或用源码构建代替预构建 CLI。
- 兼容 Node 已存在时，官方 npm 路径为 `npm install -g @minimax-ai/code@latest --registry=https://registry.npmjs.org/ --ignore-scripts=false --include=optional --allow-scripts=@minimax-ai/code,better-sqlite3`。按实际官方前置版本要求选择安装器或 npm；不要覆盖其他版本管理器或其他应用配置。
- [Headless and CI](https://agent.minimax.io/docs/cli/automation)：`mcode exec --cwd <workspace> --input - --output-format stream-json` 从 stdin 接收正文，不能同时加 positional prompt。stdout 为逐行、带版本的事件，stderr 为诊断。事件含 sequence 和 run/session/turn 标识，以及 exec、session、turn、item 生命周期；具体增量文本/工具字段须阅读安装版本对应类型，不能按名称猜 schema。未知事件应兼容处理。
- 同页规定结果 status 及错误/usage 可能缺省；必须同时处理结果状态和进程退出。SIGINT/SIGTERM/SIGHUP 可取消；会话恢复参数存在，但仅在 adapter 对应版本的路径成立时接入，不拿 TUI 的恢复能力替代 headless 证据。不能把未成功退出当作完成，也不能凭取消后 EOF 报成功。
- [ACP integration](https://agent.minimax.io/docs/cli/integrations)：`mcode acp` 使用 stdin/stdout 协议，诊断只进 stderr；可承载回复、工具状态、权限/问题、取消和模型控制。若现有 Tivano ACP 设施更适合，沿用它；不能为方便把自然语言直接写入 ACP，也不能默认放行权限。
- [Features](https://agent.minimax.io/docs/cli/features) 与 [Configuration](https://agent.minimax.io/docs/cli/configuration)：模型引用使用 provider/model，可带 variant；headless `--model` 是单次覆盖。API key 和 Token Plan 是不同认证来源，不能把 OAuth 未登录误判为 BYOK 无法使用。

### 3. Tivano 实现范围

从以下入口理解现有调用关系，按实际协议新增最小 adapter，只修改必要调用者：

- `Tivano/Core/Models/Provider.swift`
- `Tivano/Core/Models/ProviderSettings.swift`
- `Tivano/Services/Providers/ProviderRegistry.swift`
- `Tivano/Services/Providers/ProviderRegistry+CLIUpdates.swift`
- `Tivano/Services/Providers/ProviderSession.swift`
- `Tivano/App/Views/Settings/ProviderSelectionSection.swift`
- `Tivano/Resources/Localizable.xcstrings`

必须覆盖：服务商可见及可选、可执行文件发现（包括官方默认安装位置与现有路径配置）、安装状态、认证状态、模型选择、发送、流式输出、工具事件、错误呈现、取消与本任务子进程清理。安装与认证分开呈现，配置存在不等于已验证认证；可执行文件缺失、未配置认证、协议错误、服务端失败和取消不得混为一个成功状态。

恢复会话、MCP、用量、附件等额外能力只在所选协议及实际版本有官方依据时接入；不支持或未能确认的能力如实禁用并说明，不伪造 token、模型、会话 ID、工具结果或完成状态。不为补全列表实现未经证实的协议。保持其他服务商行为。

沿用现有 credential storage、进程生命周期、错误和 capability 模式，遵守四层依赖边界；Core 不依赖 UI/Services。UI 复用 ChromeSection、ChromeCard、ChromeRow、GlassPickerButton、ChromeVisualPicker、SettingsSwitch，不发明新风格。新增用户文案在 Localizable.xcstrings 用英文 key 补 zh-Hans，并读 docs/i18n/CONVENTIONS.md。新增源码必须按项目现有构建文件收录方式处理，但不运行构建。

### 4. 凭证边界

用户持有 API key，后续需要时会在主线程复制到剪贴板。现在不得读取剪贴板、扫描其他账户密钥、打开凭证文件内容，或把任何 key 放入任务单、命令参数、日志、Git、聊天。允许现有执行器按原有机制认证自己；不读取或复制其凭证，也不把其凭证用于 MiniMax。

先完成不需要 MiniMax key 的安装和适配，遇到认证/真实模型调用阶段停止该部分并报告。官方 [Configuration](https://agent.minimax.io/docs/cli/configuration) 支持 `mcode provider set-minimax-key --api-key-env MCODE_PROVIDER_API_KEY` 从进程环境读取 key；后续由主线程处理安全输入，不在本次运行。官方 [Examples](https://github.com/MiniMax-AI/minimax-code/blob/main/docs/examples.md) 推荐交互式无回显读取，再导出到该进程环境，而不是将值写进 shell 命令或历史。其 custom-provider `--api-key-env` 会把值存入 profile config.yaml，POSIX 文件权限为 0600，不能称为仅保存在环境或 Keychain；MiniMax 专用存储也需按安装版本源码确认，不自行改变 Tivano 凭证机制。首次真实发送、认证成功判断、在线模型/用量能力验证均需主线程提供凭证并执行。

### 5. 回执和交付

- 启动即在资料目录写 `startup.json`：确认读到完整任务正文、task ID、实际 base SHA、branch、worktree、执行器与时间。
- 阶段变化写 `progress.md`；阻塞写具体命令/错误并脱敏。不要创建后台轮询、watchdog、LaunchAgent 或定时通知；主线程会在当前会话继续跟进。
- 完成后仅提交本任务代码，一条普通 commit；返回分支和完整 commit SHA。后续打回用同一任务分支新增 commit，不 rebase/reset 已被主线程 fetch 的提交。
- `report.md` 写实际安装来源/包版本/路径、base/branch/commit、改动文件、协议选择与依据、已实现和禁用能力、何时需要凭证、全部未验证项。构建/测试/验收栏明确写“未运行，按任务限制由主线程执行”。不得把 exit 0 或文件生成等同于功能通过。
- 提供方安全拒绝或执行器失败即停止并报告；不自动换账号、模型、代理或重试以绕过拒绝。

## 主线程接续入口

派发回执：`status=submitted`；tmux 为 `impl-minimax-code-20261021-hank`。沿用现有执行器和 tmux 派发方式，`@task.md` 将完整任务单纳入首个 prompt；未只发送标题。Pi session ID 与任务标识相同，session 文件在本任务资料目录的 `sessions/`。首次传输在 Python 解析 stdin 时失败、未创建目录；随后使用 ASCII/base64 传输原始任务单字节，远端创建与提交成功，未重复启动 worker。

工作目录与执行者实际基线仍以 `startup.json` 为准；若该文件尚未产生，先看 runner 状态和 stderr，不能把 submitted 解释为实现者已完成准备。

已收到远端启动确认（`2026-10-21T03:20:21Z`）：`full_task_received=true`，host `Thor.local`，runner 为 `started`；实现者尚在 fetch，`base_sha/branch/worktree=null`，还未建 worktree。stderr 有新建 session 提示及 `openai/gpt-6-astra`、`openai/gpt-6.1-sol` 配置模式未匹配警告；固定执行器使用 `openai-codex/gpt-6.1-sol`，已实际写出启动回执，但不能据此宣称后续执行成功。主线程从此接续观察。

后续启动回执（`2026-10-21T03:20:54Z`）确认两次 fetch 成功，基线仍为 `64e57cbb641a5a8a2b190af043273641caad2ccc`，上述任务分支和 worktree 已创建。主线程读取回执时，尚无实现交付报告。

```sh
ssh thor 'cat /Volumes/ExHeart/forked/tivano/port-tasks/runs/minimax-code-20261021-hank-69deb4b2/runner-state.txt /Volumes/ExHeart/forked/tivano/port-tasks/runs/minimax-code-20261021-hank-69deb4b2/stderr.log'
ssh thor 'cat /Volumes/ExHeart/forked/tivano/port-tasks/runs/minimax-code-20261021-hank-69deb4b2/startup.json /Volumes/ExHeart/forked/tivano/port-tasks/runs/minimax-code-20261021-hank-69deb4b2/progress.md'
ssh thor 'cat /Volumes/ExHeart/forked/tivano/port-tasks/runs/minimax-code-20261021-hank-69deb4b2/report.md'
ssh thor 'tail -n 8 /Volumes/ExHeart/forked/tivano/port-tasks/runs/minimax-code-20261021-hank-69deb4b2/worker.jsonl'
```

主线程在其授权的集成 checkout 取回任务分支（派发 head 不执行）：

```sh
git fetch thor:/Volumes/ExHeart/forked/tivano/tivano.dev refs/heads/build/minimax-code-20261021-hank-69deb4b2:refs/remotes/thor/minimax-code-20261021-hank-69deb4b2
```

取回不代表合入；主线程审查并运行所有必要验证。未授权 push、发版、打包、安装或启动 Tivano。

## 主线程安装验证

2026-10-21，Thor 的安装包为 `@minimax-ai/code` 0.6.12，入口为 `/Users/elijah/.npm-global/bin/mcode`。主线程使用任务资料目录下 `lead-validation/` 中的独立 HOME 和 MINIMAX_DATA_DIR 验证，未读取账户凭证或发起模型请求：

- `mcode --version` 返回 `0.6.12`，退出码 0；`mcode acp --help` 正常退出。
- ACP `initialize` 返回协议版本 1 和 `minimax-code` 0.6.12。能力声明包括会话加载和恢复、HTTP/SSE MCP、图片输入；能力声明不等同于 Tivano 已适配或验收通过。
- 未配置凭证的 `session/new` 返回错误 `-32000`：`Authentication required: Run \`mcode login\` and try again.`
- 两次 ACP 验证的子进程均已退出。原始结果保存在远端 `lead-validation/`，后续产品代码构建和认证调用仍待完成。

## 实现取回与本机检查

Thor 已结束执行，提交为 `4d17f9819c3c1518814e275071b96b27b87145a8`，基线未变。主线程已 fetch 并把该提交的任务补丁应用到当前任务 worktree，未合入 dev、打包、安装或启动 Tivano。

主线程修正了模型目录刷新覆盖较新认证状态的竞态，并补齐离线 ShellResult 测试替身的 stdout 属性。Debug 构建通过；首次普通命令停在 SwiftTerm 插件验证，改用 docs/local-development.md 已记载的 `-skipPackagePluginValidation` 后成功，既有警告仍存在。

新增 `scripts/minimax_adapter_stress.py` 的 10 项离线场景全部通过；既有 ACP 选择、权限、取消和连续两轮共 4 项回归通过。32 个新增文案均有 zh-Hans，catalog 无重复 key。详细范围见 `docs/providers/minimax-code.md`。

## 中国站密钥与真实调用

2026-10-21，用户明确提供中国站 Token Plan 密钥并复制到剪贴板。主线程通过本地进程读取、SSH stdin 传输，在 Thor 子进程环境中交给官方 `set-minimax-key --api-key-env`；未将密钥输出、写入命令参数、日志或仓库。官方 setter 已将其保存在 Thor CLI 自有配置中，选择 API-key 路由；配置命令退出 0，presence metadata 显示该路由 active 且 hasApiKey。

- 原生 ACP 真实请求通过：`MiniMax-M3.1-Flash` thinking 模型返回指定文字，2 个文本增量，`end_turn`，没有工具请求，进程退出 0。证据：远端资料目录 `lead-live-20261021T041357Z/summary.json`。
- 当前生产 ACPSession、JSONRPC、StdioProcess 源码编译的独立 Swift 验证程序通过：读取 4 个模型选项，设置 `low` effort，首轮返回指定文字；关闭 CLI 后用原 session ID 加载，再次发送并正确回忆首轮指定文字。两轮各 2 个文本增量，没有工具请求或工具启动，连接全部关闭，验证程序退出 0。证据：`lead-adapter-live-20261021T041716Z/adapter-summary.json`。
- 两组测试合计发起 3 次模型请求。验证程序使用服务替身与空 MCP 配置，不等同于完整应用界面验收。

已无需用户再次提供密钥。界面截图及真实 MCP、工具/权限问答、取消仍未验收；权限模式设置和取消/异常处理已有上述离线覆盖。未合入 dev、打包、安装或启动 Tivano。
