import Foundation

// Hydra 2.0: the independent, read-only review of a job's diff before it is
// merged. See docs/hydra2.md §6.
extension AppModel {
    enum HydraReviewOutcome { case started, pending, skipped }

    /// Reviews the job once, keeping it open until findings reach an idle lead.
    func reviewHydraJob(of leadID: UUID, jobID: UUID) async -> HydraReviewOutcome {
        guard let lead = thread(leadID),
              let job = lead.hydraJobs.first(where: { $0.id == jobID }),
              job.reviewEngine == nil, job.reviewSkipped == nil else { return .skipped }
        func skip(_ reason: String) -> HydraReviewOutcome {
            updateHydraJob(jobID, of: leadID) { $0.reviewSkipped = reason }
            return .skipped
        }
        guard settings.hydraReviewEnabled else { return skip("independent review is off") }
        guard let checkoutPath = lead.worktreePath ?? project(lead.projectID)?.path else {
            return skip("review failed")
        }
        let checkout = URL(fileURLWithPath: checkoutPath, isDirectory: true)
        let runtime = runtime(for: leadID)
        await runtime.ensureLoaded()
        guard runtime.phase == .idle, !runtime.isReverting else { return .pending }
        guard runtime.hydraReviewRunning == nil else { return .pending }
        guard let selected = hydraReviewEngine() else {
            return skip("no review model available")
        }
        runtime.hydraReviewRunning = selected.reviewer
        runtime.hydraReviewProvider = selected.provider
        updateTaskSleepPrevention()
        defer {
            runtime.hydraReviewRunning = nil
            runtime.hydraReviewProvider = nil
            updateTaskSleepPrevention()
        }

        let jobHeads = hydraTeam(of: leadID).filter { $0.hydra?.jobID == jobID }
        var paths: [String: Set<String>] = [:]
        func collect(_ path: String, root: String) {
            let trimmed = path.trimmed
            let absolute = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.contains("://")
                ? trimmed : (root as NSString).appendingPathComponent(trimmed)
            if let relative = TouchedPaths.relative(absolute, root: root) {
                paths[root, default: []].insert(relative)
            }
        }
        for head in jobHeads {
            guard let info = head.hydra else { continue }
            let root = info.targetCheckout ?? checkoutPath
            if let landing = info.landing, landing.landed {
                for file in landing.files { collect(file.path, root: root) }
            }
            if !info.hasOwnCopy, info.landing == nil {
                let headRuntime = self.runtime(for: head.id)
                await headRuntime.ensureLoaded()
                for turn in headRuntime.turns {
                    for path in turn.touchedPaths ?? [] { collect(path, root: root) }
                }
            }
        }
        if let turnID = job.turnID, let start = runtime.turns.firstIndex(where: { $0.id == turnID }) {
            for turn in runtime.turns.suffix(from: start) {
                for path in turn.touchedPaths ?? [] { collect(path, root: checkoutPath) }
            }
        }
        var patch = ""
        for root in paths.keys.sorted() {
            let git = Git(root)
            guard let current = try? await git.currentTree() else { return skip("review failed") }
            let base: String
            if let recorded = job.baseTrees?[root] {
                base = recorded
            } else {
                updateHydraJob(jobID, of: leadID) {
                    if $0.baseTrees == nil { $0.baseTrees = [:] }
                    $0.baseTrees?[root] = current
                }
                base = "HEAD"
            }
            let sortedPaths = (paths[root] ?? []).sorted()
            var checkoutPatch = ""
            var start = 0
            while start < sortedPaths.count {
                let chunk = Array(sortedPaths[start..<min(start + 400, sortedPaths.count)])
                // Both trees include untracked files, including those already present at job start.
                guard let diff = try? await git.run(["--literal-pathspecs", "diff", "--no-ext-diff", base, current, "--"] + chunk),
                      diff.succeeded else { return skip("review failed") }
                checkoutPatch += diff.output
                start += chunk.count
            }
            if !checkoutPatch.trimmed.isEmpty { patch += "# checkout: \(root)\n\(checkoutPatch)\n" }
        }
        guard !patch.trimmed.isEmpty else { return skip("no changes") }
        let fileStats = DiffStats.files(inPatch: patch)
        if patch.count > 80_000 {
            let notice = "\n\n[Patch truncated to 80,000 characters.]"
            patch = String(patch.prefix(80_000 - notice.count)) + notice
        }

        var noteLines: [String] = []
        for head in jobHeads {
            guard let info = head.hydra,
                  let notes = info.reportNotes ?? job.heads.first(where: { $0.headID == head.id })?.notes else { continue }
            var fields: [String] = []
            if let deviations = notes.deviations { fields.append("Deviations \(deviations)") }
            if let unfinished = notes.unfinished { fields.append("Unfinished \(unfinished)") }
            if let uncertain = notes.uncertain { fields.append("Uncertain \(uncertain)") }
            if !fields.isEmpty { noteLines.append("\(info.persona.name): \(fields.joined(separator: " / "))") }
        }
        if hydraJobRunsDecisions(jobID, of: leadID) {
            let leadReply = runtime.entries.last(where: {
                if case .assistant = $0.item.content { return true }
                return false
            }).flatMap { entry -> String? in
                guard case .assistant(let message) = entry.item.content else { return nil }
                return message.text
            } ?? ""
            let request = HydraDecisionRequests.preReview(
                request: job.request,
                leadReply: leadReply,
                headFlags: noteLines,
                heads: jobHeads.count,
                leadBuilt: job.leadBuilt,
                leadEditsAfterReports: job.leadEditsAfterReports,
                files: fileStats
            )
            runHydraDecision(request, leadID: leadID, jobID: jobID)
        }
        let prompt = HydraPrompts.v2ReviewPrompt(request: job.request, notes: noteLines.joined(separator: "\n"), patch: patch)
        guard let findings = await TextGeneration.review(prompt, engine: selected.engine, directory: checkout) else {
            return skip("review failed")
        }
        guard openHydraJob(of: leadID)?.id == jobID, openHydraJob(of: leadID)?.ending == nil else { return .skipped }
        let findingCount = findings.contains("NO FINDINGS") ? 0 : findings.components(separatedBy: .newlines).count {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Finding ")
        }
        updateHydraJob(jobID, of: leadID) {
            $0.reviewEngine = selected.reviewer
            $0.reviewFindings = findingCount
        }
        if hydraJobRunsDecisions(jobID, of: leadID) {
            recordHydraDecisionOutcome(
                leadID: leadID, jobID: jobID, reviewer: selected.reviewer,
                findings: findingCount,
                findingPaths: findingCount == 0 ? [] : DiffStats.mentionedPaths(fileStats, in: findings)
            )
        }
        guard findingCount > 0 else { return .skipped }
        let text = HydraPrompts.v2ReviewMessage(reviewer: selected.reviewer, findings: findings)
        // The review took minutes: the user may have sent the lead something meanwhile.
        // The findings wait for the lead's next settle rather than being dropped.
        guard runtime.phase == .idle, !runtime.isReverting else {
            updateHydraJob(jobID, of: leadID) { $0.pendingReview = text }
            return .pending
        }
        await runtime.sendHydraReview(text, jobID: jobID)
        return .started
    }

    private func hydraReviewEngine() -> (engine: TextGeneration.Engine, reviewer: String, provider: ProviderKind)? {
        for choice in [settings.hydraReviewFirst, settings.hydraReviewSecond] {
            let provider = choice.provider
            guard provider == .claude || provider == .codex,
                  providers.status(provider).auth != .signedOut,
                  let executable = providers.executable(for: provider) else { continue }
            let environment = providers.environment(for: provider)
            let engine: TextGeneration.Engine
            let model: String?
            switch provider {
            case .claude:
                model = choice.model
                engine = .claude(executable: executable, environment: environment, model: model, effort: choice.effort)
            case .codex:
                guard let resolvedModel = choice.model ?? providers.defaultModel(for: .codex)?.id else { continue }
                model = resolvedModel
                engine = .codex(executable: executable, environment: environment, model: resolvedModel, effort: choice.effort)
            default: continue
            }
            var reviewer = provider.displayName
            if let model { reviewer += " \(providers.model(model, for: provider)?.name ?? model)" }
            if let effort = choice.effort, !effort.isEmpty { reviewer += " · \(ModelOption.effortTitle(effort))" }
            return (engine, reviewer, provider)
        }
        return nil
    }
}
