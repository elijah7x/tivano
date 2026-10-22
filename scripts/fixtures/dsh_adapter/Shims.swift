import Foundation

enum CaptureRun {
    static var storageRoot: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_TEST_ROOT"]!) }
    static var defaults: UserDefaults? { nil }
}
struct HydraLaunch: Sendable {}
struct VoiceOrchestratorContext: Sendable {}
enum LoginEnvironment {
    static var homeDirectory: String { ProcessInfo.processInfo.environment["HOME"]! }
    static var current: [String: String] { ProcessInfo.processInfo.environment }
    static func load() async {}
}
struct ShellResult: Sendable {
    var succeeded = false
    var output = ""
    var stdout: Data { Data(output.utf8) }
    var errorOutput = ""
}
enum Shell {
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: Double) async throws -> ShellResult {
        let test = ProcessInfo.processInfo.environment["DSH_TEST_CASE"] ?? ""
        if arguments == ["provider", "list", "--json"], test.hasPrefix("empty-variant") {
            return ShellResult(succeeded: true, output: test == "empty-variant"
                ? #"{"minimaxModelSource":"token_plan"}"#
                : #"{"minimaxModelSource":"minimax_api_key"}"#)
        }
        if ["final-report", "report-guard-missing", "patch-validation"].contains(test), arguments.last == "--dump-config" {
            let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_TEST_ROOT"]!).appendingPathComponent("patch-warnings.txt")
            return ShellResult(succeeded: true, output: "[]", errorOutput: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
        }
        throw ProviderError.failed("Fixture does not exercise Shell preflight")
    }
}
enum Storage {
    static func importAttachment(from url: URL) throws -> Attachment { throw ProviderError.failed("No fixture images") }
    static func importAttachment(data: Data, name: String, fileExtension: String) throws -> Attachment { throw ProviderError.failed("No fixture images") }
}
enum MCPProviderConfig {
    static func acpServers(allowsHTTP: Bool) -> JSONValue {
        guard ProcessInfo.processInfo.environment["DSH_TEST_CASE"] == "mixed-mcp" else { return .array([]) }
        return [["name": "healthy", "command": "/not-executed", "args": [], "env": []],
                ["name": "broken", "command": "/not-executed", "args": [], "env": []]]
    }
}
