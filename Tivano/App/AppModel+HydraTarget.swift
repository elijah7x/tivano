import Foundation

extension AppModel {
    /// Follows the lead's unambiguous worktree reference for this request, so heads do
    /// not land in the main checkout merely because that is where the chat was opened.
    /// Reads `.git` directly rather than running git: dispatch decides synchronously at
    /// the end of the lead's turn, where waiting would let a new turn slip in first.
    func hydraLeadWorktree(of lead: ChatThread, runtime: ThreadRuntime) -> String? {
        guard lead.worktreePath == nil, let leadCheckout = hydraCheckout(of: lead) else { return nil }
        let checkout = HydraPaths.canonical(leadCheckout)
        let manager = FileManager.default
        let gitDir = URL(fileURLWithPath: checkout, isDirectory: true).appendingPathComponent(".git", isDirectory: true)
        var isDir: ObjCBool = false
        // Only a repository's main checkout has a .git directory; a linked worktree has a .git file.
        guard manager.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue,
              let names = try? manager.contentsOfDirectory(atPath: gitDir.appendingPathComponent("worktrees").path) else { return nil }
        let worktrees = Set(names.compactMap { name -> String? in
            let record = gitDir.appendingPathComponent("worktrees", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true).appendingPathComponent("gitdir")
            // `gitdir` names the linked worktree's own .git file.
            guard let text = try? String(contentsOf: record, encoding: .utf8) else { return nil }
            let path = URL(fileURLWithPath: text.trimmed).deletingLastPathComponent().path
            guard manager.fileExists(atPath: path) else { return nil }
            let canonical = HydraPaths.canonical(path)
            return canonical == checkout ? nil : canonical
        }).subtracting(threads.compactMap { thread in
            // Heads' own copies are linked worktrees too, never a lead's workplace.
            thread.hydra == nil ? nil : thread.worktreePath.map(HydraPaths.canonical)
        })
        guard !worktrees.isEmpty else { return nil }

        let requestTurnID = openHydraJob(of: lead.id)?.turnID ?? runtime.entries.last(where: {
            if case .user(let message) = $0.item.content { return message.hydraHeads == nil }
            return false
        })?.turnID
        guard let requestTurnID,
              let start = runtime.turns.firstIndex(where: { $0.id == requestTurnID }) else { return nil }
        let turns = runtime.turns[start...]
        let turnIDs = Set(turns.map(\.id))
        let touched = turns.flatMap { $0.touchedPaths ?? [] }.map { path in
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: checkout, isDirectory: true))
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        let commands = runtime.entries.compactMap { entry -> String? in
            guard let turnID = entry.turnID, turnIDs.contains(turnID),
                  case .tool(let call) = entry.item.content else { return nil }
            return call.title + "\n" + (call.detail ?? "")
        }
        func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        // A lead that edited the main checkout itself is working there, whatever else it read.
        guard !touched.contains(where: { path in inside(path, checkout) && !worktrees.contains { inside(path, $0) } }) else { return nil }
        let rootParts = URL(fileURLWithPath: checkout).standardizedFileURL.pathComponents
        let matches = worktrees.filter { worktree in
            if touched.contains(where: { $0 == worktree || $0.hasPrefix(worktree + "/") }) { return true }
            let parts = URL(fileURLWithPath: worktree).pathComponents
            let shared = zip(rootParts, parts).prefix(while: { $0.0 == $0.1 }).count
            let relative = (Array(repeating: "..", count: rootParts.count - shared) + parts.dropFirst(shared)).joined(separator: "/")
            return [worktree, relative].contains { path in
                // Only entering or creating the worktree counts; reading a file in it does not.
                let pattern = "(?:\\bcd\\s+|\\bgit\\s+-C\\s+|\\bworktree\\s+add\\s+(?:[^;&|\\n]*\\s)?)[\"']?"
                    + NSRegularExpression.escapedPattern(for: path) + "(?=$|[/\\s\"'`;,)|&<>])"
                return commands.contains { $0.range(of: pattern, options: .regularExpression) != nil }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
