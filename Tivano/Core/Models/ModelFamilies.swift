import Foundation

/// Turns a provider's model list into rows a person can scan.
///
/// Two foldings, both read off the names the provider gives:
/// - `collapsed` merges the effort and Fast variants a provider lists as models of
///   their own ("Claude Opus 5.5 XHigh Fast") into one row whose effort and Fast are
///   settings, the way Claude and Codex list them. The row keeps every variant's id,
///   so the session sends the provider exactly an id it listed.
/// - `lineages` groups the rows of one line ("Claude Opus 5.5", "Claude Opus 5",
///   "Claude Opus 4.8") so a list shows the newest and folds the earlier versions, and
///   sets free, preview and experimental lines aside.
///
/// Both read names, not ids, and both err towards an extra row: a family whose names
/// do not all parse, or that would hold two variants for one effort and speed, stays
/// as the provider listed it.
enum ModelFamilies {
    // MARK: - Variants

    /// Merges the variant rows of a list whose provider names its variants (see
    /// `ProviderKind.namesModelVariants`). Rows already merged pass through, so the
    /// call is safe on a list that went through it before.
    static func collapsed(_ list: [ModelOption]) -> [ModelOption] {
        var order: [String] = []
        var groups: [String: [(option: ModelOption, effort: String?, isFast: Bool)]] = [:]
        for option in list {
            guard option.variants.isEmpty else {
                order.append("\u{0}" + option.id)
                groups["\u{0}" + option.id] = [(option, nil, false)]
                continue
            }
            let parsed = parse(option.name)
            if groups[parsed.base] == nil { order.append(parsed.base) }
            groups[parsed.base, default: []].append((option, parsed.effort, parsed.isFast))
        }
        var result: [ModelOption] = []
        for key in order {
            guard let members = groups[key] else { continue }
            let keys = Set(members.map { "\($0.effort ?? "")|\($0.isFast)" })
            guard members.count > 1, !key.hasPrefix("\u{0}"), keys.count == members.count else {
                result.append(contentsOf: members.map(\.option))
                continue
            }
            result.append(family(named: key, members))
        }
        // A family takes the stem its variants share as its id; should that be another
        // row's id, it takes its first variant's instead, which is unique by construction.
        let idCounts = Dictionary(result.map { ($0.id, 1) }, uniquingKeysWith: +)
        for index in result.indices where !result[index].variants.isEmpty && idCounts[result[index].id, default: 0] > 1 {
            result[index].id = result[index].variants[0].id
        }
        return result
    }

    private static func family(named name: String, _ members: [(option: ModelOption, effort: String?, isFast: Bool)]) -> ModelOption {
        let variants = members.map { ModelVariant(id: $0.option.id, effort: $0.effort, isFast: $0.isFast) }
        let lead = members.first { !$0.isFast } ?? members[0]
        let bakesEffort = variants.contains { $0.effort != nil }
        let efforts: [String]
        let defaultEffort: String?
        if bakesEffort {
            var seen = Set<String>()
            let listed = variants.compactMap(\.effort).filter { seen.insert($0).inserted }
            efforts = ModelOption.orderedEfforts(listed)
            // Devin lists a family's recommended variant first ("Medium", then "Low", "High"…)
            // or, when it has none, the scale from the bottom up; the bottom of the scale is
            // no recommendation, so such a family starts at medium, else high.
            defaultEffort = listed != efforts ? lead.effort
                : efforts.first { $0 == "medium" } ?? efforts.first { $0 == "high" } ?? lead.effort
        } else {
            let scaled = members.first { !$0.isFast && !$0.option.efforts.isEmpty } ?? members.first { !$0.option.efforts.isEmpty }
            efforts = scaled?.option.efforts ?? []
            defaultEffort = scaled?.option.defaultEffort
        }
        return ModelOption(
            id: sharedStem(variants.map(\.id)) ?? variants[0].id,
            name: name,
            detail: lead.option.detail,
            efforts: efforts,
            defaultEffort: defaultEffort,
            isDefault: members.contains { $0.option.isDefault },
            fastTier: variants.contains(where: \.isFast) ? "fast" : nil,
            variants: variants
        )
    }

    /// The words a provider appends to a model's name for its variants, read from the
    /// end: "GPT-6 Sol No Thinking Fast" is "GPT-6 Sol" at no effort, fast. "Thinking"
    /// counts only after an effort ("High Thinking", "No Thinking"); alone it names a
    /// model of its own ("Claude Opus 4.6 Thinking").
    static func parse(_ name: String) -> (base: String, effort: String?, isFast: Bool) {
        var words = name.split(separator: " ").map(String.init)
        var isFast = false
        var effort: String?
        if words.count > 1, words.last?.lowercased() == "fast" {
            isFast = true
            words.removeLast()
        }
        if words.count > 2, words.last?.lowercased() == "thinking" {
            let before = words[words.count - 2].lowercased()
            if before == "no" {
                effort = "none"
                words.removeLast(2)
            } else if let level = effortWord(before) {
                effort = level
                words.removeLast(2)
            }
        } else if words.count > 1, let last = words.last, let level = effortWord(last.lowercased()) {
            effort = level
            words.removeLast()
        }
        return (words.joined(separator: " "), effort, isFast)
    }

    private static func effortWord(_ word: String) -> String? {
        switch word {
        case "none": "none"
        case "minimal": "minimal"
        case "low": "low"
        case "medium": "medium"
        case "high": "high"
        case "xhigh", "x-high": "xhigh"
        case "max": "max"
        default: nil
        }
    }

    /// The longest prefix the ids share, cut back to the last separator: "claude-opus-5-5"
    /// for "claude-opus-5-5-low" and "claude-opus-5-5-max-fast".
    private static func sharedStem(_ ids: [String]) -> String? {
        guard var stem = ids.first else { return nil }
        for id in ids.dropFirst() {
            stem = String(zip(stem, id).prefix { $0 == $1 }.map(\.0))
        }
        if !ids.contains(stem) {
            while let last = stem.last, !"-_./".contains(last) { stem.removeLast() }
        }
        while let last = stem.last, "-_./".contains(last) { stem.removeLast() }
        return stem.count >= 2 ? stem : nil
    }

    // MARK: - Lines

    struct Lineage: Identifiable, Hashable {
        let key: String
        /// Newest first; the first is the row the list shows.
        var members: [ModelOption]

        var id: String { key }
        var newest: ModelOption { members[0] }
        var earlier: ArraySlice<ModelOption> { members.dropFirst() }
    }

    struct Layout: Hashable {
        /// The lines in the order the provider lists them.
        var lineages: [Lineage]
        /// Lines that are free, preview or experimental throughout, set aside together.
        var trials: [ModelOption]
    }

    static func lineages(_ list: [ModelOption]) -> Layout {
        struct Entry {
            let offset: Int
            let option: ModelOption
            let isTrial: Bool
            let version: [Int]
        }
        // Each name is read once: the sort below compares the same rows many times.
        var order: [String] = []
        var groups: [String: [Entry]] = [:]
        for (offset, option) in list.enumerated() {
            let key = lineageKey(option.name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(Entry(offset: offset, option: option, isTrial: isTrial(option.name), version: version(option.name)))
        }
        var lineages: [Lineage] = []
        var trials: [ModelOption] = []
        for key in order {
            guard let group = groups[key] else { continue }
            // Newest version first; a tie keeps the provider's order, and a free or preview
            // row never leads a line that has a regular one.
            let sorted = group.sorted { lhs, rhs in
                if lhs.isTrial != rhs.isTrial { return !lhs.isTrial }
                let order = compareVersions(lhs.version, rhs.version)
                if order != .orderedSame { return order == .orderedDescending }
                return lhs.offset < rhs.offset
            }
            if sorted.allSatisfy(\.isTrial) {
                trials.append(contentsOf: sorted.map(\.option))
            } else {
                lineages.append(Lineage(key: key, members: sorted.map(\.option)))
            }
        }
        return Layout(lineages: lineages, trials: trials)
    }

    /// Free, preview and experimental rows: trial channels rather than models to work with.
    static func isTrial(_ name: String) -> Bool {
        words(name.lowercased()).contains { trialWords.contains($0) }
    }

    private static let trialWords: Set<Substring> = ["free", "preview", "exp", "experimental"]
    /// Words that name a channel or a variant of a line, not the line.
    private static let channelWords: Set<Substring> = ["free", "preview", "exp", "experimental", "new", "beta", "highspeed", "contributor", "thinking"]

    /// The line a name belongs to: the name without its catalogue prefix, variant words,
    /// versions, context size, parentheticals and channel words. "Claude Opus 4.8",
    /// "claude-opus-5-5" and "Claude Opus 4.6 Thinking 1M" are all "claude opus"; "Kimi
    /// K2.7" and "Kimi K3" are "kimi"; "GLM-5.3 Flash" stays apart from "GLM-5.3" as "glm flash".
    /// Read by hand rather than by regular expressions: a catalogue of six hundred names
    /// is read on the main actor, and the expressions took a quarter of a second for it.
    static func lineageKey(_ name: String) -> String {
        let text = bareName(name)
        let spaced = text.split(separator: " ").filter { !isContextSize($0) }.joined(separator: " ")
        let base = parse(spaced).base
        let kept = words(base).compactMap { word -> Substring? in
            guard let first = word.first, !first.isNumber else { return nil }
            let stem = word.prefix { !$0.isNumber }
            // "k3", "m2.7" and "v4.1" are versions; "qwen3.8" is qwen and "hy4" is hy.
            if stem.count < word.count, ["k", "m", "v"].contains(stem) { return nil }
            return channelWords.contains(stem) ? nil : stem
        }
        let key = kept.joined(separator: " ")
        return key.isEmpty ? name.lowercased() : key
    }

    /// The first version number in a name, as its parts: "Claude Opus 5.5" → [5, 5],
    /// "claude-opus-4-8" → [4, 8], "GLM-5.3" and "glm-5p3" → [5, 3]. Parentheticals
    /// are left out, so a fused pairing does not borrow a version from its parts.
    static func version(_ name: String) -> [Int] {
        let text = bareName(name)
        guard let start = text.firstIndex(where: \.isNumber) else { return [] }
        var parts: [Int] = []
        var digits = ""
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character.isNumber {
                digits.append(character)
            } else if ".-p".contains(character), !digits.isEmpty,
                      text.index(after: index) < text.endIndex, text[text.index(after: index)].isNumber {
                parts.append(Int(digits) ?? 0)
                digits = ""
            } else {
                break
            }
            index = text.index(after: index)
        }
        if !digits.isEmpty { parts.append(Int(digits) ?? 0) }
        return parts
    }

    /// The name lowercased, without the catalogue prefix ("opencode/") or parentheticals.
    private static func bareName(_ name: String) -> String {
        var text = name.lowercased()
        if let slash = text.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        var result = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1; result.append(" "); continue }
            if character == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        return result
    }

    /// The words of a name split on spaces, dashes and underscores.
    private static func words(_ text: String) -> [Substring] {
        text.split { $0 == " " || $0 == "-" || $0 == "_" }
    }

    /// A context window written into a name: "1M", "256k".
    private static func isContextSize(_ word: Substring) -> Bool {
        guard let last = word.last, last == "m" || last == "k", word.count > 1 else { return false }
        return word.dropLast().allSatisfy { $0.isNumber || $0 == "." } && word.first?.isNumber == true
    }

    private static func compareVersions(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

extension ProviderKind {
    /// Providers that list each effort and Fast variant as a model of its own, so the
    /// catalogue is merged into families (see `ModelFamilies.collapsed`): Devin names
    /// every one ("Claude Opus 5.5 XHigh Fast"), Grok its Fast model ("Grok 4.7 Fast").
    var namesModelVariants: Bool { self == .devin || self == .grok }
}
