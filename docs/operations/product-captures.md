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

macOS stores privacy grants (for example access to removable volumes) per bundle ID and code signature. A capture build that shares the installed Dev bundle ID but is signed ad hoc is identified by its cdhash, so each rebuild replaces the installed Dev's grant and prompts again. Over SSH the login keychain is locked and Developer ID signing fails with `errSecInternalComponent`; build in the logged-in GUI session instead (for example a short-lived launch agent bootstrapped into `gui/<uid>`), so the capture app carries the same Developer ID signature as the installed Dev and reuses its grant. External and removable volumes add a separate Removable Volumes consent for every responsible process that touches them, so the build-host repository, task worktrees, DerivedData and capture/stress run directories belong on the internal disk. Helper binaries compiled for a run (for example `scripts/fixtures/held_drag_driver.swift`) should be built once to a stable path and signed with the same Developer ID (`codesign --force --sign '<Developer ID Application identity>' --identifier <stable-identifier> <binary>`) so their Accessibility/Post Event grant survives recompiles, instead of an ad hoc `swiftc` output that macOS treats as a new app each time.

## Timeline stress runs

In addition to product scenes, `--website-captures <folder>` accepts `TimelineStress` flags in Debug builds:

- `--timeline-stress`: Runs the general chat-timeline jitter, grow, wheel-scroll, thread-switch, window-resize, occlusion and composer stress sequence.
- `--history-scroll`: Seeds 60 turns and exercises slow and fast upward scrolling through earlier history pages.
- `--history-flick`: External-HID-only (`delivery=hid`) trackpad flick run. Seeds 60 turns on an unmounted thread, opens at the settled tail window, writes `history-flick-ready.json` (`pid`, `windowNumber`, `point`, `windowFrame`, `upSign`, `viewport`, `flicks` = 60, `readyAt`, `readyAtWallClock`) to the run directory, waits up to 30s for the external driver's first `.scrollWheel` event on the timeline window, and samples `P = documentHeight - clipMinY` every ~8ms until 1.5s after the last observed event (or budget). Build `scripts/fixtures/flick_driver.swift` once to a stable path and sign it with the same Developer ID as `held_drag_driver` (`swiftc -O scripts/fixtures/flick_driver.swift -o <stable-path>/flick_driver && codesign --force --sign '<Developer ID Application identity>' --identifier dev.tivano.flick-driver <stable-path>/flick_driver`) so its Post Event grant survives recompiles, then run `flick_driver <run-dir> [--drift]` from a process with `CGPreflightPostEventAccess() == true`. Per flick (60 flicks, 120ms apart), the driver warps to `point` and posts `.cghidEventTap` pixel events: `began(0)`, 12 `changed` events every 8ms (~0.25 viewport), `ended(0)`, `momentum begin` + 20 `momentum continue` events every 8ms decaying by 0.85 (~0.25 viewport), and `momentum end(0)`; passing `--drift` moves the pointer and event location on odd-indexed flicks down into the composer (~40pt above the bottom of `windowFrame`) for `changed`, `ended`, and momentum events to exercise gestures whose pointer drifts off the timeline (synthetic HID events are routed by each event's location, so drifted events never reach the timeline: this does not model AppKit's gesture latching and cannot test it). The app's local `.scrollWheel` monitor records every window event, segments flicks (`phase began` to `momentum end`, or `phase ended` when no momentum follows), compares `observed = P_end - P_start` against `injected` observed deltas, marks `clipMinY <= -contentInsets.top + 1` flicks `clamped`, tracks `frameJumps` (`|ΔP - observedDelta| > 40pt`), and writes `stress.json` (`history-flick-summary`), `history-flick-samples.json`, `history-flick.mp4`, and stills (`flick-bottom.png`, `flick-start.png`, `flick-end.png`). Passes (exit 0) when all 60 flicks arrive, at least two history pages load during them, no frame jump exceeds half a viewport (`pageJumps == 0`: a page landing uncompensated) and no stills are missing; per-flick discrepancy and smaller frame jumps are reported only, since overlapping momentum makes their segmentation swing by tens of points (exit 1 on fail, no events, or missing stills; exit 2 when blocked or out of time). Does not prove real finger physics or AppKit-generated momentum from physical hardware, which differs from synthetic momentum events.
- `--held-drag` (and `--held-drag-hid`): Seeds 24 turns, streams a steady reply (rehearsed deltas with no provider session, looping in external-HID mode across the driver handshake and post-ended tail), and drives a synthetic phased wheel sequence (`mayBegin`, `began`, 1.5s slow upward `changed`, 3.0s resting pause with no events, 1.5s more `changed`, `ended`, then 4.0s more streaming). When `--held-drag-hid` is passed alongside `--held-drag`—or automatically when `cgEvent.postToPid` / `NSApp.postEvent` fail the local `.scrollWheel` monitor's `event.window === window` check—the app writes `held-drag-ready.json` (`pid`, `windowNumber`, `point`, `upSign`, `readyAt`, `readyAtWallClock`) to the run directory and waits up to 30s for real WindowServer-routed events on the timeline window. From a process with `CGPreflightPostEventAccess() == true`, compile and run `scripts/fixtures/held_drag_driver.swift` (`swiftc -O held_drag_driver.swift -o held_drag_driver && ./held_drag_driver <run-dir>`) to warp the cursor and post `.cghidEventTap` phased scroll events. Writes `stress.json` and `held-drag-samples.json` (both ~16ms viewport samples—with stages derived from observed events in external-HID mode—and `observedEvents`) plus `PASS`/`FAIL` violation counts.
  - `--held-drag-quiet-hold` pauses the reply while fingers are down and resumes it after `ended`; with `HELD_DRAG_INTERVAL_MS=120` for the driver the whole hold stays within 48pt of the end. This isolates the drag timeouts: fast growth alone moves any reader out of a follow band. Before the fix this variant snapped the reader back during the pause.
  - **What `--held-drag` / `--held-drag-hid` proves**: Real WindowServer `.cghidEventTap` routing into `ScrollViewProbe`'s local `.scrollWheel` monitor with `event.window === window` matching, `isTrackpadHeld`, `notePhase`, and `.onScrollGeometryChange` unpinning holding the reader's viewport steady across a pause longer than the 2s/3s fallback timeouts while new text streams below.
  - **What it still does not prove**: Real trackpad finger physics (pressure, jitter, AppKit gesture coalescing/momentum curves) or an unattended provider turn (`autoStartedTurnToken` `isRunning` `false -> true` mid-hold), which requires a live provider session rather than rehearsed deltas.
