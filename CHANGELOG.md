# Changelog

All notable changes to Tivano are documented here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are the release tags without the `v`. The dated entries below are inherited from Droppy Code and kept as written.

`scripts/publish_release.sh` reads the section whose heading matches the version in `config/release.xcconfig` (for example `## [1.5.4] - 2026-09-17`) and publishes it as the GitHub release notes, which Settings › About shows as its New features / Bug fixes / Refinements cards. Work that has merged but not shipped sits under `## [Unreleased]`, which publishing skips; the next release renames that heading to its version and date. A `### Thanks` heading under a version names every outside contributor whose pull request shipped in it, in the form `- Name (@github-handle): what they did (#PR).`; `python3 scripts/release_credits.py` prints the block for the changes since the previous tag, and publishing stops until every contributor is named.

New entries use `### English` and `### 简体中文` sections, each with the existing third-level category headings: New features / Bug fixes / Refinements in English, 新功能 / 问题修复 / 优化改进 in Chinese. About selects the app's active language; a missing Chinese section, or one containing only whitespace and category headings, falls back to English. A single shared `### Thanks` section follows both languages.

## [Unreleased]

## [2.0.23] - 2026-10-25

### English

### Bug fixes

- Update & restart no longer stays greyed out after every chat has finished: a chat whose session was still starting, or a finished local-control request, could leave it waiting for good.

### Refinements

- When an update has to wait, Settings › About lists the chats it waits for and why (running, starting, landing Hydra work, background tasks, helpers at work, a usage-limit wait), each with a button to open it, and the dimmed button now shows a tooltip.

### 简体中文

### 问题修复

- 所有对话都结束后，“更新并重启”不再一直置灰：之前若某个对话的会话正在启动，或一次本地控制请求刚完成，按钮可能一直保持等待状态。

### 优化改进

- 更新需要等待时，设置 › 关于会列出正在等待的对话及原因（运行中、启动中、合入 Hydra 工作、后台任务、子智能体工作中、等待额度重置），每条都可直接打开；变暗的按钮也会显示提示。

### Thanks

- No outside contributors.

## [2.0.22] - 2026-10-25

### English

### New features

- The global "Continue after a usage limit" setting is gone. When Claude, Codex, OMP or Command Code stops because its usage limit is spent, a tab on that chat's composer shows when the limit resets and offers to continue automatically then. You can take back that choice, and the chat never waits unless you ask it to.
- A Hydra pair whose lead or heads run on DeepSeek Harness shows an Agent mode picker for them in its editor: a chat that joins the pair takes the lead's mode, which you can still change in the chat afterwards, the way a pair's effort works, and heads on DeepSeek Harness start in the mode you pick instead of always Standard.

### Bug fixes

- In performance mode, the Hydra team panel and a popped-out head keep a solid surface and a thin edge, instead of losing their outline and blending into the chat behind them.

- Hydra no longer tells the lead a provider is broken when a head hits a rate limit, a dropped connection or another passing error, or when other heads on that provider succeeded in the same batch.
- DeepSeek Harness chats start even when the DeepSeek Harness app is a version Tivano does not support: desktop profiles are off for that chat, and a notice says so.
- With Hide outdated models on, searching the composer's model picker finds every model again, as Settings already did.
- DeepSeek Harness sessions and Hydra heads use the CLI bundled with the DeepSeek Harness app when it is installed, instead of an older npm `dsh` that happens to be first on PATH; when the CLI in use cannot load the desktop profile, the error names its path.
- DeepSeek Harness no longer fails to start after you change the theme or dismiss the welcome notice in the DeepSeek Harness app; desktop-only settings in its profile are skipped, and a plugin file that no longer exists is reported by name.
- MCP servers reach ACP agents such as DeepSeek Harness with their command's full path, so a bare `npx` no longer rejects the whole session; a server whose command is not found is skipped with one notice instead.

### Refinements

- Switching to a chat with Hydra or helper panels lays them and the conversation out in place instead of sliding them there, and a head's own panel keeps its corner when other heads arrive or leave.

- Settings › Providers finds new versions of more agent CLIs and updates more of them in place: Antigravity installed with its official installer (with `agy update`), Cursor, OpenCode's new `@opencode/cli` package, Codex and Pi installed with their official installers, Grok's `agent` launcher and its npm package, and the DeepSeek Harness desktop app's own update channel, which Tivano reports but leaves to the app.

- In Today focus, thread titles run up to the project or task name beside them instead of stopping where the longest name would end, so short names leave the titles nearly as long as in the full list.

- Settings › General no longer shows the Token activity heatmap.
- Images that agents send are decoded and saved off the main thread, so a large screenshot no longer stalls the window.
- The model picker keeps its trimmed list between renders instead of rebuilding it on every keystroke.
- Full access is marked with a checked shield instead of a key, and the permission, attach and voice buttons under the composer share one round hover and highlight instead of an oval attach button.

- When Hydra heads fail before doing any work, the lead hears one cause per provider instead of a separate failure for each head, and is told that sending heads to that provider again would fail the same way, so it takes over their parts and tells you what to fix instead of retrying.
- Removing a model group in Settings › Models is now called Ungroup, since it keeps the models and only takes the group away, and a new group you leave unnamed is called Group.
- In the model picker, Recent, Pairs, Models and the Other models fold now read bolder and slightly larger than your group titles, so the sections and the groups inside them are easier to tell apart.
- Opening and closing Settings stutters far less: frames over 50 ms during the slide dropped by about two thirds, and closing settles about 25 ms sooner.
- Switching threads settles about 10 ms sooner, threads under the pointer and beside the selection load their history first, and scrolling a very long thread no longer gets slower the further back you go.
- Opening a long thread for the first time freezes far less: frames over 100 ms while it opens are about halved and it costs about a quarter less work, because mentions are found with a byte search, the Hydra block check no longer rebuilds its pattern for every reply, and the history above the screen lands 12 turns at a time instead of 24.

### 简体中文

### 新功能

- 全局的“额度恢复后继续”设置已移除。Claude、Codex、OMP 或 Command Code 因额度用完而停止时，该对话输入框上的标签页会显示恢复时间，并提供恢复后自动继续的选项。你可以撤销这个选择，对话只会在你要求时等待。
- Hydra 组合的领队或子代理使用 DeepSeek Harness 时，编辑器会为其显示“代理模式”选择器：对话进入组合时采用领队的模式，之后仍可在对话中手动修改，与组合的推理强度一致；DeepSeek Harness 上的子代理按所选模式启动，不再固定为标准模式。

### 问题修复

- 性能模式下，Hydra 团队面板和弹出的子智能体卡片保留实色底和细边框，不再失去外框、与后方对话融为一体。

- Hydra 子代理遇到限流、连接中断等临时错误，或同一批里同一服务商的其他子代理已经成功时，不再告诉主代理该服务商已损坏。
- DeepSeek Harness 应用的版本与 Tivano 支持的版本不一致时，对话仍能启动：本次对话不启用桌面配置，并会给出提示。
- 开启“隐藏过时模型”后，在输入框的模型选择器中搜索也能找到全部模型，与设置页一致。
- 已安装 DeepSeek Harness 应用时，DeepSeek Harness 会话和 Hydra 子代理改用应用自带的 CLI，不再误用 PATH 上靠前的旧版 npm `dsh`；当前 CLI 无法加载桌面配置时，报错会写明它的路径。
- 在 DeepSeek Harness 应用中切换主题或关闭欢迎提示后，DeepSeek Harness 不再启动失败：配置中仅属于桌面端的设置会被跳过，已不存在的插件文件会按名称报错。
- MCP 服务器以命令的完整路径传给 DeepSeek Harness 等 ACP 代理，裸 `npx` 不再导致整个会话被拒绝；找不到命令的服务器会被跳过并提示一次。

### 优化改进

- 切换到带有 Hydra 或子智能体卡片的对话时，卡片和对话内容直接出现在最终位置，不再滑动过去；其他子智能体加入或离开时，已弹出的卡片保持在原来的角落。

- 设置 › 服务商能发现更多智能体 CLI 的新版本，并在应用内更新其中更多 CLI：官方安装器安装的 Antigravity（通过 `agy update`）、Cursor、OpenCode 的新包 `@opencode/cli`、官方安装器安装的 Codex 和 Pi、Grok 的 `agent` 启动器及其 npm 包；DeepSeek Harness 桌面版按其自身的更新频道提示新版本，更新仍交给桌面应用。

- “今日聚焦”中，会话标题延伸到右侧项目或任务名之前，不再按最长名称预留空间；名称较短时，标题长度接近普通列表。

- 设置 › 通用中不再显示 Token 活动热力图。
- 代理发来的图片改在后台解码和保存，大截图不再让窗口卡住。
- 模型选择器会保留裁剪后的列表，不再每敲一个字就重新计算。
- “完全访问”的图标由钥匙改为带勾的盾牌；输入框下方的权限、附件和语音按钮统一为相同的圆形悬停与高亮，附件按钮不再是椭圆形。

- Hydra 子代理在开始工作前就失败时，主代理会按服务商收到一条合并的原因，不再逐个子代理报失败，并被告知再派给同一服务商也会以同样方式失败；它会自己接手这部分工作并告诉你需要修复什么，而不是反复重试。
- 设置 › 模型中的“移除分组标题”改称“解散分组”，因为它只移除分组、保留其中的模型；新建分组不填名称时，名称为“分组”。
- 模型选择器中，“最近”“组合”“模型”和“其他模型”标题比你的分组标题更粗、字号略大，分区与其中的分组更容易分辨。
- 打开和关闭设置时的卡顿明显减少：滑动过程中超过 50 毫秒的卡帧减少约三分之二，关闭后约快 25 毫秒恢复。
- 切换会话约快 10 毫秒恢复；鼠标悬停的会话和当前会话两侧的会话会优先预加载历史；在很长的会话里往回翻得越远，滚动也不再越慢。
- 第一次打开长会话时的卡顿明显减少：打开过程中超过 100 毫秒的卡帧约减半，工作量约少四分之一。原因是提及名字改用字节查找，检查 Hydra 委派块时不再为每条回复重新编译正则，屏幕上方的历史一次装载 12 轮而不是 24 轮。

### Thanks

- No outside contributors.

## [2.0.6] - 2026-10-23

### English

### New features

- Hide outdated models, on by default in Settings › Models, keeps model pickers short: each vendor shows its three newest versions across all your providers, models listed once per effort or Fast become one row, and Devin's Fusion pairings fold their efforts into one row each, keep only the newest leads and sidekicks, and sit in their own group. Chosen, default, recent, Hydra and in-use models always show, and search still finds everything.
- Pi's models from several accounts of one service appear once.

### Bug fixes

- Codex signed in with an API key stays recognised as signed in after Codex 0.164 changes its login status wording.

### Refinements

- Antigravity, Pi and MiniMax Code use their official colour logos, matching the other branded providers in menus and settings.
- The default model picker in Settings › New chat offers two clearly separated choices, Last selection and Custom model, with a checkmark on the one in use and all labels aligned.

### 简体中文

### 新功能

- 设置 › 模型新增“隐藏过时模型”，默认开启，让模型选择器更简洁：参照你所有服务商的模型，每个厂商只显示最新的三个版本；按推理强度或 Fast 分列的同一模型合为一行；Devin 的 Fusion 组合按推理强度合并，只保留最新的主模型和副模型，并单独成组。已选择、默认、最近使用、Hydra 引用和正在使用的模型始终显示，搜索仍可找到全部模型。
- Pi 中同一服务多个账号的模型只显示一次。

### 问题修复

- Codex 0.164 更改登录状态文案后，使用 API key 登录的 Codex 仍能被正确识别为已登录。

### 优化改进

- Antigravity、Pi 和 MiniMax Code 改用官方彩色标志，在菜单和设置中与其他品牌服务商保持一致。
- 设置 › 新对话的默认模型选择器分为“上一次选择”和“指定模型”两项，当前使用的一项带勾，标签统一左对齐。

### Thanks

- No outside contributors.

## [2.0.0] - 2026-10-22

### English

### New features

- New chats can follow the recent model or use a fixed provider and model, and either follow the latest chat's location or start in Tasks. Explicit project creation and project Hydra presets keep their priority.
- MiniMax Code is available as a CLI provider, using its existing Token Plan login or configured API key. Choose the model's advertised reasoning levels, with the official MCODE vector logo in settings and the composer.
- Keepsakes in Settings preserves an Early Supporter keepsake on this Mac. Open it to see its line drawing up close, then tap the drop of light hanging above the card: it falls along the ribbon onto the ring and the colour spreads from there across the card, which turns over once to show its back. Open it again any time to read its story and earned date, and click to flip it. The earned timestamp is stored in the edition's app data and Keychain; recovery keeps the earlier timestamp. No account or email binding is required.
- Cursor Origin repositories can open and merge pull requests with the origin CLI. Source control settings show its sign-in status.
- Archive search and chat-type and project filters make archived chats easier to find. Chats are grouped by project, and Delete all applies to the filtered selection.
- Control Tivano from the CLI with Local control in Alpha, off by default. Manually install the command-line entry to browse projects, chats and history, create regular chats, send or continue tasks in idle chats, interrupt active tasks, and read or change a limited set of settings. You can also call it over SSH using the same macOS account; Tivano must already be running with local control enabled.
- Skylight brings a weather doll to the sidebar, reflecting running, waiting, completed and failed chats. It is drawn as an engraved specimen plate: corner brackets and digit-free ruler ticks frame the doll, a fine crescent shades its head, and a small engraved tag beside it names the weather (Still, Breeze, Overcast, Fair, Drizzle). While awaiting input, a hairline thought cloud drifts in; wind sways the doll and its tag downwind and makes the skirt billow like cloth, and in rain the cloth wilts. The plate's title starts a new chat, and the whole plate highlights on hover and responds to a click. The Thread list title row is gone: focus and search move next to the sidebar button. Turn it off in Appearance > Main Interface to keep a compact new-chat button. Animation pauses when hidden. Skylight hides itself in Performance Mode, and its setting shows it is unavailable there.
- Today focus: the today-ring button to the left of search at the top of the sidebar shows only threads active since midnight today in your time zone, newest first, each labeled with its project or Task in place of the time (the time stays in the tooltip). Click again to return to Projects and Tasks.
- The sidebar separates Projects and Tasks. Start a task without choosing a project, with its own persistent workspace, or choose the project for a new chat before sending its first message. New chats remember the current project or task context.
- The default model in Settings › New chat can also set a reasoning effort, which new chats start with.
- Name a worktree's branch when you create it from the branch menu, prefilled from the chat title, and rename it later with Rename branch…. Names may use letters (Chinese included), digits and - _ . / up to 60 characters; renaming a pushed branch asks first, since the remote branch and any pull request keep the old name.

### Bug fixes

- MCP secrets no longer appear in process arguments, generated MCP config files are readable only by you, and the local MCP proxy rejects requests from web pages.
- Copilot requests time out, stopping a reply has a forced-close backstop on every ACP provider and Copilot, and approval cards left by an exited provider are cleared.
- A library missing its core lists stays read-only instead of being overwritten, recovery saves once, damaged turn files are set aside instead of failing every save, and changes made while MCP shuts down are written on quit.
- The MCP guide panel no longer swallows Escape from other windows, Push is disabled on a detached checkout, icon-only buttons have VoiceOver labels, and duplicate entries no longer crash the Models page.
- Chats with damaged workspace records remain in the library, with the affected workspace blocked from running. Recovery preserves the original file and damaged records before saving; repaired chats are not counted as skipped.
- Project counts in the sidebar only count the chats it shows, no longer helpers or Hydra heads. DeepSeek Harness and other ACP providers no longer report that models could not load when they did.
- Tool titles, context-compaction notices and agent-process errors from Codex, Command Code, ACP and OpenAI-compatible providers now appear in Chinese when the app language is Chinese.
- While chats are running, About's install-update button is disabled with a tooltip and becomes available when they finish. A provider that does not start within 90 seconds now fails the turn with a message so it can be sent again.
- The local MCP proxy limits concurrent connections and request read time, ends upstream forwarding when the local client disconnects, and no longer reports a failed stream as a clean end.
- MiniMax Code no longer leaves Tivano's permission mode in mcode's global config: Tivano records your own mode before changing it and restores it when its last MiniMax session ends, also after a crash. Model probes no longer touch it, and one failing model no longer fails the whole MiniMax catalog.
- Deleting an unfinished or unlanded Hydra head now keeps its work as a patch and removes its worktree instead of leaving an orphaned copy.
- Deleting a chat while a CLI task starts in it releases that task, so quitting and updating are no longer blocked; finished external turns no longer recreate a deleted chat's file.
- A model picked while the catalog loads is no longer replaced by the default, and reverting a chat with duplicate entries no longer crashes.
- Expanded work groups in the tree activity view stay open when new replies arrive and keep their page when scrolled back.
- Skylight stops animating while the sidebar is collapsed or covered by Settings, and count changes no longer restart its loop. An expanded keepsake no longer drifts when the Settings page scrolls.
- Keepsakes are not granted or overwritten while Keychain cannot be read; damaged copies are backed up before repair. A ready CLI worktree whose checkout is missing fails instead of running in the project folder.
- The default-model picker opens one provider's models at a time, keeps cached models usable when refresh fails, and shows complete errors with a retry action.
- Claude and Copilot stop before sending when permission changes cannot be confirmed; Pi stops when its permission gate cannot be saved. Copilot actions that need approval now reach the approval UI instead of sending a null decision.
- Add to reply now quotes the text selected when its menu opens, falling back to the full message only when no valid selection belongs to that message. Different fragments can be quoted separately, while duplicate fragments are ignored.
- MiniMax Code 0.6.12 Token Plan sessions avoid invalid empty model variants. Model changes clear unavailable reasoning levels, and startup failures appear once with actionable guidance.
- Recognize OpenCode's newer credential table, clarify Z.ai's GLM Coding Plan key requirements, and preserve Command Code's credit-error details.
- The built-in terminal selects a genuinely monospaced font, keeping Latin characters, Chinese text and the cursor aligned.
- Offline source-directory migration preserves file permissions and empty directories when run by a private background task, including when restoring local changes or rolling back.
- An interrupted checkout migration can restore local edits before its recovery worktree exists, and briefly waits for transient repository access to finish before checking the frozen snapshot again.
- Migration verification leaves Git's index unchanged, avoiding false alarms from its own file-stat refreshes.
- API keys are no longer saved unencrypted when the Keychain refuses them. Settings shows the failure, keys an earlier version left unencrypted move into the Keychain, and a key read from your shell environment is labeled as such.
- A library file with a few unreadable entries loads everything else, keeping the original and the unreadable entries in separate files; a damaged file falls back to the copy saved at the last launch.
- Fixed queued follow-ups churning while a local-control task waited, headings and lists keeping old formatting when only their structure changed, stopped API replies being recorded as complete, multi-line events in OpenAI-compatible streams, and conflict file names with unusual characters after a Hydra landing.
- Performance Mode no longer turns Clearer glass off permanently.
- DeepSeek Harness no longer fails to load models or start chats with “Internal error” when its desktop profile includes the Inspector plugin; Tivano drops plugins that need desktop-only services. Its errors now include the underlying reason.
- Collapsing or opening the sidebar no longer flashes a second sidebar button at the window's left edge.
- Locally packaged Release builds no longer carry Xcode's debugger entitlement, and keep microphone access for voice input through explicit Release entitlements.

### Refinements

- Skylight skips its status scan while hidden, and status, activity-tree and working-indicator summaries now use a single pass, reducing main-thread work.
- After downgrading from 2.0 to 1.x, standalone tasks disappear from the sidebar; their data stays on disk and returns after upgrading again.
- Settings pages breathe more: sections sit further apart, each provider and model group reads as its own unit, and headers stay close to what they title. About gains a Version information heading, and a new release's card pushes the rest down instead of leaving a gap. Popovers keep their compact spacing.
- Theme names always show their English names, and provider cards show version and update notes as plain secondary text without orange or bold.
- Project icons now offer 155 curated emoji in eight categories, with Chinese and English keyword search, search examples and a clear no-results message.
- Text generation settings now sit in General above Power. GitHub repository cloning and its entry points have been removed; GitHub sign-in remains available.
- Local packages, install backups and product captures now stay outside source checkouts. Each capture uses a fresh output directory without clearing earlier runs; design candidates and historical deliveries are archived separately from maintained assets.
- Projects and Tasks each collapse from their headers and remember their state. Sidebar section headers share one type style and aligned left and right edges, with tighter spacing between sections. Use the + beside Projects to add a project; the bottom Add project row is removed. Tasks are no longer grouped by day. The sidebar toggle is smaller inside the sidebar and keeps its round tray in the toolbar when the sidebar is hidden.
- Project names in new chats use the theme color to make switching clearer. Edit project icons from the sidebar context menu; existing icons are preserved, and the old project activation and marks settings are removed.

- Cached chats keep their layout while hidden, avoiding repeated message measurement when the sidebar opens or closes. Hidden composers pause change-stat refreshes, and hidden Hydra progress bars pause their animation and release animation slots.
- Hydra settings now put model pairs before head options and clarify when the default reasoning-effort limit applies. Codex history keeps its archive choice on the page, with restrictions in help; static run-location cards have been removed.
- Finished Hydra heads now leave their panels automatically, and their sidebar cards and folded counts disappear when the whole team finishes. Reports remain in the chat’s completion cards; the two display settings have been removed.
- Local development and releases can share one long-lived source checkout. Offline consolidation preserves local work and project bindings with backups and a rollback path.
- Long replies finish without parsing their text again on the main thread, and the newest replies are prepared first when a long chat opens. Idle chats save in the background before they are released.
- Keepsakes stops animating once still and respects Performance Mode. Finished network transfers and MCP proxy connections close promptly, with limits on oversized requests and responses.
- Settings search understands Chinese page names, and the Hydra, model, CLI update, archive, shortcut and Alpha descriptions say more precisely what they do. Today no longer lists helper and panel chats.
- The sidebar always opens at launch; the Open the sidebar at launch setting is removed. Closing it lasts for the session.
- The sidebar header's today ring, search and sidebar buttons share one optical size and line weight, and the sidebar button gets the same hover circle. Every glyph in the sidebar and chat toolbars uses the same ink color. Projects without a custom icon use a lighter two-tone folder.
- Clickable parts of Keepsakes show the pointing-hand cursor, and Skylight's hover wash has square corners matching its corner brackets.
- A keepsake now opens from and returns to the branch smoothly, without a jump on landing. The branch sways for a few seconds after you open Keepsakes, then rests and stops redrawing until you hover the keepsake.

### 简体中文

### 新功能

- 新对话可沿用最近选择或固定使用指定服务商和模型，并选择跟随最近会话的位置或创建独立任务；明确从项目新建及项目 Hydra 预设仍优先。
- 新增 MiniMax Code CLI 服务商，沿用现有 Token Plan 登录态或已配置的 API key。可选择模型实际提供的推理档位，设置与输入框使用官方 MCODE 矢量 Logo。
- 设置新增“信物”，在本机保存早期支持者信物。打开后可先细看线稿，再点卡片上方悬着的那滴光：它沿飘带落到挂环上，颜色从那里在卡片上晕开，随后卡片自动翻面一次展示背面。之后随时打开可查看描述与获得日期，点击即可翻面。获得时间同时保存在当前版本的应用数据和钥匙串中，恢复时保留较早的时间戳，无需账号或绑定邮箱。
- Cursor Origin 仓库可通过 origin CLI 创建和合并拉取请求，源代码管理设置中可查看登录状态。
- 归档页新增搜索、对话类型和项目筛选，并按项目分组；“全部删除”仅作用于筛选后显示的对话。
- 实验室新增 CLI 本机外部控制，默认关闭。手动安装命令入口后，可查看项目、会话与历史，创建普通会话，向空闲会话发送或继续任务，中断活动任务，以及读取或修改少量配置。也可通过 SSH 使用同一 macOS 账户调用；Tivano 必须已运行且开启本机外部控制。
- 侧栏新增“晴天窗”，晴天娃娃用天气提示对话的运行、待处理、完成和出错状态。画面是一张铜版雕刻风格的标本板：四角括线与无数字刻度框住娃娃，头部以一弯细月牙表现明暗，旁边的手刻小吊牌写着当前天气（Still、Breeze、Overcast、Fair、Drizzle）。等待输入时，细线思绪云缓缓飘入；风吹时娃娃和吊牌顺风摇摆，裙摆像布料一样鼓起，下雨时布料湿垂。左上角的“新对话”可开启新对话，悬停时整块标本板高亮，点击任意位置均可。原“对话列表”标题行已移除，聚焦和搜索移到侧栏按钮旁。可在“外观 > 主界面”关闭，关闭后保留新对话图标。不可见时暂停动画；性能模式下自动隐藏，设置中也会提示此时不可用。
- 今日聚焦：侧栏顶部搜索左侧的今日环按钮只显示系统时区今天 0 点以来活跃的对话，按最新排序，右侧以项目名或“任务”标签代替时间（悬停可查看时间）；再点一次回到项目和任务。
- 侧边栏分为“项目”和“任务”。无需选择项目即可创建任务，并拥有持久保留的独立工作目录；新会话可在发送第一条消息前选择项目或独立任务，后续新建会话沿用当前归属。
- 设置 › 新对话的默认模型可同时设置推理强度，新对话将以该强度开始。
- 从分支菜单新建 worktree 时可为分支命名（默认取自对话标题），之后也可通过“重命名分支…”修改。名称可包含字母（含中文）、数字和 - _ . /，最多 60 个字符；重命名已推送的分支前会先确认，因为远端分支和拉取请求仍保留旧名称。

### 问题修复

- MCP 密钥不再出现在进程参数里，生成的 MCP 配置文件只对当前用户可读；本地 MCP 代理拒绝来自网页的请求。
- Copilot 请求增加超时，停止回复在所有 ACP provider 和 Copilot 上都有强制关闭兜底；provider 退出后残留的确认卡片会被收起。
- 资料库缺失关键字段时保持只读而不是被覆盖，恢复后只保存一次；损坏的轮次文件会被移到一旁，不再让对话一直保存失败；退出时 MCP 关闭期间的改动也会写入。
- MCP 引导面板不再吞掉其他窗口的 Escape；detached 状态下禁用推送；图标按钮补齐读屏标签；模型设置页遇到重复数据不再崩溃。
- workspace 记录损坏时保留会话，并阻止异常 workspace 执行。恢复前保留原文件及损坏记录，已恢复的会话不再计入跳过数量。
- 项目旁的数字只统计侧栏里可见的对话，不再把子智能体和 Hydra head 算进去。DeepSeek Harness 等 ACP provider 在模型已加载时不再误报“无法加载模型”。
- 补齐了 Codex、Command Code、ACP 和 OpenAI 兼容接口里的工具标题、上下文压缩提示与 Agent 进程错误等文案的中文。
- 有对话在进行时，关于页的安装更新按钮置灰并提示原因，对话结束后可用。Provider 启动超过 90 秒没响应时，这一轮会报错结束，可以直接重发。
- 本地 MCP 代理限制同时连接数和请求读取时间，本地连接断开时一并结束上游转发；上游中途出错时不再假装正常结束。
- MiniMax Code 不再把 Tivano 的权限模式留在 mcode 全局配置里：修改前先记下你原来的模式，最后一个 MiniMax 会话结束时写回，崩溃后也会补写。探测模型不再改动它；单个模型探测失败也不再让整个模型列表加载失败。
- 删除未完成或未落地的 Hydra head 时，会先把改动存为补丁再删除其 worktree，不再留下孤立副本。
- CLI 任务启动途中删除对话会释放该任务，退出和更新不再被一直挡住；外部回合结束也不会再重建已删除对话的文件。
- 模型列表加载期间手动选的模型不再被默认模型覆盖；回退含重复记录的对话不再崩溃。
- 树状活动视图里手动展开的工作组，收到新回复时保持展开，滚动回来时保留已加载的步骤。
- 侧栏收起或被设置页遮住时 Skylight 停止动画，数量变化不再让动画从头开始。设置页滚动时，放大的纪念物不再错位。
- 钥匙串无法读取时不会发放或覆盖纪念物，损坏的副本会先备份再修复。CLI 创建的 worktree 显示已就绪但目录丢失时，会报错而不是在项目目录里执行。
- 默认模型选择器按服务商分步加载；刷新失败时仍可选择已载入模型，错误提示完整换行，并提供重试。
- Claude、Copilot 权限切换未获确认时停止发送，Pi 权限门禁保存失败时也不再继续发送；同时修复 Copilot 未正确进入人工审批的问题。
- “添加到回复”现在引用打开菜单时选中的文字；没有属于当前消息的有效选区时才引用全文。同一消息的不同片段可以分别引用，重复片段不会再次添加。
- MiniMax Code 0.6.12 的 Token Plan 会话会避开无效的空模型变体；切换模型时清除已不可用的推理档位，启动失败仅提示一次，并给出处理建议。
- 兼容 OpenCode 新版凭据表格，明确 Z.ai 的 GLM Coding Plan 密钥要求，并保留 Command Code 返回的额度错误详情。
- 内置终端选择真正的等宽字体，让英文字符、中文和光标保持对齐。
- 离线源码目录迁移通过后台任务运行时，会保留文件权限和空目录；恢复本地改动和回退时也会精确保留这些信息。
- 源码目录迁移即使在恢复工作树创建前中断，也能还原本地改动；短暂的仓库访问结束后，会重新核对冻结快照再继续。
- 迁移校验不会改写 Git 索引，避免因自身刷新文件状态而误判有外部改动。
- 钥匙串拒绝保存时，API 密钥不再以明文保存；设置中会提示失败，旧版本留下的明文密钥会迁入钥匙串，来自 shell 环境的密钥也会注明来源。
- 资料库文件中个别条目无法读取时，其余内容照常加载，原文件和无法读取的条目分别另存；文件整体损坏时，改用上次启动时保存的副本。
- 修复：本地控制任务等待时排队追加消息反复空转；仅结构变化的标题和列表保留旧格式；已停止的 API 回复被记为完成；OpenAI 兼容流式接口的多行事件；Hydra 落地后含特殊字符的冲突文件名。
- 性能模式不再永久关闭“更通透的玻璃”。
- DeepSeek Harness 的桌面配置包含 Inspector 插件时，不再出现模型加载失败或对话报“Internal error”；Tivano 会跳过依赖桌面端服务的插件，错误信息也会附带具体原因。
- 收起或展开侧栏时，窗口左侧不再闪现第二个侧栏按钮。
- 本地打包的 Release 版本不再带有 Xcode 的调试器授权，并通过显式 Release 授权文件保留语音输入所需的麦克风权限。

### 优化改进

- 侧栏 Skylight 在隐藏时不再计算状态，状态汇总与活动树、进行中指示器改为一次遍历，减少主线程开销。
- 从 2.0 降级回 1.x 后，独立任务会从侧栏消失；数据仍保留在磁盘上，可重新升级找回。
- 设置页更有呼吸感：板块之间间距加大，每个服务商和模型分组自成一组，标题紧贴所属内容。“关于”新增“版本信息”标题，有新版本时更新卡片会把下方内容推下去，不再留下空白。弹出层保持原有的紧凑间距。
- 主题名称始终显示英文原名；provider 卡片里的版本与更新说明改为普通灰色文字，不再橙色高亮或加粗。
- 项目图标精选扩充至 155 个 emoji，按八类用途分组，支持中英文关键词搜索，并提供搜索示例和明确的无结果提示。
- 文本生成设置移到“通用”的“电源”上方。移除 GitHub 仓库克隆功能及所有入口，保留 GitHub 登录。
- 本地安装包、安装备份和产品截图改存源码目录外。每次截图使用全新目录，不再清空历史记录；设计候选稿和历史交付资料与维护中的正式资源分开归档。
- “项目”和“任务”均可点击标题折叠，并记住展开状态。侧栏各分区标题统一字样、左右边缘对齐，分区间距更紧凑。添加项目统一使用“项目”旁的 +，移除底部“添加项目”行；任务不再按日期分组。侧栏内的收起按钮更小，侧栏隐藏时，工具栏中的按钮仍保留圆形底托。
- 新会话中的项目名使用主题色，切换入口更明显。项目图标改从侧栏右键菜单编辑，保留已有图标，并移除原项目启停和标记设置。

- 缓存会话隐藏时保留布局，减少侧边栏展开、收起时的消息重复测量。隐藏输入框暂停改动统计刷新，隐藏 Hydra 进度条暂停动画并释放动画名额。
- Hydra 设置将“组合”移到子智能体选项前，并说明默认推理强度限制的生效条件。Codex 历史仅保留归档选项，限制说明移入帮助弹窗，移除了常驻的运行位置说明卡片。
- Hydra 子智能体完成后自动收起面板，团队全部结束后，侧边栏卡片和折叠数量摘要也会隐藏。工作报告仍可从聊天中的完成卡片查看，并移除了对应的两个显示设置。
- 本地开发与发版可共用一个长期源码目录。离线迁移会备份并保留本地工作和项目绑定，同时提供回退入口。
- 长回复结束时不再在主线程重新解析全文，打开长对话时优先准备最新回复；闲置对话在后台保存后再释放。
- 信物页静止后停止动画并遵循性能模式；网络传输和 MCP 代理连接结束后及时关闭，并限制过大的请求和响应。
- 设置搜索支持中文页面名称，Hydra、模型、CLI 更新、归档、快捷键和实验室的说明更准确；今日聚焦不再列出辅助对话和面板对话。
- 侧栏每次启动都会展开，移除“启动时展开侧栏”设置；手动收起只在本次运行内有效。
- 侧栏顶部的今日环、搜索和侧栏按钮统一视觉尺寸与线重，侧栏按钮也有相同的悬停圆底；侧栏与对话顶栏的所有图标颜色一致。未设置图标的项目改用更轻的双色文件夹。
- 信物页可点击处显示手形光标；晴天窗的悬停底色改为直角，与四角刻线对齐。
- 信物展开和收回时从枝条上平滑起落，落回时不再跳动。进入信物页后枝条只摆动几秒便静止并停止重绘，鼠标移到信物上会再次轻摆。

### Thanks

- No outside contributors.

## [1.4.0] - 2026-10-18

### English

### New features

- Add Alpha, a settings page for early features behind one master switch, off by default.
- Talk with Codex out loud with Codex realtime voice, an Alpha feature off by default. Start a call from Start voice in the sidebar, or from the waveform button in any Codex chat to continue that chat by voice; Codex listens, answers and does the work in the chat. Needs Codex 0.159 or later signed in with ChatGPT.
- DeepSeek Harness joins the providers, run through its `dsh` command line. It signs in with the DeepSeek account of your DeepSeek Harness app or uses the DeepSeek API key set in Settings, and each chat picks Standard, PTC, Minimal agent or Creator mode and keeps the plugins and default model of your DeepSeek Harness app. Without a sign-in, Sign in opens the DeepSeek Harness app. With Hydra on, its own sub-agent tools are switched off so heads go out through Hydra.

### Bug fixes

- A Pi chat keeps its running indicator when Pi retries after a provider error, and gets it back when Pi picks the work up again by itself. The retry notice now names the error Pi hit.

### Refinements

- The app stays responsive while agents stream long replies: hovering, clicking and switching Settings pages no longer wait behind the reply being written. The paragraph still being written becomes selectable as soon as it finishes appearing; finished messages are selectable right away as before.
- Building rich text for a streaming reply does less work per update, especially for long paragraphs.
- While Settings or the voice stage covers a chat, its shimmer, effort-slider and call-timer animations pause, and other chats are no longer prepared in the background.
- Settings pages, the sidebar, the command palette and shared controls redraw less when you hover or switch, and collapsed provider cards are no longer built until you open them.
- Attachment previews and file icons stop re-reading the disk on every redraw.
- Settings › Power now has a dropdown instead of a switch: Off, Keep Mac awake, or Keep Mac and screen awake. The last one also keeps the display lit while tasks run, so agents can run front-end tests. Your earlier on or off choice carries over.
- Copy in a message's right-click menu now copies what you selected, and the whole message only when nothing is selected. The markdown option is renamed Copy message as markdown, since it always copies the whole message.

### 简体中文

### 新功能

- 新增「实验室」设置页，集中放置早期功能，由一个总开关控制，默认关闭。
- 新增 Codex 实时语音（实验室功能，默认关闭），可直接用语音和 Codex 对话。从侧边栏的「开始语音」发起通话，或在任意 Codex 会话中点击波形按钮，用语音继续该会话；Codex 会倾听、回答，并在会话中完成工作。需要 Codex 0.159 或更高版本，并使用 ChatGPT 登录。
- 新增 DeepSeek Harness 服务商，通过其 `dsh` 命令行运行。直接使用 DeepSeek Harness 应用里已登录的 DeepSeek 账号，或设置里的 DeepSeek API 密钥，每个会话可选标准、PTC、极简或创意模式，并沿用你在 DeepSeek Harness 桌面版里装的插件和默认模型。开启 Hydra 时会关闭它自带的子代理工具，由 Hydra 统一派发。未登录时，“登录”会打开 DeepSeek Harness 桌面版。

### 问题修复

- Pi 遇到服务商错误后自动重试时，对话的运行图标不再熄灭；Pi 自行继续工作时图标也会恢复。重试提示现在会写出 Pi 遇到的具体错误。

### 优化改进

- Agent 流式输出长回复时，应用保持流畅：悬停、点击和切换设置页不再被正在写入的回复卡住。正在写入的段落在淡入完成后即可选中文字；已完成的消息与以前一样可立即选中。
- 流式回复生成富文本时每次更新的计算量更小，长段落尤其明显。
- 设置页或语音界面遮住对话时，对话里的闪光、强度滑条和通话计时动画会暂停，也不再在后台预先准备其他对话。
- 设置页、侧边栏、命令面板和通用控件在悬停与切换时重绘更少；折叠的服务商卡片在展开前不再构建。
- 附件预览和文件图标不再在每次重绘时重复读取磁盘。
- 设置 › 电源 的开关改为下拉选项：关闭、保持唤醒、保持唤醒并亮屏。最后一项会在任务运行时让屏幕也一直亮着，方便 agent 做前端测试。之前的开关选择会沿用。
- 消息右键菜单里的「复制」现在复制你选中的文字，没有选中时才复制整条消息。Markdown 选项改名为「将消息复制为 Markdown」，因为它始终复制整条消息。

### Thanks

- No outside contributors.

## [1.3.14] - 2026-10-17

### English

### New features

- Drag a project folder in the sidebar to reorder it. While you drag, every folder folds to a single row so a folder with many chats stays easy to move, and each goes back to its own open or closed state when you drop it.
- Images an agent sends back now show in the chat: pictures Codex generates, pictures tools return such as browser screenshots, and Markdown image lines that point to a local file. Each appears as a medium tile you click to open large, and a step that produced an image stays above the reply after its turn folds.
- Each provider now shows which agent runs it and which account it uses, such as `Codex CLI · ChatGPT plan or API key` or `Tivano Code · API key`. It appears on the provider's header in Settings › Providers, in the welcome checklist and in the tooltip of the model button.
- Settings › Providers has a Show remaining usage switch that hides plan limits and balances from that page. The usage ring in a chat still shows them.

### Refinements

- Providers are grouped as Agent CLIs and Tivano Code and listed A–Z in Settings and in Choose providers, and a signed-in provider no longer jumps to the top. Model lists are A–Z too, while the models you pinned keep your own order.
- Pi and omp no longer show plan usage.
- OpenCode Zen and OpenCode Go are now one OpenCode provider. The opencode CLI decides which plan or API it uses, and your chats, pinned models and settings from either keep working.
- Reduce repeated work when adding to long chat histories and preparing them for saving by processing only new rows and reusing valid save positions.
- Reuse the existing text layout when streaming text with links grows without changing its earlier content or styling, preserving text selection as it appends.
- Skip scroll-wheel hit tests for hidden chats and reduce repeated character processing when updating text fade-in state.

### 简体中文

### 新功能

- 可在侧边栏拖动项目文件夹来调整顺序。拖动时所有文件夹会临时收起为单行，会话再多的文件夹也好拖；松手后各自恢复原来的展开状态。
- Agent 发回的图片现在会显示在对话里：Codex 生成的图片、工具返回的图片（如浏览器截图），以及回复中指向本地文件的 Markdown 图片行。图片以中等尺寸的方块展示，点击可放大查看；回合折叠后，产出图片的步骤仍会留在回复上方。
- 每个服务商现在会标明由哪个 agent 运行、用哪种账号，例如 `Codex CLI · ChatGPT 套餐或 API 密钥`、`Tivano Code · API 密钥`。显示在设置 › 服务商的标题行、欢迎页的服务商清单和模型按钮的悬停提示里。
- 设置 › 服务商新增“显示剩余额度”开关，可在该页隐藏套餐额度和余额；聊天里的用量圆环仍会显示。

### 优化改进

- 服务商分为“智能体 CLI”和 Tivano Code 两组，设置页与“选择服务商”弹窗都按 A–Z 排列，已登录的服务商不再被提到最前。模型列表同样按 A–Z，你固定的模型保持原顺序。
- Pi 和 omp 不再显示套餐用量。
- OpenCode Zen 与 OpenCode Go 合并为一个 OpenCode 服务商。用哪个套餐或 API 由 opencode CLI 决定，原有的对话、固定的模型和设置继续可用。
- 向长对话历史追加内容时只处理新增行，准备保存时复用仍有效的保存位置，减少重复计算。
- 含链接的流式文本追加时，若已有内容和样式未变，会复用已有文本布局，并保留文字选择。
- 跳过隐藏对话的滚轮命中测试，并减少更新文字淡入状态时的重复字符处理。

### Thanks

- No outside contributors.

## [1.3.8] - 2026-10-16

### English

### New features

- Choose a Z.ai region in Settings, Global or China. China talks to open.bigmodel.cn instead of api.z.ai; existing setups stay on Global.

### Bug fixes

- Show the attachment's flight into the composer, which was drawn outside its window and never appeared.
- Stop a long reply from stalling for a moment when it finishes streaming; the parse made while it streamed is reused.
- Keep link-heavy messages scrolling smoothly while their site icons load.
- Release a closed composer's memory after it has shown slash or @ suggestions.
- Stop a finished turn's steps, a work group or a tool's output from blanking the conversation for a moment when expanded or collapsed.
- Keep a reader who scrolled up from being pulled back to the end when content above them shrinks.
- Keep Tivano responsive while an update's signature is checked.
- Let Tivano quit even when its library never finishes loading.
- Let Escape close the file picker opened from the message editor instead of the editor.
- Focus a new composer reliably when it first appears.
- Stop quick picks in a question card from skipping a page, and keep the MCP setup panel open when the connection drops right after connecting.
- Show the Chinese text for context menus, sidebar actions, confirmations, tooltips, search fields and file counts that still appeared in English.
- Show when each banked Codex reset expires. Codex sometimes lists the count without the resets, so Tivano asks once more and keeps the last known dates.
- Show the real reason a usage read failed instead of asking to log in again, refresh usage after logging in through Tivano, and word a timed-out read plainly.
- Recognize Cursor, Kimi and native Grok installs for CLI updates, and point a Devin CLI bundled with the desktop app to that app for updates.

### Refinements

- List the settings pages in one run without group gaps, with Hydra after Models.
- Show release notes in the app's active language, with English as the fallback when Chinese notes are unavailable.
- Add a Refresh button for Codex usage alone, and fold each CLI's update details into a version line and a status line.

### 简体中文

### 新功能

- 可在设置中为 Z.ai 选择区域：国际站或中国区。中国区使用 open.bigmodel.cn 而非 api.z.ai；已有配置保持国际站不变。

### 问题修复

- 修复附件飞入输入框的动画因绘制在窗口外而无法显示的问题。
- 复用流式输出期间已完成的解析，避免长回复结束流式输出时短暂卡顿。
- 在网站图标加载期间，保持包含大量链接的消息滚动流畅。
- 关闭输入框后，释放因显示斜杠命令或 @ 建议菜单而占用的内存。
- 修复展开或收起已完成轮次的步骤、工作组或工具输出时，对话短暂空白的问题。
- 向上阅读时，上方内容收起不再将阅读位置拉回对话末尾。
- 检查更新包签名时，保持 Tivano 正常响应。
- 即使资料库始终未能完成加载，也能退出 Tivano。
- 从消息编辑器打开文件选择器后，按 Escape 关闭文件选择器，不再关闭编辑器。
- 新输入框首次出现时可靠地获得焦点。
- 修复问题卡片中的快捷选项跳过一页的问题，并在连接刚建立就断开时保持 MCP 设置面板打开。
- 补齐上下文菜单、侧栏操作、确认提示、工具提示、搜索框和文件数量中仍显示为英文的中文文案。
- 显示每个 Codex 储备重置的到期时间。Codex 有时只返回数量而不列出明细，Tivano 会再查询一次，并保留上次获取的日期。
- 用量查询失败时显示真实原因，不再一律提示重新登录；通过 Tivano 登录后会刷新用量，查询超时也改为易懂的提示。
- CLI 更新可识别 Cursor、Kimi 和原生安装的 Grok；随桌面应用安装的 Devin CLI 会提示通过该应用更新。

### 优化改进

- 设置页列表不再分组留空，Hydra 移至模型之后。
- 按应用当前生效的语言显示更新日志；没有可用的中文日志时回退到英文。
- 新增仅刷新 Codex 用量的按钮；每个 CLI 的更新信息合并为版本和状态两行。

### Thanks

- No outside contributors.

## [1.3.1] - 2026-10-14

### Bug fixes

- Bring back the composer's and floating controls' Liquid Glass look, now pinned to its active appearance so it no longer whitens when switching back to Tivano.

### Thanks

- No outside contributors.

## [1.3.0] - 2026-10-13

### New features

- The model picker holds up to 30 models. Settings › Models can sort them into named groups: drag models within and between groups, drag a group by its handle to reorder it, and fold groups in Settings and the picker alike.
- The composer's model picker opens with a search field (Return picks the first match), and folds other providers' models in an ongoing chat under one row. In a new chat, Recent offers the last pair and the last model new chats started on.
- A new chat can run on a temporary Hydra pair made right in the model picker: it uses Settings › Hydra's pair editor, belongs to that chat alone and is never saved as a pair, but stays in Recent for the next new chat.

### Bug fixes

- Keep the composer and floating controls from whitening when switching back to Tivano, with stable translucent surfaces, clearer contrast and subtle edge highlights.
- Keep a text selection in a chat from breaking mid-drag when another app's overlay, such as a notch drop zone, appears on screen.
- Keep the newest tick of a long conversation's minimap above the composer, so it can be clicked again.
- Stop the activity tree view from blanking the conversation for a moment when a work group is expanded or collapsed.

- Keep the message editor steady by preventing outdated row visibility updates from repeatedly rebuilding the conversation timeline.

### Refinements

- A turn's steps now show as an activity tree by default: a count summary, then a thin branch per step that draws in as it arrives.
- Remove Settle; previously settled threads return to the regular list. Use Archive to organize finished threads.
- Remove the floating usage panel; click the circle to view usage.
- Pause text fade rendering in fully hidden chat columns and resume at the current animation progress when shown, preserving Settings transitions and visible chats.

### Thanks

- No outside contributors.

## [1.2.7] - 2026-10-13

### Bug fixes

- Stop hidden chat columns from repeatedly attempting blank-viewport repairs; resume layout checks when the conversation is shown again.
- Cancel obsolete viewport refreshes and pause elapsed-time updates in hidden chats.

### Refinements

- Update row-height estimates incrementally to reduce repeated history scans during streaming replies.

### Thanks

- No outside contributors.

## [1.2.6] - 2026-10-12

### Bug fixes

- Confirm project removal, include linked chats across projects, and preserve unfinished or modified worktrees.
- Reject invalid usage-limit reset times without crashing, while retaining valid multi-day waits.
- Keep stopped turns' end checkpoints and bound command-diff waits; track observed child processes after their parent exits.
- Cancel obsolete MCP requests, validate tool results, and limit response and search-line sizes.
- Preserve timeline windows and expanded rows during layout changes, and reopen Review after its close animation.
- Approve OMP device calls once, apply the configured Default model, and block hidden chat actions while full-window Settings is open.

### Refinements

- Keep CLI installation environments separate from account credentials and require manual updates after version errors.
- Remove private infrastructure and account details from public documentation and acceptance fixtures, and include OMP icon attribution.
- Resume matching release publications safely and provide a tracked, explicitly installed push guard.
- Settings now opens in the main window, with its pages in the sidebar and the chat kept as it was behind it. The composer, its tabs and approval cards share one floating glass with a theme wash and a thin rim.
- Add a Clearer glass switch to Appearance, on by default. Turning it off swaps the window's Liquid Glass for a lighter system blur that uses less GPU. Performance Mode turns it off, and it is unavailable while a wallpaper is set.
- Preview an activity tree for a turn's steps behind a hidden `workGroupStyle` switch (`tree`; `list` stays the default): a count summary, a thin branch per step that draws in as it arrives, and older steps paged past 60.

### Thanks

- No outside contributors.

## [1.2.2] - 2026-10-12

### New features

- Add the OMP provider with model and effort selection, App permission approvals and Auto fallback, App-run Hydra with independent heads, session fork and resume, todo updates, conversation titles and usage limits.

### Bug fixes

- Show declined OMP permissions as declined, preserve MCP error states, and reject invalid model or effort selections before starting or sending a turn.
- Clear unread result dots immediately when opening or reselecting a conversation, including Hydra panels. Retry visibility checks after initial layout, preserve unread results while the window is hidden or minimized, and keep older acknowledgments from clearing newer results.

### Refinements

- Use OMP's official full-color vector logo and restore Kimi's original icon colors, keeping light and dark mode assets.
- Simplify the About page by removing the repeated introduction and license summary above Credits.
- Add hidden preview switches for comparing upstream styles: Settings filling the main window (`settingsPresentation` = `fullWindow`), a behind-window blur backdrop (`windowBackdropStyle` = `blur`) and unified floating glass on the composer, its tabs and approval cards (`floatingGlassStyle` = `upstream`). Defaults keep the current look.

### Thanks

- No outside contributors.

## [1.1.13] - 2026-10-12

### Bug fixes

- Keep conversation text still during viewport refreshes and window reactivation instead of briefly shifting it down and back.
- Clear a finished chat's green dot as soon as you open it, instead of waiting for its history to finish loading.

### Refinements

- Reorder Hydra pairs by dragging them in Settings, and keep the same order in the model picker. Simplify each pair's model, effort and head limit summary, and rename the cookbook to Pair presets (搭配方案).
- Brighten the Breeze themes' accent to the app icon's own green, the same on dark and light grounds.

### Thanks

- No outside contributors.

## [1.1.7] - 2026-10-11

### Bug fixes

- Keep Hydra tasks in linked worktrees under an existing repository's sidebar project, while preserving their execution and merge checkout. Stop invalid project routes instead of starting in another folder.
- Keep built-in file reads, writes, edits and searches inside the project after resolving symbolic links, and avoid following directory links while searching.
- Ask for approval in Pi Auto mode when a shell command uses redirection, command substitution or unrecognized arguments that may change files.
- Reject out-of-range JSON numbers without crashing the app, including request IDs and numeric tool arguments.
- Share MCP startup between concurrent requests and route server requests separately from replies, discarding duplicate and late replies after cancellation or timeout.
- Preserve unreadable or damaged MCP configuration files, pause changes and offer Retry after the file is repaired.
- Restore only the selected Git paths, including filenames containing wildcard characters, quotes or newlines.
- Keep an old turn's completion from ending a newer turn, and save its final checkpoint in the checkout where it ran.
- Let Diff panels close cleanly through AppKit, and keep a delayed close from clearing a newly opened panel.
- Resume interrupted release preparation and reuse matching release refs and pull requests. Stop publishing when contributor queries fail, read every PR page and match acknowledgements exactly.

### Refinements

- Fade only the main conversation timeline beneath the top controls, keeping the composer glass outside the timeline mask.
- Increase the font size of the conversation title at the top of the chat by 1 pt.
- Show the files a command changes after it moves into another checkout first (`cd ~/other-worktree && …`) on that command's row, with full paths, without counting them toward this chat's revert or Hydra merge. Edits other running chats made there are left out.
- Allow Interface, Content and Code font sizes up to 18, 18 and 17 pt (2 pt higher), and set their defaults to 14, 15 and 13 pt.
- Remove the README statement that rules out remote access, mobile apps, cloud sync, telemetry and a web client.

### Thanks

- No outside contributors.

## [1.1.0] - 2026-10-11

### New features

- Show each provider CLI's installed and latest version in each provider's settings, with Check again and Update buttons and a per-provider switch for update checks. Update through the channel that installed the CLI (Homebrew, npm, bun, pnpm or Claude's own updater), wait for that provider's running tasks to finish first, and hold new sessions until the update completes.

### Bug fixes

- End the whole process tree when Tivano stops an agent session, so MCP servers and commands the agent started no longer keep running after their session is gone.
- Stop a turn whose agent stays alive but goes silent, such as a stalled model stream or a suspended process, instead of showing it as running forever. After five minutes without a word the working line says how long it has had no response; after ten, Tivano stops the turn and ends a session that ignores the stop. Waiting on an approval, a question, a usage limit, a merge or working Hydra heads does not count, and a running tool gets thirty minutes.
- Keep Pi's tool gate in each edition's own library, so Tivano Dev can no longer overwrite the gate Tivano loads into its Pi sessions.
- Read the wait a usage-limit message names, such as "try again in ~158 min", "retry-after-ms" or "reset after 18h31m10s", so auto-continue knows when the limit resets; recognize more spend, quota and credit limit messages, without treating ordinary rate limiting as a spent limit.
- Preserve an unreadable library's original file and save new chats to a separate recovery index. Retry failed saves, keep unsaved chats in memory, and persist library changes before deleting chat documents.
- Keep the existing conversation when an ACP agent rejects a model or mode selection. Let Kimi's model discovery proceed without applying that selection, and fall back to approval controls when a question has no usable answer choices.
- Retain orphaned Hydra worktree copies instead of deleting them at startup, and allow quiet heads to keep running while a tool is active.
- Let mouse-wheel scrolling over code blocks and tables browse earlier messages without snapping back to the bottom. Prevent idle system sleep during usage-limit waits and background tasks.
- Read GitHub's installer digest and wait for Hydra merges and successful chat saves before installing an update. Lock shared external MCP configuration during cleanup and retain failed cleanup requests for retry.

### Refinements

- Build only the messages around the viewport in long conversations, standing measured spacers in for the rest, so scrolling stays smooth however long the chat. Jump straight to the newest messages from far up, hide the jump-to-bottom button reliably while following the reply, pause hover and clicks on rows while the content scrolls or glides, and stream short replies in smaller, more frequent steps.
- Run every Hydra head as a thread of its own, including heads on the lead's provider, which used to run as the CLI's own sub-agents inside the lead's session. Each head now shows its progress, can be stopped on its own and works in its own copy; the lead's own sub-agent tool is switched off while Hydra is on, and turning Hydra on or off or switching pairs restarts the lead's session. Heads left running by an older version settle as stopped.
- Stop updating Claude and Codex silently in the background every twelve hours; version checks are now read-only. A model that needs a newer CLI still updates it and resends the message, and a failed update names the install command to run.
- Keep full patches for only the first 60 files a single command changes, and line counts for the rest, so a codemod or generator touching hundreds of files no longer puts megabytes into the timeline and the thread file. Every file still counts toward the turn and Hydra merges, and count-only files show their path and line counts in the timeline and the diff panel.

### Thanks

- No outside contributors.

## [1.0.10] - 2026-10-11

### New features

- Add Kimi Code through its official CLI and ACP, with native sessions, model and thinking selection, permission modes, image prompts, MCP forwarding and interactive questions. Use Kimi's official icon.
- Add a Power section above Languages in General settings. Prevent idle system sleep while chat or Hydra tasks run, enabled by default; release the assertion when all tasks finish or the option is disabled, while allowing display sleep, manual sleep and lid-close sleep.

### Bug fixes

- Read Claude's context occupancy from its official context report instead of cumulative turn usage. Clear stale readings while the context changes, omit unavailable readings, and show percentages above 100% without overflowing the meter.

### Refinements

- Style bold, italic, strikethrough and inline code in streaming replies from their first word, instead of showing raw markers that restyle and reflow the line once they close. Text that never closes settles as written when the reply finishes, and finished paragraphs no longer keep a per-character map.

### Thanks

- No outside contributors.

## [1.0.6] - 2026-10-10

### Bug fixes

- Let composer text use the full width above a separate bottom control row, so narrow layouts wrap naturally without leaving an empty right-hand column. Keep the send button at the bottom right and collapse the model chip when space is tight.
- Keep replies following the conversation's end as text streams and the layout changes. Restore following when scrolling back to the bottom, while preserving the reading position when browsing earlier messages.
- Compare mirror and GitHub update feeds concurrently within a bounded response window, so a stale mirror cannot mask a newer responding source; preserve known versions and checksums and reject conflicting release metadata.
- Cancel update downloads when their caller is cancelled, settle callbacks once and remove temporary files; never bypass verification when retrying a failed transport.

### Refinements

- Prefer the earliest responding feed for the same version and retry the other trusted installer origin on transport failure, in either direction. Report what the update check found without claiming unreachable sources are current.
- Sync verified installers and update metadata to the restricted domestic mirror after publishing each release.

### Thanks

- No outside contributors.

## [1.0.3] - 2026-10-10

### Bug fixes

- Check public static update feeds before the GitHub Releases API, so normal updates no longer depend on GitHub sign-in or a shared IP's anonymous API quota. Keep the original release endpoint and DMG naming for 1.0.2 and earlier clients.
- Verify the static feed's installer checksum before mounting, alongside the existing Developer ID, bundle-ID, version and Gatekeeper checks.

### Refinements

- Publish update metadata after the notarized DMG is available, with Pages and raw-content fallback sources; reuse local GitHub credentials only for the final API fallback and explain rate-limit failures.

### Thanks

- No outside contributors.

## [1.0.2] - 2026-10-10

### Refinements

- Fill the update progress bar with the current theme's accent instead of a fixed blue.

### Thanks

- No outside contributors.

## [1.0.1] - 2026-10-10

### Bug fixes

- Clear a conversation's completed, failed or interrupted mark once its result has been read, so read history no longer shows a dot; approvals and questions stay marked until they are answered.
- Hold the result mark while a queued message, background task, merge or usage-limit wait is still working, and mark work cut off by a restart as interrupted.

### Refinements

- Redesign the installer window in the brand's light paper and sage, with a hand-drawn arrow toward Applications, and size it so macOS 27 Finder shows it without a scrollbar.

### Thanks

- No outside contributors since the start of this repository's retained history.

## [1.0.0] - 2026-10-10

### New features

- The first stable Tivano release, with provider selection, grouped model lists, sidebar conversation search, and separate Release and Dev libraries.

### Bug fixes

- Restore the Hydra watchdog and serialize automatic merges across editions using the repository lock.
- Apply content font-size settings to sent messages and retry provider CLI discovery after startup.
- Preserve notarization submission IDs and retry temporary status-check failures instead of losing the release workflow after a network timeout.

### Refinements

- Use the Breeze theme, updated conversation and permission icons, and adjustable Interface, Content, and Code font sizes.
- Dissolve scrolling content beneath the title bar and show muted conversation status marks in the sidebar.
- Remove the welcome tour, obsolete shared-library polling, and capture tooling from Release builds.
- Set Release and Dev to version 1.0.0, with isolated data and Developer ID signing.

### Thanks

- No outside contributors since the start of this repository's retained history.

## [0.2.9] - 2026-10-09

### New features

- Show a muted, persistent status mark beside each conversation in the sidebar.

### Bug fixes

- Restart the Hydra watchdog at launch, so a stalled head is stopped again and a quiet one shows how long it has been thinking.
- Automatic Hydra merges in Release and Dev serialize on the same repository lock again.

### Refinements

- Content scrolling under the title bar dissolves into the window instead of being covered by a tinted band.
- With each edition owning its library, saves go straight to disk in the background again: no per-second polling, no cross-process merge on the main thread, and no full reload after every save.
- Clear leftover head copies and day-old unreferenced attachments at launch, and remove the lock files and per-launch MCP folders the shared-library builds left behind.
- Release builds no longer include the screenshot capture tooling.
- Bring Release up to the current Dev features at version 0.2.9.

### Thanks

- No outside contributors since the start of this repository's retained history.

## [0.2.7] - 2026-10-09

### New features

- Group long model lists by family and series to make model selection easier.

### Bug fixes

- Keep Release and Dev libraries, preferences, captures, and Keychain credentials separate from each other and Droppy Code.

### Refinements

- Remove the welcome tour and its settings and menu entries.
- Use plus and minus buttons for font-size settings, with content defaulting to 14 pt.
- Refresh the new-conversation and full-access icons, and match the permission icon to the attachment control.
- Place Models before MCP in settings and soften the Breeze accent.
- Bring Release up to the current Dev features at version 0.2.7.

### Thanks

- No outside contributors since the start of this repository's retained history.

## [0.2.0] - 2026-10-09

### New features

- Search conversations from the sidebar toolbar in a floating search panel.
- Choose which providers appear in settings and model pickers without losing their saved credentials or configuration.
- Optionally hide the top conversation controls until needed.

### Bug fixes

- Decode GitHub release assets correctly so the Release edition can check for updates.
- Apply the content font-size setting to sent messages.

### Refinements

- Release and Dev share version 0.2.0, with stable Developer ID signing for both editions and a notarized Release disk image.
- Simplify sidebar rows and options, expand the toolbar hover region, and organize appearance settings.


- A new default theme, Breeze, takes the avocado green of the app icon as its accent, with Breeze Light and Breeze Dark variants; anyone who has already picked a theme keeps it.
- Compatible Release and Dev editions can run together on the same library, with conflict-safe metadata updates.
- Three font-size settings (Interface, Content, Code; one pixel smaller to three larger) replace Zoom.
- The app icon is Tivano's v1.4 artwork, masked by the system like any other Mac app icon, and Tivano Dev wears an orange DEV corner badge on the same icon.
- Load the library after launch, preserve unreadable chat files for recovery, and release excess idle runtimes.
- Compute timeline viewport frames on demand and debounce active-block resolution.
- Dev packages are built with `-O` and whole-module optimization, for performance testing.

### Thanks

- No outside contributors since the start of this repository's retained history.

## [1.7.4] - 2026-10-07

### Bug fixes
- When Claude picks the work back up by itself after a background command it started finishes, the chat shows as working: the sidebar spinner and the working indicator run, a note says why the turn started, Stop works, and the turn ends like any other. Before, that turn ran with no sign of it.

### Refinements
- While a command Claude left running in the background is still going after a turn ends, the sidebar row shows a spinner and the timeline says "Waiting on a background task" until it finishes.

## [1.7.3] - 2026-10-07

### Bug fixes
- With the activity list set to Project name, every thread shows its project's folder line: threads in a project with a picked icon wore the icon instead and sat on a shorter row.
- Performance mode keeps the window's rounded corners and shadow and paints a solid background in your theme, so the Settings window no longer blends into the main window or shows a seam beside its sidebar.

### Refinements
- When everything a Hydra chat changed is already on main, its note says so ("Already on main: nothing to merge") instead of the unclear "no files left to merge".

## [1.7.2] - 2026-10-07

### Bug fixes
- Droppy Code no longer freezes when Hydra sends out several heads while files in the project are changing: a head waiting on the working-tree snapshot another head had started could spin on the main thread forever.

## [1.7.1] - 2026-10-07

### New features
- Connect GitHub in Settings › Source control, by signing in with GitHub in your browser, through the GitHub CLI login you already have, or with a personal access token, then clone any of your repositories from the sidebar's Add project menu, the welcome screen, the command palette or File › Clone from GitHub. The repository opens as a project with a new thread, and agents can push and open pull requests with the connected account.
- Hydra can archive a finished Codex head's session from Codex's own history so delegated work stops crowding it, with the head's Droppy transcript kept and a follow-up restoring the same session. Off by default, in Settings › Hydra.
- A forwarded chat's first screen names the chat it continues, says whether the carried context was shortened, and offers a way back to the original.

### Bug fixes
- Edits made by one chat no longer show up on another chat's command rows or go out in its merge when several chats work in the same checkout.
- A running turn's card keeps its size when you open its steps: they appear as plain rows under the card instead of growing it.
- Antigravity's usage and default-model reads are skipped while the Mac is offline, so agy no longer opens a sign-in page.
- A working folder with non-ASCII characters in its path no longer crashes the file watcher, launching no longer creates an empty chat, Hydra heads stay out of the standalone chat lists, wide Markdown tables scroll sideways, and the window controls sit where they belong in full screen.

### Refinements
- The app icon, the Droppy logo in Settings and the website's icons wear Droppy's new ultramarine blue.
- Performance mode drops blurs, shadows and continuous animations for less idle GPU work, and holds its own setting during capture runs.
- Hovering the timeline minimap or a progress bar gives a soft, strong or no haptic tick, set in Settings.
- Threads and helpers sit indented under their project folder in the sidebar.
- Model settings build far fewer rows with large catalogues, the hang watchdog also catches livelocks, and the MCP cards lay out eagerly.
- Hydra's progress bars animate in Core Animation layers, so a working head's bar costs the app next to nothing and holds still while you scroll.

### Thanks
- Nikita Tsyganov (@nik1tsyganov): livelocks in the hang watchdog (!408); eager MCP cards (!410); no chat on launch (!413); Hydra heads out of chat lists (!414); scrollable Markdown tables (!415); Codex head history archiving (!416).
- Jason Kneen (@jasonkneen): lighter model settings (!405).
- minier liu (@miniers): capture-aware performance mode (!411); the non-ASCII path crash (!412).
- Dinanath Dash (@DinanathDash): timeline hover haptics (!418); window controls in full screen (!420); sidebar indentation (!422).
- Meric (@realmeric1): Antigravity reads skipped offline (!423).

## [1.7.0] - 2026-09-25

### New features
- Claude Opus 5.5 is available, and OpenAI's newest models (GPT-6 Astra, GPT-5.6 Sol, Terra and Luna) show in the model list as soon as Codex offers them; Hydra's cookbook gains teams built on them.
- Droppy Code keeps Claude Code and Codex up to date by itself: both only update inside their own interactive sessions, so a Mac that used them through Droppy Code alone stayed on an old version and a new model refused to run. The app runs each CLI's own updater twice a day, and a message a model refuses for an outdated CLI is sent again by itself once the update is in.
- Hydra's panel shows recorded lead and head tokens by provider and model, with queue, startup, execution and landing timings where available.
- Custom MCP servers can be added in Settings using a local command or a remote HTTP address, with secret fields stored in the Keychain.

### Bug fixes
- A finished Hydra chat now merges by itself every time and never says it is waiting for, or busy in, another chat: a job that finishes while another merges goes right after it, its merge request is built on the remote as it is now so a checkout that fell behind no longer opens a conflicting one, and each chat keeps one merge request that a retry updates instead of opening a new one every five minutes. A failure that clears by itself is retried quietly within a minute.
- Settings cards and the chat timeline lay out eagerly, so a row at the edge of the window can no longer freeze the app.
- Droppy Code writes far less to disk: the library is saved at most every four seconds instead of after every status change, long chats save less often while a turn runs, and web responses are no longer cached on disk. A busy team had written over two gigabytes in an hour and a quarter.
- Local file links in chat open again, Codex token spend is labelled with the turn's model, and the Codex lead no longer shows up among Hydra's worker events.
- The Hydra sidebar auto-hide setting persists and defaults to off.
- Token activity separates what it measured from what it inherited: daily totals recorded before spend kept its source are still counted, and the line under the grid names how much of the year's total those are instead of presenting them as measured.

### Refinements
- Restored the previous Droppy Code design and removed the judgment service integration.
- Hydra parses streamed delegations incrementally, reuses incremental checkout snapshots and avoids repeated timeline scans while waiting to land edits.
- Native API providers run up to four independent automatic read tools concurrently and load bounded root project guidelines.
- A dedicated Appearance pane with app-wide zoom, sharper text and the terminal's font; OpenCode Zen and OpenCode Go are separate providers; model and provider settings collapse.

### Thanks
- Nikita Tsyganov (@nik1tsyganov): the Hydra auto-hide setting (!358); Antigravity no longer gets Claude's MCP flag (!373); typed Hydra judgments (!374); a held-back delegation block is never silent (!375); local file links (!397); the Codex lead out of worker events (!398); Codex token spend per model (!400); eager layout against the edge-row freeze (!402).
- Bryan Galdámez (@JosueGalRe): custom MCP server definitions and settings (!305); collapsible model and provider settings (!376); main build fixes (!377).
- René (@diazdesandi): shared helpers and the AGPL string (!378); OpenCode Zen and Go split (!379); the Appearance pane, app-wide zoom and the terminal's font (!380); the timeline's lazy window anchor (!381); audit cleanups with five bug fixes (!401).

## [1.6.1] - 2026-09-18

### New features
- Concise AI replies are now an option in Settings, General: built-in guidance keeps replies, code comments and Hydra head work focused, and takes effect on the next message. A thread can also be forwarded to a new thread, carrying its request and context so the work can continue with another model.

### Bug fixes
- A framework's own raise while a notification is posted no longer ends the app: on macOS 27 a popover's window coming on screen can make the framework's remote view throw from inside the notification that announces it, and because that happens during a SwiftUI layout pass AppKit catches the exception and stops the app, which is how both reports of September 18 read, both from the release-notes cards on Settings › About. The app's notification posts now catch such a raise, log it with the raising observer's frames, and carry on, so the popover's window ordering and the popover itself still finish.
- The New features, Bug fixes and Refinements cards on Settings › About open their section in a card under the row instead of in a popover: the notes read in the page and scroll with it, and tapping the card again, or the card's close button, folds them away.
- The Codex usage panel names the ChatGPT plan the way OpenAI sells it: the `pro` account type is the $200 Pro tier and now reads "Pro 20x" where the panel showed "Pro", and `prolite` reads "Pro 5x" where it showed "Prolite"; plan types only Codex spells get its own CLI wording, so the self-serve business Pro Lite entitlement reads "Business Premium" instead of "self_serve_business_prolite".
- CommandCode plan names now match commandcode.ai's tiers, including Go, GOAT, Pro, Provider, Max 10×, Max 20× and Teams Pro; an unfamiliar plan ID is still shown in readable words instead of disappearing.

### Refinements
- Favicon lookup now prefers the site's DuckDuckGo icon with Google's service as a fallback, and removes solid white backgrounds so icons sit cleanly on the chat surface.
- Moving a thread to another project now follows the same project-move path everywhere and automatically expands and reveals the moved thread in the sidebar.

## [1.6.0] - 2026-09-18

Droppy Code 1.6.0 folds a finished turn into its "Worked for …" line with the turn's steps behind the chevron, keeps a running turn's steps, and the agent's thinking, in the card below its bar, hands a chat stopped by its provider's usage limit a New thread that carries the work on, lets the heads leave the sidebar on their own, and puts a mark of your choosing in front of a project's name; Netlify joins the MCP catalog. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Netlify joins the MCP catalog: sign in with your Netlify account and a thread can create projects, deploy sites and manage environment variables.
- Projects wear a mark: each project can be given an emoji or an SF Symbol in Settings, General, Projects, and the activity list can draw that mark in front of a thread's name in place of the line that named the project, one line per thread, while what the thread is doing still reads at the end of the row. The choice of list sits on the General page and on the welcome screen, and a new install starts on the compact one.
- A chat that stops on its provider's usage limit now leaves a notice with two ways out beside it: Cancel stops the automatic continue and leaves the chat to you, and New thread stops the wait and opens a new chat of the same project holding a hand-off of the request and of what the stopped turn had already done, so another model can be picked there and sent it.
- Heads can leave the sidebar by themselves: with Auto-hide heads in the sidebar on (Settings, Hydra, Heads), a chat's head card shows while one of them runs and goes once every head of that chat has finished, coming back on its own when one starts again. Off by default, so heads stay where they are.

### Bug fixes
- The GitLab MCP server no longer looks like a hiccup on GitLab's side: a top-level group that hasn't allowed MCP client access is answered by GitLab 19.4 and earlier with 404 instead of "MCP server disabled", so connecting ended in "gitlab.com didn't answer its MCP address (404), try again in a few minutes". That answer now opens the steps to turn MCP on for the group, and the app's own MCP proxy answers a path it has no route for with 502 rather than a 404 that reads as the server's reply.
- Scrolling through the chat and its panels no longer fights the reader: the timeline reads wheel ticks and a viewport that changes height as the reader's own movement rather than as content arriving, so rows landing or the composer growing never tugs anyone who is still scrolling, and the Settings pages settle a scroll burst without re-evaluating the page on every frame.
- The diff panel builds a file's rows once per change and drops a scroll request a newer one has replaced, the model list keeps its measured row heights without re-evaluating the page for every measurement, a pre-measured popover lays its content out once instead of on every parent update, the update notes on the About page scroll with the page instead of inside a scroller of their own, and the shortcuts page lays out whole so its scroller knows its content height.

### Refinements
- A finished turn reads folded: it shows its final reply with the turn's plans and any warning, and the steps it took, its heads and its changed-files card wait behind the "Worked for …" line, which opens them in a card of their own.
- A running turn keeps its work on the working line: the progress card stays the card it is, and the steps the turn is taking, with the agent's thinking and what it says between them, open under it once its chevron is clicked; the reply that concludes the turn lands in the chat once the turn ends.
- The Chronological order switch is gone from Settings › Conversation: a turn reads folded until its line is clicked, which is what the app always does now, so the switch had nothing left to change.

### Thanks
- René (@diazdesandi): confined `search_text` to the project root with a `--` guard against flag smuggling, kept plan mode blocking edits after approve-for-turn, cleared the save timer handle before `saveNow` bails and stopped `WorkingTreeWatch` tearing down the registered watch when a second caller lost the race (!307); one OpenAI-compatible session and one Keychain behind the DeepSeek, Meta and Z.ai providers (!308).
- Bryan Galdámez (@JosueGalRe): finished turns open chronologically and a head wears its profile (!283); native heads routed to head profiles on Claude, Codex and Copilot (!285); the pair editor keeps its effort row for a model whose catalog entry declares no efforts yet (!304); a model catalog probe that came back empty is tried again on the next ask instead of closing the provider's list for the rest of the run (!306).
- Nikita Tsyganov (@nik1tsyganov): named the parts of the Pi usage sum so it type-checks (!293).

## [1.5.6] - 2026-09-17

Droppy Code 1.5.6 stops a new chat from being told its agent had lost a conversation that never was, and draws the uncapped Heads at once choice as an infinity sign. Apple silicon, macOS 26 or later. Signed and notarized.

### Bug fixes
- A first message no longer opens with "Claude no longer has this conversation. It starts a new one here": the session started while the message was being typed was resumed as a conversation the CLI had never written whenever a setting changed the launch in between (effort, fast mode, the heads' provider coming online, a heads cap). A session's ID now reaches the chat with its first message, and a session replaced before then is followed by one that starts fresh, with no resume attempt and no warning.

### Refinements
- The Heads at once row on the Hydra page shows the uncapped choice as an infinity sign instead of the word Off; it reads as "No cap" to VoiceOver, the wording a pair's own editor uses.

## [1.5.5] - 2026-09-17

Droppy Code 1.5.5 gives a Hydra pair more to work with: named head profiles that route each task to a purpose-built configuration, a global cap on how many heads work at once, custom pair names with fused icons, and a running turn that can stay in the order it arrived. It also fixes resumed Claude Code chats the CLI no longer remembers, token totals for resumed chats and cross-project heads, and merges that a head's build output had swamped. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- A pair can carry head profiles: purpose-named configurations ("quick", "deep", "visual" or any word) with their own provider, model or effort, edited in the pair's Head profiles section in Settings. The lead hears which profiles exist and routes each task to one by name in its delegation block; a task without a profile, or with a name the pair does not have, runs on the heads' shared model as before.
- Chronological order, a switch in Settings › Conversation: a running turn's replies and tool runs stay in the order they arrived instead of the steps before the last tool call gathering into the working line. Off by default; finished turns keep their fold either way.
- Heads at once, a row of buttons on the Hydra page: cap how many heads work at a time for every chat, Off or 1 to 8, without setting up a pair. Off by default; a pair with a lower cap of its own keeps it.
- A pair can carry a name of its own, typed on the Hydra page in Settings, and shows as a fused icon of its lead's and heads' provider marks in the composer's model picker and model chip.

### Bug fixes
- Opening the working line while scrolled up now follows the stream: the timeline pins to the end and keeps up with the reasoning as it arrives, instead of leaving the expanded thinking fixed while the text streams out of view below.
- OpenCode models show their reasoning levels before a chat starts: the effort slider no longer says "This model has one reasoning level" for a model that has several until the first message is sent, and starting a chat no longer forgets the levels of every other OpenCode model. OpenCode reports the levels of the model a session is on, so the catalog now asks it for each model in turn, the way it already did for Cursor.
- Resuming a Claude Code chat whose conversation the CLI no longer has ("No conversation found with session ID") starts the session over instead of leaving the chat stuck: a CLI that exits before answering the first request is treated as a lost session and a new one begins.
- Token totals are right again for resumed chats: a resumed Codex chat no longer adds the whole conversation's total on every turn, Claude Code usage is counted per turn, and heads working in another project count toward their chat.
- A merge no longer carries a head's build output: files under build folders that a head's command touched are left out of the merge and its command rows, so a merge that succeeded is no longer reported as one that did not.
- Heads sent to another project now form that project's merge: their landed files were reported as outside every project because the paths were never anchored to that checkout.
- The Hydra reports popover no longer jumps when a head's report is opened: expanding a report no longer animates the toggle the way the popover's height is measured, and the report lays out eagerly instead of lazily, so the popover takes its height once rather than resizing a second time after the rows appear.
- Settling a chat with the Settled section folded no longer leaves its row fading out in the empty space below the header: the row's ghost follows the header as the list closes up and is absorbed into it, and a ghost leaving past the list's edge slips out without fading on the way.

### Refinements
- The disk image opens to a styled drag-to-Applications window, with its own background and the app icon as the volume icon, the same installer window Droppy has.
- The merge card in the timeline now walks a track of dots, one per stage, that fills as the merge moves through its stages, with the head hopping along above it and giving a small bounce once every dot lights; finished heads and the merge pill settle into place with a glide transition.
- Head popovers now open on the head itself when a head's name or mention is clicked in the timeline: a finished head's pill opens its report under a header with the head's glyph, name, status and task, and a brief's pill opens the brief the same way, while the delegation card names each head it summons with its glyph and the project it goes to.

## [1.5.4] - 2026-09-17

Droppy Code 1.5.4 gets a Hydra team moving sooner: heads start the moment their brief is written rather than when the lead's whole reply is done, a lead can send heads to any project in the sidebar, and an older Claude Code no longer fails to launch when Hydra is on. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Heads start while the lead is still writing: each one goes out the moment its entry in the delegation block is complete, so the first head is working before the last brief is typed.
- A lead can send a head to another project in the sidebar, or to any git repository on the Mac by path, which then joins the sidebar. Each project's work lands and merges on its own.

### Bug fixes
- With Hydra on, a Claude Code older than the flags Droppy Code passes it no longer fails at once with "unknown option": the app checks what the installed CLI understands and passes only that.
- The app no longer aborts when a window's chrome is redrawn in the middle of macOS laying out the title bar.
- A merge whose files were already on the default branch, taken along by another chat or by hand, no longer posts a card about it: the merging pill simply goes.
- Hydra's merge summary no longer lists the build output, ignored paths and a sibling chat's files it left out, which read as if something had gone wrong.

### Refinements
- The picture tiles in Settings (sidebar layout, heads' panels, working line, checkouts) are redrawn as crisp little windows that fill their tile, and the part each option changes lights up in accent on the chosen one.
- The source is arranged in four layers, Core, Services, UI and App, so a change to a model, a provider or a view has one home.


## [1.5.3] - 2026-09-17

Droppy Code 1.5.3 puts the keyboard in charge: Escape stops a turn and takes it back, ⌘B hides the sidebar, ⌘1 to ⌘9 switch threads, a drag selects text across a whole reply, and a large Hydra team no longer freezes the app. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- A drag selects text across a finished reply the way it does in any Mac text view: headings, paragraphs and lists are one run of native text, so the selection runs from one paragraph into the next and ⌘C copies it. Code blocks and tables keep their own views between the runs, and links still open on a click.
- Escape on a running turn stops it and takes it back: the conversation and the provider's context rewind to before it, and the message returns to the chat box to be changed and sent again. Files stay as the turn left them.
- Escape dismisses whatever is in front: a popover, a panel, a sheet, the terminal's search. A field being typed in keeps its Escape.
- ⌘B shows and hides the sidebar.
- ⌘1 to ⌘9 switch to the first nine threads, before the menu bar sees the chord.
- ⌘W archives the thread, and the question names it: Return archives, Escape keeps it, and Delete sits beside Archive.

### Bug fixes
- Twenty heads out at once no longer freeze the app: heads pace their flushes by how many are streaming, at most eight run at a time with the rest queued, and the progress bar, the Hydra button and the delegation card stopped doing work on every frame.
- Streamed text no longer gets stuck fading in when a reply is rewritten shorter, or when a character spans two segments of the veil.
- Dragging a floating panel with several open no longer stutters.
- A scroll requested while the timeline lays out no longer loops until macOS kills the app.
- A terminal that just opened takes the keyboard, so typing goes to the shell rather than the chat box.
- The usage popover no longer ends on a divider when a plan has no resets to bank.
- The heads' report popover, a head's steps popover and the plan popover open as tall as what they hold, up to a cap, instead of collapsing to a few rows with a scrollbar.

### Refinements
- The Sidebar and Heads' panels pickers in Settings show what each choice looks like: a tiny window with its column or floating panel, and one team panel against a panel for every head. The Hydra picker's options are now "One panel" and "A panel each".
- A thread opens on its last three blocks, so switching to a long chat paints at once.
- The chat columns either side of the selected thread stay built, so the arrow keys and the next click open them without a rebuild.
- Landing a head's work skips the build output when it makes its patch, so large teams merge faster.


## [1.5.2] - 2026-09-17

Droppy Code 1.5.2 fixes a crash the moment a lead's heads went out, and makes switching between chats with and without floating panels land in one step instead of gliding and jumping. Apple silicon, macOS 26 or later. Signed and notarized.

### Bug fixes
- The app no longer dies when a reply is rewritten shorter while its newest text is still fading in, which happened the moment a lead's heads went out and the delegation block left its reply.
- Switching to a chat with a different set of floating panels no longer glides the conversation, fades the panels and shifts the chat box all at once: the column snaps to the new chat's layout in one step, and a team panel held over from the previous chat no longer lingers on the new one.


## [1.5.1] - 2026-09-17

Droppy Code 1.5.1 fixes Hydra merges from a shared checkout so each chat merges only what its own team changed and says so when there is nothing left to merge, lets you drag a chosen model all the way to the top of the list, and turns rows of toggles in Settings into picker tiles. Apple silicon, macOS 26 or later. Signed and notarized.

### Bug fixes
- Hydra's automatic merge no longer takes along files another chat's team landed in the same checkout: each chat's merge carries only its own team's work, and the other chat's merge then still has its files to land.
- When a chat's work already sits on main (an earlier merge took it along, or it was committed by hand), Hydra says so in the chat and marks the heads merged, instead of ending without a word.
- When the team's files lie outside the chat's project, Hydra names the project they belong to and asks you to open the chat there, instead of merging nothing silently.
- Reordering your chosen models in Settings: a row no longer loses its drag or changes height mid-reorder, so it can be dragged all the way to the top of the list.

### Refinements
- Rows of related toggles in Settings became picker tiles with a small preview each: workspace, window and sidebar choices in General, the sidebar mode, and the Hydra head rows.
- Every head named anywhere in a reply gets its dragon and colour, not only the one that opens the sentence, links included; the heads' reports popover shows each head on its own card with a green done mark.
- Every badge and card in the conversation uses one pill style, with the same metrics throughout.
- The card that lists what each head is being sent out to do stays on screen a moment once the heads are out, wearing the same wave the heads panel shows for a finished head, and then fades away, instead of vanishing the instant the briefs are written.
- The lead is told that heads and the merge only see the chat's own project, so it says so and asks you to open the chat there rather than working in another repository unmerged.


## [1.5.0] - 2026-09-16

Droppy Code 1.5.0 fades streamed text in as it arrives, keeps a running turn's steps inside its working card, starts a project's new chats on the pair you choose, and finds OpenCode's newest models without a relaunch. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Right-click a project in the sidebar to choose the Hydra pair each of its new chats starts on; "The chat's last pair" removes the rule, and a pair removed from Settings takes its project rules with it. Contributed by nik1tsyganov.

### Bug fixes
- The app no longer dies when a layout pass asks for one redraw too many while macOS works out the window's drag region; the request is taken again a moment later, whichever view made it. 1.4.1 guarded one view, and the crash moved to the scroll view beneath it.
- The Providers page refresh reloads the model lists of OpenCode, Cursor, Grok and Devin too, so a model OpenCode gained after launch, such as Union Alpha, is findable in Settings without relaunching the app.

### Refinements
- Text streaming into a reply fades in where it lands instead of popping in whole, the fade keeping pace with the stream; nothing moves or resizes while you read.
- A running turn keeps every step, and what the agent says between steps, in its working card until the turn ends, so earlier steps no longer sit above the card as a collapsed line and the timeline reads the same while running and once folded.
- File attachments fill their chip with the file's icon, the way photos do, instead of a small icon over a truncated name.


## [1.4.1] - 2026-09-16

Droppy Code 1.4.1 folds every finished turn into its summary, keeps the app up through a layout crash, and makes Hydra heads on Z.ai think at the working effort they were promised. Apple silicon, macOS 26 or later. Signed and notarized.

### Bug fixes
- A turn the app quit under folds into its "Worked for" summary when the chat is reopened, like every other finished turn; it stayed open with every step spilled into the chat.
- The app no longer dies when macOS works out the window's drag region in the middle of a layout pass; the refused redraw is taken again a moment later.
- With "Heads work at a working effort" on, a lead at Max on a model whose scale has no medium (Z.ai's GLM) sends its heads out at the scale's middle rung; they went out at Max.
- Head pills in the chat share one left edge: the narrower pill hung off the widest one's right edge, and each head that finished shifted the others.
- The turn's diff counts only the files the chat itself changed, from the tool edits and the provider's own patch together; a file edited elsewhere in the repository meanwhile no longer lands in the turn's summary.
- A command that wrote files counts as an edit on a head's progress bar, the way its row already counts it.

### Refinements
- The head progress bars cache their staves between frames instead of walking every step of the timeline thirty times a second; three hangs of six seconds each came from that walk.
- A question from the agent, or the chat box growing under the last message, brings the conversation's end back into view; a new row while you are reading further up leaves you there.
- Banked resets sit on one line, "Banked resets · 2 available", with the outcome of a spend on a line below it.
- The diff view keeps its line numbers in fixed columns, so wrapped code stays in its own column instead of running back under the numbers.
- The clear button in the search field keeps its room when the field is empty, so the text no longer shifts when you start typing.
- Text in a reply is selected within a paragraph again; the whole-reply drag mode from 1.4.0 is gone.


## [1.4.0] - 2026-09-16

Droppy Code 1.4.0 brings Z.ai's reset cards into the usage popover and lets a drag select across a whole reply. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Banked resets for Z.ai: the usage popover and Settings, Providers show the reset cards a Coding Plan account holds, for the 5-hour and the weekly limit, each with its expiry; spend one, after a confirm step, and its limit goes back to zero.

### Refinements
- Selecting text in a reply just works: drag anywhere on a finished reply and the selection runs across the whole of it, paragraphs, lists, code and links alike; links still open on a click. The right-click Select text item is gone, since the drag does its job.


## [1.3.1] - 2026-09-16

Droppy Code 1.3.1 puts the head card in the merge popover where it belongs, shows reply quotes on a sent message as the chips they were in the chat box, and gives the Z.ai mark its colour. Apple silicon, macOS 26 or later. Signed and notarized.

### Bug fixes
- Hovering a head in the merge popover opens its card from that head's face: the card hung from the middle of the row, between the faces and the count, whichever head was under the cursor.
- A message sent with reply quotes shows them above the bubble as the chips the chat box showed them in, and the bubble keeps only the typed words; the quotes came through as raw quote lines.
- The Z.ai mark takes the label colour like the other provider marks; it drew black on a dark card.


## [1.3.0] - 2026-09-16

Droppy Code 1.3.0 brings Hydra its cookbook: ready-made lead-and-heads pairs in Settings, an intro the first time Hydra is switched on, and popovers that show each merge and report as it lands, alongside Pi and Z.ai joining the providers, banked resets for Codex, slash commands and reply quotes in the composer, and follow-ups that bundle into one message while a turn runs. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Pi joins the providers, with supervised, auto-accept and full-access approval levels.
- Slash commands in the composer: type / to lead a message with a command.
- Reply quotes: quote part of a reply to answer it in place.
- Hydra pair recipes and the cookbook page in Settings: ready-made lead-and-heads pairs with an effort for each side, and providers fall back to what is signed in.
- A Hydra intro popover the first time Hydra is switched on.
- The Hydra merge and report popovers: merge request notes with their files and status, and report digests with each head's outcome and landed files.
- Follow-ups sent while a turn runs are bundled into one message.
- Finished heads pop into panels on their own.
- The last Hydra pair is remembered and applied to new chats.
- A Discord invite button.
- Z.ai joins the providers, with the GLM Coding Plan, GLM models and plan limits in the usage popover.
- Banked resets for Codex: the usage popover and Settings, Providers show the resets a Codex account has banked; spend one, after a confirm step, to clear its active windows, and the bars spring back down.
- Command-W asks to archive the thread, Command-S settles it.
- Questions with several to answer come one per page, with navigation between them.

### Bug fixes
- A running chat no longer shows nothing until it is reopened: the timeline could take content growing under it for a scroll still coasting and stop following, and a Hydra note landing mid-turn split the turn into two blocks under one name, leaving the running tail undrawn.
- A thread reopened at its top: when its first rows fit the pane, the history landing above left the view on the oldest rows; it is put back on the end.
- A thread stopped mid-turn (settled, archived, its pair switched) closes its turn instead of showing the working line for good; deleting a running head tells its lead; Stop no longer waits on git for its diffs.
- Escape in Settings or a file picker no longer closes a chat popover underneath it.
- Hydra on every provider: heads run with full access in their own copy, so none waits on a permission prompt nobody can answer; Codex heads are recognised however the app-server announces them; a Claude head's stream survives the lead's turn ending; a block anywhere in a reply sends its heads, a block on a stopped turn says so, and a pair whose heads' provider is off says where the heads run instead; an Antigravity head starved of permissions reports a failure rather than a clean finish.
- The effort slider runs from low to high on Grok: its levels arrived from extra high down, and the knob sat at Low for the highest.
- The freeze after typing caused by the key view loop is gone, AppKit owns the loop now.
- The merging row's stage words no longer tear mid-transition.
- The working badge's time no longer jumps out of the badge when the steps open.
- Sidebar hover tracking and file card spacing are fixed.
- Nested links in Hydra report rows no longer steal the button's click.
- A link inside a merge note opens the merge request.
- Selectable text no longer overflows the row below it: it is framed to its measured height.
- Opening a work group, step or tool scrolls it into view, and copying a link confirms with a checkmark.
- Heads announced only through activity notes still join the team, and spawning notes read more clearly without the lead repeating each head's status.
- The merge pill no longer shows a stale elapsed time once the merge has landed.
- A thread keeps its model as the live catalogue changes: the built-in list holds the reference while the live list refines the details.
- An interrupted turn settles instead of hanging, and the Hydra chevron only shows where there is something to open.

### Refinements
- Floating panels dock on both sides of the chat only when both fit beside it; dragging and edge-resizing a panel no longer re-lays out the chat every frame, and sidebar and terminal drags step and settle like a window resize.
- The merge popover shows the heads whose work went into the merge; hovering a head names its task and the files of its that landed.
- Head reports open in a plain popover with a pinned header and a compact body; a head's provider mark always shows in its panel; the team's rows sit on the agent's side of the chat; a head going out is announced with its own face rather than a spinner.
- The welcome tour has eight pages of new captures over the desktop, with the floating thread list and Hydra's cookbook among them.
- Chat zoom lives in Settings with a live preview.
- History loads asynchronously so switching chats is instant.
- The app launches straight into the chat.
- The model chip and thread rows use right-click popovers.
- While a turn runs, the working line is the head panel's progress card: the task breathing, the stave bar filling with the turn's steps, the time in its pill, and the chevron opening the steps; Settings › Conversation › Show activity while working turns it back into the plain line.
- The question popover opens on its badge at one size and stays put while you answer; it is plain and native now.
- The checklist card hugs its steps like the other badges.
- Hydra recipes name current models with flexible effort levels.
- The license is GNU AGPL v3 with attribution.
- Cursor's reasoning levels come through a parameterized model picker.
- A Debug build runs as Droppy Code Dev beside the release app, with its own library and settings.
- Chat switching stays instant on long threads: a turn is finished once, a thread is written once, and snapshots and change lists cost less per turn.
- Commands stop with their turn, provider sessions stop cleanly, and the composer and message editor render more cheaply.
- The changelog page on the site is redesigned, its picture tiles take a top-copy, bottom-picture layout, and the composer tour gains scenes for notifications, commands and quotes.


## [1.2.0] - 2026-09-15

Droppy Code 1.2.0 turns one chat into a team: switch Hydra on and the agent leads helper heads on big jobs, each in a copy of your project, their work landing back in your checkout as one merge. Command Code joins the providers, threads settle instead of archiving, a welcome tour opens on first launch, and the usage popover shows every limit you are paying for. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Hydra: one chat, many heads. The lead writes the briefs, sends heads out in parallel, hears each report back in the chat, and lands the team's work in your checkout as one merge; a switch in the model chip's right-click popover and a Hydra page in Settings.
- Pairs in the model picker: a pair sets the lead's model and the heads' model, and can cross providers, a Claude lead over Gemini or OpenCode heads; the effort slider fuses the two colours for a pair.
- The team's panel and any head popped out of it float over the chat, dock in any corner, stack when they share one, and can be dragged to size; a finished head wears its outcome on its glyph, and every head has its own progress bar with its task and time.
- Command Code joins the providers, with approvals, plan limits and remaining credits.
- Settle a thread: it drops to the bottom of the sidebar, small and grey, until you reopen it.
- A welcome tour on first launch, six pages of real captures; Help › Welcome tour and About open it again.
- A floating usage panel beside the chat, switched on in General settings, with the plan's limits and credits for the model in use or a pair's two; the usage popover's expand button opens it any time.
- The usage popover stacks the lead's provider over the heads' when a pair crosses providers.
- A Threads button brings the hidden sidebar's list up in a popover, on hover.
- A zoom slider in the chrome row scales the conversation alone.
- Continue after a usage limit: when the provider's limit is spent, the chat waits for the reset and tells the agent to carry on.
- Deleting a thread asks in a popover on its row.

### Bug fixes
- The chat no longer shows empty space after idling, a quick thread switch or a turn folding; the timeline repairs itself when it finds nothing on screen.
- The window no longer freezes after typing, a loop in the queue tab's chevron.
- The working line moves as one piece, and the traffic lights take their clicks with the sidebar hidden.
- API keys live in the Keychain alone: the copy the defaults held in plain text is gone, and old copies are cleared at launch.
- Attachment files no thread refers to any more are swept from disk a day after they were written.

### Refinements
- Long threads run at 120 fps: rows are laid out as they come into view, blocks are cached, and streamed chunks are coalesced off the main thread.
- The effort slider's knob is a Liquid Glass lens, and popover buttons are the window's native capsules.
- The model picker keeps its glass inside a popover, with one checkmark for the choice.
- Heads have a budget on every provider, a watchdog stops the ones that stall, and finished heads can clear themselves from the panel.
- The sidebar's traffic lights move to it only once it can hold them, and the rail only answers over its ticks.


## [1.1.1] - 2026-09-14

A small release on the heels of 1.1.0: the chat never opens onto empty space, the working line arrives like every other row, and every copy of the app carries its licenses. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Settings › About › Licenses shows the app's license, the third-party notices and the trademark policy, shipped inside the app.

### Bug fixes
- The chat could show nothing at all after a turn finished or a quick thread switch, until the thread was opened again; the timeline now snaps back to the conversation's end whenever it finds itself past it or off its place.
- The working line appeared with a buggy slide; it is a row of the timeline now and arrives like the message you just sent.
- With the sidebar hidden, the window buttons sat too high beside the chat's chrome; they drop to its centre line as they move over.

### Refinements
- About no longer repeats the version above the release cards.


## [1.1.0] - 2026-09-14

Droppy Code 1.1.0 updates itself from here on: Settings › About checks for new versions and installs them with Update & restart. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Droppy Code updates itself: About checks GitLab for new versions, shows what changed, and Update & restart installs it in place.
- GitHub Copilot CLI joins the providers, with its models, efforts and monthly quotas.
- Antigravity joins the providers, with its plan limits.
- DeepSeek and Meta (Muse Spark) are native API providers, keys kept in your Keychain, with DeepSeek's remaining credits in the usage popover.
- 26 tinted-glass themes, from System to Catppuccin, Claude and Codex, and a window transparency setting.
- A follow-up queue above the chat box: steer a running turn, reorder what is queued, or send a queued prompt now.
- The agent's questions take a tab on the chat box, so nothing waits unseen.
- Right-click a merge or pull request link for Merge, which lands it in a helper thread.
- A minimap rail beside long threads, large previews for photos and the files the agent read, recent downloads from the attach button, and a soft chime when a turn finishes.
- Token activity heatmap at the top of General settings, and every signed-in account's usage limits on the Providers page.

### Bug fixes
- The working line appears in place instead of sliding up from under the chat box.
- Native providers' turns no longer stop after twelve tool rounds, and DeepSeek tool-call chains survive trims, compaction and interrupts.
- The changes popover opens on the file a tapped tool row edited, even when the turn's diff does not list it.
- Tool rows no longer read "Edited Edit file".
- Every attachment photo opens its own preview, not only the latest one.
- Link paragraphs no longer come out blank, and sending no longer freezes the window.
- The scroll veil at the top of a pane draws correctly in dark mode.

### Refinements
- Long threads scroll smoothly: rows are built as they come into view, hover rests while you scroll, and expanded rows stay put.
- Finished turns show only their final answer, with the tool run folded behind a chevron.
- Your messages sit in iMessage's bubble.
- Right-clicking a link opens the app's own popover instead of the system's text menu.
- Remaining credits is a settings row, and an empty archive is one symbol in the middle of the pane.
- Spinners and links wear the theme's accent; provider logos share one optical size, with Meta and DeepSeek in their brand colours.
- Popover buttons are the window's capsules, the chat box grows smoothly to five lines, and suggestions anchor to the caret.


## [1.0.0] - 2026-09-13

The coding app by Droppy (https://getdroppy.app): a native Mac app for your coding agents. Apple silicon, macOS 26 or later. Signed and notarized.

### New features
- Codex, Claude, Cursor, OpenCode, Grok, DeepSeek, Meta, Devin and Antigravity, each in its own thread, in one native window.
- The agent's questions and approvals take a tab on the chat box, so nothing waits unseen.
- Follow-ups queue above the chat box while a turn runs and send themselves when it ends.
- A diff for every turn, behind the changes tab, with a review popover.
- The command palette: every thread, project and action one keystroke away.
- The reasoning-effort slider and the model switcher, right in the composer.
- Projects and threads in the sidebar, with an Activity view that keeps the running ones at hand.
- Plans and to-dos as the agent writes them, and a notification when a turn finishes.
- Themes for the whole window, in light and dark: Catppuccin, Dracula, Tokyo Night, Nord, Gruvbox, Solarized, GitHub, Matrix and more.
- A worktree per thread, so parallel agents never touch the same checkout.
- A terminal under every thread.
