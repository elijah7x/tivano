import Foundation

extension HydraPrompts {
    /// A delegation block read while the reply holding it is still streaming: the entries
    /// whose closing brace has arrived, in the block's order, and whether the block itself
    /// has closed (its array's `]`, a bare entry's `}`, or the closing fence). Heads go
    /// out on these as they close, instead of once the whole block is written: a lead
    /// that takes a minute per brief has its first head at work while it writes the second.
    struct StreamedDelegations: Hashable, Sendable {
        var delegations: [HydraDelegation] = []
        var isComplete = false
    }

    /// The entries closed so far in a block body (what follows the opening fence), read
    /// without waiting for the JSON to be whole. The walk is over bytes: JSON's structure
    /// is ASCII, and a multi-byte character never holds an ASCII byte, so strings (with
    /// their escapes) and braces are tracked exactly, and a fence quoted inside a prompt is
    /// text like any other. An entry is read the moment its outermost brace closes, by the
    /// same rules as `delegations(in:)` (see `delegation(fromEntry:)`), and one that does
    /// not read is skipped as the whole-block parser skips it, so the two agree on the
    /// order and count of what goes out.
    static func streamedDelegations(inBody body: Substring) -> StreamedDelegations {
        var result = StreamedDelegations()
        let bytes = body.utf8
        var index = bytes.startIndex
        while index < bytes.endIndex, isJSONWhitespace(bytes[index]) { index = bytes.index(after: index) }
        guard index < bytes.endIndex else { return result }
        // The body opens an array, or is one bare entry; anything else is not readable yet.
        let isArray: Bool
        switch bytes[index] {
        case UInt8(ascii: "["):
            isArray = true
            index = bytes.index(after: index)
        case UInt8(ascii: "{"):
            isArray = false
        default:
            return result
        }
        var depth = 0
        var inString = false
        var escaped = false
        var entryStart = index
        // The body starts right after the opener's newline, so its first byte opens a line.
        var atLineStart = true
        while index < bytes.endIndex {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"):
                    if depth == 0 { entryStart = index }
                    depth += 1
                case UInt8(ascii: "}"):
                    depth -= 1
                    if depth == 0 {
                        // Braces are ASCII, so both ends sit on character boundaries.
                        if let json = JSONValue.parse(String(body[entryStart...index])), let delegation = delegation(fromEntry: json) {
                            result.delegations.append(delegation)
                        }
                        if !isArray {
                            result.isComplete = true
                            return result
                        }
                    } else if depth < 0 {
                        // A closer with nothing open: the block is broken past here, and
                        // nothing after it will read.
                        result.isComplete = true
                        return result
                    }
                case UInt8(ascii: "]") where depth == 0:
                    result.isComplete = true
                    return result
                case UInt8(ascii: "`") where depth == 0 && atLineStart:
                    // A fence opening a line outside any entry is the block's closer.
                    result.isComplete = true
                    return result
                default:
                    break
                }
            }
            atLineStart = byte == UInt8(ascii: "\n")
            index = bytes.index(after: index)
        }
        return result
    }

    /// One entry of a block read as a head's task: kept only with a prompt, titled from
    /// the prompt when it has no task, and carrying the announced name ("name", or "head")
    /// as-is when the lead gave one, for the spawner to resolve against the roster, and
    /// the project ("project", or "repo") the head is sent to, for the spawner to resolve
    /// against the sidebar. An entry may also name one of the pair's head profiles
    /// ("profile"), which the spawner resolves the same way; an unknown profile runs on
    /// the shared worker model.
    static func delegation(fromEntry entry: JSONValue) -> HydraDelegation? {
        guard let prompt = entry["prompt"]?.string?.trimmed, !prompt.isEmpty else { return nil }
        let task = entry["task"]?.string?.trimmed ?? ""
        let name = entry["name"]?.string?.trimmed
            ?? entry["head"]?.string?.trimmed
        let announced = (name?.isEmpty == false) ? name : nil
        let project = entry["project"]?.string?.trimmed
            ?? entry["repo"]?.string?.trimmed
        let profile = entry["profile"]?.string?.trimmed
        let files = (entry["files"]?.array ?? []).compactMap { $0.string?.trimmed }.filter { !$0.isEmpty }
        let continueHead = entry["continue"]?.string?.trimmed
        // A Chimera entry's suggested identity (or legacy "preset"): its 1-based number, as a number or a numeric string.
        let preset = entry["identity"]?.int ?? entry["preset"]?.int
        return HydraDelegation(role: entry["role"]?.string, preset: preset, task: task.isEmpty ? TextCleanup.singleLine(prompt, limit: 60) : task, prompt: prompt, name: announced, project: (project?.isEmpty == false) ? project : nil, profile: (profile?.isEmpty == false) ? profile : nil, files: files, filesGiven: entry["files"]?.array != nil, continueHead: (continueHead?.isEmpty == false) ? continueHead : nil)
    }

    fileprivate static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
    }
}
