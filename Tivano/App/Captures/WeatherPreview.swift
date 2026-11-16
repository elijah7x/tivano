#if DEBUG
import AppKit
import Observation
import SwiftUI

/// Isolated live preview (`--weather-preview`) and still-capture runner (`--weather-captures`)
/// for the Liquid Glass weather window scenes.
@MainActor
@Observable
final class WeatherPreview {
    static let shared = WeatherPreview()

    enum PreviewSelection: Equatable {
        case cycle
        case wind
        case sun
        case rain
        case runningQuiet
    }

    nonisolated static var isPreviewRequested: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--weather-preview")
    }

    nonisolated static var isCapturesRequested: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--weather-captures")
    }

    var weather: HeroWeather?
    var holdsSteady = false
    var selection: PreviewSelection = .cycle
    private var window: NSWindow?
    private var cycleTask: Task<Void, Never>?

    private static var parsedAppearance: AppearanceMode {
        let arguments = CommandLine.arguments
        let raw: String? = if let index = arguments.firstIndex(of: "--appearance"),
                              arguments.indices.contains(index + 1) {
            arguments[index + 1]
        } else if let prefixed = arguments.first(where: { $0.hasPrefix("--appearance=") }) {
            String(prefixed.dropFirst("--appearance=".count))
        } else {
            nil
        }
        switch raw?.lowercased() {
        case "light": return .light
        case "dark": return .dark
        case "system": return .system
        default: return .system
        }
    }

    func select(_ next: PreviewSelection) {
        selection = next
        cycleTask?.cancel()
        cycleTask = nil
        switch next {
        case .cycle:
            holdsSteady = false
            startCycleLoop(initialDelay: .milliseconds(80))
        case .wind:
            holdsSteady = true
            weather = .awaiting(1)
        case .sun:
            holdsSteady = true
            weather = .done(1)
        case .rain:
            holdsSteady = true
            weather = .failed(1)
        case .runningQuiet:
            holdsSteady = true
            weather = .idle
        }
    }

    private func startCycleLoop(initialDelay: Duration) {
        cycleTask?.cancel()
        cycleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: initialDelay)
            let scenes: [HeroWeather] = [.awaiting(1), .done(1), .failed(1)]
            while !Task.isCancelled {
                for scene in scenes {
                    guard let self, !Task.isCancelled, self.selection == .cycle else { return }
                    self.holdsSteady = false
                    self.weather = scene
                    try? await Task.sleep(for: .seconds(8.4))
                }
            }
        }
    }

    static func runPreview(model: AppModel) async {
        await model.bootstrap()
        model.settings.hasSeenHydraIntro = true
        model.settings.themeStyle = .liquidGlass
        model.settings.weatherWindowEnabled = true
        model.settings.backdropOpacity = 0.16
        model.settings.appearanceMode = parsedAppearance
        model.selectedThreadID = WebsiteCaptures.composerThreadID
        if !model.sidebar.isVisible {
            model.sidebar.toggle()
        }
        shared.holdsSteady = false
        shared.selection = .cycle
        shared.weather = .idle

        let window = WindowManager.shared.makeWeatherPreviewWindow(size: NSSize(width: 1320, height: 840)) {
            WeatherPreviewHUD()
        }
        window.center()
        if CommandLine.arguments.contains("--background-preview") {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        shared.window = window

        shared.startCycleLoop(initialDelay: .milliseconds(650))
    }

    static func runCaptures(model: AppModel) async {
        guard let output = CaptureRun.outputDirectory else { exit(1) }
        await model.bootstrap()
        model.settings.hasSeenHydraIntro = true
        model.settings.themeStyle = .liquidGlass
        model.settings.weatherWindowEnabled = true
        model.selectedThreadID = WebsiteCaptures.composerThreadID
        if !model.sidebar.isVisible {
            model.sidebar.toggle()
        }

        let stage = Stage(model: model)
        stage.show(size: NSSize(width: 1320, height: 840))
        stage.setBackdrop(ProductCaptures.backdropView(.welcome))
        await stage.ensureActive()
        let recorder = Recorder(output: output, stage: stage)
        shared.holdsSteady = true
        try? await Task.sleep(for: .milliseconds(900))

        let shots: [(name: String, appearance: AppearanceMode, style: ThemeStyle, weather: HeroWeather)] = [
            ("dark-wind", .dark, .liquidGlass, .awaiting(1)),
            ("dark-sun", .dark, .liquidGlass, .done(1)),
            ("dark-rain", .dark, .liquidGlass, .failed(1)),
            ("light-wind", .light, .liquidGlass, .awaiting(1)),
            ("light-sun", .light, .liquidGlass, .done(1)),
            ("light-rain", .light, .liquidGlass, .failed(1)),
            ("texture-off", .dark, .texture, .failed(1)),
        ]
        for shot in shots {
            model.settings.appearanceMode = shot.appearance
            model.settings.themeStyle = shot.style
            shared.weather = shot.weather
            try? await Task.sleep(for: .milliseconds(450))
            await recorder.still(shot.name, stage.productCaptureRect)
        }
        exit(0)
    }
}

private struct WeatherPreviewHUD: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var activeSceneLabel: String {
        switch WeatherPreview.shared.weather {
        case .awaiting: "起风"
        case .done: "出太阳"
        case .failed: "下雨"
        case .idle, nil: "安静"
        }
    }

    var body: some View {
        let preview = WeatherPreview.shared
        let isDark = colorScheme == .dark
        let isLiquidGlass = model.settings.themeStyle == .liquidGlass

        HStack(spacing: 6) {
            chip(
                title: preview.selection == .cycle ? "轮播 · \(activeSceneLabel)" : "自动轮播",
                symbol: "repeat",
                isSelected: preview.selection == .cycle
            ) {
                preview.select(.cycle)
            }

            chip(title: "起风·待答", symbol: "wind", isSelected: preview.selection == .wind) {
                preview.select(.wind)
            }

            chip(title: "出太阳·完成", symbol: "sun.max", isSelected: preview.selection == .sun) {
                preview.select(.sun)
            }

            chip(title: "下雨·失败", symbol: "cloud.rain", isSelected: preview.selection == .rain) {
                preview.select(.rain)
            }

            chip(title: "运行中·无动效", symbol: "bolt.slash", isSelected: preview.selection == .runningQuiet) {
                preview.select(.runningQuiet)
            }

            Divider()
                .frame(height: 14)
                .opacity(0.35)

            chip(
                title: model.settings.backdropOpacity < 0.30 ? "高透玻璃" : "标准玻璃",
                symbol: "drop.halffull",
                isSelected: model.settings.backdropOpacity < 0.30
            ) {
                model.settings.backdropOpacity = model.settings.backdropOpacity < 0.30 ? 0.50 : 0.16
            }

            chip(
                title: isDark ? "深色" : "浅色",
                symbol: isDark ? "moon.fill" : "sun.min.fill",
                isSelected: false
            ) {
                model.settings.appearanceMode = isDark ? .light : .dark
            }

            chip(
                title: isLiquidGlass ? "液态玻璃" : "质感（已关天气）",
                symbol: isLiquidGlass ? "sparkles" : "rectangle.slash",
                isSelected: isLiquidGlass
            ) {
                model.settings.themeStyle = isLiquidGlass ? .texture : .liquidGlass
                if model.settings.themeStyle == .liquidGlass, preview.selection == .cycle {
                    preview.select(.cycle)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .chromeGlassCapsule()
        .padding(.top, 10)
    }

    private func chip(title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                Text(verbatim: title)
                    .font(.ui(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Chrome.primaryText : Chrome.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Chrome.accent.opacity(0.22))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
#endif
