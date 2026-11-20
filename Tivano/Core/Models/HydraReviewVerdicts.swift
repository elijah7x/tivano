import Foundation

/// Parses the lead's per-finding verdicts (`Finding N: accepted|rejected ...`) from a
/// Hydra independent-review turn reply.
enum HydraReviewVerdicts {
    struct Item: Equatable, Sendable {
        let number: Int
        let accepted: Bool
        let text: String
    }

    private static let regex = try? NSRegularExpression(
        pattern: #"^[\s\-*>#_]*Finding\s*(\d+)[\s*_]*[:：][\s*_]*(?:partially\s+|partly\s+)?(accepted|接受|已接受|采纳|已采纳|部分采纳|rejected|驳回|已驳回|拒绝|不采纳)"#,
        options: .caseInsensitive
    )

    private static let rejectedVerdicts: Set<String> = ["rejected", "驳回", "已驳回", "拒绝", "不采纳"]
    private static let leadingVerdictPunctuation = CharacterSet.whitespaces.union(
        CharacterSet(charactersIn: "-–—:：")
    )

    /// Returns the parsed findings sorted by finding number, each carrying its verdict and
    /// trailing explanation text. Only a line that opens on the verdict counts, so a summary
    /// quoting an earlier verdict does not overturn it. The template's own placeholder lines
    /// are ignored, and a later verdict on the same finding replaces an earlier one.
    static func items(_ reply: String) -> [Item] {
        guard let regex else { return [] }
        var byNumber: [Int: Item] = [:]
        for line in reply.components(separatedBy: .newlines)
        where !line.contains("<what you changed>") && !line.contains("<why>") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let fullRange = Range(match.range(at: 0), in: line),
               let numRange = Range(match.range(at: 1), in: line),
               let verdictRange = Range(match.range(at: 2), in: line),
               let number = Int(line[numRange]) {
                let verdict = line[verdictRange].lowercased()
                let accepted = !rejectedVerdicts.contains(verdict)
                let text = explanation(after: line[fullRange.upperBound...])
                byNumber[number] = Item(number: number, accepted: accepted, text: text)
            }
        }
        return byNumber.values.sorted { $0.number < $1.number }
    }

    /// The explanation after a verdict, without its separator. A `**`/`_` run right after
    /// the verdict closes the verdict's own emphasis (`**Finding 1: accepted** - ...`) and
    /// goes with it; markers that open the explanation's own formatting stay.
    private static func explanation(after rest: Substring) -> String {
        var tail = rest.drop { $0 == " " || $0 == "\t" }
        let markers = tail.prefix { $0 == "*" || $0 == "_" }
        if !markers.isEmpty {
            let next = tail.dropFirst(markers.count).first
            if next == nil || next!.unicodeScalars.allSatisfy({ leadingVerdictPunctuation.contains($0) }) {
                tail = tail.dropFirst(markers.count)
            }
        }
        let text = tail.drop { char in
            char.unicodeScalars.allSatisfy { leadingVerdictPunctuation.contains($0) }
        }
        return String(text).trimmingCharacters(in: .whitespaces)
    }

    /// Returns each finding number mapped to whether it was accepted (`true`) or rejected (`false`).
    /// Only a line that opens on the verdict counts, so a summary quoting an earlier verdict
    /// does not overturn it. The template's own placeholder lines are ignored, and a later
    /// verdict on the same finding replaces an earlier one.
    static func parse(_ reply: String) -> [Int: Bool] {
        Dictionary(uniqueKeysWithValues: items(reply).map { ($0.number, $0.accepted) })
    }

    /// Returns the reply with every line matching the verdict regex removed, consecutive runs
    /// of three or more newlines collapsed to two, and leading/trailing whitespace trimmed.
    static func strippingVerdictLines(_ reply: String) -> String {
        guard let regex else { return reply.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalized = reply.replacingOccurrences(of: "\r\n", with: "\n")
        let kept = normalized.components(separatedBy: "\n").filter { line in
            let range = NSRange(line.startIndex..., in: line)
            return regex.firstMatch(in: line, range: range) == nil
        }
        let joined = kept
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
