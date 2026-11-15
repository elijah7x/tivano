# Product captures

`scripts/product_captures.py` builds an isolated Debug app, captures the existing product scenes and writes resized PNGs. Run it only when the owner explicitly authorizes launching a capture instance. A request to edit, merge, build or validate code does not authorize captures or an app launch.

## Output location

Each invocation reserves a new directory before building or launching anything:

```text
<artifact-root>/private-artifacts/product-captures/<run-id>/
```

The run ID contains a UTC timestamp, process ID and random suffix. Raw PNGs, JSON framing sidecars and `run.log` live in that directory; resized PNGs go in its `processed/` subdirectory. Printed output paths are absolute.

By default, the script obtains the shared Git directory with:

```sh
git -C <checkout> rev-parse --path-format=absolute --git-common-dir
```

The parent of that shared `.git` directory is the long-lived source checkout; its parent is the artifact root (the wrapper containing the checkout). This also works from a linked worktree: the artifact root is not derived from the worktree's parent, so captures do not accumulate under `.tivano/worktrees`.

Build products remain local to the current checkout/worktree in `build.noindex/product-captures-build`. The Debug app path and capture scenes, isolated app storage/defaults, app arguments and timeout behavior are unchanged. Production libraries and credentials must not be imported into the capture instance.

## Choosing another location

Set `TIVANO_ARTIFACTS_ROOT` to an absolute wrapper path to change the default artifact root. Relative values, including an empty value, are rejected. Both the configured root and the final output location must be outside the current worktree and the long-lived source checkout; checks resolve symlinks as well as checking the supplied path.

Alternatively, use `--output-dir <new-directory>` to select the exact run directory. Relative arguments are interpreted from the working directory. The environment root, if set, must still satisfy its contract. The selected directory must not already exist, even if empty; an existing file, symlink or dangling symlink is also rejected. Parent directories may already exist and missing parents are created as needed.

Path rejection happens before any build or app launch. The final directory is created without `exist_ok`, so two runs selecting the same directory cannot both proceed. A collision is an error, not an instruction to reuse or clear it. Importing the module does not select output paths, create directories, build or launch an app.

## Existing archives

The script never clears a previous capture directory or the shared archive root. Completed and failed runs remain available for deliberate review or separately authorized cleanup. The old `build.noindex/product-captures` location, including any compatibility symlink left by migration, is not reused. Passing that historical symlink as `--output-dir` is an error; choose a fresh external directory instead.

## Privacy prompts on build hosts

macOS stores privacy grants (for example access to removable volumes) per bundle ID and code signature. A capture build that shares the installed Dev bundle ID but is signed ad hoc is identified by its cdhash, so each rebuild replaces the installed Dev's grant and prompts again. Over SSH the login keychain is locked and Developer ID signing fails with `errSecInternalComponent`; build in the logged-in GUI session instead (for example a short-lived launch agent bootstrapped into `gui/<uid>`), so the capture app carries the same Developer ID signature as the installed Dev and reuses its grant. Do not move builds or runs to another disk to avoid the prompt.

## Timeline stress runs

In addition to product scenes, `--website-captures <folder>` accepts `TimelineStress` flags in Debug builds:

- `--timeline-stress`: Runs the general chat-timeline jitter, grow, wheel-scroll, thread-switch, window-resize, occlusion and composer stress sequence.
- `--history-scroll`: Seeds 60 turns and exercises slow and fast upward scrolling through earlier history pages.
- `--held-drag` (and `--held-drag-hid`): Seeds 24 turns, streams a steady reply (rehearsed deltas with no provider session, looping in external-HID mode across the driver handshake and post-ended tail), and drives a synthetic phased wheel sequence (`mayBegin`, `began`, 1.5s slow upward `changed`, 3.0s resting pause with no events, 1.5s more `changed`, `ended`, then 4.0s more streaming). When `--held-drag-hid` is passed alongside `--held-drag`—or automatically when `cgEvent.postToPid` / `NSApp.postEvent` fail the local `.scrollWheel` monitor's `event.window === window` check—the app writes `held-drag-ready.json` (`pid`, `windowNumber`, `point`, `upSign`, `readyAt`, `readyAtWallClock`) to the run directory and waits up to 30s for real WindowServer-routed events on the timeline window. From a process with `CGPreflightPostEventAccess() == true`, compile and run `scripts/fixtures/held_drag_driver.swift` (`swiftc -O held_drag_driver.swift -o held_drag_driver && ./held_drag_driver <run-dir>`) to warp the cursor and post `.cghidEventTap` phased scroll events. Writes `stress.json` and `held-drag-samples.json` (both ~16ms viewport samples—with stages derived from observed events in external-HID mode—and `observedEvents`) plus `PASS`/`FAIL` violation counts.
  - `--held-drag-quiet-hold` pauses the reply while fingers are down and resumes it after `ended`; with `HELD_DRAG_INTERVAL_MS=120` for the driver the whole hold stays within 48pt of the end. This isolates the drag timeouts: fast growth alone moves any reader out of a follow band. Before the fix this variant snapped the reader back during the pause.
  - **What `--held-drag` / `--held-drag-hid` proves**: Real WindowServer `.cghidEventTap` routing into `ScrollViewProbe`'s local `.scrollWheel` monitor with `event.window === window` matching, `isTrackpadHeld`, `notePhase`, and `.onScrollGeometryChange` unpinning holding the reader's viewport steady across a pause longer than the 2s/3s fallback timeouts while new text streams below.
  - **What it still does not prove**: Real trackpad finger physics (pressure, jitter, AppKit gesture coalescing/momentum curves) or an unattended provider turn (`autoStartedTurnToken` `isRunning` `false -> true` mid-hold), which requires a live provider session rather than rehearsed deltas.
