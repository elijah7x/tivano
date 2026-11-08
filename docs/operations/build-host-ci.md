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
`launchctl kickstart`, so the run gets the agent's session and PATH; the next
poll checks queued commits before the branch tip. SSH must work without
interactive prompts in both directions: build host → owner for fetch, and
owner → build host for status.

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
<artifact-root>/ci-results/poll.log
```

JSON is written through a temporary file and atomic replacement. Records contain
`sha`, `subject`, `state`, and UTC ISO-8601 `started_at`. Final records add
`finished_at`, elapsed `seconds`, `verify_exit` (null if unavailable),
`artifacts` (null if unavailable), `failed`, and `environment` with
`sw_vers`, `swift` (the first compiler-version line), and `git`. Failures include
`reason`. `failed` includes `build` and all checks whose summary status is neither
`PASS` nor `not selected`. The final `Artifacts: <path>` line in the verification
log locates `summary.json`; missing or invalid summaries fail the run even if
verification exits zero. The original verification artifacts stay at that path.

```sh
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' poll
git -C '<ci-checkout>' fetch owner --prune
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' run '<full-sha>'
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' run '<full-sha>' --force
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' status '<full-sha>'
TIVANO_CI_REPO='<ci-checkout>' /usr/bin/python3 '<executor-directory>/thor_ci.py' latest
```

`run` uses an already-fetched commit and never fetches. Both `poll` and `run`
skip existing `pass`/`fail` records; `run --force` replaces the selected commit's
record and log with a fresh attempt. No result records are deleted automatically.
`latest` contains the most recently started/completed run, including `running`.

`status` accepts exactly 40 hexadecimal characters and prints one JSON line:
`sha`, `state` (`pass`, `fail`, `running`, or `missing`), plus any recorded
`finished_at`, `started_at`, `failed`, `reason`, `artifacts`, and `environment`.
A missing record is exactly `{"sha":"<full-sha>","state":"missing"}`. Valid
status requests always exit zero; usage errors exit 2. Unreadable/invalid records
return `fail` with a diagnostic `reason`. `latest` prints the full latest record,
or `{"state":"missing"}` when none exists.

## Offline hosts and interrupted runs

A nonblocking lock at `ci-results/.lock` prevents overlapping runs. A busy
invocation prints `busy` and exits zero. When the owner is offline or fetch fails,
`poll` appends one timestamped line to `poll.log` and exits zero without using
an older remote-tracking commit. The next launchd tick retries. Completed
verification failures are retained and require a new commit or `run --force`.

Verification runs at niceness 10. A timeout kills the verification process group
and its descendants, then records failure. SIGTERM or Ctrl-C records
`reason: interrupted`. On the next locked invocation, abandoned `running`
records older than the configured timeout plus 600 seconds become failures with
`reason: stale`. A busy executor does not mark records stale. `poll`/`run` exit 1
for a new verification failure or setup error; the JSON result is the release
gate's source of truth.
