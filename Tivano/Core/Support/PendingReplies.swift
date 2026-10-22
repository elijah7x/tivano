import Foundation

struct DuplicateReplyID: Error {}

/// Replies waiting on a request id. The id is registered before `send` runs, so a fast
/// reply can't arrive before anyone is waiting for it.
@MainActor
final class PendingReplies<Value: Sendable> {
    private struct Entry {
        let token: UUID
        let continuation: CheckedContinuation<Value, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private var continuations: [String: Entry] = [:]

    /// Without a `timeoutValue`, a timeout throws `CancellationError`.
    func register(
        _ id: String,
        timeout: Duration? = nil,
        timeoutValue: Value? = nil,
        send: () -> Void
    ) async throws -> Value {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard continuations[id] == nil else {
                    continuation.resume(throwing: DuplicateReplyID())
                    return
                }
                continuations[id] = Entry(token: token, continuation: continuation)
                send()
                guard let timeout, continuations[id]?.token == token else { return }
                continuations[id]?.timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard self.continuations[id]?.token == token else { return }
                    if let timeoutValue {
                        self.resolve(id, timeoutValue)
                    } else {
                        self.fail(id, CancellationError())
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.continuations[id]?.token == token else { return }
                self.fail(id, CancellationError())
            }
        }
    }

    @discardableResult
    func resolve(_ id: String, _ value: Value) -> Bool {
        guard let entry = continuations.removeValue(forKey: id) else { return false }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func fail(_ id: String, _ error: Error) -> Bool {
        guard let entry = continuations.removeValue(forKey: id) else { return false }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(throwing: error)
        return true
    }

    func resolveAll(_ value: Value) {
        let waiting = Array(continuations.values)
        continuations.removeAll()
        for entry in waiting {
            entry.timeoutTask?.cancel()
            entry.continuation.resume(returning: value)
        }
    }

    func failAll(_ error: Error) {
        let waiting = Array(continuations.values)
        continuations.removeAll()
        for entry in waiting {
            entry.timeoutTask?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }
}
