import Foundation
import os

/// Best-effort local evidence; a logging failure never interrupts a Hydra job.
actor DecisionLedger {
    static let shared = DecisionLedger()
    nonisolated static var directory: URL { StoragePaths.root.appendingPathComponent("decisions", isDirectory: true) }
    nonisolated static var fileURL: URL { directory.appendingPathComponent("ledger.jsonl") }

    private static let fileLimit: Int64 = 20 * 1_024 * 1_024
    private static let previousMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let currentName = "ledger.jsonl"
    private static let previousName = "ledger.1.jsonl"
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "decisions")

    init() {
        do {
            if let directory = try DiagnosticDirectory.open(Self.directory) {
                try Self.expirePrevious(in: directory)
            }
        } catch {
            Self.log.error("Could not retain decision diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    func append(_ record: JSONValue) {
        do {
            guard let directory = try DiagnosticDirectory.open(Self.directory, create: true) else { return }
            try Self.expirePrevious(in: directory)
            let data = Data((record.compactString + "\n").utf8)
            // Drop an oversized record whole; truncation would corrupt JSONL structure.
            guard Int64(data.count) <= Self.fileLimit else { return }
            if let current = try directory.file(Self.currentName), current.size > Self.fileLimit - Int64(data.count) {
                if let previous = try directory.file(Self.previousName) { try directory.remove(previous) }
                try directory.move(current, to: Self.previousName)
                try Self.expirePrevious(in: directory)
            }
            try directory.append(Self.currentName, data: data, limit: Self.fileLimit)
        } catch {
            Self.log.error("Could not append decision diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    func measureDiagnostics() throws -> RuntimeStorageUsage {
        guard let directory = try DiagnosticDirectory.open(Self.directory) else { return RuntimeStorageUsage() }
        let current = try directory.file(Self.currentName)
        let previous = try directory.file(Self.previousName)
        return RuntimeStorageUsage(totalBytes: try DiagnosticDirectory.totalBytes([current, previous].compactMap { $0 }),
                                   cleanableBytes: previous?.size ?? 0)
    }

    func clearDiagnostics() throws {
        guard let directory = try DiagnosticDirectory.open(Self.directory) else { return }
        if let previous = try directory.file(Self.previousName) { try directory.remove(previous) }
    }

    private static func expirePrevious(in directory: DiagnosticDirectory) throws {
        if let previous = try directory.file(previousName),
           previous.modified < Date().addingTimeInterval(-previousMaxAge) {
            try directory.remove(previous)
        }
    }
}
