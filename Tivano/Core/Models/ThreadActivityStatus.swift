import Foundation

/// Pending decisions and live work remain visible; terminal results are reminders
/// only until they have been read. The stored last turn status remains unchanged.
enum ThreadActivityStatus: Equatable, Sendable {
    case idle, running, completed, approval, question, failed, interrupted

    static func resolve(lastStatus: TurnStatus?, hasUnread: Bool, needsApproval: Bool, needsAnswer: Bool, isWorking: Bool) -> Self {
        if needsApproval { return .approval }
        if needsAnswer { return .question }
        if isWorking { return .running }
        guard hasUnread else { return .idle }
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
