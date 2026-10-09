import AppKit

/// Each edition holds its own lifetime lease; old shared builds must be closed.
@MainActor
enum LibraryAccess {
    private static var lease: SharedLibraryLease?
    private static var legacyLease: SharedLibraryLease?

    static func prepare() {
        guard !CaptureRun.isEnabled else { return }
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // An exclusive legacy lease also excludes older shared-library editions.
            legacyLease = try SharedLibraryLease(at: support.appendingPathComponent(".tivano-library.lock"))
            let migration = try SharedLibraryLease(at: support.appendingPathComponent(".tivano-migration.lock"), wait: true)
            try withExtendedLifetime(migration) { try LegacyMigration.run() }
            lease = try SharedLibraryLease(at: support.appendingPathComponent(AppInfo.isDevelopment ? ".tivano-dev-library.lock" : ".tivano-release-library.lock"))
            legacyLease = nil
        } catch {
            stop(String(format: Chrome.localized("The Tivano library could not be opened. Quit older Tivano builds and check permissions and available disk space.\n\n%@"), error.localizedDescription))
        }
    }

    private static func stop(_ message: String) -> Never {
        let alert = NSAlert()
        alert.messageText = Chrome.localized("Tivano library")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: Chrome.localized("Close"))
        alert.runModal()
        exit(1)
    }
}
