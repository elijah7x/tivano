# DSH runtime contracts

Reviewed against the installed desktop runtime **0.2.1-rc.2**, not an unversioned online API. Extracted official implementation is retained locally in `build.noindex/dsh-native-source/`. This note distinguishes implemented behavior from outstanding compatibility work.

## Account, configuration and models

- The provider uses the external DSH home (`DSH_HOME`, otherwise `~/.dsh`). Credentials are not imported into Tivano, Dev or its Keychain. Local account detection recognizes the bounded v1 `records[deepseek-account-platform/default]` grant layout, including a nonempty token and issuer. It is **local evidence**, not proof the server has accepted an unexpired grant. Source: `dsh-credentials-local` and `dsh-deepseek-account-platform`.
- Reauthentication requires a changed credential-file stamp. Default-home login opens the installed app; custom-home login uses an owned web-login process with that environment. Cancellation stops only the owned process. These UI paths remain unexecuted in this task to avoid disturbing the signed-in account.
- For an installed desktop/web profile manifest (desktop wins), launch composition imports supported selected bundles and their resolution context into ACP before user/home patches and launch overlays. Those overlays are Tivano mode, optional no-delegation and optional report guard. Without that manifest, the existing ACP/user-patch launch remains available. The user files are not rewritten. Base environment preserves user telemetry choices and removes the incomplete `GIT_CONFIG_*` group that DSH would otherwise partially strip.
- Model IDs are opaque ACP values; current rc.2 uses JSON-encoded `[provider, model]`, not slash-delimited names. Never normalize these like Cursor's parameterized IDs. No fabricated API key is supplied during catalog discovery. Probe restoration uses the usable default, not an unavailable official route; a corresponding account model retains the current model when possible.
- Every patched start reruns composition validation. Only the exact known optional row/file and known desktop-only UI rows are exempted. A functional missing patch entry fails startup. A successful dump proves composition, not that every plugin's runtime startup will succeed.

## Final reports: mechanism, not prompt advice

`ThreadRuntime` includes report-only state in its session signature. At the next turn boundary, switching to a report rebuilds the DSH process and resumes the same session. Normal turns do not reuse a report-only process. Startup failure cannot silently become a new conversation.

The generated `DshReportGuard` plugin:

1. Registers a global `tools.guard` denial.
2. Wraps system-prompt assembly and removes the final tool schema list.
3. Emits readiness only after both registrations succeed.

The adapter requires both report-only configuration and readiness before dispatching the report prompt. Missing readiness fails closed. This is not a model instruction, permission refusal, or blanket MCP removal.

Official source anchors:

- `dsh-tools/lib/index.js`: `Tools.guard`, `guardReason`, and the staged execution handler. The immutable guard check follows extensible `tools/pre-execute`; an ordinary allow decision cannot bypass it. Global guards also cover agent-scoped tools.
- `dsh-system-prompt/lib/index.js`: assembly waterfall and `next()` wrapping.
- `dsh-agent`/`dsh-agent-loop`: tools emitted through assembly and dispatched through the tools service.
- `dsh-acp/lib/index.js`: `session/resume`, scoped model controls, turn admission and tool/permission events.

The native hostile-model suite covers direct tools, PTC `run_code`, a registered plugin tool and a real stdio MCP tool. Positive controls first execute plugin/MCP tools without the report guard; report runs must deny execution, advertise zero tools, retain history and complete. The real-account Swift suite additionally proves guarded resume through production ACPSession/DshCLI/Shell for all four modes. Neither suite invokes the App Hydra coordinator. A separate simulated-ACP App probe now verifies real delegation/report delivery and the unchanged 35-minute head budget: cancellation, guarded process replacement, same-head-session resume and lead follow-up. Its readiness event is simulated, not native plugin enforcement; see `docs/dsh-validation.md`.

This guard is not an OS sandbox against arbitrary trusted plugin startup code. A plugin that directly performs side effects outside the tools service is outside its enforcement boundary. Creator's ordinary management tools are guarded; arbitrary reconfiguration by previously installed code is not claimed safe.

## Plugin and marketplace boundary — supported rc.2 import

The existing desktop user patch is inherited, including filesystem-addressed custom plugins. The owner's current patch was present in the real-account Swift test; its UI delivery was not inspected.

**A desktop user patch is not the entire desktop profile.** Official `dsh-app-boot` defines a profile as `package.json` (`dsh.profile.bundles`, dependencies and version exemptions), installed package resolution, and `cordis.patch.yml`. `loadProfileDirectory` loads selected bundle layers before user patches; resolution uses the installation and active profile anchors. ACP is a different active profile.

`DshMarketplace` / `DshMarketplaceBootstrap` now prepare an owned, read-only composition using rc.2 native exports: selected compatible bundles, installed dependency anchors, exact compatibility exemptions and user overrides. Known UI/ACP conflicts, nested Include, configured Worker and unsupported dynamic module/group forms are rejected rather than silently skipped. The plugin-manager service rejects management writes to the source profile; this is not an OS sandbox for arbitrary trusted plugin code, and not a blanket reduction of Creator to Minimal.

The isolated native fixture passes selected bundle/dependency execution, user override ordering, deselection and broken-bundle rejection in all four modes (16/16); every fixture source tree remains unchanged. The existing account also passes eight real App turns on this launch path. This does not establish arbitrary marketplace-package compatibility or every Creator development/inspection workflow. Installation atomic snapshots, installation-change invalidation at turn boundaries and crash-orphan directory reclamation remain unimplemented. No credentials are copied, packages installed or writable source `node_modules` linked into a second profile.

CaptureRun-owned patches and launch resources live under its isolated `provider-runtime/dsh` root. Only the explicit DEBUG DSH integration opt-in shares external `DSH_HOME`; normal captures do not activate providers. Owned launch directories are released on startup failure and process exit.

## Recovery and isolation

Resume/auth/lock/missing-history errors retain their original failure. Existing `ThreadRuntime.startsOver` remains the separate warned recovery path. Mixed MCP failure does not silently discard healthy servers. Session notifications and permissions are isolated by session ID; approval IDs preserve numeric/string distinctions locally without changing global `RPCID.key`. Failed tool input does not fabricate successful file edits; real ACP diff blocks remain supported.
