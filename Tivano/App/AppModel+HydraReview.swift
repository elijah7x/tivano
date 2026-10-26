import Foundation

// Hydra 2.0 (Labs): the cross-vendor, read-only review of a job's diff before it is
// merged. See docs/hydra2.md §6.
extension AppModel {
    /// Reviews the v2 job's landed work once. Returns true when a `[Hydra] Review` turn
    /// went to the lead, so the caller stops and settles again when that turn ends.
    func reviewHydraJob(of leadID: UUID, jobID: UUID) async -> Bool {
        guard let lead = thread(leadID),
              let job = lead.hydraJobs.first(where: { $0.id == jobID }),
              job.reviewEngine == nil, job.reviewSkipped == nil else { return false }
        func skip(_ reason: String) -> Bool {
            updateHydraJob(jobID, of: leadID) { $0.reviewSkipped = reason }
            return false
        }
        let leadProvider = job.leadProvider.flatMap { ProviderKind(storedValue: $0) } ?? lead.provider
        guard let selected = hydraReviewEngine(for: leadProvider) else {
            return skip("no other-vendor CLI available")
        }
        guard let checkoutPath = lead.worktreePath ?? project(lead.projectID)?.path else {
            return skip("review failed")
        }
        let checkout = URL(fileURLWithPath: checkoutPath, isDirectory: true)
        let git = Git(checkoutPath)
        let runtime = runtime(for: leadID)
        await runtime.ensureLoaded()
        guard runtime.phase == .idle, !runtime.isReverting else { return skip("lead busy") }

        let jobHeads = hydraTeam(of: leadID).filter { $0.hydra?.jobID == jobID }
        var paths = Set<String>()
        func collect(_ path: String, root: String) {
            let trimmed = path.trimmed
            let absolute = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.contains("://")
                ? trimmed
                : (root as NSString).appendingPathComponent(trimmed)
            if let relative = TouchedPaths.relative(absolute, root: checkoutPath) {
                paths.insert(relative)
            }
        }
        for head in jobHeads {
            guard let info = head.hydra, let landing = info.landing, landing.landed else { continue }
            let root = info.targetCheckout ?? (head.projectID == lead.projectID ? checkoutPath : project(head.projectID)?.path ?? checkoutPath)
            for file in landing.files { collect(file.path, root: root) }
        }
        if let turnID = job.turnID,
           let start = runtime.turns.firstIndex(where: { $0.id == turnID }) {
            for turn in runtime.turns.suffix(from: start) {
                for path in turn.touchedPaths ?? [] { collect(path, root: checkoutPath) }
            }
        }
        let sortedPaths = paths.sorted()
        guard !sortedPaths.isEmpty else { return skip("no changes") }
        guard let base = job.baseCommit?.nilIfEmpty else { return skip("review failed") }

        var patch = ""
        func appendPatch(_ piece: String) {
            guard !piece.isEmpty else { return }
            if !patch.isEmpty, !patch.hasSuffix("\n") { patch += "\n" }
            patch += piece
        }
        var untracked: [String] = []
        var start = 0
        while start < sortedPaths.count {
            let chunk = Array(sortedPaths[start..<min(start + 400, sortedPaths.count)])
            guard let tracked = try? await git.run(["--literal-pathspecs", "ls-files", "-z", "--cached", "--"] + chunk),
                  tracked.succeeded else { return skip("review failed") }
            let cached = Set(tracked.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init))
            untracked += chunk.filter { !cached.contains($0) }
            guard let diff = try? await git.run(["--literal-pathspecs", "diff", "--no-ext-diff", base, "--"] + chunk),
                  diff.succeeded else { return skip("review failed") }
            appendPatch(diff.output)
            start += chunk.count
        }
        for path in untracked {
            var isDirectory: ObjCBool = false
            let file = checkout.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            guard let diff = try? await git.run(["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", path]),
                  diff.status == 0 || diff.status == 1 else { return skip("review failed") }
            appendPatch(diff.output)
        }
        guard !patch.trimmed.isEmpty else { return skip("no changes") }
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
        guard let findings = await TextGeneration.review(prompt, engine: selected.engine, directory: checkout) else {
            return skip("review failed")
        }
        let findingCount = findings.contains("NO FINDINGS") ? 0 : findings.components(separatedBy: .newlines).count {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Finding ")
        }
        updateHydraJob(jobID, of: leadID) {
            $0.reviewEngine = selected.reviewer
            $0.reviewFindings = findingCount
        }
        guard findingCount > 0 else { return false }
        // The review took minutes: the user may have sent the lead something meanwhile.
        guard runtime.phase == .idle, !runtime.isReverting else { return skip("lead busy") }
        let text = HydraPrompts.v2ReviewMessage(reviewer: selected.reviewer, findings: findings)
        await runtime.sendHydraReview(text)
        return true
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
