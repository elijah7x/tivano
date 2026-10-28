# Hydra 决策点（实验室）设计

状态：首批（影子模式）已实现（2026-10-28），Debug 构建通过、已打包 Dev。历史回放结果见下文"历史回放"一节。

## 目标与边界

- 回答一个问题：决策模型（TypeSafe Jev）在 Hydra 2 的具体环节上，是否比现有确定性启发式判断得更准。答案要来自本机生产数据，不来自榜单或厂商自测。
- 首批**只做影子模式**：只调用、只记账，不改变 Hydra 的任何行为，也不把判断展示给 lead。lead 看不到判断，结果标签才不会被污染。
- 只支持 TypeSafe 官方接口 `POST https://api.typesafe.ai/v1/systemone`、模型别名 `jev-latest`。不做网关、备用通道或 OpenAI Decisions。
- 只加不减：以后进入提示阶段时，决策模型也只能增加检查或提示，不能跳过审查、构建，不能否决合并。因此关掉它或调用失败都等于今天的 Hydra 2.0。
- 只在 Hydra job 上运行。单模型对话不接入。

## 开关与配置

- Settings › Alpha › Hydra 卡片提供 `Decision model (Jev)` 开关和 `TypeSafe API key` 输入框；默认关闭，只受 Alpha 总开关与自身开关约束（`settings.isDecisionsEnabled = alphaEnabled && alphaDecisionsEnabled`）。
- key 存在本版本的 Keychain service（Release 为 `Tivano`，Dev 为 `Tivano Dev`），account 为 `TypeSafe API Key`，与 provider key 的存法一致；不读环境变量，不写 UserDefaults。Dev 与 Release 各配各的 key。
- 按 job 盖章：`beginHydraJob` 时把 `isDecisionsEnabled` 写入 `HydraJobRecord.decisions`。中途打开只影响下一个 job；中途关闭立即停止调用（每次调用前同时要求盖章为 true 且当前仍开启），因为关闭意味着用户不想再往外发数据。
- capture run 不运行任何决策点（Keychain 不可读，存储根目录也是 capture 的）。

## 点位

每个点位由 Tivano 用代码从可观察事实组装 state，不使用被评判 agent 自己写的摘要。字符上限按 `prefix` 截断并在末尾加 `[truncated]`。下面的英文题目是发给 Jev 的原文，实现照抄。

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

题目：

- `gapUnreported`（noul）："The state is one coding agent's final report on a task its lead assigned. Agents are told not to build, test or verify; the lead does that, so saying a build or test was not run is expected and is no gap. Work the lead was assigned, or that belongs to files outside `ownedFiles`, is the lead's by design and is no gap either; unfinished work in the agent's own files is a gap even when the report asks the lead to finish it. `notes` holds the agent's own Deviations / Unfinished / Uncertain lines (null when it wrote none of them). Does the report text admit something else in its own task unfinished, failed, skipped, guessed or left for later that `notes` does not mention?"
- `completion`（choice）："Judging by the report alone, how far did the agent get with its own task? Not running builds or tests, and leaving work outside its own files to the lead, are expected of it and do not count against completion."
  - `complete`: "Says the task is done and leaves nothing over."
  - `partial`: "Did part of the task; says or shows that some of the task itself is left or skipped."
  - `blocked`: "Could not do the task, or stopped on a question, an error or missing access."
- `reworkLikely`（noul）："Will the lead most likely have to send this agent back to rework its part, judging by the report, the files it owned and the files that landed?"

结果标签：该 head 的 `continuations > 0`（被 lead 用 `continue` 送回返工）为主；H2 结果里命中该 head 落地文件的审查意见为辅。启发式基线：`notes.flagsSomething`、`followedReportFormat == false`。

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

## 调用与失败

- 每次调用一个请求、不重试，总超时 8 秒；调用放在 detached task 里，不阻塞 head 回报、审查、合并或 settle。
- 请求体为 `{"model": "jev-latest", "state": …, "questions": {id: {"type": "noul"|"choice"|"score", "instructions": …, "criteria": …}}}`；choice 的 `criteria` 是选项键到含义的对象，score 的 `criteria` 是有序等级数组。响应读取 `answers`、`model`（实际版本，如 `jev-1.14.0`）和 `usage.input_tokens` / `usage.output_tokens`。
- HTTP 映射：401/403 `auth_rejected`，422 `invalid_request`，429 `rate_limited`，408 或本地超时 `timeout`，其他 5xx/529 和不可读响应 `provider_error`，连不上 `network_error`；没有 key 记 `missing_key`。失败只写账本，不提示 lead，也不弹通知。

## 账本

`<版本数据目录>/decisions/ledger.jsonl`（Release 为 `~/Library/Application Support/Tivano/`，Dev 为 `…/Tivano Dev/`），一行一个 JSON 对象，只追加。超过 20 MB 时改名为 `ledger.1.jsonl`（覆盖更旧的一份）再写新文件。账本只在本机，包含请求和回报原文。

决策记录：

```json
{"v": 1, "kind": "decision", "id": "<uuid>", "at": "<ISO 8601>",
 "point": "headReport|preReview|reviewDisposition",
 "leadID": "<uuid>", "jobID": "<uuid>", "headID": "<uuid，仅 headReport>",
 "engine": "typesafe", "model": "jev-latest", "responseModel": "jev-1.14.0",
 "status": "ok|failed|skipped", "error": null,
 "latencyMs": 412, "inputTokens": 1630, "outputTokens": 151,
 "state": {}, "questions": {}, "answers": {}}
```

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

`python3 -I scripts/hydra_eval.py decisions --out <目录>` 只读账本和 `library.json`，按点位输出：

- 覆盖：ok / failed / skipped 计数（按 error 分）、延迟 p50 / p95、token 合计。
- H1：`gapUnreported`、`reworkLikely` 对"被送回返工"的 AUROC，以及启发式基线的 AUROC；`completion` 的分布与标签交叉表。
- H2：`defectLikely` 对 `findings > 0` 和 `reviewAccepted > 0` 的 AUROC，以及各基线的 AUROC。
- H3：各选项分布，以及每个 job 的 accepted 数与正则计数的一致率。
- 正例或反例少于 10 个时只报计数，写"不足以判断"。

进入提示阶段的建议门槛（由 owner 决定，不自动生效）：该点位正例、反例各 ≥ 30，Jev 的 AUROC 比最好的启发式高 ≥ 0.05，且前后两半数据方向一致。不满足的点位直接删掉。

## 历史回放（2026-10-28）

`scripts/hydra_decisions_replay.py` 从 Release 库里已有的 v2 job 重建三个点位的状态，经官方接口打分，再交给 `hydra_eval.py decisions` 和当时的真实结果对照。lead 当时看不到这些判断，标签没有被污染。样本：59 个 head 回报（8 个被送回返工）、36 次审查（15 次有意见）、10 次审查处置（19 条意见）。产物在仓库外 `private-artifacts/decisions-replay/2026-10-28-release-v2-r2*`。105 次调用全部成功，延迟 p50 约 0.66 秒、p95 约 0.85 秒，输入共约 15 万 token。

- **H2 审前风险**：`defectLikely` 对"审查有意见"的 AUROC 两轮分别为 0.838 / 0.864，最好的启发式（改动文件数）为 0.775，增删行数 0.565。差值的 bootstrap 95% 区间为 [-0.13, 0.26]，样本内不显著。`riskiestFile` 命中 2/9，不如"改动最多的文件"的 3/10，没有价值。
- **H1 回报一致性**：初版题目的 `gapUnreported` 高分项全是误报，因为 head 按约定不构建、不测试，Jev 把"没跑构建"当成未申报缺口。题目补上这条约定后（当前版本），三栏为空的报告最高分降到 0.25；`completion` 判为未完成的 24 个 head 里有 7 个后来被返工，8 个返工中只漏 1 个；启发式"三栏非空"标出 46 个，覆盖全部 8 个。正例太少，只能说方向可期。题目是在同一批数据上修正的，存在过拟合风险，要用新数据复核。
- **H3 审查处置**：Jev 的 19 条判断与人工判读完全一致；现有正则在 10 个 job 中有 4 个没有记录，有记录的 6 个里错了 3 个（中文回复和不按模板写的回复都识别不了）。作为账本的测量工具价值明确。

Dev 实测（2026-10-28，Codex 同模型、演示仓库）：job 正常完成，2 个 head 回报和 1 次审前判断都成功写入账本（App 内延迟 0.3–0.6 秒），审查为 Claude、0 条意见，结果记录齐全；没有意见所以 H3 未触发，它在 App 内的链路未实测。两份回报都写了"主线程需补充入口导出"，指的是本来分给 lead 的文件，`gapUnreported` 仍给出 0.84 / 0.91：留给 lead 或不归自己负责的文件的工作，也会被当成缺口，题目随后补上了这条分工说明（当前版本）。

结论：H3 的判断比正则计数可靠，但按上面的决定两者并存；H1、H2 有信号但样本不足，继续影子积累，达到上面的门槛再考虑提示阶段；`riskiestFile` 已删除。同一批状态两次打分的 AUROC 相差约 0.03，比较时要考虑模型自身的波动。

## 以后的提示阶段（未实现）

- H1：概率超过阈值时，在 v2 回报的 `Flags` 里加一行，说明报告正文可能有未申报的缺口。
- H2：高风险时再考虑加强审查。极小改动跳过审查需要影子数据证明这类 job 的已采纳意见一直为 0。
- 提示阶段同样只加不减，阈值来自本机账本，不来自厂商默认值。

## 不做的事

- 不在 provider CLI 内部做工具、skill 或权限路由，不按消息自动选模型或 effort，不让决策模型决定是否派 head。
- 不把概率当正确率，不用它跳过构建、审查或合并。
- 不用任务成功率作主判据；它的重跑噪声比要测的效果大。
