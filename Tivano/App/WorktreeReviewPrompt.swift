import Foundation

/// Builds the read-only worktree tidy-up prompt that Settings › Storage prefills into a new chat.
extension AppModel {
    func worktreeReviewPrompt(for usage: StorageUsage, now: Date = .now) -> String {
        let sorted = usage.worktrees
            .map { (worktree: $0, idle: isIdle($0)) }
            .sorted { lhs, rhs in
                if lhs.idle != rhs.idle { return lhs.idle }
                return lhs.worktree.size > rhs.worktree.size
            }

        let entries = sorted.map {
            worktreeRow(for: $0.worktree, now: now)
        }

        let rows: [String]
        let omittedCount: Int
        if entries.count > 60 {
            let kept = entries.filter { !$0.isActive }
            omittedCount = entries.count - kept.count
            rows = kept.map(\.line)
        } else {
            omittedCount = 0
            rows = entries.map(\.line)
        }

        var tableLines = [
            String(localized: "| Worktree | Project | Branch | Chat | Chat state | Last activity | Uncommitted | Size (build output) |"),
            "|---|---|---|---|---|---|---|---|",
        ]
        tableLines.append(contentsOf: rows)

        var inventory = tableLines.joined(separator: "\n")
        if omittedCount > 0 {
            inventory += "\n\n" + String(
                format: String(localized: "%lld worktrees used by active chats are left out."),
                Int64(omittedCount)
            )
        }

        let worktreesFolder = (Storage.worktreesDirectory.path as NSString).abbreviatingWithTildeInPath
        let timestamp = now.formatted(date: .abbreviated, time: .shortened)
        let template = String(localized: "## Goal\nHelp me tidy up Tivano's Git worktrees: tell me which ones are safe to delete, which ones to keep, and which ones need my attention first. Inspect only. Do not delete or change anything.\n\n## Background\nEach worktree is a separate copy of a project that a Tivano chat works in. Deleting a worktree folder keeps its branch and commits in the repository.\nWorktrees folder: %1$@\n\n## Inventory from Tivano (%2$@)\n%3$@\n\n## Check each worktree (read-only Git commands are fine)\n1. Is its branch already merged into the project's default branch or dev? (git merge-base --is-ancestor)\n2. Does it have commits that are neither pushed nor merged? (git log <default>..<branch>)\n3. What are its uncommitted changes and untracked files? (git status --short)\n4. Does it hold ignored files that are not build output, such as .env or a local database?\n\n## Output\nThree groups, each a table with Worktree, Reason and Evidence (a short summary of the command output):\n- Safe to delete: no active chat uses it, no uncommitted changes, and its commits are merged or it has none of its own.\n- Handle first: unmerged commits or uncommitted changes. Say what to do first.\n- Keep: an active chat uses it, or it changed in the last 7 days.\nEnd with how much space the safe group frees. I will delete those myself in Settings › Storage; you may list the matching commands for me to review.\n\n## Do not\nDo not run git worktree remove, rm, git reset, git clean, git checkout or git push, and do not modify any file. When unsure, put it under Handle first and say why.")
        return String(format: template, worktreesFolder, timestamp, inventory)
    }

    private func worktreeRow(
        for worktree: WorktreeUsage,
        now: Date
    ) -> (line: String, isActive: Bool) {
        let users = threadsUsing(worktree)
        let preferredThread = users.max { lhs, rhs in
            if lhs.isArchived != rhs.isArchived { return lhs.isArchived }
            return lhs.updatedAt < rhs.updatedAt
        }
        let projectName = (preferredThread?.projectID.flatMap { project($0) }
            ?? users.compactMap { project($0.projectID) }.first)?.name ?? "-"

        let chatState: String
        let isActive: Bool
        if !worktree.isRegistered {
            chatState = String(localized: "Not a worktree")
            isActive = false
        } else if users.contains(where: { !$0.isArchived }) {
            chatState = String(localized: "Active")
            isActive = true
        } else if !users.isEmpty {
            chatState = String(localized: "Archived")
            isActive = false
        } else {
            chatState = String(localized: "None")
            isActive = false
        }

        let lastActivityDate = [preferredThread?.updatedAt, worktree.lastCommitDate].compactMap { $0 }.max()
        let lastActivity = lastActivityDate.map { AppFormatting.relativeDateTime.localizedString(for: $0, relativeTo: now) } ?? "-"
        let sizeText = "\(AppFormatting.fileByteCount.string(fromByteCount: worktree.size)) (\(AppFormatting.fileByteCount.string(fromByteCount: worktree.buildFilesSize)))"

        let cells = [
            worktree.name,
            projectName,
            worktree.branch ?? "-",
            preferredThread?.title ?? "-",
            chatState,
            lastActivity,
            worktree.changedFiles.map(String.init) ?? "?",
            sizeText,
        ].map(Self.sanitizedTableCell)

        return ("| \(cells.joined(separator: " | ")) |", isActive)
    }

    private static func sanitizedTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
