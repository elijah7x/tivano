import Foundation

// Hydra 2.0 (Labs): the v2 job ledger, continuing finished heads and settling a job.
// See docs/hydra2.md.
extension AppModel {
    /// The lead's open v2 job, if any.
    func openHydraJob(of leadID: UUID) -> HydraJobRecord? {
        thread(leadID)?.hydraJobs.last(where: \.isOpen)
    }

    /// Edits one job record of a lead; a no-op when either is gone.
    func updateHydraJob(_ jobID: UUID, of leadID: UUID, _ change: (inout HydraJobRecord) -> Void) {
        updateThread(leadID) { thread in
            guard let index = thread.hydraJobs.firstIndex(where: { $0.id == jobID }) else { return }
            change(&thread.hydraJobs[index])
        }
    }

    /// Starts a v2 job for a user's request: closes any job left open, records the lead,
    /// the pair and the checkout's base. Returns the new job's id.
    func beginHydraJob(for leadID: UUID, turnID: UUID, request: String) async -> UUID? {
        guard let lead = thread(leadID) else { return nil }
        for open in lead.hydraJobs where open.isOpen {
            updateHydraJob(open.id, of: leadID) { $0.finishedAt = .now }
            releaseHydraJobCopies(of: leadID, jobID: open.id)
        }
        let pair = hydraPair(for: lead)
        let launch = hydraLaunch(for: lead)
        var baseCommit: String?
        var baseDirty: Bool?
        if let checkout = hydraCheckout(of: lead) {
            let git = Git(checkout)
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
            baseCommit: baseCommit,
            baseDirty: baseDirty,
            reviewEngine: nil,
            reviewFindings: nil,
            reviewAccepted: nil,
            reviewSkipped: nil,
            merge: nil
        )
        updateThread(leadID) { $0.hydraJobs.append(job) }
        return job.id
    }

    /// The end of a v2 lead turn with the whole team back and nothing waiting: review
    /// once, then merge (with auto-merge on) and close the job.
    func settleHydraJob(of leadID: UUID) async {
        guard let job = openHydraJob(of: leadID) else { return }
        let turns = existingRuntime(for: leadID)?.turns ?? []
        let leadTouchedFiles: Bool
        if let turnID = job.turnID, let first = turns.firstIndex(where: { $0.id == turnID }) {
            leadTouchedFiles = turns[first...].contains { !($0.touchedPaths ?? []).isEmpty }
        } else {
            leadTouchedFiles = false
        }
        let hasWork = job.heads.contains { $0.landedFiles > 0 } || leadTouchedFiles
        if hasWork, job.reviewEngine == nil, job.reviewSkipped == nil,
           await reviewHydraJob(of: leadID, jobID: job.id) {
            return
        }
        if settings.hydraAutoMerge, let lead = thread(leadID), hydraIsOn(lead) {
            await autoMergeHydraWork(of: leadID)
        }
        updateHydraJob(job.id, of: leadID) { $0.finishedAt = .now }
        releaseHydraJobCopies(of: leadID, jobID: job.id)
        scheduleSave()
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
        headRuntime.sendHydraBrief(HydraPrompts.v2ContinuePrompt(delegation: delegation, packet: packet), attachments: [])
        return nil
    }
}
