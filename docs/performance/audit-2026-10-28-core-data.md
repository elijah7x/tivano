# Core 与数据安全复核、修复交接（2026-10-28）

本文保留 Ada 的源码证据、Thor 来源和恢复设计，并已按主线程的集成结果更新。最终结果见[本轮修复报告](audit-2026-10-28.md)。基线为 Dev 2.1.21 / build 181；主线程已完成 App 构建、系统 Git 与另一版本 Git 的隔离回归、生命周期接入及本地化。未执行真实用户库迁移或生产数据清理。

## Thor 报告来源

读取顺序：实际 `AGENTS.md`、本地 `.git` 指向的共享配置、SSH 配置、项目运维与研究文档，再只读取得远端已有报告。连接和仓库位置取自本机共享 Git 配置的 `remote.thor.url` 与 SSH 配置；夜报目录由远端项目目录清单定位，不在公共文档中固化机器路径。没有启动夜审、远端构建、应用或评审。

下表文件名均相对于该报告目录；基线和版本来自报告正文，未用当前远端分支反推历史。10-13～10-20 的遗漏报告本轮已补读。

| 日期 | 文件 | 报告所审基线 | 正文版本证据 |
| --- | --- | --- | --- |
| 10-13 | `2026-10-13.md` | `885dbff` | 1.2.6 |
| 10-14 | `2026-10-14.md` | `8006219` | Dev 1.3.0 |
| 10-15 | `2026-10-15.md` | `b0ec957` | Dev 1.3.6 |
| 10-18 | `2026-10-18.md` | `9c58bd3` | Dev 1.3.14 |
| 10-19 | `2026-10-19.md` | `87725df` | 区间结束 1.4.0 |
| 10-20 | `2026-10-20.md` | `8075ebe1` | Dev 1.4.9 / Release 1.4.0 |
| 10-21 | `2026-10-21-2.0-release-audit.md` | `3d575b7` | Dev 1.4.21 |
| 10-22 | `2026-10-22.md` | `02fb1e3` | Dev 1.4.27 |
| 10-23 | `2026-10-23.md` | `f79c63a` | Dev / Release 2.0.0 |
| 10-24 | `2026-10-24.md` | `e252e30` | Dev 2.0.10 / Release 2.0.6 |
| 10-25 | `2026-10-25.md` | `a3c9ca9` | 未找到明确版本，不推断 |
| 10-27 | `2026-10-27-overtime-hydra2-remotemcp.md` | `10d2fd9` | Dev / Release 2.1.15 |
| 10-28 | `2026-10-28.md` | `1433f28` | 未找到明确版本，不推断 |

10-18 报告明确记载 10-16 无变化跳过、10-17 无运行记录；目录没有取得 10-26 报告。10-21 的普通夜报不是本次读取的加班报告，不能混为一份。远端缺少 `rg`，只读检索改用 `grep`；报告访问本身无阻碍。历史报告声称的编译、性能结果仅为原报告记录，本轮未复跑。

## 本轮实现

### 1. 合并后的同步可能覆盖准备之后的编辑（P1，高）

来源：Thor 10-21 加班报告 P2 表第 4 项（第 46 行），10-22 第 86 行再次确认未修；本地 [10-21 审计](audit-2026-10-21-sidebar-model.md) 第 12 行、[设计提案](../research/hydra-checkout-safety-2026-10-21.md) 的 A1～A4。这里按数据损失影响提高优先级。

成立条件：准备 contested 文件后，push/MR/fetch 等待期间用户继续修改；旧 `syncDefaultBranch` 在等待结束后才读取 `mergedFrom`，把新编辑当作可覆盖基线。旧 HEAD 比较与 `resetSoft` 之间另有提交竞态；`resetIndex` 也可能清掉期间新暂存的修改。

当前实现入口：`Tivano/Services/Git/Git.swift:492` 的 `captureTree(paths:onto:from:)`、`:761` 的 `synchronizeCheckout`；`Tivano/App/AppModel+HydraMerge.swift:1078` 的 `syncDefaultBranch` 及 `mergeHydraProject`。

修复：准备阶段先冻结 `sourceTree`，三方合并从该树读内容，普通路径也携带实际捕获树；同步生成 source→remote 的二进制补丁，通过 `Git.apply` 合并当前文件；需要三方合并时先在临时索引用 --cached 预演，冲突不写工作文件，无冲突后应用解析出的 patch。持有真实 `index.lock`，在临时索引以两树合并保留不相关暂存修改；重叠暂存修改拒绝同步。在真实 index.lock 保护下复核 HEAD 符号引用，以 `update-ref --stdin` 对具名分支的旧 OID 做条件更新，再发布新索引。最初的 symref-verify HEAD 与分支 update 同事务方案被回归测试发现会触发 Git 的重复 HEAD 更新拒绝，已删除该组合；最终事务只更新具名分支，并在文件写入前执行 prepare/abort 预检。提交任务分支的路径也复用此过程，删除原先的无保护 `resetIndex`。旧 Git 不支持事务语法时，在修改工作文件之前拒绝执行，不退回有竞态的方案。

恢复保证：每次同步在该 worktree 的实际 Git 目录下建立 `tivano-recovery/<UUID>/`，保留 `index.before`、`index.after`、`sync.patch`、`recovery.json`，并用 `refs/tivano/recovery/<UUID>/{working,source,head}` 固定恢复对象。冲突或后续失败不自动覆盖回滚，避免再次冲掉用户新编辑；提示恢复路径。ref 已更新、索引尚未 rename 的进程崩溃窗口可据记录人工调和。成功发布 ref 和索引后删除本次恢复 refs 和目录；失败记录继续保留。

远端成功而本地同步失败返回独立 `.syncFailed`：显示失败及 MR 地址，成功到远端的轮次结算为已发送，job 记录失败，避免全部远端成功时恢复扫描重新提交同一批工作。多项目里另一个项目同时失败的重试仍沿用现有编排，主线程需覆盖该组合。

验证交接：准备后同文件非重叠编辑应保留；重叠编辑产生明确冲突与恢复材料；新暂存修改、二进制、重命名、删除、可执行位、符号链接；在 ref 事务前插入终端提交或切分支；注入 cat-file、read-tree、apply、update-ref、rename 失败；分别在 ref 提交前后终止进程；旧 Git 语法拒绝须发生在工作文件写入前。核对索引、当前文件、恢复树三者，不能只看状态条。

限制：仓库锁是协作锁，`index.lock` 约束正常 Git 写入；它们不能锁住任意编辑器或不遵守 Git 锁的外部程序。Git 在读文件和写文件之间仍有极窄的外部写入窗口，本实现不宣称整个文件系统事务原子。已执行隔离并发及故障注入检查；真实外部编辑器的窄窗口未消除，任意直接改写符号引用且绕过 index.lock 的程序也不受该锁约束。

### 2. 产物启发式会排除已跟踪文件，随后删除副本（P1，高）

来源：本轮独立审计。旧路径 `TouchedPaths.isBuildOutput` → head `hydraWork` → 空 landing → `releaseHydraCopyAfterHistory` 强制删除；`.swiftpm`、`.commandcode`、`*.noindex` 等命名不能证明文件不是用户源码。储存页对 ignored 文件夹的判断也不能证明其中没有 force-added 跟踪文件。

当前入口：`AppModel+Hydra.swift:1083` 的 `hydraWork(in:from:to:)`、`:1290` 的 `releaseHydraCopyAfterHistory`、`:1338` 的 `keepHydraCopyAsPatch`；`AppModel+HydraMerge.swift:772` 的 `hydraWork`；`Git.swift:247` 的 `removeWorktree`；`StorageUsage.swift:103` 的 `removeBuildFiles`。

修复：base 树、HEAD 或索引已跟踪的文件优先保留，之后才对未跟踪路径应用产物和 ignore 规则。清理 build 文件夹前重读 ignore、索引和 HEAD，存在跟踪内容就保留。自动释放副本重新捕获当前差异，不信任过去的 landing；恢复补丁使用唯一名称。`Git.removeWorktree` 全调用链去掉 `--force`，包括 `AppModel.swift` 的线程删除调用。

恢复保证与行为变化：Git 拒绝移除有修改的副本时保留目录并报告；这意味着许多已落地但尚未在副本提交的头，会继续占用磁盘，不能再靠“landing 已成功”直接删除。保留提示已本地化；如未来恢复自动回收，须先设计完整归档与并发写入边界，不能加回无条件 force。`AppModel.swift` 原有“patch 后带修改也删除”的注释已同步修正。

验证交接：修改/删除已跟踪缓存目录文件、在缓存目录 `git add -f` 新文件、HEAD 跟踪但暂存删除的文件、ignored 目录内 tracked 子文件；landing 后再编辑副本；删除线程入口和储存页入口；含换行/引号的路径；删除前并发修改。每条路径均应保留内容或给出可恢复失败。

### 3. Git 或历史读取失败被当成没有工作（P1/P2，高）

来源：本轮独立审计。旧 `dirtyPaths` / `presentPaths` 的空集合兜底会让同步把未知当干净或不存在；收集路径、冷 head 历史和 diff 也有吞错结算风险。

当前入口：`Git.swift:641` 的 `dirtyPaths`、`:659` 的 `ignoredPaths`、`:672` 的 `trackedPaths`、`:683` 的 `presentPaths`、`:1129` 的 `apply`；`AppModel+HydraMerge.swift:772` 的 `hydraWork`。

修复：这些集合查询改为 throws，校验退出状态、NUL 记录数和类型；先解析 ref 的树，避免坏 ref 被逐路径当作 missing。Git 的正常 check-ignore 退出 1 仍表示无匹配。收集、sweep、差异生成及冷历史读取错误向上传递，保留 job 为失败，不用空集合或空历史继续。临时 apply 索引复制失败不再吞掉，冲突列表通过 NUL 查询且检查状态，不从人类 stderr 猜文件名。three-way apply 写冲突标记前另固定 `refs/tivano/recovery/<UUID>/before-apply`。

验证交接：权限拒绝、磁盘满、超时、失效 HEAD/base、丢失对象、截断 cat-file 回应、复制索引失败、冷 head 历史损坏/丢失。确认没有 checkout/rm、强制删除或“无工作”结算。恢复引用用于人工取回冲突前内容，不能自动整树 restore 到继续编辑的 checkout。

### 4. 附件清扫忽略不可读历史（P2，高）

来源：本轮独立审计。旧 `Storage.sweepOrphanedAttachments` 读取失败直接 continue，之后删除超过一天且“未被引用”的附件；损坏历史仍可能是它们唯一的引用。

当前入口：`Tivano/Services/Store/Storage.swift:363` 的 `sweepOrphanedAttachments`。

修复：`DiskWriter.performMaintenance` 先在写入队列取得扫描代次，再在后台任务完整枚举和读取；仅每次删除回到写入队列并复核代次，枚举失败、JSON 失败、线程/turn 解码失败、缺 turn 文件或 revision 均中止整轮。`Unreadable/` 只要有隔离内容就保留所有附件，包括非 JSON 恢复材料，不把隔离当成放弃所有权。仍保留原有一天宽限与命名限制。

恢复保证：不完整引用清单不能授权删除。代价是有损坏/隔离历史时附件不自动释放，需先恢复或由用户决定归档处置。扫描依旧在后台，新增有效性检查会增加一次类型解码，规模为总历史字节数，未测时间。

确定的并发误删路径是：旧 detached census 读完历史 → DiskWriter 发布新引用 → 旧集合删附件。后台 census 必须检查提交代次：扫描期间提交但尚未落盘的保存也可能引用旧附件。因此本轮增加写入提交代次和正在提交计数，覆盖异步/同步保存、删除与附件导入；扫描期间有新提交则中止删除，每次 unlink 和提交登记共用短锁，枚举和解码不持该锁。计数覆盖“登记写入到真正排队”的窗口。附件复制和数据导入也进入同一队列，复制后的修改时间重置为导入时间；一天宽限仍只是孤儿候选规则，不是并发安全依据。维护闭包不得重入 DiskWriter，否则会形成串行队列自锁。

验证交接：顶层坏 JSON、合法 JSON 但 schema 损坏、目录拒读、缺 turn、缺 revision、turn ID 与文件名不符、隔离历史及非 JSON 隔离文件；健康时只删真正孤儿。脚本暂停在 census 完成、删除之前，此时提交实际 `writeThread`，要求保存和同步导入能在 census 暂停时完成且旧附件保留；另覆盖先提交保存再排队清扫。上述附件用例已在隔离库运行通过；未覆盖外部进程绕过 edition 租约直接修改库的情况。

### 5. 跨 lead / edition 落地没有共用仓库写锁（P2，高）

来源：Thor 10-21 / 10-22 及本地安全提案 B1～B5。旧 landing 只排自己的 lead，不能看见另一个 lead 或 edition 的合并写入。

当前入口：`Git.swift:108` 的 `repositoryWriteLease`、`AppModel+Hydra.swift:1117` 的 `applyHydraHead`、`AppModel+HydraMerge.swift` 的 `mergeHydraProject`。沿用 `SharedResourceLock.url` 和 `SharedLibraryLease`，键为解析符号链接后的 Git common-dir，锁文件仍在两 edition 之外。

修复：landing 在真正 apply 前取得同一租约，覆盖操作状态读取、恢复材料和写入；等待可取消、有截止时间，超时保留补丁。等待后复核 head 的 copy/base/target。merge 在取租约之前等待当前 landing；同步 helper 不重复取租约。清理持锁范围也避免调用再次取同一锁的 helper。

验证交接：两 lead 同 checkout、两个 linked worktree、Release + Dev 同仓库；merge 等 landing 与 landing 等仓库锁同时发生；取消等待、超时、重新派发 head、apply 抛错均须释放租约。`ThreadRuntime` 的 revert 等其他写入口不在本轮独占范围，是否统一纳入写锁交主线程协调，不能据此称所有仓库操作已串行。

### 6. `hydraLanding` 完成后永久非 nil（P2，高，Hank 交叉发现）

当前入口：`Tivano/App/AppModel+Hydra.swift:1009` 的 `landHydraHead`、文件顶部 `HydraLandingTasks`。

修复：每次排队生成 token，以 runtime 身份记录最新 token；applied task 的 defer 仅在仍拥有该 token 时清空 `hydraLanding`。继续等待上一任务完成后再执行，旧任务结束不能清掉后续排队句柄。

验证交接：A 执行时排 B、A 完成时句柄仍指 B、B 结束归 nil；排三个、失败返回、重新建 runtime 与取消外层等待；确认 landing 串行且不因句柄残留阻止后续工作。

## 历史发现的现状及保留待办

| 分类 | 来源与当前源码证据 | 判断、局部方案及验证 |
| --- | --- | --- |
| 已实现并接入生命周期 | 10-13 P3 / 10-18 P2-12；`Core/Support/CheckoutClaims.swift:27` 的 deactivate、`:35` 的 activate、`:41` 的 retainOwners；`AppModel+HydraMerge.swift:933` 合并前按非归档线程集合核对 | 已移除的 owner 不再在合并路径长期扣走文件；停用标记拒绝迟到回调重新 claim，活跃 owner 不按年龄过期。AppModel 已接入删除/归档/取消归档，位置见下文。未改 ThreadRuntime 的 owner 计算规则。 |
| 仍适用，高；成本未实测 | 10-27 P2 表第 6 项：`Core/Models/Library.swift:230` 的 hydraJobs；`AppModel+Hydra2.swift:68` append；`ThreadRuntime.swift:3153` 追加 request；`AppModel.swift:2020` 节流保存；`Storage.swift:860` 整库编码写入 | 数据量随 job 和 follow-up 累积，单次保存 O(全库字节数)，持续繁忙时约每 4 秒一次；B 字节库的逻辑写入量可达约 B/4 秒，不是磁盘实测。先记录库大小、job 数、request 字节和编码耗时，再单独讨论完成 job 的有界摘要/显式归档；本轮不拆库、不截断既有请求。 |
| 已优化并测量 | `DiskWriter.writeThread` 原先逐个检查未脏 turn 的文件是否存在 | 每次保存先枚举目录一次，在本次保存内用集合检查存在性；写 head 成功后复用该集合清理。没有跨保存缓存，因此缺失历史仍拒绝保存。10,000 turn、单 dirty turn 的三次热运行中位耗时从 157.1 ms 降至 39.3 ms；详见总报告。 |
| 仍有明确缺口，高 | 10-20 P2-2：`Core/Support/StoragePaths.swift:13` 创建 task-workspaces；`AppModel.swift:1475` 删除线程、`:1487` 的清理只处理文档与指定 worktree | 独立任务目录没有对应回收入口，包含用户文件，不能自动删。局部方案：储存页单列孤儿目录、展示归属/大小，用户选择后移到废纸篓；验证删除任务与保留有内容工作区。属于后续产品/磁盘管理任务。 |
| 已修，不再计为当前缺陷 | 10-13～10-20 同步回收保存；当前 `AppModel.swift:862` 的 `releaseIdleRuntime` 调用 saveNow 后等待保存完成 | 不能继续转述“逐个 queue.sync 写盘”。快照成本仍可另测，由 Hank 负责。 |
| 已修，不再计为当前缺陷 | 10-18～10-25 入站图片；当前 `ProviderSession.swift:273` 的 `ToolImages.attachment` 为 nonisolated async + detached | 与 10-27 修复记录一致，不再列入本轮问题。 |
| 已修，不再计为当前缺陷 | 10-13 PendingReplies 重复 ID：`Core/Support/PendingReplies.swift:28` 拒绝重复并用 token 保护取消/超时；`TokenLedger.swift:305` 仅成功持久化后清旧 defaults | 恢复/迁移失败保护在位，未发现原报告所指覆盖路径。 |
| 当前有恢复保护 | `Storage.loadLibraryRecovering:116`、`KeepsakeStore.swift` 的 missing/value/corrupt/unavailable 区分、`DiskWriter.writeThreadSynchronously` 合并 pending dirtyTurns | 本轮不改恢复架构；这些机制不能被旧版损坏案例直接推翻。 |
| 未复现，不能升级为事实 | 10-20 P2-4：`scripts/consolidate_checkout.py:625` 重命名 source，`:633` 校验 library before-hash，app 不消费该迁移 journal | 断电后启动 app 再写库可能卡住脚本恢复，是源码推演，未做断电/迁移演练。保留离线恢复待办；现有脚本已有备份、journal、锁和恢复副本，不能写成“迁移必丢库”。 |

10-13～10-28 的滚动、Markdown、composer、语音、provider、远端 MCP 发现交 Hank / Walter 范围；本报告不重复宣布它们已修或未修。旧报告的毫秒估计、历史“PASS”和 ZCode 协议猜测不作为当前实测证据。

## 覆盖、边界与主线程接续

覆盖 Core 的 edition 路径、Library/Hydra/Timeline 持久化结构、PendingReplies、CheckoutClaims、共享租约；Store 的库恢复、turn revision 发布和清理、附件、账本与 Keepsake 恢复；Git 的捕获、落地、同步与 worktree 删除；跨 edition 数据根和离线迁移脚本的恢复顺序。Release/Dev 的路径仍由 `Core/Support/Text.swift:3` 的 AppInfo、`StoragePaths.root` 及既有 credential 配置派生，本轮没有导入、共享或迁移任何用户库。

这是定向源审，不是逐字重读所有 Core 文件，也没有证明所有恢复组合正确。主线程已运行隔离回归并完成构建；未读取生产库测量规模，未进行真实断电或真实用户编辑器竞争演练。

新增用户消息已使用完整 `AppText.localized` 模板，插值使用 `String(format:)`，文末映射已全部加入 catalog。AppModel 生命周期调用亦已接入。

API 依据：Git 官方 [apply](https://git-scm.com/docs/git-apply) 的三方合并及冲突语义、[read-tree](https://git-scm.com/docs/git-read-tree) 的两树索引保留规则、[restore](https://git-scm.com/docs/git-restore) 的 staged-only 行为、[update-ref](https://git-scm.com/docs/git-update-ref) 的 expected-old 条件更新与事务；HEAD reflog 的隐式更新见 Git 官方 [files-backend.c](https://github.com/git/git/blob/v2.56.0/refs/files-backend.c)。真实索引锁依据 Apple [open(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/open.2.html) 的 O_CREAT/O_EXCL/O_NOFOLLOW 语义。没有用远端评审或新增 head 代替本地证据。

## 收尾回归脚本：已通过

主线程已执行 `python3 scripts/data_safety_audit_checks.py`：最终 Apple Git 2.54 通过 33 项；另在 Git 2.56 通过当时的 29 项（随后新增保存规模用例）。默认创建系统临时目录并保留证据。也可提供一个尚不存在、位于源码之外的 artifact 目录，或用 `--case` 单跑一个条件、`--git` 指定支持 `cat-file -Z` 和 `update-ref` 事务的 Git。脚本不自动换 Git，不把缺能力视为通过。

脚本将当前声明抽取到 `DataSafety.swift`，编译成独立命令行夹具，不启动 Tivano。源码哈希、生成源码哈希、编译命令、编译日志、逐 case 结果、Git 子进程命令/输入/输出及新建仓库均留在 artifact 根。没有已有仓库路径参数，所有 Git 命令都指向脚本新建的 fixture 仓库；Git 全局/系统配置停用，child HOME、临时索引和共享锁根均隔离。

| 覆盖 | 实际执行对象与期望 |
| --- | --- |
| 捕获与同步 | 实际 `Git.captureTree(paths:onto:from:)`、`synchronizeCheckout`、`apply`；准备之后的非重叠编辑保留，重叠产生冲突及恢复对象，无关暂存内容保留，同文件暂存重叠拒绝；模式、二进制、删除、重命名各核对内容或索引。 |
| 读取失败 | 实际 dirty/ignored/tracked/present 查询；无效 ref、status/cat-file/check-ignore/ls-files 故障及截断 batch 回应必须抛错，不能输出成功的空集合。 |
| 恢复 | 故障注入在真实 ref 事务之前，或真实事务成功之后、索引发布之前；核对 HEAD、原索引、补丁、journal 和可读的 working 恢复树。另强制两种 apply 均失败，核对 before-apply 恢复引用。 |
| 文件归属与删除 | 抽取实际 head `hydraWork`、储存页 `removeBuildFiles`；已跟踪的产物目录文件、暂存的新文件和删除均不得过滤；dirty linked worktree 的移除必须失败且原文件保留。 |
| 仓库锁 | 两个独立夹具进程，分别从主 fixture 仓库和 linked worktree 取实际 `repositoryWriteLease`，第二个必须被拒；第一个释放后第二个应成功。 |
| 附件 | 实际清理函数、ThreadDocument 元数据解码和完整 DiskWriter；坏 JSON、坏 schema、缺 turn/revision、错 turn ID、Unreadable、正常孤儿；在 census 后暂停并提交保存，以及保存排在 census 前；旧源文件导入后不得立即作为旧孤儿删除。 |
| claim | 实际 CheckoutClaims；删除 owner 清理、archive 后迟到回调被拒、unarchive 后允许新 claim、共享 checkout 的 helper 停用不撤销 parent 的 claim；通过仅在夹具存在的扩展将活跃 claim 的时间设为 1970，确认不会按年龄淘汰。 |

夹具边界明确记录在 `results.json`：Git 的进程 transport 使用可注入故障的执行器，未覆盖产品 Shell 的超时/取消与 GitAdmission 调度；共享锁只替换存放根；head filter 只放宽可见性；附件清理只插入一个 census 后暂停点；provider/UI 叶子模型、library 准备和 prefetch 为 stub，ThreadDocument 解码、turn 引用结构、StoredTurn/File、ThreadSave、DiskWriter 声明保持来自源码。因此这些测试即使通过，也不能替代 App 构建、真实历史兼容或端到端队列验证。同步失败后的多项目编排、真实用户编辑器竞争、`hydraLanding` 三任务串行等仍需主线程在 App 层覆盖。

串行队列依据为 Swift 官方 [libdispatch queue.h](https://raw.githubusercontent.com/swiftlang/swift-corelibs-libdispatch/main/dispatch/queue.h) 对 serial FIFO 和同步重入死锁的契约；维护操作使用与项目 `writeOrThrow` 相同的 continuation + queue.async 模式。

## CheckoutClaims 生命周期接入（已完成）

所有权证据：`ThreadRuntime.claimOwner` 对有独立 worktree 的 head 使用其自身 ID；没有副本、直接在共享 checkout 工作的 Hydra head 使用 parent ID。故不能因归档一个共享 head 就删除 parent 的所有 claim，也不能用固定时长清理仍活跃的 owner。`retainOwners` 已在合并扣除 foreign paths 前执行，只移除该库中已不存在或已归档的 owner；停用 ID 留作拒绝迟到回调的标记，取消归档只允许之后的新 claim，不恢复旧路径记录。

主线程已在下述位置加入调用：

```swift
// archive(_:)：完成 isArchived / isPinned 的 updateThread 后、updateDockBadge 前。
CheckoutClaims.deactivate(owner: id)

// unarchive(_:)：当前线程和每个 helper 各自 updateThread 取消归档之后。
CheckoutClaims.activate(owner: id)
// 放在既有 for helper 循环内：
CheckoutClaims.activate(owner: helper.id)

// completeThreadDeletion(_:cleanup:)：let ids = Set(removed.map(\.id)) 之后。
// 此时删除已经通过 commitLibrary；提交失败不能撤销还存在的 owner。
for id in ids { CheckoutClaims.deactivate(owner: id) }
```

该接入覆盖 `deleteThreads` 和项目删除复用的 completeThreadDeletion，也覆盖递归 archive helpers。没有这些 hook，合并前核对仍能清掉旧 claim，但 ThreadRuntime 自己的 foreign/othersActive 在下一次 merge 之前仍可能短暂读到旧记录。脚本验证 Core API；AppModel hook 已落地并通过整应用编译，未做真实 GUI 的归档操作演练。

## 数据保留的代价与待测优化

保守拒绝 dirty worktree 删除会保留目录及注册项；同一 base/after 快照的补丁已去重。成功同步和三方 apply 清理本次恢复资料；失败的 journal 和固定恢复对象仍保留，没有自动过期策略。不能从“保存了一份 patch”直接推断其足以覆盖仍在写入的副本，也不能重新加回无条件 `--force`。未测保留量，不给 GB 级估算。

附件维护先等待扫描开始前的已排队保存，随后在后台扫描；后续写入无需等待 census，新保存提交会使删除代次失效。单次 unlink 仍与提交登记共用短锁，真实磁盘延迟未测。隔离测试已经证明 census 暂停期间保存和同步导入可完成；后续体量测量应关注扫描成本及失败恢复资料占用，不改变数据保留保证。整库账本重写仍是未测量待办；长历史保存已完成局部优化与合成测量。

## 本地化 key 映射（已加入 catalog）

下面 JSON 中的 `\n` 表示 key 内的实际换行，`%@` 顺序与调用方一致；不要把插值后的具体路径或 UUID 放进 catalog。

```json
{
  "Git did not return its common directory.": "Git 未返回共享目录。",
  "Incomplete git cat-file response.": "git cat-file 的响应不完整。",
  "Unexpected git cat-file response.": "git cat-file 返回了无法识别的响应。",
  "Git did not return its index path.": "Git 未返回索引路径。",
  "The checkout changed while the merge was prepared.": "准备合并期间，checkout 已发生变化。",
  "Checkout synchronization has conflicts: %@": "同步 checkout 时出现冲突：%@",
  "Checkout synchronization failed. Recovery: %@\n%@": "同步 checkout 失败。恢复资料：%@\n%@",
  "Hydra could not inspect the team's work.": "Hydra 无法读取团队的工作成果。",
  "The checkout's Git status could not be read.": "无法读取此 checkout 的 Git 状态。",
  "The checkout is detached; synchronize it manually.": "此 checkout 处于分离 HEAD 状态，请手动同步。",
  "Hydra merged the work, but could not synchronize the checkout.": "Hydra 已合并工作成果，但未能同步 checkout。",
  "The project checkout's Git status could not be read.": "无法读取项目 checkout 的 Git 状态。",
  "A head's history could not be read; its work was not settled: %@.": "无法读取一个 head 的历史，尚未将其工作标记为完成：%@。",
  "The default branch diverged; the checkout was kept for manual synchronization.": "默认分支已产生分歧，checkout 已保留，请手动同步。",
  "The head changed while its landing was waiting; its patch was kept.": "等待回写期间，head 已发生变化，其补丁已保留。",
  "The head's recovery patch could not be saved; its copy was kept.": "无法保存 head 的恢复补丁，其副本已保留。",
  "A rebase or merge is underway in the checkout, or its Git state could not be read.": "checkout 正在进行 rebase 或 merge，或无法读取其 Git 状态。",
  "The head's unfinished work could not be preserved. Its copy was kept so you can retry.": "无法保全这个 head 尚未完成的工作。已保留其副本，便于重试。",
  "%@'s unfinished work was kept as a recovery patch.\n%@\n\nThe copy is removed only if Git confirms it has no uncommitted changes. Review the patch against your checkout before applying it with `git apply --3way %@`.": "%@ 尚未完成的工作已保存为恢复补丁。\n%@\n\n仅当 Git 确认副本没有未提交的修改时，才会移除副本。请先对照 checkout 检查补丁，再使用 `git apply --3way %@` 应用。"
}
```
