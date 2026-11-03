import Foundation

extension AppModel {
    func hydraOwnedFiles(_ id: UUID) -> [String] {
        guard let head = thread(id), let jobID = head.hydra?.jobID,
              let leadID = head.parentThreadID else { return [] }
        return thread(leadID)?.hydraJobs.first { $0.id == jobID }?
            .heads.first { $0.headID == id }?.files ?? []
    }

    /// The folders Tivano keeps for itself: the running edition's library, both editions'
    /// data folders, and the CLI's own. A head never works in one of them, in anything
    /// inside one, or in a folder that contains one. The editions are listed apart from
    /// `StoragePaths.root` because a capture run points that elsewhere.
    nonisolated static func hydraProtectedRoots() -> [String] {
        let manager = FileManager.default
        var roots = [StoragePaths.root.path]
        if let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(support.appendingPathComponent("Tivano", isDirectory: true).path)
            roots.append(support.appendingPathComponent("Tivano Dev", isDirectory: true).path)
        }
        let home = manager.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".tivano").path)
        roots.append(home.appendingPathComponent(".tivano-dev").path)
        return roots.map { HydraPaths.canonical($0) }
    }

    /// Whether `path` is a protected folder, sits inside one, or contains one. Task
    /// workspaces are the one exception: the app's own checkouts live there.
    nonisolated static func hydraPathTouchesProtectedRoot(_ path: String, roots: [String], taskWorkspaces: String) -> Bool {
        let canonical = HydraPaths.canonical(path)
        if canonical == taskWorkspaces || canonical.hasPrefix(taskWorkspaces + "/") { return false }
        for root in roots where !root.isEmpty {
            if canonical == root || canonical.hasPrefix(root + "/") || root.hasPrefix(canonical + "/") { return true }
        }
        return false
    }

    /// The first 50 paths of a report list, plus how many were left out.
    nonisolated static func hydraFileListing(_ files: [String], limit: Int = 50) -> String {
        var text = files.prefix(limit).joined(separator: ", ")
        let rest = files.count - min(files.count, limit)
        if rest > 0 { text += "\n" + String(format: Chrome.localized("and %lld more"), Int64(rest)) }
        return text
    }

    nonisolated static func hydraOwnedPathIsSafe(_ path: String, base: String) -> Bool {
        guard !(path as NSString).isAbsolutePath else { return false }
        let relative = (path as NSString).standardizingPath
        guard relative != "..", !relative.hasPrefix("../") else { return false }
        let root = URL(fileURLWithPath: base).resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = URL(fileURLWithPath: base).appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    nonisolated static func hydraOwnedDirectory(_ files: [String], base: String) -> String? {
        let manager = FileManager.default
        var common: URL?
        for file in files {
            var directory = URL(fileURLWithPath: base).appendingPathComponent(file).resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            while !manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                let parent = directory.deletingLastPathComponent()
                guard parent != directory else { break }
                directory = parent
            }
            if var current = common {
                while directory.path != current.path && !directory.path.hasPrefix(current.path + "/") {
                    let parent = current.deletingLastPathComponent()
                    guard parent != current else { break }
                    current = parent
                }
                common = current
            } else {
                common = directory
            }
        }
        return common?.path
    }

    func prepareHydraBackup(_ id: UUID, checkout: String) async {
        guard let info = thread(id)?.hydra else { return }
        let files = hydraOwnedFiles(id)
        guard !files.isEmpty else { return }
        let base = info.filesBase ?? checkout
        // A continuation lists new files: they are copied into the backup already taken,
        // so the report can diff them like the files the head was sent out with.
        let isContinuation = info.backupPath != nil
        let owned = Set((info.backupOwnedPaths ?? []).map { ($0 as NSString).standardizingPath })
        let folder = info.backupPath.map { URL(fileURLWithPath: $0) }
            ?? StoragePaths.root.appendingPathComponent("hydra-backups", isDirectory: true).appendingPathComponent(id.uuidString)
        let added = isContinuation ? files.filter { !owned.contains(($0 as NSString).standardizingPath) } : files
        guard !added.isEmpty else { return }
        let result = await Self.copyHydraOwnedFiles(added, base: base, folder: folder)
        guard thread(id) != nil else {
            if !isContinuation { await Task.detached { try? FileManager.default.removeItem(at: folder) }.value }
            return
        }
        updateHydraHead(id) {
            $0.backupPath = folder.path
            $0.backupOwnedPaths = ($0.backupOwnedPaths ?? []) + added
            $0.backedUpFiles = ($0.backedUpFiles ?? []) + result.copied
            $0.newFiles = ($0.newFiles ?? []) + result.new
            $0.notBackedUpFiles = ($0.notBackedUpFiles ?? []) + result.skipped
        }
    }

    @concurrent
    private static func copyHydraOwnedFiles(_ files: [String], base: String, folder: URL) async -> (copied: [String], new: [String], skipped: [String]) {
        let manager = FileManager.default
        var copied: [String] = []
        var new: [String] = []
        var skipped: [String] = []
        var visited = Set<String>()
        var total = 0
        func copy(_ path: String) {
            let relative = (path as NSString).standardizingPath
            guard visited.insert(relative).inserted else { return }
            guard hydraOwnedPathIsSafe(relative, base: base) else { skipped.append(relative); return }
            let source = URL(fileURLWithPath: base).appendingPathComponent(relative)
            // Never copy the backup storage into itself.
            let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
            let storage = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            guard sourcePath != storage, !sourcePath.hasPrefix(storage + "/"), !storage.hasPrefix(sourcePath + "/") else {
                skipped.append(relative)
                return
            }
            let destination = folder.appendingPathComponent(relative)
            do {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                // Never follow links while recursively capturing an owned directory.
                guard values.isSymbolicLink != true else { skipped.append(relative); return }
                if values.isDirectory == true {
                    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                    for child in try manager.contentsOfDirectory(atPath: source.path).sorted() {
                        copy((relative as NSString).appendingPathComponent(child))
                    }
                } else if values.isRegularFile == true {
                    let size = values.fileSize ?? 0
                    guard size <= 10 * 1024 * 1024, total + size <= 50 * 1024 * 1024 else {
                        skipped.append(relative)
                        return
                    }
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: source, to: destination)
                    total += size
                    copied.append(relative)
                } else {
                    skipped.append(relative)
                }
            } catch {
                if !manager.fileExists(atPath: source.path) { new.append(relative) }
                else { skipped.append(relative) }
            }
        }
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files { copy(file) }
        return (copied, new, skipped)
    }

    @concurrent
    static func hydraBackupReport(_ info: HydraHeadInfo) async -> String? {
        guard let backup = info.backupPath, let checkout = info.targetCheckout else { return nil }
        let base = info.filesBase ?? checkout
        let manager = FileManager.default
        var parts: [String] = []
        var added = 0
        var removed = 0
        var truncated = false
        var length = 0
        func append(_ text: String) {
            guard !text.isEmpty else { return }
            let available = max(0, 20_000 - length)
            if text.count > available { truncated = true }
            let piece = String(text.prefix(available))
            if !piece.isEmpty { parts.append(piece); length += piece.count }
        }
        let backed = info.backedUpFiles ?? []
        let skipped = info.notBackedUpFiles ?? []
        var current = Set<String>()
        let storage = URL(fileURLWithPath: backup).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        func collect(_ raw: String) {
            let path = (raw as NSString).standardizingPath
            let resolved = URL(fileURLWithPath: base).appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved != storage, !resolved.hasPrefix(storage + "/"), !storage.hasPrefix(resolved + "/") else { return }
            guard hydraOwnedPathIsSafe(path, base: base),
                  !skipped.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
            let url = URL(fileURLWithPath: base).appendingPathComponent(path)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return }
            if values.isDirectory == true {
                for child in (try? manager.contentsOfDirectory(atPath: url.path)) ?? [] {
                    collect((path as NSString).appendingPathComponent(child))
                }
            } else if values.isRegularFile == true {
                current.insert((path as NSString).standardizingPath)
            }
        }
        for root in info.backupOwnedPaths ?? info.newFiles ?? [] { collect(root) }
        let paths = Set(backed).union(current).sorted()
        for path in paths {
            guard hydraOwnedPathIsSafe(path, base: base) else {
                append(String(format: Chrome.localized("Cannot diff %@: it now resolves outside %@."), path, base))
                continue
            }
            let before = URL(fileURLWithPath: backup).appendingPathComponent(path).path
            let after = URL(fileURLWithPath: base).appendingPathComponent(path).path
            let existed = backed.contains(path)
            let exists = manager.fileExists(atPath: after)
            if !existed && !exists { continue }
            if existed && !exists { removed += 1 }
            if !existed && exists { added += 1 }
            do {
                let result = try await Shell.run(URL(fileURLWithPath: "/usr/bin/diff"),
                                                ["-ruN", existed ? before : "/dev/null", exists ? after : "/dev/null"],
                                                outputLimit: 80_000)
                if result.status > 1 || result.timedOut {
                    append(String(format: Chrome.localized("Could not diff %@: %@"), path, result.failureMessage))
                } else {
                    append(result.output)
                    if result.stdout.count >= 80_000 { truncated = true }
                }
            } catch {
                append(String(format: Chrome.localized("Could not diff %@: %@"), path, error.localizedDescription))
            }
        }
        if truncated { parts.append(Chrome.localized("[Diff truncated at 20,000 characters.]")) }
        if parts.isEmpty { parts.append(Chrome.localized("No changes to the backed-up or newly listed files.")) }
        // Outside the diff budget, so a long diff never hides what has no backup.
        if !skipped.isEmpty {
            parts.append(String(format: Chrome.localized("Not backed up (size, unsupported path or copy failure): %@"),
                                hydraFileListing(skipped)))
        }
        parts.append(String(format: Chrome.localized("Added: %lld; removed: %lld."), Int64(added), Int64(removed)))
        parts.append(String(format: Chrome.localized("%@ worked in place in %@. The diff of its listed files against the copies taken before it started is above; the originals are at %@. Restore any file from there if the change is wrong."),
                            info.persona.name, checkout, backup))
        return parts.joined(separator: "\n\n")
    }
}
