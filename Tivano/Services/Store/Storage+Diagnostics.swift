import Foundation

extension Storage {
    nonisolated static func measureDiagnostics() async throws -> RuntimeStorageUsage {
        try await Task.detached(priority: .utility) {
            try HangWatchdog.measureDiagnostics()
        }.value
    }

    nonisolated static func clearDiagnostics() async throws {
        try await Task.detached(priority: .utility) {
            try HangWatchdog.clearDiagnostics()
        }.value
    }
}
