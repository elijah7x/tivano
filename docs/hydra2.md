# Hydra 2.0（实验室）设计

状态：Labs 已实现（2026-10-26）。本文描述当前设计；依据包括 `docs/research/hydra2-code-map-2026-10-26.md`、`docs/research/hydra2-audit/docs-data.md` 和 Hydra 1 基线（`scripts/hydra_eval.py baseline`，输出在仓库外 `private-artifacts/hydra-eval/2026-10-26-hydra1-baseline/`）。

## 目标与边界

- 取舍顺序：质量 > 成本 > 时间。先保证结果更好，再尽量保住组合带来的成本优势；为这两者多花的时间可以接受。
- Hydra 2 替换派发决策、交接、回报、返工和审查流程，并改变完成 head 的副本保留时机；副本创建、增量落地、合并和 watchdog 的底层算法继续复用。
- Labs 的 Hydra 2.0 开关默认关闭，受 Labs 总开关约束；没有各环节独立开关。Settings › Hydra 提供 `Delegation tilt`（`Restrained` / `Proactive`）；v1 的两个消息路由开关与 lead-review 开关在 v2 下隐藏且不生效，合并开关为 `Commit and merge automatically when done`（完成后自动提交并合并）。head profile 编辑入口保留在 Settings，规则可见、可编辑。
- 缺少 `mode` 的旧 head 按 v1 解读；早期 v2 记录缺少的新字段表示未知，不把未知改写为 v1、零或 false。

## 基线说明了什么

Release 库的历史基线包含 232 个派发 job、525 个 head（当时 Dev 库无 Hydra 记录）：

- head 失败或停止 2.9%，落地冲突 0.4%，描述的是机械层健康，不是任务质量。
- 99 个 job（43%）只派了 1 个 head。单 head 没有并行收益，但可能有上下文隔离、模型适配与成本收益；不能只凭数量判定应收回 lead。
- 135 个 job 由 Claude 领队，heads 以 Codex 为主，跨厂商交接是常见路径。
- brief 中位数约 4400 字符（含固定规则），回报中位数约 420 字符；交接需保留足够信息，回报需暴露偏差与未完成项。
- v1 缺少逐 job 的原始 base、模式、组合快照及可靠合并归属，且仅保留有存活 head 的请求。它可作运营代理指标基线，不能代表整个策略的效果。

## 1. 模式按 job 盖章

- 开着 Hydra 的新 job 读取一次 `alphaEnabled && alphaHydra2Enabled`，盖章 `.v1` / `.v2`，同时快照 tilt。模式随 launch、会话签名、brief、回报与合并传递；中途改 Labs 或 tilt 只影响下一 job，不混用路由与策略。
- v2 下所有用户消息先进入 lead。job 尚未结束时发来的消息属于同一 job，追加到交给 heads 的用户请求中；只有 settle 之后的新消息才开启新 job。忙时的追加仍由 lead 统筹，不直接送给某个 head。
- 语音通话与文字请求采用同一套 v2 job、派发、交接、预算及收尾规则。
- v1 queued/direct-head 路径只用于盖章为 v1 的 job。模式变化后的会话按新签名重建。

## 2. 派发策略：按上下文与 tilt 分工

lead 先计划，保留需要边读边判断的工作、跨文件设计、集成与最终检查；能写成自足 brief 的工作按以下倾向分配，计划可随回报修改：

- **Restrained（存储值 `restrained`）：** 为并行、大量阅读和较大的独立单项工作派发；单项可包括跨文件机械修改。小编辑和需要边读边判断的工作留给 lead。
- **Proactive（存储值 `active`）：** 更优先使用 heads，独立单项、边界清楚的编辑和阅读都可派发；大工作拆成独立并行部分。琐碎或质量敏感、由 lead 做更好的工作仍留给 lead，不为增加派发而拆散耦合工作。
- 两种倾向都适用于同模型和搭档组合。共享 heads 的 provider + model 与 lead 相同时称为同模型，effort 单独记录；profile 可覆盖单个 head 的实际配置，评估另看实际 heads。
- `HydraPair.headsNote` 可由组合编辑器或 Cookbook 配方提供；非空时写入 lead 策略，同模型与搭档组合都生效。
- 自动合并开启时始终给出自动合并规则，有合并状态时再附 `[Hydra]` 状态说明；多项目时直接给出完整路由与逐 checkout 合并规则。
- 每个 job 最多 3 轮派发，整批计一次；`continue` 返工与新派发共用预算，追加用户消息不重置预算。

## 3. 交接包

每个 head 的 brief 后由 Tivano 附加（不经 `withoutVerificationSteps` 处理）：

- 用户请求：job 的初始原话及尚未结束时的追加，最多 6000 字符，截断时注明；同时附图片和其他附件路径。
- 团队清单：本批各 head 的名字、任务标题和负责文件。
- 派发条目的 `files` 表示负责路径；同一路径分给两个条目时，派发前拒绝该块并向 lead 说明，让 lead 重拆。
- v2 等 lead 整个回复回合结束后统一派出 heads，使同批 brief 带有完整团队分工。v1 仍流式派发；v2 首个 head 的等待时间取决于完整回合，不预设秒数。

## 4. 结构化回报

- head 先写一两句结果，最后固定三行 `Deviations:`、`Unfinished:`、`Uncertain:`，空项写 `none`。文件改动由 Tivano 记录，不要求重复列出。
- 解析宽松：缺少格式时保留原文，并记录未遵守格式。解析结果进入 `reportNotes`，`summary` 保持原样；解析失败不能视为“没有问题”。
- 给 lead 的回报先列 `Flags`（只列非空项，全空写 `none`，缺格式则注明），再列落地信息及原始正文。提示词要求先读偏差和不确定涉及的文件、抽查其余，亲自集成并运行最窄的必要构建。这是模型指令，不是程序化验收保证。
- 上述要求始终随 v2 回报提供，不受隐藏的 v1 lead-review 开关控制；heads 不构建、不检查，由 lead 验证。

## 5. 返工续用原 head

- 派发条目可写 `"continue": "<head 名>"`，指向当前 lead、当前 job 中已结束（完成、失败或停止）的 head；使用原线程和仍保留的副本，不新起 head。目标不存在、仍运行、不属本 job 或副本已释放时明确拒绝。
- head 属于未结束的 v2 job 时，只能通过 lead 的 `continue` 指挥。它自己的输入框提示 `Ask the lead to send this head back`（通过主智能体让它返工）；job 结束后恢复直接发消息的原有行为。
- 完成 head 的副本保留到 job settle；自动合并开启时等合并调用返回后再定稿、释放，关闭时等最终回复与审查处理结束。落地继续使用增量 `baseTree`；会话恢复失败时走通用新会话路径并给出警告。

## 6. 异家只读检查

- v2 的固定环节，没有单独开关。Claude lead 用 Codex，Codex lead 用 Claude，其他 lead 优先 Claude、再试 Codex。Codex 使用默认模型、高推理和 read-only sandbox；Claude 单次禁用工具，未显式固定模型或推理强度。不可用、失败或 15 分钟超时记录原因，继续后续收尾。
- lead 工作回合结束后，对 job 的改动尝试审查，自动合并开启时先审后合；关闭自动合并也审查。无改动记录为不适用，不算审查失败。
- job 为每个 checkout 保存 `baseTrees`，按各 checkout 自己的 base tree、只对本 job 触及的路径生成 diff。范围包含 lead、共享 checkout 的 heads 以及其他 checkout 的 heads；不能用 lead 的根目录与 base 代替全部项目，也不能把无关路径带入审查。
- 输入为用户请求、非空三栏和带 checkout 标识的 diff，总 diff 预算 80,000 字符，截断须注明；审查不落地、不进入团队面板批次。base 缺失或 diff 收集失败须说明覆盖限制，不宣称审过完整代码。
- 只报告会导致错误行为的问题，每条包含文件位置和失败情形；lead 须明确采纳修改或驳回说明。账本记录 findings 与匹配到的 accepted 数，不把无法匹配的文本算作明确驳回，也不以零 findings 保证正确。
- 审查作为 `[Hydra] Review` 交给 lead 处理。lead 忙时把完整消息留在 `pendingReview`，待空闲后交付；job 在交付并处理之前不关闭。等待期间的新用户消息仍属于这个 job。审查调用失败可以收尾，已产生但尚未交付的意见不能当作失败或跳过而丢弃。

## 7. 评分账本

lead 线程追加 `hydraJobs: [HydraJobRecord]`，运行中持续更新；延后合并的结果按所属 job ID 回写，不能默认写入最后一个 job：

- 独立 job ID、mode、原始请求、lead `turnID`（不是用户消息 ID）、开始与结束时间；`ending` 为 `completed` / `interrupted` / `hydraOff` / `recovered`，区分正常完成、中断、关闭 Hydra 和恢复收尾。
- lead provider / model / effort，pair ID，共享 heads provider / model / effort / `headsNote`，job 的 tilt 快照。
- lead checkout 的 base commit、dirty 标记及按 checkout 保存的 `baseTrees`。tree 是审查基线，不等于完整可重放环境。
- 每个 head 的 ID、名字、实际 provider / model / effort、brief 字符数、负责路径、状态、执行秒数（不含排队和落地）、落地文件与冲突数、三栏、格式遵守和 continuation 次数。
- `leadBuilt` 记录任一 lead turn 观察到的构建命令；`leadEditsAfterReports` 累计 report / review turns 的完成编辑调用。两者均为启发式，不能证明所有构建或修改。
- 审查 engine、findings、accepted、skip reason 和待交付 `pendingReview`。缺字段是未知，不能以 engine 存在证明意见已交付处理。
- 所属 job 的最终 merge 结果；`merged` / `failed` 是远端合并结果，`nothing` 是本次无需新合并。缺结果可能是未开启、未执行、延后或尚未完成，不算成功。

`scripts/hydra_eval.py compare` 只读账本与 baseline CSV，生成运营指标：主表比较 v1 有头任务和 v2 至少派发一个 head 的任务，按任务类型分层；终态指标排除进行中及待交付审查。v2 无头任务另表展示，并报告委派率，不编造 v1 无头对照。实际 heads 的同模型分组与共享 pair 快照分开，effort、pair、tilt 均保留。审查分已交付、待交付、跳过、失败及未知；不把不同边界的时长和编辑数作为同一指标比较。

`replay-candidates` 只生成待 owner 审批的 v1 候选清单，不执行 Git 或重跑。v1 需人工恢复原始日期与 base；v2 clean base commit 可作起点，dirty / 未知基线仍须保存并恢复相应 tree / patch 及环境，不能默认当前 HEAD。自动同题 replay 尚未实现。

评估按质量 > 成本 > 时间：同题、同 base 的人工盲评质量先行；provider 实测 token / 额度 / 成本须带单位和覆盖率，未知不估价；时间最后，分清 lead 答复、审查与合并阶段。现有失败率、冲突、编辑数和耗时只表示运营健康，不能替代质量与成本结果。

## 当前状态与评估边界

v2 已在 Labs 作为完整流程提供。无头、单头由 heads 数组派生，轮数与返工由 rounds / continuations 汇总；审查与采纳直接读取账本。缺字段的旧记录保留未知，不能用零补齐后得出改善结论。

v1 基线存在存活 head、时间归属及不同请求的偏差。要比较整个策略，需补齐两版全部真实请求（包括无头），或采用同题、同 base 重跑；主表仅回答派发之后的运营差异。pending / open 数量另报，终态尚未形成时不提前下结论。

## 不做的事

- 不重写副本创建、增量落地、合并和 watchdog 的底层算法；v2 的保留与释放时机遵循 job 生命周期。
- 不让 heads 互相验证，不用审查意见自动否决合并；lead 负责判断和处理，待交付意见必须等待。
- 不自动迁移或改写 v1 历史，不把运营代理指标称为质量或成本证明。
