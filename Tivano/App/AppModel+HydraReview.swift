import Foundation

// Hydra 2.0 (Labs): the cross-vendor, read-only review of a job's diff before it is
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
        guard let checkoutPath = lead.worktreePath ?? project(lead.projectID)?.path else {
            return skip("review failed")
        }
        let checkout = URL(fileURLWithPath: checkoutPath, isDirectory: true)
        let runtime = runtime(for: leadID)
        await runtime.ensureLoaded()
        guard runtime.phase == .idle, !runtime.isReverting else { return .pending }

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
        let leadProvider = job.leadProvider.flatMap { ProviderKind(storedValue: $0) } ?? lead.provider
        guard let selected = hydraReviewEngine(for: leadProvider) else {
            return skip("no other-vendor CLI available")
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
        runtime.hydraReviewRunning = selected.reviewer
        defer { runtime.hydraReviewRunning = nil }
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

    private func hydraReviewEngine(for provider: ProviderKind) -> (engine: TextGeneration.Engine, reviewer: String)? {
        func claude() -> (engine: TextGeneration.Engine, reviewer: String)? {
            guard providers.status(.claude).auth != .signedOut, let executable = providers.executable(for: .claude) else { return nil }
            return (.claude(executable: executable, environment: providers.environment(for: .claude)), "Claude")
        }
        func codex() -> (engine: TextGeneration.Engine, reviewer: String)? {
            guard providers.status(.codex).auth != .signedOut,
                  let executable = providers.executable(for: .codex),
                  let model = providers.defaultModel(for: .codex)?.id else { return nil }
            return (.codex(executable: executable, environment: providers.environment(for: .codex), model: model), "Codex \(model)")
        }
        switch provider {
        case .claude: return codex()
        case .codex: return claude()
        default: return claude() ?? codex()
        }
    }
}
