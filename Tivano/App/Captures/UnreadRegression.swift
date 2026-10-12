#if DEBUG
import AppKit

/// Uses the real model and AppKit probe in the capture process's isolated library.
/// Run with --website-captures <folder> --unread-regression.
@MainActor
enum UnreadRegression {
    private static var results: [[String: String]] = []
    private static let first = WebsiteCaptures.composerThreadID
    private static let second = WebsiteCaptures.freshThreadID

    static func run(model: AppModel) async {
        guard let output = CaptureRun.outputDirectory else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            record("timeout", false)
            finish()
        }
        await model.bootstrap()
        guard model.isLibraryLoaded, model.thread(first) != nil, model.thread(second) != nil else {
            record("library", false)
            finish()
        }
        model.settings.hasSeenHydraIntro = true
        model.settings.hydraEnabled = false
        model.settings.notifyWhenFinished = false
        model.settings.chimeWhenFinished = false

        // No suspension here: the mounted timeline cannot consume these revisions first.
        for status: TurnStatus in [.completed, .failed, .interrupted] {
            publish(model, first, status: status)
            let revision = model.thread(first)?.unreadRevision
            model.openThread(first)
            record("open-\(status)", model.thread(first)?.hasUnread == false
                && model.thread(first)?.lastStatus == status
                && model.thread(first)?.unreadRevision == revision)
            publish(model, first, status: status)
            model.openThread(first)
            record("repeat-open-\(status)", model.thread(first)?.hasUnread == false)
        }
        publish(model, first)
        let oldRevision = model.thread(first)?.unreadRevision
        publish(model, first)
        let newRevision = model.thread(first)?.unreadRevision
        model.markRead(first, revision: oldRevision)
        record("stale-receipt", oldRevision != newRevision && model.thread(first)?.hasUnread == true)
        publish(model, second)
        model.openThread(first)
        record("other-thread-preserved", model.thread(second)?.hasUnread == true)
        model.selectedThreadID = second
        record("programmatic-selection-preserved", model.thread(second)?.hasUnread == true)
        model.selectThread(offset: 0)
        record("keyboard-current-thread", model.thread(second)?.hasUnread == false)
        if let index = model.sidebarThreads.firstIndex(where: { $0.id == first }) {
            publish(model, first)
            model.selectThread(number: index + 1)
            record("keyboard-number", model.selectedThreadID == first && model.thread(first)?.hasUnread == false)
        } else { record("keyboard-number", false) }

        let finishedTurn = UUID()
        model.turnFinished(first, status: .completed, continues: false, turnID: finishedTurn, userStopped: false)
        model.openThread(first)
        model.turnFinished(first, status: .completed, continues: false, turnID: finishedTurn, userStopped: false)
        record("duplicate-completion-stays-read", model.thread(first)?.hasUnread == false)
        model.turnFinished(first, status: .completed, continues: true, turnID: UUID(), userStopped: false)
        record("queued-successor-no-terminal-unread", model.thread(first)?.hasUnread == false)
        model.turnFinished(first, status: .interrupted, continues: false, turnID: UUID(), userStopped: true)
        record("user-stop-no-unread", model.thread(first)?.hasUnread == false)
        model.updateThread(first) { $0.hasUnread = true; $0.unreadRevision = nil }
        model.openThread(first)
        record("legacy-nil-revision", model.thread(first)?.hasUnread == false)

        for id in model.threads.map(\.id) {
            model.markRead(id, revision: model.thread(id)?.unreadRevision)
        }
        publish(model, second)
        record("dock-unread", NSApp.dockTile.badgeLabel == "1")
        record("persist-unread-write", model.flushForQuit())
        if case .success(let stored) = Storage.loadLibrary() {
            record("persist-unread-read", stored.threads.first { $0.id == second }?.hasUnread == true)
        } else { record("persist-unread-read", false) }
        model.openThread(second)
        record("dock-read", NSApp.dockTile.badgeLabel == nil)
        record("persist-read-write", model.flushForQuit())
        if case .success(let stored) = Storage.loadLibrary() {
            record("persist-read-read", stored.threads.first { $0.id == second }?.hasUnread == false)
        } else { record("persist-read-read", false) }
        for unread in [true, false] {
            record("approval-\(unread)", ThreadActivityStatus.resolve(lastStatus: .completed, hasUnread: unread,
                needsApproval: true, needsAnswer: false, isWorking: true) == .approval)
            record("question-\(unread)", ThreadActivityStatus.resolve(lastStatus: .completed, hasUnread: unread,
                needsApproval: false, needsAnswer: true, isWorking: true) == .question)
            record("working-\(unread)", ThreadActivityStatus.resolve(lastStatus: .completed, hasUnread: unread,
                needsApproval: false, needsAnswer: false, isWorking: true) == .running)
        }

        let stage = Stage(model: model)
        stage.show(size: Stage.wide)
        await stage.ensureActive()
        guard let window = NSApp.keyWindow, NSApp.isActive else {
            record("foreground-window", false)
            finish()
        }
        let recorder = Recorder(output: output, stage: stage)
        model.openThread(first)
        await pause(0.6)
        publish(model, second)
        await pause(0.4)
        record("background-result-unread", model.thread(second)?.hasUnread == true)
        await recorder.still("unread-before-open", stage.captureRect)
        clickFirstSidebarRow(in: window)
        record("sidebar-button-open", model.selectedThreadID == second
            && model.thread(second)?.hasUnread == false)
        publish(model, second)
        clickFirstSidebarRow(in: window)
        record("sidebar-button-repeat", model.thread(second)?.hasUnread == false)
        await pause(0.4)
        record("visible-open-read", model.thread(second)?.hasUnread == false)
        await recorder.still("unread-after-open", stage.captureRect)
        publish(model, second)
        await pause(0.8)
        record("visible-new-result-read", model.thread(second)?.hasUnread == false)
        await stage.ensureActive()
        WebsiteCaptures.log("unread target: window=\(window.windowNumber) key=\(window.isKeyWindow) title=\(window.title)")
        var windowObservers: [NSObjectProtocol] = []
        for name in [NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                WebsiteCaptures.log("unread window notification: \(note.name.rawValue)")
            })
        }
        defer { windowObservers.forEach(NotificationCenter.default.removeObserver) }
        window.miniaturize(nil)
        for _ in 0..<120 {
            if window.isMiniaturized { break }
            await pause(0.1)
        }
        WebsiteCaptures.log("unread mini-before: \(window.isMiniaturized), window=\(window.windowNumber), visible=\(window.isVisible), policy=\(NSApp.activationPolicy().rawValue), style=\(window.styleMask.rawValue), key=\(window.isKeyWindow), main=\(window.isMainWindow), button=\(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)")
        WebsiteCaptures.log("unread actual-window: ax=\(window.isAccessibilityMinimized()) occlusion=\(window.occlusionState.rawValue) frame=\(window.frame)")
        if window.isMiniaturized {
            publish(model, second)
            await pause(2.2)
            record("minimized-result-unread", window.isMiniaturized && model.thread(second)?.hasUnread == true)
            window.deminiaturize(nil)
            await stage.ensureActive()
            await pause(0.8)
            record("deminiaturized-read", !window.isMiniaturized && window.isVisible
                && NSApp.isActive && model.thread(second)?.hasUnread == false)
        } else {
            recordBlocked("minimized-result-unread", "NSWindow did not enter miniaturized state within 12 seconds")
            recordBlocked("deminiaturized-read", "Minimization precondition was not reached")
            await stage.ensureActive()
        }
        NSApp.hide(nil)
        await pause(0.5)
        publish(model, second)
        await pause(2.2)
        record("hidden-result-unread", NSApp.isHidden && model.thread(second)?.hasUnread == true)
        NSApp.unhide(nil)
        await stage.ensureActive()
        await pause(0.8)
        record("unhidden-read", model.thread(second)?.hasUnread == false)
        window.orderOut(nil)
        await pause(0.3)
        publish(model, second)
        await pause(2.2)
        record("ordered-out-result-unread", !window.isVisible && model.thread(second)?.hasUnread == true)
        await stage.ensureActive()
        await pause(0.8)
        record("ordered-front-read", model.thread(second)?.hasUnread == false)
        let otherApp = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.activationPolicy == .regular && !$0.isTerminated
                && $0.bundleIdentifier == "com.apple.finder"
        }
        if let otherApp {
            NSApp.yieldActivation(to: otherApp)
            otherApp.activate(options: [.activateIgnoringOtherApps])
        }
        await pause(0.5)
        publish(model, second)
        await pause(2.2)
        record("inactive-result-unread", !NSApp.isActive && model.thread(second)?.hasUnread == true)
        await stage.ensureActive()
        await pause(0.8)
        record("reactivated-read", model.thread(second)?.hasUnread == false)
        model.openThread(first)
        await pause(0.5)
        publish(model, first)
        await pause(0.8)
        record("populated-timeline-new-result-read", model.thread(first)?.hasUnread == false)

        // A separate probe gives deterministic empty-layout and stale-callback scenarios.
        model.openThread(second)
        await pause(0.4)
        let probe = ThreadResultReadProbe.ResultView(frame: .zero)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        window.contentView?.addSubview(container)
        container.addSubview(probe)
        publish(model, first)
        configure(probe, model, first)
        await pause(0.35)
        WebsiteCaptures.log("unread empty probe: frame=\(probe.frame) bounds=\(probe.bounds) visible=\(probe.visibleRect) readable=\(probe.isReadableWindow)")
        record("empty-rect-preserved", model.thread(first)?.hasUnread == true)
        probe.frame = container.bounds
        // No explicit scheduleRead: the original retry must survive repeated updates.
        for _ in 0..<20 {
            configure(probe, model, first)
            await pause(0.02)
        }
        await pause(0.4)
        record("late-layout-read-with-updates", model.thread(first)?.hasUnread == false)
        probe.frame = .zero
        publish(model, first)
        configure(probe, model, first)
        await pause(0.1)
        publish(model, first)
        await pause(0.3)
        record("queued-old-revision-preserved", model.thread(first)?.hasUnread == true)
        probe.frame = container.bounds
        configure(probe, model, first)
        await pause(0.4)
        record("new-revision-read", model.thread(first)?.hasUnread == false)
        container.isHidden = true
        publish(model, first)
        configure(probe, model, first)
        await pause(2.2)
        record("hidden-ancestor-preserved", model.thread(first)?.hasUnread == true)
        container.isHidden = false
        await pause(0.5)
        record("unhidden-ancestor-read", model.thread(first)?.hasUnread == false)
        probe.frame = .zero
        publish(model, first)
        configure(probe, model, first)
        await pause(2.2)
        record("exhausted-retries-preserve-unread", model.thread(first)?.hasUnread == true)
        probe.frame = container.bounds
        probe.needsLayout = true
        probe.layoutSubtreeIfNeeded()
        await pause(0.4)
        record("layout-after-retry-budget-reads", model.thread(first)?.hasUnread == false)
        probe.frame = .zero
        publish(model, first)
        configure(probe, model, first)
        await pause(0.1)
        configure(probe, model, second)
        probe.frame = container.bounds
        await pause(0.4)
        record("probe-switch-preserves-old-thread", model.thread(first)?.hasUnread == true)
        configure(probe, model, first)
        probe.invalidate()
        probe.removeFromSuperview()
        await pause(0.4)
        record("dismantled-probe-preserves-unread", model.thread(first)?.hasUnread == true)
        container.removeFromSuperview()
        for name in ["unread-before-open", "unread-after-open"] {
            record("screenshot-\(name)", FileManager.default.fileExists(atPath: output.appendingPathComponent(name + ".png").path))
        }
        finish()
    }

    private static func publish(_ model: AppModel, _ id: UUID, status: TurnStatus = .completed) {
        model.turnFinished(id, status: status, continues: false, turnID: UUID(), userStopped: false)
    }

    private static func configure(_ probe: ThreadResultReadProbe.ResultView, _ model: AppModel, _ id: UUID) {
        probe.configure(model: model, threadID: id, revision: model.thread(id)?.unreadRevision,
                        hasUnread: model.thread(id)?.hasUnread == true)
        probe.scheduleRead()
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func clickFirstSidebarRow(in window: NSWindow) {
        // Fixed capture fixture: the first row occupies y=115...160 from the window top.
        let point = NSPoint(x: 100, y: window.frame.height - 135)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
    }

    private static func recordBlocked(_ name: String, _ reason: String) {
        results.append(["name": name, "result": "blocked", "reason": reason])
        WebsiteCaptures.log("unread \(name): blocked — \(reason)")
        saveResults()
    }

    private static func record(_ name: String, _ passed: Bool) {
        results.append(["name": name, "result": passed ? "pass" : "fail"])
        WebsiteCaptures.log("unread \(name): \(passed ? "pass" : "fail")")
        if !passed {
            func describe(_ view: NSView) {
                if let probe = view as? ThreadResultReadProbe.ResultView {
                    WebsiteCaptures.log("probe \(probe.threadID?.uuidString ?? "nil") frame=\(probe.frame) visible=\(probe.visibleRect) readable=\(probe.isReadableWindow)")
                }
                for child in view.subviews { describe(child) }
            }
            for window in NSApp.windows {
                WebsiteCaptures.log("window \(window.windowNumber) title=\(window.title) visible=\(window.isVisible) mini=\(window.isMiniaturized)")
                if let content = window.contentView { describe(content) }
            }
        }
        saveResults()
    }

    private static func saveResults() {
        if let output = CaptureRun.outputDirectory,
           let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("unread-regression.json"), options: .atomic)
        }
    }

    private static func finish() -> Never {
        if results.contains(where: { $0["result"] == "fail" }) { exit(1) }
        exit(results.contains { $0["result"] == "blocked" } ? 2 : 0)
    }
}
#endif
