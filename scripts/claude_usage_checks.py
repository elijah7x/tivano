#!/usr/bin/env python3
"""Run the production Claude usage reader with fake credentials and HTTP transport."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + "\n"


def main():
    if sys.flags.optimize:
        raise SystemExit("run without -O or PYTHONOPTIMIZE; fixture assertions must remain enabled")
    production = (ROOT / 'Tivano/Services/Providers/PlanLimits.swift').read_text()
    marker = '// MARK: - Claude'
    count = production.count(marker)
    if count != 1:
        raise SystemExit(f'PlanLimits.swift: marker {marker!r} found {count} times, expected 1; refusing to run to avoid accessing real api.anthropic.com')
    claude = production[production.index('    // MARK: - Claude'):]
    # Replace only the transport; retain request construction and response handling.
    transport = 'URLSession.shared.data(for: request)'
    count = claude.count(transport)
    if count != 1:
        raise SystemExit(f'Claude production transport changed: {transport!r} found {count} times, expected 1; refusing to run to avoid accessing real api.anthropic.com')
    claude = claude.replace(transport, 'FixtureHTTP.data(for: request)')
    if 'URLSession' in claude:
        raise SystemExit('Claude production transport changed: URLSession remains after replacement; refusing to run to avoid accessing real api.anthropic.com')
    source = 'import Foundation\n'
    source += (ROOT / 'Tivano/Core/Support/JSONValue.swift').read_text()
    source += (ROOT / 'Tivano/Core/Support/ISO8601.swift').read_text()
    source += declaration(production, 'struct PlanLimits:')
    source += r'''
enum AppText { static func localized(_ text: String) -> String { text } }
enum CaptureRun { static var isEnabled = false }
enum ProviderKind { case claude }
struct Account {
    var id = UUID(); var provider = ProviderKind.claude
    var home: String? = "/fixture/claude"
    var isDefault = false
    var requiresClaudeActivation = false
    var requiresClaudeCleanup = false
}
enum ClaudeCredentialError: Error { case denied }
enum ProviderAccountStore {
    static var accounts = [Account()]
    static var credential: Data?
    static var reads = 0
    static var denied = false
    static func load() -> (accounts: [Account], unused: Bool) { (accounts, false) }
    static func claudeCredentials(environment: [String: String]) async throws -> Data? {
        reads += 1
        if denied { throw ClaudeCredentialError.denied }
        return credential
    }
}
enum ProviderAccounts {
    static var locks = 0
    static func beginClaudeCredentialRead(environment: [String: String]) throws -> UUID? {
        locks += 1; return ProviderAccountStore.accounts.first?.id
    }
    static func endRead(_ id: UUID) { locks -= 1 }
    static func safeClaudeError(_ error: Error) -> String { "Fixture denied" }
}
enum FixtureHTTP {
    static var calls = 0
    static var status = 200
    static var body = Data(#"{"five_hour":{"utilization":25},"seven_day":{"utilization":42}}"#.utf8)
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        precondition(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        precondition(request.httpMethod == "GET" && request.httpBody == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        precondition(request.timeoutInterval == 15)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor enum PlanLimitsReader {
'''
    source += declaration(production, '    static func failure(')
    source += declaration(production, '    nonisolated static func planName(')
    source += claude
    source += r'''
@main struct Checks {
    @MainActor static func main() async throws {
        let env = ["CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST": "1", "CLAUDE_CONFIG_DIR": "/fixture/claude"]
        func login(expired: Bool) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
                "accessToken": "fixture-only", "refreshToken": "never-used",
                "expiresAt": Date.now.addingTimeInterval(expired ? -600 : 3600).timeIntervalSince1970 * 1000
            ]])
        }
        ProviderAccountStore.credential = try login(expired: true)
        let expired = await PlanLimitsReader.readClaude(environment: env)
        precondition(expired?.problemKind == .unavailable && FixtureHTTP.calls == 0)
        ProviderAccountStore.credential = try login(expired: false)
        let success = await PlanLimitsReader.readClaude(environment: env)
        precondition(success?.windows.map(\.percent) == [25, 42] && FixtureHTTP.calls == 1)
        FixtureHTTP.status = 401
        let unauthorized = await PlanLimitsReader.readClaude(environment: env)
        precondition(unauthorized?.problemKind == .unavailable && FixtureHTTP.calls == 2)
        ProviderAccountStore.denied = true
        let denied = await PlanLimitsReader.readClaude(environment: env)
        precondition(denied?.problemKind == .unavailable && FixtureHTTP.calls == 2)
        let reads = ProviderAccountStore.reads
        ProviderAccountStore.accounts[0].requiresClaudeActivation = true
        let pending = await PlanLimitsReader.readClaude(environment: env)
        precondition(pending == nil && ProviderAccountStore.reads == reads)
        ProviderAccountStore.accounts[0].requiresClaudeActivation = false
        ProviderAccountStore.accounts[0].requiresClaudeCleanup = true
        let cleanup = await PlanLimitsReader.readClaude(environment: env)
        precondition(cleanup == nil && ProviderAccountStore.reads == reads)
        ProviderAccountStore.accounts[0].requiresClaudeCleanup = false
        CaptureRun.isEnabled = true
        let capture = await PlanLimitsReader.readClaude(environment: env)
        precondition(capture == nil && ProviderAccountStore.reads == reads && ProviderAccounts.locks == 0)
        print("PASS: Claude usage is read-only; expired/401, denied, pending, cleanup and capture paths use no refresh or CLI.")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix='tivano-claude-usage-') as temp:
        directory = Path(temp)
        swift, binary = directory / 'Checks.swift', directory / 'checks'
        swift.write_text(source)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, env={'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(directory)})


if __name__ == '__main__':
    main()
