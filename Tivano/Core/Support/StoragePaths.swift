import Foundation

/// Storage locations that views need too; they live in Core because UI can't reach `Storage`.
enum StoragePaths {
    /// The capture run's storage during a capture, otherwise Application Support.
    nonisolated static let root: URL = {
        if let captures = CaptureRun.storageRoot { return captures }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(AppInfo.libraryName, isDirectory: true)
        return url
    }()

    nonisolated static func taskWorkspace(_ threadID: UUID) -> URL {
        root.appendingPathComponent("task-workspaces", isDirectory: true)
            .appendingPathComponent(threadID.uuidString, isDirectory: true)
    }

    @discardableResult
    nonisolated static func ensureTaskWorkspace(_ threadID: UUID) throws -> URL {
        let url = taskWorkspace(threadID)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The user's window wallpaper, one file at a time.
    nonisolated static let wallpaperDirectory: URL = directory("wallpaper")

    /// A folder under the root, created on first use.
    nonisolated static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
