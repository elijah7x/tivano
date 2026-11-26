#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import ScreenCaptureKit

/// Debug-only live blank-reply monitor and thread-selection hook for real sessions.
///
/// Enable by setting `TIVANO_BLANK_WATCH` to an absolute directory path OR passing
/// `--blank-watch <dir>` (e.g. `open -n "Tivano Dev.app" --args --blank-watch /tmp/blank-watch`).
/// Does nothing unless explicitly enabled, and compiles out completely in Release builds.
@MainActor
final class BlankWatch {
    private static let selectThreadNotification = Notification.Name("dev.tivano.debug.selectThread")
    private static let scanIntervalSeconds: TimeInterval = 1.5
    private static let heartbeatIntervalSeconds: TimeInterval = 30.0
    private static let offscreenRecaptureDelayMs: Int = 100
    /// Same thresholds as `FoldReplyRepro`.
    nonisolated private static let inkLuminanceDeltaThreshold: Double = 0.25
    nonisolated private static let blankInkRatioThreshold: Double = 0.005

    private static var shared: BlankWatch?

    static func startIfEnabled(model: AppModel) {
        guard shared == nil else { return }
        guard let resolved = resolveOutputDirectory() else { return }
        do {
            try FileManager.default.createDirectory(at: resolved.url, withIntermediateDirectories: true)
        } catch {
            NSLog("BlankWatch: failed to create directory %@: %@", resolved.url.path, error.localizedDescription)
            return
        }
        let watch = BlankWatch(model: model, outputDirectory: resolved.url, activationSource: resolved.source)
        shared = watch
        watch.start()
    }

    private static func resolveOutputDirectory() -> (url: URL, source: String)? {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--blank-watch"), args.indices.contains(idx + 1) {
            let raw = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("/") {
                return (URL(fileURLWithPath: raw, isDirectory: true), "arg:--blank-watch")
            }
        }
        for arg in args where arg.hasPrefix("--blank-watch=") {
            let raw = String(arg.dropFirst("--blank-watch=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("/") {
                return (URL(fileURLWithPath: raw, isDirectory: true), "arg:--blank-watch")
            }
        }
        if let raw = ProcessInfo.processInfo.environment["TIVANO_BLANK_WATCH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("/") {
            return (URL(fileURLWithPath: raw, isDirectory: true), "env:TIVANO_BLANK_WATCH")
        }
        return nil
    }

    // MARK: - Instance state

    private weak var model: AppModel?
    private let io: BlankWatchIO
    private let activationSource: String
    private var scanTimer: Timer?
    private var heartbeatTimer: Timer?
    private var selectThreadObserver: (any NSObjectProtocol)?
    private var isScanning = false

    private var scanCount: Int = 0
    private var lastScanViewCount: Int = 0
    private var lastScanWindowCount: Int = 0
    private var captureFailureCount: Int = 0
    private var lastCaptureFailureReason: String?
    private var lastLoggedCaptureFailureReason: String?

    private var eventSequence: Int = 0
    private var consecutiveBlankCounts: [ObjectIdentifier: Int] = [:]
    private var activeBlankEvents: [ObjectIdentifier: ActiveBlankEvent] = [:]

    private init(model: AppModel, outputDirectory: URL, activationSource: String) {
        self.model = model
        self.io = BlankWatchIO(directory: outputDirectory)
        self.activationSource = activationSource
    }

    private func start() {
        let preflight = CGPreflightScreenCaptureAccess()
        log("start source=\(activationSource) dir=\(io.directory.path) pid=\(ProcessInfo.processInfo.processIdentifier) screenCapturePreflight=\(preflight)")
        if !preflight {
            log("warning screenCapturePreflight=false; ScreenCaptureKit capture may fail until Screen Recording permission is granted")
        }

        selectThreadObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.selectThreadNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let rawObject = notification.object as? String
            Task { @MainActor [weak self] in
                self?.handleSelectThreadNotification(rawObject: rawObject)
            }
        }

        let scan = Timer.scheduledTimer(withTimeInterval: Self.scanIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runScanIfIdle()
            }
        }
        scan.tolerance = 0.1
        scanTimer = scan

        let heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitHeartbeat()
            }
        }
        heartbeat.tolerance = 1.0
        heartbeatTimer = heartbeat
    }

    // MARK: - Select-thread hook

    private func handleSelectThreadNotification(rawObject: String?) {
        let trimmed: String = rawObject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let threadID = UUID(uuidString: trimmed) else {
            let sanitizedRaw: String = Self.sanitizeLogValue(rawObject ?? "nil")
            log("selectThread ignored reason=invalid_uuid raw=\(sanitizedRaw)")
            return
        }
        guard let model: AppModel = model else {
            log("selectThread ignored reason=model_deallocated threadID=\(threadID.uuidString)")
            return
        }

        model.appSpace = AppSpace.session
        let windows: [NSWindow] = NSApp.windows
        for window: NSWindow in windows where window is ThreadWindow && window.isMiniaturized {
            window.deminiaturize(nil)
        }
        WindowManager.shared.hideSettings()
        WindowManager.shared.showMain(activating: false)
        let hasVisibleThreadWindow: Bool = NSApp.windows.contains { (window: NSWindow) -> Bool in
            let isThreadWindow: Bool = window is ThreadWindow
            let isShown: Bool = window.isVisible && !window.isMiniaturized
            return isThreadWindow && isShown && window.occlusionState.contains(.visible)
        }
        if !hasVisibleThreadWindow {
            NSApp.unhide(nil)
            WindowManager.shared.showMain(activating: true)
        }

        let previousID: String = model.selectedThreadID?.uuidString ?? "none"
        guard let thread: ChatThread = model.thread(threadID) else {
            log("selectThread not_found threadID=\(threadID.uuidString) prev=\(previousID) libraryLoaded=\(model.isLibraryLoaded) threads=\(model.threadCount)")
            return
        }
        model.openThread(threadID)
        let sanitizedTitle: String = Self.sanitizeLogValue(thread.displayTitle)
        log("selectThread ok threadID=\(threadID.uuidString) prev=\(previousID) title=\"\(sanitizedTitle)\" appActive=\(NSApp.isActive)")
    }

    // MARK: - Periodic scan

    private func runScanIfIdle() async {
        guard !isScanning else { return }
        if ScrollActivity.shared.isScrolling { return }
        isScanning = true
        defer { isScanning = false }

        // Drop active blank records for views that have been deallocated.
        activeBlankEvents = activeBlankEvents.filter { $0.value.view != nil }

        let visibleWindows = NSApp.windows.filter {
            $0.isVisible
                && !$0.isMiniaturized
                && $0.occlusionState.contains(.visible)
                && $0.frame.width > 1
                && $0.frame.height > 1
                && $0.contentView != nil
        }

        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        var plans: [WindowScanPlan] = []
        var weakViewsByID: [ObjectIdentifier: WeakLinkTextView] = [:]
        var totalViews = 0

        for window in visibleWindows {
            let linkViews = Self.findAllLinkTextViews(in: window.contentView)
            var targets: [ViewScanTarget] = []
            for view in linkViews {
                guard let storage = view.textStorage, storage.length > 0 else { continue }
                guard !view.isHiddenOrHasHiddenAncestor else { continue }
                let rawVisibleRect = view.visibleRect
                guard !rawVisibleRect.isNull, !rawVisibleRect.isEmpty,
                      rawVisibleRect.width > 1, rawVisibleRect.height > 1 else { continue }

                var windowRect = view.convert(rawVisibleRect, to: nil)
                if let scroll = view.enclosingScrollView, let document = scroll.documentView {
                    let unobstructed = Self.unobstructedViewportRect(in: scroll, document: document)
                    windowRect = windowRect.intersection(document.convert(unobstructed, to: nil))
                }
                if let contentView = window.contentView {
                    windowRect = windowRect.intersection(contentView.convert(contentView.bounds, to: nil))
                }
                guard !windowRect.isNull, !windowRect.isEmpty,
                      windowRect.width > 1, windowRect.height > 1 else { continue }

                let screenRect = window.convertToScreen(windowRect)
                let viewID = ObjectIdentifier(view)
                weakViewsByID[viewID] = WeakLinkTextView(view)
                targets.append(ViewScanTarget(
                    viewID: viewID,
                    visibleRectInWindow: windowRect,
                    visibleRectInScreen: screenRect
                ))
            }

            totalViews += targets.count
            guard !targets.isEmpty else { continue }

            guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { continue }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
            let displayBoundsCG = CGDisplayBounds(displayID)
            let captureScreenRect = window.frame.intersection(screen.frame)
            guard !captureScreenRect.isNull, !captureScreenRect.isEmpty,
                  captureScreenRect.width > 1, captureScreenRect.height > 1 else { continue }

            plans.append(WindowScanPlan(
                windowNumber: window.windowNumber,
                windowTitle: window.title,
                displayID: displayID,
                displayBoundsCG: displayBoundsCG,
                primaryDisplayHeight: primaryDisplayHeight,
                backingScaleFactor: screen.backingScaleFactor,
                captureScreenRect: captureScreenRect,
                targets: targets
            ))
        }

        scanCount += 1
        lastScanWindowCount = visibleWindows.count
        lastScanViewCount = totalViews

        guard !plans.isEmpty else {
            consecutiveBlankCounts.removeAll()
            return
        }

        let scanPlans = plans
        let batch = await Task.detached(priority: .utility) {
            await Self.captureAndAnalyzeBatch(plans: scanPlans)
        }.value

        if let contentError = batch.contentError {
            recordCaptureFailure(contentError)
            return
        }

        var succeededViewIDs = Set<ObjectIdentifier>()
        var failedWindowViewIDs = Set<ObjectIdentifier>()
        var pendingOffscreenChecks: [PendingOffscreenCheck] = []

        for outcome in batch.windows {
            if let error = outcome.captureError {
                recordCaptureFailure("window=\(outcome.plan.windowNumber): \(error)")
                for target in outcome.plan.targets {
                    failedWindowViewIDs.insert(target.viewID)
                }
                continue
            }

            let targetsByID = Dictionary(uniqueKeysWithValues: outcome.plan.targets.map { ($0.viewID, $0) })

            for result in outcome.results {
                guard result.totalPixels > 0 else { continue }
                succeededViewIDs.insert(result.viewID)

                if result.isBlank {
                    let streak = (consecutiveBlankCounts[result.viewID] ?? 0) + 1
                    consecutiveBlankCounts[result.viewID] = streak

                    if streak >= 2, activeBlankEvents[result.viewID] == nil {
                        guard let view = weakViewsByID[result.viewID]?.value,
                              let window = view.window,
                              let target = targetsByID[result.viewID] else { continue }

                        let eventID = nextEventID()
                        let detectedAt = Date.now
                        let cropFilename: String? = result.croppedImage != nil ? "\(eventID)-crop.png" : nil
                        let eventRecord = Self.buildBlankEventRecord(
                            eventID: eventID,
                            timestamp: Self.isoTimestamp(detectedAt),
                            view: view,
                            window: window,
                            cropRectInWindow: target.visibleRectInWindow,
                            result: result,
                            cropPNG: cropFilename
                        )

                        activeBlankEvents[result.viewID] = ActiveBlankEvent(
                            eventID: eventID,
                            detectedAt: detectedAt,
                            windowTitle: window.title,
                            view: view
                        )

                        let cropImage = result.croppedImage
                        await writeJSONEventNow(eventRecord)
                        if let cropImage, let cropFilename {
                            let writer = io
                            Task.detached(priority: .utility) {
                                let saved = await writer.saveCropPNG(cropImage, filename: cropFilename)
                                if !saved {
                                    await writer.appendLog("[\(Self.isoTimestamp())] error failed_to_save_png file=\(cropFilename)")
                                }
                            }
                        }

                        log(String(
                            format: "blank_detected eventID=%@ viewID=%@ ink=%.3f%% len=%d window=\"%@\" text=\"%@\"",
                            eventID,
                            Self.formatViewID(result.viewID),
                            result.inkRatio * 100,
                            eventRecord.textStorageLength,
                            Self.sanitizeLogValue(window.title),
                            Self.sanitizeLogValue(eventRecord.textPrefix)
                        ))

                        pendingOffscreenChecks.append(PendingOffscreenCheck(
                            eventID: eventID,
                            viewID: result.viewID,
                            windowTitle: window.title,
                            medianLuminance: result.medianLuminance
                        ))
                    }
                } else {
                    consecutiveBlankCounts.removeValue(forKey: result.viewID)
                    if let active = activeBlankEvents.removeValue(forKey: result.viewID) {
                        let now = Date.now
                        let duration = ((now.timeIntervalSince(active.detectedAt)) * 1000).rounded() / 1000
                        let view = weakViewsByID[result.viewID]?.value
                        let window = view?.window
                        let textPrefix = view.map { String(($0.textStorage?.string ?? $0.string).prefix(24)) } ?? ""
                        let recovered = RecoveredEventRecord(
                            kind: "recovered",
                            eventID: active.eventID,
                            timestamp: Self.isoTimestamp(now),
                            windowTitle: window?.title ?? active.windowTitle,
                            viewID: Self.formatViewID(result.viewID),
                            textPrefix: textPrefix,
                            inkRatio: result.inkRatio,
                            durationSeconds: duration,
                            windowIsKey: window?.isKeyWindow ?? false,
                            appIsActive: NSApp.isActive
                        )
                        writeJSONEvent(recovered)
                        log(String(
                            format: "recovered eventID=%@ viewID=%@ ink=%.3f%% duration=%.3fs",
                            active.eventID,
                            Self.formatViewID(result.viewID),
                            result.inkRatio * 100,
                            duration
                        ))
                    }
                }
            }
        }

        // Reset streaks for views that left the screen (preserve streaks for windows whose capture failed).
        consecutiveBlankCounts = consecutiveBlankCounts.filter { key, _ in
            succeededViewIDs.contains(key) || failedWindowViewIDs.contains(key)
        }

        for check in pendingOffscreenChecks {
            await performOffscreenControlCheck(check, weakViewsByID: weakViewsByID)
        }
    }

    // MARK: - One-time offscreen control check

    private func performOffscreenControlCheck(
        _ check: PendingOffscreenCheck,
        weakViewsByID: [ObjectIdentifier: WeakLinkTextView]
    ) async {
        guard let view = weakViewsByID[check.viewID]?.value,
              view.window != nil else { return }

        let visibleRect = view.visibleRect
        let offscreenImage: CGImage?
        if !visibleRect.isNull, !visibleRect.isEmpty, visibleRect.width > 1, visibleRect.height > 1,
           let rep = view.bitmapImageRepForCachingDisplay(in: visibleRect) {
            view.cacheDisplay(in: visibleRect, to: rep)
            offscreenImage = rep.cgImage
        } else {
            offscreenImage = nil
        }

        let backgroundLuminance: CGFloat = check.medianLuminance > 0
            ? CGFloat(check.medianLuminance)
            : Self.resolvedBackgroundLuminance(for: view)

        let offscreenInkRatio: Double? = if let offscreenImage {
            await Task.detached(priority: .utility) {
                Self.computeInkMetrics(from: offscreenImage, opaqueBackgroundLuminance: backgroundLuminance)?.inkRatio
            }.value
        } else {
            nil
        }

        try? await Task.sleep(for: .milliseconds(Self.offscreenRecaptureDelayMs))

        var screenInkRatioAfterOffscreen: Double?
        var afterCaptureError: String?

        if let currentView = weakViewsByID[check.viewID]?.value,
           let currentWindow = currentView.window,
           currentWindow.isVisible,
           !currentWindow.isMiniaturized,
           currentWindow.occlusionState.contains(.visible),
           let plan = Self.makeSingleViewPlan(view: currentView, window: currentWindow) {
            let afterOutcome = await Task.detached(priority: .utility) {
                await Self.captureAndAnalyzeBatch(plans: [plan])
            }.value
            if let contentError = afterOutcome.contentError {
                afterCaptureError = contentError
                recordCaptureFailure(contentError)
            } else if let first = afterOutcome.windows.first {
                if let err = first.captureError {
                    afterCaptureError = err
                    recordCaptureFailure("offscreen-recapture window=\(plan.windowNumber): \(err)")
                } else {
                    screenInkRatioAfterOffscreen = first.results.first?.inkRatio
                }
            }
        } else {
            afterCaptureError = "view_or_window_unavailable_after_100ms"
        }

        let record = OffscreenCheckRecord(
            kind: "offscreen_check",
            eventID: check.eventID,
            timestamp: Self.isoTimestamp(),
            windowTitle: check.windowTitle,
            viewID: Self.formatViewID(check.viewID),
            offscreenInkRatio: offscreenInkRatio,
            screenInkRatioAfterOffscreen: screenInkRatioAfterOffscreen,
            afterCaptureError: afterCaptureError
        )
        writeJSONEvent(record)

        let offscreenStr = offscreenInkRatio.map { String(format: "%.3f%%", $0 * 100) } ?? "nil"
        let afterStr = screenInkRatioAfterOffscreen.map { String(format: "%.3f%%", $0 * 100) } ?? "nil"
        log("offscreen_check eventID=\(check.eventID) viewID=\(Self.formatViewID(check.viewID)) offscreenInk=\(offscreenStr) screenAfter=\(afterStr) error=\(afterCaptureError ?? "none")")
    }

    private static func makeSingleViewPlan(view: LinkTextView, window: NSWindow) -> WindowScanPlan? {
        let rawVisibleRect = view.visibleRect
        guard !rawVisibleRect.isNull, !rawVisibleRect.isEmpty,
              rawVisibleRect.width > 1, rawVisibleRect.height > 1 else { return nil }
        var windowRect = view.convert(rawVisibleRect, to: nil)
        if let scroll = view.enclosingScrollView, let document = scroll.documentView {
            let unobstructed = unobstructedViewportRect(in: scroll, document: document)
            windowRect = windowRect.intersection(document.convert(unobstructed, to: nil))
        }
        if let contentView = window.contentView {
            windowRect = windowRect.intersection(contentView.convert(contentView.bounds, to: nil))
        }
        guard !windowRect.isNull, !windowRect.isEmpty,
              windowRect.width > 1, windowRect.height > 1 else { return nil }

        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        let displayBoundsCG = CGDisplayBounds(displayID)
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let captureScreenRect = window.frame.intersection(screen.frame)
        guard !captureScreenRect.isNull, !captureScreenRect.isEmpty,
              captureScreenRect.width > 1, captureScreenRect.height > 1 else { return nil }

        let target = ViewScanTarget(
            viewID: ObjectIdentifier(view),
            visibleRectInWindow: windowRect,
            visibleRectInScreen: window.convertToScreen(windowRect)
        )
        return WindowScanPlan(
            windowNumber: window.windowNumber,
            windowTitle: window.title,
            displayID: displayID,
            displayBoundsCG: displayBoundsCG,
            primaryDisplayHeight: primaryDisplayHeight,
            backingScaleFactor: screen.backingScaleFactor,
            captureScreenRect: captureScreenRect,
            targets: [target]
        )
    }

    // MARK: - Heartbeat & logging

    private func emitHeartbeat() {
        let failureReason = lastCaptureFailureReason.map(Self.sanitizeLogValue) ?? "none"
        log("heartbeat scans=\(scanCount) lastViews=\(lastScanViewCount) lastWindows=\(lastScanWindowCount) captureFailures=\(captureFailureCount) lastFailure=\(failureReason) activeBlanks=\(activeBlankEvents.count)")
    }

    private func recordCaptureFailure(_ reason: String) {
        captureFailureCount += 1
        lastCaptureFailureReason = reason
        if lastLoggedCaptureFailureReason != reason || captureFailureCount == 1 {
            lastLoggedCaptureFailureReason = reason
            log("capture_failure count=\(captureFailureCount) reason=\(Self.sanitizeLogValue(reason))")
        }
    }

    private func log(_ message: String) {
        let line = "[\(Self.isoTimestamp())] \(message)"
        let writer = io
        Task.detached(priority: .utility) {
            await writer.appendLog(line)
        }
    }

    private func writeJSONEvent<T: Encodable & Sendable>(_ value: T) {
        let writer = io
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            await writer.appendEventJSON(data)
        }
    }

    private func writeJSONEventNow<T: Encodable & Sendable>(_ value: T) async {
        let writer = io
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            await writer.appendEventJSON(data)
        }.value
    }

    private func nextEventID() -> String {
        eventSequence += 1
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return String(format: "evt-%04d-%@", eventSequence, suffix)
    }

    // MARK: - MainActor view inspection helpers

    private static func findAllLinkTextViews(in root: NSView?) -> [LinkTextView] {
        guard let root else { return [] }
        var found: [LinkTextView] = []
        if let match = root as? LinkTextView {
            found.append(match)
        }
        for child in root.subviews {
            found.append(contentsOf: findAllLinkTextViews(in: child))
        }
        return found
    }

    private static func unobstructedViewportRect(in scroll: NSScrollView, document: NSView) -> NSRect {
        let visible = scroll.documentVisibleRect
        let insets = scroll.contentInsets
        let height = visible.height - insets.top - insets.bottom
        guard height > 24 else { return visible }
        let originY = document.isFlipped ? (visible.minY + insets.top) : (visible.minY + insets.bottom)
        return NSRect(x: visible.minX, y: originY, width: visible.width, height: height)
    }

    private static func buildBlankEventRecord(
        eventID: String,
        timestamp: String,
        view: LinkTextView,
        window: NSWindow,
        cropRectInWindow: NSRect,
        result: ViewScanResult,
        cropPNG: String?
    ) -> BlankEventRecord {
        let fullText = view.textStorage?.string ?? view.string
        let textLength = view.textStorage?.length ?? 0
        let visibleRectInWindow = view.convert(view.visibleRect, to: nil)
        let textContainerWidth = view.textContainer.map { (Double($0.containerSize.width) * 100).rounded() / 100 }
        let tempFG = inspectTemporaryForegroundColor(in: view)
        let storageMinAlpha = inspectStorageForegroundMinAlpha(in: view)
        let abnormalAncestors = inspectAbnormalAncestors(of: view, upTo: window.contentView)
        let layer = view.layer
        let redrawPolicy = view.layerContentsRedrawPolicy

        return BlankEventRecord(
            kind: "blank_detected",
            eventID: eventID,
            timestamp: timestamp,
            windowTitle: window.title,
            viewID: formatViewID(result.viewID),
            textPrefix: String(fullText.prefix(24)),
            textStorageLength: textLength,
            bounds: RectRecord(view.bounds),
            visibleRectInWindow: RectRecord(visibleRectInWindow),
            cropRectInWindow: RectRecord(cropRectInWindow),
            textContainerWidth: textContainerWidth,
            inkRatio: result.inkRatio,
            inkPixels: result.inkPixels,
            totalPixels: result.totalPixels,
            medianLuminance: result.medianLuminance,
            tempForegroundColorPresent: tempFG.present,
            tempForegroundColorCharCount: tempFG.coveredChars,
            tempForegroundColorMinAlpha: tempFG.minAlpha,
            storageForegroundColorMinAlpha: storageMinAlpha,
            abnormalAncestors: abnormalAncestors,
            hasLayer: layer != nil,
            layerClassName: layer.map { String(describing: type(of: $0)) },
            layerContentsIsNil: layer.map { $0.contents == nil },
            layerContentsRedrawPolicyRaw: redrawPolicy.rawValue,
            layerContentsRedrawPolicy: layerContentsRedrawPolicyName(redrawPolicy),
            windowIsKey: window.isKeyWindow,
            appIsActive: NSApp.isActive,
            cropPNG: cropPNG
        )
    }

    private static func resolvedAlpha(of color: NSColor, appearance: NSAppearance) -> Double {
        var alpha = 1.0
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) {
                alpha = Double(rgb.alphaComponent)
            } else {
                alpha = Double(color.cgColor.alpha)
            }
        }
        return (alpha * 10_000).rounded() / 10_000
    }

    private static func resolvedBackgroundLuminance(for view: NSView) -> CGFloat {
        var luminance: CGFloat = 0.95
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = view.window?.backgroundColor ?? NSColor.windowBackgroundColor
            if let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) {
                luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            }
        }
        return luminance
    }

    private static func inspectTemporaryForegroundColor(in view: LinkTextView) -> (present: Bool, coveredChars: Int, minAlpha: Double?) {
        guard let layoutManager = view.layoutManager,
              let storage = view.textStorage,
              storage.length > 0 else {
            return (false, 0, nil)
        }
        let length = storage.length
        let appearance = view.effectiveAppearance
        var index = 0
        var present = false
        var coveredChars = 0
        var minAlpha: Double?
        while index < length {
            var effectiveRange = NSRange(location: 0, length: 0)
            let attrs = layoutManager.temporaryAttributes(atCharacterIndex: index, effectiveRange: &effectiveRange)
            let stepEnd: Int
            if effectiveRange.length > 0 && effectiveRange.location <= index {
                stepEnd = min(length, effectiveRange.location + effectiveRange.length)
            } else {
                stepEnd = index + 1
            }
            let runLength = max(1, stepEnd - index)
            if let color = attrs[.foregroundColor] as? NSColor {
                present = true
                coveredChars += runLength
                let alpha = resolvedAlpha(of: color, appearance: appearance)
                minAlpha = minAlpha.map { min($0, alpha) } ?? alpha
            }
            index = max(index + 1, stepEnd)
        }
        return (present, coveredChars, minAlpha)
    }

    private static func inspectStorageForegroundMinAlpha(in view: LinkTextView) -> Double? {
        guard let storage = view.textStorage, storage.length > 0 else { return nil }
        let fullRange = NSRange(location: 0, length: storage.length)
        let appearance = view.effectiveAppearance
        var minAlpha: Double?
        storage.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, _, _ in
            guard let color = value as? NSColor else { return }
            let alpha = resolvedAlpha(of: color, appearance: appearance)
            minAlpha = minAlpha.map { min($0, alpha) } ?? alpha
        }
        return minAlpha
    }

    private static func inspectAbnormalAncestors(of view: NSView, upTo contentView: NSView?) -> [AbnormalAncestorRecord] {
        var abnormal: [AbnormalAncestorRecord] = []
        var cursor: NSView? = view
        var depth = 0
        while let current = cursor {
            let isHidden = current.isHidden
            let alpha = Double(current.alphaValue)
            let layerIsHidden = current.layer?.isHidden
            let layerOpacity = current.layer.map { Double($0.opacity) }
            let hasLayerMask = current.layer?.mask != nil
            if isHidden || alpha < 0.99 || layerIsHidden == true || (layerOpacity ?? 1.0) < 0.99 {
                abnormal.append(AbnormalAncestorRecord(
                    depth: depth,
                    className: String(describing: type(of: current)),
                    isHidden: isHidden,
                    alphaValue: (alpha * 10_000).rounded() / 10_000,
                    layerIsHidden: layerIsHidden,
                    layerOpacity: layerOpacity.map { ($0 * 10_000).rounded() / 10_000 },
                    hasLayerMask: hasLayerMask
                ))
            }
            if let contentView, current === contentView { break }
            cursor = current.superview
            depth += 1
        }
        return abnormal
    }

    private static func layerContentsRedrawPolicyName(_ policy: NSView.LayerContentsRedrawPolicy) -> String {
        switch policy {
        case .never: "never"
        case .onSetNeedsDisplay: "onSetNeedsDisplay"
        case .duringViewResize: "duringViewResize"
        case .beforeViewResize: "beforeViewResize"
        case .crossfade: "crossfade"
        @unknown default: "unknown(\(policy.rawValue))"
        }
    }

    // MARK: - Background ScreenCaptureKit & pixel analysis (nonisolated)

    nonisolated private static func captureAndAnalyzeBatch(plans: [WindowScanPlan]) async -> ScanBatchOutcome {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.currentProcess
        } catch {
            return ScanBatchOutcome(contentError: describeCaptureError(error), windows: [])
        }

        var outcomes: [WindowScanOutcome] = []
        outcomes.reserveCapacity(plans.count)

        for plan in plans {
            guard let display = content.displays.first(where: { $0.displayID == plan.displayID })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
                outcomes.append(WindowScanOutcome(plan: plan, results: [], captureError: "no_shareable_display"))
                continue
            }

            let matchedWindow = content.windows.first(where: { $0.windowID == CGWindowID(plan.windowNumber) })
            let includedWindows = matchedWindow.map { [$0] } ?? content.windows
            guard !includedWindows.isEmpty else {
                outcomes.append(WindowScanOutcome(plan: plan, results: [], captureError: "no_shareable_windows"))
                continue
            }

            let localDisplayRect = CGRect(x: 0, y: 0, width: plan.displayBoundsCG.width, height: plan.displayBoundsCG.height)
            let rawSourceRect = CGRect(
                x: plan.captureScreenRect.minX - plan.displayBoundsCG.minX,
                y: (plan.primaryDisplayHeight - plan.captureScreenRect.maxY) - plan.displayBoundsCG.minY,
                width: plan.captureScreenRect.width,
                height: plan.captureScreenRect.height
            )
            let sourceRect = rawSourceRect.intersection(localDisplayRect)
            guard !sourceRect.isNull, !sourceRect.isEmpty,
                  sourceRect.width > 1, sourceRect.height > 1 else {
                outcomes.append(WindowScanOutcome(plan: plan, results: [], captureError: "empty_source_rect"))
                continue
            }

            let filter = SCContentFilter(display: display, including: includedWindows)
            filter.includeMenuBar = false

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = max(2, Int((sourceRect.width * plan.backingScaleFactor).rounded()) & ~1)
            configuration.height = max(2, Int((sourceRect.height * plan.backingScaleFactor).rounded()) & ~1)
            configuration.scalesToFit = false
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let capturedImage: CGImage
            do {
                capturedImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            } catch {
                outcomes.append(WindowScanOutcome(plan: plan, results: [], captureError: describeCaptureError(error)))
                continue
            }

            let capturedScreenRect = CGRect(
                x: sourceRect.minX + plan.displayBoundsCG.minX,
                y: plan.primaryDisplayHeight - (sourceRect.maxY + plan.displayBoundsCG.minY),
                width: sourceRect.width,
                height: sourceRect.height
            )

            let scaleX = CGFloat(capturedImage.width) / capturedScreenRect.width
            let scaleY = CGFloat(capturedImage.height) / capturedScreenRect.height

            var results: [ViewScanResult] = []
            results.reserveCapacity(plan.targets.count)

            for target in plan.targets {
                let clippedScreen = target.visibleRectInScreen.intersection(capturedScreenRect)
                guard !clippedScreen.isNull, !clippedScreen.isEmpty else { continue }

                let pxMinX = max(0, min(capturedImage.width, Int(((clippedScreen.minX - capturedScreenRect.minX) * scaleX).rounded(.up))))
                let pxMaxX = max(0, min(capturedImage.width, Int(((clippedScreen.maxX - capturedScreenRect.minX) * scaleX).rounded(.down))))
                // CGImage origin is top-left while AppKit screen Y increases upward.
                let pxMinY = max(0, min(capturedImage.height, Int(((capturedScreenRect.maxY - clippedScreen.maxY) * scaleY).rounded(.up))))
                let pxMaxY = max(0, min(capturedImage.height, Int(((capturedScreenRect.maxY - clippedScreen.minY) * scaleY).rounded(.down))))

                let cropW = pxMaxX - pxMinX
                let cropH = pxMaxY - pxMinY
                guard cropW > 0, cropH > 0,
                      let cropped = capturedImage.cropping(to: CGRect(x: pxMinX, y: pxMinY, width: cropW, height: cropH)),
                      let metrics = computeInkMetrics(from: cropped) else { continue }

                let isBlank = metrics.totalPixels > 0 && metrics.inkRatio < blankInkRatioThreshold
                results.append(ViewScanResult(
                    viewID: target.viewID,
                    totalPixels: metrics.totalPixels,
                    medianLuminance: metrics.medianLuminance,
                    inkPixels: metrics.inkPixels,
                    inkRatio: metrics.inkRatio,
                    isBlank: isBlank,
                    croppedImage: isBlank ? cropped : nil
                ))
            }

            outcomes.append(WindowScanOutcome(plan: plan, results: results, captureError: nil))
        }

        return ScanBatchOutcome(contentError: nil, windows: outcomes)
    }

    nonisolated private static func computeInkMetrics(
        from image: CGImage,
        opaqueBackgroundLuminance: CGFloat? = nil
    ) -> (totalPixels: Int, medianLuminance: Double, inkPixels: Int, inkRatio: Double)? {
        let cropW = image.width
        let cropH = image.height
        guard cropW > 0, cropH > 0 else { return nil }

        let bytesPerRow = cropW * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * cropH)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drew: Bool = pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: cropW,
                    height: cropH,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            let rect = CGRect(x: 0, y: 0, width: cropW, height: cropH)
            if let bgLum = opaqueBackgroundLuminance,
               let bgColor = CGColor(colorSpace: colorSpace, components: [bgLum, bgLum, bgLum, 1.0]) {
                context.setFillColor(bgColor)
                context.fill(rect)
            }
            context.draw(image, in: rect)
            return true
        }
        guard drew else { return nil }

        let totalPixels = cropW * cropH
        let bins = 4096
        let maxBin = bins - 1
        var histogram = [Int](repeating: 0, count: bins)

        var offset = 0
        while offset < pixels.count {
            let r = Double(pixels[offset])
            let g = Double(pixels[offset + 1])
            let b = Double(pixels[offset + 2])
            let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            let bin = min(maxBin, max(0, Int((lum * Double(maxBin)).rounded())))
            histogram[bin] += 1
            offset += 4
        }

        var cumulative = 0
        let half = (totalPixels + 1) / 2
        var medianBin = 0
        for (bin, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= half {
                medianBin = bin
                break
            }
        }
        let medianLum = Double(medianBin) / Double(maxBin)

        var inkPixels = 0
        offset = 0
        while offset < pixels.count {
            let r = Double(pixels[offset])
            let g = Double(pixels[offset + 1])
            let b = Double(pixels[offset + 2])
            let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            if abs(lum - medianLum) > inkLuminanceDeltaThreshold {
                inkPixels += 1
            }
            offset += 4
        }

        let ratio = totalPixels > 0 ? Double(inkPixels) / Double(totalPixels) : 0
        return (
            totalPixels: totalPixels,
            medianLuminance: (medianLum * 10_000).rounded() / 10_000,
            inkPixels: inkPixels,
            inkRatio: (ratio * 100_000).rounded() / 100_000
        )
    }

    nonisolated private static func describeCaptureError(_ error: Error) -> String {
        let nsError = error as NSError
        if let scError = error as? SCStreamError, scError.code == .userDeclined {
            return "permission_denied(SCStreamError.userDeclined/\(nsError.code)): \(error.localizedDescription)"
        }
        if nsError.code == -3801 {
            return "permission_denied(\(nsError.domain)/\(nsError.code)): \(error.localizedDescription)"
        }
        return "\(nsError.domain)(\(nsError.code)): \(error.localizedDescription)"
    }

    nonisolated private static func formatViewID(_ id: ObjectIdentifier) -> String {
        "0x" + String(UInt(bitPattern: id), radix: 16)
    }

    nonisolated private static func isoTimestamp(_ date: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func sanitizeLogValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Internal types

    @MainActor
    private final class WeakLinkTextView {
        weak var value: LinkTextView?
        init(_ value: LinkTextView) { self.value = value }
    }

    private struct ActiveBlankEvent {
        let eventID: String
        let detectedAt: Date
        let windowTitle: String
        weak var view: LinkTextView?
    }

    private struct PendingOffscreenCheck {
        let eventID: String
        let viewID: ObjectIdentifier
        let windowTitle: String
        let medianLuminance: Double
    }

    private struct ViewScanTarget: Sendable {
        let viewID: ObjectIdentifier
        let visibleRectInWindow: CGRect
        let visibleRectInScreen: CGRect
    }

    private struct WindowScanPlan: Sendable {
        let windowNumber: Int
        let windowTitle: String
        let displayID: CGDirectDisplayID
        let displayBoundsCG: CGRect
        let primaryDisplayHeight: CGFloat
        let backingScaleFactor: CGFloat
        let captureScreenRect: CGRect
        let targets: [ViewScanTarget]
    }

    private struct ViewScanResult: Sendable {
        let viewID: ObjectIdentifier
        let totalPixels: Int
        let medianLuminance: Double
        let inkPixels: Int
        let inkRatio: Double
        let isBlank: Bool
        let croppedImage: CGImage?
    }

    private struct WindowScanOutcome: Sendable {
        let plan: WindowScanPlan
        let results: [ViewScanResult]
        let captureError: String?
    }

    private struct ScanBatchOutcome: Sendable {
        let contentError: String?
        let windows: [WindowScanOutcome]
    }

    // MARK: - JSON record schemas

    private struct RectRecord: Encodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = (Double(rect.origin.x) * 100).rounded() / 100
            y = (Double(rect.origin.y) * 100).rounded() / 100
            width = (Double(rect.size.width) * 100).rounded() / 100
            height = (Double(rect.size.height) * 100).rounded() / 100
        }
    }

    private struct AbnormalAncestorRecord: Encodable, Sendable {
        let depth: Int
        let className: String
        let isHidden: Bool
        let alphaValue: Double
        let layerIsHidden: Bool?
        let layerOpacity: Double?
        let hasLayerMask: Bool
    }

    private struct BlankEventRecord: Encodable, Sendable {
        let kind: String
        let eventID: String
        let timestamp: String
        let windowTitle: String
        let viewID: String
        let textPrefix: String
        let textStorageLength: Int
        let bounds: RectRecord
        let visibleRectInWindow: RectRecord
        let cropRectInWindow: RectRecord
        let textContainerWidth: Double?
        let inkRatio: Double
        let inkPixels: Int
        let totalPixels: Int
        let medianLuminance: Double
        let tempForegroundColorPresent: Bool
        let tempForegroundColorCharCount: Int
        let tempForegroundColorMinAlpha: Double?
        let storageForegroundColorMinAlpha: Double?
        let abnormalAncestors: [AbnormalAncestorRecord]
        let hasLayer: Bool
        let layerClassName: String?
        let layerContentsIsNil: Bool?
        let layerContentsRedrawPolicyRaw: Int
        let layerContentsRedrawPolicy: String
        let windowIsKey: Bool
        let appIsActive: Bool
        let cropPNG: String?
    }

    private struct OffscreenCheckRecord: Encodable, Sendable {
        let kind: String
        let eventID: String
        let timestamp: String
        let windowTitle: String
        let viewID: String
        let offscreenInkRatio: Double?
        let screenInkRatioAfterOffscreen: Double?
        let afterCaptureError: String?
    }

    private struct RecoveredEventRecord: Encodable, Sendable {
        let kind: String
        let eventID: String
        let timestamp: String
        let windowTitle: String
        let viewID: String
        let textPrefix: String
        let inkRatio: Double
        let durationSeconds: Double
        let windowIsKey: Bool
        let appIsActive: Bool
    }
}

private actor BlankWatchIO {
    nonisolated let directory: URL
    private let eventsURL: URL
    private let logURL: URL

    init(directory: URL) {
        self.directory = directory
        self.eventsURL = directory.appendingPathComponent("blank-events.jsonl")
        self.logURL = directory.appendingPathComponent("blank-watch.log")
    }

    func appendLog(_ line: String) {
        append(Data((line + "\n").utf8), to: logURL)
    }

    func appendEventJSON(_ data: Data) {
        var lineData = data
        lineData.append(0x0A)
        append(lineData, to: eventsURL)
    }

    func saveCropPNG(_ image: CGImage, filename: String) -> Bool {
        let url = directory.appendingPathComponent(filename)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private func append(_ data: Data, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
