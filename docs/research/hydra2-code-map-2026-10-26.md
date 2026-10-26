# Hydra 2.0 Labs: code map

2026-10-26 · Walter · source inspection only. Only this research document is created; no application changes, builds, tests, Git operations or runtime checks. Anchors refer to the delegated worktree's source. Proposed hooks are not implemented behavior.

## 1. Lead policy, delegation budget and reports

### Assembly and delivery

- `Tivano/App/AppModel+Hydra.swift:179` — `static func hydraDefinesPolicyAtLaunch(_ provider: ProviderKind) -> Bool` returns true for **Claude, Codex, Copilot and OMP**. Nearby comments omit OMP; the predicate includes it.
- `Tivano/App/Runtime/ThreadRuntime.swift:1888` — `private static func keepsHydraPolicyInSystemPrompt(_ provider: ProviderKind) -> Bool` also includes API-key providers. `Tivano/Core/Models/Provider.swift:205` identifies those as DeepSeek, Meta and Z.ai.
- `Tivano/Core/Models/Hydra.swift:762` — `static func fallbackPolicy(maxHeads: Int?, isolated: Bool, autoMerges: Bool = false, reviewsHeads: Bool = false, heads: String? = nil, projects: [HydraProjectRef] = [], profiles: [HydraHeadProfile] = []) -> String` builds the standing policy; `fallbackPolicy(_ launch: HydraLaunch)` at :797 forwards launch values. The threshold is prose (“anything bigger than a single obvious change to a single file”), reinforced by `delegationRequest(_:)` at :850; there is no executable per-pair classifier.
- `Tivano/App/Runtime/ThreadRuntime.swift:1974` — `private func ensureSession(allowNewSession: Bool = true, dshFinalReport: Bool = false) async throws -> any ProviderSession` obtains `hydraLaunch(for:)` at :1995, includes it and `hydraPairID` in `SessionSignature` (:2008–2009), then passes it through `SessionConfiguration` (:2120). A policy mode must participate in the signature or a live session can retain its old policy.
- `Tivano/Services/Providers/ClaudeSession.swift:83` — `func start() async throws -> String` calls policy at :109, disables `Agent`/`Task` (:110), and combines policy with anti-slop guidance in `--append-system-prompt` (:115). It disables system-prompt snapshots when supported so resumed sessions get current settings.
- `Tivano/Services/Providers/CodexSession.swift:282` — thread parameter assembly sets `features.multi_agent` and `features.multi_agent_v2` false and `developerInstructions = HydraPrompts.fallbackPolicy(hydra)` (:287). Voice instructions can replace this at :289–291; `Tivano/App/AppModel+Voice.swift:49` separately supplies `fallbackPolicy` to the voice context.
- `Tivano/Services/Providers/CopilotSession.swift:123` — `private func sessionParameters() -> [String: JSONValue]` builds policy at :143, excludes `task`, and appends `systemMessage` (:148). `Tivano/Services/Providers/OmpSession.swift:115` — `private var systemPrompt: String` combines Hydra, anti-slop and plan-mode instructions; `start()` (:127) sends `--append-system-prompt` (:167).
- `Tivano/Services/Providers/OpenAICompatibleSession.swift:1219` — system-prompt assembly uses `configuration.hydra.map(HydraPrompts.fallbackPolicy)` and appends project guidance. This function-reference use is a caller as well as the direct calls.
- `Tivano/App/Runtime/ThreadRuntime.swift:1799` — `startTurn(text:attachments:hydraHeads:hydraBrief:externalTurnID:)` reads launch/team/merge state. System-policy providers get turn/report notes; every other CLI gets `fallbackPreamble` or `fallbackReportPreamble` (full policy plus note). Ordinary user turns additionally get `delegationRequest` (:1814); automatic report turns do not. `session.send(TurnInput(text: prompt, ...))` at :1846 sends the result.

**V2 seam:** select policy through a resolved, stamped launch value; preserve v1 policy as the default. Standing policy, user-turn delegation request and report-turn instructions must agree, including current restrictions against delegating head review.

### Budget enforcement

`Tivano/Core/Models/Hydra.swift:732` defines `maxDelegationRounds = 3`; `HydraDelegationBudget.canDelegate` (:603) compares `rounds` with it. `beginTurn(userAuthored:)` (:609), called by `ThreadRuntime` at :1671 with `hydraHeads == nil`, resets only on user-authored turns, not automatic reports/refusals.

`private func spawnDelegatedHeads(for turnID: UUID) -> DelegationOutcome` (`ThreadRuntime.swift:3706`) refuses exhausted complete blocks at :3772 and charges at :3779. Streaming dispatch at :3871–3877 charges once on the first usable entry, then permits the existing stream; end-of-stream catch-up at :3730 separately checks `canDelegate`, which needs care if changing the budget. `maxDelegatedTasks = 32` (:3656) limits block size; `HydraLaunch.hasRoom(running:)` (`Hydra.swift:173`) controls concurrency and uses 8 when `maxHeads` is nil, despite older “uncapped” comments.

### Reports: building, batching and exact templates

`Tivano/App/Runtime/ThreadRuntime.swift:3570` — `func hydraHeadFinished(_ headID: UUID, info: HydraHeadInfo, status: HydraHeadInfo.Status, summary: String?, landing: HydraLanding? = nil, copyPath: String? = nil, provider: String? = nil, startupFailure: Bool = false)` builds `HydraReport` and replaces pending reports for that head index. `settleBatches()` (:3608) waits for pending heads and queued delegations; `flushHydraReports()` (:3619) schedules `startHydraReportTurn()` (:3638), which builds text at :3649 and calls `startTurn(..., hydraHeads: reports.map(\.headIndex))` at :3651.

The body starts **“Hydra reports:”**, not “[Hydra]”. The latter comes from `fallbackReportNote` during `startTurn`; non-system-policy CLIs also receive standing policy before that note. Exact Swift templates follow, including conditional text and interpolation expressions.

#### Team status — `Tivano/Core/Models/Hydra.swift:736`

```swift
    static func teamStatus(_ heads: [HydraHeadInfo], now: Date = .now) -> String? {
        guard !heads.isEmpty else { return nil }
        let parts = heads.map { info -> String in
            let name = info.persona.name
            switch info.status {
            case .running:
                let minutes = Int(now.timeIntervalSince(info.startedAt) / 60)
                return "\(name) (working\(minutes > 0 ? " for \(minutes)m" : ""))"
            case .completed:
                if let landing = info.landing {
                    if landing.isEmpty { return "\(name) (done, changed nothing)" }
                    if landing.landed { return "\(name) (done, landed \(landing.files.count == 1 ? "1 file" : "\(landing.files.count) files"))" }
                    return "\(name) (done, patch kept)"
                }
                return "\(name) (done)"
            case .failed: return "\(name) (failed)"
            case .stopped: return "\(name) (stopped)"
            }
        }
        return "Your heads so far: " + parts.joined(separator: ", ") + "."
    }
```

#### Turn/report prefix — `Tivano/Core/Models/Hydra.swift:863`

```swift
    static func fallbackTurnNote(team: String?, merge: String? = nil) -> String {
        let parts = [team, merge].compactMap { $0 }
        guard !parts.isEmpty else { return "" }
        return "[Hydra] " + parts.joined(separator: " ") + "\n\n---\n\n"
    }

    /// In front of a report message: the heads are back, and the lead's job is to
    /// finish, not to send out more. `canDelegate` says a round of heads is still left
    /// for what failed or turned out to be missing; otherwise the block is not offered.
    static func fallbackReportNote(team: String?, merge: String? = nil, canDelegate: Bool) -> String {
        let more = canDelegate
            ? "If the reports open up the next stage of the work, or a head failed, or a piece of the user's request is still undone, send heads out again for exactly that, with the same ```hydra block at the end of your reply; never for verifying, redoing or finishing what a head already did."
            : "Send out no more heads for this request; whatever is left, do yourself."
        return "[Hydra] Your heads reported back below." + (team.map { " " + $0 } ?? "") + (merge.map { " " + $0 } ?? "") + " " + more + "\n\n---\n\n"
    }

```

#### Report body — `Tivano/Core/Models/Hydra.swift:1160`

```swift
    static func reportMessage(_ reports: [HydraReport], stillWorking: [String] = [], reviewsHeads: Bool = false) -> String {
        let names = reports.map { HydraRoster.persona(at: $0.headIndex).name }
        var opening = "Hydra reports: \(list(names)) finished."
        if !stillWorking.isEmpty {
            opening += " \(list(stillWorking)) \(stillWorking.count == 1 ? "is" : "are") still at work; \(stillWorking.count == 1 ? "its report comes" : "their reports come") as a later message."
        }

        // Heads that failed to start on one provider with the same error share one cause;
        // the lead hears it once, so it does not read N failures as N tasks to send again.
        var startupGroups: [String: [HydraReport]] = [:]
        var startupProviders: [String] = []
        for report in reports where report.status == .failed && report.startupFailure {
            let provider = report.provider ?? "their provider"
            if startupGroups[provider] == nil { startupProviders.append(provider) }
            startupGroups[provider, default: []].append(report)
        }
        var firstWithError: [String: String] = [:]

        var sections: [String] = []
        for report in reports {
            let persona = HydraRoster.persona(at: report.headIndex)
            let outcome = switch report.status {
            case .completed: ""
            case .failed: " (failed)"
            case .stopped: " (stopped by the user before finishing)"
            case .running: ""
            }
            var effort: [String] = []
            if let elapsed = report.elapsed, elapsed >= 1 { effort.append(duration(elapsed)) }
            if report.toolCalls > 0 { effort.append(report.toolCalls == 1 ? "1 tool" : "\(report.toolCalls) tools") }
            let took = effort.isEmpty ? "" : " (" + effort.joined(separator: ", ") + ")"
            var lines = ["## \(persona.name): \(report.task)\(outcome)\(took)"]
            if let landing = landingLine(for: report) { lines.append(landing) }
            let body = report.text.trimmed
            if report.status == .failed, report.startupFailure, !body.isEmpty {
                let key = (report.provider ?? "") + "\u{0}" + body
                if let first = firstWithError[key] {
                    lines.append("Same startup failure as \(first).")
                    sections.append(lines.joined(separator: "\n"))
                    continue
                }
                firstWithError[key] = persona.name
            }
            lines.append(body.isEmpty ? "No report." : body)
            sections.append(lines.joined(separator: "\n"))
        }

        var closing: [String] = []
        if reports.contains(where: { $0.landing?.landed == true }) {
            closing.append("The changes listed above are in your checkout already; nothing needs applying.")
        }
        if reports.contains(where: { $0.copyPath == nil && $0.status == .completed }) {
            closing.append("The heads worked in your checkout, so their changes are there already.")
        }
        if reports.contains(where: { !($0.landing?.conflicts.isEmpty ?? true) }) {
            closing.append("A file listed with conflicts was merged three-way and keeps conflict markers: resolve those first, and tell the user in one line that you settled them, so the landing card above does not read as broken.")
        }
        // Two heads on one file is the split the lead was told not to make; it hears
        // which file, so it reads the result instead of trusting it.
        var owners: [String: [String]] = [:]
        for report in reports {
            for file in report.landing?.files ?? [] {
                owners[file.path, default: []].append(HydraRoster.persona(at: report.headIndex).name)
            }
        }
        for (path, names) in owners.sorted(by: { $0.key < $1.key }) where names.count > 1 {
            closing.append("\(list(names)) both changed \(path): read it as it is now before you build on it.")
        }
        for report in reports {
            guard let landing = report.landing, let path = landing.patchPath else { continue }
            closing.append("\(HydraRoster.persona(at: report.headIndex).name)'s changes would not apply on their own; the patch is at \(path). Apply it with `git apply --3way \(path)` and settle what conflicts.")
        }
        for provider in startupProviders {
            let names = (startupGroups[provider] ?? []).map { HydraRoster.persona(at: $0.headIndex).name }
            let providerReports = reports.filter { ($0.provider ?? "their provider") == provider }
            if providerReports.contains(where: { $0.status == .completed }) {
                closing.append("\(list(names)) failed on \(provider) before doing any work while other heads on \(provider) succeeded, so the failure is likely temporary: you may send their parts to \(provider) again or do them yourself.")
            } else if !providerReports.contains(where: { $0.status == .running }) {
                let one = names.count == 1
                closing.append("\(list(names)) failed on \(provider) before doing any work. The cause is \(provider)'s environment (its install, sign-in, configuration or MCP servers), not the task: sending heads to \(provider) again fails the same way. Do \(one ? "its part" : "their parts") yourself, and tell the user in one line the error above and that it needs fixing on \(provider)'s side.")
            }
        }
        if reports.contains(where: { $0.status == .failed && !$0.startupFailure }) {
            closing.append("A head that failed leaves its part to you: do it yourself or send it out again.")
        }
        if reports.contains(where: { $0.status == .stopped }) {
            closing.append("A head the user stopped leaves its part alone unless the user asks for it.")
        }
        if reports.contains(where: { $0.origin == .queued }) {
            closing.append("The user queued that work for the heads while you were busy; take it into account and carry on with the main job.")
        }
        if reports.contains(where: { $0.origin == .sent }) {
            closing.append("The user sent that work straight to the heads instead of to you; take it into account, and reply to the user on it as if they had asked you.")
        }
        // With the check on, the lead reads every file listed rather than only the ones
        // that matter, and fixes what it finds itself.
        if reviewsHeads {
            closing.append("Do not check any of this with git status or git diff: the checkout changes under you while heads work, and the user may be editing too. Do not reconcile or revert anything. " + reviewRule)
        } else {
            closing.append("Do not check any of this with git status or git diff: the checkout changes under you while heads work, and the user may be editing too. Do not reconcile, revert or redo anything. Build on the reports, read the files they name if something matters, run one verification if it matters, and finish the job.")
        }
        closing.append(reportStyleRule)
        if !stillWorking.isEmpty {
            closing.append("Do not wait for \(list(stillWorking)) and do not take over \(stillWorking.count == 1 ? "its" : "their") tasks; tell the user \(stillWorking.count == 1 ? "it is" : "they are") still at work and that you will hear from \(stillWorking.count == 1 ? "it" : "them").")
        }

        return """
        \(opening)

        \(sections.joined(separator: "\n\n"))

        \(closing.joined(separator: " "))
        """
    }
```

#### Landing line — `Tivano/Core/Models/Hydra.swift:1277`

```swift
    private static func landingLine(for report: HydraReport) -> String? {
        guard let landing = report.landing else {
            guard let path = report.copyPath else { return nil }
            return report.status == .completed ? "Changed nothing." : "Nothing landed; its unfinished work is in its copy at \(path)."
        }
        if landing.isEmpty { return "Changed nothing." }
        let files = landing.files.prefix(25).map { file -> String in
            var line = "\(file.path) (+\(file.additions) −\(file.deletions))"
            if landing.conflicts.contains(file.path) { line += " with conflicts" }
            return line
        }
        let listed = files.joined(separator: ", ")
            + (landing.files.count > 25 ? ", and \(landing.files.count - 25) more" : "")
        let omitted = landing.droppedBuildOutputFiles == 0 ? "" : "; \(landing.droppedBuildOutputFiles) build-output file\(landing.droppedBuildOutputFiles == 1 ? " was" : "s were") left out"
        if landing.patchPath != nil { return "Did not land: \(listed)\(omitted)." }
        if let error = landing.error { return "Did not land (\(error)): \(listed)\(omitted)." }
        return "Landed in your checkout: \(listed)\(omitted)."
    }
```

### Complete HydraPrompts function inventory

`H` = `Tivano/Core/Models/Hydra.swift`; `S` = `Tivano/Core/Models/HydraDelegationStream.swift`; `R` = `Tivano/App/Runtime/ThreadRuntime.swift`. Each declaration quotes the source signature. Callers below are application source, not acceptance scripts; internal/private formatting and parsing functions are included.

| Declaration | Callers / purpose |
| --- | --- |
| `H:664` — `private static func workplaceRules(_ workplace: Workplace) -> String` | H:1099, H:1147; workplace rules. |
| `H:704` — `private static func projectRule(_ projects: [HydraProjectRef]) -> String` | H:791; project-routing policy. |
| `H:736` — `static func teamStatus(_ heads: [HydraHeadInfo], now: Date = .now) -> String?` | R:1801; team status. |
| `H:762` — `static func fallbackPolicy(maxHeads: Int?, isolated: Bool, autoMerges: Bool = false, reviewsHeads: Bool = false, heads: String? = nil, projects: [HydraProjectRef] = [], profiles: [HydraHeadProfile] = []) -> String` | H:798; policy implementation. |
| `H:797` — `static func fallbackPolicy(_ launch: HydraLaunch) -> String` | H:882, H:886; ClaudeSession.swift:109, CodexSession.swift:287, CopilotSession.swift:143, OmpSession.swift:118, OpenAICompatibleSession.swift:1220 (all Tivano/Services/Providers); Tivano/App/AppModel+Voice.swift:49. |
| `H:802` — `static func mergeStatus(merges: [HydraMergeRecord], unmergedFiles: Int, now: Date = .now) -> String?` | R:1800; merge state. Local helpers files(_ count: Int) -> String (H:803), when(_ date: Date) -> String (H:804), merged(_ record: HydraMergeRecord) -> String (H:805), pendingLine(_ prefix: String) -> String (H:810) are called only within this function. |
| `H:850` — `static func delegationRequest(_ launch: HydraLaunch) -> String` | R:1814; user-turn delegation request. |
| `H:863` — `static func fallbackTurnNote(team: String?, merge: String? = nil) -> String` | H:882, R:1804; ordinary turn note. |
| `H:872` — `static func fallbackReportNote(team: String?, merge: String? = nil, canDelegate: Bool) -> String` | H:886, R:1804; report note and round guidance. |
| `H:881` — `static func fallbackPreamble(_ launch: HydraLaunch, team: String?, merge: String? = nil) -> String` | R:1806; policy plus ordinary note. |
| `H:885` — `static func fallbackReportPreamble(_ launch: HydraLaunch, team: String?, merge: String? = nil, canDelegate: Bool) -> String` | R:1808; policy plus report note. |
| `H:891` — `static func heldBackMessage(count: Int) -> String` | R:3777; exhausted-round refusal. |
| `H:900` — `static func interruptedBlockMessage(stopped: Bool) -> String` | R:3694; interrupted block notice. |
| `H:911` — `static func droppedBlockNotice(_ message: String) -> String` | H:635 (HydraDelegationBudget.noteDropped); deferred notice. |
| `H:917` — `private static func delegationOpener(in text: String) -> Range<String.Index>?` | H:943, H:966, H:1044, H:1051; opener recognition. |
| `H:924` — `private static func lineStartFences(in text: String, from start: String.Index) -> [Range<String.Index>]` | H:944, H:968; closing fence candidates. |
| `H:942` — `static func delegationBlockRange(in text: String) -> Range<String.Index>?` | H:949, H:992; block extent. |
| `H:949` — `static func hasDelegationBlock(in text: String) -> Bool` | R:3699, R:3751; Tivano/App/Views/Chat/HydraButton.swift:143, :163; block detection. |
| `H:954` — `static func hasDelegationOpener(in tail: Substring) -> Bool` | Tivano/App/Views/Chat/HydraButton.swift:184; incremental opener detection. |
| `H:965` — `static func delegations(in text: String) -> [HydraDelegation]?` | R:3750; complete reply block parse. |
| `H:981` — `private static func delegations(fromBody body: String) -> [HydraDelegation]?` | H:971; JSON-body parse; passes delegation(fromEntry:) to compactMap at H:985. |
| `H:990` — `static func withoutDelegationBlock(_ text: String) -> String` | R:800, :3675, :3687, :3752, :3759, :3820; Tivano/Core/Models/ThreadContinuation.swift:50; strip block. |
| `H:1006` — `static func hasSentDelegationBlock(in text: String) -> Bool` | H:1044, H:1051; R:798, :3814, :3819; sent state. |
| `H:1011` — `static func hasLeavingDelegationBlock(in text: String) -> Bool` | H:1044; leaving state. |
| `H:1023` — `private static func mayOpenDelegationFence(_ text: String) -> Bool` | H:1007, H:1012; fence prefilter. |
| `H:1043` — `static func markingDelegationBlockLeaving(_ text: String) -> String` | R:3815; mark fading. |
| `H:1050` — `static func markingDelegationBlockSent(_ text: String) -> String` | R:3721, R:3781; mark dispatch done. |
| `H:1057` — `static func unreadableBlockMessage(reason: String?) -> String` | R:3757; unreadable-block refusal. |
| `H:1080` — `static func withoutVerificationSteps(_ prompt: String) -> String` | H:1096; strip validation lines. |
| `H:1091` — `static func delegatedHeadPrompt(persona: HydraPersona, delegation: HydraDelegation, workplace: Workplace) -> String` | R:3913; delegated head brief. |
| `H:1121` — `static func queuedHeadPrompt(persona: HydraPersona, task: String, context: ChatContext, workplace: Workplace, leadIsWorking: Bool = true) -> String` | R:1421; queued/direct head brief. |
| `H:1160` — `static func reportMessage(_ reports: [HydraReport], stillWorking: [String] = [], reviewsHeads: Bool = false) -> String` | R:3649; report body. |
| `H:1277` — `private static func landingLine(for report: HydraReport) -> String?` | H:1192; landing line. |
| `H:1296` — `private static func duration(_ seconds: TimeInterval) -> String` | H:1188; elapsed duration. |
| `H:1301` — `private static func list(_ names: [String]) -> String` | H:1162, :1164, :1226, :1236, :1239, :1263; name-list prose. |
| `H:1309` — `private static func quoted(_ text: String, limit: Int) -> String` | H:1124, H:1127; truncated quotation. |
| `S:16` — `static func streamedDelegations(in text: String) -> StreamedDelegations?` | R:3724; Tivano/Services/Providers/OpenAICompatibleSession.swift:706; forwards to S:29. |
| `S:29` — `static func streamedDelegations(inBody body: Substring) -> StreamedDelegations` | S:18; Tivano/App/Views/Chat/TimelineRows.swift:860; streamed body parsing. |
| `S:110` — `static func delegation(fromEntry entry: JSONValue) -> HydraDelegation?` | H:985, S:73, S:213; common entry decoder for complete and incremental parsing. |
| `S:122` — `fileprivate static func isJSONWhitespace(_ byte: UInt8) -> Bool` | S:33; JSON whitespace predicate. |

## 2. Brief composition, persona, workplace and original request

- `Tivano/App/Runtime/ThreadRuntime.swift:3896` — `private func spawnWaitingHeads(launch: HydraLaunch? = nil)` consumes queued `HydraDelegation` entries. Lines :3912–3914 pass `{ persona, workplace in HydraPrompts.delegatedHeadPrompt(persona: persona, delegation: delegation, workplace: workplace) }` as the brief closure.
- `Tivano/App/AppModel+Hydra.swift:511` — `func spawnTivanoHead(from parentID: UUID, task: String, origin: HydraHeadInfo.Origin, attachments: [Attachment] = [], batchID: UUID? = nil, preferredIndex: Int? = nil, project: String? = nil, profile: String? = nil, brief: @escaping @Sendable (HydraPersona, HydraPrompts.Workplace) -> String) -> ChatThread?` inserts a thread synchronously, then starts it asynchronously. `private func startTivanoHead(_ id: UUID, route: String?, attachments: [Attachment], brief: @Sendable (HydraPersona, HydraPrompts.Workplace) -> String) async` (:635) resolves checkout/copy before calling `brief(info.persona, workplace)` (:685) and `headRuntime.sendHydraBrief(...)` (:686).
- `Tivano/Core/Models/Hydra.swift:206` — `struct HydraPersona: Hashable, Sendable` contains only `name`, `asset` and `hex`: roster identity/appearance, not model policy. `HydraPrompts.Workplace` (:656) is `.ownCopy(path:)` or `.shared(path:)`, converted into checkout rules by `workplaceRules(_:)` (:664); `makeHydraCopy(for:of:)` (`AppModel+Hydra.swift:695`) can fail, leaving the shared case.
- `Tivano/Core/Models/Hydra.swift:1091` — `static func delegatedHeadPrompt(persona: HydraPersona, delegation: HydraDelegation, workplace: Workplace) -> String` wraps persona, task, delegated prompt, workplace rules, `howToWork` and `howToReport`. **Delegation text is not guaranteed verbatim:** entry decoding trims it (`HydraDelegationStream.swift:111`), and `withoutVerificationSteps(_:)` (`Hydra.swift:1080`) removes entire lines matching validation markers, then adds “Make the assigned edits and report; the lead handles all validation.” Other lines are retained.
- `Tivano/App/Runtime/ThreadRuntime.swift:1148` — `func sendHydraBrief(_ text: String, attachments: [Attachment])` sends the assembled brief as a user-role item with `hydraBrief: true`, not as the head's system prompt. `startTurn` stores that text at :1647 and later can add attachment paths/common guidance; delegated spawns use default empty attachments, so original user images are not automatically inherited.
- `Tivano/App/AppModel+Hydra.swift:1333` — `func hydraChatContext(for parentID: UUID) -> HydraPrompts.ChatContext` already finds the lead's latest real user message by scanning `existingRuntime(for: parentID).entries.reversed()` for `.user(let message)` with `!message.isFromHydra` (:1336–1339). It also collects the latest assistant reply and current-turn tool-edit paths; it does not load absent history and returns empty context if the runtime is absent.
- `Tivano/App/Runtime/ThreadRuntime.swift:1412` — `private func dispatchHead(_ prompt: FollowUpPrompt, origin: HydraHeadInfo.Origin) -> Bool` captures that context for queued/sent tasks. `queuedHeadPrompt(...)` (`Hydra.swift:1121`) quotes only 1,200 characters of the prior user request and 800 of the reply; the new queued task is inserted directly at :1144. Delegated briefs do not attach `ChatContext` today.

**Packet hook:** snapshot the authoritative user-message text and identity at the parent user-turn boundary, carry it with each waiting delegation and into the brief closure, and append the packet outside validation-line stripping. Rereading “latest user message” at delayed startup can select a later request; full stored text, rather than `quoted(..., limit: 1_200)`, is required for a verbatim packet.

There is **no declared sibling file-ownership field** in `HydraDelegation` or `HydraHeadInfo`; touched paths/landing files record observed edits, not assigned ownership. Entries dispatch as their closing braces stream (`HydraDelegationStream.swift:69`; incremental parser :213), so the first head cannot know future siblings' assignments without an early manifest, buffering the batch or later packet updates. Buffering v1 would change its start latency.

## 3. Report capture, structured storage and Codable

`Tivano/App/AppModel+Hydra.swift:791` — `func hydraHeadTurnFinished(_ head: ChatThread, status: TurnStatus)` extracts the last assistant entry at :813–820. Failed turns restrict that lookup to the finished turn and prepend its error via `failedTurnReport(error:partial:)` (:897); completed turns currently use the last assistant entry anywhere in the head timeline, so a structured parser should bind data to the actual completed turn rather than reuse an older reply.

`func finishHydraHead(_ id: UUID, status: TurnStatus, summary: String?, landing: HydraLanding? = nil, startupFailure: Bool = false)` (:731) writes summary/status/times/landing/activity at :747–756, then forwards to the parent at :777. A v2 parser can read the raw completed-turn reply before failure/watchdog wrappers, store optional structured fields alongside unchanged `summary` through `updateHydraHead(_:_:)` (:719), and expose them to `HydraReport`/formatting; no structured-report parser exists today.

### All HydraHeadInfo fields

`Tivano/Core/Models/Hydra.swift:299` — `struct HydraHeadInfo: Codable, Hashable, Sendable`. Stored fields:

| Anchor | Fields (type / source default) |
| --- | --- |
| :326 | `index: Int`, `task: String`, `kind: Kind`, `origin: Origin`, `status: Status = .running` |
| :333 | `summary: String?`, `activity: String?`, `toolCalls: Int = 0`, `tokens: Int = 0` |
| :338 | `startedAt: Date = .now`, `finishedAt: Date?`, `queuedAt: Date?`, `executionStartedAt: Date?`, `executionFinishedAt: Date?`, `landingStartedAt: Date?`, `landingFinishedAt: Date?` |
| :360 | `nativeID: String?`, `nativeTaskID: String?`, `toolUseID: String?`, `batchID: UUID?`, `profile: String?` |
| :371 | `canStop: Bool = true`, `isBackground: Bool = true` |
| :378 | `baseTree: String?`, `targetCheckout: String?`, `pendingProjectReference: String?`, `landing: HydraLanding?`, `mergedAt: Date?` |
| :395 | `tracksProviderHistory: Bool = false`, `ownedCodexSessionID: String?`, `ownedCodexWorkingDirectory: String?`, `codexHistoryArchived: Bool = false`, `providerHistoryIssue: String?` |

Computed, not encoded: `persona: HydraPersona` (:402), `displayName: String` (:404), `isFinished: Bool` (:405), `hasOwnCopy: Bool` (:407). Nested enums: `Kind` = native/tivano (:303), `Origin` = delegated/queued/sent (:310), `Status` = running/completed/failed/stopped (:316), with computed `Status.isFinished` (:322).

`init(index:task:kind:origin:)` (:409) initializes new heads; custom `init(from decoder: Decoder) throws` (:416) reads every stored field through `container.value(_:default:)`. Missing/invalid status defaults to `.stopped`, optional fields to nil and counters to defaults; encoding/CodingKeys are synthesized for stored Codable properties.

### All HydraLanding fields

`Tivano/Core/Models/Hydra.swift:481` — `struct HydraLanding: Codable, Hashable, Sendable` stores `files: [File] = []` (:489), `conflicts: [String] = []` (:491), `droppedBuildOutputFiles: Int = 0` (:493), `patchPath: String?` (:495), `error: String?` (:496). Nested `File: Codable, Hashable, Sendable` (:482) stores `path: String`, `additions: Int` and `deletions: Int`; `isEmpty` (:499) and `landed` (:501) are computed.

`HydraLanding.init(from:)` (:503) also uses tolerant defaults; nested `File` uses synthesized Codable. `Tivano/Core/Support/Coding.swift:5` — `func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T` wraps `try? decodeIfPresent`, tolerating missing keys, nulls and type/enum mismatches. New optional fields are backward-compatible **if explicitly added to custom decoding with nil defaults**; old decoders ignore unknown keys, but an old-version decode/re-encode does not preserve them.

Persistence: `ChatThread.hydra` (`Tivano/Core/Models/Library.swift:219`) embeds head info; `updateHydraHead` → `AppModel.updateThread(_:_:)` (`Tivano/App/AppModel.swift:1075`) → `scheduleSave()` (:1091) → `saveLibrary()` (:1915) → `DiskWriter.shared.encodeAndWrite(currentLibrary(), to: Storage.libraryURL)` (:1918). Raw reply text also persists in the head timeline; the parent runtime's pending `HydraReport` is not an immutable scoring ledger.

**Scoring caveat:** latest-run fields overwrite prior summary/timing/landing. `baseTree` advances after clean landing (`AppModel+Hydra.swift:1055`) and is removed on copy release (:1214); it is neither an original base commit nor a permanent rework record.

## 4. Finished-head steering and lead-directed follow-ups

- `Tivano/App/Views/Chat/HydraPanel.swift:453` — `private struct HydraHeadTranscript: View` uses `model.runtime(for: head.id)` (:467) and renders `ComposerArea(runtime: runtime, ...)` for Tivano heads (:501). `Tivano/App/Views/Composer/ComposerView.swift:427` — `private func send()` calls `runtime.send()` when idle (:437), or `interruptAndSend()` while running.
- `Tivano/App/Runtime/ThreadRuntime.swift:1134` — `func send()` enters `startTurn` on the same head thread. At :1674 a finished head becomes `.running` and clears `finishedAt`; :1680 resets execution/landing timing. `ensureSession` reuses a matching live session (:2017), otherwise resumes from `thread.providerSessionID` (:2149).
- `Tivano/App/AppModel.swift:1714` calls `hydraHeadTurnFinished` when the head is not auto-continuing, repeating section 3's report path. `ThreadRuntime.hydraHeadFinished` (:3586) replaces queued reports for that head index and creates a fresh pending report if its old batch is gone (:3591).
- **Same thread does not guarantee the same physical session or workspace.** Successful completion calls `releaseHydraCopy(of:)` (`AppModel+Hydra.swift:785`, declaration :1157), clearing copy path/base tree at :1212–1214; `ChatThread.executionDirectory(projectPath:)` (`Library.swift:231`) then selects `hydra.targetCheckout`. Non-API head processes normally stop on completion (:839); ordinary resume failures can start a new conversation with a warning (`ThreadRuntime:2168–2185`). Codex history restoration adds safeguards at :2018 and :2169.

### Protocol today and required extension

`Tivano/Core/Models/Hydra.swift:519` — `struct HydraDelegation: Hashable, Sendable` has exactly `task: String`, `prompt: String`, `name: String?`, `project: String?` and `profile: String?`; it is not Codable. `static func delegation(fromEntry entry: JSONValue) -> HydraDelegation?` (`HydraDelegationStream.swift:110`) requires a nonempty trimmed prompt, derives a missing task title from it, accepts `name`/`head`, `project`/`repo` and `profile`. There is no operation, existing-thread target or ownership list.

**No lead follow-up operation exists in the Hydra block protocol.** `spawnWaitingHeads` (`ThreadRuntime:3911`) converts the name to a roster index then always calls `spawnTivanoHead`; `insertHydraHead` (`AppModel+Hydra.swift:528`, collision logic :553–566) advances a finished used name to its next roster round (Tova → Tova 2), while a running-name collision chooses a free head. Globally interpreting `name` as “resume” would break v1.

**V2 hook:** add an explicit optional action/target discriminator to `HydraDelegation` and its shared entry decoder (used by complete and incremental parsing), then branch before spawning. Resolve the target only within this lead's existing Tivano team, require a usable idle head, keep thread/provider-session identity, register it in the new batch, remove stale pending reports, send through its runtime and record attempt/rework identity; invalid targets should produce a refusal rather than silently spawn.

Round charging, duplicate streamed dispatch, previous landing/`mergedAt` handling and released-copy isolation need explicit handling. The current panel continuation does not create another isolated copy, and it is not by itself a complete new lead-follow-up contract.

## 5. Labs toggles and stamping mode

- `Tivano/App/AppSettings.swift:146` — `@MainActor @Observable final class AppSettings` uses `@ObservationIgnored private let defaults = CaptureRun.defaults ?? .standard` (:235). Keys `alphaEnabled`/`alphaVoiceEnabled` are at :172–173; `var alphaVoiceEnabled: Bool` (:377) saves via `didSet`, initialization uses `defaults.bool(forKey:)` (:906–907, absent = false), and `var isVoiceEnabled: Bool { alphaEnabled && alphaVoiceEnabled }` (:381) is the effective-feature pattern.
- `Tivano/App/Views/Settings/SettingsView.swift:27` labels `.alpha` “Labs”; page dispatch at :479 renders `AlphaSettingsPage()`. `Tivano/App/Views/Settings/AlphaSettingsPage.swift:14` — `struct AlphaSettingsPage: View` creates `@Bindable var settings = model.settings` (:18), master `SettingsSwitch(isOn: $settings.alphaEnabled)` (:36), and a feature `ChromeSection` → `ChromeCard` → `ChromeRow` with `SettingsSwitch(isOn: $settings.alphaVoiceEnabled)` and accessibility label (:50–54). Features are disabled/dimmed by the master switch (:63–65); the page header itself still says “Alpha” (:27).
- `Tivano/Core/Models/Library.swift:137` — `struct ChatThread: Codable, Identifiable, Hashable, Sendable` stores `hydraEnabled` (:204), `hydraEnabledIsExplicit` (:209), `hydraPairID` (:212), `temporaryHydraPair` (:215), `hydraSpawnCount` (:217), `hydra` (:219), but no mode/job policy snapshot. Its custom decoder starts at :294; absent new mode fields should mean v1/nil, not auto-opt-in.
- `Tivano/App/Runtime/ThreadRuntime.swift:1569` — `private func startTurn(text: String, attachments: [Attachment], hydraHeads: [Int]? = nil, hydraBrief: Bool = false, externalTurnID: UUID? = nil) async` is the common boundary. After guards/`beginThreadTurn` (:1637), before `TurnRecord` creation (:1643) and `ensureSession` (:1768), it can stamp effective mode/pair/request; `hydraHeads == nil` at :1671 distinguishes user requests from automatic report turns.
- `Tivano/Core/Models/Timeline.swift:287` — `struct TurnRecord: Codable, Identifiable, Hashable, Sendable` stores turn IDs, status/times, `baseCheckpoint`, `endCheckpoint`, `userItemID`, provider diff/anchor, touched paths, token spends and `hydraMerged`. Thread mode alone loses historical changes across jobs; per-job/turn policy and head-attempt records are needed for scoring. `ThreadRuntime.hydraBudget` (:395) is runtime-only.

**V1 preservation:** add an opt-in effective setting like voice, snapshot it once for a new user job and carry it through `HydraLaunch` and head metadata. Independent live reads at policy assembly, delayed startup and report/merge handling would mix modes after a mid-job flip. Queued/direct-user head dispatch at `ThreadRuntime:1412` also needs stamping because it can bypass a lead `startTurn`.

## 6. Optional pre-merge reviewer and available diff/base data

`Tivano/App/AppModel+HydraMerge.swift:111` — `func autoMergeHydraWork(of leadID: UUID, recovering: Bool = false) async` gates persistence, auto-merge, Hydra enabled and readiness, serializes merges, then awaits `runtime.hydraLanding?.value` (:163). It groups `HydraWork` per project/explicit checkout (:179–197); a hook here can coordinate job-wide review after landing, but it does not yet have the exact immutable commit candidate.

`Tivano/App/AppModel+HydraMerge.swift:292` — `private func mergeHydraProject(of leadID: UUID, lead: ChatThread, project: Project, checkout: String, work: HydraWork, runtime: ThreadRuntime, several: Bool, syncsProjectCheckout: Bool) async -> HydraProjectMerge` is the precise per-checkout seam. It takes a shared repository lease (:314), checks in-progress operations/conflict markers (:325, :334), and prepares a candidate in a three-attempt loop (:363), before commit (:426), ref updates (:446) and push (:456).

| Anchor | Available data |
| --- | --- |
| :330 | `sorted = work.paths`, owned paths for this checkout |
| :343–355 | Target/current branch, own-branch choice and destination branch name |
| :364 | `head`, the checkout HEAD commit observed for this attempt |
| :368–380 | `parent`, HEAD or the fetched remote target commit, and rebased `merged: [String: Data]` |
| :382–386 | `captured`, immutable selected working-tree snapshot, possibly rebased onto remote |
| :411 | `patch = git.diff(from: parent, to: captured)` (default, non-binary diff) |
| :414 | `[DiffFile]` parsed from the patch |
| :423–429 | Readiness/cancellation/runtime guards and HEAD-race retry |

**Candidate hook:** review `parent → captured` after :414, before description/commit, only for stamped v2 plus enabled reviewer. Keep the off branch on today's path; cache approval for an exact base/tree candidate and invalidate on changed preparation. Give the reviewer immutable diff/snapshot data and read-only capabilities; ordinary `spawnTivanoHead` grants full access, auto-lands/reports and joins batching, so it is not a read-only reviewer primitive.

There is another preparation path at :398–405: a previously sent but unmerged commit computes `base = mergeBase(head, origin/target)` and `patch = diff(base, head)`, sets `prepared` and breaks before :411. A reviewer only at :414 misses this retry path; carry review inputs with the candidate or cover both before ref/push actions. Rejection/unavailability/retry policy is new behavior; review alone must not mark ownership consumed or work merged.

**Base identities differ:** `HydraHeadInfo.baseTree` is a mutable tree hash, not HEAD. `makeHydraCopy(for:of:)` (`AppModel+Hydra.swift:695`) gets `capture.commit` and `capture.tree` (:710–712) but returns only path/tree; it does not record original HEAD/synthetic copy commit on the head. `prepareHydraPatch(_:)` (:968) has base/current trees, selected paths and binary patch (:975); `TurnRecord.baseCheckpoint` (`Timeline.swift:294`) and merge `head`/`parent` refer to different checkpoints/commits. Scoring needs explicit immutable names for each required identity.

**Timing risks:** review here happens after patches landed and the lead finished, not before landing. A model await holds repository/global merge activity longer; repeat readiness/cancellation guards afterwards and preserve retry/ownership lifecycle. Auto-merge must be enabled to reach this hook; review when auto-merge is off needs another trigger.

## 7. Per-head provider/model/effort selection and persistence

- `Tivano/App/AppModel+Hydra.swift:186` — `func hydraPair(for thread: ChatThread) -> HydraPair?` resolves temporary/saved selected pairs only while their provider matches the lead. `func hydraLaunch(for thread: ChatThread) -> HydraLaunch?` (:230) resolves heads provider, model/effort, profiles, minimum pair/global cap, isolation, auto-merge and lead-review settings.
- `func hydraHeadsProvider(of pair: HydraPair) -> ProviderKind` (:197) falls back to the lead provider if the worker provider is disabled/unavailable; `hydraLaunch` discards incompatible worker settings on that fallback (:240–259). Same-provider inherited effort may be tempered by `static func hydraHeadsEffort(leadEffort: String?, scale: [String]) -> String?` (:219), while explicit pair effort wins.
- `Tivano/Core/Models/Hydra.swift:132` — `struct HydraLaunch: Hashable, Sendable` contains `headsProvider`, `headsLabel`, `workerModel`, `workerEffort`, `workerDshMode`, `maxHeads`, `headProfiles`, `isolatesHeads`, `autoMerges`, `reviewsHeads` and `projects`. It is not Codable and carries neither pair ID/type nor mode; `func profile(named name: String) -> HydraHeadProfile?` (:179) matches optional profile names.
- `Tivano/App/AppModel+Hydra.swift:528` — `private func insertHydraHead(from parentID: UUID, task: String, origin: HydraHeadInfo.Origin, batchID: UUID?, preferredIndex: Int? = nil, project: String? = nil, profile: String? = nil) -> ChatThread?` resolves the profile (:572), writes effective provider/model/effort into `ChatThread` (:585–591), sets `.fullAccess` and `fastMode: false` (:597–598), conditionally sets dsh mode (:600) and stores only the resolved profile name in `HydraHeadInfo` (:617).
- `startTivanoHead` (:658–661) can fill a missing cross-provider model after catalog load. `ChatThread.provider/model/effort` (`Library.swift:148–155`) persist through decoding (:303–305), so **yes, head selections are recorded on the head thread**, but as mutable current selections rather than immutable attempt metadata; source pair ID/policy and rework history are not copied into head info.
- `Tivano/App/AppModel+HydraPairs.swift:56` — `func enterHydraPair(_ pair: HydraPair, for threadID: UUID, temporary: Bool = false)` changes lead provider/model/effort/pair ID using `func hydraLead(of pair: HydraPair, for thread: ChatThread) -> (model: String?, effort: String?, fastMode: Bool, dshMode: DshAgentMode?)` (:84). Lead selection and head selection are separate seams; scoring needs both.
- `Tivano/Core/Models/HydraCookbook.swift:7` — `struct HydraPairRecipe: Identifiable, Sendable` holds recipe sides. `Tivano/App/HydraCookbook+Resolve.swift:32` — `@MainActor static func resolve(_ recipe: HydraPairRecipe, registry: ProviderRegistry, settings: AppSettings) -> HydraPair?` selects available provider/model matches and creates a pair with new UUID/configuration, but no persisted recipe ID or semantic pair type. Per-type thresholds need an explicit stable classification or documented derivation, not inference from an editable pair name.

### Remaining ambiguities and v1 preservation risks

1. **Mode lifetime:** choose thread versus user-job versus turn explicitly; a job spans streaming batches, report turns, steering and merge retries, while current settings are live reads.
2. **Packet completeness:** the original request exists in the timeline, but delegated briefs omit it and sibling ownership is not modeled; streaming prevents a complete future-sibling packet without protocol changes.
3. **Follow-up identity/isolation:** a repeated name spawns today; completed copies are released, and provider resume can fall back to a new conversation.
4. **Review semantics:** `hydraReviewHeads` is an existing lead-review setting, not a cross-vendor reviewer. Current policy forbids delegating that review and ordinary heads are full-access.
5. **Scoring durability:** summary/times/landing/base tree are overwritten or cleared; current thread selections do not preserve mode/pair/base/rework history.
6. **Off behavior:** retain existing policy text/signatures/protocol as defaults and default missing metadata to v1. New policy should not silently alter verification stripping, roster-name semantics, copy release, landing, merge or watchdog behavior.

Prior-context lookup: one bounded Nowledge CLI thread search (`Tivano Hydra 2.0`, limit 3, returned space `default`) found a related architecture thread (`claude-code-f3c1d0db-5989-4b3c-9b28-a703a97397d2`); its content was not used to assert current code behavior. Evidence is the local source above. Provider continuation and runtime timing remain unverified by design.
