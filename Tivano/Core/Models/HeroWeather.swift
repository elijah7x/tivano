import Foundation

struct HeroWeatherSnapshot: Equatable, Sendable {
    static let idle = Self(weather: .idle, hasRunningWork: false, failed: 0, awaiting: 0, done: 0)
    let weather: HeroWeather
    let hasRunningWork: Bool
    let failed: Int
    let awaiting: Int
    let done: Int
}

/// The window's weather: every visible thread's activity folded into one scene.
/// A failure outranks a pending decision, which outranks an unread reply; live work
/// stays quiet, and the count is how many threads share the winning state.
enum HeroWeather: Equatable, Sendable {
    case idle
    case failed(Int)
    case awaiting(Int)
    case done(Int)

    static func resolveSnapshot<S: Sequence>(_ statuses: S) -> HeroWeatherSnapshot where S.Element == ThreadActivityStatus {
        var failed = 0, awaiting = 0, done = 0
        var hasRunningWork = false
        for status in statuses {
            switch status {
            case .failed, .interrupted: failed += 1
            case .approval, .question: awaiting += 1
            case .completed: done += 1
            case .running: hasRunningWork = true
            case .idle: break
            }
        }
        let weather: Self = if failed > 0 {
            .failed(failed)
        } else if awaiting > 0 {
            .awaiting(awaiting)
        } else if done > 0 {
            .done(done)
        } else {
            .idle
        }
        return HeroWeatherSnapshot(
            weather: weather,
            hasRunningWork: hasRunningWork,
            failed: failed,
            awaiting: awaiting,
            done: done
        )
    }

    static func resolve<S: Sequence>(_ statuses: S) -> Self where S.Element == ThreadActivityStatus {
        resolveSnapshot(statuses).weather
    }
}
