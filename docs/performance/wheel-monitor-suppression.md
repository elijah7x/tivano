# Hidden-column wheel monitor suppression

## Finding and change

`ThreadColumns.Coordinator` keeps up to eight previously visited chat columns attached behind the selected column. `ScrollViewProbe.ProbeView` installs an application-local scroll-wheel monitor for each attached timeline. Before this change, the monitor checked the window and vertical delta, then hit-tested the entire window before discovering that the event belonged to another timeline. A hidden ancestor did not remove the local monitor.

`ThreadTimeline.swift` now checks `isHiddenOrHasHiddenAncestor` before that hit test. The selected column retains the existing routing logic, including horizontal Markdown scrollers passing vertical movement through and nested vertical viewports retaining their input. No appearance, history, animation or event return value was changed.

The AppKit contracts are documented in [local event monitors](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)) and [ancestor visibility](https://developer.apple.com/documentation/appkit/nsview/ishiddenorhashiddenancestor). The latter checks explicit hidden ancestry, not occlusion by another window.

## Validation

The local harness extracts the production `ProbeView` declaration. It uses real AppKit windows, view ancestry, scroll ownership and lifecycle callbacks; event-monitor registration and event delivery are controlled. Its counting root returns a selected target, so these results quantify routing work rather than real hit-test traversal duration or physical wheel delivery.

For one visible column plus eight hidden columns, window hit-test calls per injected vertical wheel event fell from nine to one; the visible timeline received the same one callback. When all columns were hidden, calls fell from nine to zero and neither version routed the event. Checks also covered restoring another column, directly hiding the probe, zero vertical delta, missing/foreign event windows, nested vertical viewports, horizontal viewports and detachment removing monitors. All events were returned unchanged. No test window was shown and no Tivano instance was launched.

Artifacts: `build.noindex/wheel-monitor-checks/run.py`, generated Swift sources, `results.txt` and `build.log`.

The checkout's Debug build succeeded with two build jobs and the existing package-plugin validation flag. Developer ID bundle signature verification passed. Existing warnings remain for the non-Sendable completion capture in `StdioProcess.swift` and skipped App Intents metadata extraction. No package, installation, app launch or local dev integration commit was performed.

## Limits and next investigation

This is a reduction in redundant work, not a measured frame-rate improvement or proof of the original stutter's root cause. The busy Release sample at `/tmp/tivano-59554-continuation-busy-20261016.sample.txt` includes an event-monitor-to-window-hit-test branch, but its application Swift frames lack a matching dSYM; it does not establish the number of live column monitors in that process.

The user's improvement after enabling Performance Mode remains the strongest new mode comparison. That switch changes the window backdrop, multiple control surfaces and several animations together, and it persistently sets `clearerBackdrop` false. Background-only measurements must keep the global mode false and explicitly fix the clearer-glass setting, wallpaper, theme and workload. The zero-padding rim-mask candidate from `mode-render-differential.md` has not been adopted without evidence of material cost.
