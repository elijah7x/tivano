# DSH acceptance findings — 2026-10-18

**Functional evidence is substantially complete for the exercised paths; full product acceptance remains open.** Evidence includes adapter 33/33, marketplace 16/16, native contract 11/11, native report guard 12/12, eight real App account turns, simulated-ACP App Hydra scheduling and a real 35-minute budget/report transition. After unlocking, four history views and the existing foreground Settings/HeavyLoad probes were captured and inspected. Their admission/reconciliation gates passed; matched pre-change performance comparison, real wheel/RAM checks, App MCP/tool execution and live login/picker interactions remain unverified. No new account prompts, installation, packaging, merge or release were performed during this follow-up.

## Initial baseline evidence

- Production source baseline: `560e2ba677de45201cc95252fdaaab720d0e29cc`, on dev 1.3.16.
- Installed desktop-bundled CLI: `0.2.1-rc.2`. The desktop UI was not opened.
- `python3 scripts/dsh_adapter_stress.py`: real Swift ACPSession/DshCLI/DshPatches/JSONRPC/StdioProcess compiled successfully; **4/17 passed, 13/17 failed**. No production deadline was shortened. App storage, MCP installation, unused Shell preflight and other outer dependencies are shimmed; see the generated source/hash manifest.
- Native offline tests: **11/11 passed** — eight mode/delegation combinations, shared-home history/isolation/resume, cancellation, direct process cleanup. A loopback Messages API received actual dsh model requests. Network sandbox allowed only that endpoint.
- Native existing-account tests: **6 real prompts**, account Flash with low/off reasoning, two independent sessions, two initial turns each and one recall each after process restart/resume. Marker recall/isolation and direct process cleanup passed. No API credential was supplied, copied or inspected.

Local artifacts (ignored by Git):

- `build.noindex/dsh-adapter/run-_fznctnz/summary.json`
- `build.noindex/dsh-adapter/run-_fznctnz/kit/sources.json`
- `build.noindex/dsh-native/offline-final.json`
- `build.noindex/dsh-native/account-v5.json`

## Pre-marketplace repair evidence

- Pre-marketplace full app Debug build: **BUILD SUCCEEDED**, including the new report guard and zh-Hans error strings. Log: `/tmp/tivano-dsh-build-final.log`; command includes `-skipPackagePluginValidation`. Existing compiler warnings remain; this is not a warnings-free claim.
- Actual adapter matrix: **33/33 passed**, including every original failing assertion. `build.noindex/dsh-adapter/run-6tqa36th/summary.json` and `kit/sources.json` record results, source hashes and shims. The expanded suite includes repeated cancel/rebuild, failure cleanup, unsupported resume, no-guard refusal, incremental kind, 6,000 ordered deltas, credential-record parsing, uncached patch validation, model restoration and two simulated non-DSH ACP cases.
- Native report guard: **12/12 passed**, four modes × direct/plugin/MCP. Plugin and real stdio MCP tools first execute successfully without the guard. With the guard, a hostile loopback model's forced call is denied, both model requests advertise zero tools, history is preserved and reporting completes. Full-access permission mode rules out a permission-denial false positive. Evidence: `build.noindex/dsh-native/report-guard-expanded-v2.json` and `.log`.
- Actual production Swift ACP/DSH/Shell with the **existing account: eight real Flash low/off prompts passed** across Standard, PTC, Minimal and Creator, in pairs of concurrent sessions. Every mode stops, resumes the same ID in report-only configuration and recalls its synthetic marker. Evidence: `build.noindex/dsh-live/run-yqu4sk42/live-result.json`, `sources.json`, `compile.log`, `run.log`. These are additional to the six earlier native-only prompts. No app UI, Hydra coordinator or actual App MCP registry participates in this harness.
- The real Swift run uncovered a defect the simulated peer had missed: an unavailable official model route was restored after probing the usable account models, producing ACP `-32602`. Removed the fabricated probe API key and restored the usable default, preserving model identity where available. Added `probe-unusable-route`; failed preliminary live attempts sent **zero prompts**.
- Existing timeline checks pass: 20,000 height updates, restoration, invalidation, stale generations, hidden/prebuilt suppression, repair, cancellation and rapid return. Log: `/tmp/tivano-dsh-timeline-final.log`. These checks do not establish UI latency, CPU or RAM acceptance.

Production changes also propagate original resume/MCP failures, bound requests/probes, clean failed/repeated starts, isolate sessions and typed approval IDs, merge incremental tool input without fabricating edits, surface sanitized catalog errors, cancel stale authentication/catalog work, and rebuild DSH sessions only at safe turn boundaries. Local login detection is bounded and explicit relogin remains available. Custom-home login and actual Settings changes still require UI testing.

An intermediate adapter-fixture failure was Foundation's atomic temporary-file write escaping the offline sandbox during the **test's** warning-file rewrite. The fixture now writes that scratch file directly; no product assertion or sandbox rule was relaxed. The first expanded native run also caught malformed PTC positive controls: `run_code` requires a `description`. Supplying that required field made the positive controls execute and the final-report controls still deny them; all 12 cases then passed.

## Marketplace baseline (before implementation)

The lead reviewed all three follow-up head deliverables. The marketplace fixture's broken-bundle assertion was tightened: a warning plus successful startup must fail, not pass. Its user-patch case now overrides a selected bundle's configuration, testing layer order rather than only a separate plugin.

`python3 scripts/dsh_profile_stress.py --dsh <installed CLI> --summary /tmp/tivano-dsh-profile-baseline.json` compiled the Swift launch-argument harness and ran the isolated native checks: **1/4 passed**. Deselection passed; selected-bundle execution, bundle user-configuration inheritance and fail-closed broken-bundle handling failed. All four source profile trees remained unchanged. This reproduces the marketplace gap; it does not invalidate the separate 33-case ACP matrix.

`scripts/dsh_ui_acceptance.py` passed Python syntax and synthetic analyzer checks for missing evidence, exact reconciliation and a one-delta mismatch. No GUI was launched at that stage. Its outputs deliberately never establish visual/performance acceptance automatically. The design was then a proposal, not an implementation or authorization to restrict Creator's product behavior.

## Marketplace implementation and real App follow-up

- Lead-reviewed production launch plans now carry executable, arguments, environment and owned-resource cleanup through chat, auth and catalog probing. The fixture invokes actual `DshCLI.prepareLaunch`, not the legacy argument generator. The read-only rc.2 bootstrap imports supported selected bundles, their dependency anchors, user overrides and compatibility metadata; unsupported forms fail closed.
- Lead corrections: canonicalize both sides of home comparison, fingerprint the actual ASAR with Electron's `original-fs` rather than its unstable virtual inode, and exempt only the same three missing desktop UI rows already accepted by patch validation. The original 1/4 baseline became **16/16**, four cases × Standard/PTC/Minimal/Creator. PTC executes the fixture through `run_code`. Selected dependencies and overrides work, deselection stays inactive, broken bundles reject before tool/model execution, and all fixture source trees stay unchanged. Evidence: `build.noindex/dsh-marketplace/{standard,ptc,minimal,creator}.json`.
- Current adapter **33/33**: `build.noindex/dsh-adapter/run-s0xy341c/summary.json`. Native contract **11/11** and report guard **12/12** rerun: `build.noindex/dsh-marketplace/{native-contract,report-guard}.json`. Native report tests are still a separate layer, not an App Hydra transition test.
- Optimized current-source Debug build: **BUILD SUCCEEDED**, `/tmp/tivano-dsh-optimized-dev-probe-v2.log`, with `SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule` and task-local DerivedData. An initial build-output override broke SwiftTerm's generated-tool path; normal product layout under task-local DerivedData fixed it. No signing or performance gate was relaxed.
- Iris 2's probe required lead integration corrections: explicit library bootstrap, main-actor-safe orchestration, bypassing login-shell discovery only for the explicit DSH test, and bounded runtime stop-and-wait. The first App attempt stopped before any prompt because the library was not bootstrapped. The repaired attempt completed **8/8 actual App turns**, two per mode, with marker recall through real AppModel/ProviderRegistry/ThreadRuntime. It used the existing account in place, account Flash low/off, sequential sessions, no requested tools and no approvals. Normal CaptureRun remains synthetic; all non-DSH providers remain disabled/synthetic in the opt-in probe.
- App evidence: `build.noindex/dsh-app-live-v2/{dsh-integration,launch,lead-verification}.json`. The launch manifest records exact binary SHA256 and arguments. Four reported account sessions were archived with exact-ID ownership in `account-sessions/manifest.json`; unreported catalog sessions were retained rather than guessed. No matching live owned DSH process remained. Credentials and installed applications were not copied/replaced.
- **Initial visual/performance attempt blocked, not passed:** all screenshot attempts logged “no filter” and could not foreground the window. A subsequent CoreGraphics session query reported `CGSSessionScreenIsLocked = 1`. No screenshot was available for inspection. Foreground Settings/HeavyLoad runs were deliberately not attempted under this invalid condition. That attempt required unlocking; the later successful history-only replay below did not resend any of the eight account prompts.
- Existing timeline regression checks still pass: `/tmp/tivano-dsh-timeline-marketplace.log`. No CPU/RAM/GUI latency acceptance follows from them.

## History-only replay and offline Hydra preparation

Milo added `DshCaptureReplay`, routed before capture seeding, with DEBUG-only warmup/session-creation guards. The lead read the changed code and its storage/runtime callers, then built optimized Debug successfully (`/tmp/tivano-dsh-replay-build.log`). Actual replay loaded the four retained two-turn histories with network and subprocess execution denied except for the explicit App binary; source-file hashes were unchanged. It sent no account requests. All four capture attempts correctly reported `session-locked`, so that first replay provided no screenshots or visual/performance acceptance. Evidence: `build.noindex/dsh-ui-replay-v1/dsh-ui-replay.json` and the adjacent `.launch.json`. The lead also exercised four refusal cases: existing output, source/output overlap, incomplete report and symlinked source file; all refused without replacing existing content (`build.noindex/dsh-replay-negative-l9ssh8yz/results.json`).

Juno made no changes because the existing live-account path guard rejected a fixture home within the output. The lead added `DshIntegrationConfiguration.isOfflineHydra` and a dedicated canonical-descendant rule for the explicit offline flag. The executable and fixture home must both be inside the output and separate from one another; the ordinary live-account rule is unchanged. Six extracted-production path cases passed, including external-path and symlink rejection (`build.noindex/dsh-path-check/results.json`). At that stage the offline App probe was not yet implemented; Ezra subsequently supplied it, and the lead integrated and exercised it as recorded below.

The report-only conversion belongs to a **budget-stopped head**, not the lead's ordinary automatic follow-up after a head report. The production CLI-head budget is 35 minutes, with a three-minute reporting allowance. A quick coordinator test must not pretend to cover that conversion; exercising it must retain those deadlines.

## Completed App Hydra, replay and foreground probes

- **Ezra / lead integration:** wired the DEBUG offline probe before the live-account route. The lead made invalid preparation exit before storage initialization, rejected installed/non-probe bundles in the runner, denied App/subprocess networking, and replaced the fixture's 60-second timing tolerance with comparison against the actual App head-turn start. The first quick run finished the App flow but failed peer-exit evidence; a reentrant fixture termination handler could exit before its first exit record was written. Fixed that fixture race without relaxing assertions. Two subsequent quick runs passed all assertions: `build.noindex/dsh-hydra-quick-v{2,3}/runner-result.json`.
- **Budget transition:** the real production head budget expired after **2100.096839 seconds**. App interrupted the head, launched a different guarded-report process, resumed the same head session, completed its report and delivered it to the unchanged, unguarded lead session. Peak ACP concurrency was two, every peer recorded exit, and all recorded PIDs were absent. The foreground runner was interrupted, so its final summary was missing even though App completed. The lead reapplied the original runner assertions (SHA matches the launch manifest), removed only the leftover fixture lease, and preserved original evidence. Result: `build.noindex/dsh-hydra-budget-v1/lead-recovered-result.json`; this is explicitly recovered evidence, not a fabricated original runner result. Readiness remains simulated; native guard/MCP enforcement is a separate suite.
- **Unlocked history replay:** `build.noindex/dsh-ui-replay-v2` contains four real rendered screenshots inspected by the lead. Both prior marker replies are visible for every mode, with no obvious response clipping or text overlap. No account request or provider launch was allowed, source hashes were unchanged, and the raw model ID in the composer is a limitation of replay without the live catalog—not model-picker acceptance. See `lead-visual-review.json`.
- **Foreground probes:** both `build.noindex/dsh-ui-performance-v1` and `v2` completed Settings' five phases and both HeavyLoad three-phase cases. Every heavy-load thread reconciled exactly 240 deltas; segmented tools reconciled 20 groups per thread. Foreground/geometry/workload guards held. The lead added optional `--settings-probe-captures` stills **after** measured phases and workload cleanup, preserving original sampling, time limits and assertions. V2 includes three Settings stills with geometry and six HeavyLoad stills, all inspected; the analyzer reports no missing evidence or reconciliation issues. Missing-screenshot and one-delta-mismatch negative checks still reject.
- Latest optimized Debug build succeeded: `/tmp/tivano-dsh-settings-capture-build.log`. V2 Settings heartbeat p50/p95/max (ms): idle **5.16/5.22/11.75**, covered load **5.12/17.16/19.79**, visible chat **5.14/18.31/22.14**. Heavy-load driver callback p95/max: stationary text **26.78/81.72**, segmented tools **20.47/148.61**. Callback spikes are retained, not averaged away. These are neither FPS nor input-to-photon latency.
- **Performance acceptance remains not-established.** Two current-build runs are not a matched pre-change A/B baseline. No real-wheel interaction, RAM or persistence-cost acceptance is claimed. Static screenshots cannot establish fluid motion; existing translucent chrome shows underlying scrolled text. Evidence and explicit limitations: `build.noindex/dsh-ui-performance-v2/{analysis,lead-review}.json`.

## Originally reproduced adapter failures — now passing

These are 13 failing cases, not 13 independent defects. Earlier static findings are not automatically counted as reproductions.

| Cases | Observation | Scope and priority |
| --- | --- | --- |
| `resume-auth`, `resume-lock`, `resume-missing` | `session/resume` errors lead to `session/new` without surfacing the original failure. | DSH-specific. Blocker: visible transcript can disagree with model history. Runtime already has a separate, warned fresh-session path. |
| `mixed-mcp` | One broken server causes retry with **all** servers removed, including the healthy fixture. | DSH-specific. A warning exists, but execution loses required tools without a selective or explicit fallback. |
| `wrong-session` | Foreign session text and permission events reach the current adapter's user events. | Shared ACP weakness, magnified by same-connection resume/new fallback. |
| `selection-timeout`, `probe-timeout` | An unanswered config request exceeds the external 60-second limit; fixtures are then terminated. | Shared ACP weakness. This reproduces a loading/selection hang, not merely a slow startup. |
| `late-input` | Approval omits command arguments delivered in a later tool update. | DSH incremental tool-input cache is stale. |
| `failed-edit`, `failed-write` | Failed operations on unchanged files retain synthesized edits. | DSH-specific. Runtime records these edits when tool rows arrive and collects them at completion, so this is not only a fixture presentation issue. |
| `typed-ids` | RPC integer `1` and string `"1"` share the same approval identity. | Shared ACP/JSONRPC edge case. Not evidence that current stock dsh sends mixed ID types. |
| `repeat-start` | Calling `start()` twice on one adapter leaves the first peer alive after stop. | Defensive API gap. Normal ThreadRuntime creates a replacement adapter; no normal user path invoking this twice was established. Do not rank it as a proven everyday DSH leak. |
| `default-model` | ACP's current Flash model remains current, but its default marker is replaced by Pro. | DSH-specific. ThreadRuntime uses catalog defaults for new threads, contradicting the desktop-default inheritance promise. |

Initially passing adapter cases were sequential turns with duplicate RPC responses, two independent adapters, interrupt with pending approval and normal model probing. All original cases now pass. These remain bounded functional/fault tests, not long-duration App reliability proof.

## Initial native matrix coverage and remaining limits

Standard, PTC, Minimal and Creator each exposed the expected direct model tool set, with and without the no-delegation patch. Expected sets were taken from independent earlier rc.2 probes; installed provider source confirmed `DEEPSEEK_BASE_URL` and the Messages protocol. PTC's inner SDK bindings were **not** checked here. Creator's plugin-management ability could reconfigure capabilities; matching its initial tool set does not establish a security boundary.

Existing-account tests inherited the actual desktop profile. HOME and working directories remained temporary; custom-plugin UI/event delivery, marketplace plugins, arbitrary user configuration, provider Git credentials, images and MCP integrations were not exercised. There were no requested tool executions in real prompts. The account driver rejects permission requests, but this does not prevent internal tools that never ask permission.

Real-account App conversations, history-view inspection and simulated-ACP App Hydra scheduling/budget transitions are covered above. Combined real-account Hydra, native tools/MCP through App and full interactive UI acceptance are not thereby established. Still unverified: actual relogin/custom-home UI, rapid API-key changes through Settings, real non-DSH providers, other dsh versions, long-duration use and detached child cleanup. Patch diagnostic invalidation and conservative local credential parsing have offline regression coverage. Supported rc.2 marketplace inheritance is implemented and fixture-tested; broader compatibility, mutation handling and Creator tool workflows remain bounded as documented in `docs/dsh-runtime-contracts.md`. Full-performance requirements and launch boundaries are in `docs/dsh-acceptance-plan.md`.

## Test-driver corrections by the lead

- Replaced the unverified OpenAI mock protocol with the installed provider's Messages protocol and added the reviewed rc.2 contract.
- Accepted ACP capability object `resume: {}` as supported.
- Corrected the macOS sandbox loopback address syntax (`localhost:port`).
- Matched Tivano's behavior of ignoring non-JSON stdout. The inherited real profile emits one such line per process; the initial Python reader had incorrectly stopped on it.
- Corrected process-group cleanup around exited/reaped children and ensured failures still write a summary. Signalling a departed process group initially produced `PermissionError`; this was a driver failure, not an adapter defect.
- Kept real error/stderr content out of persisted logs; only fixed diagnostic categories are emitted.

The initial native attempts failed in the driver before sending model prompts. The successful account run sent all six real requests. Four empty sessions from those early attempts and the two successful test sessions were moved out of the account session directory into the private, ignored `build.noindex/dsh-native/account-sessions/` archive. Its manifest records exact source/destination paths and IDs. No pre-existing session, credential file or profile was manually modified; dsh itself may maintain its normal runtime state.

The later Swift-account run series created four prompted sessions and six empty catalog-probe sessions. All ten were archived under `build.noindex/dsh-live/account-sessions/`; its manifest records exact locations and ownership evidence (reported IDs or the unique empty catalog session created within each recorded run interval). The shared catalog parent and all unrelated sessions were retained.

## Reproduce

```sh
python3 scripts/dsh_adapter_stress.py
python3 scripts/dsh_native_stress.py --dsh /absolute/path/to/dsh \
  --offline-contract scripts/fixtures/dsh_native/0.2.1-rc.2.json \
  --summary /tmp/dsh-native-offline.json
```

Real-account use is a separate explicit opt-in documented in `scripts/fixtures/dsh_native/README.md`. It is not part of the default suite. The native, Swift-account and adapter matrices are now separate passing evidence layers. None substitutes for the remaining App workflow, broader marketplace compatibility and GUI performance acceptance.
