import Foundation

/// Live attention takes precedence over work; terminal status describes the last turn,
/// not whether the owner considers the task finished. Read/unread is independent.
enum ThreadActivityStatus: Equatable, Sendable {
    case idle, running, completed, approval, question, failed, interrupted

    static func resolve(lastStatus: TurnStatus?, needsApproval: Bool, needsAnswer: Bool, isWorking: Bool) -> Self {
        if needsApproval { return .approval }
        if needsAnswer { return .question }
        if isWorking { return .running }
        switch lastStatus {
        case .completed: return .completed
        case .failed: return .failed
        case .interrupted: return .interrupted
        case .running, nil: return .idle
        }
    }

    var title: String {
        switch self {
        case .idle: "Not started"
        case .running: "In progress"
        case .completed: "Turn completed"
        case .approval: "Awaiting approval"
        case .question: "Awaiting your answer"
        case .failed: "Turn failed"
        case .interrupted: "Stopped or interrupted"
        }
    }
}
