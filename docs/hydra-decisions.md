# Hydra 决策点（实验室）设计

状态：首批（影子模式）已实现（2026-10-28），Debug 构建通过、已打包 Dev。历史回放结果见下文"历史回放"一节。

2026-11-05 起题目版本按点位递增（`HydraDecisionRequests.questionVersion(point)`）。`headReport`、`preReview`、`reviewDisposition` 仍为 `qv=2`，本轮冻结题目与 state，保持 `reworkLikely`、`defectLikely` 样本连续；新点位从 1 开始。账本缺省 `qv` 视为 1，评估按（点位，qv）分组，不同版本不合并。

## 目标与边界

- 回答一个问题：决策模型（TypeSafe Jev）在 Hydra 2 的具体环节上，是否比现有确定性启发式判断得更准。答案要来自本机生产数据，不来自榜单或厂商自测。
- 首批**只做影子模式**：只调用、只记账，不改变 Hydra 的任何行为，也不把判断展示给 lead。lead 看不到判断，结果标签才不会被污染。
- 只支持 TypeSafe 官方接口 `POST https://api.typesafe.ai/v1/systemone`、模型别名 `jev-latest`。不做网关、备用通道或 OpenAI Decisions。
- 只加不减：以后进入提示阶段时，决策模型也只能增加检查或提示，不能跳过审查、构建，不能否决合并。因此关掉它或调用失败都等于今天的 Hydra 2.0。
- 只在 Hydra job 上运行。单模型对话不接入。

## 开关与配置

- Settings › Alpha › Hydra 卡片提供 `Decision model (Jev)` 开关和 `TypeSafe API key` 输入框；默认关闭，只受 Alpha 总开关与自身开关约束（`settings.isDecisionsEnabled = alphaEnabled && alphaDecisionsEnabled`）。
- key 存在本版本的 Keychain service（Release 为 `Tivano`，Dev 为 `Tivano Dev`），account 为 `TypeSafe API Key`，与 provider key 的存法一致；不读环境变量，不写 UserDefaults。Dev 与 Release 各配各的 key。
- 按 job 盖章：`beginHydraJob` 时把 `isDecisionsEnabled` 写入 `HydraJobRecord.decisions`。中途打开只影响下一个 job；中途关闭后，后台任务在读取 Keychain 和发送前复查当前开关与 job 盖章，不满足则退出、不写决策账本；已发出的请求不追回。
- capture run 不运行任何决策点（Keychain 不可读，存储根目录也是 capture 的）。

## 本轮测量原则（2026-11-05）

前两轮标签只记录 lead 自己的动作（续派、审查有意见），预测 lead 已会做的事价值有限。Jev 的价值应体现在 lead 漏掉、事后才暴露的问题，以及可节省的成本（如低风险 job 跳过审查）；后者本轮只测算，不改变现有审查规则。因此本轮改标签不改题，新增三个只写账本的测量点。H3 一类的文本分类已证明可靠：qv2 与正则一致 42/43，唯一分歧是正则不认中文“接受”。

## 点位

每个点位由 Tivano 用代码从可观察事实组装 state，不使用被评判 agent 自己写的摘要。字符上限按 `prefix` 截断并在末尾加 `[truncated]`。H1–H3 的英文题目是发给 Jev 的原文，实现照抄；新测量点以下列题意和选项说明。

### H1 `headReport`：head 回报一致性

时机：v2 head 以 `completed` 结束、`finishHydraHead` 把三栏写进 job 之后。失败或停止的 head 不调用。

state：

| 字段 | 内容 |
|---|---|
| `task` | lead 给这个 head 的任务标题 |
| `ownedFiles` | 派发条目的 `files` |
| `landedFiles` | 已落地到 lead checkout 的路径（没落地为空） |
| `conflicts` | 落地冲突数 |
| `report` | head 最后一条回复，≤ 6000 字符 |
| `notes` | `{deviations, unfinished, uncertain}`，空项为 null；没写三栏时整体为 null |
| `followedReportFormat` | 是否写了三栏 |

第二版删除了 `gapUnreported` 与 `completion`：生产数据（2026-10-29 至 11-01）上，`gapUnreported` AUROC 约 0.52–0.59，且高分 15 条中 10 条误报，`completion` 低于启发式；`reworkLikely` 对「之后被续派」比最佳启发式高 0.137（job 聚类 95% 区间 0.04–0.23，前后两半一致），保留原文。

题目：

- `reworkLikely`（noul）："Will the lead most likely have to send this agent back to rework its part, judging by the report, the files it owned and the files that landed?"

结果标签：本轮改用 `rework_after`、`head_missed_defect`、`correction`（定义见评估）；原 `continued_after`（同一 head 之后还有一条 `headReport` 判断）保留作历史对照。启发式基线：`notes.flagsSomething`、`followedReportFormat == false`。

### H2 `preReview`：审前风险

时机：`reviewHydraJob` 已收集到非空 diff、并选定了异家审查引擎之后，审查调用之前。与审查并行，不等待。没有 diff 或没有可用审查引擎时不调用（没有标签）。

state：

| 字段 | 内容 |
|---|---|
| `request` | job 的用户请求，≤ 4000 字符 |
| `leadReply` | lead 本 job 最后一条回复，≤ 4000 字符 |
| `headFlags` | 每个有非空三栏的 head 一行：`名字: Deviations … / Unfinished … / Uncertain …`，每行 ≤ 500 字符 |
| `heads` | 本 job 的 head 数 |
| `leadBuilt`、`leadEditsAfterReports` | 取自 job 账本 |
| `files` | `[{path, added, deleted}]`，按增删行数降序最多 40 项 |
| `filesTotal`、`linesAdded`、`linesDeleted` | 全部改动文件的合计 |

文件统计从审查用的 patch（截断前）里数出来，不发送 diff 内容。job 触及多个 checkout 时，`path` 前缀该 checkout 的文件夹名。

题目：

- `defectLikely`（noul）："The state summarises a finished multi-agent coding job just before an independent code review: the user's request, the lead's final reply, open points the agents flagged, whether a build ran, and line counts per changed file (no source). Will the review find at least one defect that would make the software behave wrongly? Judge the summary only; this is not a verdict on the code."
- `unrelatedChanges`（noul）："The state summarises a finished multi-agent coding job just before an independent code review: the user's request, the lead's final reply, open points the agents flagged, and the changed files with line counts (no source). The review will see every changed file in the checkout. Does the changed-file list include files that neither the request nor the lead's reply gives any reason to touch, so the review is likely to see changes that do not belong to this job? Judge the summary only."

`unrelatedChanges` 用于观察审查对象归属：生产案例中部分「审查有意见」来自不属于本 job 的改动。本轮暂停与 `findings_any` 比较，只对 `outside_any` 评估；保留提问一轮正是为了等这个标签。

结果：审查返回后追加一条 `outcome` 记录，含 findings 数和被意见提到的改动文件（意见文本包含相对路径；或者文件名在改动文件中唯一且出现在意见里）。另外以 job 账本的 `reviewAccepted > 0` 为辅助标签。启发式基线：总增删行数、`filesTotal`、`headFlags` 条数、`!leadBuilt`。首批还有一道 `riskiestFile`（最可能出错的文件），回放中命中率不如"改动最多的文件"，已删除。

### H3 `reviewDisposition`：审查处置标注（只用于测量）

时机：lead 处理 `[Hydra] Review` 的回合结束、`recordHydraLedger(kind: .review)` 时。job 的 `reviewFindings` 为 0 或未知时不调用。

state：`review`（lead 收到的审查消息，≤ 8000 字符）、`leadReply`（lead 该回合回复，≤ 4000 字符）。

题目：`finding_1`…`finding_n`（n = min(reviewFindings, 8)），每题都是 choice：

- 题干："The state holds an independent review's numbered findings and the lead's reply to them. How did the reply deal with Finding k?"（k 为题号）
  - `accepted`: "Says it changed or fixed something for this finding."
  - `rejected`: "Argues the finding is wrong or not worth a change, and leaves it."
  - `unaddressed`: "Does not clearly respond to this finding."

用途：和现有正则计数（`Finding N: accepted`）对照，减少 `reviewAccepted` 的未知；靠人工抽样核对，不作为提示候选。回放验证后决定两者并存：job 账本的 `reviewAccepted` 仍是正则计数，Jev 的处置只写决策账本，评估以 Jev 为准；不让 Hydra 账本依赖外部服务。

### `continuation`：续派原因（只用于测量）

时机：lead 续派 head 时，含把早先请求的 head 换人重派；重派在本地记 `meta.via=redispatch`。

state：head 原任务、上次回报、新 brief。

题目：`reason`（choice），判断这次续派的原因：

- `fix`：修复原任务结果中的错误。
- `omission`：补上原任务遗漏的工作。
- `extension`：追加原任务之外的工作。
- `investigation`：继续调查或深挖问题。
- `retry`：因失败或中断而重试。

`rework` = `fix` 或 `omission`，用来清洗 H1 标签；第三轮抽样中低分续派多为追加或深挖，不能一律算返工。

### `reviewFindings`：审查意见归属（只用于测量）

时机：审查返回且有意见时、lead 回复之前。

state：用户请求、改动文件与增删行数、逐条意见文本。

题目：每条意见一题（choice），最多 8 条，判断它与本 job 的关系：

- `inJobDefect`：本 job 内会使软件行为出错的缺陷。
- `inJobOther`：属于本 job，但不是行为缺陷。
- `outsideJob`：不属于本 job。
- `unclear`：信息不足，无法判断。

本地 `meta.findingPaths` 记录每条意见提到的改动文件，不发送，用于把被接受的本 job 缺陷关联到 head 落地文件。

### `followUp`：用户后续反馈（只用于测量）

时机：用户在有 head 或有审查的 job 之后发下一条消息时；同一 job 内的追问也算，在本地记 `meta.sameJob`。

state：先前请求、lead 最后回复、用户新消息。

题目：`followUp`（choice），判断新消息与先前结果的关系：

- `correction`：要求纠正先前结果，结果没让用户满意。
- `nextStep`：在先前结果上继续下一步。
- `newTopic`：开始无关的新话题。
- `unclear`：信息不足，无法判断。

`correction` 是“结果没让用户满意”的最接近真值的信号。三个新点位都只写账本，不提示 lead，不改变 Hydra；数据外发仍限于设置说明已列出的请求、回报、lead 回复、审查意见和文件统计。

## 调用与失败

- 每次调用一个请求、不重试，总超时 8 秒；调用放在 detached task 里，不阻塞 head 回报、审查、合并或 settle。
- 请求体为 `{"model": "jev-latest", "state": …, "questions": {id: {"type": "noul"|"choice"|"score", "instructions": …, "criteria": …}}}`；choice 的 `criteria` 是选项键到含义的对象，score 的 `criteria` 是有序等级数组。响应读取 `answers`、`model`（实际版本，如 `jev-1.14.0`）和 `usage.input_tokens` / `usage.output_tokens`。
- HTTP 映射：401/403 `auth_rejected`，422 `invalid_request`，429 `rate_limited`，408 或本地超时 `timeout`，其他 5xx/529 和不可读响应 `provider_error`，连不上 `network_error`；没有 key 记 `missing_key`。`skipped_busy` 表示进程内已有 4 个在途 Jev 请求，本次跳过发送并记录 answers 为 null。失败只写账本，不提示 lead，也不弹通知。

## 账本

`<版本数据目录>/decisions/ledger.jsonl`（Release 为 `~/Library/Application Support/Tivano/`，Dev 为 `…/Tivano Dev/`），一行一个 JSON 对象，只追加。超过 20 MB 时改名为 `ledger.1.jsonl`（覆盖更旧的一份）再写新文件。账本只在本机，包含请求和回报原文。

决策记录：

```json
{"v": 1, "qv": 2, "kind": "decision", "id": "<uuid>", "at": "<ISO 8601>",
 "point": "headReport|preReview|reviewDisposition|continuation|reviewFindings|followUp",
 "leadID": "<uuid>", "jobID": "<uuid>", "headID": "<uuid，head 相关点位>",
 "engine": "typesafe", "model": "jev-latest", "responseModel": "jev-1.14.0",
 "status": "ok|failed|skipped", "error": null,
 "latencyMs": 412, "inputTokens": 1630, "outputTokens": 151,
 "state": {}, "questions": {}, "answers": {}, "meta": {}}
```

`qv` 是各点位题目与 state 语义的版本，来自 `HydraDecisionRequests.questionVersion(point)`；该点位语义变化时才递增，缺省视为 1。本轮三个旧点位保持 2，三个新点位从 1 开始；评估按（点位，qv）分组，不合并不同版本。账本格式版本 `v` 保持 1，outcome 记录不加 `qv`。

decision 记录可带本地 `meta` 对象，只落盘、不发送给 TypeSafe，用于重派来源、逐条意见路径和同 job 追问等关联信息。

`answers` 原样保存 Jev 的 `answers` 对象；失败时为 null。保存 `state` 与 `questions` 原文，以后可以把同一批真实状态离线回放给其他引擎、便宜 LLM 的枚举输出基线或不同阈值，不必重新跑任务。

H2 结果记录：

```json
{"v": 1, "kind": "outcome", "at": "<ISO 8601>", "point": "preReview",
 "leadID": "<uuid>", "jobID": "<uuid>", "reviewer": "Codex …",
 "findings": 2, "findingPaths": ["Tivano/App/Foo.swift"]}
```

H1 的标签（`continuations`、状态）和 H2 的辅助标签（`reviewAccepted`）在 `library.json` 的 `hydraJobs` 里，按 `jobID` / `headID` 关联。

## 数据外发

发送给 TypeSafe 的内容包括：用户请求、head 回报、lead 回复、审查意见、改动文件路径与增删行数。不发送 diff 或文件内容，但回报和意见的文字可能引用代码。TypeSafe 官方接口不是零数据保留。设置页的说明里写明这些。

## 评估

`python3 -I scripts/hydra_eval.py decisions --out <目录>` 只读账本和 `library.json`，按（点位，qv）分组输出；缺省 `qv` 视为 1，不同版本不合并比较。新增标签：

- `rework_after`：后续续派被标为 `fix` 或 `omission`。
- `real_defect_any`：至少一条意见为 `inJobDefect` 且 H3 为 `accepted`。
- `outside_any`：至少一条意见为 `outsideJob`。
- `head_missed_defect`：被接受的本 job 缺陷落在该 head 落地的文件上。
- `correction`：用户后续消息被标为 `correction`。

评估输出：

- 覆盖：ok / failed / skipped 计数（按 error 分）、延迟 p50 / p95、token 合计。
- 无账本 job：拆为尚未结束、无可触发点、有触发证据但无账本三类，不把未触发混作漏记。
- H1：`reworkLikely` 对 `rework_after`、`head_missed_defect`、`correction` 的 AUROC，以及启发式基线的 AUROC；`continued_after` 保留作历史对照。第一版另统计 `gapUnreported` 和 `completion`。
- H2：`defectLikely` 对 `real_defect_any`、`correction` 的 AUROC，以及各基线的 AUROC。`unrelatedChanges` 暂停与 `findings_any` 比较，只对 `outside_any` 评估。H3 accepted 以 Jev 处置为准，正则计数仅作对照。
- H3：各选项分布，以及每个 job 的 accepted 数与正则计数的一致率。
- 正例或反例少于 10 个时只报计数，写"不足以判断"。

实用价值表按阈值输出：

| 用途 | 指标 |
|---|---|
| 提醒 | 触发率、精确率、每 100 次提醒命中数 |
| 审查分流测算 | 低于阈值可跳过的审查比例，对照漏掉的真缺陷比例 |

审查分流只测潜在收益与代价，本轮不跳过审查。

进入提示阶段的建议门槛（由 owner 决定，不自动生效）：该点位正例、反例各 ≥ 30，Jev 的 AUROC 比最好的启发式高 ≥ 0.05，且前后两半数据方向一致。通过 AUROC 门槛后，进入提示阶段前还需看实用价值表（提醒精确率与每 100 次命中数），由 owner 决定。标签尚不足以判断时继续影子测量；有充分数据仍无价值的点位再删除。

## 历史回放（2026-10-28）

`scripts/hydra_decisions_replay.py` 从 Release 库里已有的 v2 job 重建三个点位的状态，经官方接口打分，再交给 `hydra_eval.py decisions` 和当时的真实结果对照。lead 当时看不到这些判断，标签没有被污染。样本：59 个 head 回报（8 个被送回返工）、36 次审查（15 次有意见）、10 次审查处置（19 条意见）。产物在仓库外 `private-artifacts/decisions-replay/2026-10-28-release-v2-r2*`。105 次调用全部成功，延迟 p50 约 0.66 秒、p95 约 0.85 秒，输入共约 15 万 token。

- **H2 审前风险**：`defectLikely` 对"审查有意见"的 AUROC 两轮分别为 0.838 / 0.864，最好的启发式（改动文件数）为 0.775，增删行数 0.565。差值的 bootstrap 95% 区间为 [-0.13, 0.26]，样本内不显著。`riskiestFile` 命中 2/9，不如"改动最多的文件"的 3/10，没有价值。
- **H1 回报一致性**：初版题目的 `gapUnreported` 高分项全是误报，因为 head 按约定不构建、不测试，Jev 把"没跑构建"当成未申报缺口。题目补上这条约定后（当时版本），三栏为空的报告最高分降到 0.25；`completion` 判为未完成的 24 个 head 里有 7 个后来被返工，8 个返工中只漏 1 个；启发式"三栏非空"标出 46 个，覆盖全部 8 个。正例太少，只能说方向可期。题目是在同一批数据上修正的，存在过拟合风险，要用新数据复核。
- **H3 审查处置**：Jev 的 19 条判断与人工判读完全一致；现有正则在 10 个 job 中有 4 个没有记录，有记录的 6 个里错了 3 个（中文回复和不按模板写的回复都识别不了）。作为账本的测量工具价值明确。

Dev 实测（2026-10-28，Codex 同模型、演示仓库）：job 正常完成，2 个 head 回报和 1 次审前判断都成功写入账本（App 内延迟 0.3–0.6 秒），审查为 Claude、0 条意见，结果记录齐全；没有意见所以 H3 未触发，它在 App 内的链路未实测。两份回报都写了"主线程需补充入口导出"，指的是本来分给 lead 的文件，`gapUnreported` 仍给出 0.84 / 0.91：留给 lead 或不归自己负责的文件的工作，也会被当成缺口，题目随后补上了这条分工说明（当时版本）。

结论：H3 的判断比正则计数可靠，但按上面的决定两者并存；H1、H2 有信号但样本不足，继续影子积累，达到上面的门槛再考虑提示阶段；`riskiestFile` 已删除。同一批状态两次打分的 AUROC 相差约 0.03，比较时要考虑模型自身的波动。

## 第三轮生产数据（2026-11-05）

A5S + H8S 共 952 条记录；qv2 自 11-02 Release 2.2.42 起积累约 3.5 天。

- **H1 `reworkLikely`**：qv2 对 `continued_after` 的 AUROC 为 0.672，比最好启发式高 0.157，差值的 95% 区间为 0.07–0.24，前后两半一致，正例 39，数字上过门槛。但阈值 0.7 时提醒 5% 的报告、精确率仅 26.7%（阈值 0.5 时为 20%）；抽查续派多为追加或深挖，标签不足以支撑提示阶段。
- **H2 `defectLikely`**：qv2 AUROC 为 0.857，`headFlags` 为 0.771，差 0.086，95% 区间跨 0（-0.01–0.17）；qv1 的差值为 -0.014，对 accepted 的 AUROC 为 0.48，尚不稳定。`unrelatedChanges` 对 `findings_any` 为 0.50，与 `defectLikely` 相关约为 0，目前没有可检验标签。
- **H3 审查处置**：一致率 97.7%（42/43），唯一分歧为正则不认中文“接受”。
- **覆盖**：219 个已盖章但无账本的 job 均未到决策点，多为无改动、无 checkout，非漏记。

结论：H3 作为测量工具保留；H1、H2 继续影子。正则保留并补中文“接受/采纳”，job 账本不依赖外部服务的决定不变。本轮先补齐标签，再判断提醒与节省审查成本是否有实用价值。

## 以后的提示阶段（未实现）

- H1：概率超过阈值时，在 v2 回报的 `Flags` 里加一行，说明报告正文可能有未申报的缺口。
- H2：高风险时再考虑加强审查。任何阶段都不跳过审查（只加不减）。
- 提示阶段同样只加不减，阈值来自本机账本，不来自厂商默认值。

## 不做的事

- 不在 provider CLI 内部做工具、skill 或权限路由，不按消息自动选模型或 effort，不让决策模型决定是否派 head。
- 不把概率当正确率，不用它跳过构建、审查或合并。
- 不用任务成功率作主判据；它的重跑噪声比要测的效果大。
