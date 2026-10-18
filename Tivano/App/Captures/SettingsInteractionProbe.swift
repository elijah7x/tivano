#if DEBUG
import AppKit
import Darwin

@MainActor
enum SettingsInteractionProbe {
    private static var terminationDeadline: DispatchSourceTimer?
    private static let ids = [WebsiteCaptures.ID.finalAnswer, WebsiteCaptures.ID.composer, WebsiteCaptures.ID.pricing]

    static func run(model: AppModel) async {
        guard CaptureRun.isEnabled, CommandLine.arguments.contains("--website-captures"),
              CommandLine.arguments.contains("--settings-interaction-probe"),
              let output = CaptureRun.outputDirectory, let defaults = CaptureRun.defaults else { return }
        await Session(model: model, output: output, defaults: defaults).run()
    }

    @MainActor
    private final class Session {
        let model: AppModel
        let output: URL
        let defaults: UserDefaults
        let started = ContinuousClock.now
        let pages = SettingsPage.allCases
        var runtimes: [ThreadRuntime] = []
        var load: HeavyLoadProbe.StationaryTextLoad?
        var window: NSWindow?
        var frame = NSRect.zero
        var screenID: CGDirectDisplayID?
        var scale: CGFloat = 0
        var phases: [[String: Any]] = []
        var loadStopped = false

        init(model: AppModel, output: URL, defaults: UserDefaults) {
            self.model = model
            self.output = output
            self.defaults = defaults
        }

        func seconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }

        func run() async {
            save("blocked", "initializing; probe not yet completed")
            let reportURL = output.appendingPathComponent("settings-interaction.json")
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(wallDeadline: .now() + 150)
            timer.setEventHandler {
                var report: [String: Any] = [:]
                if let data = try? Data(contentsOf: reportURL),
                   let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { report = previous }
                report["status"] = "timeout"
                report["reason"] = "150 second wall deadline; this process only; task cleanup unverified"
                if var phases = report["phases"] as? [[String: Any]] {
                    for index in phases.indices where phases[index]["status"] as? String != "completed" {
                        phases[index]["status"] = "timeout"
                        phases[index]["reason"] = "wall deadline during phase; partial samples only"
                    }
                    report["phases"] = phases
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: reportURL, options: .atomic)
                }
                _exit(124)
            }
            timer.resume()
            SettingsInteractionProbe.terminationDeadline = timer

            guard model === WindowManager.shared.model else {
                await finish("blocked", "capture model differs from WindowManager main-window model"); return
            }
            model.settings.performanceMode = false
            model.settings.theme = .dark
            model.settings.clearerBackdrop = true
            model.settings.backdropOpacity = 0.5
            model.settings.hydraEnabled = false
            model.settings.hasSeenHydraIntro = true
            defaults.set("upstream", forKey: "floatingGlassStyle")
            defaults.set("fullWindow", forKey: "settingsPresentation")
            await model.bootstrap()
            guard model.isLibraryLoaded, SettingsInteractionProbe.ids.allSatisfy({ id in model.threads.contains { $0.id == id } }) else {
                await finish("blocked", "isolated mock library unavailable"); return
            }
            guard defaults.object(forKey: "wallpaperFile") == nil, !WallpaperStore.shared.hasWallpaper else {
                await finish("blocked", "isolated wallpaper unexpectedly present"); return
            }
            runtimes = SettingsInteractionProbe.ids.map { model.runtime(for: $0) }
            let readyDeadline = ContinuousClock.now + .seconds(12)
            while runtimes.contains(where: { $0.isLoadingHistory }), ContinuousClock.now < readyDeadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard runtimes.allSatisfy({ !$0.isLoadingHistory && !$0.isRunning }) else {
                await finish("blocked", "three histories did not become idle and loaded"); return
            }
            for runtime in runtimes { runtime.cancelPersistence() }
            model.selectedThreadID = SettingsInteractionProbe.ids[0]
            if model.sidebar.isVisible { model.sidebar.toggle() }
            WindowManager.shared.hideSettings()
            WindowManager.shared.showMain()
            let windowDeadline = ContinuousClock.now + .seconds(8)
            while NSApp.keyWindow == nil, ContinuousClock.now < windowDeadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            // A locked screen leaves no key window; the diagnostic run takes the main window as is.
            let lockedScreen = CommandLine.arguments.contains("--allow-locked-screen")
            guard let window = NSApp.keyWindow ?? (lockedScreen ? NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 } : nil) else {
                await finish("blocked", "main window unavailable"); return
            }
            self.window = window
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1200, height: 800)), display: true)
            frame = window.frame
            screenID = displayID(window.screen)
            scale = window.backingScaleFactor
            try? await Task.sleep(for: .seconds(6))
            guard problem(settings: false, loaded: false) == nil, timelineScroll() != nil else {
                await finish("blocked", problem(settings: false, loaded: false) ?? "main vertical timeline unavailable"); return
            }

            guard await switches("idle-switch", loaded: false),
                  await heartbeat("idle-heartbeat", loaded: false, covered: true) else {
                await finish("blocked", "idle phase failed; see phase reason"); return
            }
            WindowManager.shared.hideSettings()
            try? await Task.sleep(for: .seconds(1))
            guard problem(settings: false, loaded: false) == nil,
                  let load = HeavyLoadProbe.startStationaryTextLoad(model: model) else {
                await finish("blocked", "stationary load could not start with the chat selected"); return
            }
            self.load = load
            guard await load.waitUntilRunning() else {
                await finish("blocked", "three rehearsals did not enter running state"); return
            }
            guard await switches("load-switch", loaded: true),
                  await heartbeat("load-heartbeat-covered", loaded: true, covered: true) else {
                await finish("blocked", "covered load phase failed; see phase reason"); return
            }
            WindowManager.shared.hideSettings()
            try? await Task.sleep(for: .seconds(1))
            guard await heartbeat("load-heartbeat-chat", loaded: true, covered: false) else {
                await finish("blocked", "visible chat phase failed; see phase reason"); return
            }
            await finish("completed", "all five phases completed")
        }

        func switches(_ name: String, loaded: Bool) async -> Bool {
            WindowManager.shared.showSettings(page: .general)
            try? await Task.sleep(for: .milliseconds(500))
            let index = begin(name, loaded: loaded)
            let start = ContinuousClock.now
            let cpuStart = cpuTime()
            var samples: [String: [String: [Double]]] = [:]
            var issue = problem(settings: true, loaded: loaded)
            for _ in 0..<3 {
                for page in pages {
                    guard issue == nil else { break }
                    observeLoad(index)
                    let switchStart = ContinuousClock.now
                    SettingsNavigation.shared.page = page
                    window?.contentView?.layoutSubtreeIfNeeded()
                    window?.displayIfNeeded()
                    let syncEnd = ContinuousClock.now
                    await Task.yield()
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    let settleEnd = ContinuousClock.now
                    var values = samples[page.rawValue] ?? ["syncMilliseconds": [], "settleMilliseconds": []]
                    values["syncMilliseconds", default: []].append(seconds(switchStart.duration(to: syncEnd)) * 1000)
                    values["settleMilliseconds", default: []].append(seconds(switchStart.duration(to: settleEnd)) * 1000)
                    samples[page.rawValue] = values
                    phases[index]["pages"] = samples.mapValues { values -> [String: Any] in
                        ["syncMilliseconds": values["syncMilliseconds"] ?? [],
                         "settleMilliseconds": values["settleMilliseconds"] ?? [],
                         "syncSummary": distribution(values["syncMilliseconds"] ?? []),
                         "settleSummary": distribution(values["settleMilliseconds"] ?? [])]
                    }
                    observeLoad(index)
                    issue = problem(settings: true, loaded: loaded)
                    updateTiming(index, start: start, cpuStart: cpuStart)
                    save("blocked", "\(name) in progress; partial samples")
                    try? await Task.sleep(for: .milliseconds(250))
                    issue = issue ?? problem(settings: true, loaded: loaded)
                }
            }
            return end(index, start: start, cpuStart: cpuStart, issue: issue)
        }

        func heartbeat(_ name: String, loaded: Bool, covered: Bool) async -> Bool {
            if covered {
                SettingsNavigation.shared.page = .providers
                try? await Task.sleep(for: .milliseconds(500))
            }
            let index = begin(name, loaded: loaded)
            phases[index]["page"] = covered ? "providers" : "chat"
            let start = ContinuousClock.now
            let cpuStart = cpuTime()
            var previous = start
            var nextSave = start + .seconds(1)
            var gaps: [Double] = []
            var issue = problem(settings: covered, loaded: loaded)
            while issue == nil, seconds(start.duration(to: .now)) < 5 {
                try? await Task.sleep(for: .milliseconds(4))
                let current = ContinuousClock.now
                gaps.append(seconds(previous.duration(to: current)) * 1000)
                previous = current
                observeLoad(index)
                issue = problem(settings: covered, loaded: loaded)
                if current >= nextSave {
                    phases[index]["heartbeatGapMilliseconds"] = gaps
                    phases[index]["heartbeatSummary"] = distribution(gaps)
                    updateTiming(index, start: start, cpuStart: cpuStart)
                    save("blocked", "\(name) in progress; partial samples")
                    nextSave = current + .seconds(1)
                }
            }
            phases[index]["heartbeatGapMilliseconds"] = gaps
            phases[index]["heartbeatSummary"] = distribution(gaps)
            return end(index, start: start, cpuStart: cpuStart, issue: issue)
        }

        func begin(_ name: String, loaded: Bool) -> Int {
            phases.append(["name": name, "status": "blocked", "reason": "phase in progress",
                           "loadExpected": loaded, "loadRunningAtStart": load?.isRunning == true,
                           "loadRunningAtEverySample": load?.isRunning == true,
                           "loadObservationCount": 1])
            save("blocked", "\(name) in progress")
            return phases.count - 1
        }

        func observeLoad(_ index: Int) {
            phases[index]["loadRunningAtEverySample"] = phases[index]["loadRunningAtEverySample"] as? Bool == true && load?.isRunning == true
            phases[index]["loadObservationCount"] = (phases[index]["loadObservationCount"] as? Int ?? 0) + 1
            phases[index]["loadRunningAtEnd"] = load?.isRunning == true
        }

        func updateTiming(_ index: Int, start: ContinuousClock.Instant, cpuStart: (Double, Double)?) {
            phases[index]["wallSeconds"] = seconds(start.duration(to: .now))
            if let a = cpuStart, let b = cpuTime() {
                phases[index]["processCPUSeconds"] = ["user": b.0 - a.0, "system": b.1 - a.1, "total": b.0 + b.1 - a.0 - a.1]
            }
        }

        func end(_ index: Int, start: ContinuousClock.Instant, cpuStart: (Double, Double)?, issue: String?) -> Bool {
            observeLoad(index)
            updateTiming(index, start: start, cpuStart: cpuStart)
            let reason = issue ?? (phases[index]["processCPUSeconds"] == nil ? "getrusage unavailable" : nil)
            phases[index]["status"] = reason == nil ? "completed" : "blocked"
            phases[index]["reason"] = reason ?? "phase completed"
            save("blocked", "probe in progress; last phase: \(phases[index]["name"] ?? "unknown")")
            return reason == nil
        }

        func problem(settings: Bool, loaded: Bool) -> String? {
            guard let window else { return "main window inactive, hidden or occluded" }
            if !CommandLine.arguments.contains("--allow-locked-screen") {
                guard NSApp.isActive, window.isKeyWindow, window.isVisible,
                      !window.isMiniaturized, window.occlusionState.contains(.visible) else { return "main window inactive, hidden or occluded" }
            }
            guard screenID != nil, window.frame == frame, displayID(window.screen) == screenID,
                  window.backingScaleFactor == scale, window.frame.size == NSSize(width: 1200, height: 800) else {
                return "main window moved, resized or changed screen/scale"
            }
            guard SettingsNavigation.shared.isPresented == settings, WindowManager.shared.usesFullWindowSettings,
                  model.selectedThreadID == SettingsInteractionProbe.ids[0], !model.settings.performanceMode,
                  model.settings.theme == .dark, model.settings.clearerBackdrop, model.settings.backdropOpacity == 0.5,
                  defaults.string(forKey: "floatingGlassStyle") == "upstream", !WallpaperStore.shared.hasWallpaper else {
                return "settings presentation, selected chat or fixed visual controls changed"
            }
            if loaded { return load?.isRunning == true ? nil : "all three load runtimes were not running" }
            return runtimes.contains(where: { $0.isRunning }) ? "idle phase requires all three runtimes stopped" : nil
        }

        func timelineScroll() -> NSScrollView? {
            func collect(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(collect)
            }
            guard let window, let root = window.contentView else { return nil }
            return collect(root).filter { scroll in
                guard scroll.window === window, !scroll.isHiddenOrHasHiddenAncestor,
                      !(scroll.documentView is ComposerNSTextView), !scroll.hasHorizontalScroller,
                      scroll.bounds.width > 400, scroll.bounds.height > 120,
                      scroll.visibleRect.width > 400, scroll.visibleRect.height > 120,
                      let document = scroll.documentView,
                      document.bounds.width <= scroll.contentView.bounds.width + 2 else { return false }
                var parent = scroll.superview
                while let view = parent {
                    if view is NSScrollView { return false }
                    parent = view.superview
                }
                return true
            }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        }

        func displayID(_ screen: NSScreen?) -> CGDirectDisplayID? {
            (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }

        func cpuTime() -> (Double, Double)? {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            return (Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
                    Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000)
        }

        func distribution(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["count": 0] }
            func quantile(_ q: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * q)) - 1))] }
            return ["count": sorted.count, "p50": quantile(0.5), "p95": quantile(0.95), "p99": quantile(0.99),
                    "max": sorted.last!, "countOver16_7Milliseconds": sorted.filter { $0 > 16.7 }.count,
                    "countOver50Milliseconds": sorted.filter { $0 > 50 }.count]
        }

        func save(_ status: String, _ reason: String) {
            let report: [String: Any] = [
                "schemaVersion": 1, "status": status, "reason": reason, "pid": Int(getpid()),
                "elapsedSeconds": seconds(started.duration(to: .now)), "budgetSeconds": 150,
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "lockedScreenDiagnostic": CommandLine.arguments.contains("--allow-locked-screen"),
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "pageOrder": pages.map(\.rawValue), "rounds": 3, "switchPauseMilliseconds": 250,
                "heartbeatSeconds": 5, "heartbeatSleepMilliseconds": 4, "phases": phases,
                "loadStopped": loadStopped, "runtimeRunning": runtimes.map(\.isRunning),
                "load": "three fixed capture threads; stationary text-only heavy-load fixture; one delta per thread every 50 ms; extended up to 2400 deltas or 140 seconds; no catch-up bursts",
                "persistence": "CaptureRun isolated library/defaults; runtime persistence explicitly disabled after histories load",
                "timingSemantics": "sync includes page assignment, layoutSubtreeIfNeeded and displayIfNeeded; settle is cumulative from assignment through Task.yield and a main-queue continuation; neither proves GPU presentation",
                "limitations": "heartbeat gaps are not FPS; CPU and wall windows include bounded progress saves; load state sampled on the main actor; page measurements retain normal caches and animations; AppKit visibility cannot prove pixel coverage",
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("settings-interaction.json"), options: .atomic)
            } catch { WebsiteCaptures.log("settings-interaction report write failed: \(error)") }
        }

        // Optional stills after every measured phase and workload cleanup; never part of timing samples.
        func captureSettingsStills() async {
            guard let window else { return }
            let stage = Stage(model: model)
            let recorder = Recorder(output: output, stage: stage)
            var captures: [[String: Any]] = []
            for page in [SettingsPage.general, .providers, .models] {
                WindowManager.shared.showSettings(page: page)
                try? await Task.sleep(for: .milliseconds(700))
                let before = problem(settings: true, loaded: false)
                let name = "settings-\(page.rawValue)"
                if before == nil { await recorder.still(name, window.frame, activate: false) }
                let after = problem(settings: true, loaded: false)
                let exists = NSImage(contentsOf: output.appendingPathComponent(name + ".png")) != nil
                let f = window.frame
                captures.append([
                    "page": page.rawValue, "status": before == nil && after == nil && exists ? "captured" : "blocked",
                    "reason": before ?? after ?? (exists ? "pending-visual-inspection" : "screenshot-missing"),
                    "screenshot": name + ".png", "framePoints": [f.minX, f.minY, f.width, f.height],
                    "scale": window.backingScaleFactor, "displayID": displayID(window.screen) ?? 0,
                    "appActive": NSApp.isActive, "keyWindow": window.isKeyWindow,
                ])
            }
            let evidence: [String: Any] = ["schemaVersion": 1, "outsideMeasuredPhases": true,
                "visualReview": "unverified", "captures": captures]
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("settings-visual.json"), options: .atomic)
            }
            WindowManager.shared.hideSettings()
        }

        func finish(_ status: String, _ reason: String) async {
            if let load { loadStopped = await load.stop() }
            else { loadStopped = runtimes.allSatisfy { !$0.isRunning } }
            WindowManager.shared.hideSettings()
            save(loadStopped ? status : "blocked", loadStopped ? reason : "three runtimes did not finish after stopping the load")
            if status == "completed", loadStopped, CommandLine.arguments.contains("--settings-probe-captures") {
                await captureSettingsStills()
            }
            // Kept open for external interaction checks: the window's frame is written out and
            // a `stop` file in the output directory ends the hold early.
            if CommandLine.arguments.contains("--hold-for-interaction") {
                SettingsInteractionProbe.terminationDeadline?.cancel()
                if !model.sidebar.isVisible { model.sidebar.toggle() }
                if let window {
                    let f = window.frame, screen = window.screen?.frame ?? .zero
                    let hold: [String: Any] = ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height,
                                               "screenHeight": screen.height, "windowNumber": window.windowNumber]
                    if let data = try? JSONSerialization.data(withJSONObject: hold) {
                        try? data.write(to: output.appendingPathComponent("hold.json"))
                    }
                }
                let stop = output.appendingPathComponent("stop")
                let until = ContinuousClock.now + .seconds(600)
                while ContinuousClock.now < until, !FileManager.default.fileExists(atPath: stop.path) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
