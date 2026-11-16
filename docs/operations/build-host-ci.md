# Build-host CI

After the owner merges into local `dev`, a dedicated build-host checkout polls
`owner/dev` over SSH every five minutes. A new commit runs
`scripts/verify.py --all`, with `--gui` enabled by default. Results are keyed by
the full commit hash. Before a release, the owner's `scripts/ci_gate.py` queries
that exact hash over SSH; a result for a different commit does not cover it.

The executor uses Python 3.9's standard library. It never pushes, fetches
`origin`, packages, installs or publishes. GUI checks may run isolated apps as
part of `verify.py`; they need a logged-in graphical session.

## One-time setup

On the build host, configure noninteractive SSH access to the owner and install
the prerequisites required by `verify.py` (including Xcode and a suitable Git).
Use a dedicated clone, never a development checkout: each run forcibly checks
out the target commit and removes untracked/ignored files except `build.noindex`.
All angle-bracket values below are placeholders; checkout and repository paths
must be absolute.

```sh
git clone --no-hardlinks --origin owner --branch dev \
  '<owner-ssh-alias>:<owner-repository>' '<ci-checkout>'
git -C '<ci-checkout>' config tivano.ci.owned true
```

Cloning with `--origin owner` sets the owner remote directly and leaves `origin`
unused. Keep the local `dev` branch created by this clone: `verify.py --all` still
resolves its default `dev` baseline.

Every run checks out the commit under test, so install the executor outside the
checkout and point it at the checkout with `TIVANO_CI_REPO`. Copy it again after
`scripts/thor_ci.py` changes on dev:

```sh
install -m 0755 '<ci-checkout>/scripts/thor_ci.py' '<executor-directory>/thor_ci.py'
```

The executor reads these values with `git -C <ci-checkout> config --get` before
each `poll` or `run`:

| Key | Default | Meaning |
| --- | --- | --- |
| `tivano.ci.remote` | `owner` | Configured fetch remote; `origin` is rejected |
| `tivano.ci.branch` | `dev` | Branch on that remote |
| `tivano.ci.owned` | `false` | Must be exactly `true` (case-insensitive) to modify this checkout |
| `tivano.ci.gui` | `true` | Include `--gui`; accepts `true` or `false` |
| `tivano.ci.timeout` | `10800` | Positive verification timeout in seconds |
| `tivano.ci.notify` | unset | Optional shell command run after finished records (`pass`, `fail`, `stale`) and >3 consecutive fetch errors (30s timeout) |
| `tivano.ci.repair-metal` | `false` | `true` lets each run reinstall Xcode's Metal Toolchain (~800 MB) when an Xcode update removed it; without it the app build fails in SwiftTerm's shaders with `missing Metal Toolchain` (manual fix: `xcodebuild -downloadComponent MetalToolchain`) |

Create a user LaunchAgent plist in `~/Library/LaunchAgents/` with the template
below. Replace the XML-escaped placeholders with actual values. Use the same
label in the filename, for example `com.tivano.build-host-ci.plist`. Create the
external log directory first. Supply a PATH containing the tools required by
verification; launchd does not load shell startup files.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.tivano.build-host-ci</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>&lt;executor-directory&gt;/thor_ci.py</string>
    <string>poll</string>
  </array>
  <key>WorkingDirectory</key>
  <string>&lt;ci-checkout&gt;</string>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>&lt;verification-tool-search-path&gt;</string>
    <key>TIVANO_CI_REPO</key>
    <string>&lt;ci-checkout&gt;</string>
  </dict>
  <key>StandardOutPath</key>
  <string>&lt;external-log-directory&gt;/build-host-ci.out.log</string>
  <key>StandardErrorPath</key>
  <string>&lt;external-log-directory&gt;/build-host-ci.err.log</string>
</dict>
</plist>
```

Load it from the logged-in user's session:

```sh
launchctl bootstrap "gui/$(id -u)" '<launch-agent-plist>'
```

On the owner, configure the repository used to release:

```sh
git -C '<owner-repository>' config tivano.ci.host '<build-host-ssh-alias>'
git -C '<owner-repository>' config tivano.ci.root '<ci-checkout>'
git -C '<owner-repository>' config tivano.ci.executor '<executor-directory>/thor_ci.py'
git -C '<owner-repository>' config tivano.ci.label '<launch-agent-label>'
```

These keys are consumed by `scripts/ci_gate.py`. `ci_gate.py kick [rev]` queues
that exact commit with `thor_ci.py request` and starts the launch agent with
`launchctl kickstart`, so the run gets the agent's session and PATH, and reports
whether the build host was idle (started) or busy (queued behind the running
SHA). `ci_gate.py rerun [rev] --only a,b` uses the same path to queue a
per-check rerun for a failed commit whose build passed. `poll` drains queued
requests and the configured branch tip in a loop while holding the lock until
nothing new remains. `ci_gate.py check --wait` tolerates up to 5 consecutive SSH
failures before aborting and prints state changes with elapsed time once per
change. SSH must work without interactive prompts in both directions: build host
→ owner for fetch, and owner → build host for status.

## Results and manual commands

The default artifact root is the parent of the long-lived source checkout,
derived from the physical Git common directory, including when invoked from a
linked worktree. `TIVANO_ARTIFACTS_ROOT` can override it with an absolute path
outside every source checkout. Both the root and its `ci-results/` child are
checked after resolving symlinks. If overridden, set the same environment in
the LaunchAgent and all manual/SSH status invocations; a LaunchAgent environment
variable alone does not propagate to SSH sessions.

```text
<artifact-root>/ci-results/<full-sha>.json
<artifact-root>/ci-results/<full-sha>.log
<artifact-root>/ci-results/latest.json
<artifact-root>/ci-results/latest-error.json
<artifact-root>/ci-results/poll.log
```

JSON is written through a temporary file and atomic replacement. Records contain
`sha`, `subject`, `state`, UTC ISO-8601 `started_at`, `pid`, and `host`. Final
records add `finished_at`, elapsed `seconds`, `verify_exit` (null if unavailable),
`artifacts` (null if unavailable), `failed`, and `environment` with
`sw_vers`, `swift` (the first compiler-version line), and `git`. Failures include
`reason`. `failed` includes `build` and all checks whose summary status is neither
`PASS` nor `not selected`. The final `Artifacts: <path>` line in the verification
log locates `summary.json`; missing or invalid summaries fail the run even if
verification exits zero. The original verification artifacts stay at that path.

When the nearest first-parent `pass` ancestor within 30 commits has an identical
`environment`, the diff only touches `CHANGELOG.md` or version keys in
`config/dev.xcconfig`/`config/release.xcconfig`, and no `verify.py` `CHECKS`
trigger matches those paths, `thor_ci.py` records a `pass` with `reused_from`
and `reason: version/changelog-only diff` without running `verify.py`.

```sh
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' poll
git -C '<ci-checkout>' fetch owner --prune
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' run '<full-sha>'
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' run '<full-sha>' --only 'check_a,check_b'
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' run '<full-sha>' --force
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' status '<full-sha>'
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' latest
```

`run` uses an already-fetched commit and never fetches. Both `poll` and `run`
skip existing `pass`/`fail` records; `run --force` replaces the selected commit's
record and log with a fresh attempt. `run --only a,b` reruns only those checks
with `verify.py --only a,b --skip-build [--gui]` for a `fail` record whose build
passed, merges the new check statuses into `summary.json` and the record,
appends `reruns` history (`check`, `old_status`, `new_status`, `time`), and marks
the record `pass` only when every check in the merged summary is `PASS` or
`not selected`. No result records are deleted automatically. `latest` contains the
most recently started/completed run, including `running`.

`status` accepts exactly 40 hexadecimal characters and prints one JSON line:
`sha`, `state` (`pass`, `fail`, `running`, or `missing`), plus any recorded
`finished_at`, `started_at`, `failed`, `reason`, `artifacts`, `environment`,
`reused_from`, `reruns`, and `latest_error` (when `latest-error.json` exists).
A missing record without an active error is `{"sha":"<full-sha>","state":"missing"}`.
Valid status requests always exit zero; usage errors exit 2. Unreadable/invalid
records return `fail` with a diagnostic `reason`. `latest` prints the full latest
record, or `{"state":"missing"}` when none exists.

## Disk placement and retention

Keep `<ci-checkout>`, the build-host repository and `<worktrees-dir>` on the
internal disk: external and removable volumes require separate Removable Volumes
consent for every responsible process that touches them (see the Privacy prompts
section of `docs/operations/product-captures.md`). External disks are for
archives that no running process needs.

A host-local janitor (a launch agent outside the repository, configured per host)
prunes disposable data after tasks:

- In `private-artifacts/verify/`, keep the newest few runs intact and reduce
  older runs to `summary.json` and the top-level `*.log` files (per-check
  subdirectories are scratch homes and caches).
- Remove a task worktree's `build.noindex/` once nothing in it changed for 24
  hours (rebuildable).
- The CI checkout's own `build.noindex/` caches under fixed names are reused
  across runs and are not pruned by age.
- Never delete worktrees, source, capture archives under
  `private-artifacts/product-captures/`, stress result directories or release
  evidence.
- Log a warning when free space on the internal disk drops below a threshold.

## Offline hosts, errors, notifications and interrupted runs

A nonblocking lock at `ci-results/.lock` prevents overlapping runs. A busy
invocation prints `busy` and exits zero. When the owner is offline or fetch
fails, `poll` appends one timestamped line to `poll.log`, writes
`latest-error.json` (`time`, `message`), and exits without using an older
remote-tracking commit. Unreachable queued requests are also kept with an error
note and recorded in `latest-error.json` until resolved or older than 24 hours.
Completed verification failures are retained and require a new commit,
`run --only`, or `run --force`.

If `tivano.ci.notify` is configured on the build host, `thor_ci.py` runs that
shell command (30s timeout) with `TIVANO_CI_STATE`, `TIVANO_CI_SHA`,
`TIVANO_CI_SUBJECT`, `TIVANO_CI_FAILED`, and `TIVANO_CI_REASON` after every
finished record (`pass`, `fail`, `stale`) and on fetch errors lasting more than
3 consecutive polls. Notification failures are logged to `poll.log` and never
change a run result.

Verification runs at normal scheduling priority. A timeout kills the
verification process group and its descendants, then records failure. SIGTERM or
Ctrl-C records `reason: interrupted`. On the next locked invocation, `expire_stale`
marks abandoned `running` records `stale` as soon as the recorded `pid` is gone
or the lock is not held (with `timeout + 600` seconds kept as a backstop). A
busy executor does not mark records stale. `poll`/`run` exit 1 for a new
verification failure or setup error; the JSON result is the release gate's source
of truth.
