# Native dsh bounded checks

This Python-standard-library driver tests **dsh itself**, not Tivano's Swift adapter. It never installs packages or launches the desktop UI/login flow. Results and remaining gaps are in `docs/dsh-validation.md`.

## Offline

From the repository root, supply an installed executable and a reviewed contract:

```sh
python3 scripts/dsh_native_stress.py --dsh /absolute/path/to/dsh \
  --offline-contract scripts/fixtures/dsh_native/0.2.1-rc.2.json \
  --summary /tmp/dsh-native-offline.json
```

Uses temporary HOME/DSH_HOME, a loopback Messages API fixture and macOS `sandbox-exec`, allowing network access only to the fixture port. It never reads account credentials. Missing confinement or contract yields SKIP, not a pass.

The rc.2 contract is based on installed `dsh-llm-deepseek` source and earlier independent tool probes. For another version, review the contract first; do not derive expectations from the same run's output. Contract fields:

- `protocol`: `anthropic-messages`.
- `endpoint_environment`: `DEEPSEEK_BASE_URL`, verified in the installed provider. The driver sets it to the loopback `/anthropic` endpoint and uses a dummy API key.
- `patch`: optional verified profile patch, default `[]`. It must not install/update plugins; this is trusted configuration.
- `tools`: exact wire tool-name lists for Standard/PTC/Minimal/Creator, each with and without no-delegation.

Mode YAML is extracted from the actual `DshPatches.swift` constants, rejecting incomplete extraction. Argument order follows `DshCLI`: ACP profile, user/fixture patch, mode patch, no-delegation. Minimal omits no-delegation as production does.

Checks: all eight tool sets as received by the model; two processes sharing DSH_HOME but using separate cwd/session IDs; two marker turns each; close/resume and recall; cancellation with a held model response; direct process cleanup. The fake model reflects request history rather than maintaining its own session cache.

Tool names and model IDs are hashed in summaries. PTC's nested SDK functions, actual tool execution, plugin installation, and child processes that detach are not covered.

## Tool-free final-report contract

```sh
python3 scripts/dsh_report_stress.py --dsh /absolute/path/to/dsh \
  --summary /tmp/dsh-report.json
```

Runs four modes across direct tools, a registered plugin tool and a real local
stdio MCP tool (12 cases). It extracts the production `DshReportGuard` source.
Positive controls execute plugin/MCP tools first; the resumed report must reject
a forced tool call, expose zero tool schemas, retain history and finish. Full-access
permission mode prevents ordinary approval denial from masquerading as guard success.
PTC calls use the real `run_code` transport. Everything runs with isolated homes
and a loopback-only model, within the native runner's five-minute global deadline.
This covers plugin/MCP tool dispatch, not desktop marketplace package inheritance
or App Hydra scheduling.

## Existing account

```sh
python3 scripts/dsh_native_stress.py --real-account \
  --dsh /absolute/path/to/dsh --dsh-home /absolute/path/to/existing/.dsh \
  --summary /tmp/dsh-native-account.json
```

Never opens, copies or prints credential files. dsh uses the supplied DSH_HOME and existing desktop/web profile (desktop wins); HOME/cwd remain temporary. No API key, proxy or shell-hook environment is inherited. Review profile startup behavior before running: third-party plugins may have their own side effects. The driver does not install/update plugins or supply MCP servers.

Only Standard mode: account-route Flash with low/off reasoning, otherwise SKIP. Normal path sends six short marker prompts, with hard limits of eight prompts, two processes, 60 seconds per request and five minutes overall. No automatic retry, API-route fallback or login flow. Permission/client tool requests are denied; prompts request no tools. These measures do not enforce a tool-free sandbox inside dsh.

Replies remain in memory. Real errors/stderr are reduced to an error code and fixed diagnostic categories, never persisted raw. Non-JSON stdout is counted and ignored like Tivano's `StdioProcess`. New session IDs are reported immediately and retained in account storage for the lead to clean; existing sessions are never enumerated/deleted by the driver.

## Results and cleanup

JSON includes expected/actual/PASS/FAIL/SKIP and reasons. Exit codes: 0 all pass, 1 any failure, 2 skipped/blocked with no failure. Choose a dedicated summary path; it is overwritten.

Cleanup signals only owned process groups while their leader remains unreaped, then reaps it. Already reaped IDs are never signalled. Detached descendants and descendants remaining after an unexpectedly reaped leader are not verified. Global timeout kills owned groups; cleanup may extend slightly beyond five minutes.

The lead ran the rc.2 offline matrix and six account prompts. Neither establishes GUI correctness, arbitrary plugin compatibility, other versions, or end-to-end Tivano Hydra behavior.
