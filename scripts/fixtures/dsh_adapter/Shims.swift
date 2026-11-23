import Foundation

enum CaptureRun {
    static var storageRoot: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_TEST_ROOT"]!) }
    static var defaults: UserDefaults? { nil }
}
struct HydraLaunch: Sendable {}
enum LoginEnvironment {
    static var homeDirectory: String { ProcessInfo.processInfo.environment["HOME"]! }
    static var current: [String: String] { ProcessInfo.processInfo.environment }
    static func load() async {}
}
struct ShellResult: Sendable {
    var succeeded = false
    var status: Int32 { succeeded ? 0 : 1 }
    var output = ""
    var stdout: Data { Data(output.utf8) }
    var errorOutput = ""
}
enum Shell {
    // Keep the marketplace preflight signature without launching a real shell.
    static func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil, environment: [String: String], timeout: Double) async throws -> ShellResult {
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
    // Preserve the production tuple without reading user config or resolving commands.
    static func acpServers(allowsHTTP: Bool) -> (servers: JSONValue, skipped: [String]) {
        guard ProcessInfo.processInfo.environment["DSH_TEST_CASE"] == "mixed-mcp" else { return (.array([]), []) }
        return ([["name": "healthy", "command": "/not-executed", "args": [], "env": []],
                 ["name": "broken", "command": "/not-executed", "args": [], "env": []]], [])
    }
}
// ACPSession's Antigravity hooks; no case here runs Antigravity, so they stay inert.
@MainActor final class TokenLedger {
    static let shared = TokenLedger()
    func record(spend: Int, on date: Date = Date()) {}
}
enum ProviderRegistry { static let antigravitySeed: [ModelOption] = [] }
final class AntigravityLogTailer {
    init(url: URL, onLine: @escaping @Sendable (String) -> Void) {}
    func setTurnActive(_ active: Bool) {}
    func shutDown() {}
}
@MainActor enum AntigravitySession {
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    static func makeLogFileURL() -> URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_TEST_ROOT"]!).appendingPathComponent("antigravity.log") }
    nonisolated static func parseRetryDetails(_ line: String) -> (attempt: Int, reason: String, labelKey: String)? { nil }
    static func retryNotice(attempt: Int, reason: String, labelKey: String) -> Notice { Notice(level: .warning, message: reason) }
    static func loginHint(in text: String) -> String? { nil }
    static func addingSeedRows(_ catalog: [ModelOption], seed: [ModelOption]) -> [ModelOption] { catalog }
    static func normalize(model: String?, effort: String?, catalog: [ModelOption]) -> (model: String?, effort: String?) { (model, effort) }
}
