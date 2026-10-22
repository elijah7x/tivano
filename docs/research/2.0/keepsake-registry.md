# 信物保存服务：首期设计

> **状态：暂缓（2026-10-20，owner 决定）。** 2.0 不做服务端与邮箱绑定；信物只保存在本机，发放由版本控制：带发放逻辑的版本会发放，之后发布不再含该逻辑的版本即停止发放。本文保留为将来做登录与账号时的设计起点。

日期：2026-10-20。状态：设计提案，未实现、部署或验证。范围：Tivano macOS 的可选邮箱绑定、信物保存和跨设备恢复。

## 1. 结论与边界

建议在 `https://elijah.ac.cn/tivano/registry/v1/` 部署独立的小型 Python 服务，沿用 Polaris 的 nginx → 回环端口 → systemd 专用用户模式；首期用 SQLite WAL，验证码邮件优先采用阿里云邮件推送 DirectMail 的中国内地地域。

设置中的入口叫「信物」。用户可以不绑定、不提供邮箱，正常使用 Tivano；选择绑定时填写邮箱和昵称，验证邮件中的六位一次性验证码。重装或换 Mac 后，以同一邮箱重新验证即可恢复。没有密码、账号登录页或公开个人主页，但服务端仍必须做身份验证和访问控制。「不是登录」指产品流程，不代表可以省略鉴权。

采用 lead 已定的规则：

- 用户内部主键为递增整数 uid，从 `10000001` 开始，不回收、不改变、不向客户端暴露。邮箱、昵称、安装均不充当用户主键。
- 首期绑定后不能自行修改邮箱或昵称；第二期开放修改时仍使用原 uid。用户依法申请更正、撤回或删除的渠道不能因此关闭。
- Early Supporter 按服务端时间发放，先记在安装账本，绑定后归集到用户账本。绑定不必在截止日前完成，只要该安装此前已经获得服务端授予。
- 不持久保存 IP，不收集硬件序列号或聊天内容。邮箱绑定和营销订阅完全分开。

[已批准的设计](../../design/keepsakes/README.md)确定了信物名称、视觉和独立设置页。[早期分析](badges.md)研究的是本地 1.x 资格与未来账号；本方案采用新的「2027 年前开始使用 2.x」规则，不再要求证明运行过 1.x，也不直接把历史本地推定转为可信服务端授予。

**承诺应写成“绑定后可跨设备恢复”，不能承诺无条件永久不丢。** 邮箱失去控制、主动删除、服务终止及灾备缺口都需要明确说明。未绑定且安装凭据全部丢失，服务端无法知道哪条匿名记录属于本人。

## 2. 资格、身份与安全模型

### 2.1 Early Supporter 时间规则

建议截止点采用中国标准时间 `2027-01-01T00:00:00+08:00`，数据库对应 `2026-12-31T16:00:00Z`；时区须 owner 确认。窗口为 `[grant_start_at, grant_end_at)`：起点为正式开放登记的 2.x 上线时刻，终点不包含在内。客户端上报版本必须符合 2.x，但版本声明不是防伪证明；开源客户端可伪造请求，信物只作纪念，不作为付费权益或实名资格。

首次获用户许可后登记安装。服务器在事务内取得统一 `now`，检查窗口与版本，再插入 `install_keepsakes`。只认服务器收到并成功处理请求的时间，不接收客户端 `earned_at`，不依据电脑时钟、邮件发出时间或本地文件日期补发。服务器时钟漂移时暂停授予并报警。

离线首次运行只显示「待联网确认」，不展示成已获正式信物。跨过截止点才联网的用户不会自动获得；这是“服务器认定”与“实际离线使用”的不可消除差异。若 owner 要离线补领，必须另设人工政策与 `manual_adjustment` 来源，不能暗中放宽截止规则。服务故障跨过截止点也按同一公开政策处理。

### 2.2 安装标识不是密码

Mac 生成随机 UUID v4 `install_id`，与独立随机 256-bit `install_secret` 一起写入当前 edition 的 Keychain，再尝试登记。服务器只存 secret 的 SHA-256 摘要；高熵随机 secret 不采用六位码的存储方法。请求用 `X-Install-ID` 与 `Authorization: Bearer <install_secret>`，全程 HTTPS；禁止放在 URL、日志或分析事件中。

增加 secret 是必要的安全字段：UUID 是标识符，不能把“知道安装 ID”等同于“控制该安装”。这是安装凭据，不是额外用户编号；客户端不收到 uid、用户序号、其他安装列表或邮箱历史。业务身份响应只有本人的当前邮箱、昵称；协议另有信物数据、随机 challenge ID、错误码等必要字段。

首次登记提交 secret；同一 ID、同一 secret 可重试。同一 ID、不同 secret 一律拒绝，绝不覆盖已有凭据。已绑定安装只能访问其 uid 的账本，无法通过提交 uid 或邮箱查询别人。新安装须验证邮箱，服务器才能建立关联。已绑定安装不能通过另一邮箱验证码换人，返回冲突；解绑/撤销安装走明确流程。凭据丢失时创建新安装并验证恢复，不能凭 UUID 重发 secret。

首期凭据建议 180 天无使用即过期，过期可重新邮件验证恢复；绝对期限与安全撤销可由服务端控制。邮箱验证可控制当前安装，不证明一个自然人的唯一身份；共享邮箱、邮箱转让和完全复制 Keychain 均属于已知边界。

### 2.3 归集事务

校验 challenge 的邮箱、用途、安装、期限、尝试次数和验证码后，在一个写事务内：消费验证码 → 创建或找到用户 → 建立当前邮箱 → 绑定安装 → 归集信物 → 记录同意与事件 → 保存幂等结果。任何一步失败全部回滚。

同一信物在用户侧唯一，多个安装归集时保留最早的服务端 `granted_at` 及对应来源。安装授予记录不直接删除，而标记已归集及归属 uid，保留出处；“移到用户”指权威归属转移，并非抹掉审计证据。已经归集给 A 的安装信物永远不能转给 B。恢复到已有用户时也归集当前安装未归集的合法信物。

## 3. 数据库结构

下列为可直接转为迁移脚本的逻辑结构。SQLite 使用严格类型约束；`TEXT` 存 UTF-8，`INTEGER` 为有符号 64-bit，`BLOB` 存摘要。时间统一为 UTC Unix 毫秒 `INTEGER`，API 转 RFC 3339；布尔为 `INTEGER CHECK IN (0,1)`。表中除 `?` 标记外均为 `NOT NULL`，所有 PK 明确非空，所有 FK 开启 `foreign_keys=ON`。字符串设长度和允许值校验，不让 SQLite 类型亲和性替代校验。

Release 与 Dev 使用不同进程、数据库、凭据、发信额度和目录；每个库具有同一结构，表内 edition 再作防误用检查。以下唯一约束均在单一环境内成立。

| 表 | 列（类型；`?` 可空） | 键、索引与约束 |
| --- | --- | --- |
| `users` | `uid INTEGER`；`nickname TEXT?`；`created_at INTEGER`；`updated_at INTEGER`；`status TEXT` | PK uid；`uid >= 10000001`；status 为 active/suspended/deleted；active 时昵称必填，删除墓碑可为空。昵称不唯一，1–40 个 Unicode 字符，去首尾空白、禁止控制符。索引 `(status, updated_at)`。 |
| `user_emails` | `id INTEGER`；`email TEXT`；`uid INTEGER`；`verified_at INTEGER`；`valid_from INTEGER`；`valid_to INTEGER?` | PK id；FK uid→users；当前行 `valid_to IS NULL`；部分 UNIQUE(email) WHERE valid_to IS NULL；部分 UNIQUE(uid) WHERE valid_to IS NULL；索引 `(uid, valid_from)`；结束时间不得早于开始。历史邮箱也按最短必要期限清理。 |
| `installs` | `install_id TEXT`；`uid INTEGER?`；`secret_hash BLOB`；`credential_expires_at INTEGER`；`revoked_at INTEGER?`；`edition TEXT`；`app_version TEXT`；`os_version TEXT?`；`locale TEXT?`；`first_seen_at INTEGER`；`last_seen_at INTEGER`；`notice_version TEXT`；`consented_at INTEGER` | PK install_id，合法 UUID v4；FK uid→users；secret_hash 长 32；edition 为 release/dev 且必须匹配该库配置；索引 `(uid, last_seen_at)`、`last_seen_at`。仅明确请求时更新 last_seen，不做心跳。 |
| `keepsakes` | `code TEXT`；`name TEXT`；`grant_start_at INTEGER`；`grant_end_at INTEGER?`；`rule_version INTEGER`；`enabled INTEGER`；`created_at INTEGER`；`updated_at INTEGER` | PK code，如 early_supporter；end 可空表示长期活动，否则 end>start。name 为内部标准名称，客户端按 code 本地化；无按名称授权。规则变更写事件，不回写历史授予。 |
| `install_keepsakes` | `install_id TEXT`；`keepsake_code TEXT`；`granted_at INTEGER`；`source TEXT`；`rule_version INTEGER`；`transferred_uid INTEGER?`；`transferred_at INTEGER?` | 复合 PK(install_id, keepsake_code)；FK 到 installs、keepsakes、users；两个 transferred 字段同时为空或同时非空。索引 transferred_uid；source 为 server_window/manual_adjustment。 |
| `user_keepsakes` | `uid INTEGER`；`keepsake_code TEXT`；`granted_at INTEGER`；`source TEXT`；`rule_version INTEGER`；`origin_install_id TEXT?`；`created_at INTEGER` | 复合 PK(uid, keepsake_code)；FK uid、code；origin_install_id FK→installs，安装按保留政策删除时 SET NULL；索引 keepsake_code。source 保留原授予原因，绑定行为另记事件。 |
| `consents` | `id INTEGER`；`uid INTEGER`；`privacy_policy_version TEXT`；`purpose TEXT`；`accepted INTEGER`；`marketing_opt_in INTEGER`；`recorded_at INTEGER`；`effective_at INTEGER` | PK id；FK uid；追加式记录；purpose 为 binding/privacy_update/marketing_change/withdrawal；索引 `(uid, purpose, effective_at, id)`。营销状态读最新有效记录，默认 false；拒绝营销不阻止绑定。 |
| `verification_codes` | `challenge_id TEXT`；`email TEXT`；`install_id TEXT`；`purpose TEXT`；`code_hash BLOB`；`key_version INTEGER`；`created_at INTEGER`；`expires_at INTEGER`；`attempts INTEGER`；`consumed_at INTEGER?`；`invalidated_at INTEGER?`；`delivery_status TEXT`；`provider_message_id TEXT?` | PK 随机 challenge_id；FK install；purpose 为 bind/restore/delete，第二期可增 login/change_email；attempts 0–5；delivery_status 为 pending/sent/failed。索引 `(email,purpose,created_at)`、`(install_id,created_at)`、expires_at；同 email+purpose+install 最多一个未失效 challenge，由事务强制。 |
| `events` | `id INTEGER`；`occurred_at INTEGER`；`event_type TEXT`；`uid INTEGER?`；`install_id TEXT?`；`keepsake_code TEXT?`；`request_id TEXT`；`result_code TEXT`；`metadata_json TEXT` | PK id；uid/install/code 为可清除的引用，不阻止依法删除；索引 `(uid,occurred_at)`、`(install_id,occurred_at)`、occurred_at。metadata 只允许规则版本、政策版本、操作类别等白名单，禁止邮箱、昵称、验证码、IP、secret 或完整请求。 |
| `idempotency_keys` | `install_id TEXT`；`operation TEXT`；`key TEXT`；`request_hash BLOB`；`response_json TEXT`；`created_at INTEGER`；`expires_at INTEGER` | 复合 PK(install_id,operation,key)；FK install；request_hash 使用服务端 HMAC，避免验证码等低熵请求摘要可离线猜测；索引 expires_at。响应只含该安装可见数据，24h 后删除。 |
| `schema_migrations` | `version INTEGER`；`applied_at INTEGER` | PK version；版本化、显式迁移，不在请求内临时建表。 |

邮箱规范化：去首尾空白，域名转 IDNA 并小写，保留 local-part 大小写；首期支持 ASCII local-part，不支持 SMTPUTF8 时明确提示。禁止去掉 `+tag` 或 Gmail 点号，也不擅自把所有 local-part 小写合并：可能把不同邮箱合成一个人。显示已验证的规范化地址，并提示恢复时使用同一拼写。是否采用大小写不敏感的产品政策必须另行决定并设计冲突处理。

uid 使用 `INTEGER PRIMARY KEY AUTOINCREMENT`，初始化序列到 10000000，第一次实际用户分配为 10000001。允许断号，不代表注册人数，不按 email 哈希生成。SQLite 的 AUTOINCREMENT 防止已提交行号重用，但**旧备份恢复会倒退序列**，所以不能仅靠它声称永不重用。[SQLite 官方说明](https://www.sqlite.org/autoinc.html)

建议在独立、异地耐久对象中先记录预留 uid 段的上界（例如每段 10,000 个），成功后才使用本段；库内逐个递增分配。灾备恢复必须读取最新上界，跳过整个已预留段，再预留新段；独立记录不可用时暂停创建用户。该对象只存环境和数值，不含身份；已有用户 uid 不变。运维不得手工压低 sequence。真正上千万用户时需要扩容，但 64-bit 主键无需改型。

## 4. JSON HTTP API

生产基址：`/tivano/registry/v1`；Dev：`/tivano/registry-dev/v1`。只接受 HTTPS、`application/json`，请求最多 8 KiB；拒绝重复键、未知字段、错类型和超长值。无 Cookie、无浏览器 CORS 授权；原生 app 不要求 Origin，Origin 也不能作认证。

登记以外的接口均带安装鉴权。所有修改接口带 UUID `Idempotency-Key`，作用域为环境+安装+操作；同 key 同请求返回原结果，不重复发信/授予，同 key 不同内容返回 409。先完成鉴权，再查询幂等结果；凭据撤销、用户删除后不得重放旧响应。失效、错误验证码的重试也须幂等，不能让网络重发重复扣次数。

| 接口 | JSON 请求示例 | 成功响应与行为 |
| --- | --- | --- |
| `POST /installs` | `{"install_id":"<uuid>","install_secret":"<base64url 32 bytes>","edition":"release","app_version":"2.0.0","os_version":"15.7","locale":"zh-Hans","notice_version":"2026-10-20","consent":true}` | 新建 201，重复 200；`{"registered":true,"server_time":"…Z","profile":null,"keepsakes":[…]}`。创建时按窗口授予；已有安装保留 first_seen 和已获信物，更新版本、可选环境字段及 last_seen。 |
| `POST /verification-codes` | `{"email":"person@example.com","purpose":"bind","privacy_policy_version":"2026-10-20","consent":true}` | 202：`{"challenge_id":"<random>","expires_in":600,"resend_after":60}`；恢复使用 purpose=restore。无论邮箱是否已有用户都用同样响应形状和时序策略；只有邮箱控制者能得知后续结果。 |
| `POST /bindings` | `{"challenge_id":"…","code":"012345","nickname":"Elijah","privacy_policy_version":"2026-10-20","consent":true,"marketing_opt_in":false}` | 200：`{"profile":{"email":"person@example.com","nickname":"Elijah"},"keepsakes":[…],"server_time":"…Z"}`。新邮箱创建用户；若邮箱已有用户，验证后返回 409 `EMAIL_ALREADY_BOUND`，提示改走恢复；不覆盖其昵称。 |
| `POST /restorations` | `{"challenge_id":"…","code":"012345","privacy_policy_version":"2026-10-20","consent":true}` | 200，响应同绑定；邮箱必须已有 active 用户，安装为空关联或同一 uid。不同 uid 冲突。恢复不覆盖昵称、不重置营销选择。若验证成功但查无用户，返回 404 `NO_SAVED_KEEPSAKES`，提示改走绑定并取得 bind 用途的新码。 |
| `GET /me/keepsakes` | 无 body，不传 uid/email | 200：`{"profile":null或{"email":"…","nickname":"…"},"keepsakes":[{"code":"early_supporter","granted_at":"2026-10-20T12:00:00Z","source":"server_window"}],"server_time":"…Z"}`。匿名安装只读自己的安装账本，绑定后读自己的用户账本；不返回内部来源安装 ID。 |

验证成功但业务冲突的验证码也消费并记录幂等结果，不能重复尝试不同昵称或不同目标。对可重试的数据库故障则回滚且不消费。restore 和 bind 的 challenge 不可互换，必须同时匹配鉴权安装；不存在“先验证得到可跨任意安装使用的通用凭证”。验证码始终是六字符字符串，以保留前导零。

通用错误：`{"error":{"code":"CODE_INVALID","message":"验证码无效或已过期","retry_after":60},"request_id":"<random>"}`，其中 retry_after 可省略。客户端按 code 本地化，不直接展示服务器任意文本。状态包括 400 输入错误、401 安装凭据无效、403 用户停用/用途不匹配、404 未找到、409 绑定或幂等冲突、410 凭据或 challenge 失效、413 过大、415 类型错误、429 限流（含 Retry-After）、503 临时不可用。对错误码和过期码可统一用户提示，避免泄露更多状态。所有响应 `Cache-Control: no-store`；nginx 自身 429/502/503 可能非 JSON，客户端必须容错。

发信不放在数据库写锁期间。先落 pending challenge，再调用邮件提供商；只有 accepted/sent 可验证。HTTP 202 表示请求受理，不保证进入收件箱。发送超时不能立即重发同一请求：可能已经投递；保留 challenge，可提示等待或 60 秒后主动重发，新码使旧码失效。进程崩溃后 pending 记录标为失败并要求重发，不为了后台重发而持久保存明文验证码。

必要配套端点（同一版本，首期也要做）：`POST /marketing-preferences` 更新独立营销选择；`POST /install-revocations` 撤销当前安装并清本地凭据；`POST /deletions` 消费 purpose=delete 的新验证码，删除整个邮箱下的保存资料。删除请求与恢复一样防重放；不能仅持有旧安装 secret 就销毁全账号。无法操作 app 时提供隐私联系邮箱人工渠道，验证相同邮箱控制权；不要求身份证或聊天记录。导出请求也提供人工验证渠道，首期不必公开批量导出 API。

## 5. 客户端流程与本地保存

### 首次正常启动 2.x

不阻塞主界面，不扫描聊天与其他 edition。生成安装凭据前检查 Keychain：locked/denied 不等于不存在，不能因读取失败覆盖原凭据。在信物入口或一次性轻提示中解释「联网登记资格」和数据范围；用户明确同意后才登记匿名安装，不把可选功能变为默认追踪。用户可以仅登记资格、以后再绑定邮箱，也可完全跳过。

匿名登记提示建议：

> 可联网记录信物领取资格。我们会保存随机安装标识、应用版本和登记时间；系统版本和语言可不提供。不提供邮箱也能使用 Tivano。未绑定邮箱时，清除安装凭据后无法恢复信物。

服务器响应落盘后才显示正式 earned date。重试使用同一 ID、secret 和幂等 key；遵守 Retry-After，指数退避带抖动，离线不循环弹窗。没有 consent 时不自动发送网络请求。

### 绑定 sheet

邮箱、昵称 → 隐私说明及必要同意 → 发送验证码 → 输入六位码 → 提交绑定 → 显示「已保存到邮箱」。昵称不暗示公开展示或唯一用户名。提交前明确提示「当前版本绑定后不能自行修改邮箱和昵称，请核对」，不能只在失败后告知。

必要同意文案草案：

> 我已阅读《信物隐私说明》，同意为保存和恢复信物处理我的邮箱、昵称、安装标识及信物记录。绑定可选，不影响 Tivano 的其他功能。

独立、默认不选的营销项：

> 我愿意接收 Tivano 产品消息，可随时取消。

发送验证码即开始处理邮箱，因此隐私说明和同意须在发送前，不能等最终绑定才出现。服务通知与验证码不夹带促销。用户未选营销也能完成绑定，恢复也不替用户重新订阅。

### 重装与新 Mac

Keychain 仍在：读取原安装凭据，服务端确认后恢复缓存。Keychain 不在或凭据已过期：生成新安装 → 用户选择「从邮箱恢复」→ 新验证码 → 取得当前昵称及账本。截止日之后恢复已获信物不重新判断授予窗口；新安装自身不能借恢复冒领额外资格。

| 位置 | 内容 | 边界 |
| --- | --- | --- |
| Keychain，service 按 Release/Dev 隔离 | install_id、install_secret、环境、credential schema | 不启用 iCloud 同步作为默认恢复方案；不得读取或复用 provider/GitHub 凭据。卸载 app 不等于保证保留 Keychain。 |
| 当前 edition 的 Application Support，独立 `keepsakes.json` | 服务端信物快照、当前邮箱和昵称、最后同步时间、同意版本、待重试操作 key | 原子写入、权限收紧；邮箱属于个人信息。不给 library.json 混入身份；不是服务器授予凭证。 |
| 内存 | 验证码、输入中邮箱/昵称、challenge 状态 | 结束或过期即清，不记录日志，不保存明文验证码。 |

离线可以展示已确认的缓存并标「上次同步…」；不能离线绑定、恢复、改营销状态或宣称删除成功。服务故障不清空已有信物。删除成功后清当前本地资料；其他离线 Mac 可能仍留缓存，联网时收到撤销并清除。无法远程保证清除离线备份，要在删除说明中讲清。

Release 和 Dev 使用独立根路径、进程及数据库；客户端 edition 只作一致性校验，不能靠请求中的 flag 在同一数据库切换权限。Dev 使用明显的测试邮件主题、测试目录与不同发信额度，不归集到正式用户；Dev 的网络访问及凭据也不能污染 Release。

## 6. 滥用控制与发信

初始阈值是可调整的配置，不是容量结论：

| 层次 | 初始限制 |
| --- | --- |
| nginx 普通请求 | 独立 zone，每 IP 5r/s，burst=10，超限 429；只在短期共享内存使用 IP，不向应用转发地址。 |
| nginx 发码端点 | 独立严格 zone，每 IP 6r/m，burst=2；与普通 zone 同时生效。共享出口可能被限，UI 给出稍后重试。 |
| 邮箱发码 | 60 秒冷却、每小时 5 次、每日 10 次；绑定/恢复/删除合计，不通过变更 purpose 绕过。 |
| 安装发码 | 每小时 5 次、每日 10 次，与邮箱限额同时执行；不能靠新邮箱刷短信式轰炸。 |
| 验证 | 每 challenge 最多 5 次，安装每小时最多 20 次错误，邮箱每小时最多 20 次错误；事务内先计失败再返回。 |
| 全站邮件 | 首期每日 500 封预算熔断，达到上限暂停发码并提醒运维；Dev 独立低额预算。 |

验证码用 CSPRNG 均匀生成 000000–999999，10 分钟有效，一次使用；重发使该安装同用途旧码失效。`code_hash = HMAC-SHA-256(server_pepper, environment || challenge_id || email || purpose || install_id || code)`，比较用常数时间。不能只用 SHA256(code)：六位码可枚举。pepper 不进数据库，保留 key_version 便于轮换；轮换后过期旧码，最长兼容 10 分钟。

邮箱/安装计数可从短期 challenge 表获得，验证失败汇总用有界内存计数；重启会清除内存计数，所以数据库 challenge 的 attempts 必须保留，全站发送配额依赖持久记录。新 UUID 可以绕过安装限额，故仍需 IP 层、邮箱层与总预算。请求码不透露是否注册；不提供公共“查邮箱”接口。日志不打印请求体或异常中的邮件地址。

### 邮件投递选择

| 方案 | 适合程度与代价 |
| --- | --- |
| 阿里云 DirectMail 国内地域，API 发信 | 首选候选：与现有云运维体系接近，事务邮件用途明确，API 错误和 message ID 易于处理。需要开通资格、发信地址及域名审核、权限和额度确认。 |
| 国内事务邮件供应商的 TLS SMTP | 可替代，便于更换供应商；需核对境内驻留、合同、日志保留、退信接口与投递质量，不能只看 SMTP 连通。 |
| 现有企业邮箱 SMTP | 仅小范围验证候选，通常有反群发和日配额约束；不要把个人邮箱密码放服务器。 |
| 自建 SMTP / 未核实的海外供应商 | 不建议首期：信誉、退信和投递运维较重；境外处理还引入数据出境评估事项。 |

DirectMail 官方文档说明其支持触发邮件、API/SMTP，域名和地址按地域配置；实际中国站账户可用性与费用必须以开通时控制台为准，本文不承诺免费额度或到达率。[产品说明](https://www.alibabacloud.com/help/en/direct-mail/user-guide/overview)

建议发信子域 `mail.elijah.ac.cn`，地址如 `keepsakes@mail.elijah.ac.cn`，隔离主域发送信誉。按所选地域控制台设置域名验证、SPF、DKIM，逐步启用 DMARC；SPF 只能有一条有效策略，合并既有发送方，不能覆盖主域记录。DKIM 获取方式、selector 以当前账户文档为准；不要复制其他地域值。只有业务确需收信时才调整 MX，隐私联系人应是能收到回复的地址。阿里云官方提供 SPF/DKIM/DMARC 配置说明：[域名认证 FAQ](https://www.alibabacloud.com/help/en/direct-mail/domain-name-configuration-faqs/)。

投产前由 lead/owner 检查 QQ、163、Outlook、Gmail 实际收件、垃圾箱、延迟、退信及 From 对齐。使用受限 RAM 凭据，仅授予所需发信权限；营销信与验证码分模板、分额度。拒收地址不反复投递，提供商反馈只存必要状态和短期 message ID。

## 7. 隐私、删除与保留

本节是上线设计要求，不是法律合规结论。中国境内服务器并不自动等于符合 PIPL；需要确认实际处理者、邮件受托方、备份所在地与隐私文本。PIPL 要求明确告知处理者、用途、种类、期限和权利渠道，采取最小必要原则，提供撤回及删除机制；不能因拒绝非必要处理而拒绝其他服务。[《个人信息保护法》官方全文](https://www.cac.gov.cn/2021-08/20/c_1631050028355286.htm)

首期只增加必要的安全字段（安装凭据摘要、码状态、政策版本、撤销时间）和操作时间，不增加人口画像。`os_version` 和 `locale` 可空：分别用于协议兼容排查、邮件语言选择；只存主/次版本和语言标记，不存 build、时区、设备型号。app_version 用于 2.x 授予判断；last_seen 是服务请求时间，不是日活追踪。若没有明确支持用途，系统版本可不发送。

明确不收集：硬件序列号、机器名、MAC 地址、广告 ID、定位、完整 UA、Referer、项目名/路径、聊天、附件、模型用量、API keys、GitHub 信息、通讯录、下载来源。IP 只存在 nginx 限流和网络通信的短期内存中，数据库、访问日志、错误日志及 APM 均不落 IP。云平台或邮件提供商自身日志须另核验，不能由应用的“不存”推断整个处理链“不存”。

| 数据 | 建议保留与清理 |
| --- | --- |
| 用户、当前邮箱、用户信物 | 用户选择保存期间保留，直至主动删除或服务终止；说明长期恢复目的，定期评估必要性，不承诺不可撤销的“永久”。 |
| 未绑定安装及其信物 | 最后访问后 24 个月清理，入口说明并建议绑定；不以发提醒为由要求匿名用户提供邮箱。 |
| 已绑定安装凭据与环境字段 | 180 天不活跃即过期；过期 30 天后删除安装行和已归集安装记录，用户信物仍在，origin_install_id 置空。 |
| 验证码记录及发送状态 | 10 分钟失效；最多 24 小时后物理清理，足够支持每日限流；明文码从不持久化。 |
| 幂等缓存 | 24 小时；含邮箱的响应随用户删除立即清除。 |
| 操作事件 | 普通安全/变更事件 90 天；同意证据服务期间保留，删除后的必要留存由法律审核确定，不能默认永久保存。 |
| 历史邮箱（第二期） | 建议更换后 30 天清理，特殊争议另有依据才延长；关联 uid 不因清理历史而改变。 |
| 备份 | 加密滚动 30 天；删除资料最迟随该周期淘汰。恢复备份前重放独立删除清单。 |

用户在「信物 → 删除云端保存资料」重新验证邮箱并确认后，立即撤销全部安装凭据，移除邮箱、昵称、信物、consents、验证码和幂等缓存中的个人数据；安装记录删除。users 只保留不含个人字段的 uid 墓碑（status=deleted）及必要时间，永不分配给其他人；无法再用该墓碑恢复信物。原邮箱重新绑定属于新用户，不能承诺删除后恢复原 uid。仍可关联个人的审计引用必须清除或删除，不要把墓碑一律宣传为匿名化。

events 的 append-only 是正常业务不能修改历史，不是对抗删除权；专用、受审计的清理任务可按保留策略删除个人事件。删除请求当天落独立加密删除清单，用于灾备后再次删除，最长保留至所有相关备份过期；不含邮箱、昵称，仅内部 uid/安装引用。备份不可直接向业务开放，恢复后先应用删除清单，再启服务。人工渠道建议 15 个工作日内处理并反馈，这是服务目标，非本文断言的法定期限。

隐私说明须列出处理者真实姓名/主体和有效联系方式、各类信息与用途、匿名登记及邮箱绑定的可选性、保留周期、受托发信/备份服务、境内外位置、查阅复制更正删除及撤回方法、服务终止安排。营销同意应独立可撤回，不能仅靠删除整个账户退订。首期不要面向不满十四周岁用户提供此云保存功能，未成年人处理策略须在上线前经审核决定。使用境外邮件/备份、增加公开资料或处理敏感信息时重新评估告知、单独同意及影响评估义务，不能沿用首期同意笼统覆盖。

## 8. 存储与部署

### 8.1 SQLite 起步，按负载升级

推荐 SQLite WAL + `synchronous=FULL`，短写事务、有限 busy timeout，写锁超时返回 503；邮件网络调用不占写事务。WAL 允许读写并行，但仍只有一个写者，不能据此声称一台轻量服务器可支持千万活跃用户。库放本地磁盘，不置于共享网络文件系统。[WAL 官方说明](https://www.sqlite.org/wal.html)

部署前核对实际 SQLite 版本并采用官方当前支持、修复已知 WAL 问题的版本；现有点击服务记录的 SQLite 3.42.0 只是 2026-10-15 环境证据，不能直接认定适合新服务。

| 方案 | 首期取舍 |
| --- | --- |
| SQLite WAL | 单机低频登记、绑定、查询适合；运维和备份轻，事务足以保证唯一绑定。容量仍需实际测量。 |
| PostgreSQL | 多实例、多写入、高可用更合适；首期增加独立数据库、权限、升级和监控负担。若预计首发就有大规模突发，应直接选托管 PostgreSQL。 |

观察实际请求延迟、写锁等待、503、磁盘和备份耗时；持续写入拥塞、需要多实例或恢复目标单机无法满足时迁移。保留相同表关系和 64-bit uid，PostgreSQL 使用 BIGINT sequence，导入原 uid 后按独立高水位设置下一值；时间转 timestamptz，部分唯一索引照保留。低流量窗口暂停写入 → 一致性导出 → 导入并核对数量/约束/授予时间 → 切连接 → 保留只读旧库。迁移后已有写入则不能简单切回旧库，应停写同步差额或前向修复。数据库引擎迁移是运维工作，不改变客户端身份或 API。

### 8.2 与现有 tivano-clicks 对齐

本次只读的部署依据为 Polaris `deploy/README.md`、`deploy/nginx/elijah.ac.cn.conf`、`deploy/nginx/tivano-click-limits.conf` 及 `deploy/tivano-clicks/` 全部四个文件。现有服务为 Python + SQLite，127.0.0.1:8767，专用 systemd 用户，严格 systemd 沙箱和独立 nginx zone；2026-10-15 部署记录记载已上线。新服务不复用点击库、进程、账号或端口，不执行历史部署脚本。

建议路径及参数（端口部署前检查占用）：

| 项目 | Release 建议值 |
| --- | --- |
| 代码/依赖 | `/usr/local/libexec/tivano-registry/`，root 拥有，只读部署；独立锁定依赖的 Python 环境 |
| 数据 | `/var/lib/tivano-registry/registry.sqlite3`，目录 0700、文件 0600，不在 webroot |
| 服务 | `tivano-registry.service`，User/Group=tivano-registry，无登录 shell |
| 监听 | `127.0.0.1:8768`；Dev 建议 8769、独立 tivano-registry-dev 用户与状态目录 |
| 配置/秘密 | `/etc/tivano-registry/`，root 0600，systemd LoadCredential 或受控 EnvironmentFile；邮件凭据、OTP pepper、幂等 HMAC key、备份加密 key 不进 Git |
| 健康状态 | 回环 `/healthz`，检查进程、数据库可读和时钟状态；不公开用户数、配置或版本细节 |

unit 沿用 `Type=simple`、`Restart=on-failure`、`RestartSec=2s`、启动速率限制、`UMask=0077`、`StateDirectory`、`NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`PrivateDevices`、空 capabilities 等；初始 MemoryMax=256M、TasksMax=32，具体以实现负载调整。发信需要 DNS/HTTPS 出站，address families 应支持实际网络所需 AF_INET/AF_INET6/AF_UNIX，不能照抄只听 IPv4 的限制导致发信失效。

沿用的是部署模式，不直接扩展点击收集器的单工作线程 `http.server` 处理器；身份服务选择受维护的 Python HTTP 框架和进程服务器，实现前查其官方部署契约。此文不锁定未经工程验证的框架版本。

nginx 添加独立 `location ^~ /tivano/registry/` 与 `/tivano/registry-dev/`，它们比现有镜像 `^~ /tivano/` 更长，保留原 URI 转发；发码完整路径可用精确 `location = .../verification-codes` 应用更严限额，并包含共同代理配置。新增 `00-tivano-registry-limits.conf` 在 http 层先加载，zone 不复用点击或镜像的名称。

白名单转发 Content-Type、Content-Length、Authorization、X-Install-ID、Idempotency-Key；不转发 Cookie、X-Forwarded-For、真实 IP 或完整 UA。限制 body、缓冲和超时（连接 2s、普通读写 10s、发码至多 15s），服务端发信超时更短；access_log off，端点 error_log 不记录原始请求上下文。安全 header 在 location 内显式保持一致，避免 nginx add_header 继承陷阱；不加 Cookie 或 CORS。路径不匹配返回 404，不能落回站点 SPA 或镜像文件响应。[nginx location](https://nginx.org/en/docs/http/ngx_http_core_module.html#location)、[限流](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html)

### 8.3 备份、监控和上线责任

每晚用 SQLite Online Backup API 生成一致性快照，再加密上传境内异地存储；WAL 模式不能仅复制 `.sqlite3` 主文件。保留 30 天，密钥与备份分离，控制访问，记录备份时间和成功状态。[SQLite Backup API](https://www.sqlite.org/backup.html)

每日备份的最坏数据损失接近 24 小时，不满足“每次成功保存都绝不丢”的承诺。建议同时每小时快照，初始目标 RPO≤1h、RTO≤4h；若 owner 要接近零丢失，应增加可靠持续复制或采用托管 PostgreSQL。uid 高水位与删除清单独立耐久保存，不能只随同夜间库备份。每月由运维在隔离环境演练恢复、外键、序列和删除清单；演练不发真实邮件。

只监控运行状态、聚合 5xx/429、响应时间、发信接受/失败计数、数据库锁等待、磁盘、备份年龄、时钟同步和邮件额度，不采集行为漏斗或按用户活动画像。journal 输出结构化错误类别与随机 request_id，不输出 SQL 参数、邮箱或 secret；保留 7 天即可作为初始运维配置。故障时先停发码/授予，保留查询缓存，不静默伪造成功。

正式实施时在 Polaris 保存新服务部署件；先备份现网配置，仅增加对应 location，不整份覆盖 vhost、不修改镜像 snippet。先启动后端，再由 lead 检查 unit/nginx/隔离请求与真实投递后开放客户端；回滚撤去新路由和停止新服务，保留库与迁移记录。本文没有授权部署、发信或更改 DNS。

## 9. 第二期为什么不需要重构身份表

- 邮箱验证码登录：复用 verification_codes 的用途约束，新增独立 sessions 表处理会话、刷新和撤销，不把 install_id 变成账号。新增表是能力扩展，已有 users、信物和 uid 不迁移重建。
- 改邮箱：验证当前控制权与新邮箱，一次事务结束旧 user_emails 行、插入新当前行，唯一索引处理竞争；信物继续指向原 uid。换邮箱不创建新 users，不把旧邮箱对应的第三人合并进来。失去旧邮箱后的恢复需单独制定政策。
- 改昵称：更新 users.nickname/updated_at 并写变更事件；昵称不是唯一登录名，所以无需改外键。
- 多个信物：只增加 catalog 记录与各自授予规则，两个账本的复合主键已经支持；活动窗口变更不重写历史。将来若需撤销信物，增加显式撤销状态/事件，不能把删除行当作无痕纠错。
- 多安装：installs.uid 的多对一关系已覆盖。第二期可新增设备管理，但不得顺便暴露内部 uid 或硬件指纹。

“无需重构”是无需更换用户身份、拆分邮箱主键或搬迁授予归属，不意味着后续永远不允许增加列、索引或表。API 维持版本和兼容迁移，首期客户端没有修改邮箱/昵称端点。

## 10. 工作量与待 owner 决定事项

估算前提：一名熟悉 Swift、Python 和当前部署的工程师；无现成邮箱认证后端；包含正常安全错误路径和必要验收，不含复杂账号找回、公开主页、管理后台和法律意见费用。

| 工作 | 估算人日 | 主要不确定性 |
| --- | --- | --- |
| 服务端：schema/API/鉴权/验证码/限流/删除/备份/部署及验收 | 8–12 | 并发事务、邮件故障、灾备序列与删除清单；不能按“一个小 Python 文件”估算 |
| macOS：信物状态、绑定/恢复 sheet、Keychain、缓存、重试、本地化及验收 | 5–8 | Keychain 错误状态、重装和双 edition 隔离、离线与失败界面 |
| 邮件、DNS、权限与真实投递 | 1–2 | 审核和 DNS 生效可能额外等待数天，投递质量尚未知 |
| 隐私文本、处理清单与删除流程 | 1–2 准备人日 | 另需合适人员法律审核，时间和费用未估定 |
| 合计 | 15–24 人日 | 顺序完成约 3–5 周，供应商审批/法务等待另计 |

owner 需要确定：

1. 截止点是否采用中国标准时间；服务上线起点；离线或服务故障错过窗口是否允许人工补领。
2. 匿名登记是否按本文明确选择开启；未绑定 24 个月保留期是否接受。没有网络登记的使用无法凭本机日期补证。
3. 邮箱规范化政策、昵称长度与首期不开放修改的提示；无法访问原邮箱时是否只接受无法恢复，而不引入高风险人工认领。
4. 实际处理者与隐私联系地址、未成年人策略、删除与更正处理人、保留期限及法律审核安排。
5. 发信子域、DirectMail 国内地域及预算、测试收件人范围；营销功能是否首期完全不启用（建议默认关闭，仅保留数据结构）。
6. RPO/RTO 与备份预算，是否接受最长一小时数据损失；若不接受须升级耐久方案，不能仍写“永久保证”。
7. Dev 是否仅允许测试邮箱、测试码目录和测试发信额度；正式目录绝不接收 Dev 信物。
8. 信物是否始终仅作纪念；若以后涉及付费权益，需要重新设计反作弊与运营审核。

lead 后续验证重点：截止时区及边界、邮箱竞争绑定、同码并发消费、幂等重试、已绑定安装换人拒绝、恢复不改昵称/营销状态、归集最早时间、删除后的备份恢复、uid 不重用、Keychain 丢失/锁定、双 edition 隔离、日志不含个人信息、实际邮件投递。本文作者按 Hydra head 约束未执行任何构建、测试、lint 或验收。

证据边界：文件阅读反映本机部署存档，不是现网巡检；官方文档检索用于核对法律、邮件与存储约束，未核验账户开通条件或现网配置。Nowledge 定向搜索未得到本功能的历史决策依据，设计以本任务明确要求为准；远端判断评审由 lead 统筹，本 head 未另行调用。
