#if DEBUG
import AppKit
import Darwin

/// Opt-in, process-local background comparison. No wheel events or provider work.
@MainActor
enum RenderCostProbe {
    private static var terminationDeadline: DispatchSourceTimer?

    static let fixtureAnswer = (1...24).map { index in
        """
        Paragraph \(index). A conversation can stay open while its completed answer is read from beginning to end. This fixed paragraph gives the isolated probe enough content to scroll without contacting a provider. The text, controls and history stay the same through every background comparison. Only the window backdrop changes between the glass and solid phases, then returns to its original setting.
        """
    }.joined(separator: "\n\n")

    static func run(model: AppModel) async {
        guard CaptureRun.isEnabled,
              CommandLine.arguments.contains("--render-cost-probe"),
              let output = CaptureRun.outputDirectory,
              let defaults = CaptureRun.defaults else { return }
        let session = Session(output: output, defaults: defaults, model: model)
        await session.run()
    }

    @MainActor
    private final class Session: NSObject {
        let output: URL
        let defaults: UserDefaults
        let model: AppModel
        let started = ProcessInfo.processInfo.systemUptime
        var phases: [[String: Any]] = []
        var events: [[String: Any]] = []
        var window: NSWindow?
        var expectedFrame: NSRect?
        var expectedDisplayID: CGDirectDisplayID?
        var expectedScale: CGFloat = 0
        var stageSnapshots: [[String: Any]] = []
        var monitoring = false
        var interruption: String?
        var finished = false

        init(output: URL, defaults: UserDefaults, model: AppModel) {
            self.output = output
            self.defaults = defaults
            self.model = model
        }

        func run() async {
            for clearer in [true, false] {
                for (index, opacity) in [0.5, 1.0, 0.5].enumerated() {
                    phases.append([
                        "name": "clearer-\(clearer)-\(["A1", "B", "A2"][index])",
                        "clearerBackdrop": clearer, "backdropOpacity": opacity,
                        "status": "unverified", "reason": "not started", "eligibleForComparison": false,
                        "trajectoryElapsedSeconds": NSNull(), "processCPUSeconds": NSNull(),
                        "driverCallbackDelayMilliseconds": NSNull(),
                        "startPositionPoints": NSNull(), "endPositionPoints": NSNull(),
                        "movementSamples": 0, "scrollRangePoints": NSNull(),
                    ])
                }
            }
            save(status: "running", reason: "initializing")
            // A main-actor timeout cannot run when the UI itself stalls. This final
            // deadline touches only this capture's files and terminates this process.
            let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let timeoutReport = output.appendingPathComponent("render-cost.json")
            deadline.schedule(wallDeadline: .now() + 90)
            deadline.setEventHandler {
                var report: [String: Any] = [:]
                if let data = try? Data(contentsOf: timeoutReport),
                   let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    report = existing
                }
                report["status"] = "timeout"
                report["reason"] = "90 second capture process deadline exhausted"
                report["budgetSeconds"] = 90
                if var phases = report["phases"] as? [[String: Any]] {
                    for index in phases.indices {
                        phases[index]["eligibleForComparison"] = false
                        if phases[index]["status"] as? String == "running" {
                            phases[index]["status"] = "timeout"
                        }
                    }
                    report["phases"] = phases
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: timeoutReport, options: .atomic)
                }
                _exit(124)
            }
            deadline.resume()
            // Keep the final deadline armed even if normal termination defers exit.
            RenderCostProbe.terminationDeadline = deadline
            let watchdog = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(88)) } catch { return }
                guard !self.finished else { return }
                self.note("timeout", "capture budget ending; requesting normal exit")
                self.finish(status: "timeout", reason: "capture budget ending; requesting normal exit")
            }
            defer { watchdog.cancel() }

            // These settings belong exclusively to CaptureRun's defaults suite.
            model.settings.performanceMode = false
            model.settings.theme = .dark
            model.settings.hasSeenHydraIntro = true
            model.settings.clearerBackdrop = true
            model.settings.backdropOpacity = 0.5
            defaults.set("upstream", forKey: "floatingGlassStyle")
            await model.bootstrap()
            guard !finished else { return }
            guard model.isLibraryLoaded,
                  model.threads.contains(where: { $0.id == WebsiteCaptures.ID.finalAnswer && $0.lastStatus == .completed }) else {
                finish(status: "failed", reason: "isolated completed mock thread unavailable")
                return
            }
            guard defaults.object(forKey: "wallpaperFile") == nil, !WallpaperStore.shared.hasWallpaper else {
                finish(status: "blocked", reason: "isolated instance has wallpaper; nothing was cleared")
                return
            }

            model.selectedThreadID = WebsiteCaptures.ID.finalAnswer
            let runtime = model.runtime(for: WebsiteCaptures.ID.finalAnswer)
            while runtime.isLoadingHistory, elapsed < 15, !finished {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !finished else { return }
            guard !runtime.isLoadingHistory, !runtime.isRunning else {
                finish(status: "blocked", reason: "mock history not ready or runtime active")
                return
            }
            let stage = Stage(model: model)
            stage.show(size: NSSize(width: 1200, height: 800))
            await stage.ensureActive()
            guard !finished else { return }
            guard let contentWindow = stage.contentWindow else {
                finish(status: "blocked", reason: "Stage content window unavailable")
                return
            }
            window = contentWindow
            expectedFrame = contentWindow.frame
            expectedDisplayID = displayID(contentWindow.screen)
            expectedScale = contentWindow.backingScaleFactor
            captureStageState("after activation")
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(activityChanged), name: NSApplication.didResignActiveNotification, object: NSApp)
            center.addObserver(self, selector: #selector(activityChanged), name: NSWindow.didResignKeyNotification, object: contentWindow)
            center.addObserver(self, selector: #selector(activityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: contentWindow)
            defer { center.removeObserver(self) }

            // Let the initial chat, its neighbouring prebuilds and lazy rows settle
            // before A1, so one-time setup is not charged only to the first variant.
            monitoring = true
            note("warmup", "waiting for initial chat prebuilds")
            try? await Task.sleep(for: .seconds(6))
            guard !finished else { return }
            captureStageState("after initial warmup")
            guard available, interruption == nil, configurationStable else {
                await Recorder(output: output, stage: stage).still("warmup-blocked", stage.captureRect, activate: false)
                finish(status: "blocked", reason: "Stage changed or became unavailable during warmup")
                return
            }
            if let scroll = timelineScroll(in: contentWindow),
               let driver = CaptureTimelineScrolling.driver(in: scroll) {
                for fraction in [0.0, 0.5, 1.0, 0.5, 0.0] {
                    guard let geometry = driver.geometry(), driver.move(geometry.range * fraction) else { break }
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !finished else { return }
                }
            }
            monitoring = false
            captureStageState("after scroll warmup")
            guard available, interruption == nil, configurationStable else {
                finish(status: "blocked", reason: "Stage changed or became unavailable while warming scroll content")
                return
            }
            let recorder = Recorder(output: output, stage: stage)
            for index in phases.indices {
                guard !finished else { return }
                await measure(index, stage: stage, recorder: recorder, runtime: runtime)
            }
            let statuses = phases.compactMap { $0["status"] as? String }
            let status = statuses.allSatisfy { $0 == "completed" } ? "completed"
                : statuses.contains("failed") ? "failed" : "blocked"
            finish(status: status, reason: status == "completed" ? "six phases completed" : "one or more phases excluded; see phase reasons")
        }

        var elapsed: Double { ProcessInfo.processInfo.systemUptime - started }

        func activity() -> [String: Any] {
            guard let window else { return ["available": false] }
            var state: [String: Any] = [
                "appActive": NSApp.isActive, "keyWindow": window.isKeyWindow,
                "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? -1,
                "captureWindowNumber": window.windowNumber,
                "windowVisible": window.isVisible, "miniaturized": window.isMiniaturized,
                "occlusionVisible": window.occlusionState.contains(.visible),
                "occlusionRawValue": window.occlusionState.rawValue,
                "framePoints": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                "expectedFramePoints": expectedFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
                "backingScale": window.backingScaleFactor,
                "expectedBackingScale": expectedScale,
                "configurationStable": configurationStable,
                "interruption": interruption ?? "none",
            ]
            state["displayID"] = displayID(window.screen).map { Int($0) }
            state["expectedDisplayID"] = expectedDisplayID.map { Int($0) }
            return state
        }

        func displayID(_ screen: NSScreen?) -> CGDirectDisplayID? {
            (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }

        func captureStageState(_ label: String) {
            guard stageSnapshots.count < 8 else { return }
            var state = activity()
            state["label"] = label
            state["elapsedSeconds"] = elapsed
            stageSnapshots.append(state)
            save(status: "running", reason: label)
        }

        var available: Bool {
            guard let window else { return false }
            return NSApp.isActive && window.isKeyWindow && window.isVisible
                && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }

        var configurationStable: Bool {
            guard let window, let expectedFrame, let expectedDisplayID else { return false }
            return window.frame == expectedFrame && displayID(window.screen) == expectedDisplayID
                && window.backingScaleFactor == expectedScale
        }

        @objc func activityChanged(_ notification: Notification) {
            guard monitoring else { return }
            if notification.name != NSWindow.didChangeOcclusionStateNotification || !available {
                interruption = "activation, key-window or visible occlusion state lost"
            }
        }

        func controls() -> [String: Any] {
            [
                "performanceMode": model.settings.performanceMode,
                "theme": model.settings.theme.rawValue,
                "floatingGlassStyle": defaults.string(forKey: "floatingGlassStyle") ?? "missing",
                "clearerBackdrop": model.settings.clearerBackdrop,
                "backdropOpacity": model.settings.backdropOpacity,
                "wallpaperPresent": WallpaperStore.shared.hasWallpaper,
                "scrollInput": "SwiftUI ScrollPosition with explicit capture reader intent; no wheel event", "settleSeconds": 1.0,
                "trajectorySeconds": 6.0, "requestedCallbackSeconds": 1.0 / 60.0,
                "trajectory": "normalized triangular 0.1→0.9→0.1, three cycles in six seconds",
                "requestedWindowPoints": [1200, 800],
                "history": "WebsiteCaptures.ID.finalAnswer, fixed capture-only 24-paragraph answer, unchanged across phases",
                "initialWarmupMinimumSeconds": 7.0,
                "controlsAndAnimations": "unchanged throughout all phases",
            ]
        }

        func measure(_ index: Int, stage: Stage, recorder: Recorder, runtime: ThreadRuntime) async {
            let clearer = phases[index]["clearerBackdrop"] as! Bool
            let opacity = phases[index]["backdropOpacity"] as! Double
            let name = phases[index]["name"] as! String
            model.settings.clearerBackdrop = clearer
            model.settings.backdropOpacity = opacity
            interruption = nil
            monitoring = true
            defer { monitoring = false }
            phases[index]["status"] = "running"
            phases[index]["reason"] = "settling"
            phases[index]["controls"] = controls()
            phases[index]["activityStart"] = activity()
            phases[index]["windowSizePoints"] = window.map { [$0.frame.width, $0.frame.height] } ?? []
            phases[index]["screenScale"] = window?.screen?.backingScaleFactor ?? 0
            phases[index]["screenMaximumRefreshHz"] = window?.screen?.maximumFramesPerSecond ?? 0
            if let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               let mode = CGDisplayCopyDisplayMode(number.uint32Value) {
                phases[index]["screenNominalRefreshHz"] = mode.refreshRate
            }
            phases[index]["refreshRateNote"] = "display mode nominal and screen maximum; zero or absent means unknown, adaptive refresh is not measured"
            phases[index]["cpuMeasurementScope"] = "six-second trajectory only; process user and system time"
            note(name, "settling")
            save(status: "running", reason: name)
            let phaseStart = ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .seconds(1))
            guard !finished else { return }
            var reason = interruption
            var failure = false
            var scroll: NSScrollView?
            if !available { reason = "Stage is inactive, hidden or occluded" }
            if !configurationStable { reason = "Stage moved, resized or changed display configuration" }
            if model.selectedThreadID != WebsiteCaptures.ID.finalAnswer || runtime.isRunning {
                reason = "selected completed mock chat changed or became active"
            }
            if let window { scroll = timelineScroll(in: window) }
            if scroll == nil { reason = reason ?? "visible vertical timeline scroll view unavailable" }
            let driver = scroll.flatMap { CaptureTimelineScrolling.driver(in: $0) }
            if driver == nil { reason = reason ?? "capture scroll driver unavailable" }
            if let scroll, let document = scroll.documentView, let driver, let geometry = driver.geometry() {
                let range = geometry.range
                phases[index]["scrollRangePoints"] = range
                if range < 32 { reason = reason ?? "insufficient vertical scroll range (minimum 32 points)" }
                if reason == nil {
                    let clip = scroll.contentView
                    guard driver.move(range * 0.1) else {
                        phases[index]["status"] = "blocked"
                        phases[index]["reason"] = "capture scroll driver detached before trajectory"
                        save(status: "running", reason: name)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    phases[index]["startPositionPoints"] = driver.geometry()?.offset
                    let start = ProcessInfo.processInfo.systemUptime
                    let cpuStart = cpuTime()
                    var previousTime = start
                    var previousY = clip.bounds.origin.y
                    var moved = 0
                    var mismatches = 0
                    var requestedY: CGFloat?
                    var intervals: [Double] = []
                    while !finished {
                        try? await Task.sleep(for: .seconds(1.0 / 60.0))
                        guard !finished else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        let t = now - start
                        if intervals.count < 1000 { intervals.append((now - previousTime) * 1000) }
                        previousTime = now
                        guard available, interruption == nil, configurationStable,
                              scroll.window === window, !scroll.isHiddenOrHasHiddenAncestor,
                              model.selectedThreadID == WebsiteCaptures.ID.finalAnswer, !runtime.isRunning else {
                            reason = interruption ?? "Stage or selected chat became unavailable during trajectory"
                            break
                        }
                        guard scroll.documentView === document, let geometry = driver.geometry(), abs(geometry.range - range) < 1 else {
                            reason = "scroll range changed during trajectory"
                            break
                        }
                        let cycle = min(t, 6).truncatingRemainder(dividingBy: 2)
                        let fraction = 0.1 + 0.8 * (cycle <= 1 ? cycle : 2 - cycle)
                        if let requestedY, abs(geometry.offset - requestedY) > max(12, range * 0.03) { mismatches += 1 }
                        let target = range * fraction
                        guard driver.move(target) else { reason = "capture scroll driver detached"; break }
                        requestedY = target
                        let y = clip.bounds.origin.y
                        if abs(y - previousY) > 0.01 { moved += 1 }
                        previousY = y
                        if t >= 6 { break }
                    }
                    guard !finished else { return }
                    let duration = ProcessInfo.processInfo.systemUptime - start
                    let cpuEnd = cpuTime()
                    phases[index]["trajectoryElapsedSeconds"] = duration
                    phases[index]["endPositionPoints"] = driver.geometry()?.offset
                    phases[index]["overriddenTargetSamples"] = mismatches
                    phases[index]["movementSamples"] = moved
                    phases[index]["driverCallbackSamples"] = intervals.count
                    let sorted = intervals.sorted()
                    if !sorted.isEmpty {
                        phases[index]["driverCallbackDelayMilliseconds"] = [
                            "p50": percentile(sorted, 0.5), "p95": percentile(sorted, 0.95), "max": sorted.last!,
                        ]
                    }
                    if let cpuStart, let cpuEnd {
                        phases[index]["processCPUSeconds"] = ["user": cpuEnd.0 - cpuStart.0, "system": cpuEnd.1 - cpuStart.1]
                    } else {
                        reason = reason ?? "getrusage failed"
                        failure = true
                    }
                    if moved < 2 { reason = reason ?? "trajectory did not move clip-view bounds" }
                    if mismatches > max(2, intervals.count / 5) { reason = reason ?? "trajectory repeatedly overridden or pulled to bottom" }
                    if duration < 6 { reason = reason ?? "trajectory incomplete" }
                }
            }
            phases[index]["phaseMeasurementElapsedSeconds"] = ProcessInfo.processInfo.systemUptime - phaseStart
            phases[index]["controlsEnd"] = controls()
            if model.settings.performanceMode || model.settings.theme != .dark
                || defaults.string(forKey: "floatingGlassStyle") != "upstream"
                || model.settings.clearerBackdrop != clearer || model.settings.backdropOpacity != opacity
                || WallpaperStore.shared.hasWallpaper || !configurationStable
                || window?.frame.size != NSSize(width: 1200, height: 800) {
                reason = reason ?? "controlled settings, wallpaper or window size changed"
            }
            // Recorder's normal path activates before each still; a probe must never repair focus.
            let screenshot = "\(name).png"
            let screenshotURL = output.appendingPathComponent(screenshot)
            // A prior run's PNG must not satisfy this run's capture requirement.
            if FileManager.default.fileExists(atPath: screenshotURL.path) {
                do { try FileManager.default.removeItem(at: screenshotURL) }
                catch {
                    phases[index]["status"] = "failed"
                    phases[index]["reason"] = "could not replace previous probe screenshot"
                    note(name, "could not replace previous probe screenshot")
                    save(status: "running", reason: name)
                    return
                }
            }
            await recorder.still(name, stage.captureRect, activate: false)
            guard !finished else { return }
            let captured = FileManager.default.fileExists(atPath: screenshotURL.path)
            phases[index]["screenshot"] = screenshot
            phases[index]["screenshotSaved"] = captured
            if !captured { reason = reason ?? "static screenshot unavailable"; failure = true }
            if !available || interruption != nil { reason = reason ?? interruption ?? "Stage unavailable after capture" }
            phases[index]["activityEnd"] = activity()
            phases[index]["status"] = reason == nil ? "completed" : failure ? "failed" : "blocked"
            phases[index]["reason"] = reason ?? "six-second programmatic trajectory completed"
            phases[index]["eligibleForComparison"] = reason == nil
            note(name, phases[index]["reason"] as! String)
            save(status: "running", reason: name)
        }

        // Same largest-scroll hierarchy heuristic as TimelineStress, confined to this Stage.
        // A nested scroll view (including horizontal code blocks) cannot be the timeline.
        func timelineScroll(in window: NSWindow) -> NSScrollView? {
            func collect(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(collect)
            }
            guard let root = window.contentView else { return nil }
            return collect(root).filter { scroll in
                guard scroll.window === window, !scroll.isHiddenOrHasHiddenAncestor,
                      !(scroll.documentView is ComposerNSTextView),
                      !scroll.hasHorizontalScroller, scroll.bounds.height > 120, scroll.bounds.width > 200,
                      scroll.visibleRect.width > 200, scroll.visibleRect.height > 120,
                      let document = scroll.documentView,
                      document.bounds.width <= scroll.contentView.bounds.width + 2 else { return false }
                var parent = scroll.superview
                while let current = parent {
                    if current is NSScrollView { return false }
                    parent = current.superview
                }
                return true
            }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        }

        func cpuTime() -> (Double, Double)? {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            return (Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
                    Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000)
        }

        func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }

        func note(_ phase: String, _ message: String) {
            guard events.count < 32 else { return }
            events.append(["elapsedSeconds": elapsed, "phase": phase, "message": message])
        }

        func save(status: String, reason: String) {
            let report: [String: Any] = [
                "schemaVersion": 1, "status": status, "reason": reason,
                "pid": Int(getpid()),
                "elapsedSeconds": elapsed, "budgetSeconds": 90,
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "controls": controls(), "phases": phases, "phaseLog": events, "stageSnapshots": stageSnapshots,
                "measurementScope": "getrusage CPU is this process only; driver callback delay is not presentation FPS, dropped frames or GPU cost",
                "limitations": "programmatic scrolling only; occlusion uses AppKit visibility, not pixel coverage; no real-wheel acceptance",
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("render-cost.json"), options: .atomic)
                let log = events.map { "\($0["elapsedSeconds"]!) \($0["phase"]!) \($0["message"]!)" }.joined(separator: "\n")
                try log.write(to: output.appendingPathComponent("render-cost.log"), atomically: true, encoding: .utf8)
            } catch {
                WebsiteCaptures.log("render-cost report write failed")
            }
        }

        func finish(status: String, reason: String) {
            guard !finished else { return }
            finished = true
            for index in phases.indices where phases[index]["status"] as? String == "running" {
                phases[index]["status"] = status == "timeout" ? "timeout" : "unverified"
                phases[index]["reason"] = reason
                phases[index]["eligibleForComparison"] = false
            }
            note(status, reason)
            save(status: status, reason: reason)
            NSApp.terminate(nil)
        }
    }
}
#endif
