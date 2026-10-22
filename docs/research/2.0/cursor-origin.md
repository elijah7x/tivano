# Cursor Origin forge 支持研究

研究日期：2026-10-20。范围：当前任务副本的静态代码、官方公开资料、本机 CLI 帮助与无凭据 HTTP HEAD。未改 Swift，未构建、测试、push/fetch、创建或合并 PR，也未验证账号当前权限。

## 结论

**建议新增 `.cursorOrigin`，优先接入独立的 `origin` CLI。** Origin 已有 PR 创建、合并和公开 REST API；“没有 PR API，只能打开网页”不成立。现有 `.gitea` → `tea` 路由没有兼容性依据。官方 PR 地址是 `https://cursor.com/codebase/{owner}/{repo}/pull/{number}`，既有链接解析器也需要修改，否则只修创建命令仍会卡住 Hydra 合并。[高；官方 API](https://cursor.com/docs/api/origin)、[高；CLI 文档](https://cursor.com/docs/origin/cli/reference/pull-requests)、[高；本地模型源码](../../../Tivano/Core/Models/MergeRequestLink.swift)

这里的“高”表示官方契约或直接观察明确，不表示已完成 Tivano 端到端验收；“中”表示有依据的工程推断；“低”表示尚待证实。下文设计与工期均为建议，不冒充现有能力。

## 1. Origin 是什么、现在提供什么

| 事项 | 发现与置信度 | 来源 |
| --- | --- | --- |
| 产品定位 | 高：Cursor 自有 Git forge；2026-08-17 开始 early beta，包含仓库、PR、代码浏览和 GitHub 同步。原生 Origin 仓库以 Origin 为事实源，不经 GitHub。 | [发布说明](https://prod.cursor.com/changelog/origin-code-hosting)、[概览](https://cursor.com/docs/origin) |
| PR 网页 | 高：有 PR 列表、创建与审阅流程；分支先 push，再从仓库页面创建。GitHub 镜像仓库与原生 Origin 仓库不能混为一谈，官方说明镜像上的 cloud agent 会创建 GitHub PR。 | [Pull requests](https://prod.cursor.com/docs/origin/pull-requests) |
| CLI | 高：`origin` 是独立工具，不是 Cursor Agent CLI 的子命令；有 `pr`、`repo`、`auth`、`ssh-key`、`api`。 | [命令参考](https://cursor.com/docs/origin/cli/reference/commands)、本机帮助（下节） |
| REST API | 高：公开接口基址为 `https://api.cursor.com/v1/origin`，支持仓库、PR 创建和合并。不能因 `origin.cursor.com/api/v1` 不通就判定没有 API。 | [API 参考](https://cursor.com/docs/api/origin) |
| HTTPS 认证 | 高：`origin auth login` 浏览器登录并设置 Git credential helper；也支持 API key 登录。 | [命令参考](https://cursor.com/docs/origin/cli/reference/commands) |
| SSH 认证 | 高：支持登记 SSH 公钥，`origin ssh-key add <pubkey> -t <title>`。SSH Git 可用不等于 PR CLI 已登录。 | [命令参考](https://cursor.com/docs/origin/cli/reference/commands)、本机 remote 观察 |
| API 认证 | 高：用户 access token 或 app installation token；个人 API key 需交换成短期用户 token，不能直接作为 Origin API Bearer 使用。 | [API 认证说明](https://cursor.com/docs/api/origin) |
| Gitea / Forgejo 兼容性 | 中：未找到官方兼容声明，现有公开 API/CLI 契约不同，不应复用 `tea`。底层是否使用其代码未知（低），404 不能证明底层实现。 | [Origin API](https://cursor.com/docs/api/origin)、下节无凭据探测 |
| 近期演进 | 高：10 月官方 changelog 已描述 Origin App Marketplace 与 app JWT、installation token 集成；不能沿用早期“只有托管，无 API”的假设。 | [2026-10-13 changelog](https://cursor.com/changelog) |

官方论坛也检索到 [Origin 发布讨论](https://forum.cursor.com/t/origin-code-hosting/168670) 和 [Cloud Agents API 对 Origin URL 的报错讨论](https://forum.cursor.com/t/cloud-agents-api-support-origin-repositories-all-origin-url-forms-rejected-with-repository-access/169420)。它们说明产品入口与特定 API 曾有不同限制，不能据此推断 Origin PR API 不存在；本研究的能力判断采用官方文档而非论坛用户推测。[中；上述论坛与 API 文档]

### 本机观察：2026-10-20

以下为读取工具帮助和配置的结果，不是业务操作验收。来源是列出的本机命令，无公开 URL；不包含凭据。

- 高：`git -C /Users/elijah-air/Universe/Jupiter/Jupiter remote -v` 的 origin fetch/push 均为 `git@origin.cursor.com:elijah7/jupiter.git`；Polaris 同命令结果为 `git@origin.cursor.com:elijah7/polaris.git`。
- 高：已安装 `/Users/elijah-air/.local/bin/origin`、`/Users/elijah-air/.local/bin/cursor-agent`、`/usr/local/bin/cursor`。`cursor --help` 显示 3.25.9；`cursor-agent --help` 和 `cursor --help` 中没有 Origin forge 子命令。`cursor --merge` 是本地文件三方合并，不是 PR 合并。
- 高：`origin --version` 为 `2026.09.04-21-29-36-50525fa`。`origin pr view --help` 提示存在 `2026.10.19-14-39-49-eb6a364` 更新；本研究没有更新工具。文档与旧版行为可能有差异。
- 高：`origin pr create --help` 支持 `-R/--repo`、`--title`、`--body`、`--body-file`（`-` 表示 stdin）、`--head`、`--base`、`--status open|draft`；默认是 **draft**。
- 高：`origin pr merge --help` 支持 number / Origin PR URL / branch，以及 `-R`、`--merge`、`--squash`、`--auto`。`origin pr view --help` 支持 `--json <fields>`、`--web`。实际 JSON 的 URL 字段及成功输出尚未读取，不能假定与 `gh` 完全一样。

| 无凭据命令 | 实际响应 | 能证明什么 |
| --- | --- | --- |
| `curl -sI --max-time 15 https://origin.cursor.com/api/v1/version` | `HTTP/2 404`，`server: awselb/2.0`，`content-type: text/plain; charset=utf-8` | 高：该时间该 host 的 HEAD 路径不可用；不能证明所有 Gitea API 都不可用 |
| `curl -sI --max-time 15 https://origin.cursor.com/api/v4/version` | 同为 `HTTP/2 404`，同 server/content-type | 高：该 GitLab 风格探测路径不可用；不能推断真实 API 版本 |

响应日期分别为 `Tue, 20 Oct 2026 03:54:54 GMT`、`03:54:55 GMT`。未带 Authorization、cookie 或登录态，未跟随跳转。探测源 URL 即表中两项。

## 2. 当前 Tivano 代码路径

下表结论置信度均为高，来源为任务副本源码。已对 `MergeRequestLink` 全部引用进行文本搜索，并用代码索引查相关函数；表中区分实际 forge 分支和间接消费链接的 UI。

| 路径 / 函数 | 当前行为与 Origin 影响 |
| --- | --- |
| [Git.swift](../../../Tivano/Services/Git/Git.swift) `forge()`（315） | 对整个 remote 字符串做 `contains("gitlab")` / `contains("github")`，其余 `.gitea`。不仅遗漏 Origin，还可能被仓库名中的 github/gitlab 干扰；应解析 host 后精确识别 Origin。 |
| 同文件 `createPullRequest()`（267） | GitLab→glab、GitHub→gh、其他→tea；成功从任意 HTTPS 文本取 URL。Origin 目前走错 CLI。 |
| 同文件 `existingRequestURL()`（298） | 匹配 `already exist` 和 URL，或把 `!N` 拼为 GitLab `-/merge_requests/N`；不是通用的幂等查找契约。Origin 应按仓库、head/base 查现有 PR。 |
| 同文件 `remoteWebURL()`（230） | 去 `.git`，SSH 改 HTTPS，host/path 原样保留；会产生 `https://origin.cursor.com/owner/repo`，不是官方 `cursor.com/codebase/...`。 |
| 同文件 `mergePullRequest()`（324） | switch `link.forge` 调 CLI，GitLab 特殊重试；Origin 必须增加独立分支。 |
| [MergeRequestLink.swift](../../../Tivano/Core/Models/MergeRequestLink.swift) `Forge`、`init(url:)`、`prompt` | 枚举仅三类；`owner/repo/pull/N` 按路径认 GitHub（没有 host 校验），`pulls/N` 认 Gitea。Origin 带 `codebase` 前缀，现状解析失败。`prompt` 另外生成合并 helper 的 CLI 指令，必须同步修。`label/title` 的 `#N` 可沿用。 |
| [AppModel+HydraMerge.swift](../../../Tivano/App/AppModel+HydraMerge.swift) `hydraCreateMergeRequest()`（553） | GitLab 专用认证/恢复逻辑；其余转 `Git.createPullRequest()`。Origin 不应进入 GitLab恢复流程。 |
| 同文件 `mergeHydraProject()`（292，关键 472–477） | push→创建→解析 `MergeRequestLink`→`mergePullRequest`→sync→记录成功。URL 不能解析会报“forge 没说请求在哪”；合并命令退出成功被当作已合入。接入时必须区分排队与已合并。 |
| [ChatView.swift](../../../Tivano/App/Views/Chat/ChatView.swift) `GitStatusModel.refresh()`、`GitActionsMenu.body/openPullRequest()` | `remoteWebURL` 用于 Open repository；手动 Create pull request 先 push 再创建并打开 URL。fallback 应在此 UI 明确表达“打开仓库”，不能让服务层返回仓库 URL 冒充 PR。 |
| 同文件约 287 `mergeRequestTarget` | 用 `link.title/link.prompt` 调 `model.spawnSubagent`；这是独立于原生 `Git.mergePullRequest` 的第二条合并执行路径。 |
| [LinkPopover.swift](../../../Tivano/UI/Markdown/LinkPopover.swift) `show()` / `LinkPopoverContent` | 解析后显示 Merge，回调 helper；Open/Copy Link 通用，favicon 按 URL host 读取。缺失 CLI 时需要 App 层提供能力状态，UI 层不能依赖 Services。 |
| [LinkParagraphView.swift](../../../Tivano/UI/Markdown/LinkParagraphView.swift) `MergeRequestTarget` 与 [ProseRunView.swift](../../../Tivano/UI/Markdown/ProseRunView.swift) | 传递上述回调，不自行判断 forge。 |
| [TimelineRows.swift](../../../Tivano/App/Views/Chat/TimelineRows.swift) `HydraReportRow`（354）、`HydraMergeRow.outcomeControls()`（1193） | 用链接解析结果决定是否显示结构化 merge note；Origin 当前退回普通展示。 |
| [HydraMergePopover.swift](../../../Tivano/App/Views/Chat/HydraMergePopover.swift) `HydraMergeNote.parse()`、`openTitle` | parse 消费已解析链接；`openTitle` exhaustive switch 需加入 Origin→Open pull request。 |

### GitHub 登录与仓库选择是另一套入口

以下均为高置信度源码事实：

- [GitHubAPI.swift](../../../Tivano/Services/Git/GitHubAPI.swift)：`user/repositories/startDeviceFlow/awaitDeviceToken/request` 固定 `github.com` / `api.github.com`；`GitHubCredentials` 使用 Keychain 的 `GitHub Token`，可读取 `gh auth token --hostname github.com`；`environment(token:)` 注入 `GH_TOKEN` 及仅针对 `https://github.com` 的 credential helper。这里不调用 `forge()`。
- 同一文件内的 **`GitHubClone`**（不是独立 GitHubClone.swift）：`clone()` 固定 `https://github.com/{fullName}.git`；`configureIdentity()` 设置 GitHub noreply 邮箱；不能直接拿来克隆 Origin。
- [GitHubConnection.swift](../../../Tivano/App/GitHubConnection.swift)：`start/signInWithBrowser/connect/useGitHubCLI/finish/disconnect/loadRepositories/clone` 管理上述 GitHub token、用户与列表；没有 Origin 认证或仓库枚举。
- [Core/Models/GitHub.swift](../../../Tivano/Core/Models/GitHub.swift) 的 `GitHubRepoReference.fullName(from:)` 是 GitHub URL/owner-repo 解析器；不应放宽成“任何 host 都是 GitHub”。
- [GitHubConnectView.swift](../../../Tivano/App/Views/GitHub/GitHubConnectView.swift)、[GitHubClonePanel.swift](../../../Tivano/App/Views/GitHub/GitHubClonePanel.swift)、[GitHubSettingsSection.swift](../../../Tivano/App/Views/Settings/GitHubSettingsSection.swift)、[SidebarView.swift](../../../Tivano/App/Views/Sidebar/SidebarView.swift) 消费 GitHubConnection；[AppModel.swift](../../../Tivano/App/AppModel.swift) `bootstrap()` 启动它。最小 Origin forge 支持不必改这些入口，也不会自动获得 Origin 仓库列表。

## 3. 普通 Git 与 forge 能力的边界

`Git.push()`、`pushBranch()`、`fetch()`、`pullFastForward()`、`addWorktree()`、`removeWorktree()` 都调用普通 git，没有 forge 分支。worktree、索引、commit/tree 操作是本地 Git 工作；Origin 接入无需替换这层。[高；Git.swift 源码]

官方明确支持普通 Git clone/push/pull；结合本机 SSH remote，判断现有 Git 层在认证和仓库权限正确时可以原样使用。**这是中置信度兼容性推断，不是本次实测成功**：本研究未 fetch/push，也未创建 worktree。未登录、SSH key 未登记、仓库访问权限及入站镜像限制仍可能导致 Git 操作失败。[官方 Git 指南](https://prod.cursor.com/docs/origin/git)

PR 创建、审阅、合并、PR URL、仓库列表和 Web 登录属于 forge 层。Git 能传输对象不能证明这些能力可用；本机 SSH 配置也不能给 `origin pr` 提供 API session。[中；上述代码分层与官方认证契约]

## 4. 具体接入方案

### 推荐第一阶段：独立 forge + Origin CLI

设计置信度：中。依据为现有 Tivano CLI 架构、上述官方 CLI/API 契约和本机帮助；尚未执行真实 PR 操作。

1. **统一 remote 解析。** 在 Core 的小型纯值类型中解析 SCP SSH、`ssh://git@...`、HTTPS；host 规范化后精确匹配 `origin.cursor.com`。支持官方出现的 `owner/repo.git` 及 `/git/owner/repo.git` 两种 HTTPS 路径；只在 Origin host 下剥离可选 `git/`。去凭据、端口和 `.git` 时保留合法仓库名，拒绝缺 owner/repo 的输入。不要用 remote 名称 `origin` 判断厂商，也不要用整串 contains。
2. **Web URL 与 Git URL 分开。** Origin 仓库页面构造为 `https://cursor.com/codebase/{owner}/{repo}`；若已有 API 返回 `webUrl`，优先使用它。路径逐段编码。PR parser 优先识别 host=`cursor.com` 且路径=`codebase/owner/repo/pull/正整数`，允许已知子页面、query/fragment；不把任意网站的 `/pull/N` 视为 Origin。
3. **创建使用 `origin pr create`。** 使用参数数组而非 shell 字符串：`-R owner/repo --title <title> --body-file - --head <source> --base <target> --status open`，正文通过 stdin。现有流程已经 push，无须再隐式 `--push`。手动未传 head/base 时保留 CLI 默认分支解析。不能漏 `--status open`，否则默认 draft 可能阻塞自动合并。
4. **结构化读取与重试。** 创建后通过 `origin pr view <head> -R owner/repo --json <确认过的字段>` 得到 number、URL、状态；或用 `origin api` 读取官方 API JSON。实施前确认旧版真实字段，不假定 `url/webUrl`。重复创建/响应丢失时按同一 repo、head、base 查现有 open/draft PR，匹配唯一才复用；不能把任意错误文本中的 HTTPS 地址当 PR。
5. **合并使用 `origin pr merge <number> -R owner/repo --squash`**，squash 与当前项目单提交集成约定一致；其他项目若需要 merge commit，应遵循其合并策略，不默默忽略仓库规则。不要带 `--auto`，它只启用等待合并，不能满足 Hydra 当前“返回即已落地”的语义。命令完成后读取 PR 状态，确认 merged 才进入同步与成功记录；权限、冲突、检查阻塞应保留请求链接并停止。链接中的 repo 必须与目标 checkout 对应，不能拿外仓同号 PR 合并。
6. **两个执行入口一起覆盖。** 原生 Git service 和 `MergeRequestLink.prompt` 都改；helper 明确使用 Origin CLI、匹配 repo、不得绕过分支保护或用本地 push 替代 PR 合并。Core 仅保存纯模型/提示，不直接查询 CLI 或设置。
7. **失败退路。** CLI 未安装、未登录或版本不支持时，显示可操作说明及仓库/已有 PR 的网页按钮；手动交互才打开网页。Hydra 自动路径不弹浏览器，不持续重试确定性的缺工具/认证失败，不把“打开网页”记为创建/合并成功。没有已知 PR 时只打开仓库页面，不臆造 `/compare` 或 `/pull/new` 路由。
8. **镜像仓库单列能力。** 不能仅凭 Origin host 就断言所有仓库都应创建 Origin PR。先读取仓库 mirror/source 元数据；第一阶段明确只承诺原生 Origin PR。入站 GitHub 镜像先提示去对应网页处理，之后再按已确认的 source repo 路由 GitHub；不要从名称猜源仓库。

### 认证存储

第一阶段沿用 Origin CLI 自己的登录与 Git/SSH 配置：Tivano 不读取其私有凭据文件、不复制 SSH 私钥、不把 GitHub token 传给 Origin，也不自动执行 `origin auth login`。遇到未登录可提示用户运行该命令；GitHub 已连接状态不能充当 Origin 状态。[设计，中；CLI 认证文档与现有 GitHubCredentials]

如后续做原生 REST 登录，新增 `CursorOriginCredentials`，使用现有 `APIKeychain` 且独立 account（如 `Cursor Origin Token`），遵循 Release/Dev Keychain service 隔离；不要放进 UserDefaults、remote URL 或全局环境。用户短期 token 的交换/续期、scope、登出与过期处理必须完整设计；不能照搬 GitHub 不刷新 token 的流程。app installation 方案另需 app 注册与签名密钥管理，不是最小桌面接入的必要前提。[设计，中；官方 API 认证与项目隔离约定]

### REST 备选与选择理由

官方已有以下接口，不需要逆向 Gitea/GitLab。高置信度，来源：[Origin API](https://cursor.com/docs/api/origin)。

| 用途 | 契约摘要 |
| --- | --- |
| 创建 PR | `POST /v1/origin/repos/{ownerSlug}/{repoName}/pulls`，body 含 title/body/head/base/draft；响应 number 为字符串，webUrl 可缺省 |
| 合并 PR | `POST .../pulls/{pullNumber}/merge`，可传 `expectedHeadSha`、`mergeMethod: squash` |
| 可合并性 | `GET .../pulls/{pullNumber}/mergeability` |
| 仓库详情 | `GET /v1/origin/repos/{ownerSlug}/{repoName}`，读取 webUrl、cloneUrl 与镜像信息 |

CLI 方案与现有 gh/glab/tea 调用结构最接近，且本机已安装，认证成本小；REST 更适合明确 SHA 约束、结构化错误及完整原生账户/列表体验。也可先用 `origin api` 消费 REST JSON，由 CLI 持有认证，避免直接实现 token 生命周期。两种方式都不应重用 GitHubAPI 的固定 host、OAuth client 或 credential account。[设计判断，中]

### 文件与函数改动清单、工作量

| 阶段 | 文件 / 函数 | 预计工作量（单工程师，含 lead 验收） |
| --- | --- | --- |
| 最小安全识别与网页退路 | `Core/Models/MergeRequestLink.swift` 的 Forge/init/prompt；新增 Core remote 值类型或复用合适纯解析位置；`Services/Git/Git.swift` 的 forge/remoteWebURL；`ChatView.swift` 与 `LinkPopover.swift` 的能力传递/退路；`HydraMergePopover.openTitle`；`Localizable.xcstrings` | 0.5–1 天；缺 CLI 时禁用合并并说明，不发 tea |
| 原生 Origin PR 主流程（推荐交付范围） | `Git.swift` 的 createPullRequest/existingRequestURL/mergePullRequest；可新增 `Services/Git/CursorOriginCLI.swift` 承载 JSON 与错误；`AppModel+HydraMerge.swift` 的 hydraCreateMergeRequest/mergeHydraProject，处理确定性失败与真实 merged 状态 | 额外 1–2 天；总约 2–3 天 |
| 独立 REST / 原生账号及仓库列表 | 新增 Services 的 `CursorOriginAPI/CursorOriginCredentials`、Core DTO、App `CursorOriginConnection` 及相应设置/克隆 UI；GitHub 文件保持职责，必要时抽取中性列表容器 | 额外 3–5 天，取决于 token 生命周期和权限契约；不含应用注册等待 |

工期置信度中偏低；未做实施 spike。所有新用户文案需英文 key 与 zh-Hans；组件沿用项目 Chrome 控件。现有 GitHubConnection/API、GitHubRepoReference、GitHubClone 不属于第一阶段必须修改项。

## 5. 交给 lead 的验证与未决项

本次没有执行下列验收；不是已通过清单。

- remote 解析覆盖 SSH/HTTPS、可选 `git/`、`.git`、含 github/gitlab 的仓库名、凭据去除、假冒 host 与错误路径；保证其他 forge 不退步。
- 用授权的临时原生 Origin 仓库完成 create→读 URL→解析→merge→merged 状态；同时覆盖手动 Git 菜单、链接 helper、Hydra 三条入口。
- 取得本机旧版 CLI 的真实 create/view JSON、错误状态和退出码；确定最低支持版本。旧版帮助与在线文档存在选项差异，不静默升级。
- 断网、缺 CLI、API 未登录但 SSH 可 push、重复 PR、draft、检查未完成、合并冲突、权限不足：不调用 tea、不报假成功、不反复开 PR。
- 镜像仓库与原生仓库分开验证；PR link 的 repo 身份和 checkout 匹配；stack PR 不应意外落地未授权祖先。
- `origin pr merge --squash` 是否已足够强制团队单提交语义、合并后 source branch 是否自动删除、旧版 CLI 是否具有所需状态字段，均待业务实测。REST 的 `expectedHeadSha` 可作为更严格竞态控制方案。
- Git push/fetch/worktree 的兼容性仅有静态代码与官方契约依据，本次没有网络 Git 或端到端实测。

### 历史线索与研究边界

使用 search-memory 技能，经 `nmem --json m search 'Cursor Origin forge API CLI' -n 3` 做一次定向检索；scope 为当前 `default`，无额外过滤，未指定模式（服务返回 `fast_bm25_vector`）。排名：1. `c3c9c661-2a5d-4c5b-8185-7fe9c7c89fa2`「Cursor Origin 的认证机制：HTTPS 为主，SSH 可选」0.8564；2. `85d08a8a-2c76-4dbb-aa63-af31360b07a1`「本机 artemis 已切换 Cursor Origin 仓库为 SSH 连接」0.8362；3. `4db522fd-b87e-4b34-819d-10dd93ae0414`「Ceres 仓库迁到 Cursor Origin 的价值与代价」0.8260。仅作为历史线索，当前能力以本次官方资料为准；本机 remotes 已另行读取。没有可确认同一身份/空间约束的浏览器上下文，故未展示记忆图。

研究没有访问私有 PR 内容或读取 token。按 Hydra head 约定只写此文档，验证留给 lead；Jev 评审由 lead 统筹，本 head 未另行调用。
