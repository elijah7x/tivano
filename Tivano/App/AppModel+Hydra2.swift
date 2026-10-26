import Foundation

// Hydra 2.0 (Labs): the v2 job ledger, continuing finished heads and settling a job.
// See docs/hydra2.md.
extension AppModel {
    /// The lead's open v2 job, if any.
    func openHydraJob(of leadID: UUID) -> HydraJobRecord? {
        thread(leadID)?.hydraJobs.last(where: \.isOpen)
    }

    /// Whether a head belongs to its lead's open v2 job: such a head is steered only
    /// through the lead (`continue`), never from its own composer.
    func hydraHeadIsInOpenJob(_ head: ChatThread) -> Bool {
        guard let info = head.hydra, info.mode == .v2, let jobID = info.jobID,
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
            mode: .v2,
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
            merge: nil
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
            updateHydraJob(job.id, of: leadID) { $0.ending = ending }
            if ending != .recovered,
               hydraTeam(of: leadID).contains(where: { $0.hydra?.jobID == job.id && $0.hydra?.status == .running }) { return }
            await existingRuntime(for: leadID)?.hydraLanding?.value
            updateHydraJob(job.id, of: leadID) {
                $0.pendingReview = nil
                $0.finishedAt = .now
            }
            for head in hydraTeam(of: leadID) where head.hydra?.jobID == job.id && head.hydra?.isFinished == true {
                guard let info = head.hydra, let copy = head.worktreePath, let base = info.baseTree else { continue }
                let unchanged = (try? await Git(copy).currentTree()) == base
                guard unchanged || info.landing?.landed == true else { continue }
                releaseHydraCopy(of: head.id)
            }
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
        updateHydraJob(job.id, of: leadID) {
            $0.ending = .completed
            $0.finishedAt = .now
        }
        releaseHydraJobCopies(of: leadID, jobID: job.id)
        scheduleSave()
    }

    func endHydraJobsForHydraOff(of leadID: UUID) {
        guard let job = openHydraJob(of: leadID) else { return }
        updateHydraJob(job.id, of: leadID) { $0.ending = .hydraOff }
        for head in hydraTeam(of: leadID) where head.hydra?.jobID == job.id && head.hydra?.status == .running {
            stopHydraHead(head.id)
        }
        Task { [weak self] in
            guard let self else { return }
            // Interrupting a provider is asynchronous; let its final landing finish.
            while self.hydraTeam(of: leadID).contains(where: { $0.hydra?.jobID == job.id && $0.hydra?.status == .running }) {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard self.openHydraJob(of: leadID)?.id == job.id else { return }
            await self.settleHydraJob(of: leadID, ending: .hydraOff)
        }
    }

    /// Releases the copies retained by finished heads of one settled job.
    func releaseHydraJobCopies(of leadID: UUID, jobID: UUID) {
        for head in hydraTeam(of: leadID) where head.hydra?.jobID == jobID && head.hydra?.isFinished == true {
            releaseHydraCopy(of: head.id)
        }
    }

    /// Sends a finished head of the lead's open job back to its part in its own session.
    /// Returns nil when it went, else the reason it did not, for the lead.
    func continueHydraHead(named name: String, of leadID: UUID, delegation: HydraDelegation, packet: HydraHandoffPacket) -> String? {
        guard let job = openHydraJob(of: leadID), job.mode == .v2,
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
        // A shared-checkout head never had a copy to release. A landed report with no
        // remaining copy is the durable trace of one that was released.
        if info.landing != nil, !info.hasOwnCopy || head.worktreePath == nil {
            return "its copy was already released"
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
            workplace = (info.targetCheckout ?? (try? executionDirectory(for: head))).map { .shared(path: $0) }
        }
        headRuntime.sendHydraBrief(HydraPrompts.v2ContinuePrompt(delegation: delegation, packet: packet, workplace: workplace), attachments: [])
        return nil
    }
}
