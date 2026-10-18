# Settings and everyday interaction performance audit

2026-10-18. Static source investigation and web research only. No application, build, test, lint, profiling session or Git command was run. Locations refer to this worktree; proposed changes are not implemented. Ranking is investigation priority, not measured attribution.

## Findings ranked by likely user-visible impact

### 1. Covered chat retains live data dependencies, but already stops important rendering work

**Locations:** `Tivano/App/Views/RootView.swift:48,179,248,298,394`; `Tivano/App/Views/Chat/ChatView.swift:93`; `Tivano/App/Views/Chat/ThreadTimeline.swift:117,526,679,744,1794`; `Tivano/App/Views/Chat/TimelineRows.swift:1285,1615`; `Tivano/UI/Markdown/LinkParagraphView.swift:37,70`.

The brief's opacity observation is correct, but its implied rendering conclusion needs qualification. `DetailView` hosts separate AppKit chat columns. `ThreadColumns.Coordinator.cover` immediately supplies `chatColumnIsShown=false`, blocks interaction, then sets the containing pane's `isHidden=true` and suspends its `VeilRenderScope` after 450 ms. Hidden *nonselected* running columns are dropped; the selected running column underneath Settings is retained. Up to eight other visited columns remain cached. Thus this is not nine continuously streaming chats, nor proof that transparent pixels are composited every frame.

The remaining dependency path is concrete: runtime delta flush → observable `TimelineEntry.item` → `AssistantMessageRow.body` / `ToolRow` → `MarkdownView` → SwiftUI text or `LinkParagraphView.updateNSView` and text sizing. These row reads have no column-visibility guard. `ThreadTimeline.body` also reads the entries collection and constructs blocks before any visibility decision. Structural appends and relevant metadata changes can still invalidate it. Text appended to an existing row does **not** ordinarily invalidate the whole timeline: the cache deliberately reads `hasImages`, not tool output. `.equatable()` limits parent-driven updates; it does not unsubscribe live descendants.

`flushDelay` (`Tivano/App/Runtime/ThreadRuntime.swift:3691`) requests 16/45/90 ms batching by text length, at least 160 ms during scrolling, with additional Hydra pacing. These are requested delays, not observed frame or update rates. Hidden mounted rows remain eligible for these updates; whether AppKit/SwiftUI defers their body/layout execution must be measured. Native text rendering at `LinkParagraphView.swift:60` precedes the veil's visibility check, so stopping the fade clock alone is not a data-update barrier.

**Proposed fix, in increasing scope:**

1. Reuse `chatColumnIsShown` for immediate interaction/timer gating and the existing `VeilRenderScope.isVisible` for work that should continue through the outgoing transition. Do not add a second global timer or a per-frame environment value. Keep the existing pane, runtime and composer mounted.
2. Extend `TimelineScrollTracking.setColumnShown` to cancel pending presentation-only placement work where safe. Its current hide path cancels blank-watch and viewport-refresh tasks, but `keepAnchor` has a separate 24 × 25 ms placement task (`ThreadTimeline.swift:1061`). Gate row measurement and scroll-repair actions while covered, record a single “needs reconciliation” flag, and reconcile once on return. Do not simply discard every geometry sample: retain the reader's anchor/pin and remeasure after width/font/history changes.
3. Only if hidden row/text updates remain expensive, introduce a visibility-aware presentation boundary **before** `ThreadTimeline.body` reads runtime data. Retain a value snapshot of the mounted display data while covered; resume from current runtime state once. Snapshotting `[TimelineEntry]` is insufficient because those references remain observable. A snapshot must contain immutable rendered values, or the covered branch must contain no live row subtree. Keep composer/draft ownership outside that branch; `ThreadRuntime.draft` already lives independently at `ThreadRuntime.swift:325`.

**Risk:** medium for measurement/placement gating; high for snapshotting. A bitmap overlay by itself leaves the live tree working. Removing/replacing the hosted chat tree resets view-local scroll position, text selection, expansion state, editor focus/IME state and panel geometry, and restarts tasks. Preserve those explicitly before attempting removal. Reopening must reconcile completed turns, unread state, approvals, text arriving during cover, resize and theme/font changes without replaying old fades or jumping a reader who was scrolled up. Do not pause provider handling, persistence or the draft to save presentation work.

**Confidence:** high that live dependencies remain; medium that they materially delay Settings; hidden layout/drawing frequency unmeasured.

### 2. Some decorative clocks do not know that Settings covers them

**Locations:** `Tivano/App/Views/Chat/ActivityTree.swift:181` (`ActivityShimmer`); `Tivano/App/Views/Chat/TimelineRows.swift:554` (`HydraShimmer`); `Tivano/App/Views/Composer/EffortSlider.swift:1355` (`TrackEffect`); `Tivano/App/Views/Voice/VoiceViews.swift:258` (`VoiceCallBar`).

Activity shimmer requests up to 60 Hz; Hydra shimmer 30 Hz. Both pause for scrolling and disappear for reduced-motion/performance settings, but neither reads column or window visibility. `TrackEffect` requests 30 or 60 Hz and checks `FrontMonitor.shared.isVisible`, which means *any active visible app window*, not this column: Settings can keep that condition true. It can exist without a running agent. The voice call clock requests 1 Hz while its stage is retained under Settings. Actual hidden scheduling may be reduced by the framework; no such guarantee is expressed by these callers.

**Proposed fix:** add a local presentation gate to these clocks, preserving phase from real time on return. For reusable `TrackEffect`, allow an explicit visibility input/default so Settings previews remain animated while hidden chat instances stop. For the voice call bar use the stage/Settings visibility already passed to its orb. Retain current visible animation rates. `HydraWorkingTitle`, `HydraElapsed`, `WorkingIndicator` and scoped veils already demonstrate gating and must not be reported as unfixed.

**Risk:** low to medium. `onAppear`/`onDisappear` alone cannot represent opacity-based cover. Using app activation alone also misses a hidden pane in a visible window. A gate applied too early can freeze the outgoing transition.

### 3. Idle prebuilding can spend main-thread time behind Settings

**Locations:** `Tivano/App/Views/RootView.swift:184,197,253,366` (`DetailView` task, `Coordinator.prebuild`).

After 1.5 seconds, the task prepares neighbors and initially six top sidebar threads. It waits in 300 ms increments until global input has been idle for one second, checks that the selected runtime is not running, then adds candidates 400 ms apart. `prebuild` synchronously makes hosting trees and calls `layoutSubtreeIfNeeded`. Neither task identity nor prebuild checks Settings/voice cover. A short pause in Settings can therefore admit speculative layout just before the next hover or click. This is bounded warmup, not perpetual polling after candidates finish. It is less relevant when the selected chat is streaming, because that guard stops it; a different chat can still be working.

**Proposed fix:** include cover state in task cancellation/restart, guard before each append and in `Coordinator.prebuild`, and resume remaining candidates after the chat is visible and input has settled. Mark startup prebuild complete only after the intended work, so cancellation does not consume it permanently.

**Risk:** low. The tradeoff is a cold first switch to a deferred neighbor; preserve existing already-built columns. A lower-priority main-actor task alone cannot make synchronous layout preemptible.

### 4. The hidden sidebar still performs library-wide derivation on relevant changes

**Locations:** `Tivano/App/Views/RootView.swift:19`; `Tivano/App/Views/Sidebar/SidebarView.swift:76,505,557,708,2303`; `Tivano/App/Views/RootView.swift:181`.

The sidebar receives only opacity/input/accessibility changes, not the chat pane's visibility lifecycle. `PlacementCache.placements` builds a full fingerprint before its cache hit; activity layout scans all threads for attention. `DetailView` separately scans threads and runtime phase to derive the running set. Metadata, turn boundaries and approval/question changes can trigger this work while Settings is visible. **Ordinary message deltas do not publish `threadsRevision`**, so do not multiply these scans by token frequency. This is the candidate already documented in [overnight-update-fanout.md](overnight-update-fanout.md), not a newly discovered confirmed hotspot.

**Proposed fix:** if traces establish meaningful cost, maintain a placement revision/projection and attention membership independent of unrelated metadata; retain per-thread cell updates. A covered sidebar can also defer presentation derivation and refresh once on return without discarding search/scroll state. Keep nonvisual attention notifications live.

**Risk:** medium. Invalidation must include unread state, ordering, parent/project placement and helper visibility. Current structural invalidation alone is not sufficient. Do not remove column-retirement logic merely to avoid the running-set scan.

### 5. Runtime work continues correctly under Settings; remaining save scans can cause bursts

**Locations:** `Tivano/App/Runtime/ThreadRuntime.swift:4288,4328,4424`; `Tivano/App/AppModel+Hydra.swift:1241`; `Tivano/Core/Support/StdioProcess.swift:243`.

`snapshotForSave` still traverses loaded entries and finished turns on the main actor before handing immutable data to `DiskWriter`. Running saves are coalesced at 5–20 seconds; idle mutations debounce at 800 ms; unchanged saves are skipped. Position assignment is now cached, and entry callback binding is incremental. Those previous fixes do not remove the remaining head/dirty-turn collection scan. Multiple long running sessions can produce bursts independent of visible UI. This cannot explain sustained fully idle load by itself.

**Proposed fix:** profile whole snapshot preparation before proposing incremental per-turn indexes. Keep main-actor snapshot consistency, end-of-turn saves, retries, recovery and dirty-turn semantics. Separately measure the 30-second Hydra watchdog's library/active-entry scans and each live `StdioProcess` descendant tracker's one-second utility-queue process-tree scan; reduce redundant scanning only while preserving stalled-session detection and child cleanup.

**Risk:** high for persistence or process-tracking changes. Never turn these off when Settings opens. The latter scans consume system resources but are not evidence of main-thread blocking.

### 6. Small synchronous filesystem reads remain reachable from presentation

**Locations:** `Tivano/UI/Markdown/MarkdownView.swift:1371` → `Tivano/UI/Common/AttachmentPreview.swift:18,30` (local image existence); `AttachmentPreview.swift:363` → `PreviewImages.fileSize:112`; `Tivano/App/Views/Composer/DownloadsPopover.swift:177,227` → `FileIcons.icon:124` / `iconKey:138`; `Tivano/App/Views/Chat/TimelineRows.swift:1623,2088` → `resolveToolImagePath:45`.

These run on relevant body evaluation, not on a timer. Image path resolution for tool rows already has a 600-entry cache; extensionless file icons still perform path/type lookup **before** the icon cache hit. File size and local-image existence are not similarly cached at these call sites. Slow/network-backed paths can turn a small panel/hover update into a delay. No direct `Process()` construction was found in the view-body search; provider discovery is covered by the registry workstream.

**Proposed fix:** cache presentation metadata by path plus an explicit freshness policy, refresh asynchronously and publish only changed results. Preserve missing-file recovery. Terminal font/config reads and shell creation (`TerminalFont.swift:8,36`; `TerminalStore.swift:17,40`) are session-creation costs, not evidence that every terminal body launches a process. Downloads enumeration is already detached; composer file listing is `@concurrent` (`ComposerView.swift:1279`); legal-text bundle reads are static cached (`SettingsView.swift:1227`). Preview text reads are task-triggered (`AttachmentPreview.swift:399`), not repeated body reads, but still merit first-open profiling.

**Risk:** medium: stale metadata or negative-cache entries can hide newly created files. This is a conditional interaction hotspot, not an always-on idle loop.

### 7. Materials and input routing need separate attribution

**Locations:** `Tivano/UI/Chrome/Chrome.swift:301,386`; `Tivano/App/Views/Chat/ChatView.swift:979,1019`; `Tivano/App/Views/Chat/ThreadTimeline.swift:2560`.

The window material is independent of chat runtime state. The retained-scroll A/B/A in [render-cost-probe-review.md](render-cost-probe-review.md) supports a background-path contribution in that Debug fixture; it does not isolate GPU/WindowServer cost or establish production latency. Preserve normal glass. Test sampling area, overlapping surfaces and unnecessary updates separately from SwiftUI body work. The global Performance Mode switch changes several paths and persists `clearerBackdrop=false`, so it is not a clean material-only comparison.

Hover handlers execute on pointer events; they are not idle timers. Chat chrome, minimap and Hydra progress already convert positions into equality-checked semantic state. `LinkHoverModifier` performs native link/mention lookup per movement. The timeline wheel monitor now rejects hidden ancestry **before** whole-window hit testing; do not report the old nine-hit-test behavior as current. During the first 450 ms of cover the pane is not yet AppKit-hidden, which is a separate transition interval to measure.

**Proposed fix/risk:** retain these guards; investigate any remaining event-monitor traversal or material pass only when it correlates with a hitch. Removing hover, text selection, glass or panel behavior would fail the product requirement. A snapshot containing live translucent glass may also differ visually from the original sampling path.

## Whole-tree recurring-work inventory

Requested patterns were searched across `Tivano/`, with view call sites traced for filesystem work. Frequencies below come from source, not runtime measurement. “Eligible while hidden” means there is no explicit relevant visibility guard; it does not assert that SwiftUI actually draws it. Event-driven work has zero timer cadence. Capture-only code is separated from ordinary app work.

### Clocks, animations and polling

All paths below are under `Tivano/`.

| Location | Work / requested cadence | Hidden or idle behavior |
| --- | --- | --- |
| `App/Views/Chat/ActivityTree.swift:188` | Active activity text shimmer, up to 60 Hz | No column/window gate; scroll/reduced-motion/performance guards. Active branch required. |
| `App/Views/Chat/TimelineRows.swift:567` | Hydra brief/merge shimmer, up to 30 Hz | No column/window gate; scroll/performance/reduced-motion guards. Only corresponding active rows. |
| `App/Views/Composer/EffortSlider.swift:1363` | `TrackEffect` Canvas, up to 30/60 Hz | Window-level gate only; covered cached composers eligible even with no agent running. |
| `App/Views/Chat/HydraProgressBar.swift:859,881` | Working title 12 Hz; elapsed time 1 Hz | Explicit column + visible-app + running gates; stops under cover. |
| `App/Views/Chat/ThreadTimeline.swift:3871` | Working words/time, 1-second task loop | Same column/front/running gates; canceled when task identity changes. |
| `UI/Markdown/StreamVeil.swift:227,551` | SwiftUI/native fade display links, preferred 18 Hz (15–24 range) | Column scope invalidates links after cover transition. Shared unscoped clock is separate. `tick` returning during app inactivity/scroll does not itself invalidate the link or advance its expiry. |
| `UI/Common/Orb/OrbView.swift:50` | Orb Canvas, up to 30 Hz | `isOnScreen`, paused and reduced-motion gates. Voice call sites explicitly pause for covered sidebar/stage or hidden column (`App/Views/Voice/VoiceViews.swift:45,106,172`). |
| `App/Views/Voice/VoiceViews.swift:258` | Call duration, 1 Hz | No explicit cover gate; stage can remain mounted at opacity zero. |
| `App/Views/Settings/AboutUpdateViews.swift:411,497` | About animation 60 Hz; sparkles 30 Hz | Stops when settled/empty or scrolling; page lifetime, not app-wide. |
| `UI/Common/HydraGlyph.swift:185,207` | CA ring, 1.6-second repeated cycle | Layer animation, not a SwiftUI body clock; no explicit column gate here. Actual hidden-layer compositing is a measurement question. |
| `UI/Common/WorkingIndicators.swift:330,336` | CA dot opacity, `GradientSpin.period` repeat | Layer animation; investigate lifecycle/compositor rather than claiming 30 SwiftUI updates/sec. |
| `App/Views/Sidebar/SidebarView.swift:2443` | Shared `MinuteClock`, 60 seconds | Continues after first use, including hidden sidebar; labels alone read its time. Low expected impact. |
| `UI/Common/RenderBudget.swift:46` | Scroll reporter cleanup, 2 seconds | Only while reporters say scrolling; stops when empty. |
| `App/Views/RootView.swift:184,197,202` | Prebuild: 1.5-second initial delay, 300 ms input-idle polling, 400 ms candidate spacing | Bounded candidate list; no Settings gate. Cover/retirement delays at 321/414 are single 450/500 ms tasks. |
| `App/Views/Chat/ThreadTimeline.swift:1085,1200,1817,1877,1940,1969` | Anchor stabilization 24 × 25 ms; 150 ms scroll settle; 300 ms blank check; bounded 17 ms nudge/refresh waits | Presentation-event work, not permanent polling. Blank/refresh already column-gated; placement cancellation deserves audit. |
| `App/Runtime/ThreadRuntime.swift:3680,3691` | Delta coalescing 16/45/90 ms, scroll floor 160 ms | Continues for active streams under Settings; event-armed, not idle periodic work. |
| `App/Runtime/ThreadRuntime.swift:4293,4309,4359` | Dirty saves: 800 ms idle debounce, 5–20 seconds active, failure retry 2/5/15/60 seconds | Visibility-independent durability; no unchanged-save loop. |
| `App/AppModel.swift:1374` | Library save: 400 ms debounce and at least four seconds between saves | Mutation-driven, visibility-independent; not an idle recurring timer. |
| `App/Runtime/ThreadRuntime.swift:2143` | Quiet watchdog, 30 seconds | Session/turn lifecycle controlled; must keep monitoring hidden work. |
| `App/AppModel+Hydra.swift:1233,1243` | App Hydra watchdog, 30 seconds | Continues once started, even with no running heads; scans library then active-head entries. |
| `App/AppModel.swift:319,579` | Pending-merge sweep 300 seconds; departed-runtime cleanup 600 seconds | Hidden/idle eligible; cleanup retries while runtime still busy, then stops. |
| `Core/Support/StdioProcess.swift:253` | Descendant process discovery, one second, 200 ms leeway | Utility queue per tracked live process; unaffected by Settings. |
| `App/Runtime/VoiceController.swift:342` | Microphone/speaker meter IPC, 100 ms | Only active voice session; continues under Settings and publishes levels. Keep transport live; UI meter delivery could be gated separately. |
| `App/UpdateChecker.swift:154,157` | Update check after eight seconds, then six hours | App service, hidden/idle eligible; not per-frame work. |
| `Services/Providers/ProviderRegistry+CLIUpdates.swift:79` | CLI update discovery, six hours after initial check | Hidden/idle eligible, configured providers only; capture mode excluded. |
| Same file `:172,398,458,648` | Wait for binary replacement/busy providers: 200 ms; catalog load: 100 ms | Only requested update/load operations; may outlive page visibility. Prefer completion signaling if traces show significant polling. |
| `App/Runtime/ThreadRuntime.swift:926,1907,1927` | Stop/rewind completion waits, 50 ms | Operation-bound; first loop capped at 200 iterations. Other loops wait for the owned completion/rewind, not normal idle. |
| `Services/Providers/OpenAICompatibleSession.swift:224` | Stream buffer flush after 30 ms | Event-scheduled; continues with active hidden stream, no idle loop. |
| `App/AppDelegate.swift:59,64` | Shutdown drain, 25/250 ms | Quit-only, bounded by deadlines; not ordinary interaction work. |

No executable `Timer.publish`, `Timer.scheduledTimer` or SwiftUI `repeatForever` call was found; the `repeatForever` hit is a historical comment. CA repeats and display links above are the relevant alternative mechanisms. `Task.sleep` by itself does not identify a loop. Other matches are request timeouts/retries (provider/MCP/Shell/Git), file-event timeout (`Services/Git/WorkingTreeWatch.swift:264`, explicitly event-driven), debounced ledger saves (`Services/Store/TokenLedger.swift:140`), panel/hover/fade delays, or finite focus waits (`ComposerTextView.swift:296`, ten × 16 ms). They can finish while covered but do not establish persistent idle load. `App/Captures/` contains intentional replay/animation loops and `DispatchSourceTimer` deadlines (`HeavyLoadProbe.swift:61`, `RenderCostProbe.swift:65`, `TextParityProbe.swift:52`); exclude these opt-in fixtures from normal idle attribution.

### Input monitors and continuous hover

Each local monitor runs for every matching app event until removed, including events intended for a different view. Registration does not produce idle ticks. Check active monitor counts during reopen cycles; do not infer leaks from registration sites alone.

| Location | Trigger and scope |
| --- | --- |
| `App/Views/Chat/ThreadTimeline.swift:2560` | Wheel per attached timeline; early hidden-ancestor/window/delta guards, then hit test. Removed on detachment. |
| Same file `:2928` | Mouse release during front/placement deferral; ends pending work, not wheel polling. |
| `App/Window/ThreadWindow.swift:12` | Key down, one digit shortcut monitor per window; filters event window/modifiers/sheet. |
| `App/Views/Terminal/TerminalPanel.swift:214` | Key down per terminal host; Escape + first-responder guard before shell foreground lookup. |
| `App/Views/Chat/HydraButton.swift:287` | Mouse down per installed anchor; `catches(event)` determines ownership. Cached hosts can retain registration. |
| `App/Views/Sidebar/SidebarView.swift:1091` | Archive confirmation keyboard handling while appeared; not each sidebar row. |
| `App/Views/Settings/ShortcutsSettingsPage.swift:555` | Key down/up/modifier changes while shortcut recording is active. |
| `App/Views/Composer/FollowUpQueueTab.swift:168` | Mouse-up safety net while dragging, removed when drag clears. |
| `App/Views/Chat/ChatBadge.swift:171,182` | Popover Escape/click dismissal; key handler filters owning windows. |
| `App/Views/Composer/PromptEditor.swift:240,248` | Editor popover key/click dismissal; modal/sheet guard. |
| `App/Views/Diff/DiffInspector.swift:827,832` | Diff popover click/key dismissal. |
| `UI/Common/AttachmentPreviewPanel.swift:162,167` | Attachment popover click/key dismissal. |
| `UI/Markdown/LinkPopover.swift:55`; `App/Views/Settings/FloatingGuidePanel.swift:77` | Escape while respective UI is presented; guide explicitly checks visibility. |
| `App/Views/Chat/ChatView.swift:1019` | Pointer move → equality-checked top-controls reveal region. |
| `App/Views/Chat/TimelineMinimap.swift:219` | Pointer move → selected tick; state/haptic only when ID changes. |
| `App/Views/Chat/HydraProgressBar.swift:144` | Pointer move → stave index; equality guard before state update. |
| `UI/Markdown/LinkHover.swift:17` | Per-paragraph link/mention hit lookup on movement; cursor/popover state equality guards. |

### Repeated settings subscriptions

`@AppStorage` is notification-driven, not a timer or proof of synchronous disk access on every read. Repeated instances can multiply dependency checks when defaults change, including retained hidden views. The main repeated subscriptions are:

- Surfaces: `UI/Chrome/Chrome.swift:198,217,255,304,305`; `UI/Chrome/WindowChrome.swift:491`.
- Rows/indicators: `App/Views/Chat/ActivityTree.swift:161,246,313,428`; `TimelineRows.swift:548,719,1377`; `TimelineMinimap.swift:189,506`; `HydraProgressBar.swift:38,849,900`; `SubagentPanel.swift:251`; `ChatView.swift:954`; `HydraPanel.swift:18`; `App/Views/Sidebar/SidebarView.swift:1224,1824`.
- Shared indicators: `UI/Common/WorkingIndicators.swift:66,97`; `HydraGlyph.swift:19`; `Orb/OrbView.swift:31`; `App/Views/Composer/ComposerWorkingDots.swift:14`.
- Composer/card surfaces: `App/Views/Composer/ComposerView.swift:22,698,1318,1319`; `EffortSlider.swift:1026,1350`; `RequestCards.swift:6,80,81`; `FollowUpQueueTab.swift:328,534,535`; `ThreadChangesTab.swift:50,51`.
- Page/control instances: `App/Views/Settings/ModelsSettingsPage.swift:21,438`; `HydraSettingsPage.swift:356`; `ShortcutsSettingsPage.swift:338,474`; `App/Views/Palette/CommandPalette.swift:221`.

Most read `performanceMode`; others read `floatingGlassStyle`, `clearerBackdrop` or `workGroupStyle`. Coordinate any change with the Chrome workstream. Consider a small, stable preferences owner with leaf-level reads if traces show fan-out. Replacing every wrapper with a frequently rewritten environment struct may move rather than remove the cost.

## Best practices mapped to Tivano

Primary sources were consulted on 2026-10-18. Some individual Apple API pages returned JavaScript shells and their Markdown links were unsupported by the web reader; official indexed documentation and accessible WWDC transcripts supplied the contracts below. No unverified competitor implementation claims are used.

| Guidance | Application here / source |
| --- | --- |
| Measure slow work and unnecessary work separately; preserve identity. | Keep body calculations cheap and dependency sets narrow. Avoid rebuilding the column simply to hide it. Stable IDs and predictable row structure matter; expensive filtering before a lazy container is still expensive. [WWDC23: Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/). |
| Inspect actual update causes, including environment propagation. | Instruments 26's SwiftUI template exposes update groups, long body/platform updates and a Cause & Effect Graph. Collection membership helpers can subscribe every caller to a whole array. Environment changes can incur dependency checks even when a body's value ultimately remains unchanged: keep visibility flags infrequent and scope-local, never distribute clock time or scrolling geometry through a broad environment value. [WWDC25: Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/). |
| Observation tracks property access per observable instance, including reads through computed properties. | `@Environment(AppModel.self)` does not mean every model mutation redraws every consumer. Conversely, `model.threads.filter(...)` reads the collection; a computed helper does not hide that dependency. Passing observable entry references is not a frozen snapshot. Legacy `ObservableObject`/`@EnvironmentObject` publication is broader than `@Observable` property tracking. [Discover Observation in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10149/), [ObservedObject](https://developer.apple.com/documentation/swiftui/observedobject). |
| Geometry observation should publish only useful changes. | Transform geometry to a small Equatable result, quantize where acceptable, and avoid writing a size that controls the same measurement. Preference delivery → state → layout → preference can form a feedback loop; it is not proof of one. Tivano already quantizes resize height and defers scroll writes. Preserve those guards when adding cover/resume handling. [onGeometryChange](https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)), [Apple performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance). |
| Equality skips equivalent input updates; it is not suspension. | `equatable()` wraps `EquatableView`. Use complete equality over rendered value inputs, never “equal while hidden” as a substitute for controlling live observations. Keep current `ThreadTimeline` and Markdown equality boundaries; instrument descendant updates independently. [equatable()](https://developer.apple.com/documentation/swiftui/view/equatable()), [EquatableView](https://developer.apple.com/documentation/swiftui/equatableview). |
| Lazy containers bound creation, not all upstream work. | Keep mounted-window virtualization. Optimize `TimelineBlockCache` key construction separately if measured: it still scans all entries before a cache hit. Do not replace a small Settings stack with a lazy stack by habit. [LazyVStack](https://developer.apple.com/documentation/swiftui/lazyvstack). |
| Hover frequency follows pointer movement; local monitors execute on the main thread. | Use `onHover` for simple enter/exit; continuous hover only for position-sensitive behavior. Keep semantic equality guards and cheap window/visibility checks before native hit testing. Remove monitors at the end of their intended lifetime. [onContinuousHover](https://developer.apple.com/documentation/swiftui/view/oncontinuoushover(coordinatespace:perform:)), [AppKit event monitoring](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html). |
| Blending is separate from SwiftUI body computation. | `NSVisualEffectView` distinguishes behind-window and in-window sampling. For Tivano, area/overlap and moving sampled content are cost hypotheses to profile, not an Apple guarantee that every material is expensive. Reuse existing panel flattening and preserve appearance. [NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview), [Rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency). |
| Low input latency requires bounded CPU work as well as GPU rendering. | Zed documents specialized GPU primitives and glyph caching; it also fixed a completion filter that blocked the UI thread by moving that work asynchronously. Transfer the principles—incremental text/cache updates, background preparation and small main-thread commits—not the assumption that rewriting Tivano in a GPU framework will cure scheduling stalls. [Zed's rendering architecture](https://zed.dev/blog/videogame), [Zed completion latency fix](https://zed.dev/blog/zed-weekly-23). Cursor, VS Code, Codex and Claude are product-experience targets here; no comparable current latency benchmark or private renderer architecture was established. |

## Measurement plan for the owner

Use an optimized, symbolicated diagnostic build and a stable synthetic transcript. Keep window size, display refresh rate/scaling, theme, wallpaper, backdrop settings and workload fixed. Record binary/source identity. Do not change global Performance Mode between variants. Compare the same interactions before/after, ideally repeated A/B/A; distinguish first-open from warm paths. New launches remain subject to the owner's normal authorization.

Capture these phases: settled idle; one selected chat streaming; three sessions streaming; full-window Settings open over that selected chat; Settings over an idle selected chat while another streams; repeated page switches and pointer traversals; panel open/close; return to chat both pinned and scrolled up. Include 0–450 ms after cover separately from settled Settings. Test independent Settings windows separately: the chat is still genuinely visible there. Stop streams and allow final saves to finish before calling a phase “idle.”

Start with the **SwiftUI template in Instruments 26+**, expanding **Update Groups**, **Long View Body Updates**, **Long Platform View Updates**, **Other Long Updates** and the hitch track; correlate with its Time Profiler. Open the **Cause & Effect Graph** for suspect rows/containers and follow the changing property or state write. Low body counts do not exclude text layout or compositor work. On older tools, use Time Profiler plus explicit signposts; lack of the new graph is not negative evidence. [Apple's profiling workflow](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).

| Finding | Confirm or refute; before/after acceptance |
| --- | --- |
| 1: hidden chat | Count/timestamp `ThreadTimeline`, assistant/tool rows, Markdown preparation, `LinkParagraphView.updateNSView/sizeThatFits`, geometry callbacks and veil ticks by column/cover state. Use Time Profiler for CoreText/TextKit/layout stacks. If settled cover has negligible cost, reject a costly snapshot redesign. A fix should remove hidden presentation work without shifting a larger stall to reopen; reconcile every final message/tool and preserve draft, selection, anchor and focus. |
| 2: ungated clocks | Attribute callbacks to each shimmer/track/voice instance while visible, covered, app-inactive and genuinely idle. Confirm existing veil/elapsed guards reach zero. After gating, hidden instances should stop scheduling; visible motion and phase must remain correct. |
| 3: prebuilding | Signpost `prebuild`, `make` and `layoutSubtreeIfNeeded`. Pause in Settings for >1 second, then move/click. Correlate any input delay with a build interval. After change, no speculative column construction while covered; compare subsequent cold thread-switch latency. |
| 4: scans | Count actual metadata publications and placement/attention/running-set derivations with input sizes. Trace title/mode changes, requests and turn boundaries separately from plain deltas. Reject the candidate if it contributes little cumulative main-thread time. After a projection change, unrelated metadata should not force full key generation; ordering/unread/attention must remain current on return. |
| 5: runtime/services | Use **Time Profiler** for snapshot/watchdog bursts and **System Trace** for scheduling/wakeups across main/utility queues. Capture longer than 30 seconds and align save spans with delayed input. Test short/long histories and one/three sessions. Preserve final-state/disk correctness; reduced wakeups without reduced latency is not an interaction win. Six-hour tasks need a separate scheduled/check-triggered capture, not a 30-second idle inference. |
| 6: filesystem | Use **File Activity** alongside Time Profiler during image/download/preview/terminal opens. Attribute main-thread `stat`/resource/icon/config reads, distinguish first access from warm cache, and include slow-path files safely. After changes, warm hover/body updates should not repeat synchronous metadata reads; newly created/deleted files must still appear correctly. |
| 7: materials/input | Separate **Animation Hitches/Core Animation** and **Metal System Trace** captures as supported by the host, including WindowServer/system GPU work. First hold the material constant and measure event handling; then use a local material-only diagnostic control. Count monitor callbacks versus expensive hit tests. A new fix must improve missed deadlines/input latency with unchanged visuals; process CPU alone cannot establish compositor benefit. |

Report interaction-to-present latency p50/p95/max, missed display deadlines, main-thread busy time and actual update/callback counts. A 120 Hz display provides about 8.3 ms per frame; a 60 Hz display about 16.7 ms, shared with framework/rendering work. These are budgets, not promises that a whole frame may be spent in `body`. Main-actor synthetic callback intervals are **not** presentation FPS or physical input-to-photon latency. Keep logs aggregated and avoid per-token logging. Use separate profiling runs if instrumentation changes timing.

## Existing decisions and evidence limits

- [overnight-results.md](overnight-results.md), [incremental-entry-binding.md](incremental-entry-binding.md), [cached-save-positions.md](cached-save-positions.md), [incremental-veil-state.md](incremental-veil-state.md), [native-text-layout-investigation.md](native-text-layout-investigation.md) and [wheel-monitor-suppression.md](wheel-monitor-suppression.md) document adopted narrow fixes. This audit does not re-propose those fixes or reuse component percentages as whole-app gains.
- [three-session-replay-results.md](three-session-replay-results.md) distinguishes valid reconciliation, invalid scroll trajectories and profiling-only runs. Native linked-text storage improved in the accepted fixture; blanket plain-text rerouting and an alternate fade renderer were rejected. Preserve typography, selection and normal rendering.
- [mode-render-differential.md](mode-render-differential.md) and [render-cost-probe-review.md](render-cost-probe-review.md) separate materials from animations and explain global-mode confounding. [continuation-session-regression.md](continuation-session-regression.md), [continuation-window-trigger.md](continuation-window-trigger.md) and [overnight-update-fanout.md](overnight-update-fanout.md) do not prove a WindowServer fault, titlebar loop or sustained fully idle regression.
- One targeted Nowledge CLI thread search was performed: query `Tivano performance hidden settings`, limit 5, ambient `default` space. It returned five thread summaries (14 total matches), without source-message evidence; no architectural or performance conclusion here relies on their titles. Current source and repository notes remain the evidence base.

The lead must establish actual hidden update cadence, retained monitor counts, GPU contribution and user-visible improvement. No new performance result is claimed by this document.
