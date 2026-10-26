import Foundation

// Hydra 2.0 (Labs) prompt text. v1's text in Hydra.swift is untouched; a job stamped
// `.v2` reads only these. See docs/hydra2.md.
extension HydraPrompts {
    /// The standing policy for a v2 lead (system prompt, or per-message preamble). Kept
    /// short on purpose: rules that only matter in some turns (merge status, refusals,
    /// reports) arrive with those turns instead of standing here.
    static func v2Policy(_ launch: HydraLaunch) -> String {
        let team = launch.maxHeads.map { "up to \($0) helper agents" } ?? "helper agents"
        let tilt = switch launch.tilt {
        case .restrained:
            "Delegate parallel pieces, heavy reading (audits, research across many files) and substantial self-contained pieces such as a mechanical change across several files; do small edits yourself."
        case .active:
            "Prefer delegating whatever fits a self-contained brief, single bounded edits and reading included, and split larger work into parallel pieces; do a trivial or quality-sensitive piece yourself when that serves the result better."
        }
        var heads = ""
        if !launch.headsMatchLead, let label = launch.headsLabel ?? launch.workerModel { heads += " Heads run on \(label)." }
        if let note = launch.headsNote?.trimmed, !note.isEmpty { heads += " They are good at: \(note)." }
        let others = launch.projects.dropFirst().map(\.name)
        let projects = others.isEmpty ? "" : " A head can work in another sidebar project with `\"project\"` (its name or an absolute path): \(others.joined(separator: ", ")); its work lands and merges there."
        let merge = launch.autoMerges ? " Tivano commits and merges the team's work after you finish: never run or delegate commits, branches or merge requests, and claim a merge only when a [Hydra] note confirms it." : ""
        return """
        [Hydra 2] You lead \(team) ("heads"). Plan first, keep judgement, cross-file design, integration and the final check, and revise the plan as reports arrive. Split by context: keep work that must be judged while reading. \(tilt)\(heads)

        To delegate, end your reply with one block and stop:

        ```hydra
        [{"task": "short title", "prompt": "numbered steps naming files, symbols and exact changes", "files": ["paths/this/head/owns"]}]
        ```

        Every new-head entry needs `"files"`; no path may appear in two entries. Optional: `"name"`, `"project"`. Use only this block to delegate, never your own sub-agent tool, and never put three backticks inside a prompt. Tivano gives every head the user's request and the team's file split; resolve design choices in the brief and ask the head no questions. To send a finished head back to its part, use an entry `{"continue": "<head name>", "prompt": "..."}`. A user message while heads are out belongs to the same job.

        Heads never build, test or verify; you run the narrowest required check yourself after they report. Read the files their reports flag first.\(projects)\(merge)
        """
    }

    /// The reminder in front of a user's request. Sessions that get the full policy with
    /// every message need none (see `ThreadRuntime.startTurn`); the others get one line.
    static func v2DelegationRequest(_ launch: HydraLaunch) -> String {
        let tilt = launch.tilt == .restrained ? "restrained" : "proactive"
        return "[Hydra 2: \(tilt) delegation; every new-head entry needs \"files\".]\n\n---\n\n"
    }

    /// In front of a v2 report message (the counterpart of `fallbackReportNote`).
    static func v2ReportNote(team: String?, merge: String? = nil, canDelegate: Bool) -> String {
        let more = canDelegate
            ? "If the reports open up the next stage of the work, or a head failed, or a piece of the user's request is still undone, send heads out again for exactly that, with the same ```hydra block at the end of your reply; to rework a finished head's own part, prefer an entry with \"continue\": \"<head name>\" and the instruction in \"prompt\", which continues in its own session and copy."
            : "Send out no more heads for this request; whatever is left, do yourself."
        return "[Hydra] Your heads reported back below." + (team.map { " " + $0 } ?? "") + (merge.map { " " + $0 } ?? "") + " " + more + "\n\n---\n\n"
    }

    /// How a v2 head works. No pacing rules: they were written for slower models and only
    /// make a capable head second-guess itself.
    static let v2HowToWork = """
    - Read what the task needs, then make the change. Do exactly this task: touch no file you do not own unless unavoidable, and never revert or reformat others' work.
    - Never build, test, lint or verify; the lead does that.
    - If something blocks you, stop and say so in your report instead of working around it.
    """

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
        \(v2HowToWork)

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
    static func v2ContinuePrompt(delegation: HydraDelegation, packet: HydraHandoffPacket, workplace: Workplace? = nil) -> String {
        let workplaceRule: String
        switch workplace {
        case .ownCopy, nil:
            workplaceRule = "You keep your own copy and files."
        case .shared(let path):
            workplaceRule = "You continue in the lead's shared checkout at \(path), alongside others whose changes you must leave alone."
        }
        return """
        The lead sends you back to your part:
        \(delegation.prompt)

        \(workplaceRule) Report as before: one or two sentences of result, then exactly the three lines `Deviations: ...`, `Unfinished: ...` and `Uncertain: ...`, each `none` when empty; do not list changed files.
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
        closing.append("Read the flagged files first, then spot-check the rest; fix integration yourself and run the narrowest required check. Do not use git status or git diff to review this, and revert nothing: others may be editing the checkout.")
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

        ---
        For the lead:
        For each finding, write one line `Finding N: accepted - <what you changed>` or `Finding N: rejected - <why>`. Fix accepted findings yourself, send no heads out, and run the narrowest build if you changed code. Then answer the user in one or two lines about what the review changed.
        """
    }
}
