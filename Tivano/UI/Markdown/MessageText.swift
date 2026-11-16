import Foundation

/// The message for the clipboard: its markdown source as written, without the Hydra
/// delegation fences the timeline draws as a card. Used by the row menu's Copy (see
/// `copyActions` in TimelineRows.swift) when nothing is selected.
enum MessageText {
    @MainActor
    static func markdown(_ source: String) -> String {
        var kept: [Substring] = []
        var skipping = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if skipping {
                if trimmed.hasPrefix("```") { skipping = false }
                continue
            }
            if trimmed.hasPrefix("```") {
                let info = trimmed.drop { $0 == "`" }.trimmingCharacters(in: .whitespaces).lowercased()
                if MarkdownView.isDelegationInfo(info) { skipping = true; continue }
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
