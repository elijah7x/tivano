# 2.0 老用户徽章：识别、保存与账号迁移

研究日期：2026-10-20。范围：当前任务副本的源码、本地 v1.x 发布标签和官方平台文档；仅研究，未修改 Swift，未构建、运行或测试应用。文中的新增类型、字段和流程均为提案。

## 结论

可以为保留本机数据的 1.x 用户自动授予徽章，但**当前已发布代码没有可靠的“曾运行 1.x”专用凭据**。无法同时保证“任何 1.x 用户都不漏发”“复制数据者不获赠”“清空所有数据后仍可识别”。必须把产品承诺限定为可恢复的本机资格，之后用账号账本提供跨设备恢复。

建议最后一个 1.x Release 先写专用资格标记；2.x 第一次启动时优先恢复标记，再为直接从较早 1.x 跨版的用户做兼容推定。徽章仅作纪念，不绑定付费权益，接受有边界的本地伪造风险。账号系统不是本地徽章的前置条件。

置信度：现有存储语义与标签覆盖为高；兼容判定能覆盖多少真实用户为中，缺少安装分布；删除应用后的实际恢复效果尚未用签名安装包验证。

## 1. 已发布 1.x 留下了什么

检索了 `Tivano/` 下的 `UserDefaults`、`@AppStorage`、版本与 seen 标记、更新器、迁移器、Store 和 Keychain 调用。历史使用只读 `git log --oneline -S <key> -- Tivano/`，并在本地标签源码中查找；这些是研究证据，不是运行验证。

`git tag -l 'v1*'` 返回 17 个标签：`v1.0.0`、`v1.0.1`、`v1.0.2`、`v1.0.3`、`v1.0.6`、`v1.0.10`、`v1.1.0`、`v1.1.7`、`v1.1.13`、`v1.2.2`、`v1.2.6`、`v1.2.7`、`v1.3.0`、`v1.3.1`、`v1.3.8`、`v1.3.14`、`v1.4.0`。下表“全部标签”指这些本地标签，不代表已联网核对所有 GitHub 发行资产，也不代表每位用户实际写过这些值。

| 信号与源码 | 已发布历史 | 能证明什么；能否区分全新 2.0 |
| --- | --- | --- |
| `AppInfo.numericVersion` / `version`，`Core/Support/Text.swift:8`，读取 `CFBundleShortVersionString` | 全部标签；字符串最早见 `ba249c87e`（Dev 0.0.2） | 当前正在运行的 bundle 版本。升级后已经是 2.x，不能还原旧版本。`dev-` 是显示前缀，判版本应使用 numericVersion。 |
| `updateChecker_release`，`updateChecker_lastChecked`，`updateChecker_notifiedVersion`，`App/UpdateChecker.swift:94` | 三个键均在全部标签；最早 `ba249c87e` | 缓存的是发现的发行版本、检查时间、通知过的发行版本，**不是已安装版本**。检查失败也可能写检查时间。2.x 自己会继续写；只可作为启动前遗留的辅助信号。缓存里出现 1.x 不等于运行过 1.x。 |
| `appUpdater_pendingRelaunchVersion`，`App/AppUpdater.swift:251,263,465` | 全部标签；最早 `ba249c87e` | 更新交接时写目标版本；下一次启动无论匹配与否都会删除，交接超时也删除。不覆盖 DMG 手动替换，不能用作长期资格；目标 2.0 更不能证明来源是 1.x。 |
| 普通偏好，如 `performanceMode`、`GitHubUser`；`AppSettings.swift`、`GitHubConnection.swift`、多处 `@AppStorage` | 两者均在全部标签；最早见 `b64a00ddc`（合并 Droppy 上游） | 用户偏好或 GitHub 登录缓存，不含 Tivano 安装版本；还可能来源于早期上游迁移。新装也可写入。不能因读到默认值就认定曾安装，需区分持久域与注册默认值。 |
| `hasSeenHydraIntro`，`App/AppSettings.swift:208,713` | 全部标签；最早 `ba249c87e` | 看过 Hydra 引导，不是看过某版更新说明。可缺失、可重置、可复制。 |
| `lastVersion`、`whatsNew`、About/changelog 已读版本 | 当前相关检索未发现专用持久字段；前两个字面键的 `git log -S` 无结果 | `AboutUpdateViews.swift` 的 `seen` 是解析条目去重的临时 Set；About 展示当前版本和更新内容，不能充当历史运行凭据。不能据这两个键名的缺失推导“历史从未存在任何别名”，但已读相关实现没有提供所需能力。 |
| `LegacyMigration.run()`，`App/LegacyMigration.swift:5` | 隔离检查 `linkedUpstream` 在全部标签；最早 `871fad70b`（0.2.5） | 检查共享目录/软链与离线拆分中的状态，再创建当前 edition 的目录；没有保存迁移来源版本、首次安装时间或成功版本。**目录存在不能作资格条件**，新装启动就会创建。 |
| `library.json`，`Services/Store/Storage.swift:37,99`；`Core/Models/Library.swift:343` | 全部标签；文件名最早 `ba249c87e` | `Library` 仅有 projects/threads，没有库级 `createdAt`、installID 或 creatorAppVersion。缺文件时 `loadLibrary()` 返回空 `Library()`；有空文件也未必使用过。有效非空历史只能证明使用过兼容的数据格式。 |
| `ChatThread.createdAt`，`Core/Models/Library.swift:146,277,299`；文件/目录创建时间 | `createdAt` 在全部标签，最早 `ba249c87e`；Store 未发现安装日期记录 | 会话时间不是安装日期；缺失字段解码可默认 `.now`。迁移、备份、复制、系统时钟和手动编辑均会影响日期；文件时间也不是版本证据。不要用“早于 2.0 发布日”单独发放。 |
| `APIKeychain`，`Services/Providers/APIKeychain.swift`；`MCPKeychain`；`GitHubCredentials` 位于 `Services/Git/GitHubAPI.swift:116` | `DeepSeek API Key` 与 MCP 逻辑在 v1.0.0/v1.4.0 源码中存在；相应字符串全部标签存在，最早 `ba249c87e`。`GitHub Token` 在全部标签，最早 `b64a00ddc` | service 取 `AppInfo.libraryName`：Release 为 `Tivano`，Dev 为 `Tivano Dev`。存的是 API key/MCP secret/GitHub token，不是应用版本或徽章。CLI 用户可能从未写过；2.x 新用户也会写。不要为了徽章读取密钥内容，更不能上传凭据。 |

这些多数信号在 0.x 就存在，因此即使启动前快照读到它们，也不能严格排除“只用过 0.x、直接升 2.x”的人。Store 的 `TokenLedger.swift` 记录用量与导入指纹，同样不承担安装版本证明。

Release 的数据根为 `~/Library/Application Support/Tivano`，状态根为 `~/.tivano`；Dev 分别为 `Tivano Dev`、`~/.tivano-dev`。偏好域随 bundle identity 隔离。不得扫描另一 edition 或 Droppy 目录来补资格，也不得自动复制其 Keychain 内容。

## 2. 推荐判定与启动时序

### 先补一个 1.x 标记

建议在最后一个 1.x Release 的正常启动写入 `legacy-v1-eligibility`：schema、随机 installID、edition、`observedVersion`（实际运行的 1.x 数字版本）、observedAt、来源 `observedRunningV1`。首次写入后保留资格；可另存 lastRunVersion，不能用后者覆盖首次资格。

同时写当前 edition 的 Application Support 文件和专用 Keychain item。不要等用户打开 About、检查更新或创建聊天才写。Capture/测试运行跳过。这能覆盖清空偏好/资料库但保留 Keychain 的用户，但不能覆盖从未运行该补丁或后来清空 Keychain 的用户。

若要求“必须在 2.0 发布前使用过”，本机时钟和补丁 marker 都不够：2.0 发布后下载旧版同样会写 marker。需要发布前服务端登记并签发凭据，或承认本地纪念徽章允许这种领取方式。

### 2.x 第一次正常启动

现有入口：`TivanoApp.init()` 调用 `LibraryAccess.prepare()`；后者拿锁、执行 `LegacyMigration.run()` 并建立 edition lease。`AppDelegate` 会消费更新重启标记，`AppModel` 会加载库并启动服务。

建议在拿到排他权限、确认 edition 路径安全之后，**任何创建目录、写偏好、迁移旧库、消费重启标记和启动更新检查之前**采集有界的只读资格快照。应把路径安全检查与创建目录分开，而不是依靠调用 `prepare()` 后的目录状态。资格 I/O 不应阻塞主线程扫描全部聊天，优先读取小标记与库索引；需要补充历史时后台有界读取。

优先级如下：

1. 已有本地授予记录或专用 Keychain 授予记录：按稳定 badgeID 恢复，不重新发放。
2. 专用 1.x eligibility marker：校验 schema、edition、版本主号确为 1，授予 `legacy_v1`，记录 `observedRunningV1`。
3. 没有 marker 的直接跨版：建议“有效非空旧库 + 同一 edition 持久偏好中的旧使用痕迹（例如 Hydra 已读或更新检查记录）”才自动推定发放，来源记 `legacyDataInferred`，sourceVersion 留空。只看目录、空库、Keychain 凭据或一个时间戳均不授予。这是覆盖策略，**不是严格版本证明**。
4. 无证据：不授予，记录此次评估完成；读取错误/Keychain 暂不可用记 pending 并重试，不能当作“从未使用”。本次证据快照和判定版本要原子保存，避免第二次启动把 2.x 自建的数据认成遗留数据。

推定方案需要 owner 明确接受：只用过 0.x、完整复制旧数据者仍可能获赠；只保留库却清空偏好、只开过应用没建会话的人可能漏发。若复制误发不可接受，应关闭第 3 条自动发放，改为用户主动恢复/申领，代价是更高漏发。不能把两种政策包装成同样可靠。

### 恢复与防误判边界

| 情况 | 建议行为 |
| --- | --- |
| 干净安装 2.x，无旧数据/专用 Keychain item | 不发；后续 2.x 自己产生的偏好和库不再触发兼容判定。 |
| 仅删除 `.app`，保留用户数据 | 从已获徽章账本或 Keychain 恢复。 |
| 清空偏好或资料库，但专用 Keychain item 仍在 | 恢复；若用户用的是 marker 之前的旧版，则不能保证。 |
| 清空所有本地数据和 Keychain / 新电脑 | 本地无证据不可推断；账号阶段从服务端恢复。保留自助说明和人工申领入口，不要求上传聊天或 token。 |
| 拷贝 library.json 到新机器 | 单独库文件不发；库加偏好仍可骗过推定规则。新 marker 可用 Keychain 随机密钥认证，与 installID 配对，防止只复制普通文件。 |
| 完整迁移备份 / 本机恶意改写 | 纯本地无法判断是本人迁移还是他人复制。合法迁移不宜因硬件指纹强绑定被误伤；不采集硬件序列号。 |
| 旧数据损坏 / Keychain 锁定或拒绝访问 | 显示可重试的恢复状态，保留原文件，不静默判无资格、不生成替代凭据覆盖。 |

只在成功落盘后标记发放完成；两份存储不能原子提交时采用幂等重试：同一 badgeID/grantID 补齐缺失副本，启动恢复不重复庆祝。迁移规则版本独立于 app 版本，不要每个 2.x 更新重新扫描。

## 3. 本地模型、分层与 Keychain

建议 `Core/Models/Badge.swift` 定义纯值类型 `BadgeID`、`EarnedBadge: Codable, Sendable` 和 `BadgeLedger`。字段至少包含稳定 badgeID、grantID、earnedAt、source（observedRunningV1 / legacyDataInferred / account）、observedVersion 可选、edition、schemaVersion。展示名称、图案与 grantID 分离；英文文案为本地化键并提供 zh-Hans，不把中文显示名当主键。

`Services/Store/BadgeStore.swift` 负责原子 JSON 保存、读取和恢复；`Services` 下单独的 `BadgeKeychain` 封装 SecItem，并保留状态码以区分 notFound、locked、denied、corrupt。现有 `APIKeychain.read()` 把失败折叠成 nil，不适合原样当作资格判断接口。`App` 层 coordinator 决定启动时机、版本政策、observable UI 状态与后续网络迁移；Core 不访问设置、provider registry 或 UI。

建议普通文件放 `StoragePaths.root/badges.json`，不要混进可复制的聊天 `library.json`，不要存在 `.app` 内或仅用 UserDefaults。Keychain 用 generic-password item，service 分别 `Tivano` / `Tivano Dev`，account 为独立版本化名字如 `Badge Ledger v1`；1.x marker 另用 `Legacy V1 Eligibility`。保存短小的授予凭据/恢复信息，不放完整聊天或图片；badge artwork 随 app 资源分发。

### 删除应用后是否还在

**仅将 macOS `.app` 拖入废纸篓，一般不会删除用户 Keychain 中的项目**；这适合作为同一 macOS 用户重装后的恢复副本，而不是永久不丢的保证。官方依据与证据边界如下：

- Apple 的 [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) 说明 macOS Keychain 独立于应用包，文件式 Keychain 的默认目标是用户 login Keychain；SecItem 默认访问文件式实现，除非显式选用 data protection/synchronizable。当前 APIKeychain 没有设置这两个属性，属于前者。
- Apple 的 [卸载应用说明](https://support.apple.com/en-us/102610) 区分拖入废纸篓与专用卸载器清理其他位置的数据；[Keychain 删除说明](https://support.apple.com/en-ie/guide/keychain-access/kyca2423/mac) 则描述独立删除 Keychain。结合存储位置，这是“只删除应用包不连带删除 Keychain”的架构依据。
- **本次没有找到 Apple 对“所有卸载方式都保留、重装永远可读”的明确承诺**，不能把上述文档说成这种保证。用户主动清除、第三方卸载器、Keychain 重置、系统重装与权限变化都可能使恢复失败；iOS 卸载讨论不能代替 macOS 契约。

新增 item 使用 SecItem；若沿用文件式实现，应保留签名身份和访问控制预期。若选择 Apple 推荐的 data protection 实现，要先核对 entitlement/provisioning/access group，不能仅添加一个属性就假定旧凭据可读。新徽章 item 可独立演进，不顺手迁移现有 API keys；默认不启用 iCloud 同步，跨设备交给明确的账号流程。

本地是装饰性资格：schema/枚举/长度验证、原子写入、Keychain 副本足够起步。随机 Keychain 密钥对文件做 MAC 可阻止普通文件编辑或单独拷贝，但不是远程可验证的发行方签名；硬编码共享密钥没有可靠防伪价值。本机可控的开源客户端无法提供强反作弊。不把该徽章直接用于折扣、权限或交易；未来若改变用途，应引入服务端签发与审核，不能追认所有旧本地记录为强凭据。

## 4. 后续邮箱绑定与服务端

邮箱验证只证明控制邮箱，不能证明使用过 1.x。需要一个真正的账号与徽章服务，不能只在本地加 email 字段。

最小组件：账号 UUID 与已验证邮箱；OTP 或 magic-link 邮件及过期/单次消费/限流；会话与撤销；`badge_grants` 账本；领取端点；按账号恢复端点；删除/导出账户；运营补发与撤销记录。账本对 `(accountID, badgeID)` 唯一约束，claimID 幂等。客户端只能读自己的账本，不能自行写入可信 grant；管理密钥不进 macOS 包。

迁移流程：用户主动绑定 → 验证邮箱 → 登录后提交最少本地凭据（badgeID、grantID、来源、edition、可选旧版本）→ 服务端按政策接受为 `legacyLocalClaim` 或验证已签发凭据 → 幂等入账并返回服务端记录 → 本地标记已同步。网络失败保留本地徽章且可重试；以后重装登录直接拉取账本。一个本地 claim 默认只能绑定一个账号，改绑走明确恢复流程；不要按邮箱字符串作永久主键。

本地弱证据同步以后仍是弱来源，服务器不能凭一次上传变成“已验证历史”。可以接受纪念性申领，但需限流、审计和重复领取约束；若要求强证明，要在 1.x 阶段部署签发服务。

| 方案 | 适配与负担 | 官方依据 |
| --- | --- | --- |
| 自有后端 + 数据库 + 邮件服务 | 规则和数据迁移最可控；自行承担认证安全、邮件投递、备份、滥用处理和运维。没有既有后端团队时不建议从零自造认证。 | 这是工程取舍，不假定仓库已拥有相应服务。 |
| Supabase Auth + Postgres + 服务端 claim function | 推荐作为账号阶段的首选候选：邮箱 OTP/magic link 与关系型唯一约束适合徽章账本；RLS 控制读取，grant 只由服务端写。仍需邮件配置与领取业务。 | [Auth](https://supabase.com/docs/guides/auth)、[Email passwordless](https://supabase.com/docs/guides/auth/auth-email-passwordless)、[RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)。 |
| Firebase Auth + Firestore + Functions | 托管认证和数据库路径完整；需配置 Rules 与服务端授予，接受文档式数据模型。原生 macOS 的选定 SDK/邮箱回跳能力需单独验证，不能把 iOS 示例当作已验收。 | [Apple 平台邮箱链接](https://firebase.google.com/docs/auth/ios/email-link-auth)、[Firestore Rules](https://firebase.google.com/docs/firestore/security/rules-conditions)。旧 Dynamic Links 路径已有迁移要求，应使用当前流程。 |
| Cloudflare Workers + D1 + 认证/邮件组件 | 适合已有 Workers 运维能力的团队；D1 是 SQL 数据库，不是开箱即用的消费级账号系统。需额外实现或接入认证、会话与验证邮件。 | [D1](https://developers.cloudflare.com/d1/)、[Email Service](https://developers.cloudflare.com/email-service/get-started/send-emails/)。 |

选型建议置信度中：尚未比较目标地区投递率、现有基础设施、预算和 macOS 集成成本，不承诺某服务免费或固定价格。2.0 本地徽章不必等待这一决策。

隐私：绑定必须可选；明确说明上传邮箱和徽章资格元数据，不上传聊天、项目路径、API keys、GitHub token 或完整偏好。随机 installID 仍可关联用户，需说明用途与保留期限。公开昵称/徽章展示默认关闭，邮箱不公开；不要自动把现有 GitHub 连接视作 Tivano 账号。以后做社交还需独立的公开资料、可见性、屏蔽/举报与内容治理设计，不混入首期。删除账号应说明服务端账本删除和本地副本清除的分别含义，避免注销后自动静默重建。

## 5. UI 入口

当前 `SettingsPage` 没有 Account 页。`GitHubSettingsSection` 是 source-control 连接设置，不是 Tivano 账号。`SidebarView.swift:209` 底部只有语音入口和 Settings 行，没有个人资料组件。

首期推荐 **Settings → About 的 appCard 下方、Credits 上方**：`SettingsView.swift` 的 `AboutSettingsPage`（约 1222 行）新增 `ChromeSection(title: "Badges")`，内用 `ChromeCard` 和 `ChromeRow` 展示已获得徽章、简短说明与恢复状态。复用 `Chrome.sectionSpacing`、既有字体/颜色/分隔线；不要把个人徽章画进 `AboutVersionPill` 或应用图标，避免与版本/更新状态混淆。无徽章时用一句自然的空状态说明；读取中、失败待重试、已恢复状态可辨识；不强迫弹窗庆祝。

邮箱阶段再增加 Account 设置页，使用相同组件显示未绑定、验证中、已绑定、同步失败和退出状态；About 保留通往徽章页的入口。侧栏个人资料为后续独立入口，可放在现有 Settings 附近，复用 SidebarRow/SidebarIconBadge，点击进入 Account；当前没有现成 profile 可以直接挂徽章，首期不必扩展侧栏。

建议候选文案：英文键 `1.x Legacy User`，zh-Hans `1.x 老用户`；说明 `感谢你从 Tivano 1.x 一路相伴。`。名称、英文 supporter 是否暗示捐助都待 owner 决定。图片需有等价文本，无障碍阅读不依赖颜色；新增文案按 `docs/i18n/CONVENTIONS.md` 进入 `Localizable.xcstrings`。本研究不实现界面，因此未做渲染或截图验收。

## 6. Owner 待定与 lead 后续验证

需定的产品政策：

- 图案、正式中英文名称、说明文案；“老用户”与“支持者”是否有不同含义。
- 资格按“曾运行任何 1.x”还是“2.0 发布前已使用”；是否接受 0.x/完整复制资料的推定误发。
- 最后一个 1.x marker 补丁是否发布，留多长升级窗口；不经补丁直接跨版的兼容判定是否启用。
- Dev 是否授予独立测试徽章；建议默认不发正式 Release 徽章，绝不跨 edition 扫描。若未来共用账号，Dev 连接测试后端且不能污染正式账本。
- 清空所有数据的补领方式、改绑规则；徽章是否永远仅作装饰。
- 邮箱服务的地区、数据驻留、预算、删除与公开展示策略；账号阶段另行立项。

lead 后续应验证而本任务未执行：真实已签名 1.x → 2.x（自动更新与 DMG 替换）、跳过补丁、干净安装、空库/坏库、清偏好、Keychain 锁定/拒绝、只删除 app 后重装、文件复制/合法迁移、Release/Dev 隔离、发放中途退出与重复启动。重点证明启动快照早于任何新数据写入，以及写失败不造成误发或永久漏发。账号阶段补充重复 claim、账号切换、邮件回跳与删除账户恢复行为。

研究边界：没有读取用户真实 Keychain 或应用数据；Nowledge 定向检索未提供徽章方案依据；没有执行远端评审（同一任务由 lead 统筹），也没有将本提案写成既定产品决策。
