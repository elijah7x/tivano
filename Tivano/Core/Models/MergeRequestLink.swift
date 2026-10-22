import Foundation

/// A merge request (GitLab), pull request (GitHub, Gitea, Forgejo, Codeberg) that a link in
/// the chat points at, for the "Merge" row on the link's popover and the helper it spawns.
struct MergeRequestLink: Equatable, Sendable {
    enum Forge: Sendable {
        case gitlab
        case github
        /// Cursor Origin pull requests use the official `origin` CLI.
        case cursorOrigin
        /// Gitea and its forks, Forgejo and Codeberg among them: one CLI, `tea`, serves them all.
        case gitea
    }

    var url: URL
    var forge: Forge
    var number: Int

    /// How each forge writes its own: "!95" on GitLab, "#95" everywhere else.
    var label: String { forge == .gitlab ? "!\(number)" : "#\(number)" }

    /// `…/group/project/-/merge_requests/95` (any GitLab host, `diffs` or another page after
    /// the number included), `owner/repo/pull/95` (github.com or a GitHub Enterprise host),
    /// or `owner/repo/pulls/95` (Gitea, Forgejo, Codeberg).
    init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        let isCursor = ["cursor.com", "www.cursor.com"].contains(url.host?.lowercased() ?? "")
        if isCursor, parts.count >= 5, parts[0] == "codebase", parts[3] == "pull",
           let number = Int(parts[4]), number > 0 {
            forge = .cursorOrigin
            self.number = number
        } else if isCursor {
            return nil
        } else if let index = parts.firstIndex(of: "merge_requests"), index >= 1, index + 1 < parts.count,
           let number = Int(parts[index + 1]), number > 0 {
            forge = .gitlab
            self.number = number
        } else if parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0 {
            forge = .github
            self.number = number
        } else if parts.count >= 4, parts[2] == "pulls", let number = Int(parts[3]), number > 0 {
            forge = .gitea
            self.number = number
        } else {
            return nil
        }
        self.url = url
    }

    var originRepository: String? {
        guard forge == .cursorOrigin else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[0] == "codebase", parts[3] == "pull" else { return nil }
        return "\(parts[1])/\(parts[2])"
    }

    /// The helper's title: the same words as the popover's row.
    var title: String { "Merge \(label)" }

    /// What the helper is asked to do: land the request with the forge's own CLI, then leave
    /// the checkout on the merged main. Complete on its own, since a native provider reads
    /// no AGENTS.md before it starts.
    var prompt: String {
        let land = switch forge {
        case .gitlab:
            "Use glab from this directory: `glab mr merge \(number) --yes`. If GitLab answers that the request is still being checked (a 405), wait a few seconds and try again; if it reports conflicts, stop and say so instead of resolving them."
        case .github:
            "Use gh from this directory: `gh pr merge \(number) --merge`. If GitHub reports the pull request is not mergeable, stop and say so instead of resolving it."
        case .cursorOrigin:
            "Use origin from this directory: `origin pr merge \(number) -R \(originRepository ?? "")`. Confirm this repository matches the checkout's origin remote before merging. If origin is not installed or not signed in, tell the user to install it and run `origin auth login`, then stop. If the change is not mergeable, stop and say so instead of working around it. Never push to the base branch directly. Confirm the request is merged with `origin pr view \(number) -R \(originRepository ?? "") --json status,mergedAt` before syncing."
        case .gitea:
            "Use tea from this directory: `tea pulls merge \(number)`. If tea is not installed or signed in to this host, or the pull request is not mergeable, stop and say so instead of working around it."
        }
        return """
        Merge \(label) now: \(url.absoluteString)

        \(land) Once it is merged, sync the checkout: if this directory is on main with a clean working tree, run `git pull --ff-only`; otherwise leave the working tree alone and say so. Do not rebuild, install or relaunch anything. Reply in a few lines with the merged commit and the request's link.
        """
    }
}

/// The repository identity shared by Cursor Origin's SSH and HTTPS remotes.
struct CursorOriginRemote: Equatable, Sendable {
    let owner: String
    let repo: String
    var fullName: String { "\(owner)/\(repo)" }
    var webURL: URL {
        URL(string: "https://cursor.com/codebase")!
            .appendingPathComponent(owner).appendingPathComponent(repo)
    }

    init?(remote: String) {
        var normalized = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.contains("://"), let colon = normalized.firstIndex(of: ":") {
            normalized = "ssh://" + normalized[..<colon] + "/" + normalized[normalized.index(after: colon)...]
        }
        guard let url = URL(string: normalized), url.host?.lowercased() == "origin.cursor.com" else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }
        if parts.count == 3, parts.first == "git" { parts.removeFirst() }
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { return nil }
        owner = parts[0]
        repo = parts[1]
    }
}
