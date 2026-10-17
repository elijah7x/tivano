# Background-only probe: owner review

The owner authorized isolated execution. The first attempt exited during warmup and produced no eligible phases; the cause was not recorded precisely enough to attribute it to the product.

## Scope

Launch arguments must include both `--website-captures <dedicated output directory>` and `--render-cost-probe`. CaptureRun supplies separate storage and preferences; the normal launch and existing product captures retain their previous paths. No provider or model session is started. AppModel.bootstrap exits before normal account/merge services in capture mode, and WallpaperStore also uses the capture defaults.

For each fixed clearerBackdrop setting (true, then false), the probe keeps Performance Mode false and compares opacity 0.5, 1.0, 0.5. With no wallpaper, this changes only WindowBackdrop between the corresponding glass/blur path and the existing solid backdrop. Each phase waits one second, then drives the same six-second programmatic scroll. The corrected driver uses the existing [SwiftUI ScrollPosition API](https://developer.apple.com/documentation/swiftui/scrollposition/scrollto(y:)), with an explicit CaptureRun-only reader-intent hook; this is not wheel-event delivery. Geometry in subsequent callbacks must agree with prior targets. Controls and animations keep their normal configuration. CPU time is this process only; driver callback delay is not presentation FPS or GPU time.

## Owner corrections

- The old final-answer mock contains only three timeline items and a short reply. Only the new probe now substitutes a fixed 24-paragraph answer, giving it a useful scroll range without changing ordinary screenshots or contacting a provider.
- Added initial prebuild settling and a preparatory scroll sweep before A1. Each measured trajectory still rejects changes to its scroll range rather than silently comparing different content.
- A window move, resize, display change or backing-scale change invalidates the phase. Activity and explicit occlusion loss also invalidate it.
- The cooperative exit starts at 88 seconds. An independently scheduled 90-second wall deadline remains armed until the capture process exits, even if the main actor stalls or normal termination is delayed. The fallback preserves the latest report, marks it timed out and ineligible, and exits only that capture process with status 124. It never signals another process or relaunches anything.

## Build and artifacts

The checkout's arm64 Debug build succeeded with two build jobs; strict bundle signature verification passed. Build log: `build.noindex/wheel-monitor-checks/render-probe-build.log`. Existing UnreadRegression activation-deprecation and App Intents extraction warnings remain. This is an ordinary Debug build, not a packaged optimized Dev edition or a production-performance comparison.

Build product: `build.noindex/dd-perf/Build/Products/Debug/Tivano Dev.app`.

- Executable UUID: `C15F668E-B33D-36C1-83BC-344D3C7D681D`.
- Debug code dylib UUID: `58228BD6-D1C6-3325-B1D4-2926195023A7`.

The production deadline body was extracted into a headless test executable with its timer shortened to 0.1 seconds. It exited only itself with status 124, marked the report timed out, excluded phases from comparison and preserved previously recorded metrics. A second case blocked the harness main thread; the independent deadline still exited it and marked timeout. Neither these checks nor the build launched Tivano.

## First execution and follow-up

`build.noindex/render-cost-live-20261016-233759/render-cost.json` records a blocked warmup at about 6.23 seconds. All six phases remain unverified. No performance comparison or screenshot was obtained. The follow-up uses a stable display identifier, explicitly suppresses capture-only onboarding, and records activation, key-window, visibility, geometry and configuration state before and after warmup. A blocked warmup now attempts its own diagnostic screenshot; no eligibility condition was relaxed.

The next live capture, actual scroll motion, comparable phases and effect size remain unverified. The authorized launch briefly occupies the foreground using a separate fixture instance. No installed edition has been replaced, no production preferences have been changed and no new code has been committed or packaged.


## Retained-position correction

The 23:56:54 run reported six raw completed phases. Its immediate clip-bound checks were insufficient: `HeavyLoadProbe` subsequently observed repeated requests being undone by bottom-follow during idle-before (161 of 220 callbacks mismatched). The render run is therefore excluded by `owner-assessment.json` in its output directory. Its CPU values cannot establish the cost of sustained scrolling, nor show that glass has no cost. Original raw reports are preserved.

The lead replaced direct clip writes in both drivers with the timeline's own ScrollPosition binding, restricted to the two explicit CaptureRun probe flags. Each callback validates the previous request against actual SwiftUI scroll geometry; the corresponding native clip must also move. The revised RenderCostProbe trajectory stays between 10% and 90% to avoid bottom/top anchor transitions. Production builds exclude the hook, and ordinary Debug sessions do not bind it. The three-thread replay still requires all numbered text and completed tool output to reconcile.


## Corrected retained-scroll run

`build.noindex/render-cost-live-20261017-001600/render-cost.json` completed six eligible phases. All prior targets matched the next measured SwiftUI geometry (zero overridden samples per phase); native clip movement was recorded 196-281 times per phase. The lead viewed screenshots of both clearer-backdrop paths and the solid control. These are the unoptimized Debug results, not a delivered optimization or production FPS.

| clearerBackdrop | A1 callback p95 (ms) | Solid B callback p95 (ms) | A2 callback p95 (ms) | B reduction from A mean |
| --- | --- | --- | --- | --- |
| true | 32.693 | 25.748 | 34.754 | 23.6% |
| false | 31.851 | 26.646 | 29.609 | 13.3% |

Both half-transparent background paths had higher callback delay than their solid control, and the effect reversed in A2. This supports a background-path contribution under this fixture; it does not isolate GPU or WindowServer cost, and does not quantify what the global Performance Mode switch changes. Each process used roughly a core during continuous scrolling, so CPU alone did not express all of the scheduling difference. The solid variant is diagnostic only: preserving the normal background remains a product requirement.
