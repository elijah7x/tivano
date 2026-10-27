import CryptoKit
import Foundation

enum ZCodeCLI {
    nonisolated static let efforts = ["low", "high", "max"]
    nonisolated static let defaultEffort = "max"

    nonisolated static func defaultEntry() -> URL? {
        ["/Applications", "\(LoginEnvironment.homeDirectory)/Applications"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("ZCode.app/Contents/Resources/glm/zcode.cjs") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func appBundle(entry: URL) -> URL? {
        var ancestor = entry.resolvingSymlinksInPath()
        while ancestor.path != "/" {
            if ancestor.pathExtension == "app" { return ancestor }
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated static func runtime(entry: URL) -> URL? {
        guard let url = appBundle(entry: entry)?.appendingPathComponent("Contents/MacOS/ZCode"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    nonisolated static func builtinConfig(entry: URL) -> URL? {
        guard let url = appBundle(entry: entry)?.appendingPathComponent("Contents/Resources/config/provider/zcode-builtin.json"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    nonisolated static var personalConfigPath: String {
        "\(LoginEnvironment.homeDirectory)/.zcode/v2/provider_config.json"
    }

    nonisolated static func version(entry: URL) -> String? {
        guard let url = appBundle(entry: entry)?.appendingPathComponent("Contents/Info.plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    nonisolated static func launchEnvironment(entry: URL, base: [String: String]) -> [String: String] {
        var environment = base
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        // Both overrides are required for the server to use the same builtin revision.
        environment["ZCODE_BUILTIN_PROVIDER_CONFIG_FILE"] = builtinConfig(entry: entry)?.path
            ?? appBundle(entry: entry)?.appendingPathComponent("Contents/Resources/config/provider/zcode-builtin.json").path ?? ""
        environment["ZCODE_PERSONAL_PROVIDER_CONFIG_FILE"] = personalConfigPath
        return environment
    }

    nonisolated static func accountProviderID(_ region: ZaiRegion) -> String {
        switch region {
        case .global: "account:zai-individual-coding-plan"
        case .china: "account:bigmodel-individual-coding-plan"
        }
    }

    nonisolated static func models(entry: URL, region: ZaiRegion) -> [ModelOption] {
        guard let url = builtinConfig(entry: entry), let json = readJSON(url),
              let rules = json["config"]?["providerConfigRules"]?["providerRules"]?.array,
              let rule = rules.first(where: { $0["providerId"]?.string == accountProviderID(region) }),
              let models = rule["config"]?["builtinModelIds"]?.array,
              models.allSatisfy({ $0.string != nil }) else { return [] }
        return models.compactMap(\.string).enumerated().map { index, id in
            ModelOption(id: id, name: id, efforts: efforts, defaultEffort: defaultEffort, isDefault: index == 0)
        }
    }

    nonisolated static func builtinRevision(entry: URL) -> String? {
        guard let url = builtinConfig(entry: entry), let json = readJSON(url),
              case .int(let revision)? = json["revision"] else { return nil }
        let digest = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "zcode-builtin:\(revision):\(digest)"
    }

    nonisolated static func runtimePreferences() -> JSONValue {
        let settings = readJSON(URL(fileURLWithPath: "\(LoginEnvironment.homeDirectory)/.zcode/v2/setting.json"))
        var result: [String: JSONValue] = [
            "nativeSearchEnhancementsEnabled": .bool(settings?["nativeSearchEnhancementsEnabled"]?.bool ?? false),
        ]
        for key in ["memoryEnabled", "askUserQuestionAutoResolutionEnabled"] {
            if let value = settings?[key]?.bool { result[key] = .bool(value) }
        }
        if let mode = settings?["toolSearchMode"]?.string, ["auto", "native", "local", "off"].contains(mode) {
            result["toolSearchMode"] = .string(mode)
        }
        return .object(result)
    }

    nonisolated private static func readJSON(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return JSONValue.parse(data)
    }
}
