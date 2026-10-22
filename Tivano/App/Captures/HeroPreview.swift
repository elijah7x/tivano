import AppKit
import Observation

/// `--website-captures <folder> --hero-preview`: an interactive window whose sidebar hero
/// walks through every weather, six seconds each, so the scenes can be judged live. Runs
/// on the capture's isolated storage and defaults, like every other capture.
@MainActor
@Observable
final class HeroPreview {
    static let shared = HeroPreview()
    nonisolated static var isRequested: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--hero-preview")
    }

    private(set) var weather: HeroWeather?
    private var window: NSWindow?

    static func run(model: AppModel) async {
        await model.bootstrap()
        model.settings.hasSeenHydraIntro = true
        let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1000, height: 680))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        shared.window = window
        if !model.sidebar.isVisible { model.sidebar.toggle() }
        let scenes: [HeroWeather] = [.idle, .awaiting(1), .running(3), .done(2), .failed(1)]
        while true {
            for scene in scenes {
                shared.weather = scene
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }
}
