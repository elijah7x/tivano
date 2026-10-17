# Providers

## Vocabulary

- Agent: the program that runs the tool loop, tools, approvals and session state—a vendor CLI or Tivano Code, Tivano's own agent in `OpenAICompatibleSession` for DeepSeek, Meta and Z.ai.
- Account: what the user signs in with or pays for—a subscription, prepaid credits, or an API key.
- Model: what the account offers; many agents offer other vendors' models.

`ProviderKind` is still one fused (agent, account) pair. OpenCode is one provider on the `opencode` CLI. Pi, omp and OpenCode leave the account to the user's own setup.

## Groups

- **Agent CLIs**: the tool loop runs in a program the user installs, which Tivano starts and relays. This covers the vendors' own agents (Codex, Claude, Cursor, Grok, Devin, Kimi Code, Antigravity, Copilot, Command Code), OpenCode and the community agents Pi and omp. OpenCode needs the `opencode` CLI: models are probed from `opencode acp`, sessions run through it, and sign-in is read from its credential list. Cursor and Devin are started as `cursor-agent acp` and `devin acp`; Tivano advertises no file-system or terminal capability to them, so it executes none of their tools.
- **Tivano Code**: Tivano's own agent for providers that need no CLI and talk to an API with a key (DeepSeek, Meta, Z.ai).

The Settings list and the Choose providers popover share one order: the two groups in that order, then A-Z by display name inside each group, never by sign-in state. Every other list of providers is A-Z too. Model catalogue lists are A-Z by name (numbers in natural order) at display time; the stored catalogue keeps the provider's order because default and newest-model logic depends on it; the pinned model list keeps the user's own order.

An API-only route to a plan that today needs a CLI (OpenCode's Zen or Go) would be a new Tivano Code provider, not a regrouping.

## Where the UI shows it

The `agent · account` line appears in the settings provider header, the welcome checklist row and the model chip tooltip. The model picker is deliberately unchanged.

## Adding a provider

Add cases to `agentName`, `accountLabel` and `group`; all three are exhaustive switches, so the compiler enforces coverage. Add a zh-Hans entry per new account label to `Localizable.xcstrings`, and add a row to the table below.

## Providers

Verified against vendor documentation on 2026-10-16.

| Provider | Agent | Account label | Credentials accepted and billing | Source |
| --- | --- | --- | --- | --- |
| Codex | Codex CLI | ChatGPT plan or API key | ChatGPT sign-in (plan allowances or credits) or an OpenAI API key (usage-based) | https://developers.openai.com/codex/auth/ |
| Claude | Claude Code | Claude plan or API key | Claude Pro, Max, Team or Enterprise subscription, or a Console/API key; also Bedrock, Vertex, Foundry | https://code.claude.com/docs/en/authentication |
| Cursor | Cursor CLI | Cursor account | Browser login or a Cursor user API key; both are the same Cursor account, not model-provider keys | https://cursor.com/docs/cli/reference/authentication |
| OpenCode | OpenCode CLI | Set up in OpenCode | Whatever the user set up in the opencode CLI: OpenCode Zen (prepaid pay-as-you-go balance, models opencode/), OpenCode Go (flat monthly subscription with optional pay-as-you-go overage, models opencode-go/) or any other provider. The entry lists every model the CLI reports; signed in means the CLI holds any credential. Rows keep the CLI's names, so Zen and Go rows of one model stay distinguishable. | https://opencode.ai/docs/zen/ and https://opencode.ai/docs/go/ |
| Grok | Grok Build | Grok plan or API key | Browser or device login, enterprise OIDC, or XAI_API_KEY; subscription and xAI API billing are separate | https://docs.x.ai/build/enterprise |
| DeepSeek | Tivano Code | API key | API key, prepaid balance deducted per token | https://api-docs.deepseek.com/quick_start/pricing |
| Meta | Tivano Code | API key | Model API key, pay-as-you-go | https://dev.meta.ai/docs/pricing-rate-limits |
| Z.ai | Tivano Code | GLM Coding Plan | Tivano calls the Coding Plan endpoint (`/api/coding/paas/v4`) on z.ai or open.bigmodel.cn by region; the standard pay-as-you-go API is a different endpoint | https://docs.z.ai/devpack/tool/others |
| Devin | Devin CLI | Devin account | Devin account login or token; `WINDSURF_API_KEY` for ACP | https://docs.devin.ai/cli/reference/commands |
| Antigravity | Antigravity CLI | Google account or API key | Google account (Free, AI Pro, Ultra) or a Gemini API key with separate billing | https://antigravity.google/docs/install?tab=cli |
| Copilot | Copilot CLI | Copilot plan or API key | GitHub Copilot plan, or the user's own model-provider keys (BYOK) | https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli |
| Command Code | Command Code CLI | Subscription or credits | Browser login or a Studio API key; subscription credits plus on-demand credits | https://commandcode.ai/docs/resources/pricing-limits |
| Pi | Pi CLI | Set up in Pi | Configured inside Pi (OAuth logins, API keys, custom endpoints); models arrive as `provider/model` | https://pi.dev/docs/latest/providers |
| Kimi Code | Kimi Code CLI | Kimi membership or API key | Kimi Code OAuth membership, Console keys, or Platform pay-as-you-go keys | https://www.kimi.com/code/docs/en/kimi-code-cli/guides/getting-started.html |
| omp | omp CLI | Set up in omp | Configured inside omp (subscription logins, API keys, custom providers); models are `provider/model-id` | https://omp.sh/docs/providers |
