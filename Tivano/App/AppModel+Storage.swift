import Foundation

/// The storage page's actions on managed worktrees. Measuring lives in `Storage`; what a
/// worktree belongs to, and so whether it may go, is the library's to say.
extension AppModel {
    /// The chats that work in the worktree, or were sent to it as their checkout.
    func threadsUsing(_ worktree: WorktreeUsage) -> [ChatThread] {
        let path = Self.resolved(worktree.path)
        return threads.filter { thread in
            [thread.worktreePath, thread.hydra?.targetCheckout].contains { candidate in
                guard let candidate, !candidate.isEmpty else { return false }
                let resolved = Self.resolved(candidate)
                return resolved == path || resolved.hasPrefix(path + "/")
            }
        }
    }

    /// Only a folder no chat or project uses, with nothing uncommitted in it, is removed
    /// from the page. A chat's own worktree goes with the chat, when it is deleted.
    func canRemove(_ worktree: WorktreeUsage) -> Bool {
        guard threadsUsing(worktree).isEmpty, !hasProject(inside: worktree) else { return false }
        return worktree.isRegistered ? worktree.changedFiles == 0 : true
    }

    /// True when no non-archived chat uses the worktree and no project points inside it.
    func isIdle(_ worktree: WorktreeUsage) -> Bool {
        threadsUsing(worktree).allSatisfy(\.isArchived) && !hasProject(inside: worktree)
    }

    /// Opens a new standalone chat prefilled with a read-only worktree review prompt.
    func startWorktreeReview(for usage: StorageUsage) {
        guard let thread = newThread(affiliation: .standalone, workspace: .local) else { return }
        runtime(for: thread.id).draft.text = worktreeReviewPrompt(for: usage)
        openThread(thread.id)
        WindowManager.shared.showMain()
        WindowManager.shared.hideSettings()
    }

    private func hasProject(inside worktree: WorktreeUsage) -> Bool {
        let path = Self.resolved(worktree.path)
        return projects.contains {
            let resolved = Self.resolved($0.path)
            return resolved == path || resolved.hasPrefix(path + "/")
        }
    }

    /// Removes an unused worktree. Its branch stays, so committed work is never lost; a
    /// folder Git no longer knows goes to the Trash, since what is in it is unknown.
    func removeUnusedWorktree(_ worktree: WorktreeUsage) async -> Bool {
        guard canRemove(worktree) else { return false }
        let url = URL(fileURLWithPath: worktree.path)
        do {
            if worktree.isRegistered {
                let git = Git(worktree.path)
                guard let status = await git.status(), status.changedFiles == 0 else {
                    alert = AppAlert(title: "Could not remove worktree", message: Chrome.localized("The worktree has changes or could not be inspected. Its files were kept."))
                    return false
                }
                let common = try await git.output(["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmed
                let lease = try await git.repositoryWriteLease()
                defer { withExtendedLifetime(lease) {} }
                guard canRemove(worktree) else { return false }
                try await Git(common).removeWorktree(at: worktree.path)
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            return true
        } catch {
            alert = AppAlert(title: "Could not remove worktree", message: error.localizedDescription)
            return false
        }
    }

    func removeBuildFiles(of worktree: WorktreeUsage) async {
        do {
            try await Storage.removeBuildFiles(of: worktree)
        } catch {
            alert = AppAlert(title: "Could not delete build files", message: error.localizedDescription)
        }
    }

    /// The worktree a chat's deletion may take with it, as a deletion with the worktree
    /// would: its own, under the managed directory.
    func ownWorktree(of thread: ChatThread) -> String? {
        guard !thread.isHelper, thread.hydra?.hasOwnCopy != true, let path = thread.worktreePath, !path.isEmpty,
              Self.resolved(path).hasPrefix(Self.resolved(Storage.worktreesDirectory.path) + "/"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
