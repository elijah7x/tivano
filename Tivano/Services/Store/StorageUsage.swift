import Foundation

/// What the app keeps on disk, measured for the storage page.
struct StorageUsage: Equatable, Sendable {
    var chats: Int64 = 0
    /// Each chat's own files (its document and turns), so archived chats can be told apart.
    var chatSizes: [UUID: Int64] = [:]
    var attachments: Int64 = 0
    var patches: Int64 = 0
    var worktrees: [WorktreeUsage] = []

    var worktreesTotal: Int64 { worktrees.reduce(0) { $0 + $1.size } }
    var buildFilesTotal: Int64 { worktrees.reduce(0) { $0 + $1.buildFilesSize } }
}

/// One folder under the managed worktrees directory.
struct WorktreeUsage: Equatable, Identifiable, Sendable {
    let path: String
    var size: Int64
    /// Ignored folders with a known build or dependency name, which a rebuild brings back.
    var buildFiles: [String]
    var buildFilesSize: Int64
    /// Nil when Git could not read the folder (it is no longer a checkout, say).
    var changedFiles: Int?
    /// Git knows it as a worktree; otherwise it is a leftover folder.
    var isRegistered: Bool

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

extension Storage {
    /// Only these names are ever cleaned, and only where Git ignores them, so a tracked
    /// folder or an ignored `.env` holding secrets is never touched.
    static let buildFolderNames: Set<String> = [
        "node_modules", "build", "build.noindex", ".build", "DerivedData", "dist", "target",
        ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".venv", "venv",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".gradle", "Pods", ".dart_tool",
    ]

    /// Measures the app's data and every managed worktree. Walks whole trees, so it runs
    /// off the main actor and only when the storage page asks.
    nonisolated static func measureUsage() async -> StorageUsage {
        let threads = threadsDirectory
        let attachments = attachmentsDirectory
        let patches = patchesDirectory
        let worktrees = worktreesDirectory
        var usage = await Task.detached(priority: .utility) {
            var usage = StorageUsage(attachments: allocatedSize(of: attachments), patches: allocatedSize(of: patches))
            for item in (try? FileManager.default.contentsOfDirectory(at: threads, includingPropertiesForKeys: nil)) ?? [] {
                let size = allocatedSize(of: item)
                usage.chats += size
                if let id = UUID(uuidString: String(item.lastPathComponent.prefix(36))) {
                    usage.chatSizes[id, default: 0] += size
                }
            }
            return usage
        }.value
        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: worktrees, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
        for folder in folders {
            usage.worktrees.append(await measureWorktree(folder))
        }
        usage.worktrees.sort { $0.size > $1.size }
        return usage
    }

    private nonisolated static func measureWorktree(_ folder: URL) async -> WorktreeUsage {
        let isRegistered = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
        var changedFiles: Int?
        var buildFiles: [String] = []
        if isRegistered {
            let git = Git(folder.path)
            changedFiles = await git.status()?.changedFiles
            buildFiles = await ignoredBuildFolders(in: folder, git: git)
        }
        return await Task.detached(priority: .utility) { [buildFiles] in
            WorktreeUsage(path: folder.path, size: allocatedSize(of: folder), buildFiles: buildFiles,
                          buildFilesSize: buildFiles.reduce(0) { $0 + allocatedSize(of: URL(fileURLWithPath: $1)) },
                          changedFiles: changedFiles, isRegistered: isRegistered)
        }.value
    }

    /// Git lists a wholly ignored folder once, as `!! path/`, so nested build folders
    /// inside one are never listed apart from it.
    private nonisolated static func ignoredBuildFolders(in folder: URL, git: Git) async -> [String] {
        guard let result = try? await git.run(["status", "--porcelain=v1", "--ignored", "-z", "--untracked-files=normal"]),
              result.succeeded else { return [] }
        return result.output.split(separator: "\0").compactMap { entry -> String? in
            guard entry.hasPrefix("!! "), entry.hasSuffix("/") else { return nil }
            let relative = String(entry.dropFirst(3).dropLast())
            let url = folder.appendingPathComponent(relative, isDirectory: true)
            return buildFolderNames.contains(url.lastPathComponent) ? url.path : nil
        }
    }

    /// Deletes the build folders a measurement found, after checking each again: inside
    /// the worktree, a known build name, still ignored by Git.
    nonisolated static func removeBuildFiles(of worktree: WorktreeUsage) async throws {
        let root = URL(fileURLWithPath: worktree.path).standardizedFileURL.path + "/"
        let git = Git(worktree.path)
        let lease = try await git.repositoryWriteLease()
        defer { withExtendedLifetime(lease) {} }
        for path in worktree.buildFiles {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(root), buildFolderNames.contains(url.lastPathComponent),
                  url.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/") else { continue }
            let check = try await git.run(["check-ignore", "-q", url.path])
            if check.status == 1 { continue }
            try Git.check(check)
            // An ignored directory can still contain force-added tracked files.
            // Query the index immediately before deletion; failure cannot mean empty.
            let tracked = try await git.output(["--literal-pathspecs", "ls-files", "--cached", "-z", "--", url.path])
            guard tracked.isEmpty else { continue }
            let relative = String(url.path.dropFirst(root.count))
            guard try await git.presentPaths(among: [relative], in: "HEAD").isEmpty else { continue }
            try await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: url) }.value
        }
    }

    nonisolated static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
