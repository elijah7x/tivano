import SwiftUI

struct SidebarPorthole: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var environmentAllowsMotion = false
    @State private var shown: HeroWeather = .idle
    @State private var lastLive: HeroWeather = .idle
    @State private var hasSeeded = false
    @State private var holdDeadline: ContinuousClock.Instant?
    @State private var holdTask: Task<Void, Never>?

    private static let holdDuration: Duration = .seconds(8)

    private struct SyncState: Equatable {
        let isActive: Bool
        let live: HeroWeather
    }

    private var isSidebarShown: Bool {
        model.sidebar.isVisible
            && model.sidebar.renderedWidth > 0
            && !SettingsNavigation.shared.isPresented
    }

    private var animating: Bool {
        environmentAllowsMotion
            && !reduceMotion
            && model.isLibraryLoaded
            && model.sidebar.isVisible
            && model.sidebar.renderedWidth > 0
            && !model.sidebar.isDragging
            && !SettingsNavigation.shared.isPresented
            && !model.voice.stageOpen
    }

    var body: some View {
        #if DEBUG
        if model.isLibraryLoaded && !CaptureRun.isEnabled && (CaptureRun.defaults ?? .standard).bool(forKey: "portholeDemoCycle") {
            TimelineView(.periodic(from: .now, by: Self.demoStep)) { context in
                let step = Self.demoSteps[Int(context.date.timeIntervalSinceReferenceDate / Self.demoStep) % Self.demoSteps.count]
                card(weather: step.weather, clock: Calendar.current.date(bySettingHour: step.hour, minute: step.minute, second: 0, of: .now))
            }
        } else {
            liveCard
        }
        #else
        liveCard
        #endif
    }

    private var liveCard: some View {
        let isActive = model.isLibraryLoaded && isSidebarShown
        let live = isActive ? Self.portholeWeather(from: model.globalWeatherSnapshot) : lastLive
        let weather = effectiveWeather(isActive: isActive, live: live)
        return card(weather: weather, clock: nil)
            .onChange(of: SyncState(isActive: isActive, live: live), initial: true) { oldState, newState in
                syncWeather(from: oldState, to: newState)
            }
            .onDisappear {
                cancelHold()
            }
    }

    private func effectiveWeather(isActive: Bool, live: HeroWeather) -> HeroWeather {
        guard model.isLibraryLoaded else { return .idle }
        guard isActive else { return shown }
        if case .awaiting = live { return live }
        let isHolding = holdDeadline.map { ContinuousClock.now < $0 } ?? false
        if isHolding, Self.portholeStrength(live) < Self.portholeStrength(shown) {
            return shown
        }
        return live
    }

    static func portholeWeather(from snapshot: HeroWeatherSnapshot) -> HeroWeather {
        if snapshot.awaiting > 0 {
            .awaiting(snapshot.awaiting)
        } else if snapshot.failed > 0 {
            .failed(snapshot.failed)
        } else if snapshot.done > 0 {
            .done(snapshot.done)
        } else {
            .idle
        }
    }

    private static func portholeStrength(_ weather: HeroWeather) -> (Int, Int) {
        switch weather {
        case .idle: (0, 0)
        case .done(let count): (1, count)
        case .failed(let count): (2, count)
        case .awaiting(let count): (3, count)
        }
    }

    private static func shouldStartHold(from previous: HeroWeather, to live: HeroWeather) -> Bool {
        switch (previous, live) {
        case (.idle, .done), (.idle, .failed),
             (.awaiting, .done), (.awaiting, .failed),
             (.done, .failed):
            true
        case let (.done(before), .done(after)),
             let (.failed(before), .failed(after)):
            after > before
        default:
            false
        }
    }

    private func syncWeather(from oldState: SyncState, to newState: SyncState) {
        guard newState.isActive else { return }
        let live = newState.live
        if !hasSeeded {
            hasSeeded = true
            lastLive = live
            cancelHold()
            shown = live
            return
        }
        let previousLive = lastLive
        lastLive = live

        if case .awaiting = live {
            cancelHold()
            shown = live
            return
        }

        let now = ContinuousClock.now
        let isHolding = holdDeadline.map { now < $0 } ?? false

        if !oldState.isActive {
            if !isHolding {
                cancelHold()
                shown = live
            } else if Self.portholeStrength(live) > Self.portholeStrength(shown) {
                shown = live
                startHold(now: now)
            }
            return
        }

        if Self.shouldStartHold(from: previousLive, to: live) {
            if !isHolding || Self.portholeStrength(live) >= Self.portholeStrength(shown) {
                shown = live
                startHold(now: now)
            }
        } else if !isHolding {
            cancelHold()
            shown = live
        }
    }

    private func startHold(now: ContinuousClock.Instant) {
        let deadline = now.advanced(by: Self.holdDuration)
        holdDeadline = deadline
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, holdDeadline == deadline else { return }
            holdDeadline = nil
            holdTask = nil
            if isSidebarShown {
                shown = lastLive
            }
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        holdDeadline = nil
    }

    #if DEBUG
    /// `defaults write <Dev bundle id> portholeDemoCycle -bool YES` loops every scene for review.
    private static let demoStep: TimeInterval = 6
    private static let demoSteps: [(weather: HeroWeather, hour: Int, minute: Int)] = [
        (.idle, 7, 0), (.idle, 13, 0), (.idle, 18, 30), (.idle, 23, 0),
        (.awaiting(1), 13, 0), (.done(1), 13, 0), (.failed(1), 13, 0),
        (.awaiting(1), 23, 0), (.done(1), 18, 30), (.failed(3), 23, 0),
    ]
    #endif

    private func card(weather: HeroWeather, clock: Date?) -> some View {
        PortholeWeatherCard(
            weather: weather,
            animating: animating,
            isGlass: model.settings.themeStyle == .liquidGlass,
            clockOverride: clock
        )
        .frame(height: PortholeLayout.height)
        .background {
            WeatherMotionObserver { environmentAllowsMotion = $0 }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
