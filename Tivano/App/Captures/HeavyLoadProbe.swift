#if DEBUG
import AppKit
import Darwin

/// Isolated, deterministic event traffic; programmatic scrolling is not wheel acceptance.
@MainActor
enum HeavyLoadProbe {
    private static var terminationDeadline: DispatchSourceTimer?
    private static let ids = [WebsiteCaptures.ID.finalAnswer, WebsiteCaptures.ID.composer, WebsiteCaptures.ID.pricing]

    static func run(model: AppModel) async {
        guard CaptureRun.isEnabled, CommandLine.arguments.contains("--website-captures"),
              CommandLine.arguments.contains("--heavy-load-probe"),
              let output = CaptureRun.outputDirectory, let defaults = CaptureRun.defaults else { return }
        await Session(model: model, output: output, defaults: defaults).run()
    }

    @MainActor
    private final class Session: NSObject {
        let model: AppModel
        let output: URL
        let defaults: UserDefaults
        let usesExternalWheel = CommandLine.arguments.contains("--manual-wheel-probe")
        let usesStationaryLoad = CommandLine.arguments.contains("--stationary-load-probe")
        let textOnly = CommandLine.arguments.contains("--text-only-load-probe")
        let linkedText = CommandLine.arguments.contains("--linked-text-load-probe")
        let resumesSameID = CommandLine.arguments.contains("--resumed-id-stress-probe")
        var messageCount: Int { textOnly || resumesSameID ? 1 : 20 }
        var drivesScroll: Bool { !usesExternalWheel && !usesStationaryLoad }
        let started = ProcessInfo.processInfo.systemUptime
        var runtimes: [ThreadRuntime] = []
        var phases = ["idle-before", "three-thread-load", "idle-after"].map {
            ["name": $0, "status": "unverified", "reason": "not started", "eligibleForComparison": false] as [String: Any]
        }
        var log: [[String: Any]] = []
        var sent = [Int](repeating: 0, count: 3)
        var eventsSent = [Int](repeating: 0, count: 3)
        var completionSent = [Bool](repeating: false, count: 3)
        var threadReports: [[String: Any]] = []
        var replay: Task<Void, Never>?
        var scrollTask: Task<Void, Never>?
        var replayDone = false
        var stopped = false
        var window: NSWindow?
        var frame = NSRect.zero
        var screenID: CGDirectDisplayID?
        var scale: CGFloat = 0
        var interruption: String?

        init(model: AppModel, output: URL, defaults: UserDefaults) {
            self.model = model
            self.output = output
            self.defaults = defaults
        }

        var now: Double { ProcessInfo.processInfo.systemUptime }
        var elapsed: Double { now - started }

        func run() async {
            save("running", "initializing")
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let reportURL = output.appendingPathComponent("heavy-load.json")
            timer.schedule(wallDeadline: .now() + 120)
            timer.setEventHandler {
                var report: [String: Any] = [:]
                if let data = try? Data(contentsOf: reportURL),
                   let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { report = previous }
                report["status"] = "timeout"
                report["reason"] = "120 second wall deadline; this process only; task cleanup unverified"
                if var phases = report["phases"] as? [[String: Any]] {
                    for index in phases.indices {
                        phases[index]["eligibleForComparison"] = false
                        phases[index]["eligibleForTimingComparison"] = false
                        if phases[index]["status"] as? String == "running" { phases[index]["status"] = "unverified" }
                    }
                    report["phases"] = phases
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: reportURL, options: .atomic)
                }
                _exit(124)
            }
            timer.resume()
            HeavyLoadProbe.terminationDeadline = timer

            model.settings.performanceMode = false
            model.settings.theme = .dark
            model.settings.clearerBackdrop = true
            model.settings.backdropOpacity = 0.5
            model.settings.hydraEnabled = false
            model.settings.hasSeenHydraIntro = true
            defaults.set("upstream", forKey: "floatingGlassStyle")
            await model.bootstrap()
            guard model.isLibraryLoaded, HeavyLoadProbe.ids.allSatisfy({ id in model.threads.contains { $0.id == id } }) else {
                await finish("blocked", "isolated mock library unavailable"); return
            }
            guard defaults.object(forKey: "wallpaperFile") == nil, !WallpaperStore.shared.hasWallpaper else {
                await finish("blocked", "isolated wallpaper unexpectedly present"); return
            }
            runtimes = HeavyLoadProbe.ids.map { model.runtime(for: $0) }
            let readyDeadline = now + 12
            while runtimes.contains(where: { $0.isLoadingHistory }), now < readyDeadline, elapsed < 100 {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard runtimes.allSatisfy({ !$0.isLoadingHistory && !$0.isRunning }) else {
                await finish("blocked", "three histories did not become idle and loaded"); return
            }
            // Rehearse itself does not disable saves. Do this only after history loading.
            for runtime in runtimes { runtime.cancelPersistence() }
            threadReports = runtimes.enumerated().map { snapshot($0.element, index: $0.offset) }
            model.selectedThreadID = HeavyLoadProbe.ids[0]
            if model.sidebar.isVisible { model.sidebar.toggle() }
            let stage = Stage(model: model)
            stage.show(size: NSSize(width: 1200, height: 800))
            await stage.ensureActive()
            guard let content = stage.contentWindow else {
                await finish("blocked", "Stage content window unavailable"); return
            }
            window = content
            frame = content.frame
            screenID = displayID(content.screen)
            scale = content.backingScaleFactor
            let center = NotificationCenter.default
            for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification,
                         NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didChangeBackingPropertiesNotification, NSWindow.didMiniaturizeNotification] {
                center.addObserver(self, selector: #selector(changed), name: name,
                                   object: name == NSApplication.didResignActiveNotification ? NSApp : content)
            }
            defer { center.removeObserver(self) }
            note("warmup", "three histories loaded; runtime persistence disabled")
            try? await Task.sleep(for: .seconds(6))
            guard problem() == nil, timelineScroll() != nil else {
                await finish("blocked", problem() ?? "main vertical timeline unavailable"); return
            }
            let recorder = Recorder(output: output, stage: stage)
            for index in phases.indices {
                guard !stopped else { break }
                if index != 1 && runtimes.contains(where: { $0.isRunning }) {
                    await finish("blocked", "idle phase requires all three runtimes stopped"); return
                }
                await measure(index, stage: stage, recorder: recorder)
                if phases[index]["eligibleForComparison"] as? Bool != true {
                    // Invalid samples never become a before/after comparison.
                    await finish("blocked", "phase excluded; see phase reason"); return
                }
            }
            await finish("completed", usesStationaryLoad ? "three phases completed; stationary stream, no scroll input"
                : usesExternalWheel
                ? "three phases completed; external wheel accepted during load; no normalized timing comparison"
                : "three phases completed; programmatic scrolling only")
        }

        @objc func changed(_ notification: Notification) {
            if notification.name == NSWindow.didChangeOcclusionStateNotification,
               window?.occlusionState.contains(.visible) == true { return }
            if [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification].contains(notification.name),
               let window, window.frame == frame, displayID(window.screen) == screenID,
               window.backingScaleFactor == scale { return }
            interruption = "window activation, visibility, geometry or display changed: \(notification.name.rawValue)"
        }

        func displayID(_ screen: NSScreen?) -> CGDirectDisplayID? {
            (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }

        func windowState() -> [String: Any] {
            guard let window else { return ["available": false] }
            return [
                "appActive": NSApp.isActive, "keyWindow": window.isKeyWindow,
                "captureWindowNumber": window.windowNumber, "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? -1,
                "visible": window.isVisible, "occlusionVisible": window.occlusionState.contains(.visible),
                "framePoints": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                "expectedFramePoints": [frame.minX, frame.minY, frame.width, frame.height],
                "displayID": Int(displayID(window.screen) ?? 0), "expectedDisplayID": Int(screenID ?? 0),
                "scale": window.backingScaleFactor, "expectedScale": scale,
                "interruption": interruption ?? "none",
            ]
        }

        func problem() -> String? {
            if let interruption { return interruption }
            guard let window, NSApp.isActive, window.isKeyWindow, window.isVisible,
                  !window.isMiniaturized, window.occlusionState.contains(.visible) else { return "inactive, hidden or occluded Stage" }
            guard screenID != nil, window.frame == frame, displayID(window.screen) == screenID, window.backingScaleFactor == scale,
                  window.frame.size == NSSize(width: 1200, height: 800) else { return "window moved, resized or changed screen/scale" }
            guard model.selectedThreadID == HeavyLoadProbe.ids[0], !model.settings.performanceMode,
                  model.settings.theme == .dark, model.settings.clearerBackdrop, model.settings.backdropOpacity == 0.5,
                  defaults.string(forKey: "floatingGlassStyle") == "upstream", !WallpaperStore.shared.hasWallpaper else {
                return "selected chat or fixed visual controls changed"
            }
            return nil
        }

        func measure(_ index: Int, stage: Stage, recorder: Recorder) async {
            let name = phases[index]["name"] as! String
            guard let scroll = timelineScroll(), let document = scroll.documentView,
                  let driver = CaptureTimelineScrolling.driver(in: scroll) else {
                phases[index]["status"] = "blocked"; phases[index]["reason"] = "main timeline unavailable"; return
            }
            phases[index]["status"] = "running"
            phases[index]["threadsBefore"] = runtimes.enumerated().map { snapshot($0.element, index: $0.offset) }
            phases[index]["windowStateStart"] = windowState()
            note(name, "started")
            save("running", name)
            let nativeStart = LinkTextView.captureMutationCounts()
            let start = now
            let cpuStart = cpuTime()
            let wheelStart = CaptureTimelineScrolling.acceptedWheelEvents
            replayDone = index != 1
            if index == 1 {
                for runtime in runtimes { runtime.rehearseTurn("Heavy load probe: deterministic local fixture.") }
                guard runtimes.allSatisfy({ $0.isRunning }) else {
                    phases[index]["status"] = "blocked"; phases[index]["reason"] = "rehearsals did not enter running state"; return
                }
                replay = Task { @MainActor in await self.sendLoad() }
            }
            scrollTask = Task { @MainActor in
                var previousTime = start
                var previousY = driver.geometry()?.offset ?? 0
                var intervals: [Double] = []
                var samples: [[String: Double]] = []
                var moves = 0
                var mismatches = 0
                var rangeMin = Double.greatestFiniteMagnitude
                var rangeMax = 0.0
                var reason: String?
                var requestedY: CGFloat?
                while !Task.isCancelled, !self.stopped, self.elapsed < 104 {
                    do { try await Task.sleep(for: .seconds(1.0 / 60.0)) } catch { break }
                    let current = self.now
                    let t = current - start
                    intervals.append((current - previousTime) * 1000)
                    previousTime = current
                    if let issue = self.problem() { reason = issue; break }
                    guard scroll.window === self.window, !scroll.isHiddenOrHasHiddenAncestor,
                          scroll.documentView === document else { reason = "main timeline changed"; break }
                    guard let geometry = driver.geometry() else { reason = "capture scroll geometry unavailable"; break }
                    let range = geometry.range
                    rangeMin = min(rangeMin, Double(range)); rangeMax = max(rangeMax, Double(range))
                    if range < 32 { reason = "insufficient current vertical range"; break }
                    let observed = geometry.offset
                    if abs(observed - previousY) > 0.5 { moves += 1 }
                    if let requestedY, abs(observed - requestedY) > max(12, range * 0.03) { mismatches += 1 }
                    // Stay clear of both anchors; repeat the same six-second path in all phases.
                    let cycle = t.truncatingRemainder(dividingBy: 2)
                    let fraction = 0.1 + 0.8 * (cycle <= 1 ? cycle : 2 - cycle)
                    let target = range * fraction
                    if samples.count < 5000 {
                        var sample = ["elapsedSeconds": t, "rangePoints": Double(range), "observedY": Double(observed)]
                        if self.drivesScroll { sample["targetY"] = Double(target) }
                        samples.append(sample)
                    }
                    previousY = observed
                    if self.drivesScroll {
                        requestedY = target
                        guard driver.move(target) else { reason = "capture scroll driver detached"; break }
                    }
                    if index == 1 ? self.replayDone : t >= 6 { break }
                }
                if self.elapsed >= 104 { reason = reason ?? "capture cleanup budget reached" }
                let wheels = CaptureTimelineScrolling.acceptedWheelEvents - wheelStart
                if self.drivesScroll || (self.usesExternalWheel && index == 1) {
                    if moves < 2 { reason = reason ?? "clip bounds did not move across callbacks" }
                }
                if self.usesExternalWheel, index == 1, wheels < 2 {
                    reason = reason ?? "fewer than two external wheel events entered the timeline monitor"
                }
                if mismatches > max(2, intervals.count / 5) { reason = reason ?? "trajectory repeatedly overridden or pulled to bottom" }
                if self.now - start < 6 { reason = reason ?? "trajectory shorter than six seconds" }
                self.phases[index]["scrollSamples"] = samples
                self.phases[index]["rangeMinPoints"] = rangeMin.isFinite && rangeMin != Double.greatestFiniteMagnitude ? rangeMin : 0
                self.phases[index]["rangeMaxPoints"] = rangeMax
                self.phases[index]["observedMovementSamples"] = moves
                self.phases[index]["overriddenTargetSamples"] = mismatches
                self.phases[index]["driverCallbackIntervalMilliseconds"] = self.distribution(intervals)
                self.phases[index]["driverCallbackCount"] = intervals.count
                self.phases[index]["acceptedWheelEvents"] = wheels
                self.phases[index]["reason"] = reason ?? "trajectory completed"
                self.phases[index]["eligibleForComparison"] = reason == nil
                self.phases[index]["eligibleForTimingComparison"] = reason == nil && !self.usesExternalWheel
            }
            await scrollTask?.value
            let trajectoryEnd = now
            let cpuEnd = cpuTime()
            phases[index]["nativeStorageMutations"] = LinkTextView.captureMutationCounts()
            phases[index]["nativeStorageMutationsAtStart"] = nativeStart
            scrollTask?.cancel(); await scrollTask?.value; scrollTask = nil
            if index == 1 {
                // A failed scroll cancels traffic rather than finishing a partial turn as a full sample.
                if phases[index]["eligibleForComparison"] as? Bool != true { replay?.cancel() }
                await replay?.value
                replay?.cancel(); await replay?.value; replay = nil
                let full = sent.allSatisfy { $0 == 240 } && completionSent.allSatisfy { $0 }
                let ended = runtimes.allSatisfy { !$0.isRunning }
                let applied = reconcile()
                phases[index]["allInputsSent"] = full
                phases[index]["allRuntimesStopped"] = ended
                phases[index]["appliedStateMatches"] = applied
                if !full || !ended || !applied {
                    phases[index]["eligibleForComparison"] = false
                    phases[index]["reason"] = "incomplete inputs, completion wait or applied state; see threads"
                }
            }
            phases[index]["monotonicElapsedSeconds"] = trajectoryEnd - start
            if let a = cpuStart, let b = cpuEnd {
                phases[index]["processCPUSeconds"] = ["user": b.0 - a.0, "system": b.1 - a.1]
            } else {
                phases[index]["eligibleForComparison"] = false
                phases[index]["reason"] = "getrusage unavailable"
            }
            phases[index]["threadsAfter"] = runtimes.enumerated().map { snapshot($0.element, index: $0.offset) }
            phases[index]["windowStateEnd"] = windowState()
            let url = output.appendingPathComponent("\(name).png")
            try? FileManager.default.removeItem(at: url)
            await recorder.still(name, stage.captureRect, activate: false)
            let captured = FileManager.default.fileExists(atPath: url.path)
            phases[index]["screenshot"] = url.lastPathComponent
            phases[index]["screenshotSaved"] = captured
            if !captured || problem() != nil {
                phases[index]["eligibleForComparison"] = false
                phases[index]["reason"] = problem() ?? "current process screenshot unavailable"
            }
            phases[index]["status"] = phases[index]["eligibleForComparison"] as? Bool == true ? "completed" : "blocked"
            phases[index]["eligibleForTimingComparison"] = !usesExternalWheel && phases[index]["eligibleForComparison"] as? Bool == true
            note(name, phases[index]["reason"] as? String ?? "unverified")
            save("running", name)
        }

        func chunk(_ thread: Int, _ number: Int) -> String {
            let startsMessage = number == 1 || (!textOnly && !resumesSameID && (number - 1).isMultiple(of: 12))
            let reference = linkedText && startsMessage ? " [local fixture](file:///capture-only/fixture.swift)" : ""
            return "Thread \(thread + 1), increment \(String(format: "%03d", number)): fixed local event payload for foreground response measurement.\(reference)\n"
        }

        func messageID(_ thread: Int, number: Int = 1) -> String {
            let group = textOnly || resumesSameID ? 1 : (number - 1) / 12 + 1
            return "heavy-message-\(thread + 1)-\(group)"
        }
        func toolID(_ thread: Int, _ group: Int) -> String { "heavy-tool-\(thread + 1)-\(group)" }
        func toolText(_ thread: Int, _ group: Int) -> String { "Local fixture thread \(thread + 1), tool group \(group): complete.\n" }

        func sendLoad() async {
            let start = now
            for number in 1...240 {
                guard !Task.isCancelled, !stopped, elapsed < 100 else { break }
                for (index, runtime) in runtimes.enumerated() {
                    runtime.rehearse(.messageDelta(id: messageID(index, number: number), text: chunk(index, number)))
                    sent[index] += 1; eventsSent[index] += 1
                    if !textOnly, number.isMultiple(of: 12) {
                        if !resumesSameID {
                            runtime.rehearse(.messageCompleted(id: messageID(index, number: number), text: ""))
                            eventsSent[index] += 1
                        }
                        let group = number / 12
                        let id = toolID(index, group)
                        runtime.rehearse(.toolStarted(id: id, call: ToolCall(kind: .read, title: "Read local fixture", detail: "capture-only fixed text")))
                        runtime.rehearse(.toolOutput(id: id, text: toolText(index, group)))
                        runtime.rehearse(.toolUpdated(id: id, update: ToolUpdate(status: .completed)))
                        eventsSent[index] += 3
                    }
                }
                if number.isMultiple(of: 60) { save("running", "load progress") }
                // No catch-up bursts: overload extends elapsed time rather than dropping inputs.
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
            phases[1]["inputElapsedSeconds"] = now - start
            for (index, runtime) in runtimes.enumerated() where sent[index] == 240 && !Task.isCancelled {
                if textOnly || resumesSameID {
                    runtime.rehearse(.messageCompleted(id: messageID(index), text: ""))
                    eventsSent[index] += 1
                }
                runtime.rehearse(.turnCompleted(status: .completed, error: nil))
                eventsSent[index] += 1; completionSent[index] = true
            }
            let waitStart = now
            while runtimes.contains(where: { $0.isRunning }), now - waitStart < 8, elapsed < 110, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { break }
            }
            phases[1]["completionWaitSeconds"] = now - waitStart
            phases[1]["completionWaitSucceeded"] = runtimes.allSatisfy { !$0.isRunning }
            replayDone = true
        }

        func reconcile() -> Bool {
            var allMatch = true
            threadReports = runtimes.enumerated().map { index, runtime in
                var report = snapshot(runtime, index: index)
                let messages = (1...messageCount).compactMap { group in
                    runtime.entries.first { $0.id == messageID(index, number: (group - 1) * 12 + 1) }.flatMap { entry -> AssistantMessage? in
                        if case .assistant(let message) = entry.item.content { return message }; return nil
                    }
                }
                let answer = messages.map(\.text).joined()
                let completedMessages = messages.count(where: { !$0.isStreaming })
                var prefix = ""
                var applied = 0
                for number in 1...240 {
                    prefix += chunk(index, number)
                    if answer.hasPrefix(prefix) { applied = number } else { break }
                }
                var toolsApplied = 0
                for group in 1...20 {
                    if let entry = runtime.entries.first(where: { $0.id == toolID(index, group) }),
                       case .tool(let tool) = entry.item.content,
                       tool.status == .completed, tool.output == toolText(index, group) { toolsApplied += 1 }
                }
                let exact = answer == (1...240).map { chunk(index, $0) }.joined()
                let match = exact && applied == 240 && completedMessages == messageCount
                    && toolsApplied == (textOnly ? 0 : 20) && !runtime.isRunning && completionSent[index]
                allMatch = allMatch && match
                report["messageDeltasSent"] = sent[index]
                report["messageDeltasReconciledInFinalText"] = applied
                report["toolGroupsReconciled"] = toolsApplied
                report["providerEventsSent"] = eventsSent[index]
                report["providerEventsReconciledFromState"] = applied + toolsApplied * 3 + completedMessages + (!runtime.isRunning && completionSent[index] ? 1 : 0)
                report["completedMessagesReconciled"] = completedMessages
                report["exactFinalText"] = exact
                report["completionSent"] = completionSent[index]
                report["completionWaitSucceeded"] = !runtime.isRunning && completionSent[index]
                report["matches"] = match
                return report
            }
            return allMatch
        }

        func snapshot(_ runtime: ThreadRuntime, index: Int) -> [String: Any] {
            let bytes = runtime.entries.reduce(0) { result, entry in
                switch entry.item.content {
                case .user(let value): return result + value.text.utf8.count
                case .assistant(let value): return result + value.text.utf8.count
                case .reasoning(let value): return result + value.text.utf8.count
                case .tool(let value): return result + value.output.utf8.count
                default: return result
                }
            }
            return ["threadID": HeavyLoadProbe.ids[index].uuidString, "entries": runtime.entries.count,
                    "turns": runtime.turns.count, "textBytes": bytes, "isRunning": runtime.isRunning,
                    "isLoadingHistory": runtime.isLoadingHistory]
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

        func cpuTime() -> (Double, Double)? {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            return (Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
                    Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000)
        }

        func distribution(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [:] }
            func quantile(_ q: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * q)) - 1))] }
            return ["p50": quantile(0.5), "p95": quantile(0.95), "max": sorted.last!]
        }

        func note(_ phase: String, _ message: String) {
            guard log.count < 32 else { return }
            log.append(["elapsedSeconds": elapsed, "phase": phase, "message": message])
        }

        func save(_ status: String, _ reason: String) {
            let report: [String: Any] = [
                "schemaVersion": 1, "status": status, "reason": reason, "pid": Int(getpid()),
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "elapsedSeconds": elapsed, "budgetSeconds": 120, "phases": phases, "phaseLog": log,
                "windowState": windowState(),
                "threads": threadReports, "messageDeltasSent": sent, "providerEventsSent": eventsSent,
                "scrollInput": usesStationaryLoad ? "none; normal content following"
                    : usesExternalWheel ? "external native input; no programmatic position writes" : "programmatic ScrollPosition",
                "timingComparison": usesStationaryLoad ? "stationary deterministic traffic; no UI input; callback intervals are not FPS"
                    : usesExternalWheel ? "ineligible: external input is not a normalized trajectory; automation observation may add cost" : "normalized programmatic trajectory only",
                "textRenderer": CommandLine.arguments.contains("--native-plain-text-probe") ? "diagnostic native plain text; typography parity unaccepted" : "normal product routing",
                "nativeStorage": CommandLine.arguments.contains("--legacy-native-render-probe") ? "original full replacement" : "identical attributed prefix permits incremental append",
                "parameters": ["threadCount": 3, "messageDeltasPerThread": 240, "targetIntervalMilliseconds": 50,
                               "toolEveryDeltas": textOnly ? 0 : 12, "toolEventsPerGroup": 3,
                               "providerEventsPerThread": 241 + (textOnly ? 0 : 60) + messageCount,
                               "assistantMessagesPerThread": messageCount, "resumesSameIDAfterTool": !textOnly && resumesSameID,
                               "linkedText": linkedText, "idlePhaseSeconds": 6, "driverCallbackSeconds": 1.0 / 60.0,
                               "windowPoints": [1200, 800], "performanceMode": false, "theme": "dark",
                               "floatingGlassStyle": "upstream", "clearerBackdrop": true, "backdropOpacity": 0.5,
                               "wallpaper": false, "animationsAndRefreshRate": "unchanged",
                               "trajectory": usesStationaryLoad ? "none; no position writes or native input"
                                : usesExternalWheel ? "external native wheel; no normalized trajectory"
                                : "SwiftUI ScrollPosition capture with explicit reader intent; programmatic normalized triangular 0.1→0.9→0.1 every two seconds; current range each callback"],
                "persistence": "explicitly disabled per runtime after loading; rehearsal alone does not disable it; excludes snapshot saving and actual disk load",
                "countSemantics": "sent counts are rehearse calls; applied counts reconcile numbered final text and completed tool output, not per-handler instrumentation; rehearseTurn excluded",
                "textBytesScope": "UTF-8 user, assistant, reasoning text and tool output only; excludes metadata and rendered memory",
                "limitations": (usesStationaryLoad ? "Stationary deterministic traffic; no scrolling or automation observation. "
                    : usesExternalWheel ? "External native input; automation observation may add cost, not a controlled timing comparison. " : "Programmatic ScrollPosition, not real wheel acceptance. ")
                    + "Callback intervals are not FPS, dropped frames or GPU time; getrusage is process CPU until scroll task completion, excluding final reconciliation/screenshots; includes bounded progress writes; AppKit visibility cannot prove pixel coverage; no provider, model, head or real build task",
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("heavy-load.json"), options: .atomic)
                let lines = log.map { "\($0["elapsedSeconds"]!) \($0["phase"]!) \($0["message"]!)" }.joined(separator: "\n")
                try lines.write(to: output.appendingPathComponent("heavy-load.log"), atomically: true, encoding: .utf8)
            } catch { WebsiteCaptures.log("heavy-load report write failed: \(error)") }
        }

        func finish(_ status: String, _ reason: String) async {
            stopped = true
            replay?.cancel(); scrollTask?.cancel()
            await replay?.value; await scrollTask?.value
            replay = nil; scrollTask = nil
            if !runtimes.isEmpty { _ = reconcile() }
            if status != "completed" {
                for index in phases.indices {
                    phases[index]["eligibleForComparison"] = false
                    phases[index]["eligibleForTimingComparison"] = false
                    if phases[index]["status"] as? String == "running" { phases[index]["status"] = "unverified" }
                }
            }
            note(status, reason)
            save(status, reason)
            NSApp.terminate(nil)
        }
    }
}
#endif
