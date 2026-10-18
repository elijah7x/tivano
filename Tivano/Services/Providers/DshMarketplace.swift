import Foundation

struct DshLaunchPlan: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let ownedDirectory: URL?

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
            throw ProviderError.failed(AppText.localized("This DeepSeek Harness installation does not support read-only marketplace inheritance. Use the bundled desktop CLI."))
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
