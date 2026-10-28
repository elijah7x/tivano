// Shadow decision requests and patch statistics; see docs/hydra-decisions.md.
import Foundation

enum HydraDecisionPoint: String, Sendable {
    case headReport, preReview, reviewDisposition
}

struct DiffFileStat: Hashable, Sendable {
    var path: String
    var relativePath: String
    var added: Int
    var deleted: Int
    var churn: Int { added + deleted }
}

enum DiffStats {
    static func files(inPatch patch: String) -> [DiffFileStat] {
        let lines = patch.components(separatedBy: "\n")
        let multipleCheckouts = lines.filter { $0.hasPrefix("# checkout: ") }.count > 1
        var checkout = ""
        var files: [DiffFileStat] = []
        var inHunk = false
        for line in lines {
            if line.hasPrefix("# checkout: ") {
                checkout = URL(fileURLWithPath: String(line.dropFirst(12))).lastPathComponent
                inHunk = false
            } else if line.hasPrefix("diff --git ") {
                inHunk = false
                guard let path = destinationPath(String(line.dropFirst(11))) else { continue }
                files.append(DiffFileStat(
                    path: multipleCheckouts ? checkout + "/" + path : path,
                    relativePath: path, added: 0, deleted: 0
                ))
            } else if line.hasPrefix("@@ ") {
                inHunk = true
            } else if inHunk, !files.isEmpty {
                if line.hasPrefix("+"), !line.hasPrefix("+++ ") {
                    files[files.count - 1].added += 1
                } else if line.hasPrefix("-"), !line.hasPrefix("--- ") {
                    files[files.count - 1].deleted += 1
                }
            }
        }
        return files.sorted { $0.churn == $1.churn ? $0.path < $1.path : $0.churn > $1.churn }
    }

    static func mentionedPaths(_ files: [DiffFileStat], in text: String) -> [String] {
        let names = files.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return files.enumerated().compactMap { index, file in
            text.contains(file.relativePath) || (counts[names[index]] == 1 && text.contains(names[index]))
                ? file.path : nil
        }
    }

    /// Git quotes unusual paths with C escapes, including UTF-8 bytes in octal.
    private static func destinationPath(_ header: String) -> String? {
        let destination: String
        if let range = header.range(of: " \"b/") {
            destination = String(header[range.lowerBound...].dropFirst())
        } else if let range = header.range(of: " b/") {
            destination = String(header[range.lowerBound...].dropFirst())
        } else {
            return nil
        }
        if !destination.hasPrefix("\"") { return String(destination.dropFirst(2)) }
        let source = Array(destination.utf8.dropFirst())
        var decoded: [UInt8] = []
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == 34 { break }
            if byte != 92 {
                decoded.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < source.count else { return nil }
            let escaped = source[index]
            if (48...55).contains(escaped) {
                var value = 0
                var digits = 0
                while index < source.count, digits < 3, (48...55).contains(source[index]) {
                    value = value * 8 + Int(source[index] - 48)
                    index += 1
                    digits += 1
                }
                guard value <= 255 else { return nil }
                decoded.append(UInt8(value))
            } else {
                let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13]
                decoded.append(escapes[escaped] ?? escaped)
                index += 1
            }
        }
        guard let path = String(bytes: decoded, encoding: .utf8), path.hasPrefix("b/") else { return nil }
        return String(path.dropFirst(2))
    }
}

struct HydraDecisionRequest: Sendable {
    var point: HydraDecisionPoint
    var state: JSONValue
    var questions: [String: JSONValue]
}

enum HydraDecisionRequests {
    static func capped(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmed
        return trimmed.count > limit ? String(trimmed.prefix(max(0, limit))) + "\n[truncated]" : trimmed
    }

    static func headReport(task: String, ownedFiles: [String], landedFiles: [String], conflicts: Int, report: String, notes: HydraReportNotes?, followedReportFormat: Bool) -> HydraDecisionRequest {
        let encodedNotes: JSONValue = notes.map {
            .object([
                "deviations": .optional($0.deviations.flatMap { $0.trimmed.isEmpty ? nil : $0 }),
                "unfinished": .optional($0.unfinished.flatMap { $0.trimmed.isEmpty ? nil : $0 }),
                "uncertain": .optional($0.uncertain.flatMap { $0.trimmed.isEmpty ? nil : $0 }),
            ])
        } ?? .null
        return HydraDecisionRequest(point: .headReport, state: .object([
            "task": .string(task),
            "ownedFiles": .array(ownedFiles.map(JSONValue.string)),
            "landedFiles": .array(landedFiles.map(JSONValue.string)),
            "conflicts": .int(conflicts),
            "report": .string(capped(report, 6_000)),
            "notes": encodedNotes,
            "followedReportFormat": .bool(followedReportFormat),
        ]), questions: [
            "gapUnreported": noul("The state is one coding agent's final report on a task its lead assigned. Agents are told not to build, test or verify; the lead does that, so saying a build or test was not run is expected and is no gap. Work the lead was assigned, or that belongs to files outside `ownedFiles`, is the lead's by design and is no gap either; unfinished work in the agent's own files is a gap even when the report asks the lead to finish it. `notes` holds the agent's own Deviations / Unfinished / Uncertain lines (null when it wrote none of them). Does the report text admit something else in its own task unfinished, failed, skipped, guessed or left for later that `notes` does not mention?"),
            "completion": choice("Judging by the report alone, how far did the agent get with its own task? Not running builds or tests, and leaving work outside its own files to the lead, are expected of it and do not count against completion.", criteria: [
                "complete": "Says the task is done and leaves nothing over.",
                "partial": "Did part of the task; says or shows that some of the task itself is left or skipped.",
                "blocked": "Could not do the task, or stopped on a question, an error or missing access.",
            ]),
            "reworkLikely": noul("Will the lead most likely have to send this agent back to rework its part, judging by the report, the files it owned and the files that landed?"),
        ])
    }

    static func preReview(request: String, leadReply: String, headFlags: [String], heads: Int, leadBuilt: Bool, leadEditsAfterReports: Int, files: [DiffFileStat]) -> HydraDecisionRequest {
        HydraDecisionRequest(point: .preReview, state: .object([
            "request": .string(capped(request, 4_000)),
            "leadReply": .string(capped(leadReply, 4_000)),
            "headFlags": .array(headFlags.map { .string(capped($0, 500)) }),
            "heads": .int(heads),
            "leadBuilt": .bool(leadBuilt),
            "leadEditsAfterReports": .int(leadEditsAfterReports),
            "files": .array(files.prefix(40).map { .object(["path": .string($0.path), "added": .int($0.added), "deleted": .int($0.deleted)]) }),
            "filesTotal": .int(files.count),
            "linesAdded": .int(files.reduce(0) { $0 + $1.added }),
            "linesDeleted": .int(files.reduce(0) { $0 + $1.deleted }),
        ]), questions: [
            "defectLikely": noul("The state summarises a finished multi-agent coding job just before an independent code review: the user's request, the lead's final reply, open points the agents flagged, whether a build ran, and line counts per changed file (no source). Will the review find at least one defect that would make the software behave wrongly? Judge the summary only; this is not a verdict on the code."),
        ])
    }

    static func reviewDisposition(review: String, leadReply: String, findings: Int) -> HydraDecisionRequest? {
        guard findings > 0 else { return nil }
        let questions = Dictionary(uniqueKeysWithValues: (1...min(findings, 8)).map { number in
            ("finding_\(number)", choice("The state holds an independent review's numbered findings and the lead's reply to them. How did the reply deal with Finding \(number)?", criteria: [
                "accepted": "Says it changed or fixed something for this finding.",
                "rejected": "Argues the finding is wrong or not worth a change, and leaves it.",
                "unaddressed": "Does not clearly respond to this finding.",
            ]))
        })
        return HydraDecisionRequest(point: .reviewDisposition, state: .object([
            "review": .string(capped(review, 8_000)),
            "leadReply": .string(capped(leadReply, 4_000)),
        ]), questions: questions)
    }

    private static func noul(_ instructions: String) -> JSONValue {
        .object(["type": .string("noul"), "instructions": .string(instructions)])
    }

    private static func choice(_ instructions: String, criteria: [String: String]) -> JSONValue {
        .object(["type": .string("choice"), "instructions": .string(instructions), "criteria": .object(criteria.mapValues(JSONValue.string))])
    }
}
