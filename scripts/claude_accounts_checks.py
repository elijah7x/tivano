#!/usr/bin/env python3
"""Exercise production Claude credential and account code with synthetic files and Keychain.

Never reads the real login environment, Keychain, starts a provider, or makes a
network request. Security calls and account-service dependencies in the generated
copy are replaced; credential parsing and ProviderAccounts transaction logic are unchanged.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SHIMS = r'''
import Foundation
import Security
enum AppText { static func localized(_ text: String) -> String { text } }
enum CaptureRun { static var isEnabled = false }
enum LoginEnvironment {
    static var homeDirectory = CommandLine.arguments[1]
    static var current: [String: String] = ["USER": "fixture", "HOME": CommandLine.arguments[1]]
    static func load() async {}
}
enum ProviderAccountStore {
    static var accountsRoot: String { LoginEnvironment.homeDirectory + "/accounts" }
    static var stored = ProviderAccountBook()
    static var saveCalls = 0
    static var failOnSave: Int?
    static var orgNameByHome: [String: String] = [:]
    static func load() -> ProviderAccountBook { stored }
    @discardableResult static func save(_ book: ProviderAccountBook) -> Bool {
        do { try saveThrowing(book); return true } catch { return false }
    }
    static func saveThrowing(_ book: ProviderAccountBook) throws {
        saveCalls += 1
        if saveCalls == failOnSave { throw CocoaError(.fileWriteUnknown) }
        stored = book
    }
    static func defaultCodexHome(environment: [String: String]) -> String { LoginEnvironment.homeDirectory + "/codex" }
    static func claudeIdentity(home: String, isDefault: Bool = false) -> [String: String]? {
        orgNameByHome[home].map { ["organizationName": $0] }
    }
    static func makeHome(provider: ProviderKind, id: UUID, linkingFrom: String) throws -> String {
        let path = accountsRoot + "/" + provider.rawValue + "/" + id.uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
    static func removeHome(_ home: String) { try? removeHomeThrowing(home) }
    static func removeHomeThrowing(_ home: String) throws {
        if FileManager.default.fileExists(atPath: home) { try FileManager.default.removeItem(atPath: home) }
    }
    static func codexIdentity(home: String) -> CodexIdentity? { nil }
    static func codexImportCandidates(defaultHome: String) -> [CodexImportCandidate] { [] }
    static func importCodexCredential(_ candidate: CodexImportCandidate, into home: String) throws {}
}
extension Dictionary where Key == String, Value == String {
    var string: String? { nil }
}
extension String {
    var string: String? { self }
}
struct CodexImportCandidate { var id: String; var identity: CodexIdentity; var label: String? }

enum ProviderKind: String, Codable, Sendable {
    case claude, codex
    var displayName: String { rawValue }
    var loginCommand: String { rawValue + " auth login" }
}
struct ProviderStatus {
    enum Auth: Equatable { case unknown, signedOut, signedIn(String?) }
}
struct PlanLimits: Equatable, Sendable {
    struct Window: Equatable, Sendable { var id: String; var percent: Double; var resetsAt: Date? }
    var windows: [Window] = []
    var planName: String?
    var problem: String?
}
@MainActor enum PlanLimitsReader {
    static var reads = 0
    static var inFlight = 0
    static var peak = 0
    static var delayNanoseconds: UInt64 = 0
    static var result = PlanLimits(problem: "fixture unavailable")
    static func read(_ provider: ProviderKind, executable: URL, environment: [String: String]) async -> PlanLimits? {
        reads += 1
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        } else {
            await Task.yield()
        }
        return result
    }
    static func failure(_ message: String) -> PlanLimits { PlanLimits(problem: message) }
}
@MainActor final class ProviderRegistry {
    static var forgotten: [UUID] = []
    static func forgetClaudeIdentity(_ accountID: UUID) { forgotten.append(accountID) }
    static var authCalls = 0
    // Storage for the production catalog rules extracted from ProviderRegistry.swift below.
    var catalogs: [ProviderKind: [ModelOption]] = [:]
    var catalogFetchedAt: [ProviderKind: Date] = [:]
    static var loginIdentity = ClaudeAccountIdentity(accountID: "acct-one", organizationID: "org-one", email: "one@example.test")
    func executable(for provider: ProviderKind) -> URL? { URL(fileURLWithPath: "/fixture-never-executed") }
    func baseEnvironment(for provider: ProviderKind) -> [String: String] { LoginEnvironment.current }
    func environment(for provider: ProviderKind, account: ProviderAccount) -> [String: String] {
        var env = LoginEnvironment.current
        if let home = account.home {
            env["CLAUDE_CONFIG_DIR"] = home
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = home
            env["CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"] = "1"
        }
        return env
    }
    static func claudeIdentity(executable: URL, environment: [String: String], directory: URL, signingInAccountID: UUID? = nil) async throws -> ClaudeAccountIdentity {
        guard claudeAccountAllowsProbe(environment: environment, signingInAccountID: signingInAccountID) else {
            throw ClaudeAccountValidationError.verificationFailed
        }
        return loginIdentity
    }
    static func auth(_ provider: ProviderKind, _ executable: URL, _ environment: [String: String]) async -> ProviderStatus.Auth {
        authCalls += 1
        return .unknown
    }
    func invalidateClaudeAccountViews() {}
    func resetPlanLimits(_ provider: ProviderKind) {}
    func refreshPlanLimits(_ provider: ProviderKind, force: Bool) {}
    func refresh(_ provider: ProviderKind) async {}
    func loadCatalog(_ provider: ProviderKind, force: Bool) async {}
}
enum ProviderError: Error { case failed(String) }
enum CodexSession {
    static func readPlanLimits(executable: URL, environment: [String: String]) async throws -> PlanLimits? { nil }
}
enum TextCleanup { static func stripANSI(_ text: String) -> String { text } }
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
struct ShellResult { var status: Int32 = 0; var stdout = Data(); var stderr = Data(); var timedOut = false; var succeeded: Bool { status == 0 }; var output: String { String(decoding: stdout, as: UTF8.self) }; var errorOutput: String { String(decoding: stderr, as: UTF8.self) } }
@MainActor enum Shell {
    static var securityFindResult = ShellResult(status: 44)
    static var securityDeleteResult = ShellResult(status: 0)
    static var securityArguments: [[String]] = []
    static var cliCommands: [(arguments: [String], configDir: String?)] = []
    static var loginShouldFail = false
    static var calls = 0
    static func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil, environment: [String: String], timeout: Double) async throws -> ShellResult {
        if executable.path == "/usr/bin/security" {
            securityArguments.append(arguments)
            if arguments.first == "delete-generic-password" {
                return securityDeleteResult
            }
            return securityFindResult
        }
        calls += 1
        cliCommands.append((arguments, environment["CLAUDE_CONFIG_DIR"]))
        if arguments == ["auth", "login"] {
            if loginShouldFail { return ShellResult(status: 1) }
            if let home = environment["CLAUDE_CONFIG_DIR"] {
                ProviderAccountStore.orgNameByHome[home] = "Fixture Org"
            }
        }
        return ShellResult()
    }
}
enum FixtureKeychain {
    static var deleteCalls = 0
    static var deleteDenied = false
    static func delete(_ query: CFDictionary) -> OSStatus {
        deleteCalls += 1
        return deleteDenied ? errSecAuthFailed : errSecSuccess
    }
}
func check(_ condition: Bool, _ label: String) { precondition(condition, label) }
func rejects(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Expected rejection: " + label) } catch {}
}
@MainActor func rejectsAsync(_ label: String, _ action: () async throws -> Void) async {
    do { try await action(); fatalError("Expected rejection: " + label) } catch {}
}
'''

CHECKS = r'''
@main struct Checks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let home = LoginEnvironment.homeDirectory
        let profile = home + "/accounts/claude/a"
        let other = home + "/accounts/claude/b"
        for path in [profile, other, home + "/.claude"] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","refreshToken":"fixture-refresh","expiresAt":1,"scopes":["user:inference"]},"trustedDeviceToken":"fixture-device"}"#.utf8)
        check(try ClaudeAccountCredentials.validated(payload) == payload, "native fields preserved, expired token remains refreshable")
        for bad in [#"{"claudeAiOauth":{"accessToken":""}}"#, #"{"claudeAiOauth":{"accessToken":"x","expiresAt":true}}"#, #"{"claudeAiOauth":{"accessToken":"x","refreshToken":4}}"#, "sk-ant-fixture"] {
            rejects("invalid credential") { _ = try ClaudeAccountCredentials.validated(Data(bad.utf8)) }
        }

        // Default and managed unattended reads both go through /usr/bin/security so CLI ACLs match.
        let plain = LoginEnvironment.current
        Shell.securityFindResult = ShellResult(status: 0, stdout: payload)
        check(try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false) == payload, "default account reads security output")
        check(Shell.securityArguments.last == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "fixture", "-w"], "default security arguments")
        Shell.securityFindResult = ShellResult(status: 0, stdout: Data(payload.map { String(format: "%02x", $0) }.joined().utf8))
        check(try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false) == payload, "hex output decoded")

        var managedEnv = LoginEnvironment.current
        managedEnv["CLAUDE_CONFIG_DIR"] = profile
        managedEnv["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = profile
        Shell.securityFindResult = ShellResult(status: 0, stdout: payload)
        check(try await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true) == payload, "managed account reads via security tool")
        check(Shell.securityArguments.last?[2].hasPrefix("Claude Code-credentials-") == true, "managed account uses hashed Keychain service")

        managedEnv["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = other
        await rejectsAsync("mismatched selectors rejected") {
            _ = try await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true)
        }
        managedEnv["CLAUDE_CONFIG_DIR"] = other
        Shell.securityFindResult = ShellResult(status: 44)
        check(try await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true) == nil, "missing managed item without file")
        try payload.write(to: URL(fileURLWithPath: other + "/.credentials.json"))
        check(try await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true) == payload, "missing managed item falls back to own file")
        Shell.securityFindResult = ShellResult(status: 51)
        await rejectsAsync("denied Keychain never selects file") {
            _ = try await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true)
        }
        for status: Int32 in [0, 44] {
            Shell.securityFindResult = ShellResult(status: status, timedOut: true)
            await rejectsAsync("timed-out security result never selects file") {
                _ = try await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true)
            }
        }
        Shell.securityFindResult = ShellResult(status: 44)
        var emptySecure = managedEnv
        emptySecure["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = ""
        _ = try await ClaudeAccountCredentials.readUnattended(environment: emptySecure, isManaged: false)
        check(Shell.securityArguments.last?[2] == "Claude Code-credentials", "empty secure selector wins for default")
        let link = home + "/accounts/claude/link"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: profile)
        await rejectsAsync("symlink profile rejected") {
            try await ClaudeAccountCredentials.remove(configDirectory: link)
        }
        await rejectsAsync("outside managed root rejected") {
            try await ClaudeAccountCredentials.remove(configDirectory: home + "/.claude")
        }

        // Remove uses /usr/bin/security first, then falls back to legacy Keychain delete for old Tivano items.
        Shell.securityDeleteResult = ShellResult(status: 0)
        let deleteBefore = FixtureKeychain.deleteCalls
        try await ClaudeAccountCredentials.remove(configDirectory: other)
        check(!fm.fileExists(atPath: other + "/.credentials.json"), "remove deletes .credentials.json")
        check(Shell.securityArguments.last?.first == "delete-generic-password", "remove tries security tool first")
        check(FixtureKeychain.deleteCalls == deleteBefore, "successful security delete skips legacy Keychain delete")

        Shell.securityDeleteResult = ShellResult(status: 51)
        FixtureKeychain.deleteDenied = false
        try await ClaudeAccountCredentials.remove(configDirectory: profile)
        check(FixtureKeychain.deleteCalls == deleteBefore + 1, "denied security delete falls back to legacy Keychain delete")

        FixtureKeychain.deleteDenied = true
        await rejectsAsync("both security and legacy Keychain delete denied surfaces error") {
            try await ClaudeAccountCredentials.remove(configDirectory: profile)
        }
        FixtureKeychain.deleteDenied = false
        Shell.securityDeleteResult = ShellResult(status: 0)

        // Legacy account decoding compatibility.
        let identity = ClaudeAccountIdentity(accountID: "a", organizationID: "o", email: "one@example.test")
        check(!identity.matches(.init(accountID: "a", organizationID: "other", email: identity.email)), "organization matters")
        let oldAccount = Data(#"{"id":"00000000-0000-0000-0000-000000000001","provider":"codex","addedAt":0}"#.utf8)
        let decodedOld = try JSONDecoder().decode(ProviderAccount.self, from: oldAccount)
        check(decodedOld.claudeIdentity == nil && decodedOld.organizationID == nil && !decodedOld.requiresClaudeActivation && !decodedOld.requiresClaudeCleanup, "old account decoding")

        // Native addAccount runs `claude auth login` directly in the account's own CLAUDE_CONFIG_DIR.
        let registry = ProviderRegistry()
        let accounts = ProviderAccounts(registry: registry)
        Shell.cliCommands.removeAll()
        ProviderRegistry.loginIdentity = ClaudeAccountIdentity(accountID: "acct-1", organizationID: "org-1", email: "one@example.test")
        let addError = await accounts.addAccount(.claude)
        check(addError == nil, "native addAccount succeeds")
        let saved = accounts.accounts(for: .claude).first { !$0.isDefault }!
        check(!saved.requiresClaudeActivation && !saved.requiresClaudeCleanup, "added account is immediately ready")
        check(saved.email == "one@example.test" && saved.organizationName == "Fixture Org", "metadata recorded from CLI")
        check(Shell.cliCommands.count == 1 && Shell.cliCommands[0].arguments == ["auth", "login"] && Shell.cliCommands[0].configDir == saved.home,
              "addAccount runs login directly in target CLAUDE_CONFIG_DIR without temporary credential copy")

        // Adding the same account+org again is rejected and cleaned up automatically.
        Shell.cliCommands.removeAll()
        let dupError = await accounts.addAccount(.claude)
        check(dupError != nil, "duplicate Claude account is rejected")
        check(accounts.accounts(for: .claude).filter { !$0.isDefault }.count == 1, "duplicate staging account cleaned up")
        check(Shell.cliCommands.map(\.arguments) == [["auth", "login"], ["auth", "logout"]], "duplicate cleanup runs official auth logout")

        // Re-sign-in with wrong account refuses and locks the profile until original account signs back in.
        ProviderRegistry.loginIdentity = ClaudeAccountIdentity(accountID: "acct-other", organizationID: "org-other", email: "other@example.test")
        let mismatch = await accounts.signIn(accounts.account(id: saved.id)!)
        check(mismatch != nil && accounts.account(id: saved.id)!.requiresClaudeCleanup, "wrong-account login locks profile")
        ProviderRegistry.loginIdentity = ClaudeAccountIdentity(accountID: "acct-1", organizationID: "org-1", email: "one@example.test")
        let recovered = await accounts.signIn(accounts.account(id: saved.id)!)
        check(recovered == nil && !accounts.account(id: saved.id)!.requiresClaudeCleanup, "re-signing with original account recovers profile")

        // Coalescing and serialization of usage reads.
        let beforeCoalescing = PlanLimitsReader.reads
        async let left = accounts.refreshClaudeAccount(saved.id, force: true)
        async let right = accounts.refreshClaudeAccount(saved.id, force: true)
        let pair = await (left, right)
        check(pair.0 == pair.1 && PlanLimitsReader.reads == beforeCoalescing + 1, "concurrent readers share one request")

        let otherReader = ProviderAccounts(registry: registry)
        let defaultID = otherReader.accounts(for: .claude).first { $0.isDefault }!.id
        PlanLimitsReader.peak = 0
        let previousReads = PlanLimitsReader.reads
        async let accountRead = otherReader.refreshClaudeAccount(saved.id)
        async let defaultRead = otherReader.refreshClaudeAccount(defaultID)
        _ = await (accountRead, defaultRead)
        check(PlanLimitsReader.peak == 1 && PlanLimitsReader.reads == previousReads + 2, "different account reads are serialized")

        // Removal waits for an in-flight usage check rather than failing with busy.
        let waitingAccounts = ProviderAccounts(registry: registry)
        PlanLimitsReader.delayNanoseconds = 60_000_000
        let slowRead = Task { await waitingAccounts.refreshClaudeAccount(saved.id, force: true) }
        try await Task.sleep(nanoseconds: 10_000_000)
        Shell.cliCommands.removeAll()
        Shell.securityDeleteResult = ShellResult(status: 51)
        FixtureKeychain.deleteDenied = true
        let removeFailure = await waitingAccounts.remove(saved)
        _ = await slowRead.value
        PlanLimitsReader.delayNanoseconds = 0
        check(removeFailure != nil && waitingAccounts.account(id: saved.id)!.requiresClaudeCleanup, "cleanup failure retains retryable record")
        check(Shell.cliCommands.last?.arguments == ["auth", "logout"], "remove calls official claude auth logout")

        // Force-remove escape hatch removes stuck record even when Keychain denies deletion.
        let forced = await waitingAccounts.remove(saved, forceRemoveLocal: true)
        check(forced == nil && waitingAccounts.account(id: saved.id) == nil, "forceRemoveLocal unblocks stuck account")
        check(ProviderRegistry.forgotten.contains(saved.id), "cleanup forgets cached identity")

        // Re-add and test normal removal + post-delete save retry.
        let freshAccounts = ProviderAccounts(registry: registry)
        Shell.securityDeleteResult = ShellResult(status: 0)
        FixtureKeychain.deleteDenied = false
        check(await freshAccounts.addAccount(.claude) == nil, "re-add after removal succeeds")
        let saved2 = freshAccounts.accounts(for: .claude).first { !$0.isDefault }!
        ProviderAccountStore.failOnSave = ProviderAccountStore.saveCalls + 2
        let persistFailure = await freshAccounts.remove(saved2)
        check(persistFailure != nil && freshAccounts.account(id: saved2.id)!.requiresClaudeCleanup, "post-delete persistence failure remains retryable")
        ProviderAccountStore.failOnSave = nil
        let retried = await freshAccounts.remove(saved2)
        check(retried == nil && freshAccounts.account(id: saved2.id) == nil, "cleanup retry succeeds when directory already gone")

        // Codex removal saves before signing out.
        let codexID = UUID()
        let codexHome = try ProviderAccountStore.makeHome(provider: .codex, id: codexID, linkingFrom: "")
        let codexAccount = ProviderAccount(id: codexID, provider: .codex, home: codexHome,
            name: nil, email: nil, plan: nil, accountID: nil, addedAt: .now)
        ProviderAccountStore.stored.accounts.append(codexAccount)
        let codexAccounts = ProviderAccounts(registry: registry)
        let callsBeforeRemoval = Shell.calls
        ProviderAccountStore.failOnSave = ProviderAccountStore.saveCalls + 1
        _ = await codexAccounts.remove(codexAccount)
        check(codexAccounts.account(id: codexID) != nil && fm.fileExists(atPath: codexHome)
            && Shell.calls == callsBeforeRemoval, "failed Codex save preserves login and directory")
        ProviderAccountStore.failOnSave = nil
        _ = await codexAccounts.remove(codexAccount)
        check(codexAccounts.account(id: codexID) == nil && !fm.fileExists(atPath: codexHome)
            && Shell.calls == callsBeforeRemoval + 1, "Codex logout only follows saved removal")

        // Capture mode never touches credentials or CLI.
        let callsBeforeCapture = Shell.calls
        let secBeforeCapture = Shell.securityArguments.count
        CaptureRun.isEnabled = true
        _ = await freshAccounts.addAccount(.claude)
        _ = await freshAccounts.signIn(saved2)
        _ = await freshAccounts.remove(saved2)
        _ = await freshAccounts.refreshClaudeAccount(saved2.id)
        check(Shell.calls == callsBeforeCapture && Shell.securityArguments.count == secBeforeCapture, "capture entry points never touch credentials or CLI")
        await rejectsAsync("captures cannot read credentials") {
            _ = try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false)
        }

        // The production seed, stale-seed rule and reload predicate, sliced from ProviderRegistry.swift.
        let seedIDs = ProviderRegistry.claudeSeed.map(\.id)
        check(seedIDs.contains("claude-fable-5-2[1m]") && seedIDs.contains("claude-fable-5-1[1m]"), "Claude seed offers Fable 5.2 and keeps the 5.1 id")
        let previousSeed = ["default", "opus", "claude-fable-5-1[1m]", "sonnet", "haiku"].map { ModelOption(id: $0, name: $0) }
        check(ProviderRegistry.isStaleClaudeSeed(previousSeed) && ProviderRegistry.isStaleClaudeSeed([]), "a cached previous seed is re-seeded")
        check(!ProviderRegistry.isStaleClaudeSeed(previousSeed + [ModelOption(id: "opus[1m]", name: "Opus 1M")]), "a live Claude list is kept")
        let catalogRegistry = ProviderRegistry()
        check(!catalogRegistry.catalogReloaded(.claude, since: nil), "an empty Claude list is not reloaded")
        catalogRegistry.catalogs[.claude] = ProviderRegistry.claudeSeed
        check(catalogRegistry.catalogFetchedAt[.claude] == nil && catalogRegistry.catalogReloaded(.claude, since: nil), "a seeded Claude list counts as reloaded without a fetch date")
        catalogRegistry.catalogs[.codex] = [ModelOption(id: "fixture", name: "Fixture")]
        check(!catalogRegistry.catalogReloaded(.codex, since: nil), "another provider needs a new fetch date")
        let stamp = Date()
        catalogRegistry.catalogFetchedAt[.codex] = stamp
        check(catalogRegistry.catalogReloaded(.codex, since: nil) && !catalogRegistry.catalogReloaded(.codex, since: stamp), "another provider reloads only when its fetch date changed")
        catalogRegistry.catalogs[.codex] = []
        check(!catalogRegistry.catalogReloaded(.codex, since: nil), "an empty list is never reloaded")
        print("Claude account checks passed: native CLI login/logout, security-tool reads, legacy Keychain delete fallback, duplicate rejection, wrong-account lock/recovery, removal wait and force-remove escape hatch, and catalog seed rules; synthetic data only.")
    }
}
'''


def main():
    if sys.flags.optimize:
        raise SystemExit("run without -O or PYTHONOPTIMIZE; fixture assertions must remain enabled")
    credential = (ROOT / "Tivano/Services/Providers/ClaudeAccountCredentials.swift").read_text()
    for forbidden in ("SecItemAdd(", "SecItemUpdate(", "SecItemCopyMatching("):
        if forbidden in credential:
            raise SystemExit(f"Compliance guard: {forbidden} must not exist in ClaudeAccountCredentials.swift; official Claude CLI owns credential writes and reads")
    if credential.count("SecItemDelete(") == 0:
        raise SystemExit("Security boundary changed: no 'SecItemDelete(' call to replace; refusing to run against the real Keychain")
    credential = credential.replace("SecItemDelete(", "FixtureKeychain.delete(")
    if (ROOT / "Tivano/Services/Providers/ClaudeSwapImport.swift").exists():
        raise SystemExit("ClaudeSwapImport.swift must remain removed")
    registry = (ROOT / "Tivano/Services/Providers/ProviderRegistry.swift").read_text()
    start = registry.index("    private static func claudeAccountAllowsProbe(")
    end = registry.index("\n    static func auth(", start)
    probe = registry[start:end].replace("private static", "static")
    # Catalog rules are sliced the same way, and a marker that stops matching fails loudly. The real
    # registry needs most of the provider layer, so only these members run against the shim's storage.
    def piece(text, start, end, name):
        if text.count(start) != 1 or text.count(end) != 1:
            raise SystemExit(f"{name} markers changed; update scripts/claude_accounts_checks.py")
        first = text.index(start)
        last = text.index(end)
        if last <= first:
            raise SystemExit(f"{name} markers are out of order; update scripts/claude_accounts_checks.py")
        return text[first:last]
    seed = piece(registry, "    private static let claudeEfforts", "\n\n    /// The seed with a live Claude list laid over it", "Claude seed")
    stale = piece(registry, "    private static func isStaleClaudeSeed(", "\n\n    // Seeds come from the same tables", "stale Claude seed rule")
    reload = piece(registry, "    func models(for provider: ProviderKind) -> [ModelOption] {", "\n    func sortedModels(", "catalog reload rule")
    for required in ("claude-fable-5-2[1m]", "claude-fable-5-1[1m]"):
        if required not in seed:
            raise SystemExit(f"Claude seed no longer names {required}; update scripts/claude_accounts_checks.py")
    if "func catalogReloaded(" not in reload:
        raise SystemExit("catalogReloaded moved out of the extracted slice; update scripts/claude_accounts_checks.py")
    catalog = "\nextension ProviderRegistry {\n" + "\n\n".join(
        part.replace("private static", "static") for part in (seed, stale)) + "\n\n" + reload + "\n}\n"
    models = (ROOT / "Tivano/Core/Models/Provider.swift").read_text()
    option = piece(models, "struct ModelOption: Codable", "\nextension Array where Element == ModelOption {", "ModelOption")
    variant = piece(models, "struct ModelVariant: Codable", "\nstruct SlashCommand: Hashable", "ModelVariant")
    source = "\nextension ProviderRegistry {\n" + probe + "\n}\n" + option + variant + catalog + credential
    source += (ROOT / "Tivano/Core/Models/ProviderAccount.swift").read_text()
    source += (ROOT / "Tivano/Services/Providers/ProviderAccounts.swift").read_text() + CHECKS
    # Scan before prepending SHIMS so fake definitions are excluded, not production
    # fragments. API names have a suffix; the bare SecItem in SecItem.h is not an API.
    remaining = sorted(set(re.findall(r'\b(?:SecItem|SecKeychain|SecAccess)\w+\b', source)))
    if remaining:
        raise SystemExit(f"Security boundary changed: real Keychain identifiers remain: {', '.join(remaining)}; refusing to run")
    source = SHIMS + source
    with tempfile.TemporaryDirectory(prefix="tivano-claude-checks-") as temp:
        directory = Path(temp).resolve()
        swift = directory / "Checks.swift"
        swift.write_text(source)
        binary = directory / "checks"
        # Match the app target's approachable concurrency: nonisolated async runs on its caller.
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                        str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(directory)], check=True,
                       env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(directory)})


if __name__ == "__main__":
    main()
