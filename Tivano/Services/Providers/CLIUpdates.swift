import Foundation

/// Who owns an installed provider CLI, read from the binary's real path. An update goes
/// through that owner: `brew upgrade` for the cask or formula, `npm install -g --prefix`
/// for that npm prefix, `bun`/`pnpm` with the global directory the files already use.
/// A path that does not prove an owner is left alone. This type does not read or write
/// the app's provider settings.
enum CLIInstallChannel: Equatable, Sendable {
    case homebrew(brew: String, token: String, cask: Bool)
    case npm(tool: String, package: String, prefix: String, tag: String)
    /// `globalDir` is bun's package directory and `binDir` is where its shims are linked.
    case bun(tool: String, package: String, globalDir: String, binDir: String, tag: String)
    /// `globalDir` is pnpm's global package directory (`PNPM_HOME/global`) and `binDir` is `PNPM_HOME/bin`.
    case pnpm(tool: String, package: String, globalDir: String, binDir: String, pnpmHome: String, tag: String)
    case selfUpdate(executable: String, arguments: [String], environment: [String: String])

    /// What the Update button runs, as the user would type it.
    var command: String {
        let invocation = invocation
        var parts: [String] = []
        let locationKeys = ["BUN_INSTALL_GLOBAL_DIR", "BUN_INSTALL_BIN", "PNPM_HOME"]
        let overrides = locationKeys.compactMap { key in invocation.environment[key].map { key + "=" + $0 } }
        if !overrides.isEmpty { parts = ["env"] + overrides }
        parts += [invocation.tool] + invocation.arguments
        return parts.map { value in
            if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "_./@:+-=".contains($0) }) { return value }
            return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }.joined(separator: " ")
    }

    /// Extra environment keys are merged onto the login environment by the registry.
    /// Replacing the environment with only these keys would drop `PATH`.
    var invocation: (tool: String, arguments: [String], environment: [String: String]) {
        switch self {
        case .homebrew(let brew, let token, let cask):
            // Ask mode is brew's default and would block a process nobody is reading.
            // https://docs.brew.sh/Manpage
            return (brew, ["upgrade", "--no-ask", cask ? "--cask" : "--formula", token], [
                "HOMEBREW_NO_ASK": "1",
                "HOMEBREW_NO_ANALYTICS": "1",
                "HOMEBREW_NO_EMOJI": "1",
                "HOMEBREW_NO_ENV_HINTS": "1",
            ])
        case .npm(let tool, let package, let prefix, let tag):
            // `--prefix` is the prefix the files already use, so another npm on PATH
            // cannot write a second global copy. https://docs.npmjs.com/cli/v11/using-npm/config
            return (tool, ["install", "-g", "--prefix", prefix, "\(package)@\(tag)"], [
                "npm_config_fund": "false",
                "npm_config_audit": "false",
            ])
        case .bun(let tool, let package, let globalDir, let binDir, let tag):
            // These two variables are the documented overrides for install.globalDir and
            // install.globalBinDir. https://bun.sh/docs/runtime/bunfig
            return (tool, ["add", "-g", "\(package)@\(tag)"], [
                "BUN_INSTALL_GLOBAL_DIR": globalDir,
                "BUN_INSTALL_BIN": binDir,
            ])
        case .pnpm(let tool, let package, let globalDir, let binDir, let pnpmHome, let tag):
            // Pin every documented location. `-g` alone follows pnpm's own default and can
            // install a second copy. https://pnpm.io/settings/other https://pnpm.io/global-packages
            return (tool, ["add", "-g", "--global-dir", globalDir, "--global-bin-dir", binDir, "\(package)@\(tag)"], [
                "PNPM_HOME": pnpmHome,
            ])
        case .selfUpdate(let executable, let arguments, let environment):
            return (executable, arguments, environment)
        }
    }

    /// Stable id of the install being updated. The tool binary is not part of it: replacing
    /// npm on PATH does not change the prefix the package lives in.
    var identity: String {
        switch self {
        case .homebrew(let brew, let token, let cask):
            return "homebrew:\(cask ? "cask" : "formula"):\(token):\(brew)"
        case .npm(_, let package, let prefix, let tag):
            return "npm:\(prefix):\(package)@\(tag)"
        case .bun(_, let package, let globalDir, let binDir, let tag):
            return "bun:\(globalDir):\(binDir):\(package)@\(tag)"
        case .pnpm(_, let package, let globalDir, let binDir, _, let tag):
            return "pnpm:\(globalDir):\(binDir):\(package)@\(tag)"
        case .selfUpdate(let executable, let arguments, let environment):
            if let directory = environment["CODEX_INSTALL_DIR"] {
                return "self:codex:\(directory)"
            }
            return "self:\(executable):\(arguments.joined(separator: " "))"
        }
    }
}

/// `newer` / `older` compare the candidate with the baseline. `unparsed` means one side
/// had no readable version; that is not equality and not a successful update.
enum CLIVersionComparison: Equatable, Sendable {
    case newer
    case older
    case equal
    case unparsed
}

/// One provider CLI's installed and latest version, and where its update stands.
/// A nil `latest` means no verified feed, not that the install is current.
struct CLIUpdateStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case checking
        case current
        case available
        /// Update asked for; chats on this provider are still running a turn.
        case waiting
        case updating
        case updated
        case failed
    }

    var phase: Phase
    var installed: String?
    var latest: String?
    var channel: CLIInstallChannel?
    /// The failed check's or update's own message, one line.
    var error: String?
    /// Whether the failure was the update itself rather than the check.
    var updateFailed = false
    var checkedAt: Date?
}

/// Seams the registry uses to fake a layout, a package-manager answer, and a release feed.
/// The live probe shells out only for read-only ownership queries (`brew info`) and fetches
/// only HTTP release documents. It does not install or upgrade anything.
struct CLIProbe: Sendable {
    var home: @Sendable () -> String
    var standardize: @Sendable (String) -> String
    var resolve: @Sendable (URL) -> URL
    var installLayout: (@Sendable (URL) -> URL)? = nil
    var isExecutable: @Sendable (String) -> Bool
    var readFile: @Sendable (String) -> Data?
    var which: @Sendable (String, [String: String]) -> String?
    var run: @Sendable (URL, [String], [String: String]) async throws -> ShellResult
    var fetch: @Sendable (URL) async throws -> Data

    static let live = CLIProbe(
        home: { LoginEnvironment.homeDirectory },
        standardize: { path in
            let expanded = (path as NSString).expandingTildeInPath
            return (expanded as NSString).standardizingPath
        },
        resolve: { $0.resolvingSymlinksInPath() },
        installLayout: { CLIProbe.revealInstallLayout($0) },
        isExecutable: { path in
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        },
        readFile: { FileManager.default.contents(atPath: $0) },
        which: { name, environment in LoginEnvironment.which(name, in: environment)?.path },
        run: { executable, arguments, environment in
            try await Shell.run(executable, arguments, environment: environment, timeout: 30)
        },
        fetch: { url in try await CLIUpdates.loadFeed(url) }
    )

    /// Follows a symlink far enough to see `lib/node_modules`, bun's global dir, pnpm's
    /// `global/v11` tree, or a Homebrew keg, and stops before a content-addressed store
    /// hop that would hide that layout.
    fileprivate static func revealInstallLayout(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if layoutVisible(standardized.path) { return standardized }
        if let linked = symlinkTarget(of: standardized.path) {
            let parent = standardized.deletingLastPathComponent().path
            let joined = URL(fileURLWithPath: join(parent, linked)).standardizedFileURL
            if layoutVisible(joined.path) { return joined }
        }
        return url.resolvingSymlinksInPath()
    }

    private static func symlinkTarget(of path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink(path, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func join(_ directory: String, _ target: String) -> String {
        if target.hasPrefix("/") { return (target as NSString).standardizingPath }
        return ((directory as NSString).appendingPathComponent(target) as NSString).standardizingPath
    }

    private static func layoutVisible(_ path: String) -> Bool {
        let parts = (path as NSString).pathComponents
        func contains(_ sequence: [String]) -> Bool {
            guard parts.count >= sequence.count else { return false }
            for index in 0...(parts.count - sequence.count) where Array(parts[index..<(index + sequence.count)]) == sequence {
                return true
            }
            return false
        }
        if contains(["lib", "node_modules"]) || contains([".bun", "install", "global", "node_modules"]) { return true }
        if contains(["Cellar"]) || contains(["Caskroom"]) { return true }
        if contains([".local", "share", "claude", "versions"]) || contains([".codex", "packages", "standalone"]) { return true }
        guard let global = parts.firstIndex(of: "global"), global + 2 < parts.count, parts[global + 1] == "v11" else { return false }
        return parts[(global + 2)...].contains("node_modules")
    }
}

/// Read-only install ownership and version feeds for provider CLIs.
enum CLIUpdates {
    /// Nil when the binary's path does not prove an owner. Nix, `/usr`, `/bin`, and any
    /// other unrecognized location stay nil: this does not guess a self-updater from the provider.
    @concurrent
    static func channel(
        for provider: ProviderKind,
        executable: URL,
        environment: [String: String],
        probe: CLIProbe = .live
    ) async throws -> CLIInstallChannel? {
        if provider.isAPIKeyBased { return nil }
        let original = probe.standardize(executable.path)
        let resolved = probe.standardize(probe.resolve(executable).path)
        guard !isProtected(resolved) else { return nil }
        let layout = probe.standardize((probe.installLayout?(executable) ?? probe.resolve(executable)).path)
        for path in [layout, resolved, original] {
            if isProtected(path) { continue }
            if let owned = npmChannel(provider, path: path, environment: environment, probe: probe) { return owned }
            if let owned = bunChannel(provider, path: path, environment: environment, probe: probe) { return owned }
            if let owned = pnpmChannel(provider, path: path, original: original, environment: environment, probe: probe) { return owned }
            if let owned = homebrewChannel(path: path, probe: probe) { return owned }
        }
        if isProtected(resolved), isProtected(original) { return nil }
        if let native = claudeNativeChannel(provider, original: original, resolved: resolved, probe: probe) { return native }
        return nil
    }

    /// The version the channel would install, or the provider's verified read-only feed when
    /// `channel` is nil. Nil means there is no verified feed. It does not mean the install is current.
    /// `installed` is never used as that answer. HTTP failures, bad JSON, a missing or unreadable
    /// version, and a failed `brew info` throw.
    @concurrent
    static func latestVersion(
        _ provider: ProviderKind,
        installed: String?,
        channel: CLIInstallChannel?,
        executable: URL,
        environment: [String: String],
        probe: CLIProbe = .live
    ) async throws -> String? {
        _ = (installed, executable)
        switch channel {
        case .homebrew(let brew, let token, let cask):
            return try await homebrewVersion(brew: brew, token: token, cask: cask, environment: environment, probe: probe)
        case .npm(_, let package, _, let tag), .bun(_, let package, _, _, let tag), .pnpm(_, let package, _, _, _, let tag):
            return try await registryVersion(package, tag: tag, probe: probe)
        case .selfUpdate:
            return try await unmanagedVersion(provider, environment: environment, probe: probe)
        case nil:
            return try await unmanagedVersion(provider, environment: environment, probe: probe)
        }
    }

    /// SemVer precedence, plus a Homebrew cask revision after a comma (`4.94.0,241994`).
    /// Build metadata is ignored. A prerelease is older than the same release. Text such as
    /// Claude's `2.1.211 (Claude Code)` is read from its first version token.
    static func compare(_ candidate: String, with baseline: String) -> CLIVersionComparison {
        guard let candidate = versionToken(in: candidate), let baseline = versionToken(in: baseline) else { return .unparsed }
        let width = max(candidate.numbers.count, baseline.numbers.count)
        let new = candidate.numbers + Array(repeating: 0, count: width - candidate.numbers.count)
        let old = baseline.numbers + Array(repeating: 0, count: width - baseline.numbers.count)
        if new != old { return old.lexicographicallyPrecedes(new) ? .newer : .older }
        if (new.first ?? 0) >= 2000, candidate.prerelease != baseline.prerelease { return .unparsed }
        return comparePrerelease(candidate.prerelease, baseline.prerelease)
    }

    /// True only when `latest` is strictly newer. An unreadable version is not newer and is not equal;
    /// use `compare` to tell those apart.
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        compare(latest, with: installed) == .newer
    }

    // MARK: - Ownership

    /// Unix global installs live at `{prefix}/lib/node_modules`. The package directory has to be
    /// this provider's package; a nested dependency under some other package is not an install we update.
    /// https://docs.npmjs.com/cli/v11/configuring-npm/folders
    private static func npmChannel(
        _ provider: ProviderKind,
        path: String,
        environment: [String: String],
        probe: CLIProbe
    ) -> CLIInstallChannel? {
        let parts = components(path)
        guard let modules = parts.indices.first(where: { parts[$0] == "node_modules" && $0 >= 1 && parts[$0 - 1] == "lib" }),
              let package = directPackage(parts, modules: modules),
              knownPackages(provider).contains(package) else { return nil }
        let prefix = join(Array(parts[..<(modules - 1)]))
        guard components(prefix).count > 1 else { return nil }
        let bundled = (prefix as NSString).appendingPathComponent("bin/npm")
        let tool = probe.isExecutable(bundled) ? bundled : probe.which("npm", environment).map { probe.standardize($0) }
        guard let tool else { return nil }
        return .npm(tool: tool, package: package, prefix: prefix, tag: "latest")
    }

    /// Default bun global layout only: `~/.bun/install/global/node_modules/<package>` and shims in
    /// `~/.bun/bin`. A custom `install.globalDir` is accepted when the process environment already
    /// names that directory and its bin directory. https://bun.sh/docs/pm/cli/add
    private static func bunChannel(
        _ provider: ProviderKind,
        path: String,
        environment: [String: String],
        probe: CLIProbe
    ) -> CLIInstallChannel? {
        let parts = components(path)
        guard let modules = parts.lastIndex(of: "node_modules"),
              let package = directPackage(parts, modules: modules),
              knownPackages(provider).contains(package) else { return nil }
        let globalDir = join(Array(parts[..<modules]))
        let defaultGlobal = probe.standardize((probe.home() as NSString).appendingPathComponent(".bun/install/global"))
        let defaultBin = probe.standardize((probe.home() as NSString).appendingPathComponent(".bun/bin"))
        let configuredGlobal = environment["BUN_INSTALL_GLOBAL_DIR"].flatMap { $0.isEmpty ? nil : probe.standardize($0) }
        let configuredBin = environment["BUN_INSTALL_BIN"].flatMap { $0.isEmpty ? nil : probe.standardize($0) }
        let binDir: String
        if same(globalDir, defaultGlobal) {
            guard configuredGlobal == nil || same(configuredGlobal!, globalDir),
                  configuredBin == nil || same(configuredBin!, defaultBin) else { return nil }
            binDir = defaultBin
        } else if let configuredGlobal, same(globalDir, configuredGlobal), let configuredBin {
            binDir = configuredBin
        } else {
            return nil
        }
        let bundled = (probe.home() as NSString).appendingPathComponent(".bun/bin/bun")
        let tool = probe.isExecutable(bundled) ? bundled : probe.which("bun", environment).map { probe.standardize($0) }
        guard let tool else { return nil }
        return .bun(tool: tool, package: package, globalDir: globalDir, binDir: binDir, tag: "latest")
    }

    /// pnpm 11 stores each global package at `{PNPM_HOME}/global/v11/<hash>/node_modules/<package>`
    /// and links bins in `{PNPM_HOME}/bin`. https://pnpm.io/global-packages
    private static func pnpmChannel(
        _ provider: ProviderKind,
        path: String,
        original: String,
        environment: [String: String],
        probe: CLIProbe
    ) -> CLIInstallChannel? {
        let parts = components(path)
        guard let modules = parts.indices.last(where: { index in
            index >= 4 && parts[index] == "node_modules" && parts[index - 2] == "v11" && parts[index - 3] == "global"
        }), let package = directPackage(parts, modules: modules),
              knownPackages(provider).contains(package) else { return nil }
        let home = join(Array(parts[..<(modules - 3)]))
        let binDir = (home as NSString).appendingPathComponent("bin")
        let globalDir = (home as NSString).appendingPathComponent("global")
        let originalInBin = same((original as NSString).deletingLastPathComponent, binDir)
        guard originalInBin || probe.isExecutable((binDir as NSString).appendingPathComponent("pnpm")) else { return nil }
        if let configured = environment["PNPM_HOME"], !configured.isEmpty, !same(probe.standardize(configured), home) {
            return nil
        }
        let bundled = (binDir as NSString).appendingPathComponent("pnpm")
        let tool = probe.isExecutable(bundled) ? bundled : probe.which("pnpm", environment).map { probe.standardize($0) }
        guard let tool else { return nil }
        return .pnpm(tool: tool, package: package, globalDir: globalDir, binDir: binDir, pnpmHome: home, tag: "latest")
    }

    /// `Caskroom/<token>/<version>/…` and `Cellar/<token>/<version>/{bin,libexec}/…`.
    /// A Node formula is not the CLI: its global packages are npm's. https://docs.brew.sh/Manpage
    private static func homebrewChannel(path: String, probe: CLIProbe) -> CLIInstallChannel? {
        let parts = components(path)
        let matches = parts.indices.filter { parts[$0] == "Caskroom" || parts[$0] == "Cellar" }
        for index in matches.reversed() {
            let cask = parts[index] == "Caskroom"
            guard index >= 1, index + 1 < parts.count else { continue }
            let token = parts[index + 1]
            guard isBrewToken(token), !isNodeFormula(token) else { continue }
            if cask {
                guard index + 3 < parts.count else { continue }
            } else {
                guard index + 4 < parts.count, parts[index + 3] == "bin" || parts[index + 3] == "libexec" else { continue }
            }
            let prefix = join(Array(parts[..<index]))
            let brew = (prefix as NSString).appendingPathComponent("bin/brew")
            guard probe.isExecutable(brew) else { continue }
            return .homebrew(brew: brew, token: token, cask: cask)
        }
        return nil
    }

    /// The native installer owns `~/.local/bin/claude` only when that launcher resolves inside
    /// `~/.local/share/claude/versions/`. `claude update` keeps both. Homebrew and npm do not use it.
    /// https://code.claude.com/docs/en/setup
    private static func claudeNativeChannel(
        _ provider: ProviderKind,
        original: String,
        resolved: String,
        probe: CLIProbe
    ) -> CLIInstallChannel? {
        guard provider == .claude else { return nil }
        let home = probe.home()
        let versions = (home as NSString).appendingPathComponent(".local/share/claude/versions")
        guard isWithin(resolved, versions) else { return nil }
        let launcher = probe.standardize((home as NSString).appendingPathComponent(".local/bin/claude"))
        let executable = same(original, launcher) ? launcher : (isWithin(original, versions) ? original : resolved)
        return .selfUpdate(executable: executable, arguments: ["update"], environment: [:])
    }

    // MARK: - Feeds

    fileprivate static func loadFeed(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ShellError(String(localized: "The release feed did not answer over HTTP."))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ShellError(String(format: String(localized: "The release feed answered %d."), http.statusCode))
        }
        return data
    }

    /// `GET /{package}/{version}` accepts a version or `latest` and returns the version document.
    /// https://github.com/npm/registry/blob/master/docs/REGISTRY-API.md
    private static func registryVersion(_ package: String, tag: String, probe: CLIProbe) async throws -> String {
        guard tag == "latest" || tag == "stable", let url = registryURL(package: package, tag: tag) else {
            throw ShellError(String(localized: "The release feed URL is invalid."))
        }
        let json = try feedJSON(try await probe.fetch(url))
        guard let version = json["version"] as? String else {
            throw ShellError(String(localized: "The release feed did not include a version."))
        }
        guard versionToken(exact: version) != nil else {
            throw ShellError(String(localized: "The release feed's version could not be read."))
        }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Version feeds that do not grant an update. Claude's `stable` channel has no verified HTTP feed.
    /// Codex's CLI versions are the `@openai/codex` releases. Cursor and Antigravity publish no feed here.
    private static func unmanagedVersion(_ provider: ProviderKind, environment: [String: String], probe: CLIProbe) async throws -> String? {
        switch provider {
        case .claude:
            switch claudeReleaseChannel(probe, environment: environment) {
            case .latest: return try await registryVersion("@anthropic-ai/claude-code", tag: "latest", probe: probe)
            case .stable: return nil
            case .unreadable: throw ShellError(String(localized: "Claude update settings could not be read."))
            }
        case .codex:
            return try await registryVersion("@openai/codex", tag: "latest", probe: probe)
        case .copilot: return try await registryVersion("@github/copilot", tag: "latest", probe: probe)
        case .opencode, .opencodeGo: return nil
        case .pi: return try await registryVersion("@earendil-works/pi-coding-agent", tag: "latest", probe: probe)
        case .commandcode: return try await registryVersion("command-code", tag: "latest", probe: probe)
        default:
            return nil
        }
    }

    /// `brew info` is local and can name a third-party tap. formulae.brew.sh is only Homebrew/core
    /// and Homebrew/cask; querying it by token alone reports a different package of the same name.
    /// https://formulae.brew.sh/docs/api/ https://docs.brew.sh/FAQ
    private static func homebrewVersion(
        brew: String,
        token: String,
        cask: Bool,
        environment: [String: String],
        probe: CLIProbe
    ) async throws -> String {
        var environment = environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_EMOJI"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        let result = try await probe.run(
            URL(fileURLWithPath: brew),
            ["info", cask ? "--cask" : "--formula", "--json=v2", token],
            environment
        )
        guard result.succeeded else {
            let detail = result.failureMessage.split(whereSeparator: \.isNewline).first.map(String.init) ?? result.failureMessage
            throw ShellError(String(format: String(localized: "brew info failed: %@"), detail))
        }
        let entry = try homebrewEntry(result.stdout, cask: cask)
        let local = try homebrewVersion(in: entry, cask: cask, source: "brew info")
        let tap = entry["tap"] as? String
        let official = cask ? tap == "homebrew/cask" : tap == "homebrew/core"
        guard official, let url = URL(string: "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(token).json") else {
            return local
        }
        let remoteJSON = try feedJSON(try await probe.fetch(url))
        let remote = try homebrewVersion(in: remoteJSON, cask: cask, source: "The release feed")
        return compare(remote, with: local) == .newer ? remote : local
    }

    private static func homebrewEntry(_ data: Data, cask: Bool) throws -> [String: Any] {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw ShellError(String(localized: "brew info returned invalid JSON.")) }
        guard let object = json as? [String: Any] else { throw ShellError(String(localized: "brew info returned invalid JSON.")) }
        let key = cask ? "casks" : "formulae"
        guard let entries = object[key] as? [[String: Any]] else { throw ShellError(String(localized: "brew info returned invalid JSON.")) }
        guard let entry = entries.first else { throw ShellError(String(localized: "brew info did not include a version.")) }
        return entry
    }

    private static func homebrewVersion(in json: [String: Any], cask: Bool, source: String) throws -> String {
        let raw: String?
        if cask {
            raw = json["version"] as? String
        } else {
            raw = (json["versions"] as? [String: Any])?["stable"] as? String
        }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShellError(source == "brew info" ? String(localized: "brew info did not include a version.") : String(localized: "The release feed did not include a version."))
        }
        let version = (cask ? raw.split(separator: ",").first.map(String.init) ?? raw : raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard versionToken(exact: version) != nil else {
            throw ShellError(source == "brew info" ? String(localized: "brew info's version could not be read.") : String(localized: "The release feed's version could not be read."))
        }
        return version
    }

    /// `autoUpdatesChannel` in the user settings file. Missing file or key means `latest`.
    /// A broken file is not treated as either channel. Project settings are not read.
    /// https://code.claude.com/docs/en/setup https://code.claude.com/docs/en/settings
    private static func claudeReleaseChannel(_ probe: CLIProbe, environment: [String: String]) -> ClaudeReleaseChannel {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (probe.home() as NSString).appendingPathComponent(".claude")
        let path = probe.standardize((config as NSString).appendingPathComponent("settings.json"))
        guard let data = probe.readFile(path) else { return .latest }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        guard json.keys.contains("autoUpdatesChannel") else { return .latest }
        switch json["autoUpdatesChannel"] as? String {
        case "stable": return .stable
        case "latest": return .latest
        default: return .unreadable
        }
    }

    private enum ClaudeReleaseChannel {
        case latest
        case stable
        case unreadable
    }

    // MARK: - Versions

    private struct ParsedVersion {
        var numbers: [Int]
        var prerelease: [PrereleaseID]
    }

    private enum PrereleaseID: Equatable {
        case number(Int)
        case word(String)
    }

    /// https://semver.org/#spec-item-11
    private static func comparePrerelease(_ candidate: [PrereleaseID], _ baseline: [PrereleaseID]) -> CLIVersionComparison {
        if candidate.isEmpty, baseline.isEmpty { return .equal }
        if candidate.isEmpty { return .newer }
        if baseline.isEmpty { return .older }
        for (lhs, rhs) in zip(candidate, baseline) {
            switch (lhs, rhs) {
            case let (.number(new), .number(old)):
                if new != old { return new > old ? .newer : .older }
            case (.number, .word):
                return .older
            case (.word, .number):
                return .newer
            case let (.word(new), .word(old)):
                if new != old { return new > old ? .newer : .older }
            }
        }
        if candidate.count == baseline.count { return .equal }
        return candidate.count > baseline.count ? .newer : .older
    }

    private static func versionToken(in text: String) -> ParsedVersion? {
        let cleaned = TextCleanup.stripANSI(text)
        var cursor = cleaned.startIndex
        while cursor < cleaned.endIndex {
            if boundary(cleaned, at: cursor), let (parsed, end) = consumeVersion(cleaned, from: cursor), endBoundary(cleaned, at: end) {
                return parsed
            }
            cursor = cleaned.index(after: cursor)
        }
        return nil
    }

    private static func versionToken(exact text: String) -> ParsedVersion? {
        let cleaned = TextCleanup.stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (parsed, end) = consumeVersion(cleaned, from: cleaned.startIndex), end == cleaned.endIndex else { return nil }
        return parsed
    }

    private static func consumeVersion(_ text: String, from start: String.Index) -> (ParsedVersion, String.Index)? {
        var cursor = start
        if cursor < text.endIndex, text[cursor] == "v" || text[cursor] == "V" {
            let next = text.index(after: cursor)
            if next < text.endIndex, text[next].isNumber { cursor = next }
        }
        guard let numbers = consumeNumbers(text, from: &cursor), numbers.count >= 2 else { return nil }
        var prerelease: [PrereleaseID] = []
        if cursor < text.endIndex, text[cursor] == "-" {
            cursor = text.index(after: cursor)
            guard let identifiers = consumePrerelease(text, from: &cursor) else { return nil }
            prerelease = identifiers
        }
        if cursor < text.endIndex, text[cursor] == "+" {
            cursor = text.index(after: cursor)
            guard consumeDotIdentifiers(text, from: &cursor) else { return nil }
        }
        if cursor < text.endIndex, text[cursor] == "," {
            guard let revisions = consumeCommaRevisions(text, from: &cursor) else { return nil }
            return (ParsedVersion(numbers: numbers + revisions, prerelease: prerelease), cursor)
        }
        return (ParsedVersion(numbers: numbers, prerelease: prerelease), cursor)
    }

    private static func consumeNumbers(_ text: String, from cursor: inout String.Index) -> [Int]? {
        var numbers: [Int] = []
        var value: Int?
        var digits = 0
        var leadingZero = false
        func finish() -> Bool {
            guard let value, digits > 0, !(leadingZero && digits > 1 && (numbers.first ?? 0) < 2000) else { return false }
            numbers.append(value)
            return true
        }
        while cursor < text.endIndex, text[cursor].isNumber || text[cursor] == "." {
            if text[cursor] == "." {
                guard finish() else { return nil }
                value = nil
                digits = 0
                leadingZero = false
            } else {
                let digit = Int(String(text[cursor])) ?? 0
                if digits == 0 { leadingZero = digit == 0 }
                value = (value ?? 0) * 10 + digit
                digits += 1
                if digits > 9 { return nil }
            }
            cursor = text.index(after: cursor)
        }
        guard finish() else { return nil }
        return numbers
    }

    private static func consumePrerelease(_ text: String, from cursor: inout String.Index) -> [PrereleaseID]? {
        var identifiers: [PrereleaseID] = []
        var word = ""
        func finish() -> Bool {
            guard !word.isEmpty else { return false }
            if word.allSatisfy(\.isNumber) {
                if word.count > 1, word.first == "0" { return false }
                guard let number = Int(word) else { return false }
                identifiers.append(.number(number))
            } else {
                identifiers.append(.word(word))
            }
            word = ""
            return true
        }
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "." {
                guard finish() else { return nil }
            } else if character.isNumber || character.isLetter || character == "-" {
                word.append(character)
            } else {
                break
            }
            cursor = text.index(after: cursor)
        }
        guard finish() else { return nil }
        return identifiers
    }

    private static func consumeDotIdentifiers(_ text: String, from cursor: inout String.Index) -> Bool {
        var length = 0
        var empty = true
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "." {
                if empty { return false }
                empty = true
            } else if character.isNumber || character.isLetter || character == "-" {
                empty = false
                length += 1
            } else {
                break
            }
            cursor = text.index(after: cursor)
        }
        return length > 0 && !empty
    }

    private static func consumeCommaRevisions(_ text: String, from cursor: inout String.Index) -> [Int]? {
        var revisions: [Int] = []
        while cursor < text.endIndex, text[cursor] == "," {
            cursor = text.index(after: cursor)
            let start = cursor
            while cursor < text.endIndex, text[cursor].isNumber { cursor = text.index(after: cursor) }
            let digits = text[start..<cursor]
            guard !digits.isEmpty, digits.count <= 9, let value = Int(digits) else { return nil }
            revisions.append(value)
        }
        return revisions.isEmpty ? nil : revisions
    }

    private static func endBoundary(_ text: String, at index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        let next = text[index]
        return !next.isNumber && !next.isLetter && !".+-,".contains(next)
    }

    private static func boundary(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex, index < text.endIndex else { return true }
        let previous = text[text.index(before: index)]
        return !previous.isNumber && !previous.isLetter && previous != "."
    }

    // MARK: - Paths

    /// Package identities follow the official install docs: code.claude.com/docs/en/setup,
    /// learn.chatgpt.com/docs/codex/cli, opencode.ai/docs, pi.dev/docs/latest/quickstart,
    /// docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli,
    /// and commandcode.ai/docs. Other packages do not grant update permission.
    private static func knownPackages(_ provider: ProviderKind) -> Set<String> {
        switch provider {
        case .claude: ["@anthropic-ai/claude-code"]
        case .codex: ["@openai/codex"]
        case .copilot: ["@github/copilot"]
        case .opencode, .opencodeGo: ["opencode-ai"]
        case .pi: ["@earendil-works/pi-coding-agent"]
        case .commandcode: ["command-code"]
        default: []
        }
    }

    private static func directPackage(_ parts: [String], modules: Int) -> String? {
        guard modules + 1 < parts.count else { return nil }
        guard !parts[(modules + 1)...].contains("node_modules") else { return nil }
        let name = parts[modules + 1]
        if name.hasPrefix("@") {
            guard modules + 3 < parts.count, isPackagePiece(name), isPackagePiece(parts[modules + 2]) else { return nil }
            return "\(name)/\(parts[modules + 2])"
        }
        guard modules + 2 < parts.count, isPackagePiece(name) else { return nil }
        return name
    }

    private static func isPackagePiece(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        let rest = name.dropFirst()
        if first == "@" { return !rest.isEmpty && rest.allSatisfy(packageCharacter) }
        return packageCharacter(first) && rest.allSatisfy(packageCharacter)
    }

    private static func packageCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
    }

    private static func isNodeFormula(_ token: String) -> Bool {
        token == "node" || token.hasPrefix("node@")
    }

    private static func isBrewToken(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter || first.isNumber, !token.hasSuffix(".rb") else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || "+-_.@".contains($0) }
    }

    private static func isProtected(_ path: String) -> Bool {
        let parts = components(path)
        guard parts.count >= 2, parts[0] == "/" else { return false }
        switch parts[1] {
        case "nix", "bin", "sbin", "System": return true
        case "usr": return parts.count >= 3 && ["bin", "lib", "sbin"].contains(parts[2])
        default: return false
        }
    }

    private static func isWithin(_ path: String, _ directory: String) -> Bool {
        let pathParts = components(path)
        let directoryParts = components(directory)
        guard pathParts.count > directoryParts.count else { return false }
        return Array(pathParts.prefix(directoryParts.count)) == directoryParts
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        components(lhs) == components(rhs)
    }

    private static func components(_ path: String) -> [String] {
        ((path as NSString).standardizingPath as NSString).pathComponents
    }

    private static func join(_ parts: [String]) -> String {
        NSString.path(withComponents: parts)
    }

    private static func registryURL(package: String, tag: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let name = package.addingPercentEncoding(withAllowedCharacters: allowed),
              let tag = tag.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://registry.npmjs.org/\(name)/\(tag)")
    }

    private static func feedJSON(_ data: Data) throws -> [String: Any] {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw ShellError(String(localized: "The release feed returned invalid JSON.")) }
        guard let json = object as? [String: Any] else { throw ShellError(String(localized: "The release feed returned invalid JSON.")) }
        return json
    }
}
