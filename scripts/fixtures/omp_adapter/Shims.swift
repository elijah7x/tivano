import Foundation

enum CaptureRun {
    static var storageRoot: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["T08_STORAGE"]!) }
    // ZaiRegion needs this capture hook; keep preferences inside the fixture root.
    static let defaults: UserDefaults? = UserDefaults(suiteName: storageRoot!.appendingPathComponent("defaults").path)!
}
struct HydraLaunch: Sendable {}
enum HydraPrompts { static func fallbackPolicy(_ launch: HydraLaunch) -> String { "App-run heads only" } }
@MainActor final class TokenLedger { static let shared = TokenLedger(); var total=0; func record(spend: Int) { total += spend } }
enum MCPPaths { static var claudeConfigURL: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["T08_STORAGE"]!).appendingPathComponent("no-mcp.json") } }
enum MCPBridge { static func installBridge() throws -> URL { throw ProviderError.failed("fixture has no MCP bridge") } }
enum LoginEnvironment { static var homeDirectory: String { ProcessInfo.processInfo.environment["T08_STORAGE"]! } }
struct ShellResult: Sendable { var stdout=Data(); var succeeded=false; var failureMessage="unexecuted catalog shim" }
enum Shell { static func run(_ executable: URL, _ args: [String], in directory: URL, environment: [String:String], timeout: Double) async throws -> ShellResult { throw ProviderError.failed("catalog path not tested by adapter fixture") } }
// ProviderSession's ToolImages needs these signatures; real Storage pulls in the app's
// library persistence and UI dependencies. These fixtures do not import tool images.
enum Storage {
    static func importAttachment(from url: URL) throws -> Attachment { throw ProviderError.failed("No fixture images") }
    static func importAttachment(data: Data, name: String, fileExtension: String) throws -> Attachment { throw ProviderError.failed("No fixture images") }
}
