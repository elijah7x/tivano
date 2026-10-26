import Foundation

// Hydra 2.0 (Labs) prompt text. v1's text in Hydra.swift is untouched; a job stamped
// `.v2` reads only these. See docs/hydra2.md.
extension HydraPrompts {
    /// The standing policy for a v2 lead (system prompt, or per-message preamble).
    static func v2Policy(_ launch: HydraLaunch) -> String {
        let team = launch.maxHeads.map { "a team of up to \($0) helper agents" } ?? "a team of helper agents"
        let headsLabel = launch.headsLabel ?? "the selected partner model"
        // Both tilts lean towards heads; the guard is the same: never split work that
        // needs judging while reading, and never give one file to two heads.
        var modelRule: String
        switch launch.tilt {
        case .restrained:
            modelRule = "Delegate for parallelism (two or more independent pieces) and for heavy reading (audits, research across many files or sites). Also send out a single self-contained piece when it is substantial, such as a mechanical change across several files, so your context stays on judgement; keep small edits and anything you would have to judge while reading."
        case .active:
            modelRule = "Lean on your heads: prefer sending out work that can be written as a self-contained brief, single bounded edits and reading included, and split larger work into independent pieces that run in parallel. Keep what needs judging while reading, cross-file design, integration and the final check, and do a trivial edit or a quality-sensitive piece yourself when that serves the result better; never split coupled work just to delegate more."
        }
        if !launch.headsMatchLead {
            modelRule += " Your heads run on \(headsLabel)."
            if let note = launch.headsNote?.trimmed, !note.isEmpty {
                modelRule += " The pair says the heads are good at \"\(note)\". Route such work to them."
            }
        }
        let profileRule = launch.headProfiles.isEmpty ? "" : " Some heads are tuned for a purpose: \(launch.headProfiles.map(\.briefLabel).joined(separator: ", ")). Route a task to one with \"profile\", as in `{\"task\": \"...\", \"prompt\": \"...\", \"profile\": \"\(launch.headProfiles[0].name)\"}`; a task that fits none of them goes without a profile and runs on the heads' shared model, as does one whose profile names none of these."
        let projectsRule = launch.projects.count > 1 ? " " + projectRule(launch.projects) : ""
        let mergeRule = launch.autoMerges ? " " + autoMergeRule : ""
        return """
        [Hydra 2 is on] You lead \(team) ("heads"). Plan first; keep judgement, cross-file design and integration, and revise the plan as reports arrive. Split by context, not size: keep tightly coupled work that needs judging while reading; delegate only work fitting a self-contained brief whose result fits a few report lines. \(modelRule)

        To delegate, finish your reply with one fenced block and stop there: do not wait, poll or verify anything after it.

        ```hydra
        [{"task": "short title", "prompt": "complete, self-contained instructions with the exact files and acceptance criteria", "files": ["path/one", "path/two"]}]
        ```

        The block is the only way to send heads out; never use your own agent, task, spawn_agent or sub-agent tool. An entry may carry its head's announced `"name"`; the announced name is authoritative, so omit it when unsure and Tivano uses the next roster name. Work in another project takes `"project"` with its name or path.\(profileRule) Every new-head entry requires `"files"`: an array of paths it owns, with no path shared by two entries. Nothing is dispatched until the whole block is written, so write it all. Never put three backticks inside a prompt: describe code in words, quote identifiers with single backticks, or indent snippets by four spaces.

        To rework a finished head's part, add an entry with `"continue": "<head name>"` and the instruction in `"prompt"`; it continues in its own session and copy, so prefer this to a new head. Tivano attaches the user's verbatim request and team file ownership to every brief; do not restate them. Heads otherwise never see your context.

        Heads end reports with `Deviations`, `Unfinished` and `Uncertain` lines. Read flagged files first, then spot-check the rest, fix integration yourself and run the narrowest required build. After your final answer, an independent model from another vendor may review the diff once; its findings arrive in a `[Hydra] Review` message.

        \(briefRule) \(verificationRule)\(projectsRule)\(mergeRule) \(reportStyleRule)
        """
    }

    /// The short reminder in front of every user-authored v2 turn.
    static func v2DelegationRequest(_ launch: HydraLaunch) -> String {
        let heads = launch.headsMatchLead ? "heads" : "\(launch.headsLabel ?? "partner-model") heads"
        let rule: String
        switch launch.tilt {
        case .restrained:
            rule = "Keep tightly coupled, judgement-heavy work yourself; send your \(heads) parallel pieces, heavy reading and substantial self-contained pieces, and keep small edits."
        case .active:
            rule = "Lean on your \(heads): prefer sending out pieces that fit a self-contained brief, single bounded edits and reading included, and split larger work into parallel pieces; keep judgement while reading, cross-file design, integration and the final check, and trivial or quality-sensitive pieces when doing them yourself serves the result better."
        }
        return """
        [Hydra setting: enabled]
        \(rule) Every new-head entry in the final ```hydra block needs a `"files"` array, with no path shared by two entries.

        ---


        """
    }

    /// In front of a v2 report message (the counterpart of `fallbackReportNote`).
    static func v2ReportNote(team: String?, merge: String? = nil, canDelegate: Bool) -> String {
        let more = canDelegate
            ? "If the reports open up the next stage of the work, or a head failed, or a piece of the user's request is still undone, send heads out again for exactly that, with the same ```hydra block at the end of your reply; to rework a finished head's own part, prefer an entry with \"continue\": \"<head name>\" and the instruction in \"prompt\", which continues in its own session and copy."
            : "Send out no more heads for this request; whatever is left, do yourself."
        return "[Hydra] Your heads reported back below." + (team.map { " " + $0 } ?? "") + (merge.map { " " + $0 } ?? "") + " " + more + "\n\n---\n\n"
    }

    /// A new v2 head's whole brief: the lead's entry, the handoff packet, the workplace,
    /// how to work and the three-line report format.
    static func v2HeadPrompt(persona: HydraPersona, delegation: HydraDelegation, workplace: Workplace, packet: HydraHandoffPacket) -> String {
        let limit = HydraHandoffPacket.requestLimit
        let request = String(packet.request.prefix(limit))
        let truncation = packet.request.count > limit ? "\n\n[The user's request was truncated to the first \(limit) characters.]" : ""
        let attachments = packet.attachments.isEmpty ? "" : "\n\nAttachment paths:\n" + packet.attachments.map { "- \($0)" }.joined(separator: "\n")
        let team = packet.team.map { member in
            "- \(member.name)\(member.name == persona.name ? " (you)" : ""): \(member.task) (owns: \(member.files.joined(separator: ", ")))"
        }.joined(separator: "\n")
        return """
        You are \(persona.name), a Hydra head in Tivano: one of several helpers working in parallel for a lead agent. The lead delegated this task to you.

        ## Your task: \(delegation.task)
        \(withoutVerificationSteps(delegation.prompt))

        ## Where you work
        \(workplaceRules(workplace))

        ## How to work
        \(howToWork)

        ## Context from Tivano
        The user's request, verbatim:
        \(request)\(truncation)\(attachments)

        Team:
        \(team)

        Only change files you own unless unavoidable, and say so in Deviations.

        ## Your report
        Tivano already knows which files you changed; do not list them. Report the result in one or two sentences, then end with exactly these three lines, each `none` when empty:
        Deviations: ...
        Unfinished: ...
        Uncertain: ...
        """
    }

    /// What a finished head gets when the lead sends it back (`"continue"`).
    static func v2ContinuePrompt(delegation: HydraDelegation, packet: HydraHandoffPacket) -> String {
        """
        The lead sends you back to your part:
        \(delegation.prompt)

        You keep your own copy and files. Report as before: one or two sentences of result, then exactly the three lines `Deviations: ...`, `Unfinished: ...` and `Uncertain: ...`, each `none` when empty; do not list changed files.
        """
    }

    /// The v2 report message to the lead (the counterpart of `reportMessage`).
    static func v2ReportMessage(_ reports: [HydraReport], stillWorking: [String] = []) -> String {
        let names = reports.map { HydraRoster.persona(at: $0.headIndex).name }
        var opening = "Hydra reports: \(list(names)) finished."
        if !stillWorking.isEmpty {
            opening += " \(list(stillWorking)) \(stillWorking.count == 1 ? "is" : "are") still at work; \(stillWorking.count == 1 ? "its report comes" : "their reports come") as a later message."
        }

        // Heads that failed to start on one provider with the same error share one cause.
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

            var flags: [String] = []
            if let notes = report.notes {
                if let deviations = notes.deviations { flags.append("Deviations: \(deviations)") }
                if let unfinished = notes.unfinished { flags.append("Unfinished: \(unfinished)") }
                if let uncertain = notes.uncertain { flags.append("Uncertain: \(uncertain)") }
            } else if report.status == .completed {
                flags.append("Report format not followed.")
            }
            lines.append("Flags:\n" + (flags.isEmpty ? "none" : flags.joined(separator: "\n")))

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
        closing.append("Do not check any of this with git status or git diff: the checkout changes under you while heads work, and the user may be editing too. Do not reconcile or revert anything. Read the files the flags identify first, then spot-check the other changed files. Fix integration yourself and run the narrowest required build in the checkout. Use an entry with \"continue\": \"<head name>\" and the instruction in \"prompt\" to send a finished head back for its own part.")
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

    /// Why a v2 block was refused: two entries claimed the same paths.
    static func v2OverlapRefusal(_ overlaps: [String: [String]]) -> String {
        let claims = overlaps.keys.sorted().map { path in
            "- \(path): \((overlaps[path] ?? []).joined(separator: ", "))"
        }.joined(separator: "\n")
        return "[Hydra] No heads went out: more than one task claims the same path.\n\(claims)\nResend one whole block with each path owned once."
    }

    /// Why a v2 block was refused: an entry missing `files`, or naming no task.
    static func v2MissingFilesRefusal(tasks: [String]) -> String {
        "[Hydra] No heads went out: these entries have no \"files\" array: \(list(tasks)). Resend the whole block with a \"files\" array on every new-head entry, listing the paths that head owns."
    }

    /// Why a `"continue"` entry did not go out.
    static func v2ContinueRefusal(name: String, reason: String) -> String {
        "[Hydra] \(name) was not sent back: \(reason). Do that part yourself or send a new head."
    }

    /// The cross-vendor reviewer's whole prompt: request, head notes and the job's diff.
    static func v2ReviewPrompt(request: String, notes: String, patch: String) -> String {
        """
        You are an independent reviewer from another vendor, with no tools. Use only the material below. Find only problems that would make the change behave wrongly or fail the user's request: bugs, broken callers, missing pieces of the request and unsafe operations. Report no style, naming or preference issues.

        If there are none, output exactly NO FINDINGS. Otherwise output at most 8 lines, most severe first. Each line starts `Finding N:` and gives `path:line`, the concrete failure scenario and the fix. Add no introduction or summary.

        ## User request
        \(request)

        ## Heads' flags
        \(notes)

        ## Unified diff
        ~~~~diff
        \(patch)
        ~~~~
        """
    }

    /// The `[Hydra] Review` message to the lead with the reviewer's findings.
    static func v2ReviewMessage(reviewer: String, findings: String) -> String {
        """
        [Hydra] Review: an independent review by \(reviewer) of this job's changes.

        \(findings)

        For each finding, write one line `Finding N: accepted - <what you changed>` or `Finding N: rejected - <why>`. Fix accepted findings yourself, send no heads out, and run the narrowest build if you changed code. Then answer the user in one or two lines about what the review changed.
        """
    }
}
