# Tivano 2.0：飞书、钉钉与企业微信 CLI 接入提案

> **状态：已放弃本次实现（2026-10-20，owner 决定）。** 办公 CLI 卡片及安装检测的试作已丢弃，不随 2.0 合入。本文仅保留研究依据，不代表待执行需求；用户自行安装的 CLI 或自定义 MCP 不受此决定影响。

研究日期：2026-10-20。范围：当前任务副本源码、本机已安装技能、厂商及 Zcode 官方公开资料。本文只提出改动，不安装 CLI、不登录、不调用企业数据、不改 Swift；构建及业务验收留给 lead。

## 结论

| 厂商 | 推荐形态 | 理由与置信度 |
| --- | --- | --- |
| 飞书 / Lark | **(c) CLI workflow 为默认，独立 MCP 为可选高级入口** | 官方 `@larksuite/cli` 带技能，适合个人办公；另有 `@larksuiteoapi/lark-mcp`，可映射现有 stdio。两者不是同一个产品，也不共享“已连接”状态。高 |
| 钉钉 | **(b) CLI workflow** | 官方 `dws` 管理 OAuth/device flow、组织 profile 和技能。它调用上游 MCP，不等于它对 Tivano 提供 MCP server。高；“没有任何独立 MCP 服务”不作断言 |
| 企业微信 | **(b) CLI workflow** | 官方 `wecom-cli`、扫码初始化和领域技能已有完整入口；没有核实到可直接填入目录的官方 stdio server 命令或通用托管 URL。高（CLI）；中（MCP 接入口未找到） |

不要为了让卡片出现而把 `dws`、`wecom-cli` 或 `lark-cli` 填成 `.stdio`：stdio 在 Tivano 中意味着 JSON-RPC MCP server，不是“可运行命令”。CLI 登录中的 OAuth/device flow 也不能直接映射成 `.oauth(url:)`。

## 1. Tivano 当前实际能力

### Transport、目录与设置页

源码依据：`Tivano/Core/Models/MCP.swift`、`MCPCatalog.swift`、`MCPCustom.swift`，以及 `Tivano/App/Views/Settings/MCPSettingsPage.swift`、`MCPSetupPanel.swift`。

- `MCPTransport` 恰有三种：`.stdio(command:args:)`、`.http(url:headers:)`（Streamable HTTP）、`.oauth(url:)`（远端 MCP OAuth；Tivano 登录后经本地 `MCPProxy` 注入 token）。没有独立 SSE、CLI workflow、设备登录 transport。
- `MCPCustomServer.Kind` 只有 `stdio`、`http`；自定义编辑器没有 OAuth 选项。stdio 支持 args/env，HTTP 支持 headers。远端地址要求 HTTPS，仅 loopback 允许 HTTP。
- 目录支持字段 `.secret/.text/.path`、默认值、必填标识、args/env/header 中的 `{field}` 替换。现有分类为 developer/browser/search/**work**/data/cloud/knowledge；办公接入可复用 `.work`，不必增加分类。
- 设置页按分类呈现目录和已连接条目，另有自定义入口。连接依赖 probe 得到实际工具列表；`MCPSetupPanel` 只负责打开配置网页、显示步骤、再次 probe，不安装技能，也不是任意 CLI 登录终端。
- 连接元数据写 `Storage.root/mcp.json`，自定义定义写 `custom-mcp.json`，secret 字段源值存 Keychain。**不能据此声称所有派生配置都没有密钥**：`MCPProviderConfig` 会把 resolved env/header/args 写入 app 自己的 provider JSON；OAuth token 经 proxy 避免此问题，普通 stdio 的 App Secret 不享有同一保证。

### 条目如何到达各 provider

依据：`Services/MCP/MCPStore.swift`、`MCPProviderConfig.swift`、`MCPPaths.swift`、`MCPSessionOverrides.swift`、`MCPExternalSync.swift`、`MCPHub.swift` 及各 provider session。

安装目录项的实质是保存连接、解析字段、probe，再 `exportAll()` 生成会话配置，不是把 CLI/npm 包预装到每个 provider。

| Provider | 当前注入方式 |
| --- | --- |
| Claude | `Storage.root/mcp/claude.json`，`mcpServers`；启动 `--mcp-config <path> --strict-mcp-config`。stdio 为 command/args/env，远端为 type=http/url/headers |
| Codex | `mcp/codex.json` 的 `mcp_servers` 经 app-server config override；HTTP 用 `http_headers`，本地 command/args/env。已有 Tivano 连接时，用户自配的其他 server 仅在本会话被 enabled=false |
| Copilot | `mcp/copilot.json` 经 `--additional-mcp-config <JSON>`；本地 type=local，远端 type=http，tools=["*"]；额外用户 server 在本会话禁用，接 GitHub 时还禁用内置 MCP |
| Cursor、OpenCode、Grok、Devin、Kimi、DSH | `usesACP` 路径，在 ACP session 初始化传 `mcpServers`；允许 HTTP 的 agent 接收原生 HTTP，否则以 `npx -y mcp-remote <url>` 转成 stdio。env/headers 转 name/value 数组 |
| OpenCode 补充 | `MCPSessionOverrides.opencodeEnvironment()` 另生成 `OPENCODE_CONFIG_CONTENT`，映射 remote 或 local command 数组；不是编辑用户的 opencode.json |
| Antigravity | `mcp/gemini-settings.json`，远端键 `httpUrl`；通过 `GEMINI_CLI_SYSTEM_SETTINGS_PATH` 注入 |
| Command Code、Pi、OMP | 安装/加载 Tivano 的 MCP bridge，`loadMCPTools()` 注册工具；不是依赖这些 CLI 自动识别某个新配置文件 |
| Tivano Code（DeepSeek、Meta、Z.ai） | `OpenAICompatibleSession` 经 `MCPHub.tools()` / call，由 Tivano 自己连接 server |

`MCPExternalSync` 只清理旧版本有登记的 Cursor/OpenCode/Gemini 配置条目；当前不向用户全局 MCP 文件持续安装条目。上述是静态代码路径确认，不代表本次逐 provider 连通性验收。

### 已有 skills 功能的边界

已按任务要求搜索 `skill`。Codex 的 `skills/list` 获取已有技能，`SlashCommand.codexSkills` 解析 enabled/name/path，发送时能携带 skill item；Claude/Copilot/Command Code 能显示技能工具调用。DSH patch 配置其随包 skill 目录。

**未发现统一的技能商店、下载/安装/升级/卸载器或三家办公 CLI 配置向导。** 尤其 `PiCLI.swift` 和 `OmpCLI.swift` 启动参数含 `--no-skills`，不能假设往 `~/.agents/skills` 写文件后所有 provider 都能用。MCP bridge 的全 provider 覆盖不自动带来 CLI workflow 覆盖。

## 2. 厂商证据

### 飞书 / Lark（高）

官方仓库：[larksuite/cli](https://github.com/larksuite/cli)。包是 **`@larksuite/cli`**，可执行名 **`lark-cli`**，不要误用搜索结果中的 `@lark-org/lark-cli`。当前官方完整向导为：

    npx @larksuite/cli@latest install

纯 CLI 安装可用 `npm install -g @larksuite/cli@latest`；领域技能另用 `npx skills add larksuite/cli -y -g`。完整向导包含技能安装，不能将它展示成“只安装二进制”。[官方 README](https://github.com/larksuite/cli/blob/main/README.md)、[package.json](https://github.com/larksuite/cli/blob/main/package.json)。npm 包是原生程序分发入口，声明 darwin/linux/win32、x64/arm64 等平台，Node >=16、MIT；macOS 有明确支持，未核实官方 brew formula，不提供猜测命令。

认证：`lark-cli config init` / `config init --new` 配置或引导创建应用（App ID/App Secret）；`auth login --recommend` 或限定 scope/domain 完成用户 OAuth。`--as user` 代表本人；`--as bot` 用应用凭据，资源可见范围不同。分步流程 `auth login --scope <scopes> --no-wait --json` 返回 verification URL/device_code，随后 `auth login --device-code <code>` 完成；这不是 MCP HTTP 地址。

本机证据：`~/.agents/skills/lark-shared/SKILL.md`（version 1.1.0）及 `references/lark-shared-identity-and-permissions.md` 已存在，明确依赖 `lark-cli`、user/bot 区分、授权 URL 配二维码、业务成功信封 `ok == true` 和退出码 10 的高风险门禁。**只证明技能存在，不证明二进制、账号或 scope 已可用**。本次没有读取凭据。优先复用现有策展技能，不能全量覆盖。

独立 MCP：[larksuite/lark-openapi-mcp](https://github.com/larksuite/lark-openapi-mcp)，包 **`@larksuiteoapi/lark-mcp`**，MIT、Node >=20。官方命令：

    npx -y @larksuiteoapi/lark-mcp mcp

`APP_ID`、`APP_SECRET` 可经环境变量传入，默认 stdio；也支持自行部署 streamable/SSE，不能据此虚构厂商统一托管 URL。用户身份支持独立 login / `--oauth --token-mode user_access_token`，与 CLI 的登录缓存不能假定互通。[配置](https://github.com/larksuite/lark-openapi-mcp/blob/main/docs/usage/configuration/configuration.md)、[参数](https://github.com/larksuite/lark-openapi-mcp/blob/main/docs/reference/cli/cli.md)、[包要求](https://github.com/larksuite/lark-openapi-mcp/blob/main/package.json)。MCP README 提示文件上传下载、直接编辑文档存在限制，不能用它冒充 CLI 的完整办公能力。[能力边界](https://github.com/larksuite/lark-openapi-mcp/blob/main/README.md)

### 钉钉（高；直接 MCP 接入中）

官方仓库：[DingTalk-Real-AI/dingtalk-workspace-cli](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli)。包 **`dingtalk-workspace-cli`**，可执行名 **`dws`**，Apache-2.0。macOS amd64/arm64、Linux、Windows；有 npm、Homebrew 和 Releases 二进制：

    npm install -g dingtalk-workspace-cli
    brew tap DingTalk-Real-AI/dingtalk-workspace-cli https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli.git
    brew install dingtalk-workspace-cli

这是替代安装方式，不要全部执行。技能：`npx skills add DingTalk-Real-AI/dingtalk-workspace-cli -g`，或 `dws skill setup`（可选目标/mono/multi，具所有权与备份机制）。npm/升级可能安装或刷新全局技能；Zcode 明确因此优先官方 shell 安装器的 `DWS_NO_SKILLS=1` 模式，不能假设此变量也控制 npm postinstall。[官方中文说明](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli/blob/main/README_zh.md)、[Zcode setup](https://github.com/zai-org/zcode-plugins/blob/main/plugins/dingtalk-cli/skills/setup/SKILL.md)

认证：`dws auth login` 浏览器 OAuth；`dws auth login --device` 设备授权。默认身份是所授权组织用户，组织可能须管理员开启 CLI 访问；profile 使用稳定的 `corpId:userId`。自建应用支持完整 `DWS_CLIENT_ID`/`DWS_CLIENT_SECRET` 对；raw `dws api` 用内部应用 App Token，不读 OAuth User Token，也没有 Lark 式 `--as user/bot` 通用开关。[认证与参数](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli/blob/main/docs/reference.md)

架构文档明确 CLI 内部有 **MCP HTTP client**、产品路由与请求签名。未发现文档承诺 `dws mcp serve` 或可直接给通用 MCP client 使用的单一公开 URL；`DWS_<PRODUCT>_MCP_URL` 是产品端点覆盖，不能替代完整认证契约。因此当前不提 `.oauth(猜测地址)`。[官方架构](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli/blob/main/docs/architecture.md)

### 企业微信（高；直接 MCP 接入中）

官方仓库：[WecomTeam/wecom-cli](https://github.com/WecomTeam/wecom-cli)。包 **`@wecom/cli`**，可执行名 **`wecom-cli`**，MIT，Node >=18；明确 macOS x64/arm64、Linux x64/arm64、Windows x64。

    npm install -g @wecom/cli
    npx skills add WeComTeam/wecom-cli -y -g
    wecom-cli auth init

上游 README 将领域 skills 列为必需；若 Tivano 提供自己的完整 workflow，则可像 Zcode 一样把全套上游技能作为可选扩展。没有核实到官方 brew 安装方式，不编造 formula。[官方 README](https://github.com/WecomTeam/wecom-cli/blob/main/README.md)

`auth init` 默认扫码创建绑定；非交互可用 `--noninteractive`，手动模式 `--manual` 输入 Bot ID/Secret。它是机器人绑定/授权体系，不应描述为通用 CorpID/CorpSecret 接入，也没有证据支持 Lark 式 user/bot 切换或标准 OAuth device grant。`auth show --status` 必须整行等于 `authorized`；本地凭据存在不等于远端业务成功。[官方认证参考](https://github.com/WecomTeam/wecom-cli/blob/main/docs/cli-reference.md)

官方变更日志说明旧版曾消费 MCP 工具集，现有命令按服务端 schema 发现；这不证明 CLI 本身是 MCP server。此次 README/参考文档没有给出通用 MCP server stdio 命令或统一托管 URL，因此暂不增加 MCP 条目。[官方 CHANGELOG](https://github.com/WecomTeam/wecom-cli/blob/main/CHANGELOG.md)

## 3. Zcode 实际安装什么

官方 [Skill 文档](https://zcode.z.ai/cn/docs/skill) 和 [Plugin 文档](https://zcode.z.ai/cn/docs/plugin) 区分 skills 与 MCP：插件可以单独带 skills，MCP 是可选组件；技能可从外部 agent 复制/软链导入。当前目录清单见 [zai-org/zcode-plugins/marketplace.json](https://github.com/zai-org/zcode-plugins/blob/main/marketplace.json)。

直接读取三家插件清单、setup/cli 技能及仓库目录树后确认（高）：

| 插件 | 读取时版本 | 内容与安装边界 |
| --- | --- | --- |
| [lark-cli](https://github.com/zai-org/zcode-plugins/tree/main/plugins/lark-cli) | 0.1.2 | `.claude-plugin` / `.zcode-plugin` 清单 + `skills/setup`、`skills/cli`；setup 用 npm 纯 CLI 安装，避开默认全局技能向导；复用 profile，再按需配置应用和 OAuth |
| [dingtalk-cli](https://github.com/zai-org/zcode-plugins/tree/main/plugins/dingtalk-cli) | 0.1.1 | 同样两个技能；setup 优先仅 CLI 安装、组织/profile/OAuth 检查；上游领域 skills 另选 |
| [wecom-cli](https://github.com/zai-org/zcode-plugins/tree/main/plugins/wecom-cli) | 0.1.1 | 同样两个技能；setup npm 安装、扫码或本地手动凭据、状态检查；上游 skills 可选 |

三家目录均未见 `.mcp.json`，读取的插件清单没有 `mcpServers`。点击插件安装首先得到操作说明，不等于 CLI 已安装、已授权或业务可用。Bot Channel 是另一功能，不能用“机器人接 Zcode 会话”证明办公 CLI 的安装实现。

## 4. 代码草案（仅提案）

### 4.1 可复用现有模型的飞书 MCP 条目

以下是**应用身份的可选高级入口**，不是默认个人办公登录。采用环境变量避免 Secret 出现在 argv；但现有配置导出仍会落 resolved env，需先解决下述发布阻塞。示例工具暂空，待真实 tools/list 后填，避免拿 REST API 名猜 MCP tool 名。

    MCPCatalogEntry(
        id: "feishu",
        name: "Feishu OpenAPI",
        vendor: "Lark",
        summary: "Access Feishu resources as an app",
        category: .work,
        asset: "mcp-feishu",
        colorValue: 0x3370FF,
        transport: .stdio(command: "npx", args: [
            "-y", "@larksuiteoapi/lark-mcp", "mcp",
            "--token-mode", "tenant_access_token"
        ]),
        fields: [
            MCPField(key: "appID", label: "App ID", placeholder: "cli_…",
                     kind: .text, help: "Use a Feishu self-built app"),
            MCPField(key: "appSecret", label: "App secret", placeholder: "",
                     kind: .secret, help: "Copy the secret from your Feishu app")
        ],
        env: ["APP_ID": "{appID}", "APP_SECRET": "{appSecret}"],
        docsURL: "https://github.com/larksuite/lark-openapi-mcp",
        sampleTools: [],
        keysURL: "https://open.feishu.cn/app"
    )

对应 `Localizable.xcstrings` 至少需 zh-Hans：`Access Feishu resources as an app` →「以应用身份访问飞书资源」、`App ID` →「App ID」、`App secret` →「应用密钥」、`Use a Feishu self-built app` →「使用飞书自建应用」、`Copy the secret from your Feishu app` →「从飞书应用后台复制密钥」。先查现有键，避免重复。国际 Lark 需要另定域名/入口，不能混用中国应用凭据。

**没有钉钉、企业微信的 `MCPCatalogEntry` literal**：缺少经过核实的 MCP transport/endpoint，硬凑可编译条目会误导。二者应进入下面的 workflow catalog；CLI workflow 不应扩充 `MCPTransport`。

### 4.2 新增独立 CLI workflow 类型

建议 Core 增加 `CLIWorkflowEntry` / `CLIWorkflowState`，与 MCP 目录并列；字段含 id/name/vendor/summary/category/asset/colorValue/docsURL、executable、安装来源、技能来源与版本、认证命令计划。命令应以 executable + argv 结构表示，不拼 shell 字符串。以下为新类型设计示意，不是当前可编译代码：

    CLIWorkflowEntry(
        id: "feishu-cli", name: "Feishu CLI", vendor: "Lark",
        category: .work, asset: "mcp-feishu", colorValue: 0x3370FF,
        executable: "lark-cli",
        package: .npm("@larksuite/cli"),
        skillsRepository: "https://github.com/larksuite/cli",
        docsURL: "https://github.com/larksuite/cli"
    )
    CLIWorkflowEntry(
        id: "dingtalk-cli", name: "DingTalk CLI", vendor: "DingTalk",
        category: .work, asset: "mcp-dingtalk", colorValue: 0x0089FF,
        executable: "dws",
        package: .homebrew(tap: "DingTalk-Real-AI/dingtalk-workspace-cli",
            repository: "https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli.git",
            formula: "dingtalk-workspace-cli"),
        skillsRepository: "https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli",
        docsURL: "https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli"
    )
    CLIWorkflowEntry(
        id: "wecom-cli", name: "WeCom CLI", vendor: "WeCom",
        category: .work, asset: "mcp-wecom", colorValue: 0x2B7BD6,
        executable: "wecom-cli",
        package: .npm("@wecom/cli"),
        skillsRepository: "https://github.com/WecomTeam/wecom-cli",
        docsURL: "https://github.com/WecomTeam/wecom-cli"
    )

三种 workflow 的默认 `fields` 都应为空：凭据由各 CLI 原生流程处理，不把 App Secret、Bot Secret 或 OAuth token 收进通用聊天输入。可选 profile 选择应来自脱敏状态结果。自建应用高级路径再设计安全输入，不让用户误以为三家都需要 App ID/Secret。

### 4.3 最小落地范围与限制

1. **Core**：新增上述 workflow 模型/目录；复用 `.work`，不增加 MCP transport。状态至少区分未安装、已安装未登录、等待授权、缺管理员权限、已认证但业务未验证、可用、失败。
2. **Services**：新增 CLI 安装/版本/认证状态适配器；执行安装前展示命令、目标目录及技能副作用。复用现有二进制和凭据；更新保留来源、版本、所有权和覆盖预览，不覆盖现有全局技能。钉钉 brew 方案仍需检查安装副作用；不能仅据 npm 行为推断 brew。
3. **App**：新增 CLI workflows 设置区域和向导；复用 ChromeSection/Card/Row/SettingsSwitch 等现有组件。授权链接/二维码先展示再等待，支持取消、超时和重试；不要复用 MCP tools/list 作为 CLI 就绪标准。
4. **Provider 接入**：建立显式兼容表。首期可只支持能读取指定 skill 且能执行 shell 的 provider；Pi/OMP 的 `--no-skills` 需要明确的定向加载机制，不能直接删除以放开所有全局技能。API provider 也需技能索引/正文加载与命令执行路径；完成前 UI 标记不支持，不能沿用 MCP 的“每个 provider”承诺。
5. **凭据阻塞**：飞书 MCP 的 secret env 会被现有 `MCPProviderConfig` 序列化。若要求 Keychain-only，需另做运行时 secret 注入/桥接，或先不发布此高级条目；普通 env 字段不能伪装成已经安全完成。
6. **资产与本地化**：在 `Tivano/Resources/Assets.xcassets` 所采用的实际目录结构下增加 `mcp-feishu.imageset`、`mcp-dingtalk.imageset`、`mcp-wecom.imageset`（实施时定位现有 asset catalog）。以上颜色是品牌识别用蓝色草案，**不是已核实的官方色彩规范**；图标须取官方授权素材后核对色值和单色处理，不从第三方插件截图重绘。本任务未采集或添加图片。所有新增 UI 英文键补 zh-Hans。

## 5. Lead 后续验收与未决项

- 固定实际安装版本及 skill revision；确认 macOS Apple Silicon/Intel 安装、PATH、Node 依赖、取消安装及升级不覆盖用户策展内容。
- 三家各用一个实际组织做最小只读业务请求；分别覆盖已有登录、授权取消/过期、scope 不足、管理员未开通、多账号选择。不用本地 `authorized` 或退出码 0 代替业务成功。
- 飞书 MCP 若推进：验证 app 身份边界、实际 tools/list、各 provider 的 stdio/env 注入与派生文件密钥处理；用户身份 MCP 另做授权与缓存隔离设计。
- 钉钉/企业微信若要求直接 MCP：须由厂商给出公共端点、认证与客户端兼容契约，再补目录项；当前不能交付猜测 endpoint。
- 本文未运行构建、测试、CLI 安装或登录；未做 UI 看图验收。网页/仓库内容基于读取时的 main，会随上游变化。
- 历史上下文：通过 Nowledge CLI 搜索 thread `Tivano Zcode 飞书 CLI`，返回 0 条；结论来自本次源码和官方资料，不依赖未溯源记忆。
