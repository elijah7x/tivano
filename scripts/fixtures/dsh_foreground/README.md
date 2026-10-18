# Foreground wheel and resource evidence

`../../dsh_foreground_acceptance.py` plans by default. `wheel_sampler.m` is an external, task-owned helper, not production code. Neither has been built, run, linted or tested by the Hydra head. The lead owns all verification and desktop operations.

## What it does

- Launches the explicit task bundle's real `CFBundleExecutable` with the existing `--website-captures <new-directory> --heavy-load-probe --manual-wheel-probe` protocol. No installation, `open`, bundle-ID lookup, activation of another app, provider or user-data access.
- Keeps the existing three phases (six-second idle-before, complete three-thread load, six-second idle-after), 240 deltas per thread, 20 completed assistant messages and 20 completed tools per thread, 321 events per thread, exact final-text/tool reconciliation and all probe guards. It does not shorten deadlines, modify the app, write offsets or increment acceptance counters.
- During the observed load phase only, posts pixel scroll events into the system HID event stream: nominal 10 Hz, alternating ±24 pixels each second of helper uptime. Classification is **injected-system-wheel**, not a hardware wheel, human interaction or input-to-photon measurement. `acceptedWheelEvents >= 2` and observed movement still come from the existing app monitor.
- Samples the owned PID with `proc_pidinfo` at nominal 100 ms intervals. Saves every RSS value, cumulative user/system CPU nanoseconds, process start identity, monotonic timestamp, actual interval and observed report phase. RSS is **not total memory footprint**. CPU utilization can be derived from differences in cumulative CPU divided by actual elapsed time; do not silently normalize to one core or substitute elapsed time for CPU.
- Saves the full resource/event stream in `samples.ndjson`, child output separately, lifecycle/provenance in `foreground-driver.json`, original probe JSON/PNGs unchanged, and separate raw-evidence/admission/performance sections in `foreground-analysis.json`. Exit zero is not performance or visual acceptance.

Phase labels are observations of the probe's atomic report, not exact boundaries. Every sample retains the observed `elapsedSeconds` and `phaseLog`; report changes can lag phase transitions, and screenshot/transition work can be attributed to the prior observed phase. Keep those transition samples, do not claim exact per-phase peaks from them. The final report can precede process exit; sampling ends at the last live sample, never fabricates post-exit RSS. The parent records and reaps its own child. Missing samples for any phase, identity changes, sampler failure, incomplete workload or failed guards block admission.

The probe intentionally emits `eligibleForTimingComparison=false` for external wheel input. This driver preserves that exclusion. Matching runs can support owner-reviewed wheel/resource evidence, not normalized callback-timing improvement or an automatic overall performance pass. Settings remains a separate existing probe, not a new case in this driver.

## Lead setup and run

1. Obtain explicit owner authorization to launch this task build **and inject system wheel events**. An authorization flag is an attestation, not permission by itself. Keep the desktop unlocked. Do not quit, relaunch, unlock or change permissions for any existing user app.
2. Use an already available task-local **`-O` Debug** CaptureRun-enabled bundle. Release ignores capture isolation flags and is prohibited. App and helper must resolve under the explicit task build root, either this checkout's `build.noindex` or a dedicated `/tmp/<task>` directory. Installed `/Applications` bundles, aliases resolving there and real data directories are rejected. Do not copy an installed old release to fake a baseline.
3. Build only the helper (the head did not do this):

   ```sh
   mkdir -p build.noindex/dsh-foreground-tools
   xcrun clang -O2 -fobjc-arc \
     -framework Cocoa -framework ApplicationServices \
     scripts/fixtures/dsh_foreground/wheel_sampler.m \
     -o build.noindex/dsh-foreground-tools/wheel_sampler
   ```

   API assumptions use the macOS SDK's `libproc.h` / `sys/proc_info.h`, ApplicationServices AX hit testing, CG window lists and CG event posting. The usual SDK header paths were unavailable in the head's copy; **SDK/API compatibility is unverified**, and the lead must compile and resolve any SDK availability errors before running. No runtime fallback to direct scroll manipulation is permitted.
4. Manually ensure the helper/launching terminal has Accessibility/event-posting and Screen Recording permission as required by macOS; the app's screenshot path also needs Screen Recording. The helper only preflights: it never prompts for or grants permissions. Permission failure stops **before app launch**. A later revocation blocks input. TCC identity can change after helper rebuilds.
5. Prepare a JSON conditions file outside the source tree. Every field below is required, with real values rather than these placeholders. Nested objects are allowed for the environmental fields:

   ```json
   {
     "sourceRevision": "exact revision of this binary",
     "localChanges": "none, or retained patch identity/hash and description",
     "buildCommand": "actual build command, not a proposed command",
     "optimization": "-O",
     "configuration": "Debug",
     "buildSettings": {"swift": "actual flags", "compiler": "actual version", "sdk": "actual SDK"},
     "architecture": "arm64",
     "os": "actual OS version/build",
     "hardware": "actual machine/chip/RAM and power conditions",
     "display": "display ID/model, refresh rate, resolution, scaling and arrangement",
     "window": "1200x800 points, origin, backing scale, foreground and unobscured",
     "fonts": "font family/size, dynamic sizing, locale and text-rendering settings",
     "materials": "dark; clearerBackdrop=true; opacity=0.5; upstream glass; wallpaper=false; performanceMode=false; record accessibility settings",
     "workload": "unchanged CaptureRun fixture; three segmented threads; 240 deltas, 20 tools and 321 events each; 50ms requested delta cadence",
     "persistence": "disabled per runtime after history load; fresh isolated fixture; disk-save cost excluded",
     "baselineRole": "current"
   }
   ```

   Preserve binary identity, build logs/settings and local patch identity. The script hashes the executable, helper and relevant protocol sources; operator-supplied provenance is not independently proven by a hash.
6. Establish a **visually inspected timeline region** for this fixed 1200×800 capture layout, in window-relative top-left screen points. Use a small interior rectangle within the main timeline, excluding composer, minimap, nested tools, overlays and title bar. Do not guess from these instructions or merely use the whole window. Existing same-layout screenshots/AX inspection can establish it; if no reliable geometry is available, the run is **blocked**, not a reason to weaken guards. Position the mouse there manually during the six-second warmup/idle-before; the helper never moves the pointer or activates windows.

   At every injected event the helper requires: report window guards; frontmost owned PID; the capture window number at the cursor as the first visible CG window; matching focused AX window bounds; cursor inside the attested rectangle; hit-test ancestry from the owned PID through a large AX scroll area containing that rectangle to that exact focused window. SwiftUI may not expose that ancestry; that is **blocked**, not a coordinate-only fallback. AX observation can be slow and is part of this driver's overhead. The guards are checked again immediately before posting. OS focus can still change between checking and delivering a global event; this is not an atomic routing guarantee. Keep the desktop undisturbed and reject any interrupted run.
7. Plan first (replace paths and `X Y W H` with actual values):

   ```sh
   python3 scripts/dsh_foreground_acceptance.py \
     --task-build-root "$PWD/build.noindex" \
     --app "$PWD/build.noindex/TaskBuild/Tivano Dev.app" \
     --helper "$PWD/build.noindex/dsh-foreground-tools/wheel_sampler" \
     --conditions /tmp/dsh-current-conditions.json \
     --output /tmp/dsh-current-wheel-unique \
     --timeline-region X Y W H
   ```

   With explicit authorization, append **all** of:

   ```sh
   --run --owner-authorized --authorize-system-wheel \
   --confirm-debug-capture --confirm-timeline-region
   ```

   Output must not exist; reuse is rejected even for an empty directory. The app has its original 120-second internal deadline; parent and helper retain 140-second outer deadlines. A blocked helper stops injection and causes the parent to stop only its direct app child. Ctrl-C terminates only this driver's children. If the driver itself is forcibly killed, the helper/app retain their own deadlines; do not use name-based cleanup.
8. Inspect **all three actual PNGs**, including the load image, and the live layout when authorized. Confirm timeline identity, unobscured foreground content, normal fonts/materials, selection appearance and lack of rendering corruption. Saved PNG paths, AX geometry and DOM-style inspection do not replace looking at the images. Retain the lead's dated notes next to the artifacts. No automated screenshot-review claim is emitted.

## Existing baseline leads and missing evidence

The following are references, not a valid DSH pre/post baseline:

| Material | What it establishes / what is missing here |
| --- | --- |
| `docs/performance/overnight-2026-10-18.md` | Describes `-O` Debug A (then-HEAD plus same probe) vs B (then-workspace), three alternating pairs and `run5-foreground`. Refers to `build.noindex/settings-probe/` and `build.noindex/scripts/{build_ab.sh,run_settings_probe.py,summarize.py,profile_probe.py,inclusive.py}`. Those directories, binaries, raw JSON and launch metadata are **missing in this copy**. “HEAD” is not an immutable source identity. The document also retains both a foreground-B retest claim and an older “B 尚未…复测” statement; resolve through original launch/raw evidence, not inference. Historical 5.1 ms and CPU observations are not thresholds. |
| `docs/performance/three-session-replay-results.md` | `heavy-load-live-20261017-001003` is unoptimized Debug, with idle-after shorter than six seconds: not a full-suite timing baseline. `heavy-load-profile-20261017-001204` and `stationary-profile-20261017-013506` are profiling-only/excluded. `native-final-acceptance-20261017-022249/segmented-tools` is a single correctness run, not pre/post proof. All referenced `build.noindex` artifacts are **missing here**. Earlier resumed-ID traffic differs from today's default segmented transcript. |
| `docs/performance/settings-and-interaction-audit.md` | Static audit and a measurement plan, not raw timing/RSS or launch evidence. Requires stable source/build, workload, visual conditions and repeated matched experiments; distinguishes persistence, GPU, callbacks and input latency. |
| Current DSH Settings/HeavyLoad repeats from the lead brief | Two rounds of the current build are repeatability evidence only. Their raw JSON/launch metadata are **not present in this copy**; they cannot become pre-change A/B by renaming. |

`build.noindex` itself was absent in this head's copy. No visible retained measurement JSON or launch manifest from those locations was available to read. Do not create another worktree, switch source, copy a project or substitute an old installed app to fill this gap. Ask the lead to supply existing retained directories and provenance if available.

Required comparison evidence: actual pre-DSH source revision **and local patch state**, binary hash, actual compiler/SDK and build settings (especially `-O` Debug vs unoptimized), same architecture/OS/hardware/power conditions, monitor/refresh/scaling/window origin and size, fonts/locale/accessibility settings, materials/theme, fixture/history sizes, renderer route, text-only vs segmented vs resumed-ID mode, requested cadence and complete workload, disabled-persistence policy and cold/warm conditions. Keep the same helper and protocol hashes and wheel region. Distinguish first-open from warm runs. Preserve paired/repeated run order and manual review; same-source repeats cannot demonstrate a change effect.

Read-only comparison of retained evidence:

```sh
python3 scripts/dsh_foreground_acceptance.py \
  --analyze /tmp/dsh-current-wheel-unique --baseline /path/to/existing-pre-change-run
```

A baseline from this driver needs `baselineRole: "pre-change"`, distinct source state and executable hash. The analyzer lists exact missing/mismatched environmental, protocol and report fields. Older directories without this manifest/resource series are explicitly unmatched; it still exposes their available `heavy-load.json` evidence. Settings-only directories cannot satisfy the wheel/resource protocol. A matching result is only a candidate for owner review, never proof of causality or automatic performance approval. Source relationships and retained patches require lead review. No baseline directory is changed.

## Ownership and cleanup

Only the three new source files belong to this task: the Python driver, this README and `wheel_sampler.m`. Production Swift and the existing driver/probe/docs are untouched. The helper executable, task app, conditions and unique run directory belong to the lead's explicit task run; retain all raw evidence until review is complete. Cleanup is manual and path-specific after owned children exit. Never delete user libraries, installed bundles, other agents' worktrees or unrelated `/tmp` content. No build output is supplied by the head.
