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
            return skip("not applicable: no checkout")
        }
        let checkout = URL(fileURLWithPath: checkoutPath, isDirectory: true)
        let runtime = runtime(for: leadID)
        await runtime.ensureLoaded()
        guard runtime.phase == .idle, !runtime.isReverting else { return .pending }
        guard runtime.hydraReviewRunning == nil else { return .pending }
        let jobHeads = hydraTeam(of: leadID).filter { $0.hydra?.jobID == jobID }
        if !(await Git(checkoutPath).isRepository()) {
            var hasGitTarget = false
            for head in jobHeads {
                if let target = head.hydra?.targetCheckout, await Git(target).isRepository() {
                    hasGitTarget = true
                    break
                }
            }
            guard hasGitTarget else { return skip("not applicable: not a Git checkout") }
        }
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
        var skippedNonGitChanges = false
        for root in paths.keys.sorted() {
            let git = Git(root)
            guard await git.isRepository() else {
                skippedNonGitChanges = true
                continue
            }
            guard let current = try? await git.currentTree() else { return skip("review failed: git tree") }
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
                      diff.succeeded else { return skip("review failed: git diff") }
                checkoutPatch += diff.output
                start += chunk.count
            }
            if !checkoutPatch.trimmed.isEmpty { patch += "# checkout: \(root)\n\(checkoutPatch)\n" }
        }
        guard !patch.trimmed.isEmpty else {
            return skip(skippedNonGitChanges ? "not applicable: not a Git checkout" : "no changes")
        }
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
        let prompt = HydraPrompts.v2ReviewPrompt(request: job.request, notes: noteLines.joined(separator: "\n"), patch: patch)
        let findings: String
        let readableDirectories = paths.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        switch await TextGeneration.review(
            prompt,
            engine: selected.engine,
            directory: checkout,
            readableDirectories: readableDirectories
        ) {
        case .success(let text): findings = text
        case .failure(let failure):
            return skip("review failed (\(selected.reviewer)): \(failure.description)")
        }
        guard openHydraJob(of: leadID)?.id == jobID, openHydraJob(of: leadID)?.ending == nil else { return .skipped }
        let findingCount = findings.components(separatedBy: .newlines).count {
            $0.range(of: #"^[\s\-*>#_]*Finding\s*\d"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        updateHydraJob(jobID, of: leadID) {
            $0.reviewEngine = selected.reviewer
            $0.reviewFindings = findingCount
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
            guard HydraReviewChoice.providers.contains(provider),
                  providers.status(provider).auth != .signedOut,
                  let executable = providers.executable(for: provider) else { continue }
            let environment = providers.environment(for: provider)
            let engine: TextGeneration.Engine
            let model: String?
            var effort = choice.effort
            switch provider {
            case .claude:
                model = choice.model
                engine = .claude(executable: executable, environment: environment, model: model, effort: choice.effort)
            case .codex:
                guard let resolvedModel = choice.model ?? providers.defaultModel(for: .codex)?.id else { continue }
                model = resolvedModel
                engine = .codex(executable: executable, environment: environment, model: resolvedModel, effort: choice.effort)
            // For these CLIs an unset review model means the CLI's own default, not the
            // model last used in a chat (which `defaultModel(for:)` prefers).
            case .grok:
                model = choice.model
                let wire = choice.model.map { grokWireSelection(model: $0, effort: choice.effort) } ?? (model: nil, effort: choice.effort)
                engine = .grok(executable: executable, environment: environment, model: wire.model, effort: wire.effort)
            case .pi:
                model = choice.model
                engine = .pi(executable: executable, environment: environment, model: model, effort: choice.effort)
            case .antigravity:
                let rawModel = choice.model
                let catalog = AntigravitySession.addingSeedRows(providers.models(for: .antigravity), seed: ProviderRegistry.antigravitySeed)
                let normalized = AntigravitySession.normalize(model: rawModel, effort: choice.effort, catalog: catalog)
                model = rawModel
                // Without a model, normalize sends no effort; the label must not claim one.
                if rawModel == nil { effort = nil }
                engine = .antigravity(executable: executable, environment: environment, model: normalized.model, effort: normalized.effort)
            default: continue
            }
            var reviewer = provider.displayName
            if let model { reviewer += " \(providers.model(model, for: provider)?.name ?? model)" }
            if let effort, !effort.isEmpty { reviewer += " · \(ModelOption.effortTitle(effort))" }
            return (engine, reviewer, provider)
        }
        return nil
    }
}
