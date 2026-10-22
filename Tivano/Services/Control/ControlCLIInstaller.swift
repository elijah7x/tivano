import Foundation
import Darwin

/// Only called by explicit App settings buttons. Symlinks avoid quoting/shell config,
/// survive spaces in an App path, and can be repaired after an App move using a receipt.
enum ControlCLIInstaller {
    static func commandName(_ edition: ControlEdition) -> String { edition == .dev ? "tivano-dev" : "tivano" }
    static let helperName = "tivano-control"

    static func install(directory: URL, helper: URL, name: String, previousTarget: String?) throws {
        guard helper.isFileURL, helper.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: helper.path),
              !name.contains("/"), !name.isEmpty else { throw ControlFailure(code: .unavailable) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent(name)
        let existing = try existingTarget(link)
        if let existing {
            guard existing == previousTarget || existing == helper.path else { throw ControlFailure(code: .conflict) }
            let temporary = directory.appendingPathComponent(".\(name)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: helper.path)
            // Recheck the receipt immediately before publication. Another same-UID process
            // can still race this action; local control is not protection against that UID.
            guard try existingTarget(link) == existing else { throw ControlFailure(code: .conflict) }
            guard rename(temporary.path, link.path) == 0 else { throw ControlFailure(code: .permission) }
        } else {
            // symlink(2) fails on collision; never overwrite an unrecognized entry.
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
        }
    }

    static func uninstall(directory: URL, name: String, previousTarget: String?) throws {
        guard !name.contains("/"), !name.isEmpty else { throw ControlFailure(code: .invalidRequest) }
        let link = directory.appendingPathComponent(name)
        guard let existing = try existingTarget(link) else { return }
        guard let previousTarget, existing == previousTarget else { throw ControlFailure(code: .conflict) }
        try FileManager.default.removeItem(at: link)
    }

    private static func existingTarget(_ url: URL) throws -> String? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw ControlFailure(code: .permission)
        }
        guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == getuid() else { throw ControlFailure(code: .conflict) }
        return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }
}
