import CoreGraphics
import Foundation

struct FileMentionLabel: Equatable, Sendable {
    var name: String
    var detail: String? = nil
}

struct FileMentionSuggestionPlacement: Equatable, Sendable {
    var size: CGSize
    var opensAbove: Bool
}

enum FileMentions {
    /// How many spaces a path may hold before the scan stops looking further.
    static let maxSpacesInPath = 6

    static func tokens(in text: String, resolve: (String) -> Bool?) -> [(range: NSRange, path: String)] {
        var results: [(range: NSRange, path: String)] = []
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        var utf16Offset = 0
        var atBoundary = true

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "@", atBoundary {
                let tokenStartOffset = utf16Offset
                var cursor = scalars.index(after: index)
                var cursorOffset = utf16Offset + 1
                let pathStart = cursor

                while cursor < scalars.endIndex, !scalars[cursor].properties.isWhitespace {
                    cursorOffset += scalars[cursor].utf16.count
                    cursor = scalars.index(after: cursor)
                }

                if cursor > pathStart {
                    // A picked path may hold spaces ("Docs/My Notes.md"): the run is extended
                    // over single spaces and the longest candidate that resolves wins, so the
                    // chip covers the whole path on insertion and again on reload.
                    var match: (end: String.UnicodeScalarView.Index, endOffset: Int)?
                    if resolve(String(scalars[pathStart..<cursor])) != nil { match = (cursor, cursorOffset) }
                    var probe = cursor
                    var probeOffset = cursorOffset
                    for _ in 0..<Self.maxSpacesInPath {
                        guard probe < scalars.endIndex, scalars[probe] == " " else { break }
                        var next = scalars.index(after: probe)
                        var nextOffset = probeOffset + 1
                        guard next < scalars.endIndex, !scalars[next].properties.isWhitespace else { break }
                        while next < scalars.endIndex, !scalars[next].properties.isWhitespace {
                            nextOffset += scalars[next].utf16.count
                            next = scalars.index(after: next)
                        }
                        if resolve(String(scalars[pathStart..<next])) != nil { match = (next, nextOffset) }
                        probe = next
                        probeOffset = nextOffset
                    }
                    if let match {
                        results.append((
                            range: NSRange(location: tokenStartOffset, length: match.endOffset - tokenStartOffset),
                            path: String(scalars[pathStart..<match.end])
                        ))
                        cursor = match.end
                        cursorOffset = match.endOffset
                    }
                }

                index = cursor
                utf16Offset = cursorOffset
                atBoundary = false
                continue
            }

            atBoundary = scalar.properties.isWhitespace
            utf16Offset += scalar.utf16.count
            index = scalars.index(after: index)
        }

        return results
    }

    static func labels(for paths: [String]) -> [String: FileMentionLabel] {
        var uniquePaths: [String] = []
        var seen: Set<String> = []
        for path in paths where seen.insert(path).inserted {
            uniquePaths.append(path)
        }

        struct Entry {
            let path: String
            let name: String
            let parents: [String]
        }

        var groups: [String: [Entry]] = [:]
        for path in uniquePaths {
            let (name, parents) = splitComponents(path)
            groups[name, default: []].append(Entry(path: path, name: name, parents: parents))
        }

        var result: [String: FileMentionLabel] = [:]
        result.reserveCapacity(uniquePaths.count)

        for (name, entries) in groups {
            if entries.count == 1 {
                result[entries[0].path] = FileMentionLabel(name: name, detail: nil)
                continue
            }

            var depths = entries.map { $0.parents.isEmpty ? 0 : 1 }

            while true {
                var buckets: [String?: [Int]] = [:]
                for index in entries.indices {
                    let depth = depths[index]
                    let candidate: String? = depth == 0
                        ? nil
                        : entries[index].parents.suffix(depth).joined(separator: "/")
                    buckets[candidate, default: []].append(index)
                }

                var grew = false
                for indices in buckets.values where indices.count > 1 {
                    for index in indices where depths[index] < entries[index].parents.count {
                        depths[index] += 1
                        grew = true
                    }
                }

                if !grew {
                    for index in entries.indices {
                        let depth = depths[index]
                        let detail: String? = depth == 0
                            ? nil
                            : entries[index].parents.suffix(depth).joined(separator: "/")
                        result[entries[index].path] = FileMentionLabel(name: name, detail: detail)
                    }
                    break
                }
            }
        }

        return result
    }

    static func parentDirectory(for path: String) -> String {
        splitComponents(path).parents.joined(separator: "/")
    }

    static func suggestionPlacement(
        desiredHeight: CGFloat,
        preferredWidth: CGFloat = 450,
        containerWidth: CGFloat,
        spaceAbove: CGFloat? = nil,
        spaceBelow: CGFloat? = nil,
        minAboveHeight: CGFloat = 148
    ) -> FileMentionSuggestionPlacement {
        let width = containerWidth > 0 ? min(preferredWidth, max(300, floor(containerWidth))) : preferredWidth
        guard let spaceAbove, let spaceBelow else {
            return FileMentionSuggestionPlacement(
                size: CGSize(width: width, height: desiredHeight),
                opensAbove: true
            )
        }
        if spaceAbove >= minAboveHeight || spaceAbove >= spaceBelow {
            return FileMentionSuggestionPlacement(
                size: CGSize(width: width, height: min(desiredHeight, max(70, floor(spaceAbove)))),
                opensAbove: true
            )
        }
        return FileMentionSuggestionPlacement(
            size: CGSize(width: width, height: min(desiredHeight, max(70, floor(spaceBelow)))),
            opensAbove: false
        )
    }

    private static func splitComponents(_ path: String) -> (name: String, parents: [String]) {
        var trimmed = path[...]
        while trimmed.last == "/" {
            trimmed = trimmed.dropLast()
        }
        if trimmed.isEmpty {
            return (name: path, parents: [])
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.last else {
            return (name: String(trimmed), parents: [])
        }
        return (name: name, parents: Array(parts.dropLast()))
    }
}
