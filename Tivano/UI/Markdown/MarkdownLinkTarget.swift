import Foundation

/// Resolves a markdown link URL into an external URL, an existing local file URL, or a missing local path.
enum MarkdownLinkTarget: Equatable {
    case web(URL)
    case file(URL)
    case missing(String)

    static func resolve(_ url: URL, base: String?) -> MarkdownLinkTarget {
        let path: String
        if let scheme = url.scheme {
            guard scheme.caseInsensitiveCompare("file") == .orderedSame else {
                // `Foo.swift:12` parses with scheme `Foo.swift`; an existing local file wins.
                if url.host == nil, let raw = url.absoluteString.removingPercentEncoding,
                   case .file(let local) = resolve(raw, base: base) {
                    return .file(local)
                }
                return .web(url)
            }
            path = url.path
        } else {
            guard url.host == nil else {
                return .web(url)
            }
            path = url.path
        }
        return resolve(path, base: base)
    }

    private static func resolve(_ rawPath: String, base: String?) -> MarkdownLinkTarget {
        var path = rawPath
        guard !path.isEmpty else {
            return .missing("")
        }
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        if !path.hasPrefix("/") {
            guard let base, !base.isEmpty else {
                return .missing(path)
            }
            let expandedBase = base.hasPrefix("~") ? (base as NSString).expandingTildeInPath : base
            path = standardize(expandedBase.hasSuffix("/") ? expandedBase + path : expandedBase + "/" + path)
        }
        if FileManager.default.fileExists(atPath: path) {
            return .file(URL(fileURLWithPath: path))
        }
        if let stripped = stripLineColumnSuffix(from: path) {
            return .file(URL(fileURLWithPath: stripped))
        }
        return .missing(path)
    }

    private static func standardize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !absolute {
                    parts.append(part)
                }
            } else {
                parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }

    private static func stripLineColumnSuffix(from path: String) -> String? {
        guard let first = stripPositiveTrailingNumber(from: path) else { return nil }
        if isExistingNonDirectory(first) {
            return first
        }
        if let second = stripPositiveTrailingNumber(from: first), isExistingNonDirectory(second) {
            return second
        }
        return nil
    }

    private static func stripPositiveTrailingNumber(from path: String) -> String? {
        guard let colon = path.lastIndex(of: ":") else { return nil }
        let digits = path[path.index(after: colon)...]
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(digits), value > 0 else {
            return nil
        }
        let stripped = String(path[..<colon])
        guard !stripped.isEmpty, !stripped.hasSuffix("/") else { return nil }
        return stripped
    }

    private static func isExistingNonDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
