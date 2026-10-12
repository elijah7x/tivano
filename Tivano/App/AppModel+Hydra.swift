import Foundation

// Hydra's heads are threads: each one has a timeline of its own, sits in its lead's
// floating panel while it works, and drops under the lead in the sidebar once dismissed,
// like any helper. Every head is Tivano-run, whatever the lead's provider: it has a
// session of its own, in a copy of the checkout it was sent to, and its work lands in
// that checkout the moment it reports. No head runs inside the lead's provider session.

/// What a head changed in its copy since the tree it started from: the patch itself, the
/// files it touches, and the tree the copy holds now, which becomes the head's new base
/// once the patch lands.
private struct HydraPatch: Sendable {
    var text: String
    var files: [HydraLanding.File]
    var droppedBuildOutputFiles: Int
    var after: String
}

/// Absolute checkout paths compared the same way a repository lease is: standardized,
/// symlinks resolved. Shared with the merge, which groups work by the same identity.
enum HydraPaths {
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func same(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }
}

/// The git checkout an explicit path belongs to. `common` is `git rev-parse
/// --path-format=absolute --git-common-dir`, resolved like the merge's repository lease.
private enum HydraGitIdentityReader {
    struct Identity: Sendable {
        var checkout: String
        var common: String
        var mainCheckout: String
    }

    static func read(at path: String) async -> Identity? {
        let git = Git(path)
        guard await git.isRepository() else { return nil }
        guard let top = try? await git.output(["rev-parse", "--path-format=absolute", "--show-toplevel"]).trimmed.nilIfEmpty,
              let commonRaw = try? await git.output(["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmed.nilIfEmpty else { return nil }
        let checkout = HydraPaths.canonical(top)
        let commonURL = commonRaw.hasPrefix("/")
            ? URL(fileURLWithPath: commonRaw)
            : URL(fileURLWithPath: checkout).appendingPathComponent(commonRaw)
        let common = commonURL.standardizedFileURL.resolvingSymlinksInPath().path
        let main = (common as NSString).lastPathComponent == ".git"
            ? URL(fileURLWithPath: common).deletingLastPathComponent().resolvingSymlinksInPath().path
            : checkout
        return Identity(checkout: checkout, common: common, mainCheckout: main)
    }
}

/// One capture of a checkout's working tree, shared by the heads sent out together.
/// The heads of one delegation block ask for it within milliseconds of each other:
/// without this each head would pay for its own capture and the last one would start
/// half a minute after the first. The capture is `Git.currentTree`, so after the first
/// head of a session the tree is the checkout's watch snapshot, walked only where git
/// saw it change rather than over the whole project. A capture stands for a few seconds
/// only, and a landing into the checkout throws it away, so no head ever starts from a
/// stale tree.
@MainActor
private enum HydraTreeCache {
    private struct Capture {
        var tree: String
        var commit: String
        var capturedAt: Date
        /// The generation the checkout was in when this was taken: a capture from before
        /// a landing stands for nothing now, however recently it was made.
        var generation: UInt64
    }

    /// How long a capture stands in for the checkout: long enough for one batch to go out
    /// on it, short enough that the next head sees the checkout as it is.
    private static let lifetime: TimeInterval = 3

    private static var captures: [String: Capture] = [:]
    /// Bumped by every invalidation: a capture that began in an earlier generation is
    /// neither stored nor joined, so a landing cannot be undone in the cache by a walk
    /// that was already under way when it happened.
    private static var generations: [String: UInt64] = [:]
    /// Captures under way with the generation they began in, so heads asking at the same
    /// moment wait for the one running rather than each starting another.
    private static var inFlight: [String: (generation: UInt64, task: Task<(tree: String, commit: String), any Error>)] = [:]

    static func capture(of checkout: String, with git: Git) async throws -> (tree: String, commit: String) {
        while true {
            try Task.checkCancellation()
            let generation = generations[checkout] ?? 0
            if let ready = captures[checkout], ready.generation == generation, Date.now.timeIntervalSince(ready.capturedAt) < lifetime {
                let current = try await git.currentTree()
                try Task.checkCancellation()
                guard (generations[checkout] ?? 0) == generation else { continue }
                if current == ready.tree { return (ready.tree, ready.commit) }
            }
            if let running = inFlight[checkout], running.generation == generation {
                let made = try await running.task.value
                try Task.checkCancellation()
                guard (generations[checkout] ?? 0) == generation else { continue }
                return made
            }
            let task = Task { () async throws -> (tree: String, commit: String) in
                // The incremental snapshot path: the watch hands back the tree already
                // captured when nothing was written since, and otherwise walks only the
                // directories that changed, with the event fence and the full-walk
                // fallback it keeps (see `WorkingTreeWatch`). It is the same tree a full
                // `captureTree` makes — untracked files, deletions, index changes and
                // worktree roots included — for a fraction of the cost on a big checkout.
                let tree = try await git.currentTree()
                // The commit is the heads' starting point and no branch ever sees it, so it
                // carries no head's name: several heads share this one.
                let commit = try await git.commitTree(tree, message: "Tivano: a Hydra head's starting point")
                return (tree, commit)
            }
            inFlight[checkout] = (generation, task)
            let made: (tree: String, commit: String)
            do {
                made = try await task.value
            } catch {
                // A capture that failed or was cancelled leaves nothing behind: the next
                // head starts one of its own rather than waiting on a dead task.
                if inFlight[checkout]?.task == task { inFlight[checkout] = nil }
                throw error
            }
            if inFlight[checkout]?.task == task { inFlight[checkout] = nil }
            // A landing moved the checkout on while this walked: the tree is not the one
            // the head was sent for, so it is neither stored nor returned and the walk is
            // simply made again. Landings are one at a time, so this does not spin.
            guard (generations[checkout] ?? 0) == generation else { continue }
            captures[checkout] = Capture(tree: made.tree, commit: made.commit, capturedAt: .now, generation: generation)
            return made
        }
    }

    /// The checkout changed under the capture: the next head captures it afresh, and a
    /// capture already under way is not trusted, whatever it comes back with.
    static func invalidate(_ checkout: String) {
        captures[checkout] = nil
        generations[checkout] = (generations[checkout] ?? 0) + 1
    }
}

/// What the watchdog over the Tivano-run heads remembers between looks (see
/// `AppModel.startHydraWatchdog`): its one loop, each head's tool count at the last
/// look, the heads it has labelled as thinking, and the heads it stopped, whose reports
/// open with why.
@MainActor
private enum HydraWatchdog {
    /// How often it looks, and how long a head is quiet before it is called thinking,
    /// then stalled.
    static let tick: Duration = .seconds(30)
    static let thinkingAfter: TimeInterval = 180
    static let stalledAfter: TimeInterval = 600

    static var loop: Task<Void, Never>?
    static var toolCounts: [UUID: Int] = [:]
    static var labelled: Set<UUID> = []
    static var stalledHeadIDs: Set<UUID> = []

    static let stalledNote = "Stalled: no edits for 10 minutes; stopped by Tivano. Resend with a sharper brief."
}

extension AppModel {
    /// Whether a chat leads a team right now: Hydra on for the app (the master) and on
    /// for this chat's own switch. Helpers lead no team of their own.
    func hydraIsOn(_ thread: ChatThread) -> Bool {
        settings.hydraEnabled && thread.hydraEnabled && !thread.isHelper
    }

    /// Whether the provider defines the lead's Hydra policy at launch, in its system
    /// prompt, and switches its own sub-agent tool off there (Claude's Agent, Codex's
    /// collab agents, Copilot's task), so a lead never runs heads inside its session.
    /// Every head is Tivano-run all the same; the other CLIs take the policy per message.
    static func hydraDefinesPolicyAtLaunch(_ provider: ProviderKind) -> Bool {
        provider == .claude || provider == .codex || provider == .copilot || provider == .omp
    }

    /// The pair a chat leads with: the one picked for it in the composer's model picker,
    /// for as long as the chat stays on that pair's provider. A chat with none leads its
    /// heads on its own model and effort; no pair applies to a chat on its own.
    func hydraPair(for thread: ChatThread) -> HydraPair? {
        guard let pair = settings.hydraPair(thread.hydraPairID), pair.provider == thread.provider else { return nil }
        return pair
    }

    /// The provider a pair's heads go out on, as far as this Mac can run it: a heads'
    /// provider that is not installed or is switched off would only fail every head, so the
    /// heads stay on the lead's provider until it is.
    func hydraHeadsProvider(of pair: HydraPair) -> ProviderKind {
        guard let provider = pair.workerProvider, provider != pair.provider,
              providers.countsAsInstalled(provider), settings.isEnabled(provider) else { return pair.provider }
        return provider
    }

    /// Why a pair's heads are not on the provider the pair names, in a sentence for the
    /// lead's timeline, or nil when they are. Read when heads go out, so the user hears
    /// once per job rather than never (the fallback used to be silent).
    func hydraHeadsFallbackNote(of pair: HydraPair) -> String? {
        guard let provider = pair.workerProvider, provider != pair.provider, hydraHeadsProvider(of: pair) == pair.provider else { return nil }
        let reason = providers.status(provider).isInstalled ? "is switched off in Settings" : "is not installed on this Mac"
        return "The pair's heads run on \(pair.provider.displayName) for now: \(provider.displayName) \(reason)."
    }

    /// The effort heads inherit from a lead when the pair leaves it open: a working
    /// effort when the lead thinks above it, since a head's brief is a bounded task and
    /// the lead keeps the judgement; the lead's own effort at the working rung or below,
    /// or on a scale the lead's word is not on; nil when the lead has none. The working
    /// rung is a literal medium when the model's scale has one, else the scale's own
    /// middle rung — Z.ai's low/high/max works out at high, which its API counts as the
    /// medium effort (see `ZaiSession.reasoningEffort`).
    static func hydraHeadsEffort(leadEffort: String?, scale: [String]) -> String? {
        guard let leadEffort, !leadEffort.isEmpty else { return nil }
        guard let lead = scale.firstIndex(of: leadEffort) else { return leadEffort }
        let working = scale.firstIndex(of: "medium") ?? (scale.isEmpty ? nil : (scale.count - 1) / 2)
        guard let working else { return leadEffort }
        return lead > working ? scale[working] : leadEffort
    }

    /// What the heads run on while the chat leads, or nil with Hydra off. Without a pair
    /// the heads inherit the chat's own model, and the effort as `hydraHeadsEffort`
    /// tempers it, and go out without a cap.
    func hydraLaunch(for thread: ChatThread) -> HydraLaunch? {
        guard hydraIsOn(thread) else { return nil }
        let refs = projects.map { HydraProjectRef(name: $0.name, path: $0.path) }
        let ownRefs = refs.filter { $0.path == project(thread.projectID)?.path } + refs.filter { $0.path != project(thread.projectID)?.path }
        let pair = hydraPair(for: thread)
        let headsProvider = pair.map(hydraHeadsProvider) ?? thread.provider
        let elsewhere = headsProvider != thread.provider
        // A pair's heads' model and effort are its heads' provider's words: with the heads
        // kept on the lead's provider because that one cannot run here, they mean nothing,
        // and the heads inherit the chat's own model and effort instead.
        let keepsModel = pair.map { !$0.sendsHeadsElsewhere || elsewhere } ?? true
        var label: String?
        if elsewhere {
            let model = providers.model(pair?.workerModel, for: headsProvider) ?? providers.defaultModel(for: headsProvider)
            label = "\(model?.shortName ?? pair?.workerModel ?? "the default model") on \(headsProvider.displayName)"
        }
        let pairEffort = keepsModel ? pair?.workerEffort : nil
        let workerEffort: String?
        if let pairEffort {
            workerEffort = pairEffort
        } else if settings.hydraTempersHeadEffort, !elsewhere {
            workerEffort = Self.hydraHeadsEffort(leadEffort: thread.effort, scale: providers.model(thread.model, for: thread.provider)?.efforts ?? [])
        } else {
            workerEffort = nil
        }
        return HydraLaunch(
            headsProvider: headsProvider,
            headsLabel: label,
            workerModel: keepsModel ? pair?.workerModel : nil,
            workerEffort: workerEffort,
            // The lower of the pair's cap and the Hydra page's; with neither, the heads run uncapped.
            maxHeads: [pair?.maxHeads, settings.hydraMaxHeads].compactMap { $0 }.min(),
            headProfiles: pair?.headProfiles ?? [],
            isolatesHeads: settings.hydraIsolateHeads,
            autoMerges: settings.hydraAutoMerge,
            reviewsHeads: settings.hydraReviewHeads,
            projects: ownRefs
        )
    }

    /// The per-chat Hydra switch: off kills heads for that chat only, on restores them
    /// (with the app-wide switch on). Each flip also saves the choice as the default
    /// new threads start with.
    func setHydra(_ on: Bool, for id: UUID) {
        guard let thread = thread(id) else { return }
        guard on else {
            updateThread(id) { $0.hydraEnabled = false }
            settings.hydraDefaultEnabled = false
            return
        }
        let pair = settings.hydraPair(for: thread.provider, model: thread.model)
        updateThread(id) {
            $0.hydraEnabled = true
            $0.hydraPairID = pair?.id
        }
        settings.hydraDefaultEnabled = true
        guard let pair else { return }
        if let lead = pair.orchestratorModel, lead != thread.model, providers.model(lead, for: thread.provider) != nil {
            updateThread(id) {
                $0.model = lead
                $0.effort = pair.orchestratorEffort ?? $0.effort
            }
        } else if let effort = pair.orchestratorEffort {
            updateThread(id) { $0.effort = effort }
        }
    }

    /// The heads a lead still shows in its panel, in the order they were sent out. Read
    /// through the parent index and the heads' own cells, so the chat showing them is left
    /// alone when any other thread changes.
    func hydraHeads(of parentID: UUID) -> [ChatThread] {
        panelHeads(of: parentID)
    }

    /// How many of a lead's Tivano-run heads are still at work.
    func runningTivanoHeads(of parentID: UUID) -> Int {
        hydraHeads(of: parentID).count { $0.hydra?.kind == .tivano && $0.hydra?.status == .running }
    }

    /// How many of a lead's heads are still at work, whatever their kind.
    func runningHydraHeads(of parentID: UUID) -> Int {
        hydraHeads(of: parentID).count { $0.hydra?.status == .running }
    }

    /// How many distinct files a merge could still send for this lead: the lead's
    /// own unmerged turns and every head whose landing no merge has taken yet.
    /// Build output, paths under no sidebar project, and heads whose work was
    /// kept as a patch are left out. Feeds the merge-state note in front of
    /// the lead's messages, so it never says nothing changed while heads'
    /// files sit in the checkout.
    func hydraUnmergedFileCount(of leadID: UUID) -> Int {
        guard let runtime = existingRuntime(for: leadID) else { return 0 }
        var paths = Set(runtime.hydraUnmergedTurns.filter { $0.status != .running }.flatMap { $0.touchedPaths ?? [] })
        for head in hydraTeam(of: leadID) {
            // Only the head's own `mergedAt` says a merge took its work; a lead turn's
            // `hydraMerged` flag is not evidence of one, so no timestamp shortcut here.
            guard let info = head.hydra, info.mergedAt == nil, !(info.landing?.patchPath != nil || info.landing?.error != nil) else { continue }
            for file in info.landing?.files ?? [] { paths.insert(file.path) }
        }
        paths = paths.filter { path in !TouchedPaths.isBuildOutput(path) && projects.contains { TouchedPaths.relative(path, root: $0.path) != nil } }
        return paths.count
    }

    /// Every head a lead has sent out, in the panel or not, in the order they went.
    func hydraTeam(of parentID: UUID) -> [ChatThread] {
        children(of: parentID)
            .filter { !$0.isArchived && $0.isHydraHead }
            .sorted { ($0.hydra?.index ?? 0) < ($1.hydra?.index ?? 0) }
    }

    /// The names of a lead's Tivano-run heads still at work, other than `excluding`.
    func workingHydraHeadNames(of parentID: UUID, excluding: Set<Int> = []) -> [String] {
        hydraHeads(of: parentID)
            .filter { $0.hydra?.kind == .tivano && $0.hydra?.status == .running && !excluding.contains($0.hydra?.index ?? -1) }
            .compactMap { $0.hydra?.persona.name }
    }

    /// The checkout a lead works in: its worktree, else the project folder.
    private func hydraCheckout(of lead: ChatThread) -> String? {
        lead.worktreePath ?? project(lead.projectID)?.path
    }

    /// A sidebar project whose name equals the reference, case-insensitive, after a
    /// tilde is expanded. A path that is not itself a project's name is routed later.
    private func hydraNamedProject(_ reference: String) -> Project? {
        let expanded = (reference as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return projects.first { $0.name.caseInsensitiveCompare(expanded) == .orderedSame }
    }

    /// An explicit reference that is not a sidebar name. Nil means insert already applied
    /// the old rules: no reference, or a name that hit.
    private func hydraRouteReference(_ reference: String?) -> String? {
        guard let reference, !reference.trimmed.isEmpty, hydraNamedProject(reference) == nil else { return nil }
        return reference
    }

    /// The checkout a head's copy is made from and its work lands in. An explicit
    /// checkout wins. Older records leave it nil and keep the previous rule: the lead's
    /// own checkout for a head in the lead's project, else the head's project folder.
    private func hydraCheckout(of head: ChatThread, lead: ChatThread) -> String? {
        if let target = head.hydra?.targetCheckout, !target.isEmpty { return target }
        return head.projectID == lead.projectID ? hydraCheckout(of: lead) : project(head.projectID)?.path
    }

    /// Whether a head is still allowed to start. A stop or a delete during routing leaves
    /// it finished or gone; routing must not bring it back or launch its provider.
    private func hydraHeadCanStart(_ id: UUID) -> Bool {
        thread(id)?.hydra?.status == .running
    }

    /// Ends a head whose explicit project could not be routed, and tells its lead why.
    /// Does nothing when the head was already stopped or removed.
    @discardableResult
    private func failHydraRoute(_ id: UUID, _ message: String) -> Bool {
        guard hydraHeadCanStart(id), let parentID = thread(id)?.parentThreadID else { return false }
        runtime(for: parentID).appendHydraNote(message)
        finishHydraHead(id, status: .failed, summary: message)
        return false
    }

    /// Same-repo choice: the lead's project, else the project on the repository's main
    /// checkout, else the one added first.
    private func hydraPreferredProject(_ matches: [Project], lead: ChatThread, mainCheckout: String) -> Project? {
        guard !matches.isEmpty else { return nil }
        if let leadProject = matches.first(where: { $0.id == lead.projectID }) { return leadProject }
        if let main = matches.first(where: { HydraPaths.same($0.path, mainCheckout) }) { return main }
        return matches.min { $0.addedAt < $1.addedAt }
    }

    /// The sidebar project an explicit path belongs to, read from the project list after
    /// the git calls return. An unmatched repository is registered in the same actor
    /// turn as the final lookup.
    private func hydraProject(for identity: HydraGitIdentityReader.Identity, lead: ChatThread, headID: UUID) async -> Project? {
        func choose(from list: [Project], commons: [UUID: String]) -> Project? {
            let exact = list.filter { HydraPaths.same($0.path, identity.checkout) }
            if let chosen = hydraPreferredProject(exact, lead: lead, mainCheckout: identity.mainCheckout) { return chosen }
            let same = list.filter { commons[$0.id] == identity.common }
            return hydraPreferredProject(same, lead: lead, mainCheckout: identity.mainCheckout)
        }

        var commons: [UUID: String] = [:]
        var examined = Set<UUID>()
        while true {
            let unread = projects.filter { !examined.contains($0.id) }
            for project in unread {
                guard hydraHeadCanStart(headID) else { return nil }
                examined.insert(project.id)
                if let common = await HydraGitIdentityReader.read(at: project.path)?.common {
                    commons[project.id] = common
                }
            }
            guard hydraHeadCanStart(headID) else { return nil }
            // New projects can arrive during any git read, including the last one.
            guard projects.allSatisfy({ examined.contains($0.id) }) else { continue }
            if let chosen = choose(from: projects, commons: commons) { return chosen }
            return addProject(at: URL(fileURLWithPath: identity.checkout, isDirectory: true))
        }
    }

    /// Points a head at the project and checkout an explicit path resolved to, before
    /// any copy or provider starts. The landing checkout remains after a copy is released;
    /// a head sent somewhere else does not inherit the parent's worktree.
    private func applyHydraRoute(_ id: UUID, project chosen: Project, checkout: String, lead: ChatThread) {
        guard let head = thread(id), let parentID = head.parentThreadID, let parent = thread(parentID) else { return }
        let sameProject = chosen.id == parent.projectID
        let inherited: String?
        if sameProject {
            inherited = parent.worktreePath ?? self.project(parent.projectID)?.path
        } else {
            inherited = chosen.path
        }
        let differs = inherited.map { !HydraPaths.same($0, checkout) } ?? true
        updateThread(id) { thread in
            thread.projectID = chosen.id
            if differs {
                thread.worktreePath = nil
                thread.branch = nil
            } else if sameProject {
                thread.worktreePath = parent.worktreePath
                thread.branch = parent.branch
            } else {
                thread.worktreePath = nil
                thread.branch = nil
            }
            if !sameProject, let info = head.hydra, !info.task.isEmpty {
                var title = "\(info.persona.name) · \(TextCleanup.singleLine(info.task, limit: 60)) · \(chosen.name)"
                if let profile = info.profile { title += " · \(profile)" }
                thread.title = title
            }
        }
        updateHydraHead(id) {
            $0.targetCheckout = checkout
            $0.pendingProjectReference = nil
        }
    }

    /// Resolves an explicit path onto a sidebar project and a checkout. A linked worktree
    /// of a repository already in the sidebar reuses that project. A repository that is
    /// not reuses nothing and is added. Anything that is not a readable git checkout, and
    /// not an exact sidebar path, fails the head instead of running it in the lead's folder.
    private func routeHydraHead(_ id: UUID, reference: String) async -> Bool {
        guard hydraHeadCanStart(id), let head = thread(id), let parentID = head.parentThreadID, let lead = thread(parentID) else { return false }
        let name = head.hydra?.persona.name ?? "The head"
        let expanded = (reference as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return failHydraRoute(id, String(format: Chrome.localized("Hydra: no project named %@ is in the sidebar, so %@ did not start."), reference, name))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return failHydraRoute(id, String(format: Chrome.localized("Hydra: %@ is not a folder on this Mac, so %@ did not start."), reference, name))
        }
        guard let identity = await HydraGitIdentityReader.read(at: expanded) else {
            guard hydraHeadCanStart(id) else { return false }
            let listed = projects.filter { HydraPaths.same($0.path, expanded) }
            if let chosen = hydraPreferredProject(listed, lead: lead, mainCheckout: HydraPaths.canonical(expanded)) {
                applyHydraRoute(id, project: chosen, checkout: HydraPaths.canonical(expanded), lead: lead)
                return true
            }
            return failHydraRoute(id, String(format: Chrome.localized("Hydra: %@ is not a Git checkout Tivano can read, so %@ did not start."), reference, name))
        }
        guard hydraHeadCanStart(id) else { return false }
        if let chosen = await hydraProject(for: identity, lead: lead, headID: id) {
            guard hydraHeadCanStart(id) else { return false }
            applyHydraRoute(id, project: chosen, checkout: identity.checkout, lead: lead)
            return true
        }
        return false
    }

    // MARK: - Sending heads out

    /// Sends out a head with a session of its own, on the pair's model and effort. With
    /// isolation on and a git repository to copy, the head first gets a worktree of its
    /// own, made as it is from the checkout of the project the delegation names (the
    /// lead's own when it names none); otherwise it works in that checkout itself.
    /// `brief` writes the prompt once it is known where the head works. A `profile`
    /// naming one of the pair's head profiles runs the head on that profile's model,
    /// effort and provider instead of the pair's shared worker fields.
    @discardableResult
    func spawnTivanoHead(
        from parentID: UUID,
        task: String,
        origin: HydraHeadInfo.Origin,
        attachments: [Attachment] = [],
        batchID: UUID? = nil,
        preferredIndex: Int? = nil,
        project: String? = nil,
        profile: String? = nil,
        brief: @escaping @Sendable (HydraPersona, HydraPrompts.Workplace) -> String
    ) -> ChatThread? {
        guard let head = insertHydraHead(from: parentID, task: task, origin: origin, batchID: batchID, preferredIndex: preferredIndex, project: project, profile: profile) else { return nil }
        let route = hydraRouteReference(project)
        Task { await startTivanoHead(head.id, route: route, attachments: attachments, brief: brief) }
        return head
    }

    private func insertHydraHead(
        from parentID: UUID,
        task: String,
        origin: HydraHeadInfo.Origin,
        batchID: UUID?,
        preferredIndex: Int? = nil,
        project: String? = nil,
        profile: String? = nil
    ) -> ChatThread? {
        guard let parent = thread(parentID) else { return nil }
        // A lead with no heads left starts the roster over. The count would otherwise
        // climb for the life of the chat, and a lead that has sent out twenty-five heads
        // over a morning would name its next one "Hank 2" with one head in the panel.
        let sequential = hydraTeam(of: parentID).isEmpty ? 0 : parent.hydraSpawnCount
        // A delegation that announced its head by name is authoritative: the spawned head
        // carries exactly the announced roster name, so "Sent Gus" never spawns Otto.
        // Two heads sharing one index would merge each other's reports, so a name a
        // finished head of the team already carries goes to the next round of that name
        // ("Tova" is done, so this one is "Tova 2"), and a name a head still at work
        // carries, or an unknown one, falls back to the next free head in order. The team
        // counts finished heads too, so the fallback skips every index a pinned head ever
        // took: the counter alone would name a second Tova. The spawn count moves past
        // the index the fallback used, and by one for a pin, so ordering and future
        // names never shift for a pin: "Gus" on a fresh team does not make the next head
        // "Ezra 2".
        let team = hydraTeam(of: parentID)
        let taken = Set(team.compactMap { $0.hydra?.index })
        let rounds = HydraRoster.personas.count
        var pinned: Int?
        if let base = preferredIndex, base >= 0 {
            var candidate = base
            while taken.contains(candidate), team.contains(where: { $0.hydra?.index == candidate && $0.hydra?.isFinished == true }) {
                candidate += rounds
            }
            if !taken.contains(candidate) { pinned = candidate }
        }
        var fallback = sequential
        while taken.contains(fallback) { fallback += 1 }
        let index = pinned ?? fallback
        updateThread(parentID) { $0.hydraSpawnCount = max((pinned == nil ? index : sequential) + 1, parent.hydraSpawnCount + 1) }
        let launch = hydraLaunch(for: parent)
        // A delegation routed to one of the pair's head profiles runs on that profile's
        // model, effort and provider instead of the pair's shared worker fields; an
        // unknown profile name falls back to the shared fields, like an unrouted one.
        let routed = profile.flatMap { launch?.profile(named: $0) }
        let persona = HydraRoster.persona(at: index)
        // A name hits now. An absolute path, or a name that hits nothing, waits for the
        // startup task: git has to say which checkout it is before the head is given a
        // project, and the parent's worktree must not be copied on ahead of that.
        let named = project.flatMap(hydraNamedProject)
        let needsRoute = hydraRouteReference(project) != nil
        let target = named ?? self.project(parent.projectID)
        let sameProject = target?.id == parent.projectID

        // A head goes out on the pair's heads' provider, which may not be the lead's: there
        // it runs the pair's model or that provider's default, and the lead's model and
        // effort mean nothing to it.
        let headsProvider = routed?.provider ?? launch?.headsProvider ?? parent.provider
        let elsewhere = headsProvider != parent.provider
        var head = ChatThread(
            projectID: target?.id ?? parent.projectID,
            provider: headsProvider,
            model: routed?.model ?? launch?.workerModel ?? (elsewhere ? providers.defaultModel(for: headsProvider)?.id : parent.model),
            effort: routed?.effort ?? launch?.workerEffort ?? (elsewhere ? nil : parent.effort),
            // A Tivano-run head works in its own copy under a brief that forbids git and
            // build-output work, and its landing is a patch the lead reviews: nobody sits
            // at its chat to answer a permission prompt, so it runs with full access. Left
            // on the lead's supervised mode, a head stalled on its first gated tool until
            // the watchdog stopped it.
            runtimeMode: .fullAccess,
            fastMode: false
        )
        head.parentThreadID = parentID
        head.isInPanel = true
        head.worktreePath = needsRoute ? nil : (sameProject ? parent.worktreePath : nil)
        head.branch = needsRoute ? nil : (sameProject ? parent.branch : nil)
        if task.isEmpty {
            head.title = persona.name
        } else if !sameProject, let target {
            head.title = "\(persona.name) · \(TextCleanup.singleLine(task, limit: 60)) · \(target.name)"
        } else {
            head.title = "\(persona.name) · \(TextCleanup.singleLine(task, limit: 60))"
        }
        // A routed head wears its profile in the title: "Hank · audit the parser · deep".
        if let routed { head.title += " · \(routed.name)" }
        head.hasCustomTitle = true
        var info = HydraHeadInfo(index: index, task: task, kind: .tivano, origin: origin)
        info.tracksProviderHistory = true
        info.profile = routed?.name
        info.batchID = batchID
        info.pendingProjectReference = needsRoute ? project : nil
        info.canStop = true
        head.hydra = info
        insertThread(head)
        runtime(for: head.id).hydraStartupPending = true

        // A new head brings the panel back and takes the stage.
        let leadRuntime = runtime(for: parentID)
        leadRuntime.isHydraPanelHidden = false
        leadRuntime.hydraSelectedHeadID = head.id
        return head
    }

    /// Gives a Tivano-run head its copy of the checkout, then its brief. An explicit
    /// path is routed here, before the copy and before the provider, so a stop or a
    /// delete during that read never starts the head.
    private func startTivanoHead(_ id: UUID, route: String?, attachments: [Attachment], brief: @Sendable (HydraPersona, HydraPrompts.Workplace) -> String) async {
        var briefSent = false
        defer {
            if !briefSent { existingRuntime(for: id)?.hydraStartupPending = false }
        }
        if let route {
            guard await routeHydraHead(id, reference: route) else { return }
        }
        guard let head = thread(id), let info = head.hydra, info.status == .running,
              let parentID = head.parentThreadID, let lead = thread(parentID) else { return }
        guard let checkout = hydraCheckout(of: head, lead: lead) else {
            failHydraRoute(id, String(format: Chrome.localized("Hydra: %@ did not start because its checkout could not be read."), info.persona.name))
            return
        }
        updateHydraHead(id) { $0.targetCheckout = checkout }
        // A head on another provider than its lead, with no model chosen for it, runs that
        // provider's default: the catalogue it comes from may not have loaded yet.
        if head.provider != lead.provider, head.model == nil {
            await providers.loadCatalog(head.provider)
            if let model = providers.defaultModel(for: head.provider)?.id {
                updateThread(id) { $0.model = model }
            }
        }
        guard thread(id)?.hydra?.status == .running else { return }
        var workplace = HydraPrompts.Workplace.shared(path: checkout)
        if settings.hydraIsolateHeads, let copy = await makeHydraCopy(for: head, of: checkout) {
            updateThread(id) {
                $0.worktreePath = copy.path
                $0.branch = nil
            }
            updateHydraHead(id) { $0.baseTree = copy.tree }
            workplace = .ownCopy(path: copy.path)
        }
        // Stopped while its copy was being made: it never starts.
        guard thread(id)?.hydra?.status == .running else { return }
        let headRuntime = runtime(for: id)
        // The brief goes out now, so the head's execution begins now: whatever it waited
        // for before this (a slot, a queue, a copy of the checkout) is not its work. An
        // earlier interval is cleared, so a head steered on for another turn is timed on
        // this one.
        updateHydraHead(id) {
            $0.executionStartedAt = .now
            $0.executionFinishedAt = nil
        }
        let headBrief = brief(info.persona, workplace)
        headRuntime.sendHydraBrief(headBrief, attachments: attachments)
        briefSent = true
    }

    /// A worktree for `head` holding the checkout exactly as it is, uncommitted and
    /// untracked work included: a tree of the working files, committed on top of HEAD
    /// where no branch will ever see it, and checked out detached. Nil where the project
    /// cannot be copied (no git, no commits yet) or git refuses; the head then works in
    /// the checkout itself.
    private func makeHydraCopy(for head: ChatThread, of checkout: String) async -> (path: String, tree: String)? {
        guard let info = head.hydra, let project = project(head.projectID) else { return nil }
        // A head's work landing in the checkout right now finishes first, so the copy
        // starts from the checkout whole rather than half-way through a patch.
        if let parentID = head.parentThreadID { await existingRuntime(for: parentID)?.hydraLanding?.value }
        let git = Git(checkout)
        guard await git.isRepository(), await git.hasCommits() else { return nil }
        let folder = project.name.replacingOccurrences(of: " ", with: "-").lowercased()
        let name = info.persona.name.replacingOccurrences(of: " ", with: "-").lowercased()
        let suffix = String(head.id.uuidString.lowercased().prefix(8))
        let path = Storage.worktreesDirectory.appendingPathComponent("\(folder)-\(name)-\(suffix)").path
        do {
            // The heads of one delegation block start within milliseconds of each other
            // and want the same checkout, so they share one capture of it (see
            // `HydraTreeCache`); only the worktree itself is made per head.
            let capture = try await HydraTreeCache.capture(of: checkout, with: git)
            try await git.addDetachedWorktree(at: path, commit: capture.commit)
            return (path, capture.tree)
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
    }

    func updateHydraHead(_ id: UUID, _ change: (inout HydraHeadInfo) -> Void) {
        updateThread(id) { thread in
            guard var info = thread.hydra else { return }
            change(&info)
            thread.hydra = info
        }
    }

    // MARK: - Reporting back

    /// A head is done: its status and report land on it, and its lead hears about it. The
    /// report is relayed by the lead's runtime, which waits for the rest of a batch.
    func finishHydraHead(_ id: UUID, status: TurnStatus, summary: String?, landing: HydraLanding? = nil) {
        guard let head = thread(id), let info = head.hydra, !info.isFinished else { return }
        // A head the watchdog stopped tells its lead why, ahead of whatever it had said.
        var summary = summary
        if HydraWatchdog.stalledHeadIDs.remove(id) != nil {
            summary = [HydraWatchdog.stalledNote, summary ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        if status != .running { hydraHeadRetries[id] = nil }
        let outcome: HydraHeadInfo.Status = switch status {
        case .completed: .completed
        case .failed: .failed
        case .interrupted: .stopped
        case .running: .running
        }
        // The progress the head reported while it ran lands on the record now, once.
        let live = existingRuntime(for: id)
        updateHydraHead(id) {
            $0.status = outcome
            $0.summary = summary ?? $0.summary
            $0.finishedAt = .now
            if let landing { $0.landing = landing }
            if let live {
                if let activity = live.hydraActivity { $0.activity = activity }
                $0.toolCalls = max($0.toolCalls, live.hydraToolCalls)
                $0.tokens = max($0.tokens, live.hydraTokens)
            }
        }
        // Opt-in: a finished head leaves the panel on its own, for the sidebar under its
        // lead, instead of waiting for "Clear finished heads". Running heads stay put. It
        // goes once its panel has played the head's finish (see `HydraPanel.finishHold`),
        // not the instant it is done, and only if it is still there to clear.
        if settings.hydraAutoClearFinished {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(HydraPanel.finishHold + 0.2))
                guard let self, let head = self.thread(id), head.isInPanel, head.hydra?.isFinished == true else { return }
                self.updateThread(id) { $0.isInPanel = false }
                if let parentID = head.parentThreadID {
                    let leadRuntime = self.runtime(for: parentID)
                    if leadRuntime.hydraSelectedHeadID == id { leadRuntime.hydraSelectedHeadID = nil }
                    if leadRuntime.hydraPoppedHeadID == id { leadRuntime.hydraPoppedHeadID = nil }
                    leadRuntime.hydraAutoPopHeld.remove(id)
                    leadRuntime.hydraAutoPanelDocks[id] = nil
                    leadRuntime.panelStackOrder.removeAll { $0 == .auto(id) }
                }
            }
        }
        guard let parentID = head.parentThreadID, let finished = thread(id)?.hydra else { return }
        let leadRuntime = runtime(for: parentID)
        let copyPath = info.hasOwnCopy ? head.worktreePath : nil
        leadRuntime.hydraHeadFinished(head.id, info: finished, status: outcome, summary: summary, landing: landing, copyPath: copyPath)
        // The copy goes back only once the lead has the report, and only from a head that
        // finished: a head that was stopped or that failed hands its report the path to
        // its copy, where its half-done work is, and that folder has to still be there
        // when the lead reads it. Those copies go when the heads are cleared by hand, or
        // when the head is steered on for another turn.
        if settings.hydraAutoClearFinished, outcome == .completed {
            releaseHydraCopy(of: id)
        }
    }

    /// A Tivano-run head's turn ended: its last reply is its report, and the work in its
    /// copy lands in the lead's checkout before the lead hears of it.
    func hydraHeadTurnFinished(_ head: ChatThread, status: TurnStatus) {
        guard let info = head.hydra, info.kind == .tivano else { return }
        // The turn is over, whatever it did: the time its execution took is readable now,
        // apart from the wait in front of the landing that follows.
        updateHydraHead(head.id) { $0.executionFinishedAt = .now }
        let headRuntime = existingRuntime(for: head.id)
        // The turn that just closed. A failure is read against it alone, so an error an
        // earlier turn left behind can never be reported as this one's cause.
        let turnID = headRuntime?.turns.last(where: { $0.completedAt != nil })?.id
        // The error this turn itself recorded. Only an error-level notice in the current
        // turn counts: a warning, a note, or tool output is no failure cause.
        let error: String? = if let headRuntime, let turnID {
            headRuntime.entries.last(where: { entry in
                guard entry.turnID == turnID, case .notice(let note) = entry.item.content else { return false }
                return note.level == .error
            }).flatMap { entry -> String? in
                guard case .notice(let note) = entry.item.content else { return nil }
                return note.message
            }
        } else { nil }
        // A completed turn's report is its last reply, as ever. A failed turn's prose is
        // output it did not finish, so it is read from this turn alone.
        let spoken = headRuntime?.entries.last(where: { entry in
            guard case .assistant(let message) = entry.item.content else { return false }
            return status != .failed || (turnID != nil && entry.turnID == turnID && !message.text.trimmed.isEmpty)
        })
            .flatMap { entry -> String? in
                guard case .assistant(let message) = entry.item.content else { return nil }
                return message.text
            } ?? ""
        let report = status == .failed ? Self.failedTurnReport(error: error, partial: spoken) : spoken
        if let headRuntime {
            let tools = headRuntime.entries.count { $0.kind == .tool }
            updateHydraHead(head.id) { $0.toolCalls = tools }
        }
        // An API session is memory only, and keeping it is what lets the head be steered
        // on with its brief and its work still in mind. Normally a process goes now;
        // an eligible Codex completion keeps its exact session through landing/archive.
        // Setting off, failed turns and retry paths retain the immediate-stop behavior.
        let historySession = status == .completed ? headRuntime?.retainCodexHeadSessionForHistory() : nil
        if !head.provider.isAPIKeyBased, historySession == nil { headRuntime?.stopHeadSessionAfterProviderHistory() }
        // A head that died at the door, before a tool ran (the agent's own store locked
        // while several started at once, or its process gone before a word), is started
        // again on its brief after a short pause rather than reported as failed: the lead
        // never hears of a head that only stumbled on the way out. Two more goes, then it
        // reports the failure.
        // Classified on the turn's error, never on the prose it left behind: a head that
        // did say something before it fell over is past the door, and partial output is
        // no launch failure.
        if status == .failed, Self.isLaunchFailure(error ?? ""), let headRuntime,
           headRuntime.entries.contains(where: { $0.kind == .tool }) == false,
           hydraHeadRetries[head.id, default: 0] < 2,
           let brief = headRuntime.entries.first(where: { $0.kind == .user }).flatMap({ entry -> String? in
               guard case .user(let message) = entry.item.content else { return nil }
               return message.text
           }) {
            hydraHeadRetries[head.id, default: 0] += 1
            let attempt = hydraHeadRetries[head.id, default: 0]
            let pause = Double(attempt) * 2 + Double(info.index % 4) * 0.5
            Task {
                try? await Task.sleep(for: .seconds(pause))
                // Stopped from the panel, or steered on by hand, meanwhile: leave it.
                guard let headRuntime = existingRuntime(for: head.id), !headRuntime.isRunning,
                      thread(head.id)?.hydra?.status == .running else { return }
                headRuntime.draft = ComposerDraft(text: brief, attachments: [])
                headRuntime.send()
            }
            return
        }
        Task {
            defer {
                if let headRuntime, let historySession {
                    Task { await headRuntime.stopCompletedCodexHeadSession(historySession) }
                }
            }
            // Only finished work lands: a stopped or failed head keeps its half-done edits
            // in its copy, where a later turn can carry on from them.
            var landing: HydraLanding?
            if status == .completed, info.hasOwnCopy { landing = await landHydraHead(head.id) }
            // Landing takes seconds, and minutes behind a queue or a lead mid-turn. The
            // user may have steered the head on from the panel in that time: it is at work
            // again, so it is not finished. Marking it so would hand the lead a report for
            // a turn still running and give back the copy the head's tools are writing
            // into. It reports again when this new turn ends.
            guard !Task.isCancelled, existingRuntime(for: head.id)?.isRunning != true else { return }
            // The head reported; a report arriving on an already-finished head (the user
            // steered it on from the panel) goes to the lead as a fresh one.
            if thread(head.id)?.hydra?.isFinished == true { updateHydraHead(head.id) { $0.status = .running } }
            finishHydraHead(head.id, status: status, summary: report, landing: landing)
            if let headRuntime, let historySession {
                headRuntime.archiveCodexHeadHistory(completion: historySession)
            }
        }
    }

    /// What the lead hears of a head's failed turn: the error the turn recorded, ahead of
    /// anything the head managed to say. Its prose is named as partial output rather than
    /// passed off as the finished report, and a turn that recorded no error says so.
    private static func failedTurnReport(error: String?, partial: String) -> String {
        var parts = [error ?? "The turn failed without a recorded error."]
        let partial = partial.trimmed
        if !partial.isEmpty { parts.append("Partial output before the failure:\n\n\(partial)") }
        return parts.joined(separator: "\n\n")
    }

    /// Whether a head's failure report is the agent failing to get going at all, rather
    /// than anything about the task: its store locked, no session, or the process gone.
    private static func isLaunchFailure(_ report: String) -> Bool {
        let text = report.lowercased()
        return ["database is locked", "database locked", "sqlite_busy", "did not start a session", "the agent exited", "stopped unexpectedly"]
            .contains { text.contains($0) }
    }

    /// Carries what changed in a head's copy since its base into the lead's checkout: the
    /// patch between the two trees, applied there, three-way where the checkout has moved
    /// on. What lands moves the base forward, so a head steered on later lands only what
    /// is new; a patch that will not apply is kept as a file and the base stays.
    ///
    /// The patch is read from the head's own copy, which nothing else is touching, so
    /// heads finishing together prepare theirs side by side. Writing into the checkout is
    /// the part that goes one at a time: two patches at once would leave the later one
    /// judged against files the earlier was still changing. A patch over a file the lead
    /// is editing this very turn waits for the lead to come to rest first (see
    /// `waitForSettledCheckout`); the others do not wait for it.
    private func landHydraHead(_ id: UUID) async -> HydraLanding {
        guard let parentID = thread(id)?.parentThreadID else { return HydraLanding() }
        var landing = HydraLanding()
        let prepared: HydraPatch
        do {
            guard let made = try await prepareHydraPatch(id) else { return landing }
            prepared = made
        } catch {
            landing.error = error.localizedDescription
            return landing
        }
        landing.files = prepared.files
        landing.droppedBuildOutputFiles = prepared.droppedBuildOutputFiles
        let sharesCheckout: Bool
        if let head = thread(id), let lead = thread(parentID),
           let target = hydraCheckout(of: head, lead: lead), let leadCheckout = hydraCheckout(of: lead) {
            sharesCheckout = HydraPaths.same(target, leadCheckout)
        } else {
            sharesCheckout = true
        }
        await waitForSettledCheckout(parentID, paths: sharesCheckout ? prepared.files.map(\.path) : [])
        let leadRuntime = runtime(for: parentID)
        let previous = leadRuntime.hydraLanding
        let applied = Task<HydraLanding, Never> {
            await previous?.value
            return await self.applyHydraHead(id, landing: landing, patch: prepared)
        }
        leadRuntime.hydraLanding = Task { _ = await applied.value }
        return await applied.value
    }

    /// A head's work as a patch against the tree its copy started from, with the files it
    /// touches. Nil where the head changed nothing or has no copy to compare.
    private func prepareHydraPatch(_ id: UUID) async throws -> HydraPatch? {
        guard let head = thread(id), let info = head.hydra, let base = info.baseTree, let copy = head.worktreePath else { return nil }
        let copyGit = Git(copy)
        let after = try await copyGit.captureTree()
        guard after != base else { return nil }
        let work = try await Self.hydraWork(in: copyGit, from: base, to: after)
        guard !work.paths.isEmpty else { return nil }
        let text = try await copyGit.diff(from: base, to: after, binary: true, paths: work.paths)
        guard !text.isEmpty else { return nil }
        // A binary patch runs to megabytes, and parsing it counts every line: off the
        // main actor, so the chat keeps streaming while a head lands.
        return await Task.detached(priority: .utility) {
            let files = DiffParser.parse(text).map {
                HydraLanding.File(path: $0.path, additions: $0.additions, deletions: $0.deletions)
            }
            return HydraPatch(
                text: text,
                files: files,
                droppedBuildOutputFiles: work.droppedBuildOutputFiles,
                after: after
            )
        }.value
    }

    /// The files a head changed in its copy between two trees that are its work: build
    /// output and tool caches (see `TouchedPaths.isBuildOutput`) are left out, and
    /// counted. They are cut from the list before any patch is made rather than from the
    /// patch afterwards: a copy that built the app holds hundreds of megabytes of them
    /// where the project's .gitignore missed them, which was minutes of git, and as much
    /// memory, for a patch of a few source files. A Command Code head writes its taste
    /// file into its copy on every run, so without this every one of them "changed
    /// something".
    private static func hydraWork(in copyGit: Git, from base: String, to after: String) async throws -> (paths: [String], droppedBuildOutputFiles: Int) {
        let changed = try await copyGit.changedPaths(from: base, to: after)
        let paths = changed.filter { !TouchedPaths.isBuildOutput($0) }
        return (paths, changed.count - paths.count)
    }

    /// Waits for the lead's checkout to be a safe place to write: the lead is not in the
    /// middle of a turn that has already edited one of `paths` (a three-way merge would
    /// leave conflict markers in a file the lead is still writing), and the team's work is
    /// not on its way to the remote. Gives up after half an hour and lands anyway, so a
    /// head's work is never lost to a lead that never comes to rest.
    private func waitForSettledCheckout(_ parentID: UUID, paths: [String]) async {
        guard let leadRuntime = existingRuntime(for: parentID) else { return }
        // The runtime keeps the files the lead's current turn has touched, so the check is
        // a set intersection rather than a walk of the turn's timeline on every look: the
        // landing waits here up to half an hour, at four looks a second.
        let wanted = Set(paths)
        let deadline = Date.now.addingTimeInterval(30 * 60)
        while Date.now < deadline {
            let busy = leadRuntime.phase != .idle && !wanted.isEmpty
                && !wanted.isDisjoint(with: leadRuntime.hydraCurrentTurnTouchedPaths)
            guard busy || leadRuntime.isHydraMerging else { return }
            // A cancelled task's sleep throws at once, without suspending: swallowing
            // that would turn this into a tight loop on the main actor for the rest of
            // the half hour, with the whole app frozen behind it. The landing goes ahead
            // instead, as it does at the deadline.
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
        }
    }

    private func applyHydraHead(_ id: UUID, landing: HydraLanding, patch: HydraPatch) async -> HydraLanding {
        var landing = landing
        guard let head = thread(id), let info = head.hydra,
              let parentID = head.parentThreadID, let lead = thread(parentID), let checkout = hydraCheckout(of: head, lead: lead) else { return landing }
        // The application begins here, after the queue in front of it has cleared (the
        // caller waits for the previous landing first), and ends when this returns, however
        // it goes. A landing that never got this far keeps neither stamp, so an unreadable
        // interval is not mistaken for a fast one.
        updateHydraHead(id) { $0.landingStartedAt = .now; $0.landingFinishedAt = nil }
        defer { updateHydraHead(id) { $0.landingFinishedAt = .now } }
        let checkoutGit = Git(checkout)
        // A rebase or a merge is half done in the checkout: a patch laid on top of that
        // would be impossible to tell from the operation's own conflicts, and resolving
        // either would lose the other. The work waits as a patch file instead.
        guard !(await checkoutGit.hasOperationInProgress()) else {
            landing.patchPath = keepHydraPatch(patch.text, of: info, headID: head.id)
            landing.error = "a rebase or merge is underway in the checkout, or its git state cannot be read"
            noteHydraLanding(landing, of: info, to: parentID)
            return landing
        }
        do {
            landing.conflicts = try await checkoutGit.apply(patch.text)
            // Only a clean landing moves the base. With conflict markers in the checkout
            // the work is not settled, so the head keeps its whole diff: steered on, it
            // offers all of it again rather than leaving the unresolved part to nobody.
            if landing.conflicts.isEmpty { updateHydraHead(id) { $0.baseTree = patch.after } }
        } catch {
            landing.patchPath = keepHydraPatch(patch.text, of: info, headID: head.id)
            landing.error = error.localizedDescription
        }
        // The checkout has moved, so the next head captures it afresh rather than starting
        // from the tree this patch just changed.
        HydraTreeCache.invalidate(checkout)
        // The lead's changes tab and diff panel now show the head's work too.
        existingRuntime(for: parentID)?.noteDiffChanged()
        noteHydraLanding(landing, of: info, to: parentID)
        return landing
    }

    /// Keeps a patch that could not be applied as a file beside the others, and hands back
    /// where it went; nil when even that failed.
    private func keepHydraPatch(_ text: String, of info: HydraHeadInfo, headID: UUID) -> String? {
        let slug = info.persona.name.replacingOccurrences(of: " ", with: "-").lowercased()
        let url = Storage.patchesDirectory.appendingPathComponent("\(slug)-\(headID.uuidString.lowercased().prefix(8)).patch")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }

    /// A landing that did not go cleanly says so in the lead's timeline: conflict markers
    /// and kept patches are otherwise only a few words in a head's row, and the lead is
    /// told not to look at git status, so nobody would see them.
    private func noteHydraLanding(_ landing: HydraLanding, of info: HydraHeadInfo, to parentID: UUID) {
        guard let leadRuntime = existingRuntime(for: parentID) else { return }
        let name = info.persona.name
        if !landing.conflicts.isEmpty {
            let files = landing.conflicts.map { "`\($0)`" }.joined(separator: ", ")
            // Worded as what happens next, not as damage: the lead settles the markers
            // before anything goes out, so the reader has nothing to do.
            leadRuntime.appendHydraNote("""
            \(name)'s work landed; the lead is settling a conflict in \(landing.conflicts.count == 1 ? "1 file" : "\(landing.conflicts.count) files").
            \(files)

            The checkout had moved on where \(name) was working, so the merge was three-way and left markers in \(landing.conflicts.count == 1 ? "this file" : "these files"). The lead resolves them before the work goes out; nothing to do on your side.
            """)
        }
        if let path = landing.patchPath {
            let files = landing.files.map { "`\($0.path)`" }.joined(separator: ", ")
            leadRuntime.appendHydraNote("""
            \(name)'s work did not land and was kept as a patch.
            \(files)

            \(landing.error.map { "Why it did not land: \($0).\n\n" } ?? "")Apply it with `git apply --3way \(path)` and settle what conflicts.
            """)
        }
    }

    // MARK: - Stopping and clearing

    /// Stops a head where it runs: its own turn. A native head from an older version is
    /// long gone with the session it ran in, and is only marked stopped.
    func stopHydraHead(_ id: UUID) {
        guard let head = thread(id), let info = head.hydra, !info.isFinished else { return }
        switch info.kind {
        case .tivano:
            if let headRuntime = existingRuntime(for: id), headRuntime.isRunning {
                headRuntime.interrupt()
            } else {
                // Not started yet, its copy still being made: it never will.
                finishHydraHead(id, status: .interrupted, summary: nil)
            }
        case .native:
            finishHydraHead(id, status: .interrupted, summary: nil)
        }
    }

    /// Stops every head of a lead's still at work.
    func stopAllHydraHeads(of parentID: UUID) {
        for head in hydraHeads(of: parentID) where head.hydra?.status == .running {
            stopHydraHead(head.id)
        }
    }

    /// Clears the panel: finished heads move under the lead in the sidebar, and the panel
    /// stays out of the way until the next head starts. Running heads keep working.
    func dismissHydraHeads(of parentID: UUID) {
        clearFinishedHydraHeads(of: parentID)
        let leadRuntime = runtime(for: parentID)
        leadRuntime.isHydraPanelHidden = true
        leadRuntime.hydraSelectedHeadID = nil
        leadRuntime.hydraPoppedHeadID = nil
        leadRuntime.hydraAutoPopHeld.removeAll()
        leadRuntime.hydraAutoPanelDocks.removeAll()
        leadRuntime.panelStackOrder.removeAll { if case .auto = $0 { return true }; return false }
    }

    /// Finished heads leave the panel for the sidebar, and give their copies back.
    func clearFinishedHydraHeads(of parentID: UUID) {
        for head in hydraHeads(of: parentID) where head.hydra?.isFinished == true {
            updateThread(head.id) { $0.isInPanel = false }
            releaseHydraCopy(of: head.id)
        }
    }

    /// Removes the copy of the checkout a head worked in. Its work has landed, or its
    /// patch is kept; a head talked to afterwards works in the checkout itself.
    /// `targetCheckout` is that checkout when the head was sent to one, and is not a
    /// copy, so it stays after the copy path and `baseTree` are cleared.
    func releaseHydraCopy(of id: UUID) {
        guard !libraryWritesBlocked, let head = thread(id), let info = head.hydra, info.hasOwnCopy,
              let copy = head.worktreePath else { return }
        let runtime = existingRuntime(for: id)
        Task { [weak self] in
            guard let self else { return }
            await runtime?.waitForProviderHistory()
            guard !libraryWritesBlocked, thread(id)?.hydra == info, thread(id)?.worktreePath == copy,
                  existingRuntime(for: id) === runtime else { return }
            await releaseHydraCopyAfterHistory(of: id, info: info, copy: copy)
        }
    }

    private func releaseHydraCopyAfterHistory(of id: UUID, info: HydraHeadInfo, copy: String) async {
        guard !libraryWritesBlocked, let head = thread(id), head.hydra == info, head.worktreePath == copy,
              info.hasOwnCopy, info.isFinished,
              let project = project(head.projectID),
              existingRuntime(for: id)?.isRunning != true,
              existingRuntime(for: id)?.isHydraMerging != true else { return }
        let copyURL = URL(fileURLWithPath: copy).resolvingSymlinksInPath().standardizedFileURL
        let managed = Storage.worktreesDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard copyURL.path.hasPrefix(managed),
              !projects.contains(where: {
                  let path = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path
                  return path == copyURL.path || path.hasPrefix(copyURL.path + "/")
              }),
              info.targetCheckout.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == copyURL }) != true,
              !threads.contains(where: { $0.id == head.parentThreadID && $0.worktreePath == copy }) else { return }
        let runtime = existingRuntime(for: id)
        let directory = head.executionDirectory(projectPath: project.path)
        let workIsPreserved = info.landing.map { landing in
            landing.landed || landing.isEmpty
                || landing.patchPath.map { FileManager.default.fileExists(atPath: $0) } == true
        } ?? false
        if info.status != .completed || !workIsPreserved {
            guard let base = info.baseTree,
                  await keepHydraCopyAsPatch(id, name: info.persona.name, copy: copy, base: base) else {
                alert = AppAlert(title: "Could not remove worktree", message: Chrome.localized("The head's unfinished work could not be preserved. Its copy was kept so you can retry."))
                return
            }
        }
        guard !libraryWritesBlocked, thread(id)?.hydra == info, thread(id)?.worktreePath == copy,
              existingRuntime(for: id) === runtime,
              runtime?.isRunning != true, runtime?.isHydraMerging != true else { return }
        runtime?.stopSession()
        do {
            let root = try await Git(directory).repositoryRoot()
            guard !libraryWritesBlocked, thread(id)?.hydra == info, thread(id)?.worktreePath == copy,
                  existingRuntime(for: id) === runtime,
                  runtime?.isRunning != true, runtime?.isHydraMerging != true else { return }
            try await Git(root.path).removeWorktree(at: copy)
            // A restarted head may now own another copy, even on the same thread.
            guard !libraryWritesBlocked, thread(id)?.hydra == info, thread(id)?.worktreePath == copy,
                  existingRuntime(for: id) === runtime,
                  runtime?.isRunning != true, runtime?.isHydraMerging != true else { return }
            updateThread(id) {
                $0.worktreePath = nil
                $0.branch = nil
                $0.hydra?.baseTree = nil
            }
        } catch {
            alert = AppAlert(title: "Could not remove worktree", message: error.localizedDescription)
        }
    }

    /// Writes what a head changed in its copy but never landed to a patch file, and tells
    /// the lead where it went. Nothing to keep where the copy holds no changes of its own.
    private func keepHydraCopyAsPatch(_ id: UUID, name: String, copy: String, base: String) async -> Bool {
        let copyGit = Git(copy)
        // A copy that differs from its base only by build output, or by the cache the
        // head's own tool wrote there, holds no work of the head's: nothing to keep, and
        // nothing to tell the lead. Sixteen heads cleared together once put sixteen of
        // these notes into the lead's chat over five minutes, for 4 GB of build output.
        guard let after = try? await copyGit.captureTree() else { return false }
        if after == base { return true }
        guard let work = try? await Self.hydraWork(in: copyGit, from: base, to: after) else { return false }
        if work.paths.isEmpty { return true }
        guard let patch = try? await copyGit.diff(from: base, to: after, binary: true, paths: work.paths), !patch.isEmpty else { return false }
        let slug = name.replacingOccurrences(of: " ", with: "-").lowercased()
        let url = Storage.patchesDirectory.appendingPathComponent("\(slug)-\(id.uuidString.lowercased().prefix(8))-unlanded.patch")
        guard (try? patch.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        guard let parentID = thread(id)?.parentThreadID, let leadRuntime = existingRuntime(for: parentID) else { return true }
        leadRuntime.appendHydraNote("""
        \(name)'s unfinished work was kept as a patch before its copy was cleared.
        \(url.path)

        Nothing of it had landed in your checkout. Apply it with `git apply --3way \(url.path)` if you still want it.
        """)
        return true
    }

    // MARK: - Watchdog

    /// Keeps an eye on the Tivano-run heads at work, every half minute. One quiet for
    /// three minutes (no tool, no word of a reply) says so in its row, "Thinking for 3
    /// min…", rather than sitting on its last tool; one quiet for ten with nothing edited
    /// and no tool since the last look has stalled, and is stopped the way the panel's
    /// Stop stops it, with a report that opens by telling the lead why (see
    /// `finishHydraHead`). One loop for the app; calling this again does nothing.
    func startHydraWatchdog() {
        guard HydraWatchdog.loop == nil else { return }
        HydraWatchdog.loop = Task { [weak self] in
            defer { HydraWatchdog.loop = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: HydraWatchdog.tick)
                guard !Task.isCancelled, let self else { return }
                self.watchHydraHeads()
            }
        }
    }

    /// One look at the heads: the label goes on and comes off, a stalled head is stopped.
    private func watchHydraHeads() {
        var toolCounts: [UUID: Int] = [:]
        for head in threads where head.isHydraHead && head.hydra?.kind == .tivano && head.hydra?.status == .running {
            guard let headRuntime = existingRuntime(for: head.id), headRuntime.isRunning else { continue }
            let idle = headRuntime.hydraIdleSeconds
            let tools = headRuntime.hydraToolCalls
            toolCounts[head.id] = tools
            let hasRunningTool = headRuntime.entries.contains {
                if case .tool(let tool) = $0.item.content { return tool.status == .running }
                return false
            }
            if hasRunningTool {
                if HydraWatchdog.labelled.remove(head.id) != nil, headRuntime.hydraActivity?.hasPrefix("Thinking for ") == true {
                    headRuntime.hydraActivity = nil
                }
                continue
            }
            if idle >= HydraWatchdog.stalledAfter, headRuntime.hydraEditCount == 0, HydraWatchdog.toolCounts[head.id] == tools {
                HydraWatchdog.stalledHeadIDs.insert(head.id)
                HydraWatchdog.labelled.remove(head.id)
                stopHydraHead(head.id)
                continue
            }
            if idle >= HydraWatchdog.thinkingAfter {
                // Written only when the minute changes, so the row is not redrawn each look.
                let label = "Thinking for \(Int(idle / 60)) min…"
                if headRuntime.hydraActivity != label { headRuntime.hydraActivity = label }
                HydraWatchdog.labelled.insert(head.id)
            } else if HydraWatchdog.labelled.remove(head.id) != nil, headRuntime.hydraActivity?.hasPrefix("Thinking for ") == true {
                // Back at work: the label comes off, and the row says "working" again.
                headRuntime.hydraActivity = nil
            }
        }
        HydraWatchdog.toolCounts = toolCounts
        HydraWatchdog.labelled.formIntersection(toolCounts.keys)
    }

    /// Heads whose copies are gone from disk (deleted by hand, say) work in the checkout
    /// from now on, instead of failing every tool call. The copy path and `baseTree` are
    /// cleared; an explicit `targetCheckout` stays, so the next turn does not fall back
    /// to the project folder. Unclaimed copies remain in Storage.worktreesDirectory for
    /// recovery: missing chat metadata cannot prove that a copy's work landed, even when
    /// its working directory is clean.
    func sweepHydraCopies() {
        // Copies deleted from disk still hold their names in the registry until pruned:
        // only the projects that ever had a copy, one git process at a time.
        let projects = self.projects
        let projectsWithCopies = Set(threads.filter { $0.hydra?.hasOwnCopy == true }.map(\.projectID))
        Task {
            for project in projects where projectsWithCopies.contains(project.id) { await Git(project.path).pruneWorktrees() }
        }
        for head in threads where head.hydra?.hasOwnCopy == true {
            guard let copy = head.worktreePath, !FileManager.default.fileExists(atPath: copy) else { continue }
            updateThread(head.id) {
                $0.worktreePath = nil
                $0.branch = nil
            }
            updateHydraHead(head.id) { $0.baseTree = nil }
        }
        startHydraWatchdog()
    }

    /// What a head sent out from the queue is told about the main chat: the user's last
    /// request, the lead's latest reply and the files it has touched this turn. Read from
    /// the timeline, so it costs no model call.
    func hydraChatContext(for parentID: UUID) -> HydraPrompts.ChatContext {
        guard let leadRuntime = existingRuntime(for: parentID) else { return HydraPrompts.ChatContext() }
        var context = HydraPrompts.ChatContext()
        for entry in leadRuntime.entries.reversed() {
            switch entry.item.content {
            case .user(let message) where context.lastUserPrompt == nil && !message.isFromHydra:
                context.lastUserPrompt = message.text
            case .assistant(let message) where context.lastReply == nil:
                context.lastReply = message.text
            default:
                break
            }
            if context.lastUserPrompt != nil, context.lastReply != nil { break }
        }
        let currentTurn = leadRuntime.turns.last?.id
        var touched: [String] = []
        var seen: Set<String> = []
        for entry in leadRuntime.entries where entry.kind == .tool && entry.item.turnID == currentTurn {
            guard case .tool(let call) = entry.item.content else { continue }
            for edit in call.edits where !edit.path.isEmpty && seen.insert(edit.path).inserted {
                touched.append(edit.path)
            }
        }
        context.touchedPaths = touched
        return context
    }
}
