import Foundation
import Synchronization

enum DshCLI {
    static let packageName = "@deepseek-ai/dsh"

    static func modelRoute(for id: String) -> (route: String, model: String)? {
        guard let pair = try? JSONDecoder().decode([String].self, from: Data(id.utf8)), pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    /// Same names as `DeepSeekAPI.option(for:)`, kept here so DshCLI stays free of the HTTP client.
    /// dsh names the account route `DeepSeek-V4.1-Flash` and leaves the key route as the bare id,
    /// so the known models read the same on both routes and in the native DeepSeek provider.
    static func knownName(forModelID id: String) -> String? {
        switch modelRoute(for: id)?.model ?? id {
        case "deepseek-flash", "deepseek-v4-flash": "V4.1 Flash"
        case "deepseek-v4-pro": "V4 Pro"
        default: nil
        }
    }

    static func displayName(forModelID id: String) -> String {
        let model = modelRoute(for: id)?.model ?? id
        if let name = knownName(forModelID: id) { return name }
        return model.split(whereSeparator: { "-_/".contains($0) }).map { part in
            if part.lowercased() == "deepseek" { return "DeepSeek" }
            if part.first == "v", part.dropFirst().first?.isNumber == true { return part.uppercased() }
            return part.capitalized
        }.joined(separator: " ")
    }

    static func resolvedModelID(_ id: String, in models: [ModelOption]) -> String {
        if models.contains(where: { $0.id == id }) { return id }
        // The key route still lists Flash under its retired id; it is the same model.
        func canonical(_ id: String) -> String {
            let model = modelRoute(for: id)?.model ?? id
            return model == "deepseek-v4-flash" ? "deepseek-flash" : model
        }
        let selected = modelRoute(for: id)
        let model = canonical(id)
        let matches = models.filter { canonical($0.id) == model }
        if let route = selected?.route, let sameRoute = matches.first(where: { modelRoute(for: $0.id)?.route == route }) { return sameRoute.id }
        return matches.first(where: { $0.isDefault })?.id ?? matches.first?.id ?? id
    }


    private struct VersionKey: Hashable, Sendable {
        var path: String
        var modificationDate: Date?
    }

    private struct CachedVersion: Sendable {
        var value: String?
    }

    private static let versions = Mutex<[VersionKey: Task<String?, Never>]>([:])
    private static let runtimeVersions = Mutex<[VersionKey: CachedVersion]>([:])

    static func bundledRuntimeVersion(of executable: URL) -> String? {
        let launcher = executable.resolvingSymlinksInPath()
        guard launcher.path.hasSuffix("/runtime/cli/bin/dsh") else { return nil }
        let resources = launcher.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let archive = resources.appendingPathComponent("app.asar")
        let modificationDate = try? archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let key = VersionKey(path: archive.path, modificationDate: modificationDate)
        return runtimeVersions.withLock { cache in
            if let cached = cache[key] { return cached.value }
            let version = readBundledRuntimeVersion(from: archive)
            cache[key] = CachedVersion(value: version)
            return version
        }
    }

    private static func readBundledRuntimeVersion(from archive: URL) -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: archive)
            defer { try? handle.close() }
            guard let prefix = try handle.read(upToCount: 16), prefix.count == 16 else { return nil }
            let bytes = [UInt8](prefix)
            func uint32(_ offset: Int) -> UInt32 {
                UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            }
            let headerSize = uint32(4)
            let jsonSize = uint32(12)
            let dataStart = UInt64(headerSize) + 8
            let fileSize = try handle.seekToEnd()
            // getDshRuntimeVersion() reads this package through Electron's ASAR filesystem.
            // The two Pickle headers let us read the same manifest without starting Electron.
            guard jsonSize > 0, jsonSize <= 16 * 1_024 * 1_024,
                  UInt64(headerSize) >= UInt64(jsonSize) + 8,
                  dataStart <= fileSize else { return nil }
            try handle.seek(toOffset: 16)
            guard let headerData = try handle.read(upToCount: Int(jsonSize)), headerData.count == Int(jsonSize) else { return nil }
            guard var node = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else { return nil }
            for component in ["dsh", "node_modules", "@deepseek-ai", "dsh-app-boot", "package.json"] {
                guard let files = node["files"] as? [String: Any],
                      let child = files[component] as? [String: Any] else { return nil }
                node = child
            }
            guard node["unpacked"] as? Bool != true,
                  let offsetText = node["offset"] as? String,
                  let offset = UInt64(offsetText),
                  let sizeValue = node["size"] as? NSNumber else { return nil }
            let size = sizeValue.uint64Value
            guard size > 0, size <= 1_024 * 1_024,
                  offset <= fileSize - dataStart,
                  size <= fileSize - dataStart - offset else { return nil }
            try handle.seek(toOffset: dataStart + offset)
            guard let packageData = try handle.read(upToCount: Int(size)), packageData.count == Int(size),
                  let package = try JSONSerialization.jsonObject(with: packageData) as? [String: Any],
                  let version = package["version"] as? String,
                  !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return version
        } catch {
            return nil
        }
    }

    /// Where Tivano keeps the patch files. dsh's own state, sign-in included, stays in its
    /// own home (`DSH_HOME`, else `~/.dsh`), where the desktop app and `dsh` keep it too.
    static var home: URL {
        let captureRoot = CaptureRun.storageRoot
        let state = captureRoot?
            .appendingPathComponent("provider-runtime", isDirectory: true)
            ?? URL(fileURLWithPath: LoginEnvironment.homeDirectory)
                .appendingPathComponent(AppInfo.stateDirectoryName, isDirectory: true)
        let directory = state.appendingPathComponent("dsh", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return captureRoot == nil ? directory : directory.resolvingSymlinksInPath()
    }

    static func accountHome(environment: [String: String]) -> URL {
        let path = environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (LoginEnvironment.homeDirectory as NSString).appendingPathComponent(".dsh")
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func accountCredentialStamp(environment: [String: String]) -> String? {
        let file = accountHome(environment: environment).appendingPathComponent(".credentials.yaml")
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey]) else { return nil }
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0):\(String(describing: values.fileResourceIdentifier))"
    }

    /// Local evidence only, not online authentication. Reads a bounded credential document
    /// in memory; no credential values leave this function or enter logs/caches.
    static func hasAccountLogin(environment: [String: String]) -> Bool {
        let file = accountHome(environment: environment).appendingPathComponent(".credentials.yaml")
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 262_144,
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 262_145), data.count <= 262_144,
              let text = String(data: data, encoding: .utf8) else { return false }
        return hasAccountRecord(in: text)
    }

    // Recognizes the block layout written by dsh-credentials-local v1. Unknown YAML forms
    // are not evidence of sign-in; the CLI remains the authority when actually connecting.
    static func hasAccountRecord(in text: String) -> Bool {
        var versionOne = false
        var inRecords = false
        var recordIndent: Int?
        var payloadIndent: Int?
        var hasGrant = false
        var hasToken = false
        var hasIssuer = false
        var hasPayloadVersion = false
        for line in text.split(whereSeparator: \.isNewline) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty || clean.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                if recordIndent != nil { break }
                if clean.range(of: #"^version:\s*1\s*(?:#.*)?$"#, options: .regularExpression) != nil { versionOne = true }
                inRecords = clean.range(of: #"^records:\s*(?:#.*)?$"#, options: .regularExpression) != nil
                continue
            }
            guard inRecords else { continue }
            if recordIndent == nil {
                if clean.range(of: #"^["']?deepseek-account-platform/default["']?:\s*(?:#.*)?$"#, options: .regularExpression) != nil {
                    recordIndent = indent
                }
                continue
            }
            guard let recordIndent, indent > recordIndent else { break }
            if let payloadIndent, indent > payloadIndent {
                if clean.range(of: #"^version:\s*1\s*(?:#.*)?$"#, options: .regularExpression) != nil { hasPayloadVersion = true }
                if clean.hasPrefix("token:") {
                    let value = clean.dropFirst("token:".count).trimmingCharacters(in: .whitespaces)
                    hasToken = !["", "null", "~", "{}", "[]", "''", "\"\""].contains(value) && !value.hasPrefix("#")
                }
                if clean.hasPrefix("issuer:") {
                    let value = clean.dropFirst("issuer:".count).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    hasIssuer = URL(string: value)?.host != nil
                }
                continue
            }
            payloadIndent = nil
            if clean.range(of: #"^kind:\s*["']?grant["']?\s*(?:#.*)?$"#, options: .regularExpression) != nil { hasGrant = true }
            if clean.range(of: #"^payload:\s*(?:#.*)?$"#, options: .regularExpression) != nil { payloadIndent = indent }
        }
        return versionOne && hasGrant && hasPayloadVersion && hasToken && hasIssuer
    }

    static func applyBaseEnvironment(_ environment: inout [String: String], apiKey: String) {
        // dsh drops every variable whose name holds KEY, TOKEN, SECRET or PASSWORD from its tools'
        // environment. Of the GIT_CONFIG_* set Tivano adds for its GitHub sign-in that removes the
        // KEY_n entries but not COUNT, and every git call in dsh's shell then dies with "missing
        // config key GIT_CONFIG_KEY_0". The whole set goes; git falls back to the user's own config.
        for name in environment.keys where name == "GIT_CONFIG_COUNT" || name.hasPrefix("GIT_CONFIG_KEY_") || name.hasPrefix("GIT_CONFIG_VALUE_") {
            environment.removeValue(forKey: name)
        }
        if apiKey.isEmpty {
            environment.removeValue(forKey: "DEEPSEEK_API_KEY")
        } else {
            environment["DEEPSEEK_API_KEY"] = apiKey
        }
    }

    static func permissionMode(for runtimeMode: RuntimeMode) -> String {
        runtimeMode == .fullAccess ? "danger-full-access" : "workspace-write"
    }

    static func userProfilePatch(environment: [String: String]) -> URL? {
        let path = environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (LoginEnvironment.homeDirectory as NSString).appendingPathComponent(".dsh")
        let profiles = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        for name in ["desktop", "web"] {
            let patch = profiles.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("cordis.patch.yml")
            if FileManager.default.fileExists(atPath: patch.path) { return patch }
        }
        return nil
    }

    static func launchArguments(mode: DshAgentMode, delegationOff: Bool, environment: [String: String], finalReport: Bool = false) -> [String] {
        var arguments = ["--profile", "acp"]
        if let patch = userProfilePatch(environment: environment) {
            arguments += ["--patch", patch.path]
        }
        guard mode != .standard || delegationOff || finalReport else { return arguments }
        let directory = patchDirectory()
        switch mode {
        case .standard:
            break
        case .ptc:
            arguments += ["--patch", directory.appendingPathComponent("ptc.yml").path]
        case .minimal:
            arguments += ["--patch", directory.appendingPathComponent("minimal.yml").path]
            arguments += ["--patch", directory.appendingPathComponent("minimal-optional.yml").path]
        case .creator:
            arguments += ["--patch", directory.appendingPathComponent("creator.yml").path]
        }
        if delegationOff, mode != .minimal {
            arguments += ["--patch", directory.appendingPathComponent("no-delegation.yml").path]
        }
        if finalReport {
            let plugin = directory.appendingPathComponent("report-guard.mjs")
            let patch = directory.appendingPathComponent("report-guard.yml")
            if (try? String(contentsOf: plugin, encoding: .utf8)) != DshReportGuard.source {
                try? DshReportGuard.source.write(to: plugin, atomically: true, encoding: .utf8)
            }
            // JSON scalars are valid YAML, including paths containing quotes or spaces.
            let encodedPath = String(decoding: (try? JSONEncoder().encode(plugin.path)) ?? Data(), as: UTF8.self)
            let content = "- insert:\n    - id: tivano-report-guard\n      name: \(encodedPath)\n"
            if (try? String(contentsOf: patch, encoding: .utf8)) != content {
                try? content.write(to: patch, atomically: true, encoding: .utf8)
            }
            arguments += ["--patch", patch.path]
        }
        return arguments
    }

    private static func patchDirectory() -> URL {
        let directory = home.appendingPathComponent("tivano-patches", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, content) in [("ptc.yml", DshPatches.ptc), ("minimal.yml", DshPatches.minimal), ("minimal-optional.yml", DshPatches.minimalOptional), ("creator.yml", DshPatches.creator), ("no-delegation.yml", DshPatches.noDelegation)] {
            let file = directory.appendingPathComponent(name)
            if (try? String(contentsOf: file, encoding: .utf8)) != content {
                try? content.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        return directory
    }

    static func prepareLaunch(executable: URL, mode: DshAgentMode, delegationOff: Bool, environment: [String: String], finalReport: Bool = false) async throws -> DshLaunchPlan {
        var baseEnvironment = environment
        applyBaseEnvironment(&baseEnvironment, apiKey: environment["DEEPSEEK_API_KEY"] ?? "")
        let arguments = launchArguments(mode: mode, delegationOff: delegationOff, environment: baseEnvironment, finalReport: finalReport)
        let prepared = try await Task.detached { [baseEnvironment] in
            try DshMarketplace.prepare(executable: executable, arguments: arguments, environment: baseEnvironment)
        }.value
        // A desktop profile is only inherited where this runtime fits the bootstrap, which
        // is checked once per DeepSeek Harness version instead of pinned to one; where it
        // does not, the chat runs without the profile and says so once per version.
        var plan = prepared
        if prepared.ownedDirectory != nil {
            let version = bundledRuntimeVersion(of: executable)
            switch await DshMarketplaceCompatibility.verdict(for: prepared, version: version) {
            case .compatible, .unknown:
                break
            case .incompatible:
                prepared.cleanup()
                let warning = DshMarketplaceCompatibility.takeWarning(version: version)
                plan = DshMarketplace.plainPlan(executable: executable, arguments: arguments, environment: baseEnvironment, warning: warning)
            }
        }
        do {
            try Task.checkCancellation()
            // The marketplace bootstrap admits the exact in-memory composition before
            // making ACP ready; a separate dump would read a different generation.
            if plan.ownedDirectory == nil, plan.arguments.contains("--patch"),
               !(await patchesApply(executable: plan.executable, arguments: plan.arguments, environment: plan.environment)) {
                throw ProviderError.failed(AppText.localized("DeepSeek Harness could not load Tivano's configuration. Update DeepSeek Harness or check your profile patches, then try again."))
            }
            try Task.checkCancellation()
            return plan
        } catch {
            plan.cleanup()
            throw error
        }
    }

    static func installedVersion(of executable: URL) async -> String? {
        let modificationDate = try? executable.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let key = VersionKey(path: executable.path, modificationDate: modificationDate)
        let task = versions.withLock { cache in
            if let task = cache[key] { return task }
            let task = Task<String?, Never> {
                await LoginEnvironment.load()
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = LoginEnvironment.current["PATH"] ?? environment["PATH"]
                applyBaseEnvironment(&environment, apiKey: "")
                guard let result = try? await Shell.run(executable, ["--version"], environment: environment, timeout: 15),
                      result.succeeded,
                      let range = result.output.range(of: #"\b[0-9]+(?:\.[0-9]+)+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?"#, options: .regularExpression)
                else { return nil }
                return String(result.output[range])
            }
            cache[key] = task
            return task
        }
        return await task.value
    }

    static func patchesApply(executable: URL, arguments: [String], environment: [String: String]) async -> Bool {
        var environment = environment
        applyBaseEnvironment(&environment, apiKey: environment["DEEPSEEK_API_KEY"] ?? "")
        guard !Task.isCancelled,
              let result = try? await Shell.run(executable, arguments + ["--dump-config"], environment: environment, timeout: 20),
              result.succeeded, !Task.isCancelled else { return false }
        let directory = home.appendingPathComponent("tivano-patches", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let userPatch = userProfilePatch(environment: environment)?.resolvingSymlinksInPath().standardizedFileURL
        return !result.errorOutput.split(whereSeparator: \.isNewline).contains { line in
            let prefix = "dsh: ["
            guard line.hasPrefix(prefix),
                  let separator = line.range(of: "] patch: entry \""),
                  line.hasSuffix("\" not found") else { return false }
            let file = URL(fileURLWithPath: String(line.dropFirst(prefix.count).prefix(upTo: separator.lowerBound)))
                .resolvingSymlinksInPath().standardizedFileURL
            let row = String(line[separator.upperBound...].dropLast("\" not found".count))
            if file == directory.appendingPathComponent("minimal-optional.yml"), row == "tool-working-directory" { return false }
            if file == userPatch, row.hasPrefix("ui-") { return false }
            return true
        }
    }
}
