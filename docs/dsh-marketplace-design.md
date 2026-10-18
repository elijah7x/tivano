# DSH 市场插件继承方案（rc.2 静态设计）

> 实现进展：主线程已实现 rc.2 只读组合，并完成四模式共 16 项隔离 fixture 与 8 条真实 App 账号消息。下文保留原静态设计与研究范围，不代表所有建议均已实现。当前实现、限制和验收证据见 `dsh-runtime-contracts.md`、`dsh-validation.md`。

## 结论

推荐实现 **Tivano 自有 ACP 启动适配层：只读导入 desktop/web 的配置与解析上下文，运行 ACP 组合，管理写入与来源 profile 分离**。不要把 desktop 当活动可写 profile，也不要把它的 `node_modules` 链接给 Tivano profile。

**rc.2 现有 CLI 参数不足以直接完成这些约束。** `--profile acp --patch <desktop patch>` 缺 bundle 与解析上下文；改成 desktop 再关闭几个 UI 行则会带入 Web/桌面服务，Creator 也会写回 desktop。官方导出函数可复用，但缺少只读 profile 导入、独立写入目标及 ACP 能力准入三个接口。必须实现下面的适配层后再宣称支持；本文件不是已实现或已验收声明。

“完整继承”应指：来源已启用、可在 ACP 安全运行的市场 bundle 按原顺序进入组合，使用原安装依赖、用户配置及精确版本豁免；不静默遗漏。任一启用 bundle 依赖 Web、调度器或未明确的全局后台副作用时，启动明确失败，而不是跳过后宣称完整。**任意第三方插件全部原样运行**与**保证无后台任务、无源文件写入**不能仅靠 Cordis 配置同时保证。

## 证据范围与锚点

本次仅阅读源码与项目文件，未运行 DSH、构建、测试、lint、配置 dump 或其他验证。账号及四模式 Swift 调用已有结果以 `docs/dsh-runtime-contracts.md` 为准，不重复审计 ACP 生命周期。

官方文件来自主线程保留的已安装 **0.2.1-rc.2** 源码目录：

`/Users/elijah-air/.tivano/worktrees/tivano.dev-cae3eb4d/build.noindex/dsh-native-source/`

下表行号针对该副本，符号名是跨行号变化的检索锚点。

| 文件 / 行 | 静态结论 |
| --- | --- |
| `dsh-app-boot__lib__index.js:551–568`，`PROFILE_TEMPLATES`、`RETIRED_BUNDLES` | ACP 模板为 base + acp-app，Web 为 base + web-app；存在退役 bundle 清理。 |
| 同文件 `:995–1051`，`resolveBundleDir`、`loadProfileDirectory` | bundle 先从运行安装的 anchor 查，再从来源 profile 查；按照 manifest 的 `dsh.profile.bundles` 顺序加载 bundle patch，再读用户 patch；失败 bundle 记入 `skippedBundles`，并非整体抛错。 |
| 同文件 `:941–968`、`:1016`、`:1065–1074` | `loadProfileDirectory` 会调用 `dropRetiredBundles` 改写 manifest；`loadProfile` 还可能初始化、清理 link projection、规范化模板。二者都不能直接当只读导入器使用。 |
| 同文件 `:341`、`:372–422`、`:311–335` | 豁免实际在独立的 `compatibility.json`，不是 package.json。只认可精确 `package@version → runtime versions`；读取坏记录会告警并忽略，不从 manifest 回退。 |
| 同文件 `:1118–1137`，`readBundlePatches`、`readProfilePatches` | 顺序为 bundle → profile patch → `$DSH_HOME/cordis.patch.yml` → launch overlays → telemetry 硬关闭。缺省重读 bundle 会再次走可能写文件的 loader。 |
| 同文件 `:704–896`，`createRuntimeResolution`、`dependencyClosure` | 解析不只依赖 bundle 名：安装包图、来源直接依赖/peer、bundle 依赖闭包、linked roots 共同参与。`localPackageNames` 只记原 profile 中确已安装的直接依赖；不能把包名数组当完整解析表。 |
| 同文件 `:804–838`，`ProfileRuntimeResolution.computeLatestResolution` | refresh 会从原目录重新加载，且不会保留 synthetic layers；初始临时组合不代表后续 reload 仍安全。 |
| 同文件 `:1305–1351`、`:1846`、`:2065`、`:3492–3540` | 解析与 profile 所在路径、linked roots 相关；`PluginPackages` 安装运行期拦截及 Worker 解析，支持 ESM/CJS，不等价于设置 `NODE_PATH`。refresh 不清 Node 模块缓存。 |
| 同文件 `:2305–2403`，`prepareProfileEntries` | 行级兼容检查从 `profileContext.dir/compatibility.json` 读取；不兼容行被 disabled，包括 Include 的递归检查。只检查 bundle manifest 不够。 |
| 同文件 `:4125–4153`，`mountRootInclude` | `bareModuleBaseUrl` 可独立指定 bare import 的来源；相对名字仍依配置树基址解析。一个全局 bare anchor 不解决每个用户 Include 的相对路径或写入归属。 |
| 同文件 `:4507–4559`，`boot` | `prepare(ctx)` 在树挂载前运行，可接入自有服务；之后挂 root Include、等待 Loader、审计启动。不能把成功 compose 当作启动通过。 |
| `dsh-web-app__cordis.patch.yml:45`、`:139–140`、`:168–205`、`:586–589` | Web 层带 desktop telemetry、真正的 Schedule 服务、Web startup/server/runtime、preset registry；不是只有可删掉的浏览器 UI。 |
| `dsh-acp-app__cordis.patch.yml`（全文） | 插入 `acp-app-startup` 与 `acp`，关闭 session-title-llm 和 HMR；stdout 属于 ACP。 |
| `dsh-base__cordis.patch.yml:15–33` | base 默认含 plugin-manager 服务；仅 tools 默认 disabled。关闭模型工具不等于关闭管理服务。 |
| `dsh-plugin-manager__lib__index.js:1572–1608`、`:1930–1957`、`:2279–2305` | manager 捕获 `ctx.profileContext`；启停插件写 `profile.patchPath`，启停 bundle 写 `profile.dir/package.json`。 |
| 同文件 `:1032–1078`、`:1636–1651`、`:1970`、`:2136`、`:2360–2415` | patch 写入、版本豁免、安装/删除都属于当前 profile；修改以该目录 package.json 锁串行化。没有 HMR 仍会持久化，返回 `restart-required/no-hmr`。 |
| `dsh-plugin-manager__lib__types__tools.js:76–166`，`apply` | Creator 的 `plugin_manager` 调用同一服务；即使已授权 full-access，它也不是临时预览操作，安装可能执行构建脚本。 |

项目侧：`DshCLI.swift:userProfilePatch/launchArguments/patchesApply` 当前只追加 desktop 优先、web 后备的 patch；`DshPatches.swift:112–129` 的 Creator 会开启管理工具并加入 host runner、inspect 和 tool-cordis。上述事实修正了“复制 package.json 就可带入所有能力”的假设，也细化了旧契约中关于豁免位置的概述。

## 推荐实现

### 1. 输入与只读加载

新增一个随 Tivano 交付、版本受控的 JS 启动适配器，由 Swift 启动计划调用；使用已安装 DSH 的 Node/模块与安装 anchor，不下载、不安装、不修改官方包。不假定现有 `dsh` 可执行文件接受任意 JS 文件：实现阶段必须接入实际安装的启动方式；目前提供的源码副本没有 CLI launcher，不能把这个入口当作已经确认的参数接口。

来源选择以 **profile manifest 存在**为准，desktop 优先，其次 web；没有用户 patch 不代表没有市场插件。存在但损坏的 desktop 不得悄悄回退 web。两者均不存在时使用纯 ACP 模板，不创建或修复用户 profile。保留现有 `DSH_HOME` 与账号路径，凭证继续由原 credentials provider 原位读取，不能复制 `.credentials.yaml` 或更换 home 来制造隔离。

实现 `readSourceProfile`（建议函数名，非官方已有 API）：

- 用 `readProfileManifest`、`resolveBundleDir`、`bundlePatchPaths`、`loadOverlayPatches` 只读构建与 `loadProfileDirectory` 对应的 layer 数据；不调用其写入清理路径。退役条目只在内存中处理并给出原因，不写回。
- 保留启用顺序、禁用状态、patch 来源、bundle 目录和安装版本。安装但未启用的 bundle 不自动激活；普通已安装依赖仍可被启用插件或用户 patch 导入。
- 读取 `readProfileCompatibility` 的有效精确豁免；有坏记录时给出诊断，不扩大豁免范围。与运行安装版本不匹配的旧豁免不生效。
- 读取 profile patch 和 home patch 各一次到内存，保留相对解析基址。配置可能内含秘密，不能记录完整值、不能为“缓存”复制到磁盘。原生 `!!js` 语义需用官方 parser 保留，不能用 Swift 字符串过滤 YAML。
- bundle 不可读、依赖缺失、兼容冲突或功能 patch 目标不存在均停止启动，附 bundle/行/来源路径；不能把官方 `skippedBundles` 的容错当成完整继承。

### 2. 组合 ACP，而不是裁剪整个桌面 Host

构建空 root 上的有序组合：

1. 运行安装的 `dsh-base` + `dsh-acp-app`，各一次。
2. 来源 manifest 中已启用的市场 bundle，保持相对顺序；已识别的官方 surface 层不加入。
3. 来源 profile 用户配置，然后 home 用户配置。
4. Tivano 模式、no-delegation、report guard，保持已有相对顺序。
5. 不可被用户覆盖的 ACP 边界策略，以及原 telemetry opt-out。

不导入整个 `dsh-web-app`、Web presets 或桌面 surface。不能凭 `@deepseek-ai/` 前缀删掉所有官方市场包；surface 排除须按已确认版本的精确包身份维护。用户或市场 patch 若依赖 Web 行，必须按来源识别为 surface-only，或拒绝启动；不能推广当前三个 UI missing-entry 例外来吞掉功能错误。配置对象整体替换语义应保持，不自行深合并。

准入必须在任何插件挂载前完成，递归覆盖 group、Include 与后续动态加载：

- 保留且固定 ACP transport/startup；禁止替换其模块身份、重启 Web server/runtime、启用 HMR 或原始管理写入服务。
- 已知 Web UI、desktop telemetry、Schedule 和桌面全局后台行不能激活；也不能允许换一个行 ID 插入同一模块来绕过策略。按规范化模块身份与能力检查，不只按 ID。
- 市场包需要经审查的 ACP host 入口/能力声明（绑定版本或内容指纹）；纯浏览器包、依赖 Schedule 的包及未知启动副作用的包报不支持，不把它们悄悄变成 disabled。
- rc.2 本次读取的组合接口没有通用的“禁止后台服务”能力契约。最小实现是版本绑定的准入表与递归加载约束；任意第三方 JS 仍不是沙箱。若要求对恶意插件也保证不写文件、不启动任务，还需进程级隔离或官方受限执行接口，不可用工具权限或 chmod 冒充。

因此首个交付应是有明确拒绝边界的 ACP 市场兼容，不是“任意 desktop 插件完整兼容”。

### 3. 依赖解析与所有权分离

在内存创建来源 profile 的 runtime resolution，保留安装优先、源 profile 直接依赖查找、bundle 依赖闭包及原包内相对依赖语义；通过 `PluginPackages` 交给官方 ESM/CJS/Worker 解析。包目录仍指向用户现有安装，**不创建 node_modules 链接，不复制包，不执行 pnpm**。

初始数据应由只读 loader 提供；不得调用 `computeLatestResolution`/`refresh` 回到原写入路径。适配器每次启动重建，不在线复用官方 manager 的刷新。单用一份“合并 package.json”加 `createRuntimeResolution` 不足：普通直接依赖依靠原 profile 本地查找，安装保留包与 profile 包的优先级也不能被一张全局映射粗暴扁平化。

`profileContext` 不能指向 desktop：

- 解析上下文：只读来源 profile 与运行安装 anchor。
- 活动 profile 身份和管理目标：Tivano 自有、每次启动独立的目录。
- compatibility：自有目录可保存有效精确豁免的派生副本供官方行级检查使用；它不是授权来源，不能新增、延长或跨版本授权。
- root/Include：自有空 root；来源配置在内存组合，必须保留每个来源的相对路径语义。相对 plugin specifier、嵌套 Include、配置内 `baseUrl` 不能靠随意换工作目录解决。需实现只读 provenance-aware Include 适配器；未支持的路径形式拒绝，不能挂一个可能回写源文件的原生 Include。

这是新增适配接口，不是 `boot` 的现成布尔选项。可复用 `boot(..., prepare, bareModuleBaseUrl)` 和 `PluginPackages`，但来源路径与活动写入路径分离、递归 Include、边界策略必须由 Tivano 明确实现。Worker 与 linked package 的相同约束也属于实现范围。

### 4. Creator 写入边界

本方案的 Creator 保留开发/检查用途，**不继承对用户 desktop/web profile 的管理写权限**。不能用“ACP 关闭 HMR”来保证只读；manager 无 HMR 也会先保存。

- 不挂原始 `plugin-manager` 写服务，改为自有只读 inventory 服务；插件、bundle、豁免列表反映实际导入来源及生效状态，而不是空的生成 profile。
- `install_bundle`、`remove_bundle`、`set_plugin`、`set_bundle`、`set_version_exemption` 均明确拒绝，并说明此 Host 是只读继承。不能让 Creator 安装到生成目录后返回假成功，也不能自动转写 desktop。
- Creator 新文件只属于用户明确授权的项目工作区，不能覆盖来源插件、profile、凭证或安装目录。开发出的 patch 可以作为工作区提案保存；本任务的约束下不自动应用到用户配置。
- `DshPatches.creator` 不能原样沿用：管理工具改接只读 API；`cordis-host-runner`/`tool-cordis` 的配置写入与动态挂载能力需要受同一策略约束。**当前保留源码没有这两个包的实现，不能确认其所有写入最终经过 plugin-manager。** 在读取并定位它们及 Cordis Loader 的持久化入口前，不开放其变更操作；允许的只读 inspect 也需确认没有附带执行入口。
- 禁止只在模型工具层拦截：内部服务、Include、动态加载和 shell 可成为旁路。这里承诺的是受支持的可信插件及适配 API 的写入归属，不是针对任意 Host JS 的 OS 沙箱。

若产品坚持 Creator 保持原生安装/配置修改能力，则与“不安装、不修改用户已有 profile 或插件”冲突；不能以换个 profile 名消除这个冲突。推荐保持只读继承，不自动扩大授权。

## 生成物、并发与配置变化

- 生成物放在 `DshCLI.home` 对应的 edition 私有 `dsh/marketplace-runs/<UUID>/`，只由该次启动拥有；目录 0700、文件 0600，拒绝已有 symlink 目标。资源包括空 root、最小活动 manifest、派生 compatibility 和无秘密的诊断元数据；源 patch 不落盘。
- 不共享一个可写 `tivano-acp` profile。主会话、Hydra heads、auth/catalog 探测各有自己的运行目录；故不会互改 bundle、overlay 或 Creator 状态。退出时只删自己的目录；崩溃遗留按 lease/进程身份确认无活跃 owner 后清理，不触碰用户 profile 或其他 edition。
- 来源由 DSH 自己管理。读取期间采集 manifest、compatibility、profile/home patch、bundle patch、相关安装包/锁文件的身份与内容指纹，读完再次比较；发生变化有限重试，持续变化报“profile 正在更新”，不安装或修复。指纹诊断只记录文件身份/摘要，不记录配置值。
- 这种双读不是跨进程事务，也不能冻结源码：desktop 的安装/卸载会改变未来 lazy import。现有 package.json 写锁并不能证明全部文件都受它覆盖；不能擅自创建用户 profile 的锁文件来宣称隔离。
- 启动后固定配置代次，不做 HMR。下一次启动重新导入；来源发生变化时，拒绝新 turn 并在安全边界重新启动/恢复，不给当前树打热补丁。依赖消失或在使用中变化时终止本次运行、保留会话与原错误，禁止自动新建对话掩盖失败。
- 若要保证 desktop 安装与 ACP 同时运行仍有原子、稳定的依赖视图，必须补充 DSH 共同遵守的只读租约/版本化包快照接口；当前源码不提供这个保证。此缺口不得被描述为已经支持无缝并发升级。普通并发 ACP 启动只读同一静态安装则不需要改源 profile。

## 失败策略

适配入口/版本不支持、source manifest 损坏、缺依赖、无效配置、未准入市场包、权限边界无法建立时，均在启动 ACP 前失败。原包代码不得为探测 capabilities 而提前执行。错误指出来源、包、行与原因，移除配置值和凭证；不回退到“只有 ACP 基础层”。

成功解析不能代表运行成功：实现后仍需启动审计和真实 ACP fixture。兼容检查自动 disabled 的功能行、待服务导致未激活的启用行都要纳入准入结果；不能只接受退出码为零。`--dump-config` 与真实启动必须使用同一代配置与解析输入，dump 本身不应打印秘密配置到应用日志。

## 实现改动点（本次未修改）

| 文件 | 调用点与必要改动 |
| --- | --- |
| `Tivano/Services/Providers/DshCLI.swift` | `userProfilePatch` 改为 manifest 驱动的来源描述；`launchArguments` 升级为可失败的启动计划（实际 executable、args、env、运行目录 lease），接入自有 launcher；`patchesApply` 使用同一代输入及结构化准入错误，而不是只匹配 missing-row 文本。账号、基础环境处理保持原路径。 |
| 新增 `Tivano/Services/Providers/DshMarketplace.swift` | Swift 启动计划、edition 私有目录和 lease、来源变化标识、适配版本选择、清理；不承担 YAML/Node 解析。 |
| 新增 `Tivano/Services/Providers/DshMarketplaceBootstrap.swift` | 按 `DshReportGuard` 现有模式承载 JS 适配器源码：只读 loader、组合、provenance Include、resolution 接入、只读管理服务、准入策略及结构化错误。函数名和上述文件拆分为建议新增实现，非现有 API。 |
| `Tivano/Services/Providers/DshPatches.swift` | `creator` 改接只读管理与受限 inspect；所有模式之后追加不可覆盖的 ACP 边界，禁用原 manager 服务而不只禁工具。 |
| `Tivano/Services/Providers/ACPSession.swift` | `launchArguments` 的 DSH 分支（约 :114）、`start(applyingSelection:)`（约 :134–160）、`authStatus`（约 :365–371）、`probeModels`（约 :395 起）统一取得启动计划；探测不能绕过准入；把目录 lease 绑定到进程生命周期。仅替换准备/启动输入，不重做已修复的 ACP 收发与恢复协议。 |
| `Tivano/Resources/Localizable.xcstrings` | 实现新增错误/只读说明时补英文 key 与 zh-Hans。 |
| `docs/dsh-runtime-contracts.md` | 实现验收后更新市场边界；澄清豁免位于 `compatibility.json`，列实际支持范围，不能提前标为完整继承。 |

## 主线程后续证据与验收（未执行）

实现前还需读取已安装 CLI 的 bootstrap/Node 入口、`dsh-cordis-host-runner`、`dsh-tool-cordis` 和 Loader/Include 持久化实现，确定可调用入口与所有 Creator 写入口；不能仅凭本目录缺失这些文件就猜接口。缺少的只读导入、独立解析/管理上下文和 capability 准入，应实现为 Tivano 自有适配代码或请求官方新增接口，不修改用户安装的官方源码。

最小隔离 fixture 应包括：只有 manifest 选中的市场 bundle、普通直接依赖的 bare import、嵌套依赖/peer、ESM/CJS/Worker、精确版本豁免、禁用 bundle、带相对 Include 的用户配置，以及尝试插入 Web/Schedule/动态行的负例。验证目标包括：ACP 可调用真实市场工具；来源文件无修改、无 node_modules 链接、无安装；所有新进程无 Web listener/重复调度器；Creator 变更明确拒绝；并行启动互不覆盖；配置更新/包移动明确重启或失败；auth/catalog 同样遵守边界。四模式与 report guard 在新组合下仍需回归，但不重复归因已修复的 ACP 生命周期。

**目前结论仅来自静态源码：推荐路径和缺失接口已确定，启动入口、Creator 全部写入路径、原子依赖代次及运行行为尚未验收。**
