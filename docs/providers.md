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

Verified against vendor documentation on 2026-10-16 (ZCode row: 2026-10-28).

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
| ZCode | ZCode CLI | GLM Coding Plan | Uses the GLM Coding Plan key configured for the Z.ai provider (no separate `zcode login`); the CLI is bundled inside the ZCode desktop app (`ZCode.app/Contents/Resources/glm/zcode.cjs`) and models come from the Coding Plan endpoint by region | https://zcode.z.ai |


## Claude manual accounts

Claude supports adding, renaming, selecting and removing subscription accounts, plus importing selected accounts from CSWAP. Selection applies to new independent chats. Each managed chat saves its profile ID and CLI account/organization identity on its first launch attempt; retries, rewinds and same-provider child chats retain that binding. Claude never rotates accounts automatically. Codex keeps its existing behavior.

The default profile is an exception to account isolation: it follows the external CLI or CSWAP login, including custom configuration directories and API-key/provider configurations. Selecting another account does not move existing default-profile chats into it.

Managed profiles use edition-specific private directories, with `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` set to the same directory. Default-profile settings, history, skills and MCP secrets are not copied. Managed sessions check the CLI's auth status and account/organization metadata in the actual working directory before launching, sending or compacting. Conflicting authentication settings or a changed identity stop the operation. The official CLI owns server-side token validation and refresh during normal use; local identity checks cannot make external credential writes atomic with a running CLI request.

CSWAP preview reads only its non-secret index. Import reads only the credentials the user selects, supporting the inspected claude-swap 0.28.0 index, Base64 backups and Keychain storage. Account UUID plus organization UUID identify duplicates, falling back to email when no account UUID exists; existing credentials are not overwritten. Only OAuth credentials and minimal identity metadata are copied, and Keychain access may require macOS permission. Imported accounts remain pending until explicitly enabled: import alone must not authenticate, fetch usage or start a Claude process. A profile awaiting credential cleanup cannot be used.

Copies can expire, and independent profiles do not create independent server-side logins. Refreshing one copy may affect another copy of the same login in CSWAP or another Tivano instance. For ongoing use in two instances, sign in separately through the official CLI and keep their libraries and profile directories separate. Separate local storage is not a guarantee against server-side effects.

Live processes and account checks prevent reauthentication/removal. Reauthentication first signs in to a temporary profile and verifies the managed chat's recorded identity before replacing the original login. An interrupted replacement blocks use until a matching sign-in repairs it; an interrupted import remains removable. Saved chats prevent removing their profile. Removing an unused managed Claude account deletes its local credentials and profile; it does not call `claude auth logout` or revoke the CSWAP source login.

Quota checks read existing credentials and issue a read-only OAuth usage HTTP request for activated accounts. They never launch the CLI, initialize hooks/MCP/plugins, send model requests, call the OAuth refresh endpoint or add a polling timer. Expired access tokens and HTTP 401 make usage temporarily unavailable; normal Claude use lets the official CLI refresh its login before another usage check. These responses alone do not mean a new sign-in is required. Per-account reads share an in-flight request and a five-minute cache with a 60-second minimum for explicit refresh, including failures; forced reads still join a request already running. Reads for different accounts are serialized within the app. A bound chat reads its own account, and late responses cannot replace another selected account's global display.

Managed quota checks never fall back to the default login after missing credentials or denied Keychain access. Credential selectors preserve the difference between missing and empty values, using service names inspected in Claude Code 2.1.314. Background model discovery uses the existing Claude seed; commands and live models arrive from user-started sessions rather than an extra discovery handshake. Quota checks still generate network traffic, and normal CLI sessions may run configured hooks, MCP and plugins; this is not a zero-network or zero-server-risk guarantee.

Validation uses synthetic credentials, temporary directories and mocked credential/process/HTTP boundaries, never production or Dev credentials. Capture mode cannot import real Claude credentials and is not a sandbox for live account testing. Check pending/cleanup guards, account-bound results, failure caching, concurrent requests and unchanged external data before separately authorized UI acceptance.

Sources: [authentication and directory isolation](https://code.claude.com/docs/en/authentication), [auth commands](https://code.claude.com/docs/en/cli-reference), and [environment precedence](https://code.claude.com/docs/en/env-vars).
