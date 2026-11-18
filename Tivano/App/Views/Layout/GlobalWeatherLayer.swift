import AppKit
import SwiftUI

struct GlobalWeatherLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WindowLiveResize.self) private var liveResize
    @State private var displayedWeather: HeroWeather = .idle
    @State private var pulseStart: Date?
    @State private var releaseStart: Date?
    @State private var isPresent = false
    @State private var environmentAllowsMotion = false
    @State private var playback: Task<Void, Never>?

    private var canAnimate: Bool {
        isPresent
            && environmentAllowsMotion
            && !reduceMotion
            && model.settings.showsWeatherNow
            && !SettingsNavigation.shared.isPresented
            && model.appSpace == .session
            && !model.voice.stageOpen
    }

    private var holdsSteady: Bool {
        #if DEBUG
        WeatherPreview.shared.holdsSteady
        #else
        false
        #endif
    }

    var body: some View {
        let snapshot = (canAnimate || holdsSteady) ? model.globalWeatherSnapshot : .idle
        let weather = snapshot.weather
        let hasRunningWork = snapshot.hasRunningWork
        Group {
            if canAnimate && displayedWeather != .idle && (holdsSteady || pulseStart != nil) {
                WeatherCanvas(
                    kind: displayedWeather,
                    pulseStart: pulseStart,
                    releaseStart: releaseStart,
                    holdsSteady: holdsSteady,
                    backdropOpacity: model.settings.backdropOpacity,
                    isPausedExternal: liveResize.isActive
                )
            } else {
                Color.clear
            }
        }
            .background {
                WeatherMotionObserver { environmentAllowsMotion = $0 }
            }
            .onAppear {
                isPresent = true
                if holdsSteady {
                    syncSteady(for: model.globalWeather)
                }
            }
            .onChange(of: holdsSteady) { _, steady in
                if steady {
                    syncSteady(for: model.globalWeather)
                } else {
                    stop()
                }
            }
            .onChange(of: hasRunningWork) { _, running in
                if running, !holdsSteady, weather == .idle {
                    stop()
                }
            }
            .onChange(of: weather) { oldValue, newValue in
                if holdsSteady {
                    syncSteady(for: newValue)
                    return
                }
                if newValue == .idle {
                    if hasRunningWork || !canAnimate {
                        stop()
                    } else if case .awaiting = oldValue, displayedWeather != .idle, pulseStart != nil {
                        playback?.cancel()
                        playback = nil
                        let rel = Date.now
                        releaseStart = rel
                        playback = Task { @MainActor in
                            do {
                                try await Task.sleep(for: .seconds(WeatherCanvas.releaseDuration))
                                guard !Task.isCancelled else { return }
                                if releaseStart == rel {
                                    stop()
                                }
                            } catch {
                                return
                            }
                        }
                    }
                    return
                }
                guard shouldPlay(from: oldValue, to: newValue) else { return }
                playback?.cancel()
                playback = nil
                guard canAnimate else {
                    stop()
                    return
                }
                let start = Date.now
                displayedWeather = newValue
                pulseStart = start
                releaseStart = nil
                playback = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .seconds(WeatherCanvas.pulseDuration))
                        guard !Task.isCancelled else { return }
                        if pulseStart == start {
                            displayedWeather = .idle
                            pulseStart = nil
                            releaseStart = nil
                            playback = nil
                        }
                    } catch {
                        return
                    }
                }
            }
            .onChange(of: canAnimate) { _, allowed in
                if holdsSteady {
                    syncSteady(for: model.globalWeather)
                } else if !allowed {
                    stop()
                }
            }
            .onDisappear {
                isPresent = false
                stop()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .ignoresSafeArea()
    }

    private func shouldPlay(from old: HeroWeather, to new: HeroWeather) -> Bool {
        switch (old, new) {
        case (.idle, .idle): false
        case let (.awaiting(before), .awaiting(after)),
             let (.done(before), .done(after)),
             let (.failed(before), .failed(after)): after > before
        default: true
        }
    }

    private func syncSteady(for weather: HeroWeather) {
        playback?.cancel()
        playback = nil
        displayedWeather = canAnimate ? weather : .idle
        pulseStart = nil
        releaseStart = nil
    }

    private func stop() {
        playback?.cancel()
        playback = nil
        displayedWeather = .idle
        pulseStart = nil
        releaseStart = nil
    }
}

struct WeatherMotionObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> MotionView {
        let view = MotionView(frame: .zero)
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MotionView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: MotionView, coordinator: ()) {
        view.onChange = nil
    }

    @MainActor
    final class MotionView: NSView {
        var onChange: ((Bool) -> Void)?
        private weak var observedWindow: NSWindow?
        private var lastValue: Bool?
        private var screensAsleep = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         Notification.Name.NSProcessInfoPowerStateDidChange,
                         ProcessInfo.thermalStateDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged), name: name, object: nil)
            }
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            workspaceCenter.addObserver(self, selector: #selector(environmentChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            workspaceCenter.addObserver(self, selector: #selector(screensDidSleep),
                name: NSWorkspace.screensDidSleepNotification, object: nil)
            workspaceCenter.addObserver(self, selector: #selector(screensDidWake),
                name: NSWorkspace.screensDidWakeNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        isolated deinit {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observedWindow !== window {
                let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification]
                if let observedWindow {
                    for name in names { NotificationCenter.default.removeObserver(self, name: name, object: observedWindow) }
                }
                observedWindow = window
                if let window {
                    for name in names {
                        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged), name: name, object: window)
                    }
                }
            }
            environmentChanged()
        }

        override func viewDidHide() {
            super.viewDidHide()
            environmentChanged()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            environmentChanged()
        }

        @objc nonisolated private func screensDidSleep() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screensAsleep = true
                self.reportMotion()
            }
        }

        @objc nonisolated private func screensDidWake() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screensAsleep = false
                self.reportMotion()
            }
        }

        @objc nonisolated private func environmentChanged() {
            Task { @MainActor [weak self] in self?.reportMotion() }
        }

        private func reportMotion() {
            let process = ProcessInfo.processInfo
            let allowed = !screensAsleep
                && window.map {
                    $0.isVisible && $0.occlusionState.contains(.visible) && !$0.isMiniaturized
                } == true && NSApp.isActive && !NSApp.isHidden && !isHiddenOrHasHiddenAncestor
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && !process.isLowPowerModeEnabled
                && process.thermalState != .serious && process.thermalState != .critical
            guard lastValue != allowed else { return }
            lastValue = allowed
            onChange?(allowed)
        }
    }
}
