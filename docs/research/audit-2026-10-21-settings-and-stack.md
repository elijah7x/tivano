# Tivano 设置理解与技术借鉴审计

2026-10-21（Asia/Singapore）。静态源码阅读及公开资料研究；没有启动应用、构建、测试、lint、性能采样或运行 Git。唯一产物是本报告，所有建议均未实施。行号对应本任务收到的工作副本。

最值得先处理的是：API key 的 Keychain 承诺与失败回退不符；Hydra 文案没有准确表达容量、推理强度继承及远端合并；中文设置搜索遗漏本地化名称；Performance Mode 会改写另一项用户偏好。技术栈已有 Swift 6、Observation、ACP、增量 Markdown 和后台解析，不建议为这些能力重写应用。下一轮性能工作应聚焦最终回复解析竞态、可见页面的装饰时钟和有证据的长文档布局开销。

## 范围与判断方法

阅读了 `Tivano/App/Views/Settings/` 的全部 18 个 Swift 文件、`Tivano/App/AppSettings.swift`、相关英语 key 与 zh-Hans 文案、`README.md`、`docs/providers.md`、`project.yml`、Tivano 文件分层及必要的调用方。设置文件包括 SettingsView、AboutUpdateViews、AlphaSettingsPage、FloatingGuidePanel、GitHubSettingsSection、HydraCookbookPanel、HydraSettingsPage、KeepsakesSettingsPage、MCPKeyPanel、MCPSettingsPage、MCPSetupPanel、ModelsSettingsPage、ProviderSelectionSection、ProviderUpdateViews、SettingsScrollTracker、ShortcutsSettingsPage、TokenActivitySection、WallpaperCard。

对照了 [2026-10-18 旧审计](../performance/settings-and-interaction-audit.md)。下面除明确标注“仍存在”外，均是新增的理解/逻辑发现或技术研究；不把旧审计的隐藏布局、扫描和 GPU 假说重新包装成新发现。检索过 Nowledge 的 `Tivano settings interaction audit` 相关线程；只有摘要，没有据此推导技术结论。

“确认”表示静态路径足以证明行为或文案矛盾，不表示已做交互验收。“建议”表示新用户理解风险；“待实测”表示无法从源码确定耗时或资源收益。性能收益均为方向判断，没有虚构毫秒、内存节约或竞品速度排名。建议文案采用现有 Chrome 组件和本地化机制，不要求新控件。

下表路径缩写：`S/` = `Tivano/App/Views/Settings/`；`A/` = `Tivano/App/`；`C/` = `Tivano/Core/`；`L` = `Tivano/Resources/Localizable.xcstrings`。每一项的 EN/ZH 都是建议替换或补充文案，不是当前字符串。

## A. 新用户逐页理解

### 跨页面与搜索

| ID / 位置 | 问题与证据 | 建议文案（EN / zh-Hans）及处理 |
| --- | --- | --- |
| A01 — `S/SettingsView.swift:122`，关键词 `:77`；`L:6389,10228,11636` | **确认：中文页名无法正常搜索。** 过滤只看原始英文 `page.title` 和大多为英文的 keywords；显示名称却会本地化。“外观”“通用”“模型”并不在相应搜索输入中。Alpha 有中文关键词，形成不一致。搜索还只定位页面，不搜索设置行。 | 同时索引英文、本地化页名和本地化关键设置词。输入提示 EN **Search settings pages or providers**；ZH **搜索设置页面或服务商**。若将来真正索引行，再改为“搜索设置”。不只改占位文字来掩盖功能缺口。 |
| A02 — `S/HydraSettingsPage.swift:143,181,633`，`S/SettingsView.swift:1254`；`L:367,10448,11196,9689` | **确认：术语不一致。** Heads 是“子智能体”，归档中的 Hydra heads 原样保留英文；Lead 是“主导”，说明另用主会话/主智能体；同一个 effort 有时只有英文短标签，读者不知它是推理强度而非并发数或预算。 | 建议统一：EN **Lead agent / Helper agents (heads) / Reasoning effort / Lead–helper preset**；ZH **主智能体 / 子智能体（heads）/ 推理强度 / 主从搭配方案**。Hydra 保留产品名，首次写 EN **Hydra runs helper agents in parallel for the lead chat.**；ZH **Hydra 为主对话并行运行子智能体。** 归档筛选改 **Hydra helpers / Hydra 子智能体**。 |

### General

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A03 — `S/SettingsView.swift:519`；`A/AppSettings.swift:840`；`C/Models/Provider.swift:285` | **建议，默认值确认。** 全新偏好默认 Full access。当前选择摘要已经明确“不询问”，不是完全无告知；但作为新线程默认，容易被当作仅本次会话权限。切换默认也不等于改变已有对话。是否改默认属于产品决策。 | **Default permissions for new chats. Full access runs commands and edits files without asking; existing chats keep their own setting.** / **新对话的默认权限。完全访问会直接执行命令和修改文件，不再询问；已有对话保留各自的设置。** 保留 provider 对权限模式的实际映射，不暗示统一沙箱。 |
| A04 — `S/SettingsView.swift:523`；`C/Models/Provider.swift:309`；`A/AppModel.swift:834` | “Local / New worktree” 不解释副本和 Git 前提；两者实际上都在本机。独立聊天没有仓库时，默认 worktree 不等于必然创建副本；显式请求 worktree 且无项目会报错。 | 标签 **Project folder / Separate Git worktree**；**项目目录 / 独立 Git worktree**。说明 **For repository chats, choose the project folder or a separate working copy. A worktree needs a Git repository with a commit; it is not a security sandbox.** / **仓库对话可直接修改项目目录，或使用独立工作副本。worktree 需要至少有一次提交的 Git 仓库，不是安全沙箱。** |
| A05 — `S/SettingsView.swift:515`；`A/AppModel.swift:897,913` | **确认：继承说明遗漏项目优先级。** 说明只说跟随当前对话/最后服务商；实际项目指定的 Hydra pair 优先，其模型和 effort 还能覆盖这些继承。与 Models 的“每个新对话”承诺冲突。 | **New chats use the project's Hydra preset when one is set. Otherwise they inherit the current chat's model and reasoning settings, or use your saved defaults.** / **新对话优先使用项目指定的 Hydra 搭配；否则继承当前对话的模型和推理设置，或使用已保存的默认值。** |
| A06 — `S/SettingsView.swift:532` | “Show thinking” 与“working line opens”混在一起，容易理解成始终展开或所有模型都会提供思考内容。 | **Show available reasoning**；**Allow the working indicator to show reasoning when the provider supplies it.** / **显示可用的推理内容**；**服务商提供推理内容时，可在工作状态栏中展开查看。** 不承诺能显示 provider 未公开的内部过程。 |

已明确说明而不报缺陷：语言 `S/SettingsView.swift:597` 写了重启要求；简洁回复 `:536` 写了下一条消息生效；任务睡眠模式 `:588` 有解释。TokenActivitySection 已用单个 Canvas 和缓存网格（`:43,101`），不是数百独立视图；本轮不建议重复做该优化。未发现足够证据把通知、触感或自动继续开关判为“存了但没应用”。

### Appearance

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans 及处理 |
| --- | --- | --- |
| A07 — `S/SettingsView.swift:612,638`；`A/AppSettings.swift:432,868` | **确认，旧审计第 7 项仍存在。** 打开 Performance Mode 会持久写 `clearerBackdrop=false`，关闭后不会恢复。用户以为是临时覆盖，实际改写另一个偏好。启动加载也会归一化为 false。 | 在保持当前行为时如实补充 **Turning this on also turns off Clearer glass. Turn Clearer glass on again after leaving Performance Mode if wanted.** / **开启后也会关闭“更通透的玻璃”。退出性能模式后，如有需要请重新开启。** 更好的局部行为是保留用户值、只计算有效值；旧版本已丢失的偏好不能凭空恢复。 |
| A08 — `S/SettingsView.swift:612,642`；`S/WallpaperCard.swift:27` | Clearer glass 同时受壁纸、Performance Mode 限制；Skylight 和透明度也受性能模式限制。用户看到禁用项却不一定理解由谁控制。 | 随状态显示 **Unavailable while Performance Mode is on** / **性能模式开启时不可用**，或 **Unavailable with a wallpaper** / **使用壁纸时不可用**。壁纸说明补 **Wallpaper selection is separate from window transparency.** / **壁纸选择与窗口透明度分别设置。** 两个条件同时成立时同时说明。 |
| A09 — `S/SettingsView.swift:638`；`S/KeepsakesSettingsPage.swift:102,337` | **确认存在覆盖缺口，资源影响待实测。** 性能模式称关闭 background effects、最低 GPU；Keepsakes 的可见页面时钟不读 performanceMode。Reduce Motion 关了 sway，但时钟仍 tick；展开完成后 `flightTime/hintTime` 继续增长。不能把它描述成隐藏页仍渲染：该页已有 visible/windowVisible 门禁。 | 暂时准确写 **Reduce glass, glow and background effects. Some interactive animations remain.** / **减少玻璃、光晕和背景效果；部分交互动画仍会保留。** 同时让 Keepsakes 尊重性能模式，并在有限动画结束后停钟；不要冻结完成 lighting 的状态提交。 |

### Providers

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans 及处理 |
| --- | --- | --- |
| A10 — `S/SettingsView.swift:943`；`A/AppSettings.swift:636,644`；`L:15574` | **确认，高优先级。** 页面承诺 API key 存入 Keychain；`APIKeychain.setKey` 失败时却把明文保存到 UserDefaults，调用方无保存状态可显示。这不是仅翻译问题。 | 成功才显示 **Saved in Keychain** / **已保存到钥匙串**。现有回退状态必须显示 **Keychain save failed. This key is stored unencrypted in this edition's preferences.** / **钥匙串保存失败，此密钥目前以明文保存在本版本的偏好设置中。** 推荐改为失败不落明文并提供重试，但删除/迁移既有回退密钥及兼容策略需 owner 决定。不能只改一条免责声明后继续静默回退。 |
| A11 — `S/ProviderUpdateViews.swift:243,251` | **确认：开关关掉后说明仍称每六小时比较版本。** detail 不读 `isOn`。自定义路径和未知安装渠道也无条件声称继续定时检查。 | 开启：**Check this CLI for updates every six hours. Installation starts only when you choose Update.** / **每六小时检查此 CLI 的更新；仅在你点击“更新”后安装。** 关闭：**Automatic checks are off. You can still check manually.** / **自动检查已关闭，仍可手动检查。** 保留“自定义路径不会代为更新”的条件说明。 |
| A12 — `S/SettingsView.swift:993`；`S/ProviderUpdateViews.swift:252` | Binary path 对新用户不直观；填写它会影响托管更新资格，效果散落在另一行。未证实改路径必须重启整个 app，不作该断言。 | **CLI executable path (optional)**；**Leave blank for automatic detection. A custom executable is not updated by Tivano.** / **CLI 可执行文件路径（可选）**；**留空可自动查找。指定自定义可执行文件后，Tivano 不会代为更新它。** |

ProviderSelectionSection 已解释隐藏服务商仍保留配置，以及用量统计范围；不把隐藏误报成禁用已有会话。更新按钮与登录状态已有具体错误/进行中视图；本轮不建议再造通用状态系统。

### Models

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A13 — `S/ModelsSettingsPage.swift:156`；`A/AppModel.swift:913` | **确认：不是“every new chat”。** 新对话可能继承当前 effort/fast，项目 pair 也有优先级，模型偏好仅是回退。当前中文忠实翻译了同一过度承诺。 | **Set this model's default reasoning effort and fast mode. New chats may inherit the current chat or a Hydra preset instead.** / **设置此模型的默认推理强度和快速模式。新对话也可能优先继承当前对话或 Hydra 搭配的设置。** |
| A14 — `S/ModelsSettingsPage.swift:94` | 不固定任何模型会显示整个模型目录，这一点已有空态说明，但删掉最后一个固定模型时，结果反而是列表变多，容易误认为删除没生效。 | 在移除最后一项时补充 **No pinned models means the full catalog is shown.** / **未固定任何模型时，将显示完整模型目录。** 不要把 pin 改成“启用模型”。 |
| A15 — `S/ModelsSettingsPage.swift:664`；`A/AppSettings.swift:1158` | **确认：Delete group 仅删除标题。** 模型会并入邻接分组，操作不删除模型/固定项；“删除分组”容易被理解为连同内容删除。 | **Remove group heading**；**Models stay in the list.** / **移除分组标题**；**模型仍会保留在列表中。** |

### Hydra

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A16 — `S/HydraSettingsPage.swift:41,97,124` | 有 hover 帮助，不能说毫无解释；但核心模型“主智能体派任务、子智能体独立会话、汇报返回”藏在辅助层。Pairs 也容易被当成数量只能为二。 | 页头 **Hydra lets a lead chat delegate work to helper agents. A preset chooses their models; it does not limit the team to two agents.** / **Hydra 让主对话把任务分给子智能体。搭配方案用于指定双方模型，并不表示团队只能有两个智能体。** |
| A17 — `S/HydraSettingsPage.swift:146` | Own copy/Shared 解释了改动落点，却未说明 worktree 不是安全隔离；Shared 多头写同一目录的含义应直接说出。 | 独立：**Each helper uses a separate Git worktree. Its changes are applied to the lead chat's folder when it reports; conflicts may need review.** / **每个子智能体使用独立 Git worktree；汇报时将改动应用到主对话目录，冲突可能需要处理。** 共用：**All helpers edit the same folder and can change the same files.** / **所有子智能体修改同一个目录，也可能同时修改同一文件。** |
| A18 — `S/HydraSettingsPage.swift:157,644`；`A/AppModel+Hydra.swift:259` | **确认：全局配置不是全应用总量。** launch 使用 pair/global 较小上限，room 检查按 lead chat 的 running heads。无上限也不等于无限资源或不受 pair 限制。 | **Helpers at once per chat**；**The lower of this limit and the preset's limit applies. “No cap” adds no limit here.** / **每个对话的并发子智能体数**；**此处与搭配方案中较小的上限生效。“不限”表示此处不额外限制。** |
| A19 — `S/HydraSettingsPage.swift:181,636` | **确认：默认 effort 标签与实际规则冲突。** pair 未指定 worker effort 时显示 Same as the chat，但开启 temper 时可能降到标准强度；该开关默认开。列表摘要又叫 Automatic。 | nil 统一显示 **Automatic (follows helper effort rules)** / **自动（遵循子智能体推理规则）**。旁边沿用已有完整说明，必要时显示最终解析值，不再显示“与对话相同”。 |
| A20 — `S/HydraSettingsPage.swift:186,188`；`A/Runtime/ThreadRuntime.swift:1357,1365,1374` | **确认：at once / every / only 过度承诺。** 容量满或 launch 不可用时不能立刻派发；发送消息的派发失败会回到普通路径，`/plan`、`/compact` 留在原对话。queued 在空闲主对话也有顺序处理路径。 | 队列：**Use helpers for queued follow-ups when capacity is available.** / **有可用名额时，用子智能体处理排队的追加消息。** 全部消息：**Prefer helpers for messages. Commands and messages that cannot be delegated stay with the lead.** / **优先让子智能体处理消息；命令及无法派发的消息仍由主智能体处理。** |
| A21 — `S/HydraSettingsPage.swift:193` | “Reads every changed file and corrects it” 是给模型的 review 指令，不是确定执行的程序化验收；不能保证每个文件被阅读或纠错。 | **Ask the lead to review helpers' changes**；**Adds a review step before the lead finishes. This uses additional time and tokens.** / **要求主智能体审查子智能体的改动**；**在主智能体结束前增加审查步骤，会消耗更多时间和 token。** |
| A22 — `S/HydraSettingsPage.swift:195`；`A/AppModel+HydraMerge.swift:292,320,455` | **确认：外部动作应更明确。** 现有说明已提 merge request，并非完全隐瞒；但“自动合并”常被理解为把子 worktree 合到本地。实现还提交、推送远端分支、创建请求并合并，有失败/重试路径。默认关闭。 | **Automatically publish and merge team changes**；**Commits and pushes the team's changes, opens a pull/merge request, and attempts to merge it. Requires a configured remote and access.** / **自动发布并合并团队改动**；**提交并推送团队改动，创建拉取／合并请求并尝试合并；需要已配置远端及相应权限。** 开关是否增加一次明确的启用确认由 owner 决定，不在本报告中擅自加流程。 |

Codex head history `:202,210` 已明确只影响 Codex 本地历史、不清理既有记录、不删除会话，且不被 Hydra 总开关禁用；不建议重报为“关闭 Hydra 后历史选项还可点”的 bug。

### MCP

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A23 — `S/MCPSettingsPage.swift:90,140` | footer 已说明 CLI launch 时生效，但页头“every thread can use it”容易被理解为当前已启动会话立即获得工具；launch 与新 chat 也不是同一回事，Tivano 会复用 provider session（`A/Runtime/ThreadRuntime.swift:1915,1936`）。MCP 不在该 signature 中，不能承诺仅“下一条消息”就刷新；各 bridge 可能还有自身同步能力。 | **Connect external tools with MCP. CLI sessions receive configuration when they launch; an already running session may need to restart. API models use Tivano's connection.** / **通过 MCP 连接外部工具。CLI 会话启动时读取配置；已运行的会话可能需要重新启动。API 模型使用 Tivano 管理的连接。** 建议后续逐 provider 显示“已连接 / 当前会话尚未载入”，不是统一要求重启整个 app。 |
| A24 — `S/MCPSettingsPage.swift:126`；`L:7940` | Connected servers lead / 优先使用已连接的服务器像执行优先级策略，实际上这里是浏览/连接说明。不要暗示设置了工具路由优先级。 | **Connect tools to your chats** / **为对话连接工具**。 |
| A25 — `S/MCPSettingsPage.swift:859,881` | 锁图标的 tooltip 已明确明文 mcp.json 与 Keychain，不能说没有告知；但用户不 hover 就很难知道新变量的存储方式。Environment/Headers 对不了解 MCP 的用户也缺例子。 | 常驻补充 **Unlocked values are saved in mcp.json. Lock passwords and API keys to store them in Keychain.** / **未锁定的值会写入 mcp.json；请锁定密码和 API key，将它们保存在钥匙串中。** 字段帮助 **Environment: variables passed to the local command. Headers: fields sent to the remote server.** / **环境变量会传给本地命令；请求头会发送给远端服务器。** |

配置损坏已有暂停修改与重试状态（`:42`），认证 key/OAuth 面板已有等待/错误处理，本轮未发现可证明的“保存成功却完全未读”设置。对活跃 provider 会话的配置刷新只能定为上面的范围说明缺口，不能跨 provider 推断同一种 bug。

### Source control

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A26 — `S/GitHubSettingsSection.swift:39`；`S/SettingsView.swift:579,1129` | GitHub 登录描述“Let agents push…”易与 General 的权限和 Hydra 自动发布混为一谈。文本生成关闭时，commit/PR instructions 编辑器仍可编辑，用户未必知道当前不会用到。 | GitHub：**Connect GitHub for repository and pull-request actions. This does not turn on Hydra automatic publishing.** / **连接 GitHub，以使用仓库和拉取请求功能；这不会开启 Hydra 自动发布。** 指令编辑器：**Used when text generation is enabled in General.** / **在“通用”中开启文本生成后使用。** 不暗示登录替代所有操作授权。 |
| A27 — `S/SettingsView.swift:1149` | Worktree 根目录是位置配置，不是启用新对话独立副本的开关；与 General Workspace、Hydra Checkout 相隔多个页面。 | **Worktree storage folder**；**Choose where Tivano stores separate working copies. Choose when to use them in General → Workspace and Hydra → Checkout.** / **worktree 存放目录**；**选择 Tivano 存放独立工作副本的位置；是否使用副本，请在“通用 → 工作区”和“Hydra → 检出目录”中设置。** 若 A17 改标签，此处同步。 |

### Shortcuts

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A28 — `S/ShortcutsSettingsPage.swift:70,99` | 同页可录制快捷键与 Return 等固定键外形相近；不可编辑只在 hover 的 Built in 提示。Send/Steer 共用 Return，细节在帮助中而非行主信息。 | 分组 **Built-in keys (not customizable)** / **内置按键（不可修改）**。运行中 Return：**Interrupt and send now**；**Stops the current turn before sending the new message.** / **中断并立即发送**；**先停止当前轮次，再发送新消息。** |
| A29 — `S/ShortcutsSettingsPage.swift:211,218` | Clear 与 Reset to default 是两个不同动作，前者把 binding 设 nil，中文“清除”不说明是否取消快捷键还是恢复默认。 | **Remove shortcut** / **移除快捷键**；保留 **Reset to default / 恢复默认**。这只改操作命名，不改变冲突处理和录制逻辑。 |

### Archive

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A30 — `S/SettingsView.swift:1215,1220,1230` | **确认：按钮范围表达不足。** 筛选后仍叫 Delete all；help 和确认弹层正确说明 matching，但用户关闭删除确认后直接执行，主标签必须自洽。不是实际删错范围。 | 筛选时 **Delete matching chats (%lld)** / **删除匹配的对话（%lld）**；未筛选 **Delete all archived chats (%lld)** / **删除全部归档对话（%lld）**。保留项目文件不受影响的已有说明。 |

Hydra heads 中文漏译见 A02。归档筛选和恢复流程未发现新的确定逻辑缺陷。

### Alpha

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A31 — `S/AlphaSettingsPage.swift:30,52,67`；`A/AppSettings.swift:346` | **确认：关闭总开关会结束通话、关闭 local control 有效权限。** 目前只介绍不稳定，没有说关闭会立即影响进行中的工作。voice style 下一次生效已经说明清楚。 | 总开关 **Turning Alpha off ends the current voice call and disables local control. Individual feature choices are kept.** / **关闭 Alpha 会结束当前语音通话并停用本地控制；各功能的选择会保留。** voice 行 **Turning this off ends the current call.** / **关闭后会结束当前通话。** |
| A32 — `A/Control/LocalControlSettings.swift:9,40` | CLI 安装不启用权限、同账户访问、无网络 listener 都已解释，值得保留。但“this edition”不识别具体对象；新用户不知道 Dev 和 Release 的隔离。安装命令名直到成功才出现。 | 动态显示 **Controls Tivano Dev only** 或 **Controls Tivano only** / **仅控制 Tivano Dev** 或 **仅控制 Tivano**；安装行预览实际 **Command: %@** / **命令：%@**，使用 `ControlCLIInstaller.commandName`，不要另写猜测命令名。 |

### Keepsakes

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A33 — `S/KeepsakesSettingsPage.swift:90,104,106` | “Keep the keepsakes from along the way”没有说明这是纪念物而非保存会话/备份功能。只显示 `.first`；无 keepsake 时 nil 的 litAt 仍选择 Tap to light，是否能进入该状态需要 lead 用空库确认。 | 页说明 **Keepsakes mark moments in your time with Tivano. Open one to read its story.** / **信物记录你与 Tivano 相伴的时刻，打开即可阅读它的故事。** 若 nil 可达：**No keepsakes yet** / **暂无信物**，不要出现“点击点亮”。装饰时钟逻辑见 A09。 |

### About

| ID / 位置 | 问题与证据 | 建议 EN / zh-Hans |
| --- | --- | --- |
| A34 — `S/SettingsView.swift:1440`；`C/Support/Text.swift:5`；`A/UpdateChecker.swift:152,177` | 标题固定 Tivano，Dev 只有 version 的 dev- 前缀。Dev 和 Release 的数据目录、更新行为不同，是 Alpha/local control 中 edition 概念的解释入口。不是缺少版本号。 | 使用实际 edition 名称 **Tivano Dev / Tivano**（中文仍保留产品名）；Dev 补 **Development edition. Uses a separate library; automatic release updates are disabled.** / **开发版本，使用独立资料库，不自动更新到正式版本。** |

AboutUpdateViews 已区分未检查、检查失败、无更新，并明确 **Update & restart**（`:663,708`）；不把正常重启安装流程报为隐藏要求。

### 存储与生效时点补充

`A/AppSettings.swift:479` 仍保存 `projectsEnabled` / `projectActivationOverrides`，而 `isProjectActive` 在 `:493` 直接返回 true。当前搜索未见其他业务消费者；这是遗留状态与注释意图不一致，不是当前设置页上一个失效的用户开关。建议先决定保留兼容还是移除遗留键，不能擅自恢复已撤销的产品功能。若未来重新暴露，文案可用 **Enable this project / 启用此项目**，但必须先恢复真实消费者。

本轮没有证据证明全套设置需要重启。准确区分：语言需 app restart（已有提示）；voice style 下次通话（已有提示）；默认模型/权限/工作区影响新 chat；MCP/CLI 参数常受 provider session 生命周期约束；性能模式立即生效且还会改写偏好。不要加一个笼统“重启后生效”来替代逐项说明。

## B. 技术栈与开源借鉴

### 当前基线：避免重复建设

- `project.yml:8,15`：SwiftTerm 1.20.0，Swift 6 language mode、Approachable Concurrency，macOS 26。主 UI 是 SwiftUI，窗口、文本、终端有 AppKit 桥接；不是 Electron/WebView 聊天壳。
- `A/AppSettings.swift:126` 和 AppModel 使用 `@MainActor @Observable`；runtime 用统一 ProviderSession 事件接口。`Services/Providers/ACPSession.swift` 已承接多个 ACP provider；Codex/Claude 等另有专门 session。`Core/Support/StdioProcess.swift` 管理进程与 stdio。不能把“采用 ACP / Observation / Swift 6”列成尚未实施的建议。
- `UI/Markdown/MarkdownView.swift:20` 已按未稳定尾部增量解析：小尾部同步，超过 4096 bytes 后单路后台解析并覆盖 pending 为最新请求；`:170,183` 缓存流式结果供最终回复复用，`:252,285` 有后台 warm。不是每 token 都全篇同步解析。
- **新增可查路径**：后台解析未完成就收到 final 时，`:183` 只复用完全匹配文本，miss 在主 actor 同步全量 `MarkdownParser.parse`（`:190`）。`:43` 创建的后台任务没有保存取消 handle；失去 view 只阻止结果应用，不必然停止耗时解析。两者是需 lead 复现的长回复收尾/快速切页风险，不能声称已经造成实测卡顿或泄漏。
- 旧审计已记录 timeline 窗口化、稳定 identity、delta 合批、scroll 降频、保存合并、原生文本缓存和隐藏列生命周期。保留这些边界，不让新 renderer 撤销 selection、链接、中文输入法、滚动锚点和折叠状态。
- `A/AppModel+HydraMerge.swift:312` 已按 Git common-dir 做跨 edition 合并锁，存在重试和分阶段合并；`A/Control/LocalControlSettings.swift:9` 已有当前账户本地 socket 控制；`A/AppUpdater.swift:412` 已验证 Developer ID team / identifier，且有 staged install。不能因未用 Sparkle 就说更新无签名校验。

### 项目现状

查阅日期均为 2026-10-21；公开 GitHub API 的 `pushed_at`（UTC 日期）用于排除长期失联，不代表最近正式发布，更不证明质量。所有候选都找到了当前官方项目/文档；Conductor 找到的是现行产品文档，**未核实它的 macOS 产品源码开源**，不拿同名无关仓库充数。

| 项目 / 官方来源 | 本次可核实状态 |
| --- | --- |
| [Zed](https://github.com/zed-industries/zed) | 活跃 OSS；push 10-20。 |
| [CodeEdit](https://github.com/CodeEditApp/CodeEdit) | MIT；push 10-17；其 text view 是单独组件，不能把 app 成熟度等同于每个组件的适配度。 |
| [Ghostty](https://github.com/ghostty-org/ghostty) | MIT；push 10-20；当前 libghostty 已可被嵌入，API 仍在变化。 |
| [Warp](https://github.com/warpdotdev/warp) | **当前客户端已开源**；push 10-20。仓库包含 AGPL-3.0 / MIT 范围，不能沿用“只有 issue tracker”的旧结论。 |
| [opcode / 原 Claudia](https://github.com/winfunc/opcode) | AGPL-3.0；push 09-18；桌面源代码可用。 |
| [Crystal](https://github.com/stravu/crystal) → [Nimbalyst](https://github.com/nimbalyst/nimbalyst) | Crystal README 已明确 deprecated，2026-02-26 是最后 push；指向 Nimbalyst。后者当前是 MIT 开源多 agent 可视工作区，不建议再把 Crystal 当活跃依赖。 |
| [Conductor](https://www.conductor.build/docs/concepts/git-worktrees) | 活跃产品文档可读；开源状态未知，只作流程参考。 |
| [vibe-kanban](https://github.com/BloopAI/vibe-kanban) | Apache-2.0；push 09-19；**README 已宣布 sunsetting**，有代码不等于继续维护。 |
| [Sculptor](https://github.com/imbue-ai/sculptor) | MIT 源码可用；push 10-20；官方称 experimental research preview，不能称成熟行业标准。 |
| [Claude Squad](https://github.com/smtg-ai/claude-squad) | AGPL-3.0；push 08-20；仍可作为小型 tmux/worktree 编排参考。 |
| [cmux](https://github.com/manaflow-ai/cmux) | 活跃 Swift/AppKit/libghostty 项目；push 10-20；复用代码前按具体文件 LICENSE 审查，API license 分类不足以代替阅读条款。 |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) → [Textual](https://github.com/gonzalezreal/textual) | MarkdownUI 已维护模式，push 2025-12-28；官方后继是 Textual（push 2026-06-15）。不是另找同名 swift-markdown-ui fork 当官方后继。 |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Apache-2.0；push 10-19；解析/AST 库，不是 SwiftUI renderer。 |
| [STTextView](https://github.com/krzyzanowskim/STTextView) | TextKit 2 组件；push 10-06；仍公开维护平台 bug 清单。 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 活跃 macOS updater；push 10-19。 |

### 可以借鉴什么，以及 Tivano 已经做到哪里

成本是相对工程量：低 = 少数现有路径；中 = 独立模块/生命周期调整；高 = renderer、进程或发行链迁移。收益均为推断，尚未在 Tivano 测量。

| 项目 / 技术证据 | Tivano 对照 | 具体建议、收益、成本与风险 |
| --- | --- | --- |
| **Zed**：GPUI 用 GPU primitives/glyph caching；agent panel 通过 ACP 对接独立 agent。[渲染设计](https://zed.dev/blog/videogame)、[ACP 文档](https://zed.dev/acp/editor/zed)。 | 已有原生 UI、缓存、ACP；没有 GPUI。`ACPSession` + `ProviderSession` 是可保留的协议边界。 | 借鉴“小批事件 → 后台准备 → 少量主线程发布”的边界，为每次 provider turn 标记接收、合批、parse、呈现阶段。优先解决 final parse miss，而非换 Rust。收益：定位长回复尾部卡顿及 stale work；成本中，风险为 cancellation 丢 final。GPUI 全栈迁移高成本、需 owner 决策，没有整机收益证据。 |
| **CodeEdit / CodeEditTextView**：AppKit 自定义按行文本视图，面向大型代码文档；官方明确不追求 NSTextView 全功能，尤其 RTL/custom layouts。[组件 README](https://github.com/CodeEditApp/CodeEditTextView)。 | Tivano `UI/Markdown/LinkParagraphView.swift` 已是原生文本桥；`App/Views/Diff/DiffInspector.swift` 是更接近代码文档的目标，不是整段聊天替换对象。 | 只在大文件 diff/code-block 样本里比较按可见行布局与当前实现，先保留 copy、find、highlight、accessibility。可能降低首次打开和长文件内存；成本中至高。风险：RTL、长行、选择、字体度量变化。不能把组件宣传“fast”当实测优于 Tivano。 |
| **Ghostty**：Zig core、macOS SwiftUI/Metal/CoreText，终端 I/O 与渲染职责分开；libghostty embedding API 仍在演进。[仓库说明](https://github.com/ghostty-org/ghostty)。 | Tivano 用 SwiftTerm；`App/Views/Terminal/TerminalPanel.swift` 与 terminal store 管理 shell 和面板。聊天 Markdown 不经过 terminal renderer。 | 先检查隐藏 terminal 的绘制和读取是否分离、scrollback 是否有容量预算；保持 PTY 消费，降低无显示时绘制。若终端确为热点，再做 libghostty 独立原型。收益集中在终端输出，成本高，风险为 Zig 工具链/API 漂移、IME、shell lifecycle；不会直接修 chat layout。 |
| **Warp**：当前 Rust 客户端与 UI crates 源码公开，终端作为结构化开发工作流；官方列出 Tokio、Alacritty 等基础组件。[源码/工程入口](https://github.com/warpdotdev/warp)。 | Tivano 已把 provider events 转成 timeline items，而非只记录终端像素；同时有单独 terminal。 | 学其把任务、输出、状态分开建模的边界，对异常大的工具输出保留磁盘原文，UI 仅呈现可展开窗口。先读现有 truncation/preview 路径，避免二次丢数据。潜在收益是长会话内存与 UI 更新量；成本中，风险为截断影响 agent 上下文、复制/搜索不完整。不建议引入 Warp UI crates。 |
| **opcode / Claudia**：Tauri 2 + React/TS + Rust；session browsing、用量面板、checkpoint/恢复工作流。[官方 README](https://github.com/winfunc/opcode)。 | Tivano `Services/Store/Storage.swift`、runtime save、turn revert 和 token ledger 已有对应基础；不是缺少持久化。 | 借鉴明确的恢复状态与导出审计：复用现有恢复/回退路径，区分“provider 已结束”“记录已落盘”“改动可恢复”。收益是崩溃后可解释性而非原生渲染速度；成本中，风险是承诺 checkpoint 能恢复外部副作用。新事务性 checkpoint 需 owner 决策。 |
| **Crystal → Nimbalyst**：原 Crystal 将任务放入 worktree；后继把多 agent 会话、任务及 Markdown/图示产物放进同一可视工作区。[Crystal](https://github.com/stravu/crystal)、[后继](https://github.com/nimbalyst/nimbalyst)。 | Hydra 已提供隔离 worktree、汇报及落地；`HydraCookbookPanel` 已有搭配预设。 | 借鉴“任务对应哪个目录、分支、产物”的明确摘要，给 head panel 暴露真实运行目录/落地状态。收益是降低误操作和重复启动任务；成本低至中，风险为显示 stale path。不要因后继换名导入 Electron 全栈。 |
| **Conductor**：每 workspace 有工作副本、branch、terminal、chat；setup/files-to-copy 工作流。[worktrees](https://www.conductor.build/docs/concepts/git-worktrees)、[files-to-copy](https://www.conductor.build/docs/guides/use-files-to-copy)。 | Tivano 已有 `ensureExecutionDirectory`、Hydra 复制与合并。A04/A17 的问题主要是解释和生命周期可见性。 | 先借鉴 ready/preparing/failed 状态与目录解释；可选 setup hook 和 ignored-file copy 要独立授权设计，绝不默认复制 .env/凭证。收益：减少“agent 在错误环境工作”；成本中，风险：脚本副作用、秘密扩散、初始化拖慢。开源实现不可核实，不提出代码移植。 |
| **vibe-kanban**：Rust backend + web UI，任务/workspace 分离，diff inline comments 可回送 agent。[README](https://github.com/BloopAI/vibe-kanban)。 | 已有 Hydra、DiffInspector、follow-ups，尚不应据此声称缺少 review UI。 | 借鉴把特定文件行的 review comment 附到 follow-up 的结构，保留文件路径、版本及范围。收益是减少重新解释和错误修复；成本中，风险为 diff 变化后行号失效。因 sunsetting，只作设计参考，不新增运行依赖。 |
| **Sculptor**：隔离 workspace、多 integrated harness、技能驱动分阶段产物；Docker/remote 是实验功能。[README](https://github.com/imbue-ai/sculptor)、[skills](https://github.com/imbue-ai/sculptor/blob/main/docs/help/skills.md)。 | Hydra brief/report 和 cookbook 已有任务分工基础；worktree 不提供进程或网络隔离。 | 将报告附上具体产物路径、已做/未做验证和阻塞项，作为现有 head report schema 的可选字段。收益：长任务交接可靠性，成本低至中，风险：模型声称完成不等于验收。容器执行是另一个产品能力，高成本、需 owner 决策。 |
| **Claude Squad**：tmux 持有 agent，Git workspace 隔离，preview/diff，显式 attach/detach。[官方说明](https://github.com/smtg-ai/claude-squad)。 | Tivano 直接管理 stdio child、provider session、watchdog 和保存。app 退出时的生命周期与 tmux 模式不同。 | 为“UI 重开后恢复显示”与“进程跨 app 退出存活”分别定义承诺；先改用户状态说明，再决定是否有外部 session host。潜在收益：长任务抗 UI 退出；成本高，风险为孤儿进程、权限/approval 重接、协议失序。不能直接把 JSON-RPC stdout 塞进 tmux 当作兼容方案。 |
| **cmux**：Swift/AppKit + libghostty，socket CLI、OSC 通知、pending attention 导航；普通 session restore 与 tmux 生存保证分开。[README](https://github.com/manaflow-ai/cmux)。 | 已有 local control socket、approval/question UI 和侧栏 attention；不是从零新增 CLI。 | 借鉴按 thread/turn 去重的 attention 事件与“跳到下一待处理”导航，统一 terminal 和 structured provider 的通知语义。收益是多头场景的感知响应与可发现性；成本中，风险为终端输出伪造通知、重复提醒。先复用现有 attention 状态，不再轮询全库。 |
| **MarkdownUI → Textual**：MarkdownUI 维护模式；Textual 保留 SwiftUI Text 管线、InlineText/StructuredText、异步附件、原生选择和自定义 parser 接口。[MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)、[Textual](https://github.com/gonzalezreal/textual)。 | 自研 Markdown 已有 stable-prefix、流式尾部、链接/mention、veil、原生段落和缓存。Textual README 不证明每 token 增量解析更快。 | 可做单个长表格/复杂 inline 内容的替代原型；先复用 Tivano parser 输出，隔离“解析”和“布局”成本。收益可能是维护与复杂格式正确性，成本高，风险为跨块选择、主题、链接、流式未闭合语法回退。不引入维护模式 MarkdownUI 作新基建。 |
| **swift-markdown**：cmark-gfm parser，持久化 immutable/COW AST，可线程安全传递。[README](https://github.com/swiftlang/swift-markdown)。 | 当前 `MarkdownParser` 为流式体验定制。COW AST 不等于每次 `Document(parsing:)` 自动做流式增量解析。 | 先用于 completed-document 的参考语义/离线差异样本，比较 GFM edge cases；若要依赖，再评估成本。收益是格式兼容和 parser 维护，成本中，风险为不完整 token 流、额外 AST 内存和全篇重解析。不要替换每次 delta 的热路径。 |
| **STTextView / TextKit 2**：viewport-oriented 文本布局、独立 layout/selection/gutter；支持长文档，同时公开平台 bug 清单。[README](https://github.com/krzyzanowskim/STTextView)。 | 已有 `LinkParagraphView`，旧审计还记录原生文本优化与 rejected renderer。引入第二套 text stack 会增加互操作。 | 仅在超长单段落、code preview 或 diff 的独立面板里评估，保留中文 IME、RTL、selection、accessibility 作为必要验收。可能降低可见范围外布局，成本中高，风险为 TextKit 长行/输入法缺陷及高度测量。不要把整条 chat 包进一个可滚动编辑器。 |
| **Sparkle 2**：标准 updater lifecycle、appcast、Ed25519 archive 签名、Developer ID、可选 delta、SwiftUI programmatic setup。[官方安装文档](https://sparkle-project.org/documentation/)。 | Tivano 是 custom updater，并已有 Developer ID/identifier/version/staged install 验证；`SparkleParticle` 名称是动画，不是框架依赖。Dev 自动更新被明确禁用。 | 先做 threat/lifecycle 差距表：取消、下载恢复、失败回滚、正在运行时安装、版本回退拒绝。采用 Sparkle 可减少 updater 自维护，成本高，风险为发布脚本、签名密钥、镜像/appcast、双 edition 行为迁移。必须 owner 决策；不能削弱现有签名校验或顺便开启 Dev 更新。 |

### Apple Observation、严格并发和 2025–2026 SwiftUI 资料

| 官方资料 | 对 Tivano 的具体含义 |
| --- | --- |
| [Discover Observation](https://developer.apple.com/videos/play/wwdc2023/10149/)；[WWDC25 Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/) | 已用 Observation。保留 leaf-level 属性读取，避免 helper 中全库遍历扩大依赖；用 Cause & Effect 分清 body、平台 text layout 与 GPU。旧审计已有该建议，本轮不再建议全面替换 `@AppStorage`。若要做新工作，集中记录上面 final parse fallback 和 Keepsakes clock 的触发点。 |
| [WWDC25 Explore concurrency in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/266/) | Swift 6 不会让 `Task {}` 中的 CPU 工作自动离开 MainActor。Tivano 的 detached parse / `@concurrent` warm 是正确方向；需要补全取消与最终结果交接，而非再开更多任务。严格并发通过也不代表无主线程耗时；本任务未编译，不能声称所有代码已通过最新 concurrency 诊断。 |
| [WWDC25 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/) | Apple 给出 macOS 大型 List 的加载/更新提速样例，也改进 lazy container 调度；这不构成 List 全面胜过 LazyVStack 的结论。Tivano 的可变高度 Markdown、滚动锚点和混合 AppKit 行必须用同一 transcript 比较。小设置页改 LazyVStack 没有先验收益。 |
| [WWDC26 Dive into lazy stacks and scrolling](https://developer.apple.com/videos/play/wwdc2026/321/) | 官方解释 size estimation、prefetch、视图移出后销毁、动态子视图数量和 geometry 回写引起跳动。对应 `App/Views/Chat/ThreadTimeline.swift`：保留外部状态和稳定 ID；使每个 ForEach item 有稳定单一根；不要用 onAppear 才装载决定高度的内容；锚点应基于 item，而非把估计 contentOffset 当永久真值。成本中，风险为现有 scroll reconciliation 回归。先局部核查，不全量迁移 List。 |
| [WWDC26 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/) | 页面介绍 lazy Observable State 初始化和新 image caching。**来源注意**：本次抓取的 WWDC26 页面正文却把部分新行为称为“2027 releases”、并提到 Xcode 27；不能据 URL 年份就断言本仓库当前工具链已具备它们。只把通用原则用于研究；API/编译器采用需另核对实际 SDK 和 back-deployment。`@State` 初始化昂贵对象仍应按实际编译产物测量，不能未经确认删掉本地生命周期保护。 |

### 下一轮由 lead 负责的验收重点（本任务未执行）

1. 设置：全新偏好与既有偏好各一次；中英搜索；开关关闭时 subtitle；Performance Mode 开/关循环；模型继承/项目 pair 优先级；容量满时消息派发；MCP 当前和新 session；Dev/Release 名称。Keychain failure 用受控失败注入，不动真实凭证。
2. 文本：长回复恰在后台 parse 尚未完成时 final；快速切走/返回；巨大未闭合 code fence、超长段落、表格、中文及 RTL。观察主线程同步 parse 和过时后台工作，确认最终文本不丢、不回退、不重复闪动。
3. 生命周期：Keepsakes 显示/隐藏、Reduce Motion、Performance Mode、点亮途中切页；不能为了停动画漏保存纪念物状态。
4. 性能比较只在同一脚本、窗口和资料库下作 A/B/A；记录首次与热打开、p95 交互延迟、主线程工作、内存稳定值。保留旧审计里的受控测量方法，不以其他项目的 stars 或营销 benchmark 验收。

## C. 排名前十的改进机会

“safe to do now”指建议实施范围清楚、可逆，不表示本 head 已获授权修改或已完成验证；所有变更仍由 lead 按任务分工执行。“needs owner decision”涉及行为策略、发行链或长期架构取舍。

| 排名 | 机会与依据 | 标记 | 预期收益 / 成本 / 主要验收 |
| --- | --- | --- | --- |
| 1 | **消除 API key 静默明文回退与 Keychain 承诺冲突**（A10） | **needs owner decision** | 凭证存储可信度；中。决定失败时是否拒绝保存及既有回退迁移，再验证失败/重试/删除，不丢可恢复凭证。 |
| 2 | **让 Hydra 的权限范围与派发规则准确可见**（A18–A22） | **safe to do now**（仅准确文案） | 避免把远端 publish 当本地 merge、把 fallback 当失灵；低。保持行为，覆盖无容量、不同 effort、auto merge 默认关闭。改变自动发布授权流程则另需 owner。 |
| 3 | **补齐 final parse 与后台任务交接**（B 当前基线） | **safe to do now**（先窄范围诊断及局部修复） | 降低长回复收尾卡顿/过时解析；中。复用同一最终文本的 pending result、保留 last-good presentation，避免 MainActor cache-miss 全篇解析；须验证 final 不丢和取消不污染新会话。 |
| 4 | **修复中文搜索并统一 Hydra/effort 术语**（A01–A02） | **safe to do now** | 设置可发现性直接提升；低。索引本地化页名而非只改提示，保留英文产品名搜索。 |
| 5 | **让 Performance Mode 临时覆盖外观而非清除偏好**（A07–A08） | **safe to do now** | 开关行为可预测；低至中。保留新设置的 raw preference，计算 effective value；不猜测已丢失历史值。 |
| 6 | **停止 Keepsakes 已完成动画的时钟，并尊重性能模式**（A09） | **safe to do now** | 降低 Settings 可见时无收益的调度和状态写入；低至中。实测收益未知，必须保留点亮完成及可见恢复。 |
| 7 | **修正文案优先级与状态反馈**（A05、A11、A13、A30–A32） | **safe to do now** | 新对话默认、更新检查、删除范围和 Alpha 关闭效果可理解；低。动态 subtitle 与实际状态一致，中英文成对。 |
| 8 | **明确每 provider 的 MCP 配置生效边界**（A23–A25） | **safe to do now**（文案与状态梳理） | 减少“已连接却无工具”的重复排障；中。区分 hub connected / session configured。若要强制重启活跃会话，须另作 owner 决策。 |
| 9 | **针对大段落/大 diff 比较现有 renderer 与 Textual/STTextView/按行布局**（B） | **needs owner decision** | 可能改善长文档首开、内存和流式布局；中高。只批准独立原型，不先添加全局依赖；保住中文、RTL、selection、anchor，收益不成立就保留现有实现。 |
| 10 | **决定长期 session host 与 updater 的维护边界**（Claude Squad/cmux、Sparkle） | **needs owner decision** | 长任务恢复和更新可靠性；高。先选产品承诺：是否支持 agent 跨 app 退出存活、是否迁移 Sparkle；两个独立项目，不捆绑实施，不以更换框架替代恢复验收。 |

没有建议立即重写为 GPUI、换 Electron、全面引入 libghostty 或把全部 LazyVStack 换成 List。当前证据更支持修正可证明的设置矛盾，并在现有渲染/进程边界上做窄范围、可测量的改进。
