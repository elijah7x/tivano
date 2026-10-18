# Native DSH through the App (offline)

This fixture is implemented but **has not been built, run or checked**. It uses the installed native DSH and a local Messages API, not an ACP simulator or a standalone Swift adapter harness. No existing DSH profile is installed, edited or copied.

## Lead wiring required

In `Tivano/App/Captures/WebsiteCaptures.swift`:

- At the very beginning of `prepare()`, before `DshCaptureReplay` and all integration branches, insert:
  ```swift
  if DshNativeIntegrationProbe.isRequested {
      DshNativeIntegrationProbe.prepare()
      return
  }
  ```
- At the very beginning of `run(model:)`, before the same branches, insert:
  ```swift
  if DshNativeIntegrationProbe.isRequested {
      await DshNativeIntegrationProbe.run(model: model)
      return
  }
  ```

The startup caller must reach `prepare()` before constructing AppModel, MCPStore, settings or LibraryAccess whenever the raw `--dsh-offline-native-probe` flag is present, **even when CaptureRun arguments are missing or invalid**. If it only calls WebsiteCaptures for a valid CaptureRun, add that raw-flag admission guard at startup; otherwise malformed opt-ins cannot be guaranteed to exit before user-library initialization. Do not launch until this ordering is confirmed. The new Swift file must be included by the task build's source discovery.

`ProviderRegistry.swift` adds only the DEBUG/CaptureRun native opt-in, isolated-path admission and an allowlisted dummy-key/loopback environment. `MCPHub.swift` uses that environment for the opted-in fixture's stdio discovery instead of login-shell credentials. Other probes and ordinary capture behavior retain their existing branches.

## Runner

Plan only, no app launch:

```sh
python3 scripts/fixtures/dsh_app_native/runner.py
```

After the lead wires and builds the current Dev source, explicit execution:

```sh
python3 scripts/fixtures/dsh_app_native/runner.py --run \
  --app /absolute/task-products/Tivano\ Dev.app \
  --build-root /absolute/task-products \
  --source-identity 'lead-recorded revision plus uncommitted-diff identity' \
  --dsh /absolute/installed/dsh \
  --dsh-runtime-root /absolute/installed/node_modules/@deepseek-ai/dsh
```

The runner checks the Dev bundle name, confines its executable to the explicit build root and rejects `/Applications`. Source equivalence is a lead attestation, not inferred from a binary hash. A fresh random canonical `/private/tmp/tivano-dsh-app-native-*` contains HOME, DSH_HOME, temporary files, scratch project and all evidence. There is deliberately no output-directory reuse option. App preparation checks pristine homes, manifest/binary/fixture hashes and rejects symlinks before writing its isolated library and normal custom-MCP configuration.

The sandbox allows only the allocated model loopback port; public network and inbound listeners are denied. User-home reads are denied except the exact task app, installed DSH package and fixture-code directory. Writes are limited to the new output directory and `/dev/null`/`/dev/tty`. Python/Node installations or package layouts that require other user-home paths fail closed; do not broaden this to the whole home or remove the sandbox. The app's unused MCP OAuth proxy may be unable to listen; this stdio fixture does not require it.

The supervisor remains alive as the owned process-group leader. The runner records observed descendants and signals only matching PID/start-time identities at exit or timeout. The App also stops its four runtimes and shuts down its Hub. Evidence directories are retained, never recursively deleted. Total launch allowance is 285 seconds plus bounded cleanup, below five minutes; the App cancels its work at 270 seconds. Production request deadlines, runtime permissions and budgets are unchanged. No retries are added.

## Evidence and gates

Four modes each run these four bounded turns in one native session:

| Scenario | Independent evidence | App evidence |
| --- | --- | --- |
| file | Exact marker in `<mode>-file.txt`; no extra scratch files | Completed turn and completed tool, no failed tool |
| mcp | Exactly one `effect` record from the actual stdio peer, exact `<mode>-mcp.txt` contents, matching native tool-result marker | Completed turn/tool and stable session ID |
| tool-failure | Bash exits 17 without writing; no unexpected scratch edits | At least one failed tool; no completed edit paths |
| bad-mcp | Actual peer returns `isError`, exactly one independent failure record and matching native tool-result marker | Failed tool visible; same session ID, not a silently reopened session |

PTC emits actual `run_code` wrapping the tool call; reconciliation requires `run_code` in the advertised schema and App tool evidence, as well as the matching native returned tool-use ID. The model server never executes the tool itself. MCPStore loads normal `custom-mcp.json` and `mcp.json`, exports normal provider config, and MCPHub independently discovers the fixture. ACPSession receives that normal export; native DSH owns the actual MCP execution process. No direct ACPSession calls are made by the probe.

Approvals are resolved only through `ThreadRuntime.resolve`, only for a request containing this run's marker and an approve-once option. IDs/options/details are recorded. No request means **approval coverage is absent**, not approval passed. Unknown requests stop the probe without approval.

Evidence: `manifest.json`, `app-result.json`, `model-events.jsonl`, `mcp-events.jsonl`, `owned-processes.json`, `app-process.json`, `app-exit.json`, `app.log`, scratch contents and reconciled `result.json`. The final status is deliberately `reconciled-with-cleanup-limit`, not unconditional PASS. Request completion, model claims and file existence alone cannot satisfy reconciliation.

## Remaining limits

- Nothing here has been executed or checked; API/Swift integration and sandbox compatibility require lead validation.
- Broken **MCP calls** are covered; malformed initialization, startup failure and proof of no MCP config removal/reopen at the ACP wire level are not implemented. Stable App session IDs and exactly-one side effects catch replacement/duplicate execution but are not a complete wire trace.
- Cleanup records all observed owned descendants. A detached process escaping observation is not proven absent; this prevents an unconditional cleanup acceptance claim.
- The sandbox prevents user-home credential reads during the run; fixture admission itself does not prove an independently launched App inherited the runner's sandbox.
- No cloud-model decisions, screenshots/UI interactions, arbitrary plugins, performance acceptance or real-account approvals are covered. No account request budget is consumed.
