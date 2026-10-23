# 上游依赖巡检规范（upstream-watch）

Tivano 编排的外部 agent CLI 一旦重写或破坏性变更，会直接伤害 Tivano。本规范定义前瞻巡检的观察清单、渠道、判断口径与报告格式。巡检由 ZCode 定时 automation 执行（每 2 天 05:00，无人值守），跨机器职责：上游巡检在 owner host 跑，机器得开着。

## 任务约束

- 每轮先读本文件，再抽查 `Tivano/Services/Providers/ProviderRegistry.swift`、`Tivano/Core/Models/Provider.swift` 与 `docs/providers.md`——观察清单与代码有出入时以代码为准，并在报告中注明漂移；新增 provider case 在当轮并入观察清单。
- 时间窗 = 报告目录里最新文件名的日期到今天；目录为空则取最近 7 天。漏跑不丢覆盖，窗口自动顺延。
- 只读巡检：不改源码、不构建、不安装或升级任何 CLI、不启动 app、不推送、不发消息。报告文件是唯一产出。

## 观察清单

- **P0（每轮深查）**：Codex CLI、Claude Code、OpenCode、pi、omp、ACP 协议
- **P1（每轮快查 releases/changelog）**：Cursor CLI、Grok Build、Kimi Code、Copilot CLI、Devin CLI、Antigravity CLI、Command Code、DeepSeek Harness（dsh）、MiniMax Code（mcode）
- **P2（低频扫公告）**：Z.ai Coding Plan 端点与限额、DeepSeek API 公告、Meta、models.dev

清单以 `Provider.swift` 的 `ProviderKind` 实测为准。

## 渠道

| 上游 | 渠道 |
| --- | --- |
| Codex CLI | github.com/openai/codex（releases、CHANGELOG、commits） |
| Claude Code | npm `anthropics/claude-code` + 官方 CHANGELOG（闭源，推断） |
| OpenCode | anomalyco/opencode（原 sst）；主线 V2 npm `@opencode/cli`，GitHub Releases 只挂 V1——以 npm + opencode.ai/changelog 为准 |
| pi | earendil-works/pi（原 badlogic/pi-mono）+ npm `@earendil-works/pi-coding-agent`（旧 `@mariozechner/pi` 停滞勿用） |
| omp | can1357/oh-my-pi（omp.sh）；不经 npm；跟踪 omp² 重写 |
| ACP | agentclientprotocol/agent-client-protocol（原 zed-industries）；v1 稳定 + v2 alpha 双线 |
| Grok Build | 已开源 github.com/xai-org/grok-build（可查源码 diff）+ x.ai/changelog/build + npm |
| DeepSeek Harness（dsh） | deepseek.com/en/harness + api-docs.deepseek.com（news / updates） |
| MiniMax Code（mcode） | agent.minimax.io/docs/cli（changelog / quick-start）；npm 包名待查证 |
| 其余 | 各官方 changelog / releases，见 `docs/providers.md` 的 Source 列 |

渠道顺序：gh api（本机已登录）→ GitHub releases.atom / commits → npm registry JSON → 官方 docs changelog → WebSearch。某渠道失败换下一个并在报告中记录，不静默跳过。

## 集成面（判断口径）

巡检验证的是「变更是否落在 Tivano 的集成面上」，而非「有没有新版本」：

- `--version` 输出解析（正则 `数字.数字[.数字]`）。
- `ProviderRegistry.fallbackExecutables` 的 PATH / 常见安装位发现。
- `Provider.loginCommand` 与 auth/status 输出文本及格式。已知格式约定：Codex `login status` 的登录判定需兼容 0.164.0 起 API-key 路径的 `API key configured - {key}` 文案（旧为 `Logged in using an API key`）；OpenCode `auth list` 已表格化，Tivano 兼容 legacy `●` 行与 V2 三列表行，长期更稳做法是读 `~/.local/share/opencode/auth.json`。
- CLI 参数 / 子命令、ACP 会话与协议方法（Tivano 经 ACP 驱动 cursor-agent、opencode、grok、devin、kimi、dsh、mcode）。
- config 路径（如 `~/.grok/auth.json`、`~/.commandcode/auth.json`、`~/.minimax/config.yaml`、`DSH_HOME`）。
- 模型 id 与目录规则：live 模型列表是唯一可信源；Command Code 等目录随官方 catalog 漂移，解析需容忍未知 id。
- 计划限额口径、运行时要求（Codex 含 app-server 会话、计划窗口与 banked resets）。

分级高/中/低；闭源上游按版本流 + changelog 推断并标注置信度；证据不足写「不确定 + 缺什么证据」；宁可标待查，不断言。

可选只读补充：对本机已安装 CLI（PATH 含 /opt/homebrew/bin、~/.bun/bin、~/.npm-global/bin、~/.volta/bin、~/.local/bin）跑 `--version`，记录本机版本与最新版差距；失败不阻塞。

## 报告格式

写入 artifact 根下 `private-artifacts/upstream/YYYY-MM-DD.md`（仓库根的上一级目录；仓库内 `reports/upstream` 是指向它的软链，不作为写入位置），目录不存在则创建，已存在则覆盖。最新报告日期决定下轮时间窗，勿只删最新一份。中文，结构：

1. 窗口区间 + 一句话结论。
2. 上轮未关闭行动项复核：逐条标注 已解决 / 仍在 / 升级；无事写「上轮无未关闭项」。
3. 「需要关注」分级（高/中/低；无事时明确写「本窗口没有需要关注的上游变更」）。
4. 每上游一节：最新版本+发布日期、窗口内变更、影响评估、本机版本、来源链接。
5. 未能检查项与原因。

写完即结束：不提问、不修改仓库源码、不创建任何定时任务、不做任何后续动作。

## 沿革

- 2026-10-16 建立；原文件曾随 tivano.dev 工作区丢失（未跟踪文件），2026-10-23 自创建会话历史还原并入库，同时更新：OpenCode 单一 provider（Zen/Go 已合并）、报告改落 `private-artifacts/upstream/`、Grok Build 开源渠道、新增 dsh 与 MiniMax Code 观察项、报告增加「上轮未关闭行动项复核」一节。
