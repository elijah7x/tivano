#!/usr/bin/env python3
"""Exercise production Claude credential/import code with synthetic files and Keychain.

Never reads the real login environment, Keychain, or CSWAP directory, starts a
provider, or makes a network request. Security calls and account-service dependencies in the generated copy
are replaced; credential parsing and ProviderAccounts transaction logic are unchanged.
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
    static var failMetadata = false
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
    static func makeHome(provider: ProviderKind, id: UUID, linkingFrom: String) throws -> String {
        let path = accountsRoot + "/" + provider.rawValue + "/" + id.uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
    static func removeHome(_ home: String) { try? removeHomeThrowing(home) }
    static func removeHomeThrowing(_ home: String) throws {
        if FileManager.default.fileExists(atPath: home) { try FileManager.default.removeItem(atPath: home) }
    }
    static func writeClaudeIdentity(_ candidate: ClaudeSwapImportCandidate, into home: String) throws {
        try replaceClaudeMetadata(Data("{}".utf8), home: home)
    }
    static func replaceClaudeMetadata(_ data: Data?, home: String) throws {
        if failMetadata { throw CocoaError(.fileWriteUnknown) }
        let url = URL(fileURLWithPath: home + "/.claude.json")
        if let data { try data.write(to: url) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    static func codexIdentity(home: String) -> CodexIdentity? { nil }
    static func codexImportCandidates(defaultHome: String) -> [CodexImportCandidate] { [] }
    static func importCodexCredential(_ candidate: CodexImportCandidate, into home: String) throws {}
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
    static var result = PlanLimits(problem: "fixture unavailable")
    static func read(_ provider: ProviderKind, executable: URL, environment: [String: String]) async -> PlanLimits? {
        reads += 1
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
        return result
    }
    static func failure(_ message: String) -> PlanLimits { PlanLimits(problem: message) }
}
@MainActor final class ProviderRegistry {
    static var forgotten: [UUID] = []
    static func forgetClaudeIdentity(_ accountID: UUID) { forgotten.append(accountID) }
    static var authCalls = 0
    static var loginIdentity = ClaudeAccountIdentity(accountID: "new-account", organizationID: "org", email: "new@example.test")
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
    static var securityResult = ShellResult(status: 44)
    static var securityArguments: [[String]] = []
    static var calls = 0
    static func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil, environment: [String: String], timeout: Double) async throws -> ShellResult {
        if executable.path == "/usr/bin/security" {
            securityArguments.append(arguments)
            return securityResult
        }
        calls += 1
        if let home = environment["CLAUDE_CONFIG_DIR"] {
            try ClaudeAccountCredentials.write(Data(#"{"claudeAiOauth":{"accessToken":"new-fixture","refreshToken":"new-refresh"}}"#.utf8), configDirectory: home)
        }
        return ShellResult()
    }
}
enum FixtureKeychain {
    static var addGate: DispatchSemaphore?
    static var copyGate: DispatchSemaphore?
    static var addWaiting = false
    static var copyWaiting = false
    static var items: [String: Data] = [:]
    static var reads = 0
    static var denied = false
    static var deleteDenied = false
    static var lastService = ""
    static func key(_ query: CFDictionary) -> String {
        let q = query as NSDictionary
        return (q[kSecAttrService] as! String) + ":" + (q[kSecAttrAccount] as! String)
    }
    static func copy(_ query: CFDictionary, _ value: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        reads += 1
        if let gate = copyGate {
            copyWaiting = true
            gate.wait()
        }
        lastService = (query as NSDictionary)[kSecAttrService] as! String
        if denied { return errSecAuthFailed }
        guard let data = items[key(query)] else { return errSecItemNotFound }
        value?.pointee = data as CFData
        return errSecSuccess
    }
    static func update(_ query: CFDictionary, _ values: CFDictionary) -> OSStatus {
        guard items[key(query)] != nil else { return errSecItemNotFound }
        items[key(query)] = (values as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
    }
    static func add(_ query: CFDictionary, _ value: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        if let gate = addGate {
            addWaiting = true
            gate.wait()
        }
        items[key(query)] = (query as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
    }
    static func delete(_ query: CFDictionary) -> OSStatus {
        if deleteDenied { return errSecAuthFailed }
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
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
        for path in [profile, other, home + "/.claude", home + "/.claude-swap-backup/credentials"] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","refreshToken":"fixture-refresh","expiresAt":1,"scopes":["user:inference"]},"trustedDeviceToken":"fixture-device"}"#.utf8)
        check(try ClaudeAccountCredentials.validated(payload) == payload, "native fields preserved, expired token remains refreshable")
        for bad in [#"{"claudeAiOauth":{"accessToken":""}}"#, #"{"claudeAiOauth":{"accessToken":"x","expiresAt":true}}"#, #"{"claudeAiOauth":{"accessToken":"x","refreshToken":4}}"#, "sk-ant-fixture"] {
            rejects("invalid credential") { _ = try ClaudeAccountCredentials.validated(Data(bad.utf8)) }
        }
        try ClaudeAccountCredentials.write(payload, configDirectory: profile)
        var env = LoginEnvironment.current
        env["CLAUDE_CONFIG_DIR"] = profile
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = profile
        check(try ClaudeAccountCredentials.read(environment: env, isManaged: true) == payload, "managed roundtrip")
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = other
        rejects("mismatched selectors") { _ = try ClaudeAccountCredentials.read(environment: env, isManaged: true) }
        env["CLAUDE_CONFIG_DIR"] = other
        check(try ClaudeAccountCredentials.read(environment: env, isManaged: true) == nil, "no fallback to another account")
        try payload.write(to: URL(fileURLWithPath: other + "/.credentials.json"))
        FixtureKeychain.denied = true
        rejects("denied Keychain cannot fall back to file") { _ = try ClaudeAccountCredentials.read(environment: env, isManaged: true) }
        FixtureKeychain.denied = false
        check(try ClaudeAccountCredentials.read(environment: env, isManaged: true) == payload, "missing Keychain permits own file")
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = ""
        _ = try ClaudeAccountCredentials.read(environment: env, isManaged: false)
        check(FixtureKeychain.lastService == "Claude Code-credentials", "empty secure selector wins")
        env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        _ = try ClaudeAccountCredentials.read(environment: env, isManaged: false)
        check(FixtureKeychain.lastService.hasPrefix("Claude Code-credentials-"), "custom default remains readable")
        rejects("outside managed root") { try ClaudeAccountCredentials.write(payload, configDirectory: home + "/.claude") }
        let link = home + "/accounts/claude/link"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: profile)
        rejects("symlink profile") { try ClaudeAccountCredentials.write(payload, configDirectory: link) }
        let indexURL = URL(fileURLWithPath: home + "/.claude-swap-backup/sequence.json")
        let index = Data(#"{"sequence":[2,1],"accounts":{"1":{"email":"one@example.test","uuid":"one","organizationUuid":"org"},"2":{"email":"two@example.test","uuid":"two","organizationUuid":"org"}}}"#.utf8)
        try index.write(to: indexURL)
        let reads = FixtureKeychain.reads
        let candidates = try ClaudeSwapImport.candidates()
        check(candidates.map(\.slot) == ["2", "1"], "index order")
        check(FixtureKeychain.reads == reads, "preview never reads credentials")
        let selected = candidates[0]
        let encodedURL = URL(fileURLWithPath: home + "/.claude-swap-backup/credentials/.creds-2-two@example.test.enc")
        try Data(payload.base64EncodedString().utf8).write(to: encodedURL)
        check(try ClaudeSwapImport.credential(for: selected) == ClaudeAccountCredentials.sanitizedImport(payload), "CSWAP import")
        check(try Data(contentsOf: indexURL) == index, "source index unchanged")
        try Data().write(to: encodedURL)
        rejects("empty backup") { _ = try ClaudeSwapImport.credential(for: selected) }
        check(FixtureKeychain.reads == reads, "empty backup never falls back")
        try Data(String(decoding: index, as: UTF8.self).replacingOccurrences(of: "two@example.test", with: "new@example.test").utf8).write(to: indexURL)
        rejects("stale candidate") { _ = try ClaudeSwapImport.credential(for: selected) }
        try Data(#"{"sequence":[1],"accounts":{"1":{"email":"../escape"}}}"#.utf8).write(to: indexURL)
        rejects("index path traversal") { _ = try ClaudeSwapImport.candidates() }
        try ClaudeAccountCredentials.remove(configDirectory: profile)
        check(FixtureKeychain.items.isEmpty, "local remove")
        let identity = ClaudeAccountIdentity(accountID: "a", organizationID: "o", email: "one@example.test")
        check(!identity.matches(.init(accountID: "a", organizationID: "other", email: identity.email)), "organization matters")
        let oldAccount = Data(#"{"id":"00000000-0000-0000-0000-000000000001","provider":"codex","addedAt":0}"#.utf8)
        let account = try JSONDecoder().decode(ProviderAccount.self, from: oldAccount)
        check(account.claudeIdentity == nil && account.organizationID == nil, "old account decoding")
        let extended = Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","clientId":"fixture-client","refreshTokenExpiresAt":9},"trustedDeviceToken":"fixture-device","mcpOAuth":{"secret":"fixture-mcp"},"designOauth":{"refreshToken":"fixture-design"},"cloudSessionsOauth":{"refreshToken":"fixture-cloud"}}"#.utf8)
        let sanitized = try ClaudeAccountCredentials.sanitizedImport(extended)
        let clean = try JSONSerialization.jsonObject(with: sanitized) as! [String: Any]
        check(Set(clean.keys) == ["claudeAiOauth", "trustedDeviceToken"], "only login grants cross profiles")
        check((clean["claudeAiOauth"] as? [String: Any])?["clientId"] as? String == "fixture-client", "OAuth client retained")
        check(try ClaudeAccountCredentials.validated(extended) == extended, "native storage preserves unrelated fields")
        try ClaudeAccountCredentials.write(extended, configDirectory: profile)
        let before = try ClaudeAccountCredentials.snapshot(configDirectory: profile)
        try ClaudeAccountCredentials.restore(.init(keychain: sanitized, file: nil), configDirectory: profile)
        try ClaudeAccountCredentials.restore(before, configDirectory: profile)
        check(try ClaudeAccountCredentials.read(configDirectory: profile, isDefault: false) == extended, "rollback restores full native data")
        FixtureKeychain.deleteDenied = true
        rejects("cleanup denial surfaces") { try ClaudeAccountCredentials.remove(configDirectory: profile) }
        check(try ClaudeAccountCredentials.read(configDirectory: profile, isDefault: false) == extended, "failed cleanup retains Keychain")
        FixtureKeychain.deleteDenied = false
        try ClaudeAccountCredentials.remove(configDirectory: profile)
        check(!account.requiresClaudeActivation && !account.requiresClaudeCleanup, "legacy nil flags remain compatible")
        var pending = ProviderAccount(id: UUID(), provider: .claude, home: profile, name: nil, email: nil, plan: nil, accountID: nil, addedAt: .now)
        pending.claudeImportPending = true
        pending.claudeCleanupRequired = true
        let roundtrip = try JSONDecoder().decode(ProviderAccount.self, from: JSONEncoder().encode(pending))
        check(roundtrip.requiresClaudeActivation && roundtrip.requiresClaudeCleanup, "pending and cleanup survive restart")
        try index.write(to: indexURL)
        try Data(payload.base64EncodedString().utf8).write(to: encodedURL)
        let onMain = try await ClaudeAccountCredentials.offMain { Thread.isMainThread }
        check(!onMain, "credential work leaves the main thread")
        let plain = LoginEnvironment.current
        Shell.securityResult = ShellResult(status: 0, stdout: payload)
        let k = FixtureKeychain.reads
        let defaultReadFromSecurity = try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false)
        check(defaultReadFromSecurity == payload, "default account reads security output")
        check(FixtureKeychain.reads == k, "default account never reads Keychain in-process")
        check(Shell.securityArguments.last == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "fixture", "-w"], "default security arguments")
        Shell.securityResult = ShellResult(status: 0, stdout: Data(payload.map { String(format: "%02x", $0) }.joined().utf8))
        check(try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false) == payload, "hex output decoded")
        Shell.securityResult = ShellResult(status: 44)
        check(try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false) == nil, "missing item without file")
        let defaultCredentialURL = URL(fileURLWithPath: home + "/.claude/.credentials.json")
        try payload.write(to: defaultCredentialURL)
        check(try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false) == payload, "missing item falls back to file")
        Shell.securityResult = ShellResult(status: 51)
        await rejectsAsync("denied Keychain never selects file") {
            _ = try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false)
        }
        for status: Int32 in [0, 44] {
            Shell.securityResult = ShellResult(status: status, timedOut: true)
            await rejectsAsync("timed-out security result never selects file") {
                _ = try await ClaudeAccountCredentials.readUnattended(environment: plain, isManaged: false)
            }
        }
        Shell.securityResult = ShellResult(status: 44)
        try fm.removeItem(at: defaultCredentialURL)
        try ClaudeAccountCredentials.write(payload, configDirectory: profile)
        var managedEnv = LoginEnvironment.current
        managedEnv["CLAUDE_CONFIG_DIR"] = profile
        managedEnv["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = profile
        let copyGate = DispatchSemaphore(value: 0)
        FixtureKeychain.copyGate = copyGate
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let started = Date()
        await rejectsAsync("blocked managed read times out") {
            _ = try await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true, timeout: 0.3)
        }
        check(Date().timeIntervalSince(started) < 3, "stuck prompt times out")
        // The Keychain read is still blocked here; give the main-actor ticker up to 3 s to
        // show it keeps running, instead of relying on the 0.3 s timeout window on a busy host.
        let tickDeadline = Date().addingTimeInterval(3)
        while ticks <= 2 && FixtureKeychain.copyWaiting && Date() < tickDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check(ticks > 2, "main actor keeps running while Keychain waits")
        check(FixtureKeychain.copyWaiting, "managed read reached blocked Keychain")
        let stuckReads = FixtureKeychain.reads
        let retryStarted = Date()
        await rejectsAsync("second unattended read fails while one is stuck") {
            _ = try await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true, timeout: 5)
        }
        check(Date().timeIntervalSince(retryStarted) < 1 && FixtureKeychain.reads == stuckReads, "stuck read makes later unattended reads fail fast")
        let serial = try await ClaudeAccountCredentials.offMain { 7 }
        check(serial == 7, "interactive credential work is not held by a stuck unattended read")
        FixtureKeychain.copyGate = nil
        copyGate.signal()
        var released = false
        for _ in 0..<60 where !released {
            released = (try? await ClaudeAccountCredentials.readUnattended(environment: managedEnv, isManaged: true, timeout: 1)) == payload
            if !released { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        check(released, "unattended slot frees once the prompt is answered")
        FixtureKeychain.copyWaiting = false
        ticker.cancel()
        try ClaudeAccountCredentials.remove(configDirectory: profile)
        check(FixtureKeychain.items.isEmpty, "credential checks leave import storage empty")
        let registry = ProviderRegistry()
        let accounts = ProviderAccounts(registry: registry)
        let initialSelection = accounts.activeAccount(for: .claude)?.id
        let imported = await accounts.importClaudeAccounts([selected])
        check(imported.first?.contains("awaiting activation") == true, "saved does not claim verified")
        let saved = accounts.accounts(for: .claude).first { !$0.isDefault }!
        check(saved.requiresClaudeActivation && !saved.requiresClaudeCleanup, "import remains pending")
        check(Shell.calls == 0 && ProviderRegistry.authCalls == 0 && PlanLimitsReader.reads == 0, "import starts no provider or quota requests")
        check(!ProviderAccounts.canStartProcess(saved.id), "pending cannot start a process")
        accounts.use(saved)
        check(accounts.activeAccount(for: .claude)?.id == initialSelection, "pending cannot be selected")
        let pendingRead = await accounts.refreshClaudeAccount(saved.id)
        check(pendingRead == nil && PlanLimitsReader.reads == 0, "pending never reads quota")
        ProviderAccountStore.failOnSave = ProviderAccountStore.saveCalls + 1
        let activationFailure = await accounts.activateClaudeAccount(saved)
        check(activationFailure != nil && accounts.account(id: saved.id)!.requiresClaudeActivation, "failed activation remains pending")
        check(accounts.activeAccount(for: .claude)?.id == initialSelection, "failed activation preserves selection")
        ProviderAccountStore.failOnSave = nil
        let activated = await accounts.activateClaudeAccount(saved)
        check(activated == nil && accounts.activeAccount(for: .claude)?.id == saved.id, "activation commits selection")
        let firstRead = PlanLimitsReader.reads
        _ = await accounts.refreshClaudeAccount(saved.id, force: true)
        check(PlanLimitsReader.reads == firstRead, "failure cached even under force")
        check(accounts.states[saved.id]?.auth == .unknown, "quota read does not claim verified identity")
        let originalLogin = try ClaudeAccountCredentials.read(configDirectory: saved.home!, isDefault: false)
        let mismatch = await accounts.signIn(accounts.account(id: saved.id)!)
        check(mismatch != nil, "wrong-account login refused")
        check(try ClaudeAccountCredentials.read(configDirectory: saved.home!, isDefault: false) == originalLogin, "wrong-account login leaves original bytes unchanged")
        check(accounts.accounts(for: .claude).filter { !$0.isDefault }.count == 1, "temporary profile cleaned locally")
        ProviderRegistry.loginIdentity = ClaudeAccountIdentity(accountID: saved.accountID!, organizationID: saved.organizationID!, email: saved.email!)
        ProviderAccountStore.failOnSave = ProviderAccountStore.saveCalls + 3
        let failedCommit = await accounts.signIn(accounts.account(id: saved.id)!)
        check(failedCommit != nil, "login commit failure surfaces")
        check(try ClaudeAccountCredentials.read(configDirectory: saved.home!, isDefault: false) == originalLogin, "failed login commit restores old credential")
        check(!accounts.account(id: saved.id)!.requiresClaudeCleanup, "successful rollback restores original flags")
        ProviderAccountStore.failOnSave = nil
        let loggedIn = await accounts.signIn(accounts.account(id: saved.id)!)
        check(loggedIn == nil, "verified managed login commits")
        let persisted = ProviderAccountStore.stored
        var interrupted = persisted
        let savedIndex = interrupted.accounts.firstIndex { $0.id == saved.id }!
        interrupted.accounts[savedIndex].claudeCleanupRequired = true
        ProviderAccountStore.stored = interrupted
        let recovering = ProviderAccounts(registry: registry)
        let repaired = await recovering.signIn(recovering.account(id: saved.id)!)
        check(repaired == nil && !recovering.account(id: saved.id)!.requiresClaudeCleanup, "interrupted replacement can recover without deleting bound chats")
        ProviderAccountStore.stored = persisted
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
        FixtureKeychain.deleteDenied = true
        let removeFailure = await accounts.remove(saved, hasDependentChats: false)
        check(removeFailure != nil && accounts.account(id: saved.id)!.requiresClaudeCleanup, "cleanup failure retains retryable record")
        check(fm.fileExists(atPath: saved.home!), "cleanup failure retains profile directory")
        FixtureKeychain.deleteDenied = false
        ProviderAccountStore.failOnSave = ProviderAccountStore.saveCalls + 2
        let persistFailure = await accounts.remove(saved, hasDependentChats: false)
        check(persistFailure != nil && accounts.account(id: saved.id)!.requiresClaudeCleanup, "post-delete persistence failure remains retryable")
        ProviderAccountStore.failOnSave = nil
        let retried = await accounts.remove(saved, hasDependentChats: false)
        check(retried == nil && accounts.account(id: saved.id) == nil, "cleanup retry tolerates absent local files: " + (retried ?? "record remains"))
        check(ProviderRegistry.forgotten.contains(saved.id), "sign-in and cleanup forget cached identity")
        ProviderAccountStore.failMetadata = true
        FixtureKeychain.deleteDenied = true
        _ = await accounts.importClaudeAccounts([selected])
        let residue = accounts.accounts(for: .claude).first { !$0.isDefault }!
        check(residue.requiresClaudeCleanup && fm.fileExists(atPath: residue.home!), "failed import cannot hide credential residue")
        ProviderAccountStore.failMetadata = false
        FixtureKeychain.deleteDenied = false
        _ = await accounts.remove(residue, hasDependentChats: false)
        FixtureKeychain.addGate = DispatchSemaphore(value: 0)
        let gate = FixtureKeychain.addGate!
        let importTask = Task { await accounts.importClaudeAccounts([selected]) }
        let importDeadline = Date().addingTimeInterval(3)
        while !FixtureKeychain.addWaiting {
            if Date() >= importDeadline { fatalError("Import did not reach blocked credential write") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let staged = accounts.accounts(for: .claude).first { !$0.isDefault }!
        let busy = await accounts.remove(staged, hasDependentChats: false)
        check(busy?.contains("busy") == true, "import holds the account while writing")
        FixtureKeychain.addGate = nil
        FixtureKeychain.addWaiting = false
        gate.signal()
        let result = await importTask.value
        check(result.first?.contains("awaiting activation") == true, "import completes after concurrent refusal")
        _ = await accounts.remove(accounts.accounts(for: .claude).first { !$0.isDefault }!, hasDependentChats: false)
        check(!accounts.accounts(for: .claude).contains { !$0.isDefault }, "concurrent import cleanup removes staged account")
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
        let readsBeforeCapture = FixtureKeychain.reads
        let callsBeforeCapture = Shell.calls
        CaptureRun.isEnabled = true
        _ = await accounts.importClaudeAccounts([selected])
        _ = await accounts.addAccount(.claude)
        _ = await accounts.signIn(saved)
        _ = await accounts.remove(saved, hasDependentChats: false)
        _ = await accounts.refreshClaudeAccount(saved.id)
        check(FixtureKeychain.reads == readsBeforeCapture && Shell.calls == callsBeforeCapture, "capture entry points never touch credentials or CLI")
        rejects("captures cannot read credentials") { _ = try ClaudeAccountCredentials.read(environment: env, isManaged: false) }
        print("Claude account checks passed: isolated storage, selectors, permission failures, CSWAP parsing, legacy account decoding, off-main Keychain, security-tool default reads and import exclusivity; synthetic data only.")
    }
}
'''


def main():
    if sys.flags.optimize:
        raise SystemExit("run without -O or PYTHONOPTIMIZE; fixture assertions must remain enabled")
    credential = (ROOT / "Tivano/Services/Providers/ClaudeAccountCredentials.swift").read_text()
    for api, stub in {"SecItemCopyMatching": "copy", "SecItemUpdate": "update",
                      "SecItemAdd": "add", "SecItemDelete": "delete"}.items():
        target = api + "("
        if credential.count(target) == 0:
            raise SystemExit(f"Security boundary changed: no {target!r} calls to replace; refusing to run against the real Keychain")
        credential = credential.replace(target, "FixtureKeychain." + stub + "(")
    registry = (ROOT / "Tivano/Services/Providers/ProviderRegistry.swift").read_text()
    start = registry.index("    private static func claudeAccountAllowsProbe(")
    end = registry.index("\n    static func auth(", start)
    probe = registry[start:end].replace("private static", "static")
    source = "\nextension ProviderRegistry {\n" + probe + "\n}\n" + credential
    source += (ROOT / "Tivano/Services/Providers/ClaudeSwapImport.swift").read_text()
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
