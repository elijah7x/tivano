import Foundation

enum ThreadArtifactKind: String, CaseIterable, Identifiable, Sendable {
    case document
    case webpage
    case image
    case video

    var id: String { rawValue }
}

struct ThreadArtifact: Identifiable, Equatable, Sendable {
    var path: String
    var name: String
    var displayPath: String
    var mentionPath: String?
    var kind: ThreadArtifactKind
    var turnIndex: Int?
    var fileSize: Int64?

    var id: String { path }
}

enum ThreadArtifactCollector {
    private static let documentExtensions: Set<String> = [
        "md", "markdown", "mdx", "pdf", "txt", "rtf", "rtfd",
        "csv", "tsv", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key", "epub",
    ]
    private static let webpageExtensions: Set<String> = [
        "html", "htm", "xhtml", "mhtml", "webarchive",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
        "bmp", "tif", "tiff", "avif", "svg",
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi",
    ]
    private static let excludedDirectorySegments: [String] = [
        "/build.noindex/",
        "/DerivedData/",
        "/.build/",
        "/node_modules/",
        "/.git/",
    ]
    private static let remoteSchemePrefixes: [String] = [
        "http://", "https://", "ws://", "wss://", "ftp://",
        "mailto:", "data:", "javascript:", "about:", "tel:",
        "localhost:", "127.0.0.1:", "[::1]:",
    ]

    private static let markdownLinkRegex = try! NSRegularExpression(
        pattern: #"\]\(\s*(?:<([^>\n]+)>|([^)\s\n]+))"#
    )
    private static let backtickRegex = try! NSRegularExpression(
        pattern: #"`([^`\n]+)`"#
    )
    private static let plainPathRegex = try! NSRegularExpression(
        pattern: #"(?:file://|~|\.{1,2}|/)?(?:[^\s<>()\[\]{}"'`,;!?*，。、；：！？（）【】《》「」『』“”‘’]+/)*[^\s<>()\[\]{}"'`,;!?*/，。、；：！？（）【】《》「」『』“”‘’]+\.[A-Za-z0-9]{2,11}(?::\d+(?::\d+)?)?"#
    )

    static func kind(forPath path: String) -> ThreadArtifactKind? {
        guard let cleaned = cleanPathForClassification(path) else { return nil }
        let ext = (cleaned as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if documentExtensions.contains(ext) { return .document }
        if webpageExtensions.contains(ext) { return .webpage }
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    @concurrent
    static func collect(
        entries: [TimelineItem],
        turns: [TurnRecord],
        workingDirectory: String?
    ) async -> [ThreadArtifact] {
        let standardizedWorkDir: String? = workingDirectory.flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = trimmed.hasPrefix("~") ? (trimmed as NSString).expandingTildeInPath : trimmed
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        let workDirPrefix: String? = standardizedWorkDir.map { dir in
            dir == "/" ? "/" : dir + "/"
        }

        var excludedPaths: Set<String> = []
        for entry in entries {
            guard case .user(let message) = entry.content else { continue }
            for attachment in message.attachments {
                if let resolved = resolveStandardizedPath(attachment.path, workingDirectory: standardizedWorkDir) {
                    excludedPaths.insert(resolved)
                }
            }
        }

        let turnByID: [UUID: TurnRecord] = Dictionary(
            turns.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        var artifacts: [ThreadArtifact] = []
        var seen: Set<String> = []
        var visitedTurnIDs: Set<UUID> = []

        func consider(_ rawPath: String, turnIndex: Int?) {
            guard let resolved = resolveExistingArtifact(
                rawPath: rawPath,
                workingDirectory: standardizedWorkDir,
                workDirPrefix: workDirPrefix,
                excludedPaths: excludedPaths,
                seen: &seen,
                turnIndex: turnIndex
            ) else { return }
            artifacts.append(resolved)
        }

        func considerTurnTouchedPaths(_ turnID: UUID?) {
            guard let turnID, visitedTurnIDs.insert(turnID).inserted,
                  let turn = turnByID[turnID],
                  let touchedPaths = turn.touchedPaths else { return }
            for path in touchedPaths.reversed() {
                consider(path, turnIndex: turn.index)
            }
        }

        for entry in entries.reversed() {
            let entryTurnID: UUID?
            let entryTurnIndex: Int?
            if case .turnEnd(let summary) = entry.content {
                entryTurnID = entry.turnID ?? summary.turnID
                entryTurnIndex = (entry.turnID.flatMap { turnByID[$0]?.index }) ?? turnByID[summary.turnID]?.index
            } else {
                entryTurnID = entry.turnID
                entryTurnIndex = entry.turnID.flatMap { turnByID[$0]?.index }
            }

            switch entry.content {
            case .tool(let call):
                guard call.kind != .read else { break }
                if let images = call.images {
                    for image in images.reversed() {
                        consider(image.path, turnIndex: entryTurnIndex)
                    }
                }
                for edit in call.edits.reversed() {
                    consider(edit.path, turnIndex: entryTurnIndex)
                }
            case .turnEnd(let summary):
                if let files = summary.changes?.files {
                    for file in files.reversed() {
                        consider(file.path, turnIndex: entryTurnIndex)
                    }
                }
                considerTurnTouchedPaths(entryTurnID)
            case .assistant(let message):
                for candidate in extractPaths(from: message.text) {
                    consider(candidate, turnIndex: entryTurnIndex)
                }
            case .plan(let plan):
                for candidate in extractPaths(from: plan.markdown) {
                    consider(candidate, turnIndex: entryTurnIndex)
                }
            case .user, .reasoning, .todos, .notice:
                break
            }

            considerTurnTouchedPaths(entryTurnID)
        }

        for turn in turns.reversed() where !visitedTurnIDs.contains(turn.id) {
            guard let touchedPaths = turn.touchedPaths else { continue }
            for path in touchedPaths.reversed() {
                consider(path, turnIndex: turn.index)
            }
        }

        return artifacts
    }

    private static func cleanPathForClassification(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count > 2 {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")),
            trimmed.count > 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("file://") {
            if let url = URL(string: trimmed), url.isFileURL {
                trimmed = url.path
            } else {
                let dropped = String(trimmed.dropFirst("file://".count))
                trimmed = dropped.removingPercentEncoding ?? dropped
            }
        } else {
            if trimmed.contains("://") { return nil }
            for prefix in remoteSchemePrefixes where lower.hasPrefix(prefix) {
                return nil
            }
        }

        if let fragment = trimmed.firstIndex(of: "#") {
            trimmed = String(trimmed[..<fragment])
        }
        if let query = trimmed.firstIndex(of: "?") {
            trimmed = String(trimmed[..<query])
        }
        trimmed = stripLineColumnSuffix(trimmed)

        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func stripLineColumnSuffix(_ path: String) -> String {
        var result = path
        for _ in 0..<2 {
            guard let colon = result.lastIndex(of: ":") else { break }
            let suffix = result[result.index(after: colon)...]
            guard !suffix.isEmpty, suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { break }
            let prefix = String(result[..<colon])
            guard !prefix.isEmpty, !prefix.hasSuffix("/") else { break }
            result = prefix
        }
        return result
    }

    private static func resolveStandardizedPath(_ raw: String, workingDirectory: String?) -> String? {
        guard let cleaned = cleanPathForClassification(raw) else { return nil }
        let expanded: String
        if cleaned.hasPrefix("~") {
            expanded = (cleaned as NSString).expandingTildeInPath
        } else if cleaned.hasPrefix("/") {
            expanded = cleaned
        } else if let workingDirectory, !workingDirectory.isEmpty {
            expanded = workingDirectory == "/" ? "/" + cleaned : workingDirectory + "/" + cleaned
        } else {
            return nil
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func resolveExistingArtifact(
        rawPath: String,
        workingDirectory: String?,
        workDirPrefix: String?,
        excludedPaths: Set<String>,
        seen: inout Set<String>,
        turnIndex: Int?
    ) -> ThreadArtifact? {
        guard let kind = kind(forPath: rawPath) else { return nil }

        var candidates: [String] = []
        if let direct = resolveStandardizedPath(rawPath, workingDirectory: workingDirectory) {
            candidates.append(direct)
        }
        if let decoded = rawPath.removingPercentEncoding, decoded != rawPath,
           let decodedPath = resolveStandardizedPath(decoded, workingDirectory: workingDirectory),
           !candidates.contains(decodedPath) {
            candidates.append(decodedPath)
        }

        let fm = FileManager.default
        for standardized in candidates {
            guard !excludedPaths.contains(standardized) else { continue }
            guard !excludedDirectorySegments.contains(where: { standardized.contains($0) }) else { continue }
            guard seen.insert(standardized).inserted else { return nil }

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            let attributes = try? fm.attributesOfItem(atPath: standardized)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
            let name = (standardized as NSString).lastPathComponent

            let displayPath: String
            let mentionPath: String?
            if let workDirPrefix, standardized.hasPrefix(workDirPrefix) {
                let relative = String(standardized.dropFirst(workDirPrefix.count))
                displayPath = relative
                mentionPath = relative
            } else {
                displayPath = (standardized as NSString).abbreviatingWithTildeInPath
                mentionPath = nil
            }

            return ThreadArtifact(
                path: standardized,
                name: name,
                displayPath: displayPath,
                mentionPath: mentionPath,
                kind: kind,
                turnIndex: turnIndex,
                fileSize: fileSize
            )
        }

        return nil
    }

    private static func extractPaths(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var results: [String] = []

        for match in markdownLinkRegex.matches(in: text, range: fullRange) {
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard range.location != NSNotFound else { continue }
            let target = nsText.substring(with: range)
            if kind(forPath: target) != nil {
                results.append(target)
            }
        }

        for match in backtickRegex.matches(in: text, range: fullRange) {
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            let candidate = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if kind(forPath: candidate) != nil {
                results.append(candidate)
            }
        }

        for match in plainPathRegex.matches(in: text, range: fullRange) {
            let candidate = nsText.substring(with: match.range)
            if kind(forPath: candidate) != nil {
                results.append(candidate)
            }
        }

        return results
    }
}
