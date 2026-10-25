import Foundation

/// The word-bounded mention scan shared by every prose path.
enum MentionScanner {
    /// Longest name first, so 'Hank 2' beats 'Hank'; a name inside a longer word or beside
    /// a digit doesn't count.
    nonisolated static func matches<Value>(in text: String, candidates: [Value], name: (Value) -> String) -> [(range: Range<String.Index>, value: Value)] {
        // A byte search for each name first: most paragraphs name no head at all, and the
        // character walk below, against every name of a Hydra chat's roster at every
        // position, was most of what laying out a reply cost while scrolling.
        let present = candidates.filter { candidate in
            let candidateName = name(candidate)
            return !candidateName.isEmpty && text.containsBytes(candidateName)
        }
        guard !present.isEmpty else { return [] }
        let ordered = present.sorted { name($0).count > name($1).count }
        var out: [(range: Range<String.Index>, value: Value)] = []
        var i = text.startIndex
        while i < text.endIndex {
            var hit: Value?
            for candidate in ordered {
                let candidateName = name(candidate)
                guard text[i...].hasPrefix(candidateName) else { continue }
                let after = text.index(i, offsetBy: candidateName.count, limitedBy: text.endIndex) ?? text.endIndex
                let beforeOK: Bool
                if i == text.startIndex { beforeOK = true } else { let c = text[text.index(before: i)]; beforeOK = !c.isLetter && !c.isNumber }
                let afterOK: Bool
                if after == text.endIndex { afterOK = true } else { let c = text[after]; afterOK = !c.isLetter && !c.isNumber }
                if beforeOK && afterOK { hit = candidate; break }
            }
            if let hit {
                let end = text.index(i, offsetBy: name(hit).count)
                out.append((i..<end, hit))
                i = end
            } else {
                i = text.index(after: i)
            }
        }
        return out
    }
}
