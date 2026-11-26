import Foundation

/// Cache key for short-lived CLI catalog/model probes: canonical executable path
/// (with symlinks resolved) paired with a deterministic encoding of the launch
/// environment.
struct CLIProbeKey: Hashable, Sendable {
    let executable: String
    let environment: String

    init(executable: URL, environment: [String: String]) {
        self.executable = executable.resolvingSymlinksInPath().standardizedFileURL.path
        self.environment = environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\0")
    }
}

/// Coalesces concurrent CLI probes for the same executable and environment, and
/// caches completed results for `ttl` seconds when `shouldCache` accepts them.
/// Errors (and rejected results) clear the entry so the next caller probes fresh.
actor CLIProbeCache<Value: Sendable> {
    private struct Entry {
        let key: CLIProbeKey
        let task: Task<Value, Error>
        var completedAt: Date?
    }

    private let ttl: TimeInterval
    private let shouldCache: @Sendable (Value) -> Bool
    private var entry: Entry?

    init(ttl: TimeInterval = 5, shouldCache: @escaping @Sendable (Value) -> Bool = { _ in true }) {
        self.ttl = ttl
        self.shouldCache = shouldCache
    }

    func reset(key: CLIProbeKey) {
        if entry?.key == key { entry = nil }
    }

    func value(
        key: CLIProbeKey,
        force: Bool,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if force { entry = nil }
        if let entry, entry.key == key,
           entry.completedAt.map({ (0..<ttl).contains(Date.now.timeIntervalSince($0)) }) ?? true {
            return try await entry.task.value
        }
        let task = Task { try await operation() }
        entry = Entry(key: key, task: task, completedAt: nil)
        do {
            let result = try await task.value
            if entry?.task == task {
                if shouldCache(result) {
                    entry?.completedAt = .now
                } else {
                    entry = nil
                }
            }
            return result
        } catch {
            if entry?.task == task { entry = nil }
            throw error
        }
    }
}
