import Foundation
import Darwin

struct NativeFileTools: Sendable {
    let workingDirectory: String

    private static let readLimit = 1_000_000
    private static let mutations = Mutations()

    private actor Mutations {
        func run(_ operation: @Sendable () throws -> Void) rethrows {
            try operation()
        }
    }
    private static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "build", "dist", "DerivedData", "Pods", "target", ".venv", "venv"]

    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    private func outsideProject() -> ProviderError {
        .failed(String(format: localized("That path is outside the project. Stay inside %@."), workingDirectory))
    }

    private func systemError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func realURL(_ url: URL) throws -> URL {
        guard let resolved = Darwin.realpath(url.path, nil) else { throw systemError() }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func projectRoot() throws -> URL {
        try realURL(URL(fileURLWithPath: workingDirectory).standardizedFileURL)
    }

    private func contains(_ url: URL, in root: URL) -> Bool {
        url.pathComponents.starts(with: root.pathComponents)
    }

    /// Canonicalize existing ancestors too, so a new nested file cannot escape
    /// through a symlink. Actual I/O subsequently walks only canonical components.
    func resolveURL(_ path: String) throws -> URL {
        try resolveURL(path, root: projectRoot())
    }

    private func resolveURL(_ path: String, root: URL) throws -> URL {
        let trimmed = path.trimmed
        guard !trimmed.isEmpty else { throw ProviderError.failed("A file path is required.") }
        guard !trimmed.utf8.contains(0) else {
            throw ProviderError.failed(localized("A file path must not contain a null character."))
        }
        let candidate = (trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
            ? URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            : URL(fileURLWithPath: workingDirectory).appendingPathComponent(trimmed)).standardizedFileURL
        var ancestor = candidate
        var suffix: [String] = []
        var info = stat()
        while Darwin.lstat(ancestor.path, &info) != 0 {
            guard errno == ENOENT, ancestor.path != "/" else { throw systemError() }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        // realpath rejects dangling/cyclic links instead of treating them as absent.
        let realAncestor = try realURL(ancestor)
        guard contains(realAncestor, in: root) else { throw outsideProject() }
        let target = suffix.reduce(realAncestor) { $0.appendingPathComponent($1) }
        guard contains(target, in: root) else { throw outsideProject() }
        return target
    }

    // Apple XNU open(2)/rename(2): relative openat/renameat use the directory fd;
    // O_NOFOLLOW protects only the final component, hence the one-component walk.
    // This does not guard against an already-open directory being moved elsewhere.
    private func openDirectories(_ components: [String], from base: Int32, create: Bool = false) throws -> Int32 {
        var current = Darwin.openat(base, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw systemError() }
        do {
            for component in components {
                try Task.checkCancellation()
                var next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard Darwin.mkdirat(current, component, mode_t(0o777)) == 0 || errno == EEXIST else { throw systemError() }
                    next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw systemError() }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func withRoot<T>(_ body: (URL, Int32) throws -> T) throws -> T {
        let root = try projectRoot()
        let slash = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard slash >= 0 else { throw systemError() }
        defer { Darwin.close(slash) }
        let fd = try openDirectories(Array(root.pathComponents.dropFirst()), from: slash)
        defer { Darwin.close(fd) }
        return try body(root, fd)
    }

    private func relativeComponents(_ url: URL, root: URL) throws -> [String] {
        guard contains(url, in: root) else { throw outsideProject() }
        return Array(url.pathComponents.dropFirst(root.pathComponents.count))
    }

    private func withParent<T>(_ url: URL, root: URL, rootFD: Int32, create: Bool = false,
                               _ body: (Int32, String) throws -> T) throws -> T {
        let components = try relativeComponents(url, root: root)
        let parent = try openDirectories(Array(components.dropLast()), from: rootFD, create: create)
        defer { Darwin.close(parent) }
        return try body(parent, components.last ?? ".")
    }

    private func withFile<T>(parent: Int32, name: String, _ body: (Int32) throws -> T) throws -> T {
        let fd = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw systemError() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ProviderError.failed(localized("That path is not a regular file."))
        }
        return try body(fd)
    }

    private func readChunks(_ fd: Int32, _ consume: (Data) throws -> Bool) throws {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw systemError() }
            guard count > 0 else { break }
            if try !consume(Data(buffer.prefix(count))) { break }
        }
        try Task.checkCancellation()
    }

    private func readData(_ fd: Int32, limit: Int? = nil) throws -> Data {
        var data = Data()
        try readChunks(fd) { chunk in
            data.append(chunk)
            return limit.map { data.count <= $0 } ?? true
        }
        if let limit, data.count > limit {
            var info = stat()
            guard Darwin.fstat(fd, &info) == 0 else { throw systemError() }
            throw ProviderError.failed("That file is too large to read (\(info.st_size) bytes).")
        }
        return data
    }

    private func replaceFile(parent: Int32, name: String, data: Data) throws {
        var info = stat()
        let exists = Darwin.fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        if !exists, errno != ENOENT { throw systemError() }
        if exists, info.st_mode & S_IFMT != S_IFREG {
            throw ProviderError.failed(localized("That path is not a regular file."))
        }
        let temporary = ".tivano-" + UUID().uuidString
        let fd = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o666))
        guard fd >= 0 else { throw systemError() }
        defer {
            Darwin.close(fd)
            Darwin.unlinkat(parent, temporary, 0)
        }
        if exists {
            guard Darwin.fchmod(fd, info.st_mode & mode_t(0o777)) == 0 else { throw systemError() }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw systemError() }
                offset += count
            }
        }
        try Task.checkCancellation()
        guard Darwin.renameat(parent, temporary, parent, name) == 0 else { throw systemError() }
    }

    private func directoryNames(_ fd: Int32) throws -> [String] {
        let copy = Darwin.openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw systemError() }
        guard let directory = Darwin.fdopendir(copy) else {
            let error = systemError()
            Darwin.close(copy)
            throw error
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else { throw systemError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    private func entryInfo(parent: Int32, name: String) throws -> stat {
        var info = stat()
        guard Darwin.fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemError() }
        return info
    }

    func displayPath(_ path: String) -> String {
        let trimmed = path.trimmed
        if trimmed.isEmpty { return workingDirectory }
        let root = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        if trimmed.hasPrefix("/"), contains(URL(fileURLWithPath: trimmed).standardizedFileURL, in: root) {
            return ToolTitles.relativePath(trimmed, to: workingDirectory)
        }
        return trimmed
    }

    @concurrent func readFile(_ path: String, startLine: Int? = nil, lineCount: Int? = nil) async throws -> String {
        try Task.checkCancellation()
        let data = try withRoot { root, rootFD in
            let url = try resolveURL(path, root: root)
            return try withParent(url, root: root, rootFD: rootFD) { parent, name in
                try withFile(parent: parent, name: name) { try readData($0, limit: Self.readLimit) }
            }
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ProviderError.failed("That file is not readable as text.")
        }
        if startLine != nil || lineCount != nil {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let first = max(1, startLine ?? 1)
            guard first <= lines.count else { return "(the file has \(lines.count) lines; start_line \(first) is past the end)" }
            let count = max(1, lineCount ?? 200)
            let last = first - 1 + min(count, lines.count - first + 1)
            let slice = lines[(first - 1)..<last].joined(separator: "\n")
            return "(lines \(first)-\(last) of \(lines.count))\n" + slice
        }
        // Bytes bound characters, so a file under the limit skips the grapheme count.
        guard text.utf8.count > 60_000 else { return text }
        let characterCount = text.count
        if characterCount > 60_000 { return String(text.prefix(60_000)) + "\n…(truncated, \(characterCount) chars total; read the rest with start_line and line_count)" }
        return text
    }

    @concurrent func writeFile(path: String, content: String) async throws {
        try Task.checkCancellation()
        try await Self.mutations.run {
            try Task.checkCancellation()
            guard let data = content.data(using: .utf8) else { throw ProviderError.failed("Could not encode that content.") }
            try withRoot { root, rootFD in
                let url = try resolveURL(path, root: root)
                try withParent(url, root: root, rootFD: rootFD, create: true) { parent, name in
                    try replaceFile(parent: parent, name: name, data: data)
                }
            }
        }
    }

    @concurrent func editFile(path: String, old: String, new: String) async throws {
        try Task.checkCancellation()
        try await Self.mutations.run {
            try Task.checkCancellation()
            guard !old.isEmpty else { throw ProviderError.failed("old_string must not be empty. Read the file first, then edit an exact block.") }
            try withRoot { root, rootFD in
                let url = try resolveURL(path, root: root)
                try withParent(url, root: root, rootFD: rootFD) { parent, name in
                    let data = try withFile(parent: parent, name: name) { try readData($0) }
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw ProviderError.failed("That file is not readable as text.")
                    }
                    let current = text as NSString
                    var remaining = NSRange(location: 0, length: current.length)
                    var firstMatch = NSRange(location: NSNotFound, length: 0)
                    var occurrences = 0
                    while remaining.length > 0 {
                        try Task.checkCancellation()
                        let match = current.range(of: old, options: [], range: remaining)
                        guard match.location != NSNotFound else { break }
                        if occurrences == 0 { firstMatch = match }
                        occurrences += 1
                        remaining.location = NSMaxRange(match)
                        remaining.length = current.length - remaining.location
                    }
                    try Task.checkCancellation()
                    guard occurrences == 1 else {
                        if occurrences == 0 { throw ProviderError.failed("That exact text was not found in \(displayPath(path)). Read the file and copy it exactly.") }
                        throw ProviderError.failed("That text appears \(occurrences) times in \(displayPath(path)). Include more context so it matches once.")
                    }
                    let replacement = current.replacingCharacters(in: firstMatch, with: new)
                    try Task.checkCancellation()
                    try replaceFile(parent: parent, name: name, data: Data(replacement.utf8))
                }
            }
        }
    }

    @concurrent func searchText(pattern: String, path: String, regex: Bool) async throws -> String {
        let trimmed = pattern.trimmed
        guard !trimmed.isEmpty else { return "Error: a search pattern is required." }
        guard !trimmed.utf8.contains(0) else {
            throw ProviderError.failed(localized("A search pattern must not contain a null character."))
        }
        // Apple Libc regex(3): REG_EXTENDED retains grep -E's POSIX ERE dialect.
        // grep treats newline-separated patterns as alternatives, including -F.
        let patterns = trimmed.components(separatedBy: "\n")
        var expressions: [regex_t] = []
        defer {
            for index in expressions.indices { Darwin.regfree(&expressions[index]) }
        }
        if regex {
            for pattern in patterns {
                var expression = regex_t()
                let status = pattern.withCString { Darwin.regcomp(&expression, $0, REG_EXTENDED | REG_NOSUB) }
                guard status == 0 else {
                    throw ProviderError.failed(localized("That search regular expression is invalid."))
                }
                expressions.append(expression)
            }
        }
        let literals = patterns.map { Data($0.utf8) }
        func matches(_ line: Data) -> Bool {
            if !regex { return literals.contains { $0.isEmpty || line.range(of: $0) != nil } }
            var terminated = Array(line)
            terminated.append(0)
            return terminated.withUnsafeBytes { bytes in
                let string = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                return expressions.indices.contains { Darwin.regexec(&expressions[$0], string, 0, nil, 0) == 0 }
            }
        }
        let deadline = Date().addingTimeInterval(30)
        func checkSearch() throws {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ProviderError.failed(localized("Search failed.")) }
        }
        return try withRoot { root, rootFD in
            let base = try resolveURL(path.trimmed.isEmpty ? "." : path, root: root)
            var output: [String] = []
            var outputBytes = 0
            var matchCount = 0
            var full = false
            let excluded: Set<String> = [".git", "node_modules", ".build", "build"]
            func scan(_ fd: Int32, label: String?) throws {
                var pending = Data()
                var lineNumber = 0
                var fileOutput: [String] = []
                var fileBytes = 0
                var fileMatches = 0
                var binary = false
                func line(_ data: Data) {
                    lineNumber += 1
                    guard matches(data) else { return }
                    fileMatches += 1
                    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                    let result = (label.map { $0 + ":" } ?? "") + "\(lineNumber):" + text
                    let room = max(0, 64_000 - outputBytes - fileBytes)
                    let limited = String(decoding: result.utf8.prefix(room), as: UTF8.self)
                    if output.count + fileOutput.count < 120 { fileOutput.append(limited) }
                    fileBytes += min(result.utf8.count + 1, room)
                    if fileBytes + outputBytes >= 64_000 { full = true }
                }
                try readChunks(fd) { chunk in
                    try checkSearch()
                    if chunk.contains(0) { binary = true; return false }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        try checkSearch()
                        line(Data(pending[..<newline]))
                        pending.removeSubrange(...newline)
                        if full { return false }
                    }
                    return true
                }
                guard !binary else { full = false; return }
                if !pending.isEmpty, !full { line(pending) }
                output.append(contentsOf: fileOutput)
                outputBytes += fileBytes
                matchCount += fileMatches
            }
            func walk(_ directory: Int32, _ components: [String], _ label: String) throws {
                for name in try directoryNames(directory) {
                    try checkSearch()
                    guard !full else { return }
                    let info = try entryInfo(parent: directory, name: name)
                    let kind = info.st_mode & S_IFMT
                    if kind == S_IFDIR, excluded.contains(name) { continue }
                    let childComponents = components + [name]
                    let childLabel = label + "/" + name
                    if kind == S_IFDIR {
                        let child = try openDirectories([name], from: directory)
                        defer { Darwin.close(child) }
                        try walk(child, childComponents, childLabel)
                    } else if kind == S_IFREG {
                        try withFile(parent: directory, name: name) { try scan($0, label: childLabel) }
                    } else if kind == S_IFLNK {
                        let link = root.appendingPathComponent(childComponents.joined(separator: "/"))
                        guard let target = try? resolveURL(link.path, root: root) else { continue }
                        // An in-project file link is usable; directory links are never traversed.
                        try withParent(target, root: root, rootFD: rootFD) { parent, targetName in
                            let targetInfo = try entryInfo(parent: parent, name: targetName)
                            guard targetInfo.st_mode & S_IFMT == S_IFREG else { return }
                            try withFile(parent: parent, name: targetName) { try scan($0, label: childLabel) }
                        }
                    }
                }
            }
            try withParent(base, root: root, rootFD: rootFD) { parent, name in
                let info = try entryInfo(parent: parent, name: name)
                if info.st_mode & S_IFMT == S_IFDIR {
                    let fd = try openDirectories(relativeComponents(base, root: root), from: rootFD)
                    defer { Darwin.close(fd) }
                    try walk(fd, relativeComponents(base, root: root), path.trimmed.isEmpty ? "." : base.path)
                } else {
                    try withFile(parent: parent, name: name) { try scan($0, label: nil) }
                }
            }
            try checkSearch()
            if output.isEmpty { return "(no matches)" }
            let text = output.joined(separator: "\n").trimmed
            return matchCount > 120 || full ? text + "\n…(\(matchCount) matches, truncated)" : text
        }
    }

    @concurrent func listFiles(_ path: String, recursive: Bool) async throws -> String {
        try Task.checkCancellation()
        return try withRoot { root, rootFD in
            let base = try resolveURL(path.trimmed.isEmpty ? "." : path, root: root)
            let fd = try openDirectories(relativeComponents(base, root: root), from: rootFD)
            defer { Darwin.close(fd) }
            var results: [String] = []
            func walk(_ directory: Int32, _ relative: [String]) throws {
                for name in try directoryNames(directory) {
                    try Task.checkCancellation()
                    guard results.count < 300 else { return }
                    guard !Self.skippedDirectories.contains(name), !name.hasPrefix(".DS_Store"),
                          !recursive || !name.hasPrefix(".") else { continue }
                    let info = try entryInfo(parent: directory, name: name)
                    let components = relative + [name]
                    let label = components.joined(separator: "/")
                    let kind = info.st_mode & S_IFMT
                    var isDirectory = kind == S_IFDIR
                    if kind == S_IFLNK {
                        // Listed links are never traversed; refuse external targets too.
                        let link = root.appendingPathComponent(label)
                        guard let target = try? resolveURL(link.path, root: root) else { continue }
                        isDirectory = try withParent(target, root: root, rootFD: rootFD) { parent, targetName in
                            try entryInfo(parent: parent, name: targetName).st_mode & S_IFMT == S_IFDIR
                        }
                    }
                    if kind == S_IFDIR, recursive {
                        let child = try openDirectories([name], from: directory)
                        defer { Darwin.close(child) }
                        let childURL = root.appendingPathComponent(label)
                        if (try? childURL.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { continue }
                        try walk(child, components)
                    } else {
                        if recursive, isDirectory { continue }
                        results.append(label + (isDirectory ? "/" : ""))
                    }
                }
            }
            try walk(fd, relativeComponents(base, root: root))
            if results.count >= 300 { results.append("…(truncated)") }
            return results.isEmpty ? "(empty)" : results.joined(separator: "\n")
        }
    }
}
