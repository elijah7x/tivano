# MiniMax Code

Tivano runs the independent `@minimax-ai/code` CLI as `mcode acp`. This is not
MiniMax's multimedia CLI, a direct API adapter, or a Claude Code backend.

## Installation and credentials

Install from the [official quick start](https://agent.minimax.io/docs/cli/quick-start).
The standalone macOS installer places the launcher at `~/.minimax-code/bin/mcode`.
Tivano also searches PATH and common npm prefixes. An explicit Binary path wins;
a missing custom path does not silently select another installation.

A compatible Node installation can use the documented npm command:

```sh
npm install -g @minimax-ai/code@latest --registry=https://registry.npmjs.org/ --ignore-scripts=false --include=optional --allow-scripts=@minimax-ai/code,better-sqlite3
```

Tivano checks the public npm version feed but does not update this CLI. Its
optional native dependency needs the official installation flags; the generic
updater does not implement that transaction.

Credentials remain CLI-owned. Tivano does not add a MiniMax Keychain entry or
rewrite the CLI's configuration. Token Plan uses `mcode login`; Global accounts
use `mcode login --region global`. BYOK does not require that login. Once the key
is securely available in the child process environment, the documented setter is:

```sh
mcode provider set-minimax-key --api-key-env MCODE_PROVIDER_API_KEY
```

China Token Plan API keys can also use this setter; this route was exercised with
a user-supplied `sk-cp-` key against the installed CLI's China-region default.
This selects the API-key route rather than the managed Token Plan login route.

The setter **persists** the key in the active profile's `config.yaml`, under
`minimax_api.apiKey`, and selects `minimax_api_key`. In 0.6.12 the BYOK writer uses
an atomic file replacement and POSIX mode 0600. This is not environment-only or
Keychain storage. The installation directory and CLI data directory are separate;
see [configuration](https://agent.minimax.io/docs/cli/configuration).

The registry reads `provider list --json` presence metadata. A missing selected
BYOK key is signed out. For Token Plan it uses ACP's `minimax-code-login` check;
that method checks the selected authentication route and does not initiate login.
An accepted local check remains `unknown`. The message distinguishes an API-key
route with a locally configured key from a Token Plan route with local sign-in
available. Missing credentials get guidance for the selected route, not a request
to switch routes. Neither configuration nor model enumeration proves that a
server accepted a credential. No automatic model request runs here.

## ACP contract

The initial implementation was read against installed package metadata
`@minimax-ai/code` **0.6.12** on 2026-10-21, including these shipped bundles:

- `run-acp-command-MV4O4NBX.js`: initialize, config controls, sessions, prompt,
  permission and elicitation projections, cancellation, stop reasons.
- `chunk-KGAIRLNO.js`: selected-route login gate, including BYOK.
- `chunk-YDWWGAEN.js` and `provider-command-PVOKX3IV.js`: public provider snapshot
  and environment-based key setter.
- `chunk-5ADYFF2U.js`, `chunk-47KWM23C.js`, `chunk-X3PES5WL.js`: key persistence and
  private configuration writes.

The [official source preview](https://github.com/MiniMax-AI/minimax-code) was also
read at `5821f7c9b0363a9b97a57fff3deaa4cd2da165a4`, especially
`packages/tui/src/acp/{agent,control-state,interactions,updates}.ts`,
`application/login-gate.ts` and `provider/{application,contract}.ts`. That preview
is not represented as the installed package's source revision: it differs, for
example, in image support. The installed bundle and runtime advertisements govern
the adapter. Latest package numbers must be read from package metadata, not copied
from this document.

[ACP integration](https://agent.minimax.io/docs/cli/integrations) reserves stdout
for JSON-RPC and stderr for diagnostics. The adapter sends framed JSON-RPC, never
a natural-language stdin prompt. It checks protocol version 1 and agent identity
`minimax-code`. Invalid JSON/envelopes fail the connection; unknown notifications
are ignored and unsupported requests receive a method-not-found response.

Models are the advertised `model` config-option values, preserved verbatim. In
0.6.12 these encode provider/model/variant as `m:<provider>:<model>:u` or
`m:<provider>:<model>:v:<variant>`, with URI-encoded components. They are not the
headless `--model provider/model#variant` spelling. No model seed or invented
session ID is supplied. Reasoning effort is offered only from actual select
configOptions in the reasoning category, including 0.6.12's `thinkingEffort` /
`thought_level`. The catalogue probe selects each advertised model/variant in its
separate disposable ACP session and reads that exact selection's returned options.
Fresh sessions avoid inheriting another model's thinking state. It sends no
prompts and does not change the CLI's global
model or authentication source. Values and their order are retained verbatim,
including values outside Tivano's usual effort vocabulary. A model with no
advertised control is described as having no advertised adjustable reasoning;
Tivano does not infer that it has only one reasoning level.

Before any prompt, Tivano requires an acknowledged `permissionMode` option:

| Tivano mode | MiniMax process mode | Host behavior |
| --- | --- | --- |
| Supervised | `default` | Show permission requests |
| Auto-accept edits | `default` | Approve edit requests only |
| Auto | `auto` | CLI reviewer; remaining requests stay visible |
| Full access | `bypassPermissions` | Explicit user-selected full access |

A missing option, unadvertised value or malformed acknowledgement fails before
prompt submission. Plan uses the advertised session mode. Permission requests are
not approved just because this is a new provider. Questions use ACP form
elicitation; titles are displayed while their original `const` IDs go back on the
wire. Unsupported forms are declined.

Although 0.6.12 labels permission mode as process-scoped, its setter calls
`config.permission.write`; local validation observed the chosen mode in a later
CLI process. The lead restored the owner's initial mode after validation. Do not
assume the CLI's advertised scope guarantees that the preference is ephemeral.

Replies, reasoning, tools, diffs and context occupancy use existing ACP event
mapping. Only an explicit prompt result `end_turn` completes a MiniMax turn.
Refusal, limits, malformed results, RPC errors and EOF during a prompt are not
success. Cancellation uses `session/cancel`; a five-second grace deadline closes
a silent connection. Cancelled/failed turns close the CLI and its tracked child
processes through Tivano's existing process lifecycle. A successful persistent
ACP session remains open for the next turn and is stopped when its runtime is
released.

## Capability boundaries

- Existing ACP `session/load` is used only when `loadSession` is advertised;
  replayed history is not added to the current turn. Session IDs come from the CLI.
- Existing MCP configuration is passed through ACP session fields; HTTP is used
  when advertised, with the existing stdio handling otherwise.
- Actual `usage_update.used/size` can update context occupancy. No token-spend
  totals, account limits, balances or costs are synthesized.
- Image attachments are disabled. Installed 0.6.12 advertises images, but the
  source preview disagrees and end-to-end attachment behavior has not been checked.
- Rewind, adapter-managed compaction, binary/audio input and ACP extension
  features (delegation, queues, goals) are not added here. A tool-free Hydra final
  report is explicitly rejected rather than sent with tools still available.
- The provider uses the official monochrome mascot as an original SVG; provenance
  is recorded in [the logo note](minimax-code-logo.md). Existing Chrome settings
  and picker components are reused.

The existing synchronized `Tivano` source/resource folder includes these edits
and the new image set; no generated project rewrite is needed.

## Verification status

The Thor implementation commit is `4d17f9819c3c1518814e275071b96b27b87145a8`.
The owner thread corrected a catalogue-refresh race that could overwrite a newer
authentication status and updated the offline ShellResult shim to match its
production interface.

Owner-thread checks on 2026-10-21:

- Debug build passed using the documented `-skipPackagePluginValidation` flag.
  Existing compiler warnings remain; no app was installed or launched.
- `python3 scripts/minimax_adapter_stress.py`: 10/10 offline cases passed against
  production ACP/JSON-RPC/process sources. Covers two turns, question title/ID
  mapping, missing authentication, permission mismatch, invalid JSON/envelopes,
  missing results, unknown stop reason, EOF and silent cancellation. All fixture
  peers exited. Service shims and a simulated agent mean this is not live-provider
  acceptance.
- Existing `dsh_adapter_stress.py` cases `acp-selection`, `acp-permission`,
  `acp-cancel` and `two-turns`: 4/4 passed.
- The catalog has no duplicate keys; all 32 new strings have zh-Hans translations.
- On Thor, installed `mcode` 0.6.12 returned its version and ACP help, accepted
  `initialize`, and rejected unauthenticated `session/new` with error -32000.
  These used an isolated HOME/data directory and made no model requests.

- With the owner's China Token Plan key, one real CLI ACP request returned the
  exact requested text in two chunks and ended with `end_turn`. Supervised
  permission mode was acknowledged; no tools were requested. The CLI exited 0.
- A standalone harness compiled from the current production ACPSession,
  JSON-RPC and process sources then exercised the real CLI on Thor. It discovered
  four model options, used `m:minimax:MiniMax-M3.1-Flash:v:thinking` with `low`
  effort and received the expected streamed reply. After closing the CLI, it
  loaded the original session and correctly answered a second prompt requiring
  the first turn's context. Both turns passed, with no tool requests or starts;
  all connections closed and the harness exited 0. Supporting services were
  stubbed and MCP was empty, so this is adapter acceptance, not full-app testing.

The live checks made three model requests in total. Real tools, permission and
question interactions, cancellation and MCP still require live validation.
UI appearance and rendered translations have not been inspected; launching
Tivano requires separate explicit authorization.

## Local Token Plan follow-up (2026-10-21, head investigation)

This follow-up reads the owner's standalone installation at
`~/.minimax-code/releases/0.6.12/lib/node_modules/@minimax-ai/code`; the package
metadata says 0.6.12. No CLI authentication files, tokens, clipboard, private
conversation storage or remote Thor credentials were read. The supplied screenshot
shows two `Internal error` notices after `hi`, with `M3.1 Flash (订阅限免)` selected.
It does not identify the wire model ID, failed ACP operation or underlying cause.
The preceding Thor API-key checks do **not** establish Token Plan login support.

### Evidence and changes

- Authentication: installed `chunk-YDWWGAEN.js` reports `minimaxModelSource` and
  separate `minimax-oauth` / `minimax-api-key` presence entries. In
  `chunk-KGAIRLNO.js`, the login gate examines the selected model source and
  `managedTokenPresent`; in `run-acp-command-MV4O4NBX.js`, both `authenticate` and
  session creation/loading use that gate. No extra login call or API-key fallback
  is required to reuse the existing login. Settings now explain both routes and
  distinguish local readiness from server authentication. MiniMax is excluded
  from the generic substring-based auth retry, so an arbitrary error containing
  “auth” cannot initiate another authentication attempt.
- Environment: `ProviderRegistry.environment(for:)` uses `LoginEnvironment.current`;
  `StdioProcess` passes it through. That preserves HOME, MINIMAX_DATA_DIR,
  MAVIS_DATA_DIR and exported proxy variables. Nothing here sets a different
  MiniMax data root, key or region. The actual app-versus-terminal effective
  environment has **not** been compared; no environment-root defect is established.
  Official [configuration](https://agent.minimax.io/docs/cli/configuration)
  documents the data-root precedence and separate authentication sources.
- Error detail loss is confirmed: installed ACP `A$` / `Pg` converts ordinary
  exceptions into code `-32603`, message `Internal error`, with details under
  `error.data` (usually `details`). Tivano's `RPCError.errorDescription` uses only
  `message`. ACPSession now preserves the operation name and numeric ACP code,
  classifies known authentication-required and transport signatures into fixed
  localized messages, and otherwise explicitly leaves the cause unknown. It
  never displays arbitrary RPC data or MiniMax stderr. This exposes a safe
  diagnostic category, **not** the account's underlying failure cause.
- Effort discovery: installed `mt` / `fx` returns only the selected model AND
  variant's `effortOptions`. `session/set_config_option` for `model` calls
  `selectSessionModel`, which forwards `sessionId` to `model.select`. The installed
  `chunk-5ADYFF2U.js` handler updates the session and returns before the global
  `setDefaultModel` branch. It does not select the global model. The former MiniMax exception to effort probing left
  nondefault models undiscovered. The probe now reads each exact advertised
  selection. It does not transfer API-key-model effort scales to subscription
  models.
- Full snapshots: the [ACP config-options contract](https://agentclientprotocol.com/protocol/v1/session-config-options)
  replaces the entire options list. ACPSession clears absent current effort/model
  controls, retains exact model IDs in its lookups, and accepts only advertised
  select values. ProviderRegistry no longer fills a revoked MiniMax effort scale
  from the cached catalogue or treats its IDs as Cursor IDs. Model/variant IDs and
  effort values are transmitted unchanged; switching model requires an acknowledged
  model before an effort can be sent. The composer clears an invalid saved effort
  when the observed option changes and shows an explicit unavailable-control
  message. Existing controls are reused; new strings include zh-Hans. One 0.6.12
  boundary remains: its session selector can preserve thinking state when only
  a variant changes, and `fx` omits the effort control if that state is no longer
  advertised. Tivano follows the returned snapshot rather than inventing a reset
  value or taking options from another route.
- ACPSession emits only the owning startup error or prompt failure when closing,
  with no additional MiniMax exit error for the same operation. A separate duplicate
  path is outside this head's assigned files: `ThreadRuntime.warmSession()` appends
  the startup error, then `ThreadRuntime.startTurn(text:attachments:hydraHeads:hydraBrief:externalTurnID:)`'s catch appends the send failure
  after retrying startup. The lead must reconcile warmup/send ownership there;
  the screenshot alone does not prove which duplicate path fired.

### Lead validation still needed

No build, test, lint, app launch, model request or UI inspection of the changed
product was performed by this head. The prior verification section describes the
previous implementation only. `scripts/minimax_adapter_stress.py` adds unrun
fixtures for startup/prompt errors with private-looking details, exact variant and
unusual effort values, per-model catalogue discovery, model switches, and effort
revocation. Existing cases now advertise proper select types and full config
notifications as the real CLI does.

The lead should:

1. Build and run offline fixtures, plus the existing ACP regressions. Check that
   error payloads and stderr never leak fixture secrets, each failed operation has
   one completion, revoked efforts cannot reach a prompt, and exact encoded IDs
   survive round trips. Check catalogue refresh after a CLI route change.
2. With the user's existing local Token Plan route unchanged, compare only safe
   route/presence metadata and effective data-root/proxy selection between Tivano
   and the terminal. Obtain the failed operation, ACP code and safe cause category;
   retain deeper diagnostics locally with secrets removed. Reproduce `hi` once
   authorized, without switching the account to an API key.
3. Refresh the catalogue, select the subscribed Flash model, inspect its actual
   configOptions, then switch between an advertised adjustable model/variant and
   one without the control. Confirm the slider and wire value match the selected
   model, including a removed effort option and returning to a previous model.
4. Inspect the rendered Settings/composer in English and zh-Hans; this head did
   not launch the app. Verify startup/warmup, prompt error, cancellation and EOF
   yield one visible failure, including the runtime duplication path above.
5. Separately confirm the existing API-key route still works. Successful metadata
   probes or the historical Thor requests cannot substitute for either local
   route's real request acceptance.

Still unknown: the cause of the owner's eight-second failure; the subscribed
Flash model's actual wire identifier and effort controls; and full-app acceptance
of the existing login. These changes must not be reported as resolving that live
failure until the lead has that evidence.

### Owner-thread findings and corrections

The following supersedes the head's unknowns above:

- The owner's local 0.6.12 CLI reports `minimaxModelSource=token_plan`, with the
  OAuth entry active and no API key. Its existing sign-in accepted a real ACP
  prompt without supplying or changing credentials.
- Selecting `m:minimax:MiniMax-M3.1-Flash:v:` reproduces ACP -32603 with
  `error.data.details = "Invalid model reasoning"` before any prompt. The CLI
  advertises this empty variant, yet its Token Plan model selector rejects it.
  The same selection succeeds on Thor's confirmed API-key route. This is a
  model-selection defect, not evidence of a missing login.
- The compatibility guard applies only to reported version 0.6.12 AND the
  Token Plan source, obtained from public provider presence metadata. It omits
  inactive empty variants, retains an already active variant, and gives existing
  saved selections an actionable message to choose a thinking variant or update
  the CLI. It never rewrites an ID or silently changes the user's selected model.
  API-key variants remain available.
- The subscribed Flash thinking variant advertises `default`, `low`, `medium`,
  `high`, `xhigh`, `max`. M3 thinking returned no adjustable control in these
  probes, and the app does not invent one. Each model is probed in a separate
  disposable session because the CLI can carry incompatible effort state across
  model switches.
- The lead passed the discovered MiniMax catalogue into runtime sessions, moved
  stale-effort cleanup onto the always-present composer chip, and suppressed the
  speculative MiniMax warmup notice so an explicit send owns its startup error.
- The final Debug build passed. All 17 MiniMax offline cases passed, including
  Token Plan empty-variant rejection and API-key preservation; the four existing
  ACP selection/permission/cancel/two-turn regressions passed.
- Production adapter sources completed two live turns with session restoration
  on the owner's login route and two on Thor's API-key route, using Flash thinking
  and `low`. Replies matched exactly, no tools were requested or started, and all
  connections closed. Service shims and empty MCP mean these are adapter checks,
  not full-app UI acceptance.
- The official logo compiled successfully and was rendered and visually inspected
  from the built asset catalogue at 16, 24, 48 and 128 pixels.
- On 2026-10-21, after explicit owner authorization, `scripts/package_local.sh
  --dev` built and installed the signed dev-1.4.16 app, then the lead reopened
  `/Applications/Tivano Dev.app`. Settings identified the existing Token Plan
  login. After refreshing the catalogue and adding Flash thinking to the user's
  picker, the existing conversation returned `MCODE_LOGIN_OK` in the app. The
  effort control changed from Default to Low. Historical error notices remain.
  An earlier automation input dropped Chinese characters; that unintended turn
  began reading the fixture workspace and was stopped before the successful
  explicitly tool-free English prompt. App screenshots were reduced, skewed
  window thumbnails, so full-size in-app visual acceptance remains limited;
  the native asset rendering above is the reliable logo visual check. No dev
  merge was performed.
