import Foundation

/// Resolves a markdown link URL into an external URL, an existing local file URL, or a missing local path.
enum MarkdownLinkTarget: Equatable {
    case web(URL)
    case file(URL)
    case missing(String)

    static let autolinkExtensions: Set<String> = [
        // Images
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
        "avif", "ico", "svg", "psd", "raw", "dng",
        // Video / audio
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "gifv", "mp3", "m4a", "wav",
        "flac", "aac", "ogg", "opus",
        // Webpages
        "html", "htm", "xhtml", "mhtml", "webarchive",
        // Documents / data / design
        "pdf", "md", "markdown", "mdx", "txt", "rtf", "rtfd", "csv", "tsv",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "epub", "sketch", "fig", "xd",
        // Code / config / archives
        "swift", "py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "jsonc",
        "jsonl", "yaml", "yml", "toml", "xml", "plist", "xcconfig", "xcstrings",
        "css", "scss", "less", "sql", "sh", "zsh", "bash", "rb", "go", "rs",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "cs", "php",
        "lua", "r", "dart", "zig", "vue", "svelte", "astro", "proto", "graphql",
        "env", "ini", "conf", "log", "diff", "patch", "zip", "tar", "gz", "tgz",
        "dmg", "pkg",
    ]

    private static let rootedMacOSPrefixes = [
        "/Users/", "/Volumes/", "/Applications/", "/Library/",
        "/tmp/", "/private/", "/var/", "/opt/", "/System/",
    ]

    private static let codeSpanForbiddenCharacters: Set<Character> = Set("|;&><$=*?\n\r\t")
    private static let proseTrailingPunctuation: Set<Character> = Set(".,;:!?)]}>\"'，。；：！？】）》")

    /// Scans prose runs for `file:///...`, `~/...`, rooted macOS paths, relative multi-segment
    /// paths, and bare `http://localhost` / `http://127.0.0.1` URLs. Non-localhost `http(s)://`
    /// URLs are matched and skipped without linking so paths in their query/fragment stay untouched.
    private static let prosePathPattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9@._/:~-])(?:(?i:https?://)[^\s<>()"'，。；：！？】）》]+|(?i:file:///)[^\s<>()"'，。；：！？】）》]+|(?:~/|/(?:Users|Volumes|Applications|Library|tmp|private|var|opt|System)/)[^\s<>()"'，。；：！？】）》]+|(?:(?:\.\.?/)+|[A-Za-z0-9_\p{L}\p{N}\p{M}-]+/(?!(?:Users|Volumes|Applications|Library|tmp|private|var|opt|System)/))(?:[A-Za-z0-9_.\p{L}\p{N}\p{M}-]+/)*[A-Za-z0-9_.\p{L}\p{N}\p{M}-]+\.[A-Za-z0-9]{1,16}(?::\d+(?::\d+)?)?)"#,
        options: []
    )

    static func makeAutolinkURL(for rawCandidate: String) -> URL? {
        let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains("\n"), !candidate.contains("\r") else {
            return nil
        }
        if isLocalhostURL(candidate) {
            return URL(string: candidate)
                ?? candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        }
        let lowered = candidate.lowercased()
        if lowered.hasPrefix("file:///") {
            let rawPath = String(candidate.dropFirst("file://".count))
            let decoded = rawPath.removingPercentEncoding ?? rawPath
            guard decoded.hasPrefix("/"), hasAutolinkExtension(decoded) else { return nil }
            return URL(fileURLWithPath: decoded)
        }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("mailto:") || candidate.hasPrefix("//") {
            return nil
        }
        guard hasAutolinkExtension(candidate) else { return nil }
        if candidate.hasPrefix("~/") {
            let expanded = (candidate as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded)
            }
            var components = URLComponents()
            components.path = candidate
            return components.url
        }
        if candidate.hasPrefix("/") {
            return URL(fileURLWithPath: candidate)
        }
        // RFC 3986 forbids `:` in the first segment of a relative-path reference; prepend `./`
        // so `Foo.swift:12` or `欢迎.md:12` stays a relative path URL instead of a scheme.
        let firstSegment: Substring
        if let slash = candidate.firstIndex(of: "/") {
            firstSegment = candidate[..<slash]
        } else {
            firstSegment = candidate[...]
        }
        let relativePath = firstSegment.contains(":") ? "./" + candidate : candidate
        var components = URLComponents()
        components.path = relativePath
        return components.url
    }

    static func autolinkedLocalPaths(_ parsed: AttributedString) -> AttributedString {
        var out: AttributedString?
        for run in parsed.runs {
            let slice = parsed[run.range]
            if run.link != nil {
                out?.append(AttributedString(slice))
                continue
            }
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                let text = String(slice.characters)
                if let url = autolinkCodeSpanURL(text) {
                    var built = beginAutolinkOutput(&out, parsed: parsed, upTo: run.range.lowerBound)
                    var linked = AttributedString(slice)
                    linked.link = url
                    built.append(linked)
                    out = built
                } else {
                    out?.append(AttributedString(slice))
                }
                continue
            }
            guard let pattern = prosePathPattern, mayContainLocalPath(slice) else {
                out?.append(AttributedString(slice))
                continue
            }
            let text = String(slice.characters)
            let ns = text as NSString
            let matches = pattern.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            guard matches.contains(where: { proseCandidate($0, in: text)?.url != nil }) else {
                out?.append(AttributedString(slice))
                continue
            }
            var built = beginAutolinkOutput(&out, parsed: parsed, upTo: run.range.lowerBound)
            var cursor = 0
            var pieceIndex = slice.characters.startIndex
            var pieceOffset = 0
            var textIndex = text.startIndex
            var textOffset = 0
            func piece(_ span: Range<Int>) -> AttributedString {
                let lo = slice.characters.index(pieceIndex, offsetBy: span.lowerBound - pieceOffset)
                let hi = slice.characters.index(lo, offsetBy: span.count)
                pieceIndex = hi
                pieceOffset = span.upperBound
                return AttributedString(slice[lo..<hi])
            }
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                let distance = text.distance(from: textIndex, to: range.lowerBound)
                let start = textOffset + distance
                textIndex = text.index(textIndex, offsetBy: distance)
                textOffset = start
                guard start >= cursor else { continue }
                guard let candidate = proseCandidate(match, in: text) else { continue }
                let end = start + candidate.text.count
                if start > cursor { built.append(piece(cursor..<start)) }
                if let url = candidate.url {
                    var linkSlice = piece(start..<end)
                    linkSlice.link = url
                    built.append(linkSlice)
                } else if end > cursor {
                    built.append(piece(start..<end))
                }
                cursor = end
            }
            let count = textOffset + text.distance(from: textIndex, to: text.endIndex)
            if cursor < count { built.append(piece(cursor..<count)) }
            out = built
        }
        return out ?? parsed
    }

    private static func beginAutolinkOutput(
        _ out: inout AttributedString?,
        parsed: AttributedString,
        upTo lowerBound: AttributedString.Index
    ) -> AttributedString {
        if let existing = out {
            out = nil
            return existing
        }
        return lowerBound > parsed.startIndex
            ? AttributedString(parsed[parsed.startIndex..<lowerBound])
            : AttributedString()
    }

    private static func mayContainLocalPath(_ slice: AttributedSubstring) -> Bool {
        slice.unicodeScalars.contains { $0.value == 47 }
    }

    private static func autolinkCodeSpanURL(_ raw: String) -> URL? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.hasPrefix("-"),
              !candidate.contains(where: { codeSpanForbiddenCharacters.contains($0) }) else {
            return nil
        }
        let lowered = candidate.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("mailto:") || candidate.hasPrefix("//") {
            return nil
        }
        if lowered.hasPrefix("file:///") || candidate.hasPrefix("~/") {
            return makeAutolinkURL(for: candidate)
        }
        if candidate.hasPrefix("/") {
            guard rootedMacOSPrefixes.contains(where: { candidate.hasPrefix($0) }) else {
                return nil
            }
            return makeAutolinkURL(for: candidate)
        }
        guard !candidate.contains(where: \.isWhitespace), !candidate.contains("://") else {
            return nil
        }
        let stripped = stripSyntacticLineColumnSuffix(from: candidate)
        guard !stripped.contains(":") else {
            return nil
        }
        return makeAutolinkURL(for: candidate)
    }

    private static func proseCandidate(_ match: NSTextCheckingResult, in text: String) -> (text: String, url: URL?)? {
        guard let range = Range(match.range, in: text) else { return nil }
        var matchText = String(text[range])
        while let last = matchText.last, proseTrailingPunctuation.contains(last) {
            matchText.removeLast()
        }
        guard !matchText.isEmpty else { return nil }
        let lowered = matchText.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard isLocalhostURL(matchText) else { return (matchText, nil) }
            return (matchText, makeAutolinkURL(for: matchText))
        }
        return (matchText, makeAutolinkURL(for: matchText))
    }

    private static func isLocalhostURL(_ candidate: String) -> Bool {
        let lowered = candidate.lowercased()
        let prefixLength: Int
        if lowered.hasPrefix("http://localhost") {
            prefixLength = "http://localhost".count
        } else if lowered.hasPrefix("http://127.0.0.1") {
            prefixLength = "http://127.0.0.1".count
        } else {
            return false
        }
        var index = candidate.index(candidate.startIndex, offsetBy: prefixLength)
        if index == candidate.endIndex { return true }
        if candidate[index] == ":" {
            index = candidate.index(after: index)
            let portStart = index
            while index < candidate.endIndex, candidate[index] >= "0", candidate[index] <= "9" {
                index = candidate.index(after: index)
            }
            guard index > portStart else { return false }
            if index == candidate.endIndex { return true }
        }
        return candidate[index] == "/"
    }

    private static func hasAutolinkExtension(_ rawPath: String) -> Bool {
        let stripped = stripSyntacticLineColumnSuffix(from: rawPath)
        guard !stripped.isEmpty, !stripped.hasSuffix("/") else { return false }
        let fileName: Substring
        if let slash = stripped.lastIndex(of: "/") {
            fileName = stripped[stripped.index(after: slash)...]
        } else {
            fileName = stripped[...]
        }
        guard let dot = fileName.lastIndex(of: ".") else { return false }
        let stem = fileName[..<dot]
        let ext = fileName[fileName.index(after: dot)...]
        guard !stem.isEmpty, !stem.allSatisfy({ $0 == "." }), !ext.isEmpty else {
            return false
        }
        return autolinkExtensions.contains(ext.lowercased())
    }

    private static func stripSyntacticLineColumnSuffix(from path: String) -> String {
        guard let first = stripPositiveTrailingNumber(from: path) else { return path }
        if let second = stripPositiveTrailingNumber(from: first) {
            return second
        }
        return first
    }

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
