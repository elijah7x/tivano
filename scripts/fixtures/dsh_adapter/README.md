# DSH adapter fault fixtures

Run from the repository root on macOS with the project's Xcode toolchain:

```sh
python3 scripts/dsh_adapter_stress.py
# Optional single case:
python3 scripts/dsh_adapter_stress.py --case selection-timeout
```

The entry point compiles real Swift sources, then runs each case in a separate
process. It does not launch Tivano or real DSH. All generated files, HOME,
DSH_HOME, temporary directories, module caches and logs live under a unique
`build.noindex/dsh-adapter/run-*` directory. `sandbox-exec` denies networking and
writes outside that directory; the runner refuses to proceed without it.
Environment inheritance is restricted to DEVELOPER_DIR. No credentials are read
by the fake peer. The sandbox is a write/network boundary, not a general read
sandbox for the compiler.

`kit/sources.json` lists every compiled source, extracted declaration, SHA256 and
shim. `kit/compile-command.json` records the exact compiler invocation. The real
ACPSession, DshCLI, DshPatches, JSONRPC, StdioProcess, framing, selection and
deadline implementations are compiled without edits. Timeline declarations and
ProviderStatus are extracted verbatim, following the OMP fixture pattern.
Shims cover App contexts, attachment import, login environment, Shell composition
responses and static MCP configuration. MCP servers are named fixture data; no
server is launched. Patch-validation cases exercise real diagnostic parsing against
synthetic `--dump-config` results. Guard readiness is simulated here; the separate
native report suite executes the real plugin. Version checks are not covered.

Each fake child records inbound JSON-RPC frames (method, session ID and typed
request/response ID) in `wire-*.jsonl`. Case `result.json` contains event and wire
observations. Root `summary.json` contains expectations, observations, timeout,
exit status and overall result. Any failed or blocked case makes the runner exit
nonzero. A setup/compiler failure marks every selected case blocked. Individual
case failures never skip later cases.

Cases cover two sequential turns with duplicate replies; auth, lock and missing
resume failures; mixed healthy/broken MCP; foreign session message/permission
isolation; unanswered send-selection and probe-selection; incremental approval
arguments; failed edit/write final state; integer/string approval identities;
two concurrent adapters; interrupt; repeated start/stop cleanup; non-Pro model
default preservation; and public model probing.

Assertions describe desired behavior, not current implementation. In particular:
missing history must be surfaced rather than silently replaced; a mixed MCP
failure must be surfaced or selectively retried, never discard healthy servers;
failed file operations must not remain as actual edits; and an advertised current
non-Pro model must retain its default marker. These policy assertions may expose
intentional current behavior and require the lead's product decision, not a
fixture change to make the run green.

The external case limit is 60 seconds, above the production 45-second startup
request deadline. No production timeout is shortened or replaced. Hung cases
fail and are terminated externally. Each fixture also watches its unique lease;
revoking it exits only that fixture, including an orphan from repeated start.
The runner never kills processes found by name or stale recorded PID. The fake
peer creates no descendants and does not detach. Cleanup failures are reported.

The expanded matrix adds failed-start cleanup, unsupported resume, recovery permissions,
resume deadlines, repeated cancel/rebuild, report readiness, incremental tool kind,
probe default restoration, unavailable credential routes, 6,000-delta flood, local
credential records, patch invalidation and simulated non-DSH ACP turns/cancellation.
The repaired suite passes 33/33; the original baseline was 4/17. See
`docs/dsh-validation.md` for source-linked evidence and remaining limitations.

## Native marketplace composition

`python3 scripts/dsh_profile_stress.py --dsh /absolute/path/to/dsh --mode standard --summary /tmp/dsh-profile.json` compiles `ProfileHarness.swift`, calls production `DshCLI.prepareLaunch` and runs its returned executable/arguments/environment with an isolated profile and loopback model. Repeat with `ptc`, `minimal` and `creator`. All modes retain selected/dependency, user-override, deselected and broken-bundle assertions, including source immutability. PTC uses the actual `run_code` surface. This is not the App or arbitrary-package acceptance.

## Actual Swift adapter with the existing account

```sh
python3 scripts/dsh_adapter_live.py --real-account \
  --dsh /absolute/path/to/dsh --dsh-home /absolute/path/to/existing/.dsh
```

This separately authorized runner compiles production ACP/DSH/framing/process code
and the verbatim Shell/collector portion. It runs all four modes, with at most eight
account Flash low/off prompts and two concurrent sessions. Each remembers a synthetic
marker, stops, resumes through a report-only process and recalls it without tools.
It never opens a login window, copies credentials or installs plugins. Login-shell
discovery, App contexts and MCP configuration remain shimmed; it does not test the
Hydra coordinator or GUI. Existing profile plugins may execute their normal startup
behavior. Results, source hashes and limits live under `build.noindex/dsh-live/`.
Production request deadlines and a 60-second per-turn completion wait apply. A
five-minute Swift watchdog cancels the structured work and lets the real adapter
clean up; cleanup may extend beyond that window. It does not abruptly kill
Foundation's subprocess tree. `--compile-only` checks the harness without starting DSH.
Task-created session IDs are reported for the lead's narrowly scoped cleanup.
