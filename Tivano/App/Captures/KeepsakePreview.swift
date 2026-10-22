#if DEBUG
import AppKit

@MainActor
enum KeepsakePreview {
    nonisolated static var isRequested: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--keepsake-preview")
    }

    static func run(model: AppModel) async {
        guard isRequested else { return }
        await model.bootstrap()
        model.prepareKeepsakePreview()
        WindowManager.shared.showSettings(page: .keepsakes)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
