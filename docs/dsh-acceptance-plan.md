# DSH acceptance plan

A successful build, simulated ACP peer, native CLI, actual Swift adapter, App workflow and performance probe are different evidence layers. No layer substitutes for the next. No existing assertion, timeout or performance threshold is weakened by this task.

## Executable checks without launching Tivano

| Check | Command | Acceptance / evidence |
| --- | --- | --- |
| Actual adapter fault matrix | `python3 scripts/dsh_adapter_stress.py` | Every selected case passes; no timeout or owned fixture survivor. 60-second external case limit, unchanged 45-second production request deadlines and 180-second overall catalog deadline. Source hashes and shims in each run. |
| Installed native mode contract | `python3 scripts/dsh_native_stress.py --dsh /absolute/path/to/dsh --offline-contract scripts/fixtures/dsh_native/0.2.1-rc.2.json --summary /tmp/dsh-native.json` | All 11 cases pass against the independently reviewed rc.2 contract. Loopback-only model, isolated HOME/DSH_HOME. |
| Marketplace composition | `python3 scripts/dsh_profile_stress.py --dsh /absolute/path/to/dsh --mode standard --summary /tmp/dsh-profile.json` (repeat `ptc`, `minimal`, `creator`) | Actual launch plan, selected dependency execution, override order, deselection, fail-closed broken bundle and source immutability. No cloud requests. |
| Native report guard | `python3 scripts/dsh_report_stress.py --dsh /absolute/path/to/dsh --summary /tmp/dsh-report.json` | Four modes × direct/plugin/MCP tool surfaces. Positive plugin/MCP controls, denied report execution, zero advertised schemas, retained history and completed report. No cloud requests. |
| Actual Swift + existing account | `python3 scripts/dsh_adapter_live.py --real-account --dsh /absolute/path/to/dsh --dsh-home /absolute/path/to/existing/.dsh` | Four modes, at most eight account Flash low/off prompts and concurrency two. Start → response → stop → guarded resume → recall. Production adapter, framing, process and Shell code; App/MCP shell discovery remain explicitly shimmed. Real-account authorization required. |
| Full app compile | `xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration Debug -skipPackagePluginValidation build` | `BUILD SUCCEEDED`; retain full log and source identity. Does not install or launch. |
| Timeline algorithm/regression checks | `python3 scripts/timeline_performance_checks.py` | Existing 20,000-update, restoration/invalidation/stale-generation and visibility/repair/cancellation assertions. Not a UI latency benchmark. |

`acp-two-turns` and `acp-cancel` are simulated non-DSH ACP regression cases, not real-service compatibility evidence. Existing OMP scripts concern another adapter; do not use their pass count as DSH or shared ACP acceptance.

## App workflow acceptance — requires explicit launch permission

Run the current worktree build, not the installed older Dev edition. Do not quit/relaunch the user's installed Tivano, install, package or merge as a side effect. Use the existing isolated CaptureRun mechanism for synthetic probes; real provider workflows need a separately isolated test library and the deliberately shared external DSH account.

Required functional checks:

- Existing sign-in, manual relogin and custom DSH_HOME login destination/cancellation. Do not invalidate a working account merely to manufacture a failure.
- Model picker default/effort, sanitized catalog error and retry, rapid key changes with stale-result cancellation, and safe process replacement at turn boundaries.
- Four modes, streaming/stop/resume, real tools and MCP (including a failing peer), long output, approvals and incremental inputs, correct completed/failed edit presentation.
- Actual Hydra lead/head scheduling, recovery and final-report transition with preserved history and no tools; no nested delegation leakage.
- Inherited custom-plugin behavior and **marketplace bundle composition**. Supported rc.2 composition now passes 16 fixture cases; arbitrary packages and Creator management/development workflows are not thereby accepted. See `dsh-runtime-contracts.md`.
- Representative other ACP providers after shared lifecycle/event changes.

The owner has authorized an isolated current-source Dev launch with the existing account. The DEBUG opt-in is `--website-captures <fresh-dir> --dsh-integration-probe --dsh-test-executable <absolute-cli> --dsh-test-home <existing-home>`. The real App probe completed eight turns across four modes; that prompt budget is consumed. The initial locked-screen attempts were blocked. Unlocked history-only replay subsequently produced four inspected screenshots without provider requests, and the existing foreground probes completed their gates. Do not repeat account prompts merely to obtain pictures. App Hydra quick and real-duration budget scenarios now pass with simulated ACP; native tools/MCP through App and matched pre-change performance comparison remain separate acceptance items.

## Existing performance probes and criteria

1. **SettingsInteractionProbe:** an optimized (`-O`) Debug build launched with `--website-captures <isolated-dir> --settings-interaction-probe`. See `docs/performance/overnight-2026-10-18.md` and `Tivano/App/Captures/SettingsInteractionProbe.swift`. All five phases must complete: idle page switches, idle heartbeat, loaded switches, covered-load heartbeat, visible-chat heartbeat. Its window/foreground, unchanged display geometry, active three-session workload and visibility guards must pass. Retain `settings-interaction.json`, source/binary identity and screenshots. `--settings-probe-captures` adds three stills and `settings-visual.json` only after measured phases and load cleanup; it does not establish pixel coverage during timing samples.
2. **HeavyLoadProbe:** existing three-session capture paths in `Tivano/App/Captures/HeavyLoadProbe.swift`; stationary text flags are `--stationary-load-probe --text-only-load-probe`. Exact final text must reconcile all 240 deltas per thread; the segmented-tool variant additionally reconciles 20 completed tool groups per thread. Retain all three phases and the existing phase-duration, movement and completion guards. Stationary replay is not real-wheel acceptance. See `docs/performance/three-session-replay-results.md`.
3. Compare unchanged workload, window, display, typography, normal materials and persistence assumptions against the established baseline using repeated A/B/A or paired foreground runs. Report heartbeat and interaction p50/p95/max, CPU window and callback counts separately. Do not call heartbeat intervals FPS or input-to-photon latency. Profile-only/locked-screen/invalid trajectories must be labelled, not mixed into timing comparisons.

The cited code has correctness/admission gates and reports timing; it does **not** define a universal numeric DSH CPU/RAM/p95 pass threshold. The historical 5.1 ms median and 17.7–19.6 ms p95 are observations, not newly invented cutoffs. If another owner-approved performance gate is supplied, retain it exactly. No GUI or performance acceptance can be inferred from the no-launch checks above.
