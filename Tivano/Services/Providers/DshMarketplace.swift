import CryptoKit
import Foundation
import Synchronization

struct DshLaunchPlan: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let ownedDirectory: URL?
    var warning: String? = nil

    func cleanup() {
        guard let ownedDirectory,
              ownedDirectory.standardizedFileURL == ownedDirectory.resolvingSymlinksInPath().standardizedFileURL,
              (try? String(contentsOf: ownedDirectory.appendingPathComponent("owner"), encoding: .utf8)) == ownedDirectory.lastPathComponent else { return }
        try? FileManager.default.removeItem(at: ownedDirectory)
    }

    func releaseAfterExit(of process: StdioProcess) {
        guard ownedDirectory != nil else { return }
        Task.detached {
            _ = await process.waitForExit()
            cleanup()
        }
    }
}

enum DshMarketplace {
    /// The launch without the desktop profile: the arguments with the profile's own patch
    /// left out, for a runtime the profile bootstrap does not fit (see `DshCLI.prepareLaunch`).
    static func plainPlan(executable: URL, arguments: [String], environment: [String: String], warning: String?) -> DshLaunchPlan {
        let inherited = DshCLI.userProfilePatch(environment: environment)?.path
        var plainArguments: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--patch", index + 1 < arguments.count {
                if arguments[index + 1] != inherited {
                    plainArguments.append(arguments[index])
                    plainArguments.append(arguments[index + 1])
                }
                index += 2
            } else {
                plainArguments.append(arguments[index])
                index += 1
            }
        }
        return DshLaunchPlan(executable: executable, arguments: plainArguments, environment: environment, ownedDirectory: nil, warning: warning)
    }

    static func prepare(executable: URL, arguments: [String], environment: [String: String]) throws -> DshLaunchPlan {
        let fm = FileManager.default
        let profiles = DshCLI.accountHome(environment: environment).appendingPathComponent("profiles")
        let source = try ["desktop", "web"].map { profiles.appendingPathComponent($0) }.first { directory in
            let manifest = directory.appendingPathComponent("package.json")
            do {
                _ = try fm.attributesOfItem(atPath: manifest.path)
                return true
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return false
            }
        }
        guard let source else {
            return DshLaunchPlan(executable: executable, arguments: arguments, environment: environment, ownedDirectory: nil)
        }
        let manifest: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("package.json"))) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            manifest = parsed
        } catch {
            throw ProviderError.failed(AppText.localized("DeepSeek Harness could not read the selected profile manifest. Repair it before restarting."))
        }
        // The installed shell launcher explicitly enters Electron's Node mode. The CLI
        // itself does not accept arbitrary JavaScript as an application argument.
        let launcher = executable.resolvingSymlinksInPath()
        let resources = launcher.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let electron = resources.deletingLastPathComponent().appendingPathComponent("MacOS/DeepSeek Harness")
        guard launcher.path.hasSuffix("/runtime/cli/bin/dsh"),
              fm.isExecutableFile(atPath: electron.path),
              let script = try? String(contentsOf: launcher, encoding: .utf8),
              script.contains("ELECTRON_RUN_AS_NODE=1"),
              script.contains("dsh-desktop-host/lib/cli.js") else {
            let shipped: Set<String> = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-acp-app"]
            if let dsh = manifest["dsh"] as? [String: Any],
               let profile = dsh["profile"] as? [String: Any],
               let bundles = profile["bundles"] as? [String],
               bundles.allSatisfy({ shipped.contains($0) }),
               (manifest["dependencies"] as? [String: Any] ?? [:]).keys.allSatisfy({ shipped.contains($0) }),
               (manifest["peerDependencies"] as? [String: Any] ?? [:]).isEmpty {
                return DshLaunchPlan(executable: executable, arguments: arguments, environment: environment, ownedDirectory: nil)
            }
            throw ProviderError.failed(String(format: AppText.localized("DeepSeek Harness at %@ cannot inherit the desktop app's marketplace profile, and retrying will fail the same way. Use the CLI bundled with the DeepSeek Harness app, or set it as the Binary path in Settings → Providers → DeepSeek Harness."), executable.path))
        }
        let state = DshCLI.home
        let root = state.appendingPathComponent("marketplace-runs", isDirectory: true)
        guard state.standardizedFileURL == state.resolvingSymlinksInPath().standardizedFileURL else {
            throw ProviderError.failed(AppText.localized("DeepSeek Harness could not create a private marketplace run directory."))
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ProviderError.failed(AppText.localized("DeepSeek Harness could not create a private marketplace run directory."))
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var overlays: [String] = []
            var index = 0
            let inherited = DshCLI.userProfilePatch(environment: environment)?.path
            while index < arguments.count {
                if arguments[index] == "--patch", index + 1 < arguments.count {
                    if arguments[index + 1] != inherited { overlays.append(arguments[index + 1]) }
                    index += 2
                } else { index += 1 }
            }
            let options: [String: Any] = [
                "runtime": resources.appendingPathComponent("app.asar/dsh").path,
                "source": source.path,
                "home": DshCLI.accountHome(environment: environment).path,
                "overlays": overlays,
                "errors": DshMarketplaceBootstrap.errorMessages,
            ]
            let files: [(String, Data)] = [
                ("owner", Data(directory.lastPathComponent.utf8)),
                ("bootstrap.mjs", Data(DshMarketplaceBootstrap.source.utf8)),
                ("options.json", try JSONSerialization.data(withJSONObject: options)),
                ("cordis.yml", Data("[]\n".utf8)),
                ("package.json", Data("{\"private\":true,\"type\":\"module\"}\n".utf8)),
            ]
            for (name, data) in files {
                guard fm.createFile(atPath: directory.appendingPathComponent(name).path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw ProviderError.failed(AppText.localized("DeepSeek Harness could not create a private marketplace run directory."))
                }
            }
            var environment = environment
            environment["ELECTRON_RUN_AS_NODE"] = "1"
            return DshLaunchPlan(executable: electron, arguments: ["--expose-internals", directory.appendingPathComponent("bootstrap.mjs").path], environment: environment, ownedDirectory: directory)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }
}

/// Whether a DeepSeek Harness runtime fits the desktop-profile bootstrap, found by running
/// the bootstrap once in check mode rather than pinning one version: the internal modules
/// it reads are not a public API, but most releases leave them as they were. The answer is
/// kept per runtime version and bootstrap, so a new release or a new Tivano asks again.
enum DshMarketplaceCompatibility {
    enum Verdict: Sendable {
        case compatible
        case incompatible
        /// The check could not tell (the profile itself was refused, or it timed out): the
        /// launch goes ahead and the session reports what it finds, as it always did.
        case unknown
    }

    private static let verdictsKey = "dshMarketplaceCompatibility"
    private static let warnedKey = "dshMarketplaceIncompatibleWarned"
    private static let checks = Mutex<[String: Task<Verdict, Never>]>([:])
    private static let bootstrapDigest = SHA256.hash(data: Data(DshMarketplaceBootstrap.source.utf8))
        .prefix(8).map { String(format: "%02x", $0) }.joined()

    private static func key(_ version: String?) -> String {
        "\(version ?? "unknown")|\(bootstrapDigest)"
    }

    static func verdict(for plan: DshLaunchPlan, version: String?) async -> Verdict {
        let key = key(version)
        if let known = (UserDefaults.standard.dictionary(forKey: verdictsKey) as? [String: Bool])?[key] {
            return known ? .compatible : .incompatible
        }
        let task = checks.withLock { running in
            if let task = running[key] { return task }
            let task = Task<Verdict, Never> {
                var environment = plan.environment
                environment["TIVANO_DSH_CHECK"] = "1"
                guard let result = try? await Shell.run(plan.executable, plan.arguments, in: FileManager.default.temporaryDirectory, environment: environment, timeout: 90) else {
                    return .unknown
                }
                let verdict: Verdict = switch result.status {
                case 0: .compatible
                case 3: .incompatible
                default: .unknown
                }
                if verdict != .unknown {
                    var stored = UserDefaults.standard.dictionary(forKey: verdictsKey) as? [String: Bool] ?? [:]
                    stored[key] = verdict == .compatible
                    UserDefaults.standard.set(stored, forKey: verdictsKey)
                }
                return verdict
            }
            running[key] = task
            return task
        }
        let verdict = await task.value
        checks.withLock { $0[key] = nil }
        return verdict
    }

    /// The notice for a runtime that does not fit, the first time only for each version.
    static func takeWarning(version: String?) -> String? {
        let key = key(version)
        var warned = UserDefaults.standard.stringArray(forKey: warnedKey) ?? []
        guard !warned.contains(key) else { return nil }
        warned.append(key)
        UserDefaults.standard.set(warned, forKey: warnedKey)
        return String(format: AppText.localized("DeepSeek Harness %@ changed what Tivano reads to load your desktop profile, so chats on it run without the profile's plugins until Tivano catches up."), version ?? AppText.localized("unknown"))
    }
}
