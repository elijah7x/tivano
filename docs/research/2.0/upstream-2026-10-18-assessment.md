# 2026-10-18 上游报告对 Tivano 2.0 的影响评估

评估日期：2026-10-20。依据主检出的 `reports/upstream/2026-10-18.md` 与 `2026-10-16.md`，逐项对照本任务副本源码。以下行号属于本副本，不能照搬巡检报告的旧行号。只做源码阅读与明确要求的 OpenCode 输出采集，未构建、测试、升级 CLI 或启动 Tivano。

结论：OpenCode 凭据探测存在确定缺口；Z.ai key 引导和 Command Code 额度错误展示需要修订。omp 模型发现会受上游修复改善，但报告称扩展层完全不经 Tivano 的判断不成立。其余项目未发现这次更新导致的确定协议破坏；“否”只指报告所述变更，不代表全部版本兼容性已验收。

## 逐项评估

下表路径以仓库根为基准；`Providers/` 是 `Tivano/Services/Providers/`，`Models/` 是 `Tivano/Core/Models/`。优先级是本评估建议。

| 项目 | 是否影响 Tivano | 证据 file:line | 建议变更 | 优先级 |
| --- | --- | --- | --- | --- |
| OpenCode V2 `auth list` 表格输出（两期高风险） | 是 | `Providers/ProviderRegistry.swift:1182`、`:1227`、`:1232`；本次两种管道输出采集 | `auth` 同时解析旧 `●` 行与三列表格，按来源列排除环境变量行 | 2.0 前必须 |
| OpenCode Console Go 凭据签发、`opencode/` / `opencode-go/` 前缀 | 不确定 | `Models/Provider.swift:39`、`:61`；`Providers/ACPSession.swift:519`、`:520` | 单 provider 接收 CLI 模型 ID，无需再拆 Zen/Go；服务端签发故障不能靠客户端改前缀修复，尚无本次账户验证 | 2.0 后 |
| Z.ai Standard / Individual / Team key 分离、到期语义 | 是 | `Models/ZaiRegion.swift:25`、`:29`；`Tivano/App/Views/Settings/SettingsView.swift:938`；`Providers/ZaiSession.swift:75`、`:79`、`:83` | 明确本入口使用 Coding Plan key；补充到期不转按量计费；保留现有端点与 reset API | 2.0 前必须 |
| omp 18.12.0 稳定 catalog、18.11.2 模型名回退 | 是 | `Providers/OmpCLI.swift:22`、`:29`、`:41`、`:55`；`Providers/ProviderRegistry.swift:838` | 排期升级并由 lead 验收；不改 JSON 字段解析，避免把上游空目录误判为 Tivano parser 破坏 | 2.0 后 |
| omp 18.11.2 `usage` AI-credit 单位修正 | 否 | `Providers/PlanLimits.swift:68`、`:81`；`Providers/OmpSession.swift:587`、`:619` | Tivano 不调用 `omp usage`；读取 RPC token 字段，不消费 Premium Requests 文案，无 parser 变更 | 不处理 |
| omp 18.11.3 Bun 请求挂死、SSE 255s；18.12 压缩变量 | 是 | `Providers/OmpSession.swift:154`、`:170` | 会话依赖 CLI 的请求实现，修复可能改善挂起；属于 CLI 升级收益，不需改 Tivano framing 或 usage parser | 2.0 后 |
| omp extension host breaking、“库/扩展层不经 Tivano” | 不确定 | `Providers/OmpSession.swift:154` 明确 `-e`；`Providers/OmpCLI.swift:161`、`:189` | 修正巡检断言；升级前核对扩展入口、工具审批回调和 rpc-ui 事件。不能据此直接宣称已破坏或无需验收 | 2.0 前必须 |
| omp² / Rust 渐进迁移（含基线预告） | 否 | `Providers/OmpCLI.swift:59`；`Providers/OmpSession.swift:154` | Swift 经 CLI/RPC 集成，不链接 TypeScript/Rust 内核；继续跟踪 CLI/扩展契约，不根据实现语言改代码 | 不处理 |
| Command Code live 模型列表 | 否 | `Providers/CommandCodeAPI.swift:183`、`:194`、`:202`、`:225`；`Providers/ProviderRegistry.swift:203`、`:807`、`:843` | 模型增删本身可接受；缓存和未知 ID 边界见下文，建议后续加固而非重写 parser | 2.0 后 |
| Command Code 新 credit 文案、基线 per-model credits | 是 | `Providers/CommandCodeSession.swift:441`、`:468`、`:486`；`Providers/CommandCodeAPI.swift:168` | 保留 CLI 原始错误，避免把续费处理中改写成“充值或等月度重置”；额度读取仍走 billing API，无模型额度协议变更证据 | 2.0 前必须 |
| DeepSeek Flash-1017、Pro 路由不明、Search & Fetch | 不确定 | `Providers/ProviderRegistry.swift:279`；`Providers/DeepSeekAPI.swift:54`、`:60`、`:62` | `deepseek-flash` 已可接收新快照；不虚构 V4.1-Pro ID。Pro 实际后端无法由 ID 判定，建议淡化“Best”宣传，保留兼容 ID；不接入无关 Search & Fetch | 2.0 后 |
| Claude Code 2.1.302 默认 permission mode | 否 | `Providers/ClaudeSession.swift:89`；`Providers/TextGeneration.swift:81` | 会话及辅助文本请求均显式传 mode，不受缺省变化影响 | 不处理 |
| Claude 基线 auth 刷新 bug / 模型别名 | 否 | `Providers/ProviderRegistry.swift:1191`、`:1193`、`:922` | 报告已记本机升到修复版；Tivano 读取 `loggedIn/email`，模型来自 handshake，无需硬改别名；未重新核验本机 Claude 版本 | 不处理 |
| Codex 稳定版 / 可选 MCP 字段 / WebSocket zstd | 否 | `Providers/ProviderRegistry.swift:1185`、`:1189`；`Providers/CodexSession.swift:715` | login 文本匹配与 stdio app-server 路径不受报告所述变化影响；无须切换传输 | 不处理 |
| pi 1.3.0 / 基线包迁移、Azure/主题/Kimi 配置 breaking | 否 | `Providers/PiCLI.swift:63`、`:87` | 模型通过 `get_available_models` 动态读取；报告未指出该 RPC 变动，用户 CLI 配置迁移不等于 Tivano 协议迁移 | 不处理 |
| ACP v1 增量 / v2 alpha | 否 | `Providers/ACPSession.swift:185`、`:387` | 显式协商 protocolVersion 1；不提前切到 v2，新增能力单独排期 | 不处理 |
| Cursor CLI 无新条目 / 基线 status 与 Watching | 否 | `Providers/ProviderRegistry.swift:1195`、`:1199`；`Providers/ACPSession.swift:109` | 现有 status 与 ACP 路径继续使用；公开 notes 空白不是兼容性证明，但无具体需改项 | 不处理 |
| Grok 1.0.62、公开 notes 滞后 | 不确定 | `Providers/ProviderRegistry.swift:1242`、`:1245`、`:1246`；`Models/Provider.swift:201` | 嵌套 auth.json 已按 `root.values` 兼容；未知闭源版本 ACP 行为仍需 lead 实测，不能用“无 notes”判无影响 | 2.0 后 |
| Devin 无新版本 / 本机落后 / ACP 修复 | 否 | `Providers/ProviderRegistry.swift:1202`、`:1259`；`Providers/ACPSession.swift:121` | `auth status` 的 `Name:` 和 `devin acp` 有对应路径；报告未给新破坏，CLI 升级另行安排 | 2.0 后 |
| Kimi 2.2.0 / NotifyUser 与 executor 移除 | 否 | `Providers/ProviderRegistry.swift:1220`；`Models/Provider.swift:201` | ACP 仍是集成面；所述默认关闭通知和废弃配置无报告证据要求本次改动 | 不处理 |
| Copilot canary / 基线模型 canonical ID | 否 | `Providers/CopilotSession.swift:400`；`Providers/ProviderRegistry.swift:835` | live 列表接收上游模型 ID；不因 canary 替换警告或 settings.json 的用户配置迁移修改集成；未安装实测未补做 | 不处理 |
| Antigravity 1.4.1 与基线基础模型名 | 否 | `Providers/AntigravitySession.swift:389`、`:409`、`:441`；`Providers/ProviderRegistry.swift:519` | 继续解析 TSV、拆 effort；私有 settings 注入仍是存量风险，不是此次格式变化 | 不处理 |
| Meta muse-spark / models.dev schema 增量 | 否 | `Providers/MetaAPI.swift:46`；`Providers/ProviderRegistry.swift:914`；`Providers/ACPSession.swift:519` | Meta ID 保持；OpenCode 目录经 ACP 间接取得，不直接解码 models.dev 新 schema | 不处理 |
| 仓库漂移：Zen/Go 分列旧文 | 不确定 | `docs/providers.md:37`；`Models/Provider.swift:39`；目标 `docs/upstream-watch.md` 缺失 | 提供替换段落；无法原文引用旧段，必须由 lead 找到实际文件后补引文 | 2.0 前必须 |
| 仓库漂移：Claude / OpenCode 旧行号 | 是 | `Providers/ClaudeSession.swift:89`；`Providers/ProviderRegistry.swift:953`、`:1232` | 后续报告把 OpenCode `●` 位置更新为 1232；953 当前是 API catalog 日期存储代码块，不再是 auth parser | 2.0 后 |

## 确定影响项的精确变更建议

### 1. OpenCode：保留旧格式，同时接受逐行三列表格

唯一 `auth list` 人类可读凭据解析位于 `ProviderRegistry.auth(_:_:_:)` 的 `.opencode` 分支，当前为 1226–1240 行。1232 行 `hasPrefix("\u{25CF}")` 会过滤掉本次所有表格行，命令成功便返回 `.signedOut`。这是本地可复现的格式与实现不匹配，未启动 Tivano 做 UI 复现。

采集使用 PATH 中的本地 `opencode`。`opencode auth list` 和 `opencode auth list | cat` 均通过 subprocess 管道运行，退出码均为 0；二者格式一致。没有采集真实 TTY，不把直接命令的非 TTY 结果误称为 TTY 验证。未输出、保存任何 key 或账户值。脱敏结构如下，列之间是至少两个空格，没有表头、边框或 `●`：

```text
<provider display name>     API key                  stored
<provider display name>     <environment var name>   environment
<provider display name>     <environment var name>   environment
<provider display name>     API key                  stored
```

第一列显示名可含空格（本次包含公开产品名 OpenCode Go）；第二列 `API key` 也含单个空格。第三列标明 `stored` 或 `environment`，且两类行混排。不能简单按空格 split，也不能在第一条 environment 行停止，否则漏掉后面的 stored 行。本次未重新读取 CLI 版本，因此不将 10-18 报告的 v2.0.18 写成本次版本测量。

建议仅替换该分支 1229–1238 的提取部分，抽为纯解析函数便于 lead 验收：

1. 保留 1228 的 ANSI 清理；失败退出先返回 `.unknown`，不要让错误输出中的形似数据行判为已登录。
2. 旧格式：逐行去首尾空白，识别 `●`，保留现有移除 ` api` / ` oauth` 后缀逻辑；只在明确旧格式的 Environment 段标题之后忽略旧 bullet，不能用全局 `prefix` 截断混排表格。
3. 新格式：以连续两个以上空白或 tab 为列界，要求恰好三列；第一列非空，第三列大小写归一后为 `stored`，第二列为明确凭据类型（本次 `API key`；OAuth 类型需用上游 fixture 核对可接受拼写）。按第一列返回显示名，不依赖 `opencode` 的大小写或只允许 Zen/Go。
4. 第三列为 `environment` 的行跳过，继续读后续行，维持当前“持有存储凭据才算登录”的语义；未知列/未知来源不冒充凭据。
5. 合法凭据非空 → `.signedIn(firstName)`；命令成功但无凭据 → `.signedOut`；未知非空格式建议 `.unknown`，区分未登录与 CLI 协议变化。空目录成功输出需要独立 fixture 确认。

其他 OpenCode 输出消费：`ProviderRegistry.version`（1172–1179）提取版本号；`openCodeCatalog`（908–919）走 ACP；`ACPSession` 在 519–533 行读取 `availableModels/modelId/name`，546–573 行读取 config options；`CLIUpdates.unmanagedVersion`（620–640）是版本探测。它们不解析 `auth list` 表格，无需随本修复改动。旧 `opencodeGo` 存储值在 `Provider.swift:39` 归一，模型 ID 的 Zen/Go 前缀应原样保留。

交给 lead 的验收输入应包括旧 bullet、三列表格、stored/environment 混排、ANSI、带空格显示名、空列表、非零退出和陌生格式；本任务不执行这些检查。

### 2. Z.ai：改引导与错误解释，不擅自改计费路由

`ZaiAPI.swift:7` 固定 Coding Plan `/api/coding/paas/v4`；`ZaiRegion.swift:18–25` 按 Global / China 选 host。quota/reset 在 `ZaiAPI.swift:10–12`。本次报告没有它们改址的证据，不建议更换 endpoint 或增加到期自动 fallback。当前代码没有自动转 Standard 的逻辑，应保留。

具体建议：

- `SettingsView.swift:938` 的通用“只需 API key”说明对 Z.ai 增加专门说明，放在已填 key 后也能看到的位置：**“此入口使用 GLM Coding Plan。请使用对应计划的 API key；Standard API key 的计费类型不会因切换 endpoint 而改变。已有兼容 key 无需仅因本次管理调整而更换。”**
- `ZaiRegion.swift:29` 目前是通用 key 管理页面；先核对官网当前计划 key 入口再改链接，不能凭公告摘要猜新 URL。China host 的政策与链接需独立核验，不能把国际站公告自动套到智谱国内账号。
- `ZaiSession.friendlyError` 的 75–80 行：无计划错误应同时提示核对 key 类型；到期错误建议改为 **“GLM Coding Plan 已到期，请续订后重试。此入口不会自动转为按量计费；Standard API 需要单独创建 Standard key，并使用支持 Standard API 的入口。”** 不暗示当前 Tivano 的 Z.ai 入口已支持 Standard。
- 83–84 行只要含 enterprise 就要求换个人 key，可能过度概括新 Team Plan；没有 Team 支持证据前，不直接放开，也不宣称全部 Team key 无效。保留服务端错误细节，提示核对账号套餐/key 类型。
- 新用户可见英文 key 与 zh-Hans 翻译一起进入 `Localizable.xcstrings`。只改说明，不改变认证失败与额度耗尽的分类。

公告原链接为 [Z.ai key 管理公告](https://docs.z.ai/devpack/notice/api-key-management)；本次网页读取失败，政策细节以用户提供的 10-18 报告为依据，不声称重新核实了公告原文。

### 3. omp：升级收益与扩展风险分开处理

`OmpCLI.catalog` 调用 `models --json --no-extensions`（55–67 行），要求顶层 `models` 数组；`listModels` 读取 `provider/id/name/thinking`，缺 name 回退 id。`authStatus` 同样读 catalog，所以账号轮换造成空目录还可能表现为未登录。18.12.0 的稳定读取修复直接利好这两条路径，但没有字段变更证据需要改 parser。[官方 v18.12.0 notes](https://github.com/can1357/oh-my-pi/releases/tag/v18.12.0) 确认 `keys.peek()` 稳定账号选择与请求压缩变量调整。

Tivano 不调用 `omp usage`；`PlanLimitsReader` 明确排除 omp。会话用 `OmpSession.reportContext` 的 `contextTokens/totalTokens`（587–589），及消息 `usage.input/output/cacheRead/totalTokens`（619–629），不是 CLI 用量面板的单位标签。因此 18.11.2 单位修正无需 Swift 改动。Bun/SSE 修复属于 CLI 内请求可靠性收益，安排升级即可，不新增本地超时补丁。

但会话用 `--mode rpc-ui ... -e <extension>`（`OmpSession.swift:154`），`OmpCLI.swift:161` 标注自带扩展基于 18.8.0 契约。因此必须删去巡检“extension host 协议不经 Tivano 路径”的绝对判断。建议替换为：**“目录发现禁用扩展，字段格式未见变化；实际聊天加载 Tivano 自带扩展，extension host 变更需核对审批 gate、MCP bridge 和 rpc-ui 事件，尚未证明不受影响。”** 本次未升级或调用 omp 会话，不能给出通过结论；lead 在决定 2.0 支持版本时完成这项兼容性确认。

### 4. Command Code：动态列表可读，额度说明可能丢失

`CommandCodeAPI.parseModels`（194–233）不依赖固定列表或固定 Planning/Implementation 模型，按 `<id><至少两个空白><description>` 解析。配置模型缺席时不会强行插回，成功 live 列表替换缓存。未知 ID 仍须包含 `-` 或 `/`（208），effort/context 元数据有静态表，因此“所有未来格式都兼容”不成立，但报告只给出列表内容变化，尚无格式破坏证据。

缓存 TTL 为六小时（`ProviderRegistry.swift:203`），但成功读取后 `attemptedCatalogs` 的 807 行短路意味着同一次运行里不会仅因六小时到期自动再读，需 force 刷新或下次运行。失败/空列表保留旧 catalog（843–850）；这是降级策略，会暂留已退役模型。建议 2.0 后将成功尝试门槛与 TTL 协调，并处理已选模型退役提示；这不是本次发现的启动阻断。

确定需改的是 `CommandCodeSession.friendlyError`（486–494）：命中 `insufficient credits` / `out of credits` 时覆盖原文，新“续费支付处理中”细节可能因此消失；退出码 10（468–469）无条件固定文案，也丢弃 stderr。

最小修改建议：额度分支保留非空原始错误，只在完全没有信息时给通用提示；退出码 10 按 `runError`、`tail`、通用 fallback 的顺序展示。若需要统一前缀，附原文而非覆盖它；不要把支付处理中当作瞬时 rate limit 自动重试。对应 fallback 与 zh-Hans 同步。模型 parser 无需为 v1.83 列表增删改白名单。

本次可访问 [Command Code changelog](https://commandcode.ai/changelog)，但未实测 cmd 错误载荷；上述覆盖风险由本地控制流确定，具体新文案命中哪一分支仍需 lead 的 fixture 确认。

### 5. 报告定位修正

下一次巡检将 OpenCode `ProviderRegistry.swift:953` 改为当前 `auth` 分支 1226–1240（关键条件 1232）。Claude 的 89 行仍有效。引用应带函数名，避免新增代码后旧行号继续误导。

## `docs/upstream-watch.md` 集成面替换稿与缺失项

本副本与主检出 `/Users/elijah-air/Universe/Oort/forked/tivano/tivano/docs/upstream-watch.md` 均不存在该文件。因此无法按要求逐字引用旧 Zen/Go 段落；不能把报告转述伪装成原文。仅能准确引用 10-18 报告中的描述：

> `docs/upstream-watch.md` 的「集成面」小节仍是 Zen/Go 分列的旧描述，需要刷新

这不是目标文档的原文。该项尚未完成，需 lead 提供实际旧文件或定位移动后的路径。本任务不新建、不编辑目标文档。

依据 `docs/providers.md:37` 与当前代码，建议替换段落：

> **OpenCode**：Tivano 只有一个 OpenCode provider，使用用户在 OpenCode CLI 中配置的全部服务，包括 Zen、Go 和其他 provider。Zen 与 Go 的模型分别保留 CLI 返回的 `opencode/`、`opencode-go/` ID 和显示名称；不按前缀筛掉其他模型。认证通过 `opencode auth list` 检测存储凭据，需兼容旧 `●` 行和 V2 三列表格，并区分 environment 来源。模型与 reasoning 配置经 ACP 动态探测；现有 `opencodeGo` 存储值迁移为 `opencode`。

## 范围与未验证事项

- 两份巡检报告均从用户指定的主检出绝对路径读取；源码证据来自本任务副本。未把报告中的本机版本当成本次实测。
- Nowledge CLI 定向 thread search：`Tivano OpenCode auth list`，limit 3，返回 0 条；没有历史结论替代源码依据。
- 未构建、运行测试、验收脚本或启动 App；未改 Swift、版本、CLI 安装与认证数据。OpenCode 只采集输出格式；没有真实 TTY 与空凭据环境样本。
- Grok 闭源版本差异、DeepSeek Pro 实际路由、Z.ai 国内/Team key 支持与 omp 扩展兼容性仍不确定。

## 2.0 前阻塞项

1. 修复 OpenCode 三列表格凭据探测，并由 lead 验收旧/新格式及混排环境行。
2. 补齐 Z.ai Coding Plan key 类型与到期说明，避免错误 key 引导；保留现有计费路由。
3. 保留 Command Code 额度错误的原始细节，避免误导正在续费的用户。
4. 确定 2.0 支持的 omp 版本，并补齐 Tivano 自带扩展兼容证据；目前是验收缺口，不是已证实 breaking。
5. 找到实际 `upstream-watch.md`，补录旧段引文并应用集成面替换稿；目前是文档输入缺失，非运行时阻断。
