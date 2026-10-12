import Foundation

enum CaptureRun { static var storageRoot: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["T08_STORAGE"]!) } }
struct HydraLaunch: Sendable {}
enum HydraPrompts { static func fallbackPolicy(_ launch: HydraLaunch) -> String { "App-run heads only" } }
@MainActor final class TokenLedger { static let shared = TokenLedger(); var total=0; func record(spend: Int) { total += spend } }
enum MCPPaths { static var claudeConfigURL: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["T08_STORAGE"]!).appendingPathComponent("no-mcp.json") } }
enum MCPBridge { static func installBridge() throws -> URL { throw ProviderError.failed("fixture has no MCP bridge") } }
enum LoginEnvironment { static var homeDirectory: String { ProcessInfo.processInfo.environment["T08_STORAGE"]! } }
struct ShellResult: Sendable { var stdout=Data(); var succeeded=false; var failureMessage="unexecuted catalog shim" }
enum Shell { static func run(_ executable: URL, _ args: [String], in directory: URL, environment: [String:String], timeout: Double) async throws -> ShellResult { throw ProviderError.failed("catalog path not tested by adapter fixture") } }
