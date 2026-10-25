#if DEBUG
import AppKit

/// An isolated capture instance showing the usage-limit tab in each of its states, for
/// review by hand: `--website-captures <folder> --usage-limit-preview`. Nothing is ever
/// sent to a provider while it runs (see `ThreadRuntime.startTurn`).
@MainActor
enum UsageLimitPreview {
    nonisolated static var isRequested: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--usage-limit-preview")
    }

    private static var window: NSWindow?

    static func run(model: AppModel) async {
        await model.bootstrap()
        model.settings.hasSeenHydraIntro = true
        // The capture library is seeded dark; the preview follows the Mac instead.
        model.settings.theme = .system
        let ids = WebsiteCaptures.ID.self
        let now = Date.now
        model.autoContinue.preview(ids.composer, resetsAt: now.addingTimeInterval(2 * 3_600 + 13 * 60), waiting: false)
        model.autoContinue.preview(ids.finalAnswer, resetsAt: now.addingTimeInterval(47 * 60), waiting: true)
        model.autoContinue.preview(ids.archive, resetsAt: now.addingTimeInterval(-5 * 60), waiting: false)
        model.autoContinue.preview(ids.diffPopover, resetsAt: nil, waiting: false)
        model.selectedThreadID = ids.composer
        let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1200, height: 760))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if !model.sidebar.isVisible { model.sidebar.toggle() }
    }
}
#endif
