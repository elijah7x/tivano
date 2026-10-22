import Foundation

/// The sidebar hero's weather: every visible thread's activity folded into one scene.
/// A failure outranks a pending decision, which outranks live work, which outranks an
/// unread reply; the count is how many threads share the winning state.
enum HeroWeather: Equatable, Sendable {
    case idle
    case failed(Int)
    case awaiting(Int)
    case running(Int)
    case done(Int)

    static func resolve<S: Sequence>(_ statuses: S) -> Self where S.Element == ThreadActivityStatus {
        var failed = 0, awaiting = 0, running = 0, done = 0
        for status in statuses {
            switch status {
            case .failed, .interrupted: failed += 1
            case .approval, .question: awaiting += 1
            case .running: running += 1
            case .completed: done += 1
            case .idle: break
            }
        }
        if failed > 0 { return .failed(failed) }
        if awaiting > 0 { return .awaiting(awaiting) }
        if running > 0 { return .running(running) }
        if done > 0 { return .done(done) }
        return .idle
    }

    /// The drafting tag beside the doll; idle shows none.
    var tag: String? {
        switch self {
        case .idle: nil
        case .failed(let n): "FAIL · \(n)"
        case .awaiting(let n): "WAIT · \(n)"
        case .running(let n): "RUN · \(n)"
        case .done(let n): "DONE · \(n)"
        }
    }
}
