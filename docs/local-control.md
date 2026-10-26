# Local-control CLI (Alpha, protocol v1)

Local control controls **an already-running Tivano**. It is off by default. In
Settings → Alpha, turn on both Alpha and Local control yourself. Closing either
gate stops listening and shuts down existing connections. It does not cancel
already-accepted turns or worktree preparation. Approvals and questions remain in
the App; clients can observe waiting but cannot approve, answer, log in or grant
permissions.

This is a **same-account capability**, not protection against malicious processes
with your UID. Other processes in your account can read exposed conversation
history and perform the allowed actions while it is enabled. Local control
itself has no TCP listener, background daemon, automatic App launch or direct CLI
access to library files. [Remote MCP](remote-mcp.md) is a separate Alpha gate that
serves the same commands to cloud agents over a loopback HTTP listener.

## Install, repair and remove the PATH entry

The native `tivano-control` helper ships inside each signed App's
`Contents/Helpers`, using the App's Developer ID team and hardened runtime.
Settings → Alpha → Install or repair CLI creates a symlink in `~/.local/bin`:

- Release: `tivano`
- Dev: `tivano-dev`

Installation, repair and uninstall are **explicit user actions**. None changes
Local-control permission. Tivano never edits shell startup files; add
`~/.local/bin` to PATH yourself if necessary. Symlinks handle spaces without shell
quoting. Repair after moving the App replaces only the link identified by the
saved installation receipt. An unrelated file/link is a collision, not permission
to overwrite it. Uninstall likewise removes only the receipt-owned link. Regular
updates at the same App path need no new PATH entry.

The helper's edition is compiled in, not selected with a CLI flag. Release and Dev
have distinct socket locations, instance handshakes, data owners and PATH names.
Do not copy a helper between editions.

## Commands

Examples use Dev; substitute `tivano` for Release. UUIDs are stable thread/project
identities, not sidebar names. The CLI's working directory is never an execution
directory.

```sh
tivano-dev info
tivano-dev providers
tivano-dev projects --limit 25
tivano-dev threads --archive active --role normal --limit 25
tivano-dev threads --affiliation standalone
tivano-dev threads --affiliation project --project PROJECT_UUID
tivano-dev threads --affiliation missing_project --role all --archive all
tivano-dev thread THREAD_UUID
tivano-dev history THREAD_UUID --limit 25
# Continue a page with the returned nextCursor:
tivano-dev history THREAD_UUID --limit 25 --cursor CURSOR

# No project means an explicit standalone task, not the current UI project.
tivano-dev create --workspace local --provider codex
# Explicit project checkout or new worktree:
tivano-dev create --project PROJECT_UUID --workspace local --provider claude --model MODEL_ID
tivano-dev create --project PROJECT_UUID --workspace worktree --provider codex

tivano-dev send THREAD_UUID --text 'Investigate the failure.'
printf '%s' 'Continue the investigation.' | tivano-dev send THREAD_UUID --stdin
tivano-dev send THREAD_UUID --text 'Continue.' --continuation providerSession
tivano-dev interrupt THREAD_UUID --turn TURN_UUID

tivano-dev operation 'INSTANCE_UUID/OPERATION_UUID/ISSUED_MILLISECONDS'
tivano-dev settings get
tivano-dev settings set textGeneration automatic
tivano-dev settings set antiSlopEnabled true
tivano-dev settings set performanceMode true
tivano-dev settings set showsSkylight false
```

`info` reports protocol/instance/edition, methods, limits and retention.
`providers` is a cached availability/capability summary, not a refresh or login.
It contains no account name, auth diagnostic, credential or environment. Unknown
authentication is reported as unknown and does not authorize submission. Provider,
model and negotiated session capabilities are checked again on a write. A model
option must be in the App's current catalog; refresh providers in the UI if needed.

Creation never inherits the selected thread's model, permissions, Hydra pair,
selection or draft. New threads use supervised permissions and Hydra off. A
provider that cannot operate supervised cannot be externally created. Ordinary
existing threads keep their current permissions; the CLI cannot change them.
Missing project records are errors, never standalone tasks.

A standalone task resolves to `StoragePaths.taskWorkspace(threadUUID)`; its
workspace is created on submission, not by queries. A project thread explicitly
uses either its project directory or its worktree. Worktree creation is
asynchronous: the operation and thread expose `preparing`, `ready` or `failed`.
Configured setup scripts must actually exit successfully before ready (at most
16 scripts, 120 seconds each, bounded diagnostic capture). Send is rejected while
preparing or failed. A failed checkout is retained for owner inspection, never
silently replaced with the project directory. Preparation interrupted by App
restart is marked failed rather than assumed successful. UI-created worktrees also
record pending/failed intent for CLI admission. A UI/legacy worktree whose setup
was only spawned in an interactive terminal has no observed completion boundary:
it is explicitly unsupported for CLI submission, not advertised ready. This does
not replace the UI's independent terminal workflow; worktrees created through this
CLI use the completion-observed path above.

Send is text-only. Slash-command input, attachments, queue/steering, helpers,
Hydra/head/voice targets, archived threads, reverting/busy runtimes, pending
provider-history operations, working children and unsupported targets are
rejected. Eligibility/configuration/directory are rechecked after asynchronous
boundaries. The external path uses the existing persistence/execution chain but
never consumes/repopulates the UI draft or silently queues a rejected message.
The App remains the sole runtime and Store owner.

### Continuation and outcomes

- `automatic`: fresh for an unsent thread; transcript reconstruction for native
  API providers; provider-session continuation otherwise.
- `fresh`: only an unsent thread with no prior conversation.
- `providerSession`: the exact persisted session, with no start-new fallback.
  A changed resume identity or unsupported resume fails explicitly. Process-only
  Antigravity/Command Code startup is not advertised as exact continuation.
- `transcript`: only native API providers. This is bounded user/assistant
  transcript reconstruction (not exact tool/session recovery).

An operation progresses through `accepted`, `preparing`/`ready` for workspace
creation, or `accepted`, `started`, `waiting`, `ended`/`failed` for turns. Adapters
may report completion without a separate started event. `started` is the
normalized adapter's turn event, not an assertion that useful work happened.
`completed` is the adapter/provider's completion report, **not proof that the task
was done correctly**. Method return, process liveness and emitted text are not
success tests. Waiting approvals/questions stay in the UI. Provider failures
retain safe categories; full provider diagnostics stay in the App, not in a
credential-bearing transport error dump.

Interrupt acceptance is not a stopped turn. Its outcome waits for runtime
finalization and any submission stack to unwind. `stopEvidence` distinguishes
`provider_reported_interrupted` from `runtime_ended_only`; the latter does not
independently confirm provider-process termination. Completion persistence
failure is reported as failure, even if the provider reported completed.

## Write tickets, disconnects and restart limits

Before delivery, the CLI prints a ticket to stderr:
`INSTANCE_UUID/OPERATION_UUID/ISSUED_MILLISECONDS`. Save it. stdout is a JSON
response envelope. Exit 0 can mean only acceptance; exit 2 is a transport/request
error, 3 a failed operation receipt, and 4 unknown outcome.

The ledger retains a canonical payload SHA-256 and outcome, not the submitted
text. Within one instance/window, the same ticket and payload returns its receipt;
a changed payload conflicts. There are at most 16 nonterminal operations and 256
receipts. Terminal receipts are retained for one hour from ticket issuance;
capacity rejects new writes rather than evicting an unexpired receipt. Pending
operations remain tracked (bounded) until they end. A first delivery more than
30 seconds after issuance is unknown and is not executed. This prevents a stale,
evicted ticket being mistaken for a new write. Deliberately minting a new ticket
is a new operation, not an exactly-once guarantee.

For a known ticket, an explicit `--operation TICKET` on the original command can
retrieve its same-payload receipt without repeating the mutation. **The client
never automatically retries a write.** After disconnect, query `operation TICKET`
first. The in-memory ledger does not survive App restart: an old query is unknown,
and an old ticket cannot write to a new instance. Expired or unknown outcomes
require owner reconciliation, not blind resubmission. Accepted history/thread/turn
identifiers help that reconciliation but are not a durable exactly-once ledger.

## Queries and pagination

- Threads: default active (`!isArchived`) and normal (`!isHelper && !isHydraHead`).
  Helpers exclude heads; heads take precedence over helper status. `all` is
  explicit. Affiliation is standalone only when projectID is nil; a non-nil UUID
  with no project record is `missing_project`.
- Search is case-insensitive **title metadata only**, never transcript search.
- Projects/threads are ordered by UUID string. Limit is 1–100. Metadata cursor
  membership/order binds the filter, App instance and library-index revisions;
  any index mutation invalidates it. Volatile runtime status is sampled only for
  the requested window. A single bounded ID cache avoids full-library DTO
  serialization for small pages. Libraries over 100,000 threads or 10,000 projects
  are rejected by this interface rather than allocating without a bound.
- History is **persisted-only**, strict and read-only. It never creates a runtime,
  provider or task directory, repairs/migrates a corrupt document, or forces a
  live runtime save. It uses Store serialization and a read-only projection.
  At most the 8 MiB head plus four 8 MiB turn files are read per page. Indexed
  bodies outside that window are not loaded. Oversize legacy heads fail explicitly.
- History limit is 1–50 entries. Indexed turns follow the stored reference order;
  embedded turns follow index/UUID order; unscoped notices are last. Within a
  group, ordering is position, date, then item ID. Text is a 4,000-byte excerpt
  with an explicit `truncated` flag; attachment bytes/metadata are not exported.
  A page may be short or empty with a next cursor due to the four-file bound.
- History cursors bind the exact persisted head hash, instance and thread. A
  changed head invalidates the cursor; restart pagination explicitly. Corruption,
  missing sent-thread documents and absent referenced turns are errors, never
  empty successful recovery.

## Typed settings

Only `textGeneration` (`automatic|claude|codex|off`), `antiSlopEnabled` (Bool),
`performanceMode` (Bool) and `showsSkylight` (Bool) are exposed. Invalid key/type
pairs are rejected before any setter runs. Writes use AppSettings setters, not
arbitrary defaults or view-only onChange behavior. Reads/writes return stored
preference and effective value separately where different.

Performance mode clears `clearerBackdrop`, matching the existing App setter; it
suppresses effective Skylight visibility without erasing `showsSkylight`.
Turning performance mode off restores that preferred visibility, but does not
restore the cleared backdrop setting. Text-generation effectiveness is the App's
no-preferred-provider choice; individual threads can prefer a different engine.
Anti-slop changes affect subsequent session signatures, not an accepted turn's
already-delivered policy.

## Transport and shutdown contract

The endpoint is under `/private/tmp/tivano-control-<uid>/<release|dev>/control.sock`.
Both account/edition directories are owner-only 0700, the socket is 0600, and both
peers check UID. Symlinks/permissive or foreign endpoint entries are rejected.
An owner-only flock lease prevents two listeners from stealing an edition's
endpoint. Only its lease holder removes a stale socket; stop unlinks only the
socket inode it created. Private directories/lease file are deliberately retained.

Frames are four-byte big-endian lengths followed by JSON. The first frame is a
version/edition/optional-expected-instance handshake; every subsequent request
also pins the negotiated instance. Limits: eight connections/active handlers,
one request in flight per connection, no pipelining, 128 KiB request, 1 MiB frame,
64 KiB text, and 30-second connection deadlines. The CLI uses a 15-second bounded
exchange, and `--stdin` has a 15-second/64 KiB bound. A connection flood cannot
create unbounded detached read handlers. Disabled control has no listener,
repeating poll or provider work; enabled idle does not poll the request handler.

Before the updater/quit flush boundary, the service stops admission and revokes
connections. A pending accepted mutation (including preparation and post-send
cleanup) refuses the flush rather than silently cancelling work or allowing
post-flush writes. Wait for the operation or stop it in the UI, then retry.
A failed flush/installer launch/refused handoff restores admission if the gates
are still enabled. Successful quit keeps it closed. A new App process always
requires a new handshake and has unknown old operation outcomes.

## Validation and owner-side gates

The maintained checks are build-only or synthetic non-GUI:

```sh
# Use fresh, external, sufficiently short artifact paths; never put these in source.
python3 scripts/local_control_checks.py /absolute/external/short-run
python3 scripts/local_control_domain_checks.py /absolute/external/domain-run
```

The first runs production protocol/socket/client/ledger/Store projection/installer
code with synthetic fixtures, plus both compiled-edition native CLI parser
checks. The second injects selected production App/runtime/settings declarations
verbatim into synthetic framework/provider/disk dependencies. Its front-door and
failure checks **do not execute a real provider or the full App**. Structural
assertions supplement, not replace, execution/persistence integration tests.
No harness initializes the App entry point or accesses a real library/account,
install directory or live updater. All fixtures, binaries, caches and logs go
under the supplied external artifact path.

Validation remains four rounds, not a fixed retry count:

1. Connection/isolation: disabled, handshake, wrong edition/instance/version,
   permissions, revocation, framing/connection/handler limits.
2. Functional: standalone/project/worktree readiness and actual setup completion,
   metadata/history pages, creation/submission/continuation/interruption, settings.
3. Failure/recovery: duplicate/simultaneous writes, disconnect, missing directory,
   persistence failure, restart/unknown receipts, shutdown/version mismatch.
4. Performance/regression: disabled vs enabled-idle vs controlled queries, bounded
   descriptors/memory, no unintended runtime/provider creation.

**Pending owner authorization/verification:** a successful prescribed signed
Debug xcodebuild and embedded-helper signature/link/resource verification; actual
App/GUI enable/disable/revocation; each real provider/model/session continuation
and interruption; approvals; real setup/persistence faults; moved-App PATH repair
and update/quit failure restoration; real disabled/idle/query performance and UI
regression measurements. Synthetic timings and type diagnostics are not passes
for these. Do not launch, package, install or exercise live update/provider paths
without the owner's separate authorization.
