# Timeline jitter investigation

## Observed cause

On 2026-10-12, a Thor run of the real chat view recorded 31 successful one-point
scroll-and-restore operations. Every operation had visible conversation rows;
the blank-layout watch never fired. Twenty-two operations occurred while the
reader was away from the bottom. Return-to-front refreshes were the main source.
The baseline included 60 seconds at rest, simulated reply growth, 22 thread
switches, 22 window resizes and 22 cover/uncover cycles.

`ThreadTimeline.refreshViewport` retained a workaround for the former lazy stack:
`beginNudge` moved the clip view by one point, then `restoreNudge` restored it.
The timeline now uses an eager `VStack`, so this physical movement unnecessarily
disturbed rows that were already displayed. The original video's exact initiating
event was not recorded; the runtime baseline establishes the faulty movement path.

The default refresh now leaves visible rows in place. Missing rows or an unseen
pinned end can trigger a bounded stack recreation without an artificial scroll.
Existing user-scroll protection, bottom following and blank-layout repairs remain.

## Isolated reproduction

The Debug-only driver uses the existing capture library and defaults isolation.
It rehearses provider events and exercises the real model, chat view, AppKit
wheel/key queue, window switching, resizing and occlusion. It records stills and
12-second, 30fps recordings of its own chat window. It does not record the desktop
or start a provider for the simulated replies.

Wheel input first targets this process with Apple's [CGEvent.postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)).
If it is not delivered, the driver records a direct `NSScrollView.scrollWheel`
fallback and uses it for both directions. This exercises viewport movement but
does not establish that physical wheel input or the local event monitor works.
Key events enter the AppKit queue so the composer sees the event's modifier flags.
Capture enumerates [only the current process](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getcurrentprocessshareablecontent(completionhandler:)).

Run only on an unlocked graphical session, with explicit launch authorization.
Set a temporary `caffeinate -d -i -s -u -t 1800` assertion during a comparison,
and release it when the runner exits. For builds, wrap `xcodebuild` with
`caffeinate -d -i -s -u` so the assertions last until the build exits. This
prevents idle display and system sleep but cannot unlock an already locked session.
Thor's host-specific screensaver idle time was 600 seconds. On this host,
`caffeinate` did not prevent that independent screensaver lock: the session locked
at 14:38:31 CST while task wake assertions were used around the build workflow.
For the supplementary run, a task guard temporarily sets
`defaults -currentHost write com.apple.screensaver idleTime -int 0`, restores the
original 600 on exit, and has a 30-minute restoration deadline. It does not change
the password requirement or unlock an existing lock screen.

For the fixed path, run the signed Debug executable with:

    TIVANO_TIMELINE_TRACE=<output>/timeline.jsonl <app>/Contents/MacOS/Tivano\ Dev --website-captures <output> --timeline-stress

For a baseline, add `TIVANO_TIMELINE_LEGACY_NUDGE=1`. The legacy path is accepted
only by an isolated Debug stress run. It is absent from Release and cannot be
enabled in normal app launches. Use different output directories and run the two
cases sequentially with the same signed executable.

Artifacts are `run.log`, `stress.json`, `timeline.jsonl`, PNGs with framing JSON,
and `pinned-motion.mp4`, `grow-motion.mp4`, `occlude-motion.mp4`. The trace contains
timing, caller labels, counts, geometry and scroll state, not message bodies or
credentials. It is opt-in and capped; writes occur on a background queue.

The driver returns failure for missing stills and exits with status 2 if the
foreground desktop is unavailable or the 300-second budget expires. Check the
actual artifacts and phase results rather than treating process exit alone as
acceptance. Resizing uses `setFrame`, not a physical live-resize drag.

## Thor signing

Use a task worktree based on `artemis/dev`. If Thor lacks the Developer ID private
key, build there with `CODE_SIGNING_ALLOWED=NO` for compilation only. Transfer the
Debug bundle to Artemis, sign embedded native code before the containing bundle
with the existing Developer ID, hardened runtime and secure timestamp, then run
`codesign --verify --deep --strict`. Xcode Debug bundles can contain
`Tivano Dev.debug.dylib` and `__preview.dylib`; sign both before the app.

Return that verified bundle to the Thor task's build directory for the authorized
run. Do not export the private key, use local/ad-hoc signing, replace an installed
app or invoke packaging scripts on Thor.

## Validation status

Local Dev integration is based on `dbd803266` (Dev 1.1.12). The squash includes
the fix, diagnostics, isolated driver, changelog entry, and Dev 1.1.13/build 56.
The integrated tree's Debug build passed on Artemis with Developer ID signing.
Existing RowGlide actor-isolation and StdioProcess Sendable warnings remain.
The graphical evidence below is from the Thor task build; the integrated build
was not launched or installed.

Base: `artemis/dev` at `d2174d5ddab86a479cb54d45cdcfdfa6e7d84406` (Dev 1.1.9).
Thor branch: `thor/timeline-jitter-20261012-3a2b4eec`.
Thor worktree: `/Volumes/ExHeart/forked/tivano/worktrees/timeline-jitter-20261012-3a2b4eec`.

The initial Debug baseline captured the movement and valid screenshots. After
correcting the diagnostic integration, Debug and Release compilation passed.
The first same-build visual comparison was interrupted by a locked Thor session
(`CGSSessionScreenIsLocked=Yes`), so that attempt is not acceptance evidence.
After the owner unlocked Thor, the 14:33 CST comparison completed both modes with
the same signed executable. The legacy trace recorded 31 successful one-point
nudges, all with visible rows; the fixed trace recorded zero. Neither blank watch
fired. Both runs completed 60 seconds pinned, reply growth, 22 thread switches,
22 resizes, 22 actual occlusions, and four-line typing followed by Command-A/delete.
All stills and three recordings per run were produced.

The legacy occlusion recording contains 17 captured pairs of a 2-pixel downward
translation followed by its return. The fixed recording contains zero such
translations in the same text region; both pinned recordings are stable. These
were checked from decoded frames and actual rendered captures. The original
video's precise initiating event remains unknown.

The first unlocked runs did not successfully deliver posted wheel events, and
only the probe's direct fallback moved the viewport. The lead corrected the
driver to keep using that fallback for both directions. Debug compilation passed;
the supplementary signed `fixed-wheel` run initially stopped at its locked-session
preflight at 14:42 CST. After another owner unlock, it completed at 14:50 CST:
878 trace events, zero nudges, zero blank-watch fires, no missing stills, and
successful recordings. The direct fallback moved the real viewport 800pt away,
held it there, and returned to distance-from-bottom zero; the rendered captures
confirm both positions. All other phases completed again. Physical wheel delivery
and real provider sessions are outside this simulated capture's evidence.
The temporary screensaver setting was read back as 600 after automatic restoration;
task wake assertions were released.

The lead initially controlled Thor through direct SSH commands, outside the owner's
existing agent tmux sessions. The comparison now has its own visible session:
`tmux attach -t timeline-jitter`, window `comparison`. Its runner is
`build.noindex/jitter-evidence/run-comparison.sh`; output is also saved to
`comparison-control.log`. The 14:21 CST attempt exited with status 2 at the locked
session preflight, before launching a GUI instance. It is not test evidence.

The first build errors, subsequently addressed, were:

- `No signing certificate "Developer ID Application" found`: compile on Thor,
  then sign on Artemis as described above.
- `value of type 'NSApplication' has no member 'post'`: use `postEvent` for key
  queueing and `CGEvent.postToPid` for the wheel driver.
- `type '()' cannot conform to 'View'`: bind the diagnostic call as a local value
  inside the view builder.
- `cannot convert value of type 'StaticString' to expected argument type 'String'`:
  explicitly convert diagnostic labels before comparing them.
