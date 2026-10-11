import Foundation
import Synchronization

struct GitStatus: Equatable, Sendable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changedFiles = 0
}

struct GitBranch: Identifiable, Hashable, Sendable {
    var name: String
    var isCurrent: Bool
    var upstream: String?

    var id: String { name }
}

enum GitError: LocalizedError, Sendable {
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let command): String(format: AppText.localized("Timed out running %@."), command)
        }
    }
}

enum GitLane: Hashable, Sendable {
    case read, checkpoint, long

    fileprivate static func inferred(command: String, environment: [String: String]) -> Self {
        switch command {
        case "fetch", "push", "pull", "clone", "worktree": .long
        case "write-tree", "commit-tree", "update-ref", "read-tree", "hash-object": .checkpoint
        case "add", "update-index", "rm": environment["GIT_INDEX_FILE"] != nil ? .checkpoint : .read
        default: .read
        }
    }
}

private actor GitAdmission {
    static let shared = GitAdmission()
    private var available: [GitLane: Int] = [.read: 6, .checkpoint: 2, .long: 2]
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var queues: [GitLane: [Waiter]] = [:]

    func perform<T: Sendable>(lane: GitLane, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(lane)
        defer { release(lane) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ lane: GitLane) async throws {
        try Task.checkCancellation()
        if available[lane, default: 0] > 0 {
            available[lane, default: 0] -= 1
            return
        }
        let id = UUID()
        let cancelled = Mutex(false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.withLock({ $0 }) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    queues[lane, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            Task { await self.cancel(id, lane: lane) }
        }
    }

    private func cancel(_ id: UUID, lane: GitLane) {
        guard let index = queues[lane]?.firstIndex(where: { $0.id == id }) else { return }
        queues[lane]?.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ lane: GitLane) {
        if queues[lane]?.isEmpty == false {
            queues[lane]?.removeFirst().continuation.resume()
        } else {
            available[lane, default: 0] += 1
        }
    }
}

/// A thin wrapper around the git command line. Every call runs off the main actor.
struct Git: Sendable {
    let directory: URL

    init(_ path: String) {
        directory = URL(fileURLWithPath: path)
    }

    private static var executable: URL { LoginEnvironment.git }

    @discardableResult
    func run(
        _ arguments: [String],
        environment extra: [String: String] = [:],
        input: Data? = nil,
        timeout: TimeInterval? = nil,
        lane: GitLane? = nil
    ) async throws -> ShellResult {
        var environment = LoginEnvironment.current
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment.merge(extra) { _, new in new }
        let command = arguments.first(where: { !$0.hasPrefix("-") }) ?? ""
        let assignedLane = lane ?? GitLane.inferred(command: command, environment: extra)
        // Merges read status and diffs too, so the bound only stops a read that has hung.
        let deadline = timeout ?? (command == "status" ? 60 : command == "diff" ? (arguments.contains("--binary") ? 300 : 90) : assignedLane == .long ? 300 : 120)
        let resolvedEnvironment = environment
        return try await GitAdmission.shared.perform(lane: assignedLane) {
            try await withThrowingTaskGroup(of: ShellResult.self) { group in
                group.addTask {
                    try await Shell.run(
                        Self.executable,
                        ["-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments,
                        in: directory,
                        environment: resolvedEnvironment,
                        input: input,
                        timeout: deadline + 5
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(deadline))
                    throw GitError.timedOut(command: "git " + arguments.joined(separator: " "))
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
    }

    func output(_ arguments: [String]) async throws -> String {
        let result = try await run(arguments)
        try Self.check(result)
        return result.output
    }

    static func check(_ result: ShellResult) throws {
        if !result.succeeded { throw ShellError(result.failureMessage) }
    }

    // MARK: - Repository

    func isRepository() async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"]))?.trimmedOutput == "true"
    }

    func repositoryRoot() async throws -> URL {
        let prefix = try await output(["rev-parse", "--show-prefix"])
        var root = directory
        for _ in prefix.trimmed.split(separator: "/") {
            root.deleteLastPathComponent()
        }
        return root
    }

    func hasCommits() async -> Bool {
        (try? await run(["rev-parse", "--verify", "--quiet", "HEAD"]))?.succeeded ?? false
    }

    func status() async -> GitStatus? {
        guard let result = try? await run(["status", "--porcelain=v2", "--branch"]), result.succeeded else { return nil }
        var status = GitStatus()
        for line in result.output.split(separator: "\n") {
            if let head = line.value(after: "# branch.head ") {
                status.branch = head == "(detached)" ? nil : head
            } else if let upstream = line.value(after: "# branch.upstream ") {
                status.upstream = upstream
            } else if let counts = line.value(after: "# branch.ab ") {
                for token in counts.split(separator: " ") {
                    if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                    if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                status.changedFiles += 1
            }
        }
        return status
    }

    func branches() async -> [GitBranch] {
        let format = "%(HEAD)%09%(refname:short)%09%(upstream:short)"
        guard let text = try? await output(["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads"]) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let upstream = parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil
            return GitBranch(name: String(parts[1]), isCurrent: parts[0] == "*", upstream: upstream)
        }
    }

    func switchBranch(_ name: String) async throws {
        try Self.check(await run(["switch", name]))
    }

    func createBranch(_ name: String) async throws {
        try Self.check(await run(["switch", "-c", name]))
    }

    func addWorktree(at path: String, branch: String, base: String?) async throws {
        var arguments = ["worktree", "add", "-b", branch, path]
        if let base { arguments.append(base) }
        try Self.check(await run(arguments))
    }

    func removeWorktree(at path: String) async throws {
        try Self.check(await run(["worktree", "remove", "--force", path]))
    }

    func remoteURL() async -> String? {
        guard let text = try? await output(["remote", "get-url", "origin"]) else { return nil }
        return text.trimmed.nilIfEmpty
    }

    /// The https page for the origin remote, when it is a hosted repository.
    func remoteWebURL() async -> URL? {
        guard var remote = await remoteURL() else { return nil }
        if remote.hasSuffix(".git") { remote.removeLast(4) }
        if remote.hasPrefix("git@"), let colon = remote.firstIndex(of: ":") {
            let host = remote[remote.index(remote.startIndex, offsetBy: 4)..<colon]
            remote = "https://\(host)/\(remote[remote.index(after: colon)...])"
        } else if remote.hasPrefix("ssh://git@") {
            remote = "https://" + remote.dropFirst("ssh://git@".count)
        }
        return remote.hasPrefix("http") ? URL(string: remote) : nil
    }

    func listFiles() async -> [String] {
        guard let text = try? await output(["ls-files", "--cached", "--others", "--exclude-standard"]) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - Commit and publish

    func workingChanges() async -> (summary: String, patch: String) {
        let summary = (try? await output(["status", "--short"])) ?? ""
        var patch = (try? await output(["diff", "HEAD", "--no-ext-diff"])) ?? ""
        if patch.utf8.count > 40_000 { patch = String(patch.prefix(40_000)) }
        return (summary, patch)
    }

    func commitAll(message: String) async throws {
        try Self.check(await run(["add", "-A"]))
        try Self.check(await run(["commit", "-F", "-"], input: Data(message.utf8)))
    }

    func push() async throws {
        try Self.check(await run(["push", "-u", "origin", "HEAD"], timeout: 300))
    }

    /// Opens a pull request (GitHub) or merge request (GitLab) for the current branch, or
    /// for `source` into `target` when those are given.
    func createPullRequest(title: String, body: String, source: String? = nil, target: String? = nil) async throws -> URL? {
        let result: ShellResult
        switch await forge() {
        case .gitlab:
            var arguments = ["mr", "create", "--title", title, "--description", body, "--yes"]
            if let source { arguments += ["--source-branch", source] }
            if let target { arguments += ["--target-branch", target] }
            result = try await Shell.run(tool: "glab", arguments, in: directory, timeout: 300)
        case .github:
            var arguments = ["pr", "create", "--title", title, "--body", body]
            if let source { arguments += ["--head", source] }
            if let target { arguments += ["--base", target] }
            result = try await Shell.run(tool: "gh", arguments, in: directory, timeout: 300)
        case .gitea:
            var arguments = ["pulls", "create", "--title", title, "--description", body]
            if let source { arguments += ["--head", source] }
            if let target { arguments += ["--base", target] }
            result = try await Shell.run(tool: "tea", arguments, in: directory, timeout: 300)
        }
        if !result.succeeded, let existing = Self.existingRequestURL(in: result, web: await remoteWebURL()) {
            return existing
        }
        try Self.check(result)
        let text = result.output + "\n" + result.errorOutput
        let match = text.firstMatch(of: #/https://\S+/#)
        return match.flatMap { URL(string: String($0.output)) }
    }

    /// The open request a forge names when creating another for the same branch fails:
    /// GitHub and Gitea print its address, GitLab names it as `!<number>`. A retried
    /// merge then carries on with that request rather than failing on it.
    static func existingRequestURL(in result: ShellResult, web: URL?) -> URL? {
        let text = result.output + "\n" + result.errorOutput
        guard text.lowercased().contains("already exist") else { return nil }
        if let match = text.firstMatch(of: #/https://\S+/#), let url = URL(string: String(match.output)) {
            return url
        }
        guard let match = text.firstMatch(of: #/!(\d+)/#), var web else { return nil }
        if web.user != nil, var components = URLComponents(url: web, resolvingAgainstBaseURL: false) {
            components.user = nil
            components.password = nil
            if let stripped = components.url { web = stripped }
        }
        return web.appending(path: "-/merge_requests/\(match.1)")
    }

    /// Which forge the origin remote is on, by its host: GitLab and GitHub by name, and
    /// Gitea's family (tea serves them all) for anything else.
    func forge() async -> MergeRequestLink.Forge {
        let remote = (await remoteURL() ?? "").lowercased()
        if remote.contains("gitlab") { return .gitlab }
        if remote.contains("github") { return .github }
        return .gitea
    }

    /// Lands a request with the forge's own CLI. GitLab answers 405 while it is still
    /// checking a fresh request, so that is tried again a few times.
    func mergePullRequest(_ link: MergeRequestLink) async throws {
        let number = String(link.number)
        var lastFailure = "The request could not be merged."
        for attempt in 0..<6 {
            let result: ShellResult
            switch link.forge {
            case .gitlab: result = try await Shell.run(tool: "glab", ["mr", "merge", number, "--yes", "--squash", "--remove-source-branch"], in: directory, timeout: 300)
            case .github: result = try await Shell.run(tool: "gh", ["pr", "merge", number, "--merge"], in: directory, timeout: 300)
            case .gitea: result = try await Shell.run(tool: "tea", ["pulls", "merge", number], in: directory, timeout: 300)
            }
            if result.succeeded { return }
            lastFailure = result.failureMessage
            let text = (result.output + result.errorOutput).lowercased()
            guard link.forge == .gitlab, text.contains("405") || text.contains("not allowed") || text.contains("checking") else { break }
            try? await Task.sleep(for: .seconds(3 + attempt * 2))
        }
        throw ShellError(lastFailure)
    }

    // MARK: - Landing a team's work

    /// The branch the remote treats as its default: what origin's HEAD points at, else
    /// main or master where one exists.
    func defaultBranch() async -> String {
        if let head = try? await output(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).trimmed,
           !head.isEmpty {
            return head.hasPrefix("origin/") ? String(head.dropFirst("origin/".count)) : head
        }
        for candidate in ["main", "master"] where (try? await run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"]))?.succeeded == true {
            return candidate
        }
        return "main"
    }

    /// A tree of HEAD with only `paths` taken from the working tree, additions and
    /// deletions included: what one thread's work amounts to, with nothing else that
    /// happens to be uncommitted alongside it.
    func captureTree(paths: [String]) async throws -> String {
        let fileManager = FileManager.default
        let index = fileManager.temporaryDirectory.appendingPathComponent("tivano-index-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        if await hasCommits() { try Self.check(await run(["read-tree", "HEAD"], environment: environment, lane: .checkpoint)) }
        if !paths.isEmpty {
            try Self.check(await run(["--literal-pathspecs", "add", "-A", "--ignore-errors", "--pathspec-from-file=-", "--pathspec-file-nul"], environment: environment, input: Self.nulSeparated(paths), timeout: 300, lane: .checkpoint))
        }
        let tree = try await run(["write-tree"], environment: environment, lane: .checkpoint)
        try Self.check(tree)
        return tree.trimmedOutput
    }

    /// The team's `paths` on top of `base`, a commit the checkout's `head` is an ancestor
    /// of: what the work amounts to on the remote as it is now. A checkout that has fallen
    /// behind otherwise sends a merge request built on its old HEAD, and every file the
    /// remote changed since then conflicts on the forge, which is how one finished job
    /// opened a conflicted merge request every five minutes. A file `base` changed since
    /// `head` too is merged three ways with git's own `merge-file` (head's version, the
    /// base's, the working tree's). Nil when any such file conflicts, is changed on one
    /// side and deleted on the other, or was added on both sides differently; `merged`
    /// holds every three-way result, for the checkout to take once the work has landed.
    func captureTree(paths: [String], onto base: String, from head: String) async throws -> (tree: String, merged: [String: Data])? {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("tivano-rebase-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let environment = ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path]
        try Self.check(await run(["read-tree", base], environment: environment, lane: .checkpoint))

        // Renames as a delete and an add, so a file the remote moved away counts as changed.
        let upstream = Set(try await output(["diff", "--name-only", "--no-renames", "-z", head, base]).split(separator: "\0").map(String.init))
        let clean = paths.filter { !upstream.contains($0) }
        let contested = paths.filter { upstream.contains($0) }
        if !clean.isEmpty {
            try Self.check(await run(["--literal-pathspecs", "add", "-A", "--ignore-errors", "--pathspec-from-file=-", "--pathspec-file-nul"], environment: environment, input: Self.nulSeparated(clean), timeout: 300, lane: .checkpoint))
        }

        var merged: [String: Data] = [:]
        for path in contested {
            let ancestor = await blobData(head, path)
            let remote = await blobData(base, path)
            let working = try? Data(contentsOf: directory.appendingPathComponent(path))
            switch (remote, working) {
            case (nil, nil):
                // Gone on both sides: the base already has it the way the team left it.
                continue
            case (let remote?, nil):
                // The team deleted it: fine only while the remote left it as head had it.
                guard remote == ancestor else { return nil }
                try Self.check(await run(["--literal-pathspecs", "rm", "--cached", "--quiet", "--ignore-unmatch", "--", path], environment: environment, lane: .checkpoint))
            case (nil, _?):
                // The remote deleted a file the team kept or changed.
                return nil
            case (let remote?, let working?):
                guard remote != working else { continue }
                // Added on both sides with different contents: nothing to merge from.
                guard let ancestor else { return nil }
                let current = scratch.appendingPathComponent("current")
                let common = scratch.appendingPathComponent("common")
                let other = scratch.appendingPathComponent("other")
                try working.write(to: current)
                try ancestor.write(to: common)
                try remote.write(to: other)
                // Exit 0 is a clean merge written into `current`; above 0 counts conflicts.
                let result = try await run(["merge-file", "--quiet", "--", current.path, common.path, other.path])
                guard result.succeeded else { return nil }
                let content = try Data(contentsOf: current)
                let blob = try await run(["hash-object", "-w", "--stdin"], input: content, lane: .checkpoint)
                try Self.check(blob)
                let mode = await fileMode(base, path) ?? "100644"
                try Self.check(await run(["update-index", "--add", "--cacheinfo", "\(mode),\(blob.trimmedOutput),\(path)"], environment: environment, lane: .checkpoint))
                merged[path] = content
            }
        }
        let tree = try await run(["write-tree"], environment: environment, lane: .checkpoint)
        try Self.check(tree)
        return (tree.trimmedOutput, merged)
    }

    /// A file's bytes at a commit, or nil where the commit has no such file.
    private func blobData(_ commit: String, _ path: String) async -> Data? {
        guard let result = try? await run(["cat-file", "blob", "\(commit):\(path)"]), result.succeeded else { return nil }
        return result.stdout
    }

    /// A file's mode at a commit ("100644", "100755"), or nil where it has none.
    private func fileMode(_ commit: String, _ path: String) async -> String? {
        guard let listing = try? await output(["ls-tree", "-z", commit, "--", path]),
              let entry = listing.split(separator: "\0").first,
              let mode = entry.split(separator: " ").first else { return nil }
        return String(mode)
    }

    func treeHash(of ref: String) async throws -> String {
        try await output(["rev-parse", "\(ref)^{tree}"]).trimmed
    }

    func commitHash(of ref: String = "HEAD") async throws -> String {
        try await output(["rev-parse", "--verify", ref]).trimmed
    }

    func message(of ref: String) async throws -> String {
        try await output(["log", "-1", "--format=%B", ref]).trimmed
    }

    /// A commit of `tree` on `parent` in the user's own name, for a branch to carry.
    func commitWork(_ tree: String, parent: String, message: String) async throws -> String {
        let result = try await run(["commit-tree", tree, "-p", parent, "-F", "-"], input: Data(message.utf8), lane: .checkpoint)
        try Self.check(result)
        return result.trimmedOutput
    }

    func updateRef(_ ref: String, to commit: String) async throws {
        try Self.check(await run(["update-ref", ref, commit], lane: .checkpoint))
    }

    /// Moves `ref` only while it still points at `old`, so a branch someone else moved in
    /// the meantime is left where it is rather than run over. `old` nil means the ref must
    /// not exist yet.
    func updateRef(_ ref: String, to commit: String, expecting old: String?) async throws {
        try Self.check(await run(["update-ref", ref, commit, old ?? ""], lane: .checkpoint))
    }

    /// Pushes a branch. `force` is for a branch Tivano owns outright (a Hydra job's),
    /// which a retry rebuilds on a newer base, so its open merge request follows along
    /// instead of a second one being opened.
    func pushBranch(_ name: String, force: Bool = false) async throws {
        try Self.check(await run(["push", "-u"] + (force ? ["--force"] : []) + ["origin", "refs/heads/\(name):refs/heads/\(name)"], timeout: 300))
    }

    func fetch() async throws {
        try Self.check(await run(["fetch", "--quiet", "origin"], timeout: 300))
    }

    func isAncestor(_ commit: String, of other: String) async -> Bool {
        (try? await run(["merge-base", "--is-ancestor", commit, other]))?.succeeded ?? false
    }

    func mergeBase(_ a: String, _ b: String) async -> String? {
        guard let result = try? await run(["merge-base", a, b]), result.succeeded else { return nil }
        return result.trimmedOutput.nilIfEmpty
    }

    /// Paths that differ between two commits or trees, as they are on disk: NUL-separated,
    /// so a name with a quote or a tab in it comes back unquoted and usable as a path.
    func changedPaths(from: String, to: String) async throws -> [String] {
        try await output(["diff", "--name-only", "-z", from, to]).split(separator: "\0").map(String.init)
    }

    /// Lines added and removed per file between two trees, over `paths` alone and without a
    /// patch: what a change too big to show line by line still counts for.
    func lineCounts(from: String, to: String, paths: [String]) async throws -> [RevertPreview.File] {
        var files: [RevertPreview.File] = []
        var start = 0
        while start < paths.count {
            let chunk = Array(paths[start..<min(start + Self.diffPathChunk, paths.count)])
            let text = try await output(["--literal-pathspecs", "diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", from, to, "--"] + chunk)
            files += try RevertPreview(numstat: text).files
            start += chunk.count
        }
        return files
    }

    /// Paths with uncommitted changes, staged or not, untracked ones included.
    func dirtyPaths() async -> [String] {
        guard let text = try? await output(["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else { return [] }
        var records = text.split(separator: "\0", omittingEmptySubsequences: false)[...]
        var paths: [String] = []
        while let entry = records.popFirst() {
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            // A rename or a copy is two records: the new name, then the name it came from.
            // That second record is not an entry of its own, and both names are dirty.
            if code.contains("R") || code.contains("C"), let origin = records.popFirst(), !origin.isEmpty {
                paths.append(String(origin))
            }
        }
        return paths
    }

    /// Paths from `paths` that the checkout ignores.
    func ignoredPaths(among paths: [String]) async -> Set<String> {
        guard !paths.isEmpty, let result = try? await run(["check-ignore", "-z", "--stdin"], input: Self.nulSeparated(paths)), result.succeeded || result.status == 1 else { return [] }
        return Set(result.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init))
    }

    /// Paths from `paths` that HEAD holds. That is what `captureTree(paths:)` reads its
    /// index from, so a path in HEAD can be staged even once it is gone from disk (the
    /// deletion is the work), while a path in neither is a pathspec that matches nothing
    /// and takes the whole `git add` down. `ls-files` reads no pathspec file, so the
    /// check goes through `cat-file --batch-check`, one `HEAD:<path>` per line on stdin,
    /// which answers in order with `missing` for what HEAD does not have.
    func trackedPaths(among paths: [String]) async -> Set<String> {
        await presentPaths(among: paths, in: "HEAD")
    }

    /// Paths from `paths` that `ref` holds, answered by one `cat-file --batch-check` over
    /// the lot rather than a `cat-file -e` per path: a branch that moved on by thousands
    /// of files (a build's output merged once by mistake, say) used to mean thousands of
    /// git processes one after another, with the main actor picking each one up in turn.
    func presentPaths(among paths: [String], in ref: String) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let input = paths.reduce(into: Data()) { data, path in
            data.append(contentsOf: "\(ref):\(path)".utf8)
            data.append(0)
        }
        guard let result = try? await run(["cat-file", "--batch-check=%(objecttype)", "-Z"], input: input), result.succeeded else { return [] }
        let answers = result.output.split(separator: "\0", omittingEmptySubsequences: false)
        var tracked = Set<String>()
        for (path, answer) in zip(paths, answers) where !answer.hasSuffix(" missing") {
            tracked.insert(path)
        }
        return tracked
    }

    private static func nulSeparated(_ paths: [String]) -> Data {
        paths.reduce(into: Data()) { data, path in
            data.append(contentsOf: path.utf8)
            data.append(0)
        }
    }

    /// Whether a rebase, merge or cherry-pick is underway: nothing may move then.
    ///
    /// Every marker is per-worktree, so one `rev-parse --git-dir` names where all of them
    /// live — a linked worktree's own git directory, where git writes them, not the shared
    /// one — and the rest is six `fileExists` calls. Asking `--git-path` per marker was six
    /// git processes on every landing and every merge. A directory git cannot be asked
    /// about, or one that is no repository at all, counts as busy: callers use the answer
    /// to keep out of a checkout's way, and a state nobody can read is no reason to write
    /// into it. (`GIT_DIR`, when the environment sets it, is honoured by `--git-dir` too.)
    func hasOperationInProgress() async -> Bool {
        guard let gitDirectory = try? await output(["rev-parse", "--path-format=absolute", "--git-dir"]).trimmed,
              !gitDirectory.isEmpty else { return true }
        for marker in ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"] {
            if FileManager.default.fileExists(atPath: gitDirectory + "/" + marker) { return true }
        }
        return false
    }

    /// Moves the current branch to `commit`; index and working tree stay as they are.
    func resetSoft(to commit: String) async throws {
        try Self.check(await run(["reset", "--soft", "--quiet", commit]))
    }

    /// The index takes HEAD's version of `paths`; the working tree stays as it is.
    func resetIndex(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try Self.check(await run(["--literal-pathspecs", "reset", "--quiet", "--pathspec-from-file=-", "--pathspec-file-nul"], input: Self.nulSeparated(paths)))
    }

    /// Index and working tree take `ref`'s version of `paths`.
    func checkoutPaths(from ref: String, _ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try Self.check(await run(["--literal-pathspecs", "checkout", "--quiet", ref, "--"] + paths))
    }

    func removePaths(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try Self.check(await run(["--literal-pathspecs", "rm", "--quiet", "--"] + paths))
    }

    func pullFastForward() async throws {
        try Self.check(await run(["pull", "--ff-only", "--quiet"], timeout: 300))
    }

    // MARK: - Checkpoints

    static func checkpointRef(thread: UUID, turn: Int, phase: String) -> String {
        "refs/tivano/checkpoints/\(thread.uuidString.lowercased())/\(turn)-\(phase)"
    }

    /// Snapshots the working tree into a hidden ref without touching the user's index or
    /// branch. A tree already checkpointed since anything changed reuses its commit, so a
    /// turn starting on an untouched tree costs the `update-ref` alone.
    func captureCheckpoint(_ ref: String) async throws {
        let tree = try await currentTree()
        let watch = await watch()
        let commit: String
        if let known = watch?.commit(of: tree) {
            commit = known
        } else {
            let result = try await run(["commit-tree", tree, "-m", "Tivano checkpoint"], environment: Self.identity, lane: .checkpoint)
            try Self.check(result)
            commit = result.trimmedOutput
            watch?.remember(commit: commit, of: tree)
        }
        try Self.check(await run(["update-ref", ref, commit], lane: .checkpoint))
    }

    /// The working tree as a tree object, from the directory's watch when it can vouch
    /// that nothing changed since the last capture, else captured now.
    func currentTree() async throws -> String {
        guard let indexPath = await indexPath(), let watch = await watch() else { return try await captureTree() }
        return try await watch.currentTree(indexPath: indexPath) { scratch, paths in
            guard let scratch else { return try await captureTree() }
            return try await captureTree(scratch: scratch, paths: paths)
        }
    }

    /// `captureTree` over a scratch index kept between captures: with `paths`, the
    /// directories the watch saw change since the last capture, only they are walked and
    /// the rest of the index stands. A walk that fails, as when a path vanished with
    /// nothing of it in the index, is redone whole.
    private func captureTree(scratch: URL, paths: [String]?) async throws -> String {
        let environment = ["GIT_INDEX_FILE": scratch.path]
        if let paths, !paths.isEmpty, FileManager.default.fileExists(atPath: scratch.path),
           (try? await run(["--literal-pathspecs", "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], environment: environment, input: Self.nulSeparated(paths), timeout: 300, lane: .checkpoint))?.succeeded == true {
            let tree = try await run(["write-tree"], environment: environment, lane: .checkpoint)
            try Self.check(tree)
            return tree.trimmedOutput
        }
        try? FileManager.default.removeItem(at: scratch)
        if let indexPath = await indexPath(), FileManager.default.fileExists(atPath: indexPath) {
            try? FileManager.default.copyItem(atPath: indexPath, toPath: scratch.path)
        } else if await hasCommits() {
            try Self.check(await run(["read-tree", "HEAD"], environment: environment, lane: .checkpoint))
        }
        try Self.check(await run(["add", "-A", "--", "."], environment: environment, timeout: 300, lane: .checkpoint))
        let tree = try await run(["write-tree"], environment: environment, lane: .checkpoint)
        try Self.check(tree)
        return tree.trimmedOutput
    }

    private func watch() async -> WorkingTreeWatch? {
        guard let indexPath = await indexPath() else { return nil }
        return WorkingTreeWatch.shared(for: directory.path, gitDirectory: (indexPath as NSString).deletingLastPathComponent)
    }

    /// The working tree as a tree object: a cheap before/after marker for a
    /// diff, with no commit and nothing referenced. Respects .gitignore.
    func captureTree() async throws -> String {
        let fileManager = FileManager.default
        let index = fileManager.temporaryDirectory.appendingPathComponent("tivano-index-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]

        // Starting from the real index keeps git's stat cache, so unchanged files are not re-hashed.
        if let indexPath = await indexPath(), fileManager.fileExists(atPath: indexPath) {
            try? fileManager.copyItem(atPath: indexPath, toPath: index.path)
        } else if await hasCommits() {
            try Self.check(await run(["read-tree", "HEAD"], environment: environment, lane: .checkpoint))
        }
        try Self.check(await run(["add", "-A", "--", "."], environment: environment, timeout: 300, lane: .checkpoint))
        let tree = try await run(["write-tree"], environment: environment, lane: .checkpoint)
        try Self.check(tree)
        return tree.trimmedOutput
    }

    /// What a worktree's index path was resolved from: its `.git` file, which names the
    /// git directory, and the environment overrides git would honour over it.
    struct GitFileStamp: Equatable {
        var identifier: UInt64?
        var modified: Date?
        var size: Int?
        var overrides: String

        init(gitFile: String, environment: [String: String]) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: gitFile)
            identifier = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            modified = attributes?[.modificationDate] as? Date
            size = attributes?[.size] as? Int
            overrides = (environment["GIT_DIR"] ?? "") + "\u{0}" + (environment["GIT_INDEX_FILE"] ?? "")
        }
    }

    /// Resolved index paths of worktrees by working directory. A session works in a
    /// handful of directories; past the bound the cache is simply dropped.
    static let worktreeIndexPaths = Mutex<[String: (stamp: GitFileStamp, path: String?)]>([:])

    /// The repository's index file. A checkout with its own `.git` directory keeps it right
    /// there, which saves the git process that asking would cost on every snapshot. A
    /// worktree (`.git` is a file naming the git directory) asks once and keeps the answer
    /// while that file stands unchanged: a snapshot asks three or four times, and every
    /// command tool takes two snapshots. A directory inside a repository, with no `.git`
    /// of its own, still asks every time, since the answer depends on its ancestors.
    private func indexPath() async -> String? {
        var isDirectory: ObjCBool = false
        let dotGit = directory.appendingPathComponent(".git").path
        let environment = LoginEnvironment.current
        let exists = FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue, environment["GIT_DIR"] == nil, environment["GIT_INDEX_FILE"] == nil {
            return dotGit + "/index"
        }
        let stamp = exists ? GitFileStamp(gitFile: dotGit, environment: environment) : nil
        if let stamp, let cached = Self.worktreeIndexPaths.withLock({ $0[directory.path] }), cached.stamp == stamp {
            return cached.path
        }
        let path = try? await output(["rev-parse", "--path-format=absolute", "--git-path", "index"])
            .trimmed
        if let stamp {
            Self.worktreeIndexPaths.withLock { paths in
                if paths.count >= 64 { paths.removeAll() }
                paths[directory.path] = (stamp, path)
            }
        }
        return path
    }

    /// Paths per `git diff` call when a caller names many: well under the argument limit.
    private static let diffPathChunk = 400

    /// The patch between two trees or refs. `binary` puts whole binary blobs in it, so a
    /// picture a head added applies elsewhere. Over `paths` alone when given: a diff of a
    /// tree that holds build output runs to hundreds of megabytes, so the caller names
    /// the files it wants rather than cutting the rest out afterwards.
    func diff(from: String, to: String, binary: Bool = false, paths: [String]? = nil) async throws -> String {
        // `diff` takes no pathspec file, so the paths go on the command line, and as
        // plain names: a `?` or `[` in one is a character, not a pattern. Long lists go in
        // chunks: a command that touched thousands of files would otherwise blow the
        // argument limit, and one diff per chunk joins into the same patch.
        var arguments = paths == nil ? [] : ["--literal-pathspecs"]
        arguments += ["diff", "--no-ext-diff", "-M"]
        if binary { arguments.append("--binary") }
        arguments += [from, to]
        guard let paths, paths.count > Self.diffPathChunk else {
            if let paths { arguments += ["--"] + paths }
            let result = try await run(arguments, timeout: binary ? 300 : 90)
            try Self.check(result)
            return result.output
        }
        var output = ""
        var start = 0
        while start < paths.count {
            let chunk = Array(paths[start..<min(start + Self.diffPathChunk, paths.count)])
            let result = try await run(arguments + ["--"] + chunk, timeout: binary ? 300 : 90)
            try Self.check(result)
            if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
            output += result.output
            start += chunk.count
        }
        return output
    }

    /// What undoing a thread's file changes would touch: of `paths` (the files its agent
    /// changed, relative to this directory), the ones that differ between `base` and `end`,
    /// the tree the thread last left. A file the checkout has changed again since then is
    /// somebody else's work now, so it is marked kept. Other threads' files never appear:
    /// only `paths` are looked at. Without an `end` tree (no turn finished) the files are
    /// compared to the checkout as it is, which then counts as what the thread left.
    func previewRestore(base: String, end known: String?, paths: [String]) async throws -> RevertPreview {
        guard !paths.isEmpty else { return RevertPreview(files: []) }
        let end: String
        if let known { end = known } else { end = try await captureTree(paths: paths) }
        // `git diff` takes no pathspec file; a turn touches tens of files, well within the arguments.
        var preview = try RevertPreview(numstat: await output(["--literal-pathspecs", "diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", base, end, "--"] + paths))
        guard !preview.files.isEmpty else { return preview }
        let root = try await repositoryRoot()
        let left = try await blobs(in: end, at: preview.files.map(\.path), root: root)
        let now = try await workingBlobs(at: preview.files.map(\.path), root: root)
        preview.files = preview.files.map { file in
            var file = file
            file.isKept = left[file.path] != now[file.path]
            return file
        }
        return preview
    }

    /// Puts `paths` (repository-relative) back as they are in `ref`, deleting the ones it
    /// lacks. Nothing outside `paths` is touched.
    func restore(_ paths: [String], from ref: String) async throws {
        guard !paths.isEmpty else { return }
        let root = try await repositoryRoot()
        let present = try await blobs(in: ref, at: paths, root: root)
        let restored = paths.filter { present[$0] != nil }
        if !restored.isEmpty {
            let result = try await run(
                ["--literal-pathspecs", "restore", "--source", ref, "--worktree", "--staged", "--pathspec-from-file=-", "--pathspec-file-nul"],
                input: Data(restored.map { root.appendingPathComponent($0).path }.joined(separator: "\0").utf8)
            )
            try Self.check(result)
        }
        let created = paths.filter { present[$0] == nil }
        if !created.isEmpty {
            _ = try? await run(
                ["--literal-pathspecs", "rm", "-q", "--cached", "--ignore-unmatch", "--pathspec-from-file=-", "--pathspec-file-nul"],
                input: Data(created.map { root.appendingPathComponent($0).path }.joined(separator: "\0").utf8)
            )
            for path in created { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
        }
    }

    /// The blob of each of `paths` (repository-relative) in `ref`, for the ones it has.
    private func blobs(in ref: String, at paths: [String], root: URL) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        // ls-tree's path arguments are patterns, not checkout pathspecs. Enumerate the
        // full tree with verbatim NUL names, including directories, then match exactly.
        let listing = try await output(["ls-tree", "-r", "-t", "-z", "--full-tree", ref])
        let rootPath = root.standardizedFileURL.path + "/"
        var requested: [String: [String]] = [:]
        for path in paths {
            let absolute = root.appendingPathComponent(path).standardizedFileURL.path
            guard absolute.hasPrefix(rootPath) else { throw ShellError("Invalid repository-relative path: \(path)") }
            requested[String(absolute.dropFirst(rootPath.count)), default: []].append(path)
        }
        var blobs: [String: String] = [:]
        blobs.reserveCapacity(paths.count)
        for entry in listing.split(separator: "\0") {
            // "<mode> <type> <hash>\t<path>"
            guard let tab = entry.firstIndex(of: "\t") else { throw ShellError("Invalid git ls-tree entry.") }
            let fields = entry[..<tab].split(separator: " ")
            guard fields.count == 3 else { throw ShellError("Invalid git ls-tree entry.") }
            let name = String(entry[entry.index(after: tab)...])
            for path in requested[name] ?? [] { blobs[path] = String(fields[2]) }
        }
        return blobs
    }

    /// The blob each of `paths` (repository-relative) would hash to as it is on disk; a
    /// missing file has none.
    private func workingBlobs(at paths: [String], root: URL) async throws -> [String: String] {
        let existing = paths.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard !existing.isEmpty else { return [:] }
        // --stdin-paths is line-based; argv preserves newlines and quotes in filenames.
        var blobs: [String: String] = [:]
        var start = 0
        while start < existing.count {
            let chunk = Array(existing[start..<min(start + Self.diffPathChunk, existing.count)])
            let result = try await run(["hash-object", "--"] + chunk.map { root.appendingPathComponent($0).path }, lane: .checkpoint)
            try Self.check(result)
            let hashes = result.output.split(whereSeparator: \.isNewline)
            guard hashes.count == chunk.count else { throw ShellError("git hash-object answered for \(hashes.count) of \(chunk.count) files.") }
            for (path, hash) in zip(chunk, hashes) { blobs[path] = String(hash) }
            start += chunk.count
        }
        return blobs
    }

    func deleteCheckpoints(thread: UUID) async {
        let prefix = "refs/tivano/checkpoints/\(thread.uuidString.lowercased())/"
        guard let refs = try? await output(["for-each-ref", "--format=%(refname)", prefix]) else { return }
        let commands = refs.split(separator: "\n").map { "delete \($0)\n" }.joined()
        guard !commands.isEmpty else { return }
        _ = try? await run(["update-ref", "--stdin"], input: Data(commands.utf8), lane: .checkpoint)
    }

    // MARK: - Copies of the checkout

    private static let identity = [
        "GIT_AUTHOR_NAME": "Tivano", "GIT_AUTHOR_EMAIL": "tivano@localhost",
        "GIT_COMMITTER_NAME": "Tivano", "GIT_COMMITTER_EMAIL": "tivano@localhost",
    ]

    /// A commit of `tree` on top of HEAD that no ref points at: the checkout as it is,
    /// uncommitted work included, with the history behind it. Something a worktree can
    /// start from.
    func commitTree(_ tree: String, message: String) async throws -> String {
        var arguments = ["commit-tree", tree, "-m", message]
        if await hasCommits() { arguments += ["-p", "HEAD"] }
        let result = try await run(arguments, environment: Self.identity, lane: .checkpoint)
        try Self.check(result)
        return result.trimmedOutput
    }

    /// A worktree at `path` with `commit` checked out and no branch: a copy of the
    /// checkout to work in, whose own status shows only what changed in it.
    func addDetachedWorktree(at path: String, commit: String) async throws {
        try Self.check(await run(["worktree", "add", "--detach", path, commit], timeout: 300))
    }

    /// Forgets worktrees whose folders are gone from disk.
    func pruneWorktrees() async {
        _ = try? await run(["worktree", "prune"])
    }

    /// Applies `patch` to the working tree and stages nothing. A hunk that no longer fits
    /// is merged three-way against the blobs the patch names; a file the merge cannot
    /// settle keeps conflict markers, and those paths come back. Throws when nothing
    /// could be applied at all.
    func apply(_ patch: String) async throws -> [String] {
        let data = Data(patch.utf8)
        let plain = try await run(["apply", "--binary", "--whitespace=nowarn", "-"], input: data)
        if plain.succeeded { return [] }

        // The three-way merge works through an index that matches the working tree, so
        // it gets a throwaway one that does, and the real index never changes.
        let fileManager = FileManager.default
        let index = fileManager.temporaryDirectory.appendingPathComponent("tivano-apply-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        if let indexPath = await indexPath(), fileManager.fileExists(atPath: indexPath) {
            try? fileManager.copyItem(atPath: indexPath, toPath: index.path)
        } else if await hasCommits() {
            try Self.check(await run(["read-tree", "HEAD"], environment: environment, lane: .checkpoint))
        }
        try Self.check(await run(["add", "-A", "--", "."], environment: environment, timeout: 300, lane: .checkpoint))
        let merged = try await run(["apply", "--3way", "--binary", "--whitespace=nowarn", "-"], environment: environment, input: data, lane: .checkpoint)
        if merged.succeeded { return [] }
        // "U path" names each file left with markers; without one, nothing was applied.
        let conflicts = merged.errorOutput.split(separator: "\n").compactMap { line -> String? in
            line.hasPrefix("U ") ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil
        }
        guard !conflicts.isEmpty else { throw ShellError(merged.failureMessage) }
        return conflicts
    }
}

private extension Substring {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
