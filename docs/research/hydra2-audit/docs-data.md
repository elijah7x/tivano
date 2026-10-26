# Hydra 2 文档、评估与数据审计

2026-10-26 · Suki · 只读源码审计。行号对应本任务工作副本；未构建、运行脚本、启动 App 或执行其他检查。这里的“建议替换”是可直接采用的文案，“建议代码”是后续实施锚点，不表示已经修改或验证。

共 **34 项发现**：`docs/hydra2.md` 15 项、评估与数据 12 项、其他文档与更新日志 5 项、捕获与探针 2 项。另核对了全部 27 个含 Hydra 的 docs 文件、两个 README、`AGENTS.md`、`CHANGELOG.md` 的 `[Unreleased]` / `[2.1.x]`，以及 `Tivano/App/Captures/` 全部 17 个文件。

## 最重要的三项

1. **早期 v2 账本有丢失风险。** 后加的 `leadBuilt` / `leadEditsAfterReports` 是非可选字段；旧记录缺键时合成解码失败，`ChatThread` 又把整个 `hydraJobs` 回退为空数组。评估脚本还把缺字段当成 `false` / `0`。见 E03。
2. **当前比较不能回答 owner 的质量 > 成本 > 时间目标。** v2 的无头任务被放进总体中位数，与只含有头任务的 v1 基线直接比较；质量与成本没有结果指标，耗时和合并指标也不是同一边界。见 E05、E06、E09、E11。
3. **主文档仍描述初版方案，且审查承诺大于实际覆盖。** 两种 tilt、全部消息先给 lead、`pendingReview` 和后加账本字段未完整回写；共享检出、多项目、超过 80,000 字符的 diff 并不都在异家审查输入中。见 D01–D15，尤其 D03、D04、D11、D12。

## 一、`docs/hydra2.md` 逐节核对

### D01 — 状态与“只改决策层 / 副本不变”互相矛盾

**文档：** 第 3 行“状态：草案”，第 8 行“副本、落地、合并、watchdog 原样共用”，第 92 行“不改副本……的行为”。

**代码：** v2 已在设置和更新日志中落地；完成 head 的副本在 v2 中保留，v1 才在回报后释放（`Tivano/App/AppModel+Hydra.swift:826-832`），并在 job settle 后统一释放（`Tivano/App/AppModel+Hydra2.swift:91-100`）。审查也插到了可选自动合并之前（`Tivano/App/AppModel+Hydra2.swift:83-92`）。复用的是副本创建、落地、合并和 watchdog 算法，不是所有生命周期行为。

**建议替换第 3、8、92 行：**

> 状态：Labs 已实现（2026-10-26）；本文按当前实现及后续决策修订。
>
> - Hydra 2 替换决策层，并改变完成 head 的副本保留时机；副本创建、增量落地、远端合并和 watchdog 的底层算法继续复用。异家只读审查在可选自动合并之前运行。

### D02 — “实验室只有一个开关、没有子开关”已漏掉 tilt 和设置变化

**文档：** 第 9 行“实验室里只有一个开关……下文第 1–7 节全部生效，没有子开关……旧记录缺少的新字段一律按 v1 解释”。

**代码：** 有效开关是 `alphaEnabled && alphaHydra2Enabled`（`Tivano/App/AppSettings.swift:395`）；v2 下另有 `HydraTilt.restrained` / `.active`（`Tivano/Core/Models/Hydra2.swift:17-20`，`Tivano/App/AppSettings.swift:828-837`）。v2 隐藏 v1 lead-review 开关并改自动合并文案（`Tivano/App/Views/Settings/HydraSettingsPage.swift:184-220`）。旧 head 缺 `mode` 才可按 v1；早期 v2 的 `tilt=nil` 是未知，不应笼统把所有缺字段都解释成 v1。

**建议替换第 9 行：**

> - Labs 的 Hydra 2.0 开关默认关闭，并受 Labs 总开关约束；没有各环节独立开关。v2 在 Settings › Hydra 另有一个 Restrained / Proactive 委派倾向，所有用户消息都先给 lead，由 lead 决定 heads 承担什么。v1 的两个消息路由开关和 lead-review 开关在 v2 下不生效且不显示；自动合并开关改名为“完成后自动提交并合并”。缺少 `mode` 的旧 head 按 v1 解读；早期 v2 记录缺少的新字段按“未知”处理，不改写历史。

### D03 — job 模式盖章正确，但中途切换和 tilt 快照仍有混用路径

**文档：** 第 23–26 行，尤其“中途切换开关只影响下一条请求，不会在一个 job 里混用”和“直接排给 heads 的任务沿用该 lead 当前 job 的模式”。

**代码：** 新用户回合确实只在 `hydraHeads == nil` 时盖章（`Tivano/App/Runtime/ThreadRuntime.swift:1691-1709`），模式也进入 session launch（同文件 `2052-2067`）。但：

- v1 直达 head 的开关读取的是**当前全局** `isHydra2Enabled`，不是当前 job 的盖章（`Tivano/App/AppSettings.swift:834-837`；`Tivano/App/Runtime/ThreadRuntime.swift:1418-1437`）。v2 job 中途关闭 Labs 后，旧的 `hydraAlwaysHeads` 可再次直达 head，并进入 v1 的 `queuedHeadPrompt`，造成混用。
- `beginHydraJob` 只在开始时记录一次 `tilt`（`Tivano/App/AppModel+Hydra2.swift:38-52`），后续每回合却重新读取实时 `settings.hydraTilt`（`Tivano/App/AppModel+Hydra.swift:230-275`）。中途改 tilt 会改变后续策略，但账本仍写开始时的值。
- v2 生效时两个路由计算值都为 false，所以“v2 用户直接排给 heads”不是现行路径（`Tivano/App/AppSettings.swift:834-837`）。

**建议代码：**

1. 路由直接按 job 模式读取原始 v1 开关，不再使用含实时 `!isHydra2Enabled` 的计算值：`dispatchQueuedHead` 要求 `hydraJobMode == .v1 && (settings.hydraQueueHeads || settings.hydraAlwaysHeads)`，`dispatchSentHead` 要求 `hydraJobMode == .v1 && settings.hydraAlwaysHeads`。这样 v2 job 中途关闭 Labs 不会直达 head，v1 job 中途开启 Labs 也不会改变既有路由。
2. 给 runtime 一个统一的 stamped-launch helper：v2 从 `openHydraJob.tilt` 恢复 tilt（旧记录的 nil 用明确的兼容默认），v1 不读取 tilt。`startTurn`、`ensureSession`、`spawnDelegatedHeads`、`spawnWaitingHeads`、`dispatchHead` 都走这个 helper，不再分别读取实时值。

**建议将第 26 行替换为（配合上述修正）：**

> - v2 下所有用户消息都进入 lead；v1 的 queued/direct-head 路径只在其 job 盖章为 v1 时可用。模式和 tilt 都在 job 开始时快照，中途改设置只影响下一 job。

### D04 — 第 2 节的“默认自己做 / 同模型不派单 head / 搭档才派单项”已被两种 tilt 取代

**文档：** 第 28、32–36 行，尤其“单个 head 不派”和“机械改动和大量阅读即使只有一份也交给 heads”只用于搭档组合。

**代码：** 两种 tilt 都偏向 heads；Restrained 也允许一个 substantial self-contained piece，Proactive 优先派出 single bounded edits（`Tivano/Core/Models/HydraPrompts+V2.swift:10-25,47-64`）。基本策略按 tilt 分支，不再按同模型 / 搭档分支。另一个定义不一致是：文档和评估按 provider + model 判断同模型，`headsMatchLead` 还比较 effort（`Tivano/App/AppModel+Hydra.swift:256-258`；`scripts/hydra_eval.py:585-588`）。

**建议将第 28、32–36 行替换为：**

> ## 2. 派发策略：按上下文与 tilt 分工
>
> v2 的 lead 先计划，保留需要边读边判断的工作、跨文件设计、集成与最终检查；能写成自足 brief 的工作按下列倾向分配，计划可随回报修改：
>
> - **Restrained（存储值 `restrained`）：** 为并行、大量阅读，以及较大的独立单项工作派发；单项可包括跨多个文件的机械修改。小编辑和需要边读边判断的工作留给 lead。
> - **Proactive（存储值 `active`）：** 更优先使用 heads；能写清 brief 的独立单项、 bounded edits 和阅读都可派发，大工作拆成独立并行部分。琐碎或质量敏感、由 lead 亲自做更好的部分仍留给 lead，不能为了多派而拆散耦合工作。
>
> 两种 tilt 都适用于同模型和搭档组合。组合是否“同模型”按 lead 与共享 heads 配置的 provider + model 判断；effort 单独记录和比较，不改名为另一种模型。

**建议代码：** 若采用上述统一定义，从 `headsMatchLead` 删除 effort 比较；否则必须同步修改文档、`HydraLaunch` 注释和评估定义，不能保留三套口径。

### D05 — `headsNote` 不是所有组合都会注入，Cookbook 也没有该字段

**文档：** 第 37 行“非空时写入 lead 策略……Cookbook 配方可带默认值”。

**代码：** note 只在 `!launch.headsMatchLead` 的分支里注入（`Tivano/Core/Models/HydraPrompts+V2.swift:19-24`）；`HydraPairRecipe` 没有 `headsNote`（`Tivano/Core/Models/HydraCookbook.swift:7-25`），`resolve` 也未赋值（`Tivano/App/HydraCookbook+Resolve.swift:32-44`）。

**建议代码（保住原设计，而不是删掉承诺）：**

- 把 `headsNote` 注入移到 `if !launch.headsMatchLead` 外，使同模型组合也能说明 heads 擅长什么；`headsLabel` 仍只在模型不同的时候添加。
- 在 `HydraPairRecipe` 加 `var headsNote: String? = nil`，并在 `resolve` 中 `pair.headsNote = recipe.headsNote`；需要默认说明的配方再填实际内容。

**建议将第 37 行替换为（配合上述修正）：**

> - 组合说明：`HydraPair.headsNote` 可由组合编辑器或 Cookbook 配方提供。非空时写入 lead 策略，同模型和搭档组合都生效；lead 按它分配适合的活。

### D06 — “项目与合并规则渐进披露”不是当前实现

**文档：** 第 38 行“其他项目只列名称与路径，路由细则只在……带 `project` 时……补充”。

**代码：** 多项目时直接拼接完整 `projectRule`（`Tivano/Core/Models/HydraPrompts+V2.swift:26-29`）；该规则本身已经包含项目路由、逐 checkout 合并和 lead 工具行为（`Tivano/Core/Models/Hydra.swift:736-740`）。自动合并开启时，完整 `autoMergeRule` 也直接进入 standing policy，不等到有合并状态；状态说明才由 `mergeStatus` 按需添加（`Tivano/App/Runtime/ThreadRuntime.swift:1838-1842`）。

**若按当前行为修文档，建议替换第 38 行：**

> - 规则披露：自动合并开启时始终给出自动合并规则，已有合并状态时再附 `[Hydra]` 状态说明；多项目时直接给出完整项目路由与逐 checkout 合并规则。当前没有“第一次使用 `project` 后才补充细则”的单独 v2 分支。

如果渐进披露仍是产品要求，则应改代码而不是把这项设计目标删掉。

### D07 — 附件类型写窄了；v2 等的是整个 lead 回合结束，不只是 block 闭合

**文档：** 第 45 行只提“图片附件路径”；第 48 行“派发块闭合后才统一派出……晚几十秒”。

**代码：** packet 保存所有附件路径（`Tivano/App/Runtime/ThreadRuntime.swift:1693-1695`），brief 写为通用 `Attachment paths`（`Tivano/Core/Models/HydraPrompts+V2.swift:77-104`）。v2 跳过流式 reader，在 `finishTurn` 的 `spawnDelegatedHeads` 才派发（`Tivano/App/Runtime/ThreadRuntime.swift:3509,3825-3829,4103-4106`）。没有代码证据支持固定“几十秒”。

**建议替换第 45、48 行：**

> - 用户原话：job 开始时的请求文本（前 6000 字符，截断时注明），以及图片和其他附件的路径。
> - v2 等 lead 的整个回复回合结束后统一派出 heads（v1 仍随条目流式闭合而派发）。因此首个 head 要等完整回复结束，换来同批 brief 都带全队分工；延迟取决于该回合，不预设固定秒数。

### D08 — lead 收到的不是固定三行；lead-review 隐藏和“按需构建”未写清

**文档：** 第 54 行“每个 head 先列三栏……lead 仍亲自完成集成和构建”。

**代码：** `Flags` 只列非空字段，全空才写 `none`，格式缺失时写 `Report format not followed`（`Tivano/Core/Models/HydraPrompts+V2.swift:155-178`）。提示词要求 lead 读 flagged files、抽查其余，并运行“narrowest required build”，不是每次都必须构建（同文件 `41,227-228`）。v2 不读取 `hydraReviewHeads` 的 v1 报告分支，设置项也隐藏（`Tivano/App/Runtime/ThreadRuntime.swift:3714-3716`；`Tivano/App/Views/Settings/HydraSettingsPage.swift:212-220`）。这些是模型指令，不是程序化完成保证。

**建议替换第 54 行并补一条设置说明：**

> - 给 lead 的回报：每个 head 先列 `Flags`（只列非空的三栏，全空写 `none`，未遵守格式则注明），再列落地信息，最后附原始正文。提示词要求 lead 先读偏差和不确定涉及的文件、抽查其余，亲自集成并运行最窄的必要构建；`leadBuilt` 只记录实际观察到的构建调用。
> - v2 不读取 v1 的“要求 lead 审查 heads”开关，该开关在 v2 下隐藏；上述检查指令始终随 v2 回报给出。

### D09 — continuation 的目标状态和副本释放时点不准确

**文档：** 第 58–60 行“已完成的 Tivano head”“副本保留到 job 结束（lead 的最终回复落定或合并开始）”。

**代码：** `isFinished` 包括 completed、failed、stopped（`Tivano/Core/Models/Hydra.swift:331-338,423-428`），continuation 接受这些已结束状态，但拒绝运行中或副本已释放的 head（`Tivano/App/AppModel+Hydra2.swift:105-127`）。自动合并开启时，`await autoMergeHydraWork` 返回后才写 `finishedAt` 并释放副本，不是合并一开始就释放（同文件 `88-93`）。

**建议替换第 58–60 行：**

> - v2 派发条目可写 `"continue": "<head 名>"`，指向本 lead 当前 job 中已结束（完成、失败或停止）的 Tivano head；在原有线程和仍保留的副本中继续，不新起 head。目标不存在、仍运行、不属于本 job 或副本已释放时明确拒绝。
> - 完成 head 的副本保留到 job settle。自动合并开启时，先等 `autoMergeHydraWork` 返回，再定稿并释放；关闭时，在最终回复及审查流程 settle 后释放。落地继续使用增量 `baseTree`，会话恢复失败时按通用路径新开会话并给出警告。

### D06 之后无独立编号遗漏：第 39 行的三轮上限及 continuation 计入同一预算，与 `spawnV2DelegatedHeads` 的整块一次计轮一致（`Tivano/App/Runtime/ThreadRuntime.swift:3884-3894,3950-3953`）。

### D10 — 审查引擎的“默认强模型、高推理、无工具”对 Claude / Codex 并不都成立

**文档：** 第 64 行“用该 CLI 的默认强模型与高推理强度，一次性无工具运行，天然只读”。

**代码：** 引擎选择顺序符合文档（`Tivano/App/AppModel+HydraReview.swift:121-136`）。Codex review 用默认模型并显式 `model_reasoning_effort="high"`，加 `-s read-only`；Claude review 没有指定模型或 effort，只明确 `--tools ""`（`Tivano/Services/Providers/TextGeneration.swift:76-99`）。Codex 的 read-only sandbox 不等于配置层面“无工具”；prompt 虽声明 no tools，但不是同一种强制边界。

**建议替换第 64 行：**

> - v2 的固定审查环节，没有单独开关。lead 是 Claude 时选 Codex；lead 是 Codex 时选 Claude；其他 lead 优先 Claude，再试 Codex。Codex 用其默认模型、高推理和 read-only sandbox；Claude 单次禁用工具，但未显式固定模型或推理强度。两者都是一次性只读调用；不可用、失败或 15 分钟超时时记录原因，不阻塞后续合并。

### D11 — “有落地改动就审整个 job 最终 diff”覆盖过头

**文档：** 第 65–66 行“v2 job 有落地改动……输入只有……本 job 的最终 diff”。

**代码与缺口：**

- 触发还包括 lead 自己触及文件，且自动合并关闭也会审查（`Tivano/App/AppModel+Hydra2.swift:75-89`）。
- shared-checkout head 没有 landing 记录；`hasWork` 只看 `landedFiles` 和 lead turns，可能漏掉其改动（`Tivano/App/AppModel+Hydra2.swift:77-84`；`Tivano/App/AppModel+Hydra.swift:923-936`）。
- 审查只在一个 lead checkout 上运行 Git。其他项目的落地路径先按各自 root 拼接，随后又相对 lead checkout 计算，外部路径会被丢弃（`Tivano/App/AppModel+HydraReview.swift:20-53`）。job 也只有 lead checkout 的一个 `baseCommit`（`Tivano/Core/Models/Hydra2.swift:110-113`）。
- diff 超过 80,000 字符会截断（`Tivano/App/AppModel+HydraReview.swift:83-86`）。notes 只含非空三栏，不是完整 head 正文（同文件 `88-98`）。

**建议代码（正式化前的覆盖缺口）：** 给每个 head 记录本次 job 的 `touchedFiles`，让 shared heads 也进入 `hasWork` 与路径收集；按 checkout 分组保存 base / diff，分别生成带项目标签的 patch，再做统一长度预算。不能用 lead 的 base 和 Git 根冒充整个 job。

**在修复前，建议将第 65–66 行替换为如实限制：**

> - 触发：lead 回合 settle 后，对已观察到的 lead 编辑或 own-copy head 落地改动尝试审查；自动合并开启时位于合并前，关闭时也会尝试。shared-head-only 和多项目改动目前可能没有完整进入审查。
> - prompt 包含用户原话、非空三栏和当前能收集到的 diff；diff 上限 80,000 字符并注明截断。审查不落地、不进入团队面板批次。

### D12 — 审查决策不是程序强制；`pendingReview` 完全缺失

**文档：** 第 67–68 行要求每条采纳或驳回，但没有说明 lead 忙时如何交付。

**代码：** 接受 / 拒绝格式是 prompt 要求（`Tivano/Core/Models/HydraPrompts+V2.swift:280-288`）；账本只数 accepted，不记录 rejected 或漏答（`Tivano/App/Runtime/ThreadRuntime.swift:3751-3759`）。审查完成时 lead 忙，完整消息写入 `pendingReview`，下一次 settle 且 idle 时先交付（`Tivano/App/AppModel+HydraReview.swift:105-118`；`Tivano/App/AppModel+Hydra2.swift:66-74`）。

**建议在第 68 行后新增：**

> - 每条意见的处理格式是提示词要求；账本目前只可靠记录 accepted 数，不把未匹配文本当作明确驳回。
> - 审查运行期间 lead 开始其他工作时，findings 存入 `pendingReview`，不插入正在运行的回合。lead 下一次完成回合并空闲时，先交付这条 `[Hydra] Review`，记录其处理结果，再继续当前 job 的 settle / merge。没有后续完成回合时，它保持待交付，不谎称已送达。

### D13 — 评分账本字段清单和语义已过时

**文档：** 第 72–80 行。

**代码：** `HydraJobRecord` 还保存原始 `request`、共享 heads effort / note、`tilt`、`reviewSkipped`、`pendingReview`（`Tivano/Core/Models/Hydra2.swift:92-127`）；`turnID` 是 lead turn，不是 user timeline item 的 request ID（`Tivano/App/AppModel+Hydra2.swift:21,38-45`）。`leadBuilt` 覆盖整个 job 的 lead turns，`leadEditsAfterReports` 只累计 report / review turns；构建识别是命令子串启发式，编辑识别是完成的 edit tool / 带 edits metadata 的调用（`Tivano/App/Runtime/ThreadRuntime.swift:3731-3759`）。`merge=nil` 还可能是未开启、未走到或 deferred，不等于“无需合并”（`Tivano/Core/Models/Hydra2.swift:86-90,127`）。

**建议将第 72–80 行替换为：**

> lead 线程追加 `hydraJobs`；每个 job 有独立 ID、模式、原始请求文本、lead turn ID、开始 / 结束时间。运行中持续更新，延后审查和合并结果可后补，不宣称 `finishedAt` 后记录绝不再变。
>
> - lead provider / model / effort，pair ID，共享 heads provider / model / effort / `headsNote`，以及本 job 的 `tilt`；
> - lead checkout 的 base commit 和 dirty 标记；
> - 每个 head 的 ID、名字、实际 provider / model / effort、brief 字符数、负责文件、状态、执行秒数、落地文件数、冲突数、三栏、格式遵守情况和 continuation 次数；
> - `leadBuilt`：任一 lead turn 是否观察到构建命令；`leadEditsAfterReports`：report / review turns 中观察到的完成编辑调用。两者都是启发式覆盖，不证明所有构建或文件修改；
> - 审查 engine、findings、accepted、skip reason，以及尚未交付的 `pendingReview`；
> - 最终已记录的 merge 结果。`nil` 只表示没有最终结果，可能未开启、未执行、延后或尚未完成；`nothing` 才是本次判定无需新合并。

### D14 — `compare` / replay 能力写多了；质量与成本没有评估闭环

**文档：** 第 82 行“支持从历史 job 选题，在记录的 base commit 上重跑做同题对比”。

**代码：** `compare` 只做账本 / CSV 汇总；`replay-candidates` 只读 v1 baseline 并写候选 Markdown，不运行 replay 或 Git（`scripts/hydra_eval.py:736-749,752-791`）。v1 没有 base commit，候选说明要求 operator 从原始记录恢复日期再选 commit；v2 的 dirty base 也只有布尔值，没有可复现的未提交快照。第 7 行的质量 > 成本 > 时间顺序本身正确，但账本和 `metric_values` 没有结果质量或成本指标（`scripts/hydra_eval.py:626-644`）。

**建议替换第 82 行并新增评估原则：**

> `scripts/hydra_eval.py compare` 生成运营指标对照；`replay-candidates` 只为 v1 历史任务生成待 owner 审批的候选清单，不执行重跑。v1 需人工恢复原始 base；v2 只有 clean base commit 才能直接作为重跑起点，dirty job 在保存可复现 tree / patch 前不得假装可复现。自动同题 replay 尚未实现。
>
> 现有失败率、冲突、编辑数、时长是运营健康指标，不是结果质量或成本。正式比较按质量 > 成本 > 时间报告：同题、同 base 的人工盲评质量先行；token / 额度 / 价格只在 provider 有对应数据时报告并显示覆盖率，不能估算未知价格；时间最后，并区分 lead 答复、审查和合并阶段。

### D15 — “落地顺序”已是旧计划，且“账本记录各环节”需区分存储与派生

**文档：** 第 84–88 行仍写未来交付顺序；第 88 行说账本逐 job 记下是否只派一个。

**代码：** `single_head` 是评估脚本按 `heads.count == 1` 派生的列，不是 `HydraJobRecord` 字段（`scripts/hydra_eval.py:397,598`）。无头、单头、continuation 和 rounds 可由现有记录派生，审查与采纳是直接字段。

**建议将第 84–88 行替换为：**

> ## 当前状态与评估边界
>
> v2 已在 Labs 落地，后续决策以本文上述当前行为为准。评估时可从 heads 数组派生是否派发、是否单头，从 rounds / continuations 派生派发与返工情况；审查条数、采纳数和跳过原因直接读取账本。无头 job 是 v2 的重要结果，不能在总体效果比较中静默删除或与 v1 有头样本混为一谈。

第 90–94 行其余两项：“不让 heads 互相验证 / 不用审查自动阻塞合并”和“不自动迁移 v1 历史”与当前设计一致；副本条款按 D01 修正。

## 二、`scripts/hydra_eval.py` 与账本数据

### E01 — job 有 4 个存储字段未读；head 的 14 个字段已全部读取

`HydraJobRecord` 共 27 个存储字段，脚本读取 23 个。未读：

- `leadEffort`（`Tivano/Core/Models/Hydra2.swift:102`）；
- `headsEffort`（同文件 `106`）；
- `headsNote`（同文件 `107`）；
- `pendingReview`（同文件 `126`，单独见 E04）。

`HydraJobHeadRecord` 的 `headID/name/provider/model/effort/briefChars/files/status/seconds/landedFiles/conflicts/notes/followedReportFormat/continuations` 均在 `extract_v2` 使用（`scripts/hydra_eval.py:526-579`），没有漏读 head 字段。

**建议代码：** 在 `V2_JOB_FIELDS` 的 `lead_model` 后加 `lead_effort`，在 `heads_model` 后加 `heads_effort, heads_note`，并在 job dict 加：

```python
lead_effort=record.get('leadEffort'),
heads_effort=record.get('headsEffort'),
heads_note=record.get('headsNote'),
```

`heads_note` 属自由文本，继续脱敏；effort 用于分层和成本解释，不应只留在源账本。

### E02 — tilt 存储值映射正确，说明和未知值归组需要修正

脚本正确使用 `restrained` 和 `active`，没有把 UI 的 `Proactive` 错当存储值（`scripts/hydra_eval.py:712-715`；`Tivano/Core/Models/Hydra2.swift:17-20`）。问题是第 709 行把 Restrained 写成“only parallel / heavy reading”，漏掉 substantial self-contained single pieces；非空、非两个合法值的记录不会进入 Restrained / Proactive / Unknown 任一组。

**建议将第 709 行替换为：**

> Restrained also allows a substantial self-contained piece; Proactive prefers self-contained pieces, including single bounded edits. Blank means a record from before the setting; an unrecognised nonblank value is reported separately, never silently treated as either tilt.

分组循环改成显式三分支，并增加 `Unrecognised` 行或计数；只有 `nil` / 空字符串进入 `Unknown (pre-tilt)`。

### E03 — 后加非可选字段会破坏旧 v2 解码，脚本又把“未知”伪造成 0 / false

**代码证据：** `leadEditsAfterReports = 0` 和 `leadBuilt = false` 是非可选存储属性，且 `HydraJobRecord` 没有自定义 decoder（`Tivano/Core/Models/Hydra2.swift:85-130`）。Swift 合成解码不会用属性默认值替代缺失键。`ChatThread` 对整个数组使用 `container.value(.hydraJobs, default: [])`（`Tivano/Core/Models/Library.swift:350-351`；helper 在 `Tivano/Core/Support/Coding.swift:3-7`），所以一个早期 job 缺这些后加键时，会导致该 lead 的整个 `hydraJobs` 解码为空，下一次保存还有覆盖风险。脚本又显式使用 `.get(..., 0)` / `.get(..., False)`（`scripts/hydra_eval.py:607-608`），无法区分旧记录未知和真实零值。

**建议 Swift 代码：** 将后加字段改为可空以表示旧记录未知，新 job 仍显式初始化观察值：

```swift
var leadEditsAfterReports: Int?
var leadBuilt: Bool?
```

`beginHydraJob` 的 job 初始化显式写 `leadEditsAfterReports: 0, leadBuilt: false`；累计改为：

```swift
job.leadEditsAfterReports = (job.leadEditsAfterReports ?? 0) + edits
```

`leadBuilt` 现有 `if built { job.leadBuilt = true }` 可保持不变。若不愿改类型，则必须为整个 `HydraJobRecord` 编写容忍缺键的自定义 decoder；不能只给属性一个默认值。

**建议 Python 代码：**

```python
lead_edits_after_reports=number(record.get('leadEditsAfterReports')),
lead_built=boolean(record.get('leadBuilt')),
```

这样 `built_observed` 和中位数才只覆盖真正记录过的 job。

### E04 — `pendingReview`、进行中 job 和“无改动”被混进审查结果口径

`pendingReview` 非空表示审查引擎已跑完、findings 尚未交给 lead；它会在交付前清空（`Tivano/App/AppModel+HydraReview.swift:105-118`；`Tivano/App/AppModel+Hydra2.swift:68-73`）。当前导出看不到这个状态。`reviewed` 只看 engine，因此把待交付与已处理混在一起；`unrecorded` 又包括尚未 settle 的 job 和根本没有改动的 job（`scripts/hydra_eval.py:670-690`）。无改动时 `settleHydraJob` 不调用审查，也不会写 `reviewSkipped="no changes"`（`Tivano/App/AppModel+Hydra2.swift:83-87`）。

**建议代码：**

- `V2_JOB_FIELDS` 加 `is_open, review_pending_delivery`；job dict 加 `is_open=finish is None, review_pending_delivery=bool(record.get('pendingReview'))`。只导出布尔状态，不导出审查正文。
- “Review ran”改名“Review engine completed”；另报“Review findings pending delivery”和“Open jobs”。
- 审查接受率继续要求 `reviewAccepted != nil`，但明确排除 pending / open；findings-per-reviewed-job 分为“引擎完成”和“已交付处理”两个口径。
- 在 `settleHydraJob` 对 `!hasWork` 且尚无审查结果的 job 写 `reviewSkipped="no changes"`，让“无改动不适用”与“尚未运行”可分。报告把 `no changes` 单列，不算失败 skip。
- 若需区分“审查仍在运行”和“尚未开始”，再补 `reviewStartedAt` 或显式状态枚举；当前字段在旧 job 被新请求提前关闭时不足以可靠区分二者。

### E05 — 无头 v2 与有头 v1 的总体直接比较不公平；采用两个队列，而不是一个滤镜

当前 Overall 和 task-type 表把全部 v2 job（包括 `heads=0`）与 baseline 的有头 job 直接比较（`scripts/hydra_eval.py:647-668`）。这会影响 heads 中位数、单头率、时长、编辑数、审查和合并口径。简单删除无头 v2 也不公平，因为“lead 自己完成”正是 v2 的收益之一。

**建议的 like-for-like 口径：**

1. **Delegated-work 队列（现有数据可做）：** 两边都限 `heads > 0`，按 task type 分层；终态指标要求 v1 `final_reply_observed=true`、v2 `finishedAt != nil && !pendingReview`。每项仍展示自己的 observed denominator。此队列只回答“已经派发时，机械层和 lead 收尾有何差异”。v1 surviving-head 偏差无法靠脚本消除，需明确保留。
2. **Whole-policy 队列（当前基线不能做）：** 重提 v1 baseline，把所有真实 Hydra lead 请求都纳入，包括 `heads=0`；或做同题、同 base replay。v1 / v2 都保留无头任务，才能比较整个策略的结果质量、总成本和总时长。另报 v2 `heads=0` 的数量与比例，但不给它们编造 v1 对照 delta。
3. open / pending job 单独列数，不进入终态结论。模型、effort、pair、tilt、auto-merge 是分层变量，不应混在一个 Overall 数字里。

**建议把 Overall 标题改为：** `Delegated-work operational comparison (not whole-policy effectiveness)`；在 Whole-policy 数据存在前，不输出“v2 总体更好 / 更省”的结论。

### E06 — 没有质量或成本结果指标，不能用运营代理指标替代 owner 优先级

`metric_values` 只有 job 数、head 数、rounds、时长、编辑、失败、冲突、合并（`scripts/hydra_eval.py:634-644`）。没有正确性、需求完整性、返工后验收，也没有 token、额度或价格。baseline 自己还声明不估算 token / cost（同文件 `354`）。

**建议在 `comparison.md` 顶部加入固定说明：**

> These are operational health metrics, not task-quality or cost results. They cannot rank Hydra 2 against the owner's quality > cost > time priority. Use matched same-task replays and blind result review for quality; report provider-observed token/credit/cost only with coverage and units; report time last.

同题 replay 的结果模板至少包含：`quality_score / quality_notes / reviewer_blind`，`lead_tokens / head_tokens / review_tokens`（未知即空），`provider_credit_or_cost / unit / coverage`，以及分阶段时长。不要把 token 数直接命名为美元成本，也不要将 lead 的编辑数当作质量反向指标。

### E07 — `same_model` 按共享 pair 快照，不代表实际 heads；模型快照还可能过早

脚本只用 `leadProvider/leadModel/headsProvider/headsModel`（`scripts/hydra_eval.py:585-588`）。但 profile 可让单个 head 跑不同 provider / model，实际 per-head 记录已在账本中；无头 job 也没有“实际 heads 同模型”可言。另一个定义差异见 D04：代码的 `headsMatchLead` 还看 effort。

快照时机也会留下未知：`beginHydraJob` 在 `ensureModel` 前记录 lead model / effort（`Tivano/App/Runtime/ThreadRuntime.swift:1691-1695,1768`）；跨 provider head 的默认 model 在 `startTivanoHead` 后段才补到 thread（`Tivano/App/AppModel+Hydra.swift:679-685`），job head 记录没有同步更新。

**建议代码：**

- 在 `ensureModel` 后回写 job 的 `leadModel/leadEffort`；head 默认 model 解析后同步对应 `HydraJobHeadRecord.model`。保留原配置值时另用 `configured...` 命名，不把 nil default 当成实际模型。
- `same_model` 用实际 `head_rows`：无头或任一实际 provider / model 缺失为 `None`；所有 head 都与 lead 的 provider + model 相同才为 `True`，任一个不同为 `False`。共享 pair 分组另命名 `pair_same_model`，不要混用。
- effort 只作单独分层；若产品决定 effort 也改变“搭档”类别，必须同时改 D04、代码和脚本，而非只改一处。

### E08 — `base_commit` 被脱敏规则抹掉，dirty base 也不能只靠 commit 重放

`redact` 把任意 40 位以上、看起来像 opaque blob 的字符串替换掉（`scripts/hydra_eval.py:36-38`），`write_rows` 又对每个字符串无差别调用它（同文件 `466-471`）。因此 40 字符 Git SHA 的 `base_commit` 在 `v2_jobs.csv` 中不可用；第 731 行虽承认会误伤 hash，但没有解决 replay 需要它的问题。`baseDirty=true` 时只有布尔值，base commit 不能还原未提交状态。

**建议代码：** 不对结构化字段做自由文本脱敏。最小修法是把 `write_rows` 改为只对明确自由文本列脱敏：

```python
FREE_TEXT_FIELDS = {'request_excerpt', 'heads_note', 'review_skipped_reason'}
writer.writerows({k: redact(v) if k in FREE_TEXT_FIELDS and isinstance(v, str) else v
                  for k, v in row.items()} for row in rows)
```

`base_commit, job_id, head_id, pair_id, turn_id` 等结构化值不在自由文本集合中。replay 候选增加硬条件：只有 `base_commit` 非空且 `base_dirty is False` 才可自动建议；dirty / unknown 单独列出，要求保存 tree / patch 或人工重建，不得默认 current HEAD。

### E09 — `wall_seconds` 名称和 v1/v2 job 时间边界不一致

v2 head 的 `seconds` 是 `executionStartedAt → executionFinishedAt`，不含排队和落地（`Tivano/App/AppModel+Hydra.swift:806-819`）；v1 `wall_seconds` 从 queued / started / created 到 finished。虽然当前表没有直接比较 head 时长，v2 CSV 仍把它叫 `wall_seconds`（`scripts/hydra_eval.py:400-405,565-579`）。

v1 job 时长是 request →  qualifying final reply，v2 是 `startedAt → finishedAt`，后者还包括异家审查及可能的自动合并等待（同文件 `297-309,599-600,723-725`）。直接并排“Median job wall seconds”会把新增阶段算成 v2 变慢，边界不同。v1 rework 从首个 head finished 开始，v2 从首个交付的 report turn 开始，也不是同一起点。

**建议代码与口径：**

- v2 head CSV 将 `wall_seconds` 改为 `execution_seconds`；不要把 v1 wall 与 v2 execution 作同名列比较。
- job 增加 `leadFinishedAt`：最后 lead 工作回合完成、开始审查前写入。v1 已有 qualifying final reply 时间，可与 v2 `leadFinishedAt - startedAt` 比较。`reviewFinishedAt` / `mergeFinishedAt` / `finishedAt` 另报阶段时间。
- 在统一字段存在前，从 v1-v2 对照表移除“Median job wall seconds”，只在各版本内部展示，不伪装成同指标。
- 将 v1 rework 起点改为首个实际交付给 lead 的 report message，或给 v2 记录首个 head finish 对应编辑段；review 修复编辑单独统计。未对齐前不把两个数放在同一“lead rework edits”比较行。

### E10 — 格式解析失败被误记为“没有任何 flags”

`notes` 不是 dict 时，只要 `followedReportFormat` 非空，脚本就设 `flags=False`（`scripts/hydra_eval.py:556-564`）。但 `followed=False` 恰恰表示三栏解析失败，原始正文里仍可能有偏差或不确定性；这不是“确认无 flags”。

**建议代码：**

```python
flags = (any(notes.get(field) is not None
             for field in ('deviations', 'unfinished', 'uncertain'))
         if isinstance(notes, dict) else None)
```

只有实际存在 `HydraReportNotes`（包括三栏全空的 `{}`）才进入 flags observed denominator；同步删掉第 729 行“有 report-format result 就能确定 flags”的说法，改为“只有 notes 存在时可判定”。

### E11 — 合并成功率混合了首次 / 最终、尝试 / 无操作和开关状态

v1 baseline 要求一次窗口内所有 outcomes 都是 merged / settled，早期失败后最终成功也算失败（`scripts/hydra_eval.py:286-309`）；v2 只有一个可覆盖的 `merge` 最终值，并将 `nothing` 与 `merged` 都算成功（同文件 `582-584,632-643`）。这不是同一指标。`nothing` / `settled` 还应与真正远端 merge 分开；`merge=nil` 也不能区分 auto-merge off、deferred 和未完成。

**建议代码与口径：**

- 统一比较“最终远端 merge 结果”：v1 取按时间排序后的最后一个明确 outcome，v2 取最终 `merge`；若要比较首次成功率，则 v2 也必须记录 attempts，不能用最终值反推。
- `merged` 与 `failed` 进入远端 merge success；`nothing` / `settled` 单列“无需新合并”，不抬高成功率。
- 在 settle 调用 auto-merge 前记录 `mergeAttempted=true`，并保留 auto-merge 设置快照。`mergeAttempted=false` 是未请求；`true + merge=nil` 是 deferred / 未知。只有定义一致的已观察 job 进入分母。

### E12 — 合并结果按“最后一个 v2 job”写入，可能串到下一请求

`recordHydraJobMerge` 不接收 job ID，而是写 `thread.hydraJobs.last`（`Tivano/App/AppModel+HydraMerge.swift:1148-1150`）。延迟 merge / recovery 与下一 job 重叠时，这个结果不一定属于实际合并的请求；评估再精确也无法修复错误归属。

**建议代码：** 从 `settleHydraJob` 把当前 `job.id` 传入 `autoMergeHydraWork`，再传入所有 `recordHydraJobMerge` 调用，按 ID 更新并确认仍属同一 lead。recovery 也必须先恢复 owning job ID，不能默认最后一个；无法确认归属时保留 merge 历史但不写任一 job 的评分字段。

## 三、其他 docs、README、AGENTS 与更新日志

### O01 — 旧设置审计需要标明 v1 范围

`docs/research/audit-2026-10-21-settings-and-stack.md:63-75` 的 A16–A22 仍讨论两个消息开关、lead-review 开关和旧自动合并文案。它是 2026-10-21 的历史审计，不应逐条伪装成当时错误；但当前读者需要知道这些不是 v2 控件。v2 的替代关系见 `Tivano/App/Views/Settings/HydraSettingsPage.swift:184-220`。

**建议在该文件 `### Hydra` 标题下加入：**

> 范围说明（2026-10-26 补记）：以下 A16–A22 记录 Hydra 1 当时的状态与文案建议。Hydra 2 下，两个消息路由开关由 Restrained / Proactive tilt 替代，所有消息先给 lead；lead-review 开关隐藏；自动合并行现名“Commit and merge automatically when done”。不要把这些历史条目当成 v2 当前设置清单。

### O02 — DSH 的 Hydra 验收证据是 v1，当前验收计划缺少 v2 场景

`docs/dsh-runtime-contracts.md:32` 和 `docs/dsh-validation.md:60-67` 所述模拟 ACP Hydra 证据来自 `DshHydraIntegrationProbe`，其 fixture 明确叫 `tivano-dsh-offline-hydra-v1`（`Tivano/App/Captures/DshHydraIntegrationProbe.swift:8`）。探针断言两个 lead turns 和完成后副本释放（同文件 `161-169`），这些是 v1 期望；v2 的副本保留、结构化回报和审查流程不同。`docs/dsh-acceptance-plan.md:28` 只写通用 Hydra scheduling，没有区分版本。

**建议在 `dsh-runtime-contracts.md:32` 的“App probe”后加“（Hydra 1）”，并在 `dsh-acceptance-plan.md:28` 后新增：**

> 现有 simulated-ACP App Hydra 证据仅覆盖 v1，不覆盖 Hydra 2。v2 需另行固定 `alphaEnabled && alphaHydra2Enabled`，覆盖 lead 无头完成、两种 tilt、`files` / 团队交接包、三栏回报、continuation、整回合后派发、异家审查不可用 / 无 findings / 有 findings，以及 lead 忙时 `pendingReview` 的延迟交付；不得复用 v1 的“两回合 + 立即释放副本”断言作为 v2 通过证据。

### O03 — `[Unreleased]` 把 lead 检查和异家审查写成了无条件事实

`CHANGELOG.md:15,25` 的“the lead always checks … and another vendor reviews it / 主智能体总会……并由另一家……审查”过强。lead 检查是提示词要求；异家审查受改动可见性、CLI 可用性、调用成功和 diff 范围限制（`Tivano/App/AppModel+Hydra2.swift:83-86`；`Tivano/App/AppModel+HydraReview.swift:17-18,29-53,99-115`）。

**建议英文替换为：**

> - With Hydra 2.0 on, Settings › Hydra no longer shows Ask the lead to review heads' changes: v2 always asks the lead to inspect flagged files and spot-check the rest, and tries a one-shot cross-vendor review when it finds reviewable changes and another vendor's CLI is available. Review skips and failures are recorded and do not block merging. The automatic merge switch is now Commit and merge automatically when done, and says what happens with it off and on.

**建议中文替换为：**

> - 开启 Hydra 2.0 后，设置 › Hydra 不再显示“要求主智能体审查子智能体的改动”：v2 总会要求主智能体先读标记文件并抽查其余改动；发现可审查的改动且另一家有可用 CLI 时，还会尝试一次异家只读审查。审查不可用或失败会记录原因，不阻塞合并。自动合并开关改名为“完成后自动提交并合并”，并说明关闭和开启时分别会发生什么。

### O04 — `[2.1.8]` 的“下一轮结束”应限定为完成且空闲的 settle

`CHANGELOG.md:48,65` 说 findings 在 lead 下一轮结束时送达。实际只在下一次完成回合后的 settle 且 runtime idle 时交付；停止 / 失败回合不满足 settle 条件，尚未有后续回合时仍是 pending（`Tivano/App/Runtime/ThreadRuntime.swift:3548-3554`；`Tivano/App/AppModel+Hydra2.swift:68-73`）。

**建议英文句替换为：**

> Hydra 2.0's review is no longer lost when the lead is busy as it finishes: its findings are saved and delivered once the lead is idle after its next completed turn.

**建议中文句替换为：**

> Hydra 2.0 的审查结果不再因审查完成时主智能体正忙而丢失：结果会先保存，在主智能体下一轮完成并空闲后送达。

该条目关于 `reviewAccepted`、`leadBuilt`、`leadEditsAfterReports` 现在会记录的说法适用于新记录；旧记录兼容问题仍需按 E03 修复，不能据此宣称旧数据都完整可读。

### O05 — `[2.1.0]` 的“verbatim”和无条件异家审查需要加边界

`CHANGELOG.md:97,113` 说每个 head 都获得“your request verbatim / 你的原话”，但 brief 只放前 6000 字符并附截断说明（`Tivano/Core/Models/HydraPrompts+V2.swift:77-100`）；“another vendor reviews the changes before they merge / 改动合入前由另一家……审查”也未说明可用性、失败跳过和 diff 范围。

**建议英文相关分句替换为：**

> each head gets your request text (up to 6,000 characters, with a truncation notice) and the batch's file split, reports its deviations and open points, and can be sent back to rework its part. When reviewable changes are found and another vendor's CLI is available, Tivano tries a one-shot read-only review before optional automatic merging; unavailable or failed reviews are recorded and do not block merging.

**建议中文相关分句替换为：**

> 每个 head 会收到你的请求文本（最多 6000 字符，截断时注明）和本批文件分工，汇报偏差和待决问题，也可以被要求返工自己负责的部分；发现可审查的改动且另一家有可用 CLI 时，会在可选自动合并前尝试一次异家只读审查，审查不可用或失败会记录原因，不阻塞合并。

`[2.1.8]` tilt 条目的 Restrained / Proactive 描述与当前提示词基本一致，raw value 也正确；无需把 `active` 改成 `proactive`。

### 未发现需要因 v2 改写的其他文档

`README.md:32` / `README.zh-CN.md:32` 是 Hydra 能力概览，未声称 v2 一定派头或一定审查；`AGENTS.md` 的 head 不验证、lead 验证、worktree 与合并规则仍符合 v2 head prompt。`docs/anti-slop.md`、`docs/local-control.md`、`docs/shared-library.md`、`docs/public-release.md`、性能 / DSH 历史记录和 `docs/research/hydra2-code-map-2026-10-26.md` 都有各自历史范围，未发现 v2 新造成的事实错误。代码地图已明确“提案不是已实现行为”，不应当作当前参考文档重写；若继续引用其行号，应重新生成地图而不是逐行补丁。

## 四、捕获与探针

### C01 — 产品 Hydra mock 是 v1 形态；当前不会冒充 v2，但应显式固定并补 v2 场景

`ProductCaptures+Hydra.swift:22-135` 的 head 没有 `mode/jobID/reportNotes`，delegation JSON 没有 `files`，回报也没有三栏；这是合法 v1 历史场景。标准 capture 会清空 isolated defaults，而 Labs / Hydra 2 默认关闭，且没有 capture 显式开启 v2，所以当前不存在“默认把这张 v1 图当 v2 图展示”的事实。`WebsiteCaptures.swift:113-119` 关闭两个 v1 路由开关，在 v2 默认关闭时足以保证 queue scene 不派头。

**建议代码：**

- 在 `WebsiteCaptures.prepare` 的 isolated defaults 重置后显式写 `alphaHydra2Enabled=false`（需要整个 Labs 状态明确时也写 `alphaEnabled=false`），把现有产品图的 v1 意图固定下来，避免未来改默认值悄悄改变场景。
- 新增独立 v2 fixture，而不是给现有图硬塞三行：lead 带 `hydraJobs`，head 带 `.v2`、匹配 `jobID`、结构化 notes 和 `files` 分工；分别覆盖无头 lead、工作 heads、待交付 `pendingReview` 的空态 / 加载 / 错误状态。截图命名和说明标明 `hydra-v1` / `hydra-v2`，不共用含糊的 `capture-hydra` 作为两版证据。

### C02 — DSH v1 探针当前安全，但 v1-only 设置与断言应显式锁版

`DshHydraIntegrationProbe.swift:56-64` 清空 defaults，设置 `hydraQueueHeads/hydraAlwaysHeads/hydraReviewHeads` 等 v1-only 键；由于 v2 默认关闭，它目前确实跑 v1，不是错误的 v2 探针。问题在于模式只靠默认值隐式成立，而 fixture 名称和成功断言已经明确依赖 v1（同文件 `8,161-169`）。

**建议代码：** 在 `defaults.removePersistentDomain` 后显式加入：

```swift
defaults.set(false, forKey: "alphaHydra2Enabled")
```

若 probe 不测试 Labs 总开关，再同时显式 `alphaEnabled=false`。保留现有 v1-only 设置，因为它们对固定 v1 路径有意义；不要用开启 v2 来“更新”这个探针。另建 v2 probe，并按 O02 的新场景写独立断言，尤其不能要求 v2 completed head 的 copy 已释放或 lead 恰好两个 turns。

## 建议实施顺序

1. 先修 E03 的旧账本解码和未知值语义，再修 E12 的 job 归属，避免继续产生不可评估数据。
2. 回写 D01–D15，并同步 O03–O05 的用户可见承诺；D11 的 shared / 多项目审查覆盖在正式化前应作为功能缺口处理，而不只是文档脚注。
3. 按 E01、E04、E07–E10 修导出和指标定义，再按 E05 分队列、按 E06 建同题质量 / 成本评估；旧 Overall 数字不得用作 v2 转正依据。
4. 最后固定 C01 / C02 的 v1 意图并补独立 v2 场景。所有代码与脚本修改及真实比较仍由 lead 在其 checkout 构建、运行和验收。
