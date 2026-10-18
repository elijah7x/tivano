# Offline App Hydra probe

Simulated ACP backend; no account requests, installed CLI, credentials, tool execution, MCP execution, installation, or app replacement. The implementing head did not run checks. The lead integrated, built and exercised the quick and full-duration budget scenarios; evidence and remaining limits are in `docs/dsh-validation.md`.

## Lead integration

In `WebsiteCaptures.prepare()`, before the existing `DshIntegrationConfiguration.isEnabled` branch:

```swift
if DshIntegrationConfiguration.isOfflineHydra {
    DshHydraIntegrationProbe.prepare()
    return
}
```

In `WebsiteCaptures.run(model:)`, before the existing integration-probe branch:

```swift
if DshIntegrationConfiguration.isOfflineHydra {
    await DshHydraIntegrationProbe.run(model: model)
    return
}
```

Keep these in the DEBUG capture path. The existing real-account probe must not run in this mode. Include the new Swift file in the app target if the project does not automatically include source files. The lead has wired both branches into WebsiteCaptures. Fixture execution does not modify production source.

## Operator commands

Supply a **current-source DEBUG Dev bundle** explicitly. The runner rejects installed application paths, the wrong bundle identity and binaries without the DEBUG fixture marker. It does not locate, build, install, quit, or replace an existing application. App and fixture subprocess networking is denied by sandbox. It directly starts a separate process with capture storage. `--source-revision` is an operator attestation, not proof that a binary matches the source. Bundle path, executable hash, version, selected source hashes, and the attestation are retained in `runner-plan.json`.

Plan only (does not create output or launch anything):

```sh
python3 scripts/fixtures/dsh_app_hydra/run.py \
  --app '/explicit/path/Tivano Dev.app' \
  --output /tmp/dsh-hydra-quick-unique \
  --source-revision '<revision-used-for-this-build>'
```

Quick coordinator run (usually seconds; outer limit 240 seconds):

```sh
python3 scripts/fixtures/dsh_app_hydra/run.py \
  --app '/explicit/path/Tivano Dev.app' \
  --output /tmp/dsh-hydra-quick-unique \
  --source-revision '<revision-used-for-this-build>' --run
```

Real budget-expiry run (**about 35–38 minutes**, outer limit currently 41 minutes):

```sh
python3 scripts/fixtures/dsh_app_hydra/run.py \
  --app '/explicit/path/Tivano Dev.app' \
  --output /tmp/dsh-hydra-budget-unique \
  --source-revision '<revision-used-for-this-build>' \
  --dsh-offline-hydra-budget --run
```

The budget runner reads `HydraBudget.maxSeconds` and `reportSeconds` from source and refuses unknown constant syntax. It never edits the thresholds or fakes time. The App uses those production constants directly. The outer deadline is their sum plus 180 seconds for startup/cleanup; the App coordinator allowance adds 120 seconds. Keep the machine awake for the budget run. Every invocation needs a fresh output path: `mkdir(exist_ok=False)` refuses reuse.

## What executes

The runner copies the fake CLI into `output/fixture/fake-cli`, creates a credential-free `fixture/home`, and records a fixed fixture ID, SHA-256, random marker and scenario. It creates an empty independent Git repository only in `output/scratch`, with system/global Git configuration disabled. Capture worktrees remain under the existing capture storage root. App preparation accepts these precreated fixtures but rejects existing capture storage, results or a started marker, unexpected home contents, mismatched hashes and fixture symlinks. No user repository is imported.

A real `AppModel` lead calls `ThreadRuntime.send()`. The fake lead emits one legal Hydra delegation; the real parser/coordinator creates the head. The head returns the random marker, the real completion/report route sends it to the lead, and the lead finishes its automatic second turn. No completed state is inserted and no completion coordinator is called directly. Both threads explicitly use DSH; other providers are disabled. At most two ACP processes can hold lifetime fixture locks, including catalog processes.

In budget mode the head keeps its first prompt open, emitting a small text heartbeat every 15 seconds. It waits for the real budget interruption. On ACP cancel it completes that original prompt as cancelled. Runtime then starts its report turn, replaces the process, and resumes the original session ID. Readiness is simulated only when actual launch arguments include the production-generated `report-guard.yml` inside the capture output. The fixture checks its guard ID and companion plugin file. It does **not** load or exercise that plugin. The lead's ordinary follow-up remains unguarded.

## Evidence and limits

- `dsh-hydra.json`: App stage, parent/head IDs, App assertions, production deadlines and coverage.
- `runner-result.json`: final combined result; failed invariants, peak process count, process exit evidence, timing and cleanup actions.
- `fixture/home/wire-*.jsonl`: process identity/PID, session ID, method, guard presence, role and scenario counts. No environments, full prompts or credentials are logged by the fake CLI. Session state stays in fixture home.
- `process.json`, `runner-plan.json`, `runner-stage.json`, `app.log`: launch identity, provenance, stage and app output. `preparation-error.txt` records a rejected fixture without overwriting an old result.

A quick run reports the budget scenario as **not-run**, never passed. A budget run reports quick mode as not-run. The runner checks unique independent head/lead sessions, prompt counts, report delivery, bounded ACP concurrency and exit records. Budget checks additionally require cancellation, a different head process, resume of the same ID, readiness and a production-length wait measured from the actual App head-turn start, without subtracting a startup tolerance. App checks cover one head, correct parent, no nested team, successful lead turns and interrupted-then-completed head turns in budget mode.

Only the newly launched App `Popen` handle may receive terminate/kill. Removing this fixture's lease asks its fake peers to self-terminate; the runner never kills by process name or trusts a logged PID for killing. Missing exit evidence fails the cleanup invariant. No existing app is quit. Output and scratch are retained for inspection.

A passing result proves only these simulated App/ACP paths. Native guard enforcement, MCP, tools, real authentication, UI and binary/source equivalence remain unverified. Compile errors, unconnected entry points, an old bundle, protocol drift or failed isolation checks must be fixed by the lead; do not reinterpret missing evidence as success.
