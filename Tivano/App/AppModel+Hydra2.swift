import Foundation

// Hydra 2.0: the v2 job ledger, continuing finished heads and settling a job.
// See docs/hydra2.md.
extension AppModel {
    /// The lead's open v2 job, if any.
    func openHydraJob(of leadID: UUID) -> HydraJobRecord? {
        thread(leadID)?.hydraJobs.last(where: \.isOpen)
    }

    /// Whether a head belongs to its lead's open v2 job: such a head is steered only
    /// through the lead (`continue`), never from its own composer.
    func hydraHeadIsInOpenJob(_ head: ChatThread) -> Bool {
        guard let info = head.hydra, let jobID = info.jobID,
              let lead = head.parentThreadID, let job = openHydraJob(of: lead) else { return false }
        return job.id == jobID
    }

    /// Edits one job record of a lead; a no-op when either is gone.
    func updateHydraJob(_ jobID: UUID, of leadID: UUID, _ change: (inout HydraJobRecord) -> Void) {
        updateThread(leadID) { thread in
            guard let index = thread.hydraJobs.firstIndex(where: { $0.id == jobID }) else { return }
            change(&thread.hydraJobs[index])
        }
    }

    /// Starts a v2 job for a user's request, or continues its open job; records the lead,
    /// the pair and the checkout's base. Returns the new job's id.
    func beginHydraJob(for leadID: UUID, turnID: UUID, request: String) async -> UUID? {
        guard let lead = thread(leadID) else { return nil }
        if let open = openHydraJob(of: leadID) { return open.id }
        let pair = hydraPair(for: lead)
        let launch = hydraLaunch(for: lead)
        var baseCommit: String?
        var baseDirty: Bool?
        var baseTrees: [String: String] = [:]
        if let checkout = hydraCheckout(of: lead) {
            let git = Git(checkout)
            baseTrees[checkout] = try? await git.currentTree()
            baseCommit = (try? await git.output(["rev-parse", "HEAD"]))?.trimmed.nilIfEmpty
            if let status = try? await git.output(["status", "--porcelain"]) {
                baseDirty = !status.trimmed.isEmpty
            }
        }
        let job = HydraJobRecord(
            turnID: turnID,
            finishedAt: nil,
            request: request,
            leadProvider: lead.provider.rawValue,
            leadModel: lead.model,
            leadEffort: lead.effort,
            pairID: pair?.id,
            headsProvider: launch?.headsProvider.rawValue,
            headsModel: launch?.workerModel,
            headsEffort: launch?.workerEffort,
            headsNote: launch?.headsNote,
            tilt: launch?.tilt,
            baseCommit: baseCommit,
            baseDirty: baseDirty,
            reviewEngine: nil,
            reviewFindings: nil,
            reviewAccepted: nil,
            reviewSkipped: nil,
            baseTrees: baseTrees,
            merge: nil,
            decisions: settings.isDecisionsEnabled
        )
        updateThread(leadID) { $0.hydraJobs.append(job) }
        return job.id
    }

    /// The end of a v2 lead turn with the whole team back and nothing waiting: review
    /// once, then merge (with auto-merge on) and close the job.
    func settleHydraJob(of leadID: UUID, ending: HydraJobEnding = .completed) async {
        guard let job = openHydraJob(of: leadID) else { return }
        let ending = ending == .completed ? (job.ending ?? ending) : ending
        if ending != .completed {
            existingRuntime(for: leadID)?.clearQueuedHydraHeads()
            updateHydraJob(job.id, of: leadID) { $0.ending = ending }
            if ending != .recovered,
               hydraTeam(of: leadID).contains(where: { $0.hydra?.jobID == job.id && $0.hydra?.status == .running }) { return }
            await existingRuntime(for: leadID)?.hydraLanding?.value
            cancelTransientHydraRetries(of: leadID, jobID: job.id)
            updateHydraJob(job.id, of: leadID) {
                $0.pendingReview = nil
                $0.finishedAt = .now
                if $0.reviewEngine == nil, $0.reviewSkipped == nil {
                    $0.reviewSkipped = "not run: \(ending.rawValue)"
                }
            }
            await releaseHydraJobCopies(of: leadID, jobID: job.id, includeCompleted: false)
            scheduleSave()
            return
        }
        let runtime = runtime(for: leadID)
        guard runtime.phase == .idle, !runtime.isReverting, runtime.hydraReviewRunning == nil else { return }
        if let waiting = thread(leadID)?.hydraJobs.last(where: { $0.pendingReview != nil }),
           let text = waiting.pendingReview {
            updateHydraJob(waiting.id, of: leadID) { $0.pendingReview = nil }
            await runtime.sendHydraReview(text, jobID: waiting.id)
            return
        }
        if job.reviewEngine == nil, job.reviewSkipped == nil {
            switch await reviewHydraJob(of: leadID, jobID: job.id) {
            case .started, .pending: return
            case .skipped: break
            }
        }
        guard let current = openHydraJob(of: leadID), current.id == job.id, current.ending == nil,
              runtime.phase == .idle, !runtime.isReverting else { return }
        if settings.hydraAutoMerge, let lead = thread(leadID), hydraIsOn(lead), current.merge == nil {
            await autoMergeHydraWork(of: leadID, jobID: job.id)
            // Only a scheduled retry keeps the job open: a merge that returned early without a
            // result (nothing to merge, merging off for the lead) must not strand it.
            guard !hasHydraMergePending(of: leadID, jobID: job.id) else { return }
        }
        // The review and merge awaited: a follow-up may have sent heads out meanwhile, and
        // their work belongs to this job, which stays open until they are back.
        guard openHydraJob(of: leadID)?.id == job.id, runtime.phase == .idle,
              !runtime.hydraHasOutstandingWork,
              !hydraTeam(of: leadID).contains(where: { $0.hydra?.jobID == job.id && $0.hydra?.status == .running }) else { return }
        cancelTransientHydraRetries(of: leadID, jobID: job.id)
        updateHydraJob(job.id, of: leadID) {
            $0.ending = .completed
            $0.finishedAt = .now
        }
        await releaseHydraJobCopies(of: leadID, jobID: job.id)
        scheduleSave()
    }

    func endHydraJobsForHydraOff(of leadID: UUID) {
        guard let job = openHydraJob(of: leadID) else { return }
        existingRuntime(for: leadID)?.clearQueuedHydraHeads()
        updateHydraJob(job.id, of: leadID) { $0.ending = .hydraOff }
        for head in hydraTeam(of: leadID) where head.hydra?.jobID == job.id && head.hydra?.status == .running {
            stopHydraHead(head.id)
        }
        Task { [weak self] in
            guard let self else { return }
            // Interrupting a provider is asynchronous; let its final landing finish. Capped at
            // 30 seconds: a head whose status never leaves running must not keep this polling.
            for _ in 0..<300 {
                guard self.hydraTeam(of: leadID).contains(where: { $0.hydra?.jobID == job.id && $0.hydra?.status == .running }) else { break }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard self.openHydraJob(of: leadID)?.id == job.id else { return }
            await self.settleHydraJob(of: leadID, ending: .hydraOff)
        }
    }

    /// Releases the copies retained by finished heads of one settled job, keeping any
    /// stopped or failed head whose unlanded work still sits in its copy.
    func releaseHydraJobCopies(of leadID: UUID, jobID: UUID, includeCompleted: Bool = true) async {
        for head in hydraTeam(of: leadID) where head.hydra?.jobID == jobID && head.hydra?.isFinished == true {
            guard let info = head.hydra, let copy = head.worktreePath, let base = info.baseTree else { continue }
            if includeCompleted && info.status == .completed {
                releaseHydraCopy(of: head.id)
                continue
            }
            if info.landing?.landed == true {
                releaseHydraCopy(of: head.id)
                continue
            }
            let unchanged = (try? await Git(copy).currentTree()) == base
            guard unchanged else { continue }
            releaseHydraCopy(of: head.id)
        }
    }

    /// Sends a finished head of the lead's open job back to its part in its own session.
    /// Returns nil when it went, else the reason it did not, for the lead.
    func continueHydraHead(named name: String, of leadID: UUID, delegation: HydraDelegation, packet: HydraHandoffPacket) -> String? {
        guard let job = openHydraJob(of: leadID),
              let head = hydraTeam(of: leadID).first(where: { head in
                  guard let info = head.hydra else { return false }
                  return info.kind == .tivano && info.jobID == job.id
                      && info.persona.name.caseInsensitiveCompare(name.trimmed) == .orderedSame
              }),
              let info = head.hydra else {
            return "no such head in this job"
        }
        guard info.isFinished else { return "it is still at work" }
        let headRuntime = runtime(for: head.id)
        guard headRuntime.phase == .idle else { return "it is still at work" }
        guard !hydraCopiesReleasing.contains(head.id) else { return "its copy is being released" }
        // A shared-checkout head never had a copy to release. A landed report with no
        // remaining copy is the durable trace of one that was released.
        if info.landing != nil, !info.hasOwnCopy || head.worktreePath == nil {
            return "its copy was already released"
        }
        let checkout = info.targetCheckout ?? (try? executionDirectory(for: head))
        // A head routed before Tivano's own folders were all refused may still sit in one.
        if let target = info.targetCheckout {
            let home = HydraPaths.canonical(FileManager.default.homeDirectoryForCurrentUser.path)
            let taskWorkspaces = HydraPaths.canonical(StoragePaths.root.appendingPathComponent("task-workspaces", isDirectory: true).path)
            if HydraPaths.canonical(target) != home,
               Self.hydraPathTouchesProtectedRoot(target, roots: Self.hydraProtectedRoots(), taskWorkspaces: taskWorkspaces) {
                return String(format: Chrome.localized("its folder %@ is one Tivano keeps its own data in"), target)
            }
        }
        // The lead may list paths the head was never sent with, including folders Tivano
        // writes itself; those never reach a head.
        if let base = info.filesBase ?? checkout {
            let home = HydraPaths.canonical(FileManager.default.homeDirectoryForCurrentUser.path)
            let protectedRoots = Self.hydraProtectedRoots()
            let taskWorkspaces = HydraPaths.canonical(StoragePaths.root.appendingPathComponent("task-workspaces", isDirectory: true).path)
            for file in delegation.files {
                guard Self.hydraOwnedPathIsSafe(file, base: base) else {
                    return String(format: Chrome.localized("its files list %@, which is outside %@"), file, base)
                }
                let path = HydraPaths.canonical(URL(fileURLWithPath: base).appendingPathComponent(file).path)
                if path == home || Self.hydraPathTouchesProtectedRoot(path, roots: protectedRoots, taskWorkspaces: taskWorkspaces) {
                    return String(format: Chrome.localized("its files list %@, which is a folder Tivano keeps its own data in"), file)
                }
            }
        }
        updateHydraHead(head.id) {
            $0.status = .running
            $0.finishedAt = nil
        }
        updateThread(head.id) { $0.isInPanel = true }
        let workplace: HydraPrompts.Workplace?
        if info.hasOwnCopy, let path = head.worktreePath {
            workplace = .ownCopy(path: path)
        } else {
            workplace = checkout.map { .shared(path: $0, filesBase: info.filesBase, isNonGit: info.isNonGitCheckout == true) }
        }
        let brief = HydraPrompts.v2ContinuePrompt(delegation: delegation, packet: packet, workplace: workplace)
        let headID = head.id
        if let checkout, info.isNonGitCheckout == true, !info.hasOwnCopy {
            // Files the lead listed now are copied before the head hears its brief, even for
            // a head first sent with none; the job record gains them just after this returns.
            let batchID = info.batchID
            Task { @MainActor in
                await prepareHydraBackup(headID, checkout: checkout)
                // Stopped or sent elsewhere while the files were copied: the brief is stale.
                guard let current = thread(headID)?.hydra, current.status == .running,
                      current.batchID == batchID, headRuntime.phase == .idle else { return }
                headRuntime.sendHydraBrief(brief, attachments: [])
            }
        } else {
            headRuntime.sendHydraBrief(brief, attachments: [])
        }
        return nil
    }

    /// Continues one failed or stopped head in its retained copy. An open job goes through
    /// the lead's continuation checks and ledger; a closed job leaves the composer unlocked.
    @discardableResult
    func continueFailedHydraHead(_ id: UUID) -> Bool {
        guard let head = thread(id), let info = head.hydra, info.kind == .tivano,
              info.status == .failed || info.status == .stopped,
              info.hasOwnCopy, head.worktreePath != nil,
              !hydraCopiesReleasing.contains(id) else { return false }
        if let leadID = head.parentThreadID, let job = openHydraJob(of: leadID), job.id == info.jobID {
            let ownedFiles = job.heads.first(where: { $0.headID == id })?.files ?? []
            let delegation = HydraDelegation(
                task: info.task,
                prompt: AutoContinue.failedTurnContinueMessage,
                files: ownedFiles,
                filesGiven: true,
                continueHead: info.persona.name
            )
            let packet = HydraHandoffPacket(
                request: job.request,
                team: [HydraHandoffPacket.Member(name: info.persona.name, task: info.task, files: ownedFiles)]
            )
            guard continueHydraHead(named: info.persona.name, of: leadID, delegation: delegation, packet: packet) == nil else { return false }
            updateHydraJob(job.id, of: leadID) { job in
                if let index = job.heads.firstIndex(where: { $0.headID == id }) {
                    job.heads[index].continuations += 1
                    job.heads[index].files = ownedFiles
                } else {
                    var record = HydraJobHeadRecord(headID: id, name: info.persona.name, files: ownedFiles)
                    record.continuations = 1
                    job.heads.append(record)
                }
            }
            return true
        }
        guard let headRuntime = existingRuntime(for: id),
              let turnID = headRuntime.turns.last(where: { $0.completedAt != nil })?.id,
              headRuntime.sendContinuation(after: turnID, text: AutoContinue.failedTurnContinueMessage) else { return false }
        updateHydraHead(id) {
            $0.status = .running
            $0.finishedAt = nil
            $0.executionFinishedAt = nil
        }
        updateThread(id) { $0.isInPanel = true }
        return true
    }
}
