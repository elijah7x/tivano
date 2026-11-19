import Foundation

/// Parses the lead's per-finding verdicts (`Finding N: accepted|rejected ...`) from a
/// Hydra independent-review turn reply.
enum HydraReviewVerdicts {
    private static let regex = try? NSRegularExpression(
        pattern: #"^[\s\-*>#_]*Finding\s*(\d+)[\s*_]*[:：][\s*_]*(?:partially\s+|partly\s+)?(accepted|接受|已接受|采纳|已采纳|部分采纳|rejected|驳回|已驳回|拒绝|不采纳)"#,
        options: .caseInsensitive
    )

    private static let rejectedVerdicts: Set<String> = ["rejected", "驳回", "已驳回", "拒绝", "不采纳"]

    /// Returns each finding number mapped to whether it was accepted (`true`) or rejected (`false`).
    /// Only a line that opens on the verdict counts, so a summary quoting an earlier verdict
    /// does not overturn it. The template's own placeholder lines are ignored, and a later
    /// verdict on the same finding replaces an earlier one.
    static func parse(_ reply: String) -> [Int: Bool] {
        guard let regex else { return [:] }
        var verdicts: [Int: Bool] = [:]
        for line in reply.components(separatedBy: .newlines)
        where !line.contains("<what you changed>") && !line.contains("<why>") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let numRange = Range(match.range(at: 1), in: line),
               let verdictRange = Range(match.range(at: 2), in: line),
               let number = Int(line[numRange]) {
                let verdict = line[verdictRange].lowercased()
                verdicts[number] = !rejectedVerdicts.contains(verdict)
            }
        }
        return verdicts
    }
}
