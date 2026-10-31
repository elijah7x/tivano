import Foundation

extension Storage {
    nonisolated static func measureDiagnostics() async throws -> RuntimeStorageUsage {
        try await Task.detached(priority: .utility) {
            let reports = try HangWatchdog.measureDiagnostics()
            let ledger = try await DecisionLedger.shared.measureDiagnostics()
            let (total, totalOverflow) = reports.totalBytes.addingReportingOverflow(ledger.totalBytes)
            let (cleanable, cleanableOverflow) = reports.cleanableBytes.addingReportingOverflow(ledger.cleanableBytes)
            guard !totalOverflow, !cleanableOverflow else { throw CocoaError(.fileReadTooLarge) }
            return RuntimeStorageUsage(totalBytes: total, cleanableBytes: cleanable)
        }.value
    }

    nonisolated static func clearDiagnostics() async throws {
        try await Task.detached(priority: .utility) {
            try HangWatchdog.clearDiagnostics()
            try await DecisionLedger.shared.clearDiagnostics()
        }.value
    }
}
