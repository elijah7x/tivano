import AppKit
import Foundation

// With "Merge when the team is done" on, a Hydra lead's finished job lands by itself: the
// files the lead and its heads changed go out as a commit on a branch of their own, the
// branch is pushed, a merge request is opened and merged with the forge's CLI, and the
// checkout is brought up to date. The checkout never changes branch for any of it: the
// commit is built from a snapshot of the working tree, so nothing running in the checkout
// meanwhile is disturbed, and nothing uncommitted that is not the team's goes along.

/// A head whose work a merge takes, for the note the merge popover reads.
struct HydraMergeHead {
    var name: String
    var index: Int
    var task: String
    /// The head's files among the merge's, relative to the checkout.
    var files: [String]
}

/// What merging one project's share of a Hydra job came to.
private enum HydraProjectMerge {
    case merged
    case alreadyOnMain
    case failed
    /// Not now, and nothing to tell: the checkout is mid-rebase or mid-merge, or the lead
    /// took up work again while the files were gathered. The sweep picks the job up again.
    case deferred
}

extension AppModel {
    /// One project's share of a job: the paths this merge takes, the turns and heads they
    /// settle, the paths that lie under no checkout, and the heads' files.
    typealias HydraWork = (paths: [String], turnIDs: [UUID], headIDs: [UUID], outside: [String], heads: [HydraMergeHead])

    /// Whether any chat's team work is on its way to the remote right now.
    var isAnyHydraMergeRunning: Bool { liveRuntimes.contains { $0.isHydraMerging } }

    /// How long after its last message a lead is still one the auto-merge visits. It is
    /// the window `resumeHydraMerges` sweeps, and so also how long a head's claim on its
    /// files lives once the lead has gone quiet: a lead outside it never merges again,
    /// and a claim of its heads could only hold those files from every later merge.
    private static var hydraMergeWindow: TimeInterval { 3 * 24 * 3600 }

    /// Merges the last run left unfinished: a lead chat with the auto-merge on, no turn
    /// running, no head still out, and work of its own that never went out - a finished
    /// turn's files, or a head whose landing no merge has taken, which stands even when
    /// every turn reads as spent. The merge itself finds the files and lets a job that
    /// changed nothing be.
    func resumeHydraMerges() async {
        guard settings.hydraAutoMerge else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.hydraMergeWindow)
        let leads = threads.filter { !$0.isArchived && hydraIsOn($0) && $0.updatedAt > cutoff }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        // Load every competitor before choosing the first winner. A cold runtime
        // must not keep a completed job looking unfinished until the next sweep.
        for lead in leads {
            await runtime(for: lead.id).ensureLoaded()
        }
        for lead in leads {
            guard let runtime = existingRuntime(for: lead.id),
                  runtime.isReadyForHydraMerge, !runtime.isHydraMerging else { continue }
            // The job is finished, whatever its turns read: a lead whose report-review turn
            // was booked spent while its head's work never went out has no unmerged turn
            // left, and requiring one here stranded exactly that head. A head whose landing
            // no merge has taken yet is work of its own, and the test below counts it.
            let finished = runtime.hydraUnmergedTurns.filter { $0.status == .completed }
            // A chat with nothing of its own to show never merges: Hydra merely being
            // switched on is not work, and the checkout sweep would otherwise take whatever
            // else in that checkout had changed, another chat's files or the user's own.
            let hasOwnWork = finished.contains { !($0.touchedPaths ?? []).isEmpty }
                || hydraTeam(of: lead.id).contains { $0.hydra.map { $0.mergedAt == nil && ($0.landing?.landed ?? false) } ?? false }
            guard hasOwnWork else { continue }
            await autoMergeHydraWork(of: lead.id)
        }
    }

    /// Lands a lead's finished work, when the setting says so. Runs once per finished job;
    /// what happened lands in the lead's timeline as a note from Hydra.
    func autoMergeHydraWork(of leadID: UUID) async {
        guard settings.hydraAutoMerge, let waiting = thread(leadID), hydraIsOn(waiting),
              let queued = existingRuntime(for: leadID), !queued.isHydraMerging, !queued.isHydraMergeQueued,
              queued.isReadyForHydraMerge else { return }
        // One merge goes out at a time: several jobs finishing in the same moment would
        // otherwise snapshot shared files side by side. A job that finishes while another
        // merges waits its turn right here and goes the moment that one is done. It used
        // to step aside for the sweep five minutes later, and a chat that was plainly
        // finished sat there unmerged.
        if isAnyHydraMergeRunning {
            queued.isHydraMergeQueued = true
            defer { queued.isHydraMergeQueued = false }
            while isAnyHydraMergeRunning {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
        }
        // Everything is read again after the wait, and the flag below is set with no
        // suspension after this guard, so of several waiters exactly one goes.
        guard settings.hydraAutoMerge, let lead = thread(leadID), hydraIsOn(lead), let project = project(lead.projectID),
              let runtime = existingRuntime(for: leadID), !runtime.isHydraMerging, !isAnyHydraMergeRunning,
              runtime.isReadyForHydraMerge else { return }
        runtime.isHydraMerging = true
        runtime.hydraMergeStartedAt = .now
        runtime.hydraMergeNoteID = UUID().uuidString
        runtime.hydraMergeStage = HydraMergeStage.gathering.words
        runtime.hydraMergeStep = .gathering
        defer {
            runtime.isHydraMerging = false
            runtime.hydraMergeStage = nil
            runtime.hydraMergeStep = nil
            runtime.hydraMergeStartedAt = nil
            runtime.hydraMergeNoteID = nil
        }
        // A head's work still going into the checkout finishes first: the snapshot the
        // commit is built from must hold the patch whole or not at all. Landings that have
        // not started yet wait for the merge instead (see `waitForSettledCheckout`).
        await runtime.hydraLanding?.value
        guard runtime.isReadyForHydraMerge else { return }

        // What the team touched, and only that, so a sibling's uncommitted work in the
        // same checkout stays behind. The chat's own checkout goes first, then every
        // other sidebar project that holds touched files, one merge each; only paths
        // under no sidebar project at all stay out. What the records do not hold in one
        // of those other checkouts cannot be told apart from a sibling's work there and
        // stays behind without a word: none of it was this merge's to take.
        let ownCheckout = lead.worktreePath ?? project.path
        let own = await hydraWork(of: leadID, runtime: runtime, checkout: ownCheckout, git: Git(ownCheckout), projectID: project.id, leadCheckout: ownCheckout, leadProjectID: project.id, sweepsCheckout: true)
        var groups: [(project: Project, checkout: String, work: HydraWork)] = [(project, ownCheckout, own)]
        // An outside path belongs to the sidebar project with the longest path that
        // holds it, so nested checkouts resolve to the inner one.
        var owners: [String: Project] = [:]
        for path in own.outside {
            if let holder = projects.filter({ $0.id != project.id && TouchedPaths.relative(path, root: $0.path) != nil }).max(by: { $0.path.count < $1.path.count }) {
                owners[path] = holder
            }
        }
        for other in projects where other.id != project.id && owners.values.contains(where: { $0.id == other.id }) {
            let work = await hydraWork(of: leadID, runtime: runtime, checkout: other.path, git: Git(other.path), projectID: other.id, leadCheckout: ownCheckout, leadProjectID: project.id, sweepsCheckout: false)
            groups.append((other, other.path, work))
        }
        // A head's scratch (a throwaway script in /tmp, a stray write into its own copy)
        // is nobody's project and not worth a word; only a real folder outside the
        // sidebar is something the user can act on.
        let stray = own.outside.filter { path in !Self.isScratchPath(path) && !projects.contains { TouchedPaths.relative(path, root: $0.path) != nil } }
        func strayBody(_ paths: [String]) -> String {
            let shown = paths.prefix(6).map { "`\($0)`" }.joined(separator: ", ") + (paths.count > 6 ? " and \(paths.count - 6) more" : "")
            return "\(paths.count == 1 ? "1 file was" : "\(paths.count) files were") changed outside every project: \(shown). Add the folder that holds them to the sidebar and ask for the merge again."
        }
        groups.removeAll { $0.work.paths.isEmpty }
        guard !groups.isEmpty else {
            guard !stray.isEmpty else {
                // Nothing to send and nothing outside a project: whatever the turns
                // recorded is already on the branch, ignored, build output, or gone. Mark
                // it spent, or the merge note counts those files forever.
                runtime.markHydraMerged(own.turnIDs)
                let spentAt = Date.now
                for headID in own.headIDs { updateHydraHead(headID) { $0.mergedAt = spentAt } }
                if runtime.hydraMerges.last?.outcome == .held {
                    recordHydraSettlement(leadID: leadID, runtime: runtime)
                }
                return
            }
            runtime.recordHydraMerge(HydraMergeRecord(at: .now, outcome: .stray, project: nil, label: nil, url: nil, files: stray.count, detail: strayBody(stray)))
            note(leadID, "Hydra did not merge: the team's files are outside every project.", strayBody(stray))
            return
        }
        let several = groups.count > 1
        var outcomes: [HydraProjectMerge] = []
        for group in groups {
            outcomes.append(await mergeHydraProject(of: leadID, lead: lead, project: group.project, checkout: group.checkout, work: group.work, runtime: runtime, several: several))
        }
        guard !outcomes.contains(.failed), !outcomes.contains(.deferred) else { return }
        // Another job that waited on this one, or was put off by it, goes now rather than
        // at the next sweep. Scheduled, so it starts once this merge has let go.
        Task { [weak self] in await self?.resumeHydraMerges() }
        // The work is on the default branch now, so these turns are spent: the next
        // job merges what comes after them and never this again.
        runtime.markHydraMerged(groups.flatMap { $0.work.turnIDs })
        let mergedAt = Date.now
        for headID in groups.flatMap({ $0.work.headIDs }) { updateHydraHead(headID) { $0.mergedAt = mergedAt } }
        // The projects' shares went out; only what no project holds stayed behind.
        if !stray.isEmpty {
            runtime.recordHydraMerge(HydraMergeRecord(at: .now, outcome: .stray, project: nil, label: nil, url: nil, files: stray.count, detail: strayBody(stray)))
            note(leadID, "Hydra left \(stray.count == 1 ? "a file" : "\(stray.count) files") outside every project.", strayBody(stray))
        } else if outcomes.allSatisfy({ $0 == .alreadyOnMain }) {
            recordHydraSettlement(leadID: leadID, runtime: runtime)
        }
    }

    /// A path no sidebar project could ever hold: a head's copy of a checkout under the
    /// worktrees folder, the temporary folders a head drops a throwaway script into,
    /// `~/Library`, and the dot-folders under home where agents keep their own state
    /// (`~/.claude`, `~/.codex`, `~/.tivano`): a lead writing its memory files
    /// is not leaving work behind.
    private static func isScratchPath(_ path: String) -> Bool {
        let full = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        let home = (LoginEnvironment.homeDirectory as NSString).standardizingPath
        var roots = [Storage.worktreesDirectory.path, NSTemporaryDirectory(), "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        roots.append((home as NSString).appendingPathComponent("Library"))
        let underHome = home.hasSuffix("/") ? home : home + "/"
        if full.hasPrefix(underHome), full.dropFirst(underHome.count).first == "." { return true }
        // `standardizingPath` drops a leading `/private` only while the file still exists,
        // so a head's temp file deleted since it was written keeps its `/private/tmp`
        // form while the roots lose theirs: both spellings are tried.
        let spellings = full.hasPrefix("/private/") ? [full, String(full.dropFirst("/private".count))] : [full]
        return roots.contains { root in
            let root = (root as NSString).standardizingPath
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return spellings.contains { $0.hasPrefix(prefix) }
        }
    }

    /// Merges one project's share of a lead's finished work from its checkout: the guards
    /// for repository, remote and operation in progress; the conflict-marker check; the
    /// commit, branch, push, merge request and notes. The caller groups the projects and
    /// marks the turns and heads merged once every project went through.
    ///
    /// It says something only when the user has to act (a sign-in, conflict markers, a
    /// real conflict with the remote). Everything that clears by itself - a checkout mid-
    /// rebase, a commit landing while the work was prepared, a forge still checking the
    /// request - is retried quietly instead of posted.
    private func mergeHydraProject(of leadID: UUID, lead: ChatThread, project: Project, checkout: String, work: HydraWork, runtime: ThreadRuntime, several: Bool) async -> HydraProjectMerge {
        func stage(_ name: String) -> String { several ? "\(project.name): \(name)" : name }
        func title(_ name: String) -> String { several ? "\(project.name): \(name)" : name }
        // The words carry the project's name with several projects, the step is the dot on the pill's track.
        func advance(_ step: HydraMergeStage) { runtime.hydraMergeStage = stage(step.words); runtime.hydraMergeStep = step }
        func fail(_ headline: String, _ body: String, label: String? = nil, url: URL? = nil, retryable: Bool = false) -> HydraProjectMerge {
            let detail = title(headline) + ": " + body
            if retryable { scheduleHydraMergeRetry(of: leadID) }
            // The same failure again (the sweep retries every job it can) is not news.
            if let last = runtime.hydraMerges.last, last.outcome == .failed, last.detail == detail { return .failed }
            // A failure that clears by itself is said once it has kept failing, never on
            // the first try: the retry a minute from now normally just lands.
            let saysIt = !retryable || runtime.hydraMerges.suffix(2).filter { $0.outcome == .failed && $0.retryable == true }.count >= 2
            runtime.recordHydraMerge(HydraMergeRecord(at: .now, outcome: .failed, project: project.name, label: label, url: url, files: 0, detail: detail, retryable: retryable ? true : nil))
            if saysIt { note(leadID, title(headline), body) }
            return .failed
        }

        let git = Git(checkout)
        guard await git.isRepository(), await git.hasCommits() else { return .failed }
        // Linked worktrees share refs. Serialize automatic merges across editions
        // using the common git directory, not a per-process queue or checkout path.
        guard let common = try? await git.output(["rev-parse", "--path-format=absolute", "--git-common-dir"]),
              let repoLease = try? SharedLibraryLease(at: SharedResourceLock.url(resource: URL(fileURLWithPath: common.trimmed).resolvingSymlinksInPath().path)) else {
            scheduleHydraMergeRetry(of: leadID)
            return .deferred
        }
        defer { withExtendedLifetime(repoLease) {} }
        guard await git.remoteURL() != nil else {
            return fail("Hydra did not merge: no remote.", "The team's work is in the checkout; there is no origin to push it to.")
        }
        // Someone is rebasing or merging in this checkout: the work waits for them, quietly,
        // and looks again in a minute.
        guard !(await git.hasOperationInProgress()) else {
            scheduleHydraMergeRetry(of: leadID)
            return .deferred
        }

        let sorted = work.paths
        // A head's landing can leave conflict markers behind (see `Git.apply`), and a lead
        // told not to look at git status may answer without settling them. Those markers
        // must never reach the remote: the job stays in the checkout until they are gone.
        let conflicted = await Self.pathsWithConflictMarkers(sorted, in: checkout)
        guard conflicted.isEmpty else {
            let files = conflicted.map { "`\($0)`" }.joined(separator: ", ")
            let headline = "Hydra did not merge: conflict markers in \(conflicted.count == 1 ? "a file" : "\(conflicted.count) files")."
            return fail(headline, "\(files) still \(conflicted.count == 1 ? "holds" : "hold") conflict markers from a head's landing. Resolve them and the merge goes out by itself.")
        }

        do {
            let status = await git.status()
            let target = await git.defaultBranch()
            let current = status?.branch
            // A spent branch is treated like the default branch: the job gets its own
            // branch on the remote, never on history the remote squashed away.
            let spent: Bool
            if let current, current != target {
                _ = try? await git.fetch()
                spent = await branchIsSpent(git, branch: current, target: target)
            } else {
                spent = false
            }
            let ownBranch = current == nil || current == target || spent
            let branch = ownBranch ? Self.hydraBranchName(for: lead) : current!

            // A commit landing while the work is prepared (the user's, in a terminal) moves
            // HEAD under it. That is no reason to stop: the work is prepared again on top.
            var prepared: (head: String, commit: String, message: String, files: [DiffFile], merged: [String: Data])?
            // The text engine writes the message from the patch; a retry with the same
            // patch reuses it rather than asking again.
            var described: (patch: String, message: String)?
            for _ in 0..<3 {
                let head = try await git.commitHash()
                advance(.committing)
                // On the default branch the work is built on the remote as it is now, so a
                // checkout that fell behind never sends a request that conflicts on the forge.
                var parent = head
                var tree: String?
                var merged: [String: Data] = [:]
                if ownBranch, (try? await git.fetch()) != nil,
                   let remote = try? await git.commitHash(of: "origin/\(target)"), remote != head,
                   (spent ? true : await git.isAncestor(head, of: remote)) {
                    guard let rebased = try await git.captureTree(paths: sorted, onto: remote, from: head) else {
                        let files = sorted.count == 1 ? "a file" : "files"
                        return fail("Hydra did not merge: `\(target)` changed the same lines.", "The remote changed \(files) the team changed too, in the same places. The work is in the checkout: bring `\(target)` in (`git pull`), settle the overlap, and the merge goes out by itself.")
                    }
                    parent = remote
                    tree = rebased.tree
                    merged = rebased.merged
                }
                let captured: String
                if let tree {
                    captured = tree
                } else {
                    captured = try await git.captureTree(paths: sorted)
                }
                // A lead can resume while gathering or capturing files: it has work under
                // way again, and this job goes out with it once it finishes.
                guard runtime.isReadyForHydraMerge else { return .deferred }
                // Everything the team did is committed already: taken along by another chat's
                // merge from the same checkout, or committed by hand. The job is spent either
                // way, and there is nothing to tell: the work is where it was meant to go.
                if try await captured == git.treeHash(of: parent) {
                    // A retry after a failed merge request sends the branch again; the
                    // job's commit being on the branch does not mean it is on main.
                    if !ownBranch,
                       (try? await git.commitHash(of: "refs/tivano/sent/\(branch)")) == head,
                       (try? await git.commitHash(of: "refs/tivano/merged/\(branch)")) != head {
                        let base = await git.mergeBase(head, "origin/\(target)") ?? parent
                        let patch = (try? await git.diff(from: base, to: head)) ?? ""
                        let files = await Task.detached(priority: .utility) { DiffParser.parse(patch) }.value
                        prepared = (head, head, try await git.message(of: head), files, [:])
                        break
                    }
                    return .alreadyOnMain
                }

                let patch = (try? await git.diff(from: parent, to: captured)) ?? ""
                // A whole job's patch is big and parsing it counts every line: off the main
                // actor, so the chat stays live while the work goes out.
                let files = await Task.detached(priority: .utility) { DiffParser.parse(patch) }.value
                advance(.describing)
                let message: String
                if let described, described.patch == patch {
                    message = described.message
                } else {
                    message = await commitMessage(for: lead, files: files, patch: patch, directory: checkout)
                    described = (patch, message)
                }
                let commit = try await git.commitWork(captured, parent: parent, message: message)
                // Writing the branch to a commit prepared from `head` drops anything committed
                // since: HEAD is read again, and a checkout that moved is prepared again.
                guard try await git.commitHash() == head else { continue }
                prepared = (head, commit, message, files, merged)
                break
            }
            guard let prepared else {
                return fail("Hydra did not merge: the checkout kept moving.", "Commits kept landing on `\(current ?? target)` while the team's work was prepared. The work is in the checkout and goes out on the next try.", retryable: true)
            }
            let head = prepared.head
            let files = prepared.files
            let subject = TextCleanup.singleLine(prepared.message, limit: 72)

            if ownBranch {
                // The job's own branch: one per chat, rebuilt on each try, so a retry updates
                // the request it opened instead of opening another.
                try await git.updateRef("refs/heads/\(branch)", to: prepared.commit)
            } else if prepared.commit != head {
                // The checkout's own branch must still be where it was read.
                try await git.updateRef("refs/heads/\(branch)", to: prepared.commit, expecting: head)
                // The branch moved under the checkout: the index catches up, the working
                // tree already has the content.
                try await git.resetIndex(paths: sorted)
                try await git.updateRef("refs/tivano/sent/\(branch)", to: prepared.commit)
            }
            advance(.pushing)
            try await git.pushBranch(branch, force: ownBranch)

            let body = mergeRequestBody(for: lead, files: files, through: Set(work.turnIDs), runtime: runtime)
            advance(.opening)
            let requestURL: URL?
            do {
                requestURL = try await hydraCreateMergeRequest(git: git, title: subject, body: body, source: branch, target: target)
            } catch let error as HydraMergeRequestError {
                if case .gitLabAuth = error {
                    return fail("Hydra pushed \(branch) but could not open a merge request.", error.localizedDescription)
                }
                return fail("Hydra pushed \(branch) but could not open a merge request.", "\(error.localizedDescription)\n\nThe work is in the checkout and on `\(branch)`; the next try opens the request.", retryable: true)
            } catch {
                return fail("Hydra pushed \(branch) but could not open a merge request.", "\(error.localizedDescription)\n\nThe work is in the checkout and on `\(branch)`; the next try opens the request.", retryable: true)
            }
            guard let url = requestURL,
                  let link = MergeRequestLink(url: url) else {
                return fail("Hydra pushed \(branch) but could not open a merge request.", "The forge did not say where the request is. The next try opens it again.", retryable: true)
            }
            advance(.merging)
            do {
                try await git.mergePullRequest(link)
            } catch {
                return fail("Hydra opened \(link.label) but could not merge it.", "\(url.absoluteString)\n\n\(error.localizedDescription)\n\nThe next try brings the request up to date with `\(target)` and merges it.", label: link.label, url: url, retryable: true)
            }

            if !ownBranch {
                try? await git.updateRef("refs/tivano/merged/\(branch)", to: prepared.commit)
            }

            var lines = ["\(url.absoluteString)", "", Self.filesLine(files) + " landed on `\(target)` from `\(branch)`."]
            if !work.heads.isEmpty {
                lines.append("")
                lines.append("Heads")
                for head in work.heads {
                    if head.files.isEmpty {
                        lines.append("- \(head.name) (\(head.index)): \(head.task) — no files")
                    } else {
                        lines.append("- \(head.name) (\(head.index)): \(head.task) — \(head.files.count == 1 ? "1 file" : "\(head.files.count) files"): \(head.files.joined(separator: ", "))")
                    }
                }
            }
            // What the merge left out (files written outside the checkout, build output,
            // ignored or missing paths, a sibling chat's files) is not said: none of it
            // was this merge's to take, and every line about it read as if something
            // had gone wrong.
            if ownBranch {
                advance(.syncing)
                let synced = await syncDefaultBranch(git, from: head, target: target, ownPaths: sorted, merged: prepared.merged, headIsMerged: spent)
                lines.append(synced ? "The checkout is up to date." : "The checkout was left as it was: `\(target)` moved on in other ways meanwhile, or the team's files changed again; `git pull` when it suits you.")
            } else if lead.worktreePath == nil {
                // The forge squashed the checkout's own branch: it follows the remote, or the
                // next job would be built on history the remote no longer has and conflict.
                advance(.syncing)
                let synced = await syncDefaultBranch(git, from: prepared.commit, target: target, ownPaths: [], merged: [:], headIsMerged: true)
                lines.append(synced ? "The checkout is up to date." : "The checkout was left as it was: `\(target)` moved on in other ways meanwhile, or the team's files changed again; `git pull` when it suits you.")
            } else {
                // The lead worked in a worktree: the project's own checkout follows when it can.
                advance(.syncing)
                let main = Git(project.path)
                if await main.status()?.branch == target, await main.dirtyPaths().isEmpty, !(await main.hasOperationInProgress()) {
                    if (try? await main.pullFastForward()) != nil { lines.append("The project checkout is up to date.") }
                }
            }
            runtime.recordHydraMerge(HydraMergeRecord(at: .now, outcome: .merged, project: project.name, label: link.label, url: url, files: files.count, detail: nil))
            note(leadID, title("Hydra merged \(link.label)"), lines.joined(separator: "\n"))
            existingRuntime(for: leadID)?.noteDiffChanged()
            return .merged
        } catch {
            return fail("Hydra could not merge the team's work.", "\(error.localizedDescription)\n\nThe work is in the checkout; the next try sends it again.", retryable: true)
        }
    }

    /// A retry a minute after a failure that clears by itself, rather than at the sweep
    /// five minutes on: the forge finishing its checks, a remote that moved, a push that
    /// timed out. One is pending per chat at a time.
    private func scheduleHydraMergeRetry(of leadID: UUID) {
        guard let runtime = existingRuntime(for: leadID), !runtime.hasHydraMergeRetryPending else { return }
        runtime.hasHydraMergeRetryPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self else { return }
            self.existingRuntime(for: leadID)?.hasHydraMergeRetryPending = false
            await self.autoMergeHydraWork(of: leadID)
        }
    }

    /// Opens the merge request for a Hydra branch. On GitLab this wraps `glab mr create`
    /// rather than calling `Git.createPullRequest` straight: glab answers a missing or
    /// expired token with `401 Unauthorized` next to a recovery file, which used to land in
    /// the timeline as-is. The token is checked with `glab auth status` first, a 401
    /// re-checks it (it may have been refreshed while the push ran) and otherwise tells
    /// the user how to sign in again, and any other failure that left a recovery file is
    /// retried once with `--recover` so its saved options are picked up. Squash and
    /// source-branch removal are explicit for GitLab team merges.
    private func hydraCreateMergeRequest(git: Git, title: String, body: String, source: String, target: String) async throws -> URL? {
        guard await git.forge() == .gitlab, LoginEnvironment.which("glab") != nil else {
            return try await git.createPullRequest(title: title, body: body, source: source, target: target)
        }
        let host = await git.remoteWebURL()?.host ?? "your GitLab host"
        // An explicit project keeps glab from resolving the wrong one; it names the same
        // origin remote glab would use on its own. Any credentials embedded in the remote
        // stay out of the arguments.
        var arguments = ["mr", "create", "--title", title, "--description", body, "--yes", "--squash-before-merge"]
        if var web = await git.remoteWebURL(), web.host != nil {
            if web.user != nil, var components = URLComponents(url: web, resolvingAgainstBaseURL: false) {
                components.user = nil
                components.password = nil
                if let stripped = components.url { web = stripped }
            }
            arguments += ["--repo", web.absoluteString]
        }
        arguments += ["--source-branch", source, "--target-branch", target]

        // No token on file means `mr create` can only fail with a 401: say how to sign in
        // instead of running into it.
        if let detail = await hydraGitLabAuthFailure(in: git.directory) {
            throw HydraMergeRequestError.gitLabAuth(host: host, branch: source, detail: detail)
        }

        var failure = try await Shell.run(tool: "glab", arguments, in: git.directory, timeout: 300)
        if failure.succeeded { return Self.hydraMergeRequestURL(from: failure) }
        // The chat's branch already has an open request from an earlier try: the push just
        // brought it up to date, so that request is the one to merge.
        if let existing = Git.existingRequestURL(in: failure, web: await git.remoteWebURL()) { return existing }
        if Self.isGitLabAuthFailure(failure) {
            // The token may have been refreshed while the push ran: check again before
            // giving up, and retry with the explicit options when it is good now.
            if await hydraGitLabAuthFailure(in: git.directory) == nil {
                let retry = try await Shell.run(tool: "glab", arguments, in: git.directory, timeout: 300)
                if retry.succeeded { return Self.hydraMergeRequestURL(from: retry) }
                failure = retry
            }
            if Self.isGitLabAuthFailure(failure) {
                throw HydraMergeRequestError.gitLabAuth(host: host, branch: source, detail: failure.failureMessage)
            }
        }
        // A failure that saved its options is retried once with `--recover`, which loads
        // them back from the recovery file.
        if Self.mentionsRecoverFile(failure) {
            let retry = try await Shell.run(tool: "glab", arguments + ["--recover"], in: git.directory, timeout: 300)
            if retry.succeeded { return Self.hydraMergeRequestURL(from: retry) }
            failure = retry
        }
        throw HydraMergeRequestError.creationFailed(failure.failureMessage)
    }

    /// The reason `glab auth status` gives for not being signed in, or nil when the token
    /// is good. Runs in the checkout so glab checks the host the merge goes to.
    private func hydraGitLabAuthFailure(in directory: URL) async -> String? {
        // A throw means glab itself could not run here; let the creation attempt surface
        // that. A non-zero exit is glab reporting it is not signed in.
        guard let status = try? await Shell.run(tool: "glab", ["auth", "status"], in: directory, timeout: 30) else { return nil }
        if status.succeeded { return nil }
        let message = status.failureMessage
        return message.isEmpty ? "glab is not signed in to this GitLab host." : message
    }

    /// Whether glab's output is an authentication refusal: the 401 the merge used to fail with.
    private static func isGitLabAuthFailure(_ result: ShellResult) -> Bool {
        let text = (result.output + "\n" + result.errorOutput).lowercased()
        return text.contains("401") || text.contains("unauthorized")
            || (text.contains("authentication") && (text.contains("failed") || text.contains("expired") || text.contains("invalid") || text.contains("required")))
    }

    /// Whether glab's output points at a recovery file its failed creation left behind.
    private static func mentionsRecoverFile(_ result: ShellResult) -> Bool {
        (result.output + "\n" + result.errorOutput).lowercased().contains("recover")
    }

    /// The merge request's page in glab's output, parsed the same way `Git` does.
    private static func hydraMergeRequestURL(from result: ShellResult) -> URL? {
        let text = result.output + "\n" + result.errorOutput
        let match = text.firstMatch(of: #/https://\S+/#)
        return match.flatMap { URL(string: String($0.output)) }
    }

    /// The files a lead's job changed, gathered three ways because no one way sees them
    /// all:
    ///
    /// - the turns of this job, meaning the ones no merge has taken yet, and the paths
    ///   they reported;
    /// - the heads that worked alongside those turns: what a Tivano-run head landed, and,
    ///   for a head the provider runs inside the lead's own session, the edits its own
    ///   timeline reported. A native head works in this very checkout and lands nothing,
    ///   so without its timeline its files are simply missing and the branch goes out
    ///   half-written;
    /// - and, where the first of those turns left a checkpoint, whatever else the checkout
    ///   holds that it did not then, less whatever was already uncommitted at the time.
    ///   That catches the edits no tool reported, a head writing through a shell say, and
    ///   costs nothing for a file whose content matches HEAD anyway.
    ///
    /// Paths outside the checkout are dropped rather than passed on: a lead writes to its
    /// own memory files, and `git add -A -- <path>` on one of those fails outright and
    /// takes the whole merge with it.
    private func hydraWork(of leadID: UUID, runtime: ThreadRuntime, checkout: String, git: Git, projectID: UUID, leadCheckout: String, leadProjectID: UUID, sweepsCheckout: Bool) async -> HydraWork {
        let turns = runtime.hydraUnmergedTurns
        var reported: [String] = turns.flatMap { $0.touchedPaths ?? [] }
        // What this job's own tools and landings wrote, as opposed to what its turns saw
        // change on disk: a file another chat also claims goes out here only when this
        // job edited it itself.
        var edited: [String] = []
        // A head counts until a merge has taken its work (see `HydraHeadInfo.mergedAt`),
        // and only that explicit mark proves a merge took it: a lead turn's `hydraMerged`
        // flag is bookkeeping, and a turn falsely booked spent would let a timestamp
        // shortcut discard a head whose files were still in the checkout. A head from
        // before the mark existed that already went out settles below instead, where the
        // gathering finds its paths unchanged from HEAD.
        var headPaths: [(id: UUID, name: String, index: Int, task: String, paths: [String])] = []
        var copyPaths = Set<String>()
        for head in hydraTeam(of: leadID) {
            guard let info = head.hydra, info.mergedAt == nil,
                  info.landing?.patchPath == nil, info.landing?.error == nil else { continue }
            // The checkout the head's work landed in: the chat's own for a head in its
            // project, that project's for a head sent elsewhere. A path the head's tools
            // reported lies in its own copy of that checkout and stands for the same path
            // there; a landing path is relative to it already. Anchored at that checkout,
            // a path resolves against this pass's checkout or counts as outside it, so a
            // head's work in another project reaches that project's merge instead of
            // reading as this project's, and its copy never shows up as a stray folder.
            let headRoot = head.projectID == leadProjectID ? leadCheckout : (project(head.projectID)?.path ?? leadCheckout)
            func anchored(_ path: String) -> String {
                let trimmed = path.trimmed
                guard !trimmed.isEmpty else { return "" }
                if let copy = head.worktreePath, let inCopy = TouchedPaths.relative(trimmed, root: copy) {
                    return (headRoot as NSString).appendingPathComponent(inCopy)
                }
                if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.contains("://") { return trimmed }
                return (headRoot as NSString).appendingPathComponent(trimmed)
            }
            var own: [String] = []
            var seen = Set<String>()
            func collect(_ path: String) {
                guard !path.isEmpty, let relative = TouchedPaths.relative(anchored(path), root: checkout), seen.insert(relative).inserted else { return }
                own.append(relative)
            }
            for file in info.landing?.files ?? [] { collect(file.path) }
            reported += (info.landing?.files ?? []).map { anchored($0.path) }
            edited += (info.landing?.files ?? []).map { anchored($0.path) }
            // A head's timeline runs to megabytes. One still open is read as it is; one
            // that has gone cold is decoded off the main actor rather than brought back
            // as a runtime, which would parse the whole history on the main thread for
            // every head of the team, one after another, while the chat sits frozen.
            let items: [TimelineItem]
            if let live = existingRuntime(for: head.id) {
                items = live.entries.map(\.item)
            } else {
                let headID = head.id
                items = await Task.detached(priority: .utility) { Storage.decodeDocument(headID)?.items ?? [] }.value
            }
            for item in items {
                guard case .tool(let call) = item.content else { continue }
                reported += call.edits.map { anchored($0.path) }
                edited += call.edits.map { anchored($0.path) }
                for edit in call.edits { collect(edit.path) }
            }
            if head.worktreePath != nil { copyPaths.formUnion(own) }
            headPaths.append((head.id, HydraRoster.persona(at: info.index).name, info.index, TextCleanup.singleLine(info.task, limit: 120), own))
        }

        // The lead's own tool edits, from its timeline: a lead works in any sidebar project
        // too, and a path it wrote outside its checkout is that project's share of the merge.
        // Its turns' `touchedPaths` hold only what lies inside the checkout.
        let unmerged = Set(turns.map(\.id))
        for entry in runtime.entries where entry.item.turnID.map(unmerged.contains) == true {
            guard case .tool(let call) = entry.item.content else { continue }
            for edit in call.edits {
                let trimmed = edit.path.trimmed
                guard !trimmed.isEmpty else { continue }
                let path = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.contains("://")
                    ? trimmed
                    : (leadCheckout as NSString).appendingPathComponent(trimmed)
                reported.append(path)
                edited.append(path)
            }
        }

        var paths = Set<String>()
        var outside = Set<String>()
        for path in reported where !path.isEmpty && !TouchedPaths.isBuildOutput(path) {
            if let relative = TouchedPaths.relative(path, root: checkout) {
                paths.insert(relative)
            } else {
                outside.insert(path)
            }
        }

        // Files another chat's team put in this same checkout that no merge has taken
        // yet: that chat's merge carries them, never this one's. Without this, the
        // sweep below took a sibling's landed files along, and the sibling's own merge
        // then found nothing left and said nothing.
        //
        // Two sets come back. Every reservation keeps the sweep off a sibling's file this
        // merge has no record of. The blocking claims are the reservations that also hold
        // this job: a file only a finished, idle sibling job ranks behind this one owns is
        // settled by the ordering instead, and this job's own record of it may go out (see
        // `siblingOwnedPaths`).
        let siblingFiles = siblingOwnedPaths(in: checkout, projectID: projectID, excluding: leadID)
        let siblingClaims = Set(siblingFiles.reserved.keys)
        let blockingClaims = siblingFiles.blocking
        if sweepsCheckout,
           let base = turns.first?.baseCheckpoint,
           let alreadyDirty = try? await git.changedPaths(from: "HEAD", to: base),
           let now = try? await git.captureTree(),
           let changedSince = try? await git.changedPaths(from: base, to: now) {
            let theirs = Set(alreadyDirty)
            let fresh = changedSince.filter { !theirs.contains($0) }
            paths.formUnion(fresh.filter { !siblingClaims.contains($0) })
        }

        // Nothing waits on another chat. A file another chat also claims goes out with
        // this job when this job's own tools or heads wrote it: whole, the way the
        // checkout has it, and that chat's merge later finds it on the branch already.
        // One this job only saw change on disk while its turn ran (a turn's touched paths
        // are read off the checkout's diff) is the other chat's work, and goes out with
        // that chat's merge instead. This used to hold the whole job with a note that it
        // was waiting for another chat, and a finished chat could sit unmerged for good.
        let ownEdits = Set(edited.compactMap { TouchedPaths.relative($0, root: checkout) })
        paths.subtract(Set(blockingClaims.keys).subtracting(ownEdits))
        // Old rows can carry a sibling's write; a head's own copy remains its own evidence.
        paths.subtract(CheckoutClaims.foreign(paths.subtracting(copyPaths), root: checkout, owner: leadID, since: .distantPast))
        paths = paths.filter { !TouchedPaths.isBuildOutput($0) }
        paths.subtract(await git.ignoredPaths(among: paths.sorted()))
        let tracked = await git.trackedPaths(among: paths.sorted())
        let fileManager = FileManager.default
        let checkoutURL = URL(fileURLWithPath: checkout)
        let missing = Set(paths.filter { path in
            !fileManager.fileExists(atPath: checkoutURL.appendingPathComponent(path).path) && !tracked.contains(path)
        })
        paths.subtract(missing)
        let heads = headPaths.map { entry in
            HydraMergeHead(name: entry.name, index: entry.index, task: entry.task, files: entry.paths.filter { paths.contains($0) })
        }
        // What this merge settles: every turn and head of the job. A file left to another
        // chat goes out with that chat's merge, not this one's.
        return (paths.sorted(), turns.map(\.id), headPaths.map(\.id), outside.sorted(), heads)
    }

    /// Files another chat's team put or is still putting in this same checkout that no
    /// merge has taken yet, each mapped to the chat that holds it, split in two: every
    /// reservation, and the claims that hold this job outright. That chat's own merge
    /// carries them, never this one's, so the checkout sweep in `hydraWork` keeps every
    /// reservation out of a merge the same way.
    ///
    /// A claim holds - `blocking` - unless it is a file only a finished, idle, eligible
    /// competing job ranks behind this one owns (`hydraIsFinishedIdleEligible`,
    /// `hydraRanksAfter`): two finished jobs that recorded the same files used to hold
    /// each other for good, and nothing said so. One ordering by lead UUID settles which
    /// of them takes a contested file, so the earliest job keeps priority and every job
    /// reads the same order. Active work, a job that has not completed after an
    /// interruption, a failed head's partial work, and a pending landing keep their hold.
    ///
    /// A claim stands only while the chat that made it can still land its work
    /// (`canStillMerge`). A head left unmarked by an older merge - its lead merged again
    /// since, or the job is long over - used to go on claiming its files forever, and
    /// every chat that later touched one of them went out empty, without a word.
    private func siblingOwnedPaths(in checkout: String, projectID: UUID, excluding leadID: UUID) -> (reserved: [String: String], blocking: [String: String]) {
        let team = Set(hydraTeam(of: leadID).map(\.id))
        var reserved: [String: String] = [:]
        var blocking: [String: String] = [:]
        func reserve(_ path: String, owner: String, blocks: Bool) {
            guard let relative = TouchedPaths.relative(path, root: checkout) else { return }
            reserved[relative] = owner
            if blocks { blocking[relative] = owner }
        }
        for other in threads where other.id != leadID && other.projectID == projectID && !team.contains(other.id) {
            if other.isHydraHead {
                guard let info = other.hydra, info.mergedAt == nil else { continue }
                // A head still out has files coming whatever its lead is doing; a head
                // that has finished holds them only for a lead that can still land them.
                let parent = other.parentThreadID.flatMap { thread($0) }
                guard info.status == .running || parent.map(canStillMerge) == true else { continue }
                // A running head is active work and a stopped or failed one left partial
                // work behind: both hold whatever their lead is doing. Only a completed
                // head whose lead is a finished, idle, eligible competitor ranking behind
                // this job loses its hold to the ordering.
                let rankedOut = info.status == .completed
                    && parent.map { hydraRanksAfter($0, leadID) && hydraIsFinishedIdleEligible($0) } == true
                for file in info.landing?.files ?? [] {
                    reserve(file.path, owner: parent?.title ?? other.title, blocks: !rankedOut)
                }
            } else if let live = existingRuntime(for: other.id) {
                // A later completed turn finishes the resumed job, including its
                // earlier interrupted edits. Without one, readiness remains false
                // and those partial edits keep their hold.
                let rankedOut = hydraRanksAfter(other, leadID) && hydraIsFinishedIdleEligible(other)
                for turn in live.hydraUnmergedTurns where canStillMerge(other) || turn.status != .completed {
                    for path in turn.touchedPaths ?? [] {
                        reserve(path, owner: other.title, blocks: !rankedOut)
                    }
                }
            }
        }
        return (reserved, blocking)
    }

    /// Whether a lead is a finished job that can still land its own work and so takes part
    /// in the ordering between competing jobs: idle and not merging, every head in, no
    /// landing still being written, its last turn completed, and unmerged work that the
    /// resume sweep can still pick up. A stopped or failed head whose work was kept as a
    /// patch keeps the whole job out, so its partial files stay protected.
    private func hydraIsFinishedIdleEligible(_ lead: ChatThread) -> Bool {
        guard hydraIsOn(lead), let live = existingRuntime(for: lead.id) else { return false }
        guard live.isReadyForHydraMerge, !live.isHydraMerging,
              !hydraHasPendingLanding(lead.id) else { return false }
        return canStillMerge(lead)
    }

    /// Whether a head's work is still on its way into the checkout: files that have not
    /// gone in cleanly, which is how a stopped or failed head keeps its partial work as a
    /// patch. A head that changed nothing carries no files and no work to wait for.
    private func hydraHasPendingLanding(_ leadID: UUID) -> Bool {
        hydraTeam(of: leadID).contains { head in
            guard let info = head.hydra, info.mergedAt == nil, let landing = info.landing else { return false }
            return !landing.files.isEmpty && !landing.landed
        }
    }

    /// One stable total ordering across every project, by lead UUID: the earliest job
    /// keeps priority and every job reads the same order, so a contested file is never
    /// settled by a different winner than its neighbours.
    private func hydraRanksAfter(_ lead: ChatThread, _ other: UUID) -> Bool {
        lead.id.uuidString > other.uuidString
    }

    /// Active work keeps its claims regardless of age. Completed head landings stop
    /// reserving files when their idle lead is no longer eligible for recovery.
    private func canStillMerge(_ lead: ChatThread) -> Bool {
        let live = existingRuntime(for: lead.id)
        if let live, live.phase != .idle || live.isHydraMerging { return true }
        guard !lead.isArchived, hydraIsOn(lead),
              lead.updatedAt > Date.now.addingTimeInterval(-Self.hydraMergeWindow) else { return false }
        // Landed head work no merge has taken keeps the claim alive the same way an
        // unmerged turn does: this is the eligibility `resumeHydraMerges` uses.
        let landedHeadWork = hydraTeam(of: lead.id).contains { $0.hydra.map { $0.mergedAt == nil && ($0.landing?.landed ?? false) } ?? false }
        guard let live else { return lead.lastStatus == .completed }
        return live.turns.last?.status == .completed && (!live.hydraUnmergedTurns.isEmpty || landedHeadWork)
    }

    /// A non-default branch is spent when it holds nothing `origin/<target>` lacks.
    private func branchIsSpent(_ git: Git, branch: String, target: String) async -> Bool {
        do {
            let head = try await git.commitHash()
            if (try? await git.commitHash(of: "refs/tivano/merged/\(branch)")) == head { return true }
            guard let base = await git.mergeBase("HEAD", "origin/\(target)") else { return false }
            let own = try await git.changedPaths(from: base, to: "HEAD")
            if own.isEmpty { return true }
            let changed = Set(try await git.changedPaths(from: "HEAD", to: "origin/\(target)"))
            return !own.contains { changed.contains($0) }
        } catch {
            return false
        }
    }

    /// Brings the checkout's current branch, default or not, up to the merge without touching the working
    /// tree: the branch moves to what origin has, the index takes the merged version of the
    /// team's files (the working tree already holds it), and any other file the remote
    /// changed meanwhile is checked out only where it is clean locally. Returns false, and
    /// changes nothing, where that cannot be done safely. `headIsMerged` is for a branch
    /// the forge squashed, whose tip is no ancestor of the remote.
    private func syncDefaultBranch(_ git: Git, from head: String, target: String, ownPaths: [String], merged: [String: Data] = [:], headIsMerged: Bool = false) async -> Bool {
        let remote = "origin/\(target)"
        guard (try? await git.fetch()) != nil, (headIsMerged ? true : await git.isAncestor(head, of: remote)) else { return false }
        // A file merged three ways went out holding the remote's changes as well: the
        // checkout takes that result, but only while the file still holds what was merged
        // from. A file edited again since is left alone, and so is the whole checkout.
        let root = git.directory
        var mergedFrom: [String: Data] = [:]
        for (path, _) in merged {
            guard let working = try? Data(contentsOf: root.appendingPathComponent(path)) else { return false }
            mergedFrom[path] = working
        }
        guard let changed = try? await git.changedPaths(from: head, to: remote) else { return false }
        let own = Set(ownPaths)
        let others = changed.filter { !own.contains($0) }
        let dirty = Set(await git.dirtyPaths())
        guard others.allSatisfy({ !dirty.contains($0) }) else { return false }
        // One git process answers for every path at once; a process per path took a
        // remote that had moved on by thousands of files minutes to sort.
        let present = await git.presentPaths(among: others, in: remote)
        let kept = others.filter { present.contains($0) }
        let gone = others.filter { !present.contains($0) }
        // `reset --soft` moves the branch with no expected old value, so a commit made in
        // a terminal while the merge ran would be left with nothing pointing at it. The
        // checkout is left alone instead, and `git pull` is the user's to run.
        guard (try? await git.commitHash()) == head else { return false }
        do {
            try await git.resetSoft(to: remote)
            try await git.resetIndex(paths: ownPaths)
            try await git.checkoutPaths(from: remote, kept)
            try await git.removePaths(gone)
            for (path, content) in merged {
                let url = root.appendingPathComponent(path)
                guard (try? Data(contentsOf: url)) == mergedFrom[path] else { continue }
                try content.write(to: url, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    /// The commit message: written by the text engine from the patch, like the commit
    /// sheet's, else the chat's title over the heads' tasks.
    private func commitMessage(for lead: ChatThread, files: [DiffFile], patch: String, directory: String) async -> String {
        if let engine = textEngine(preferring: lead.provider) {
            let summary = files.map { "\($0.change == .added ? "A" : ($0.change == .deleted ? "D" : "M")) \($0.path)" }.joined(separator: "\n")
            if let text = await TextGeneration.commitMessage(
                summary: summary,
                patch: patch,
                instructions: settings.commitInstructions,
                engine: engine,
                directory: URL(fileURLWithPath: directory)
            ), !text.isEmpty {
                return text
            }
        }
        var lines = [lead.title == ChatThread.untitled ? "Hydra: the team's work" : lead.title, ""]
        for head in hydraTeam(of: lead.id) {
            guard let info = head.hydra, !info.task.isEmpty else { continue }
            lines.append("- \(info.persona.name): \(TextCleanup.singleLine(info.task, limit: 100))")
        }
        return lines.joined(separator: "\n").trimmed
    }

    /// The request's description: what the team did and how the lead summed it up.
    private func mergeRequestBody(for lead: ChatThread, files: [DiffFile], through: Set<UUID>, runtime: ThreadRuntime) -> String {
        var lines = ["Opened by Tivano once its Hydra team finished.", ""]
        let heads = hydraTeam(of: lead.id).compactMap(\.hydra).filter { !$0.task.isEmpty }
        if !heads.isEmpty {
            lines.append("## Heads")
            for info in heads {
                var line = "- **\(info.persona.name)**: \(TextCleanup.singleLine(info.task, limit: 120))"
                if let landing = info.landing, !landing.files.isEmpty {
                    line += " (\(landing.files.count == 1 ? "1 file" : "\(landing.files.count) files"))"
                }
                lines.append(line)
            }
            lines.append("")
        }
        if let reply = runtime.entries.last(where: { $0.kind == .assistant && $0.item.turnID.map(through.contains) == true }).flatMap({ entry -> String? in
            guard case .assistant(let message) = entry.item.content else { return nil }
            return message.text.trimmed
        }), !reply.isEmpty {
            lines.append("## The lead's summary")
            lines.append(reply.count > 2_000 ? String(reply.prefix(2_000)) + "…" : reply)
            lines.append("")
        }
        lines.append("## Files")
        lines += files.map { "- `\($0.path)` (+\($0.additions) −\($0.deletions))" }
        return lines.joined(separator: "\n")
    }

    /// The chat's own branch: the same on every try, so a retry after a failed merge
    /// updates the request it opened. A fresh name per try opened a new request every
    /// five minutes for one job (ten of them, all conflicting, on September 22).
    private static func hydraBranchName(for lead: ChatThread) -> String {
        let title = lead.title == ChatThread.untitled ? "team" : lead.title
        var slug = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 40 { slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        let suffix = String(lead.id.uuidString.lowercased().prefix(6))
        return "hydra/\(slug.isEmpty ? "team" : slug)-\(suffix)"
    }

    /// The files among `paths` that hold a three-way merge's conflict markers: a line that
    /// opens with `<<<<<<< ` and one that opens with `>>>>>>> `. Read off the main actor;
    /// a file that is gone (a deletion the team made) or too large to be source is skipped.
    private nonisolated static func pathsWithConflictMarkers(_ paths: [String], in checkout: String) async -> [String] {
        await Task.detached(priority: .utility) {
            let root = URL(fileURLWithPath: checkout)
            let opening = Data("\n<<<<<<< ".utf8)
            let closing = Data("\n>>>>>>> ".utf8)
            return paths.filter { path in
                let url = root.appendingPathComponent(path)
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 4_000_000,
                      let data = try? Data(contentsOf: url) else { return false }
                let body = Data([0x0A]) + data
                return body.range(of: opening) != nil && body.range(of: closing) != nil
            }
        }.value
    }

    private func recordHydraSettlement(leadID: UUID, runtime: ThreadRuntime) {
        guard hydraUnmergedFileCount(of: leadID) == 0 else { return }
        runtime.recordHydraMerge(HydraMergeRecord(at: .now, outcome: .settled, project: nil, label: nil, url: nil, files: 0, detail: nil))
        note(leadID, "Already on main: nothing to merge.", "Every change from this chat is on main already, taken along by an earlier merge request (this chat's or another's) or committed by hand. Nothing was sent and no new merge request was opened.")
    }

    private static func filesLine(_ files: [DiffFile]) -> String {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        return "\(files.count == 1 ? "1 file" : "\(files.count) files") (+\(additions) −\(deletions))"
    }

    /// A note from Hydra in the lead's timeline, and word of it when the chat is out of view.
    private func note(_ leadID: UUID, _ title: String, _ body: String) {
        // The note lands under the id the merging pill has been drawn with, so the timeline
        // keeps one row from the first stage to the outcome; the id is spent here, so a
        // second note in the same run would get one of its own.
        let runtime = existingRuntime(for: leadID)
        let id = runtime?.hydraMergeNoteID
        runtime?.hydraMergeNoteID = nil
        runtime?.appendHydraNote(title + "\n" + body, id: id)
        let onScreen = selectedThreadID == leadID
        guard !(NSApp.isActive && onScreen) else { return }
        updateThread(leadID) { $0.hasUnread = true }
        updateDockBadge()
        if settings.notifyWhenFinished, let lead = thread(leadID) {
            notify(threadID: leadID, title: lead.title, body: title)
        }
    }
}

/// Why a Hydra merge request could not be opened on GitLab.
private enum HydraMergeRequestError: LocalizedError {
    /// glab is not signed in, or GitLab answered 401: the token is missing or expired.
    case gitLabAuth(host: String, branch: String, detail: String)
    /// glab failed for any other reason, recovery retry included.
    case creationFailed(String)

    var errorDescription: String? {
        switch self {
        case .gitLabAuth(let host, let branch, let detail):
            return "GitLab refused the login (401 Unauthorized) for \(host): the token glab signs in with is missing or expired.\n\n\(detail)\n\nSign back in with `glab auth login --hostname \(host)` (or export a valid GITLAB_TOKEN), then ask for the merge again. The branch `\(branch)` is already pushed, so the team's work is safe."
        case .creationFailed(let message):
            return message
        }
    }
}
