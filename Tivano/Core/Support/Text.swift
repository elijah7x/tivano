import Foundation

enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tivano"
    static let isDevelopment = Bundle.main.bundleIdentifier == "dev.tivano.Tivano.dev"
    static let libraryName = isDevelopment ? "Tivano Dev" : "Tivano"
    static let stateDirectoryName = isDevelopment ? ".tivano-dev" : ".tivano"
    static let numericVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
    static let version = (isDevelopment ? "dev-" : "") + numericVersion
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
}

enum AppText {
    /// The catalog's translation of an English UI string; a key it does not know comes back unchanged.
    static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

enum TextCleanup {
    static func stripANSI(_ text: String) -> String {
        text.replacing(#/\x1B\[[0-9;?]*[ -/]*[@-~]/#, with: "")
    }

    /// The last meaningful lines of process output, for error messages.
    static func lastLines(_ text: String, count: Int = 4) -> String? {
        let lines = stripANSI(text)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(count).joined(separator: "\n")
    }

    static func singleLine(_ text: String, limit: Int = 120) -> String {
        let remaining = text.drop(while: \.isNewline)
        let end = remaining.firstIndex(where: \.isNewline) ?? remaining.endIndex
        let line = remaining[..<end].trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// Model prose never ships an em dash. It is the tell of a machine-written
    /// paragraph, so every string a model writes for the thread passes through here:
    /// replies as they stream and as they land, thinking, plans, generated titles and
    /// commit messages. The dash becomes a plain hyphen with the spacing around it kept,
    /// so "works — every time" reads "works - every time" and "ships—sometimes" reads
    /// "ships-sometimes".
    ///
    /// The en dash stays: it is the correct mark in a range, as in "lines 10–20".
    static func withoutEmDashes(_ text: String) -> String {
        guard mayContainEmDash(text), text.contains(where: { isEmDash($0) }) else { return text }
        return String(text.map { isEmDash($0) ? "-" : $0 })
    }

    /// Whether any dash scalar is in the bytes, checked without walking graphemes: every
    /// streamed delta and every stored message passes through here, and model prose is
    /// full of other E2-led scalars (curly quotes, ellipses, en dashes) that made the
    /// lead-byte test alone let most of it through to the slow path.
    private static func mayContainEmDash(_ text: String) -> Bool {
        var utf8 = text.utf8.makeIterator()
        while let byte = utf8.next() {
            guard byte == 0xE2, let second = utf8.next() else { continue }
            if second == 0x80 {
                // U+2014 and U+2015: E2 80 94, E2 80 95.
                guard let third = utf8.next() else { return false }
                if third == 0x94 || third == 0x95 { return true }
            } else if second == 0xB8 {
                // U+2E3A and U+2E3B: E2 B8 BA, E2 B8 BB.
                guard let third = utf8.next() else { return false }
                if third == 0xBA || third == 0xBB { return true }
            }
        }
        return false
    }

    /// The em dash and its longer relatives: the horizontal bar, and the two- and
    /// three-em dashes.
    private static func isEmDash(_ character: Character) -> Bool {
        switch character {
        case "\u{2014}", "\u{2015}", "\u{2E3A}", "\u{2E3B}": true
        default: false
        }
    }
}

enum SimpleDiff {
    /// Past this much text a reported edit keeps its line counts and drops the hunk: the diff
    /// of a whole generated file would otherwise sit in the thread document forever and be
    /// encoded with every save. The same cap bounds command diffs (`ThreadRuntime.fileEdits`).
    static let diffLimit = 200_000

    /// Unchanged lines kept on each side of a change; hunks closer than twice that merge.
    private static let contextLines = 3

    /// A compact unified diff between two texts, one hunk per run of changes with context.
    static func unified(old: String, new: String) -> FileEdit.Stats {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        guard old.utf8.count + new.utf8.count <= diffLimit else {
            // Too large for an exact diff, so count by the unchanged head and tail instead.
            var prefix = 0
            while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
                prefix += 1
            }
            var suffix = 0
            while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
                  oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
                suffix += 1
            }
            return FileEdit.Stats(diff: nil, additions: newLines.count - prefix - suffix, deletions: oldLines.count - prefix - suffix)
        }

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty else {
            return FileEdit.Stats(diff: nil, additions: 0, deletions: 0)
        }

        // Walk both texts together, emitting the merged line stream a unified diff is cut from.
        var ops: [DiffOp] = []
        ops.reserveCapacity(oldLines.count + newLines.count)
        var i = 0
        var j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                ops.append(.deletion(text: oldLines[i], old: i + 1))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                ops.append(.addition(text: newLines[j], new: j + 1))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                ops.append(.context(text: oldLines[i], old: i + 1, new: j + 1))
                i += 1
                j += 1
            } else {
                break
            }
        }

        let changes = ops.indices.filter { ops[$0].isChange }
        var hunks: [String] = []
        var groupStart = changes[0]
        var groupEnd = changes[0]
        func appendHunk() {
            let start = max(0, groupStart - contextLines)
            let end = min(ops.count - 1, groupEnd + contextLines)
            let slice = ops[start...end]
            let oldStart = slice.compactMap(\.oldNumber).first ?? 0
            let newStart = slice.compactMap(\.newNumber).first ?? 0
            let oldCount = slice.count { $0.oldNumber != nil }
            let newCount = slice.count { $0.newNumber != nil }
            var lines = ["@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"]
            lines += slice.map(\.line)
            hunks.append(lines.joined(separator: "\n"))
        }
        for change in changes.dropFirst() {
            if change - groupEnd <= 2 * contextLines + 1 {
                groupEnd = change
            } else {
                appendHunk()
                groupStart = change
                groupEnd = change
            }
        }
        appendHunk()
        return FileEdit.Stats(diff: hunks.joined(separator: "\n"), additions: inserted.count, deletions: removed.count)
    }
}

/// One line of the merged stream a unified diff is assembled from, numbered from one.
private enum DiffOp {
    case context(text: String, old: Int, new: Int)
    case deletion(text: String, old: Int)
    case addition(text: String, new: Int)

    var oldNumber: Int? {
        switch self {
        case .context(_, let old, _): old
        case .deletion(_, let old): old
        case .addition: nil
        }
    }

    var newNumber: Int? {
        switch self {
        case .context(_, _, let new): new
        case .addition(_, let new): new
        case .deletion: nil
        }
    }

    var isChange: Bool {
        switch self {
        case .context: false
        case .deletion, .addition: true
        }
    }

    var line: String {
        switch self {
        case .context(let text, _, _): " " + text
        case .deletion(let text, _): "-" + text
        case .addition(let text, _): "+" + text
        }
    }
}

extension FileEdit {
    struct Stats {
        var diff: String?
        var additions: Int
        var deletions: Int
    }

    init(path: String, old: String, new: String) {
        let stats = SimpleDiff.unified(old: old, new: new)
        self.init(path: path, diff: stats.diff, additions: stats.additions, deletions: stats.deletions)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// The string without leading or trailing whitespace and newlines. The one trim
    /// every call site means; narrower sets keep `trimmingCharacters(in:)`.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
