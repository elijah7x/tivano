#!/usr/bin/env python3
"""Lead-only, macOS behavioral checks of extracted runtime-storage Swift code.

Run: python3 scripts/runtime_storage_checks.py

All executables, bundles and data live under a fresh physical temporary directory.
Each case gets a new process and library. No App, watchdog start/sample, installer,
network request, signing tool or user library is run/read. Expected safety failures
are ordinary failing tests, not xfails. The harness aggregates failures by case.

Diagnostics use real CaptureRun routing and the real StoragePaths.root declaration.
Updater application state and signature verification are explicit fixtures: these
checks do NOT validate real signing, Gatekeeper, mounting or installer handoff.
Only access control is changed in extracted code. No cleanup implementation is
copied into the fixture. Source-interface changes must be reconciled, not hidden.
"""
from pathlib import Path
import os
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WATCH = ROOT / "Tivano/Core/Support/HangWatchdog.swift"
UPDATER = ROOT / "Tivano/App/AppUpdater.swift"


def declaration(path, marker):
    source = path.read_text()
    if source.count(marker) != 1:
        raise ValueError(f"Expected one declaration: {path}: {marker}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    # Same extraction convention as runtime_audit_checks.py. Extracted blocks
    # must have balanced braces, including any braces in literals/comments.
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise ValueError(f"Unterminated declaration: {path}: {marker}")
    return source[start:end].replace("private ", "")


def constant(path, marker):
    pattern = re.compile(r"^\s*" + re.escape(marker.rstrip()) + r"\s*(?=[:=])")
    matches = [line for line in path.read_text().splitlines() if pattern.match(line)]
    if len(matches) != 1:
        raise ValueError(f"Expected one constant: {path}: {marker}")
    return matches[0].replace("private ", "") + "\n"


COMMON = r'''
import Foundation
import CoreFoundation
import Darwin
import os

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}
func expectError(_ label: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch let failure as CheckFailure { throw failure }
    catch { return }
    throw CheckFailure("Expected refusal: " + label)
}
@MainActor func expectAsyncError(_ label: String, _ body: @MainActor () async throws -> Void) async throws {
    do { try await body() }
    catch let failure as CheckFailure { throw failure }
    catch { return }
    throw CheckFailure("Expected refusal: " + label)
}
enum Fixture {
    static let root: URL = {
        guard let path = ProcessInfo.processInfo.environment["TIVANO_STORAGE_FIXTURE"],
              path.hasPrefix("/"), path.contains("tivano-storage-checks-") else {
            fatalError("Missing isolated fixture root")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        precondition(url.path == url.resolvingSymlinksInPath().path)
        precondition(FileManager.default.currentDirectoryPath == url.path)
        return url
    }()
    static func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func write(_ url: URL, _ data: Data = Data("fixture".utf8)) throws {
        precondition(url.path.hasPrefix(root.path + "/"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    static func bytes(_ url: URL, _ size: Int64) throws {
        try write(url, Data())
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func age(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }
}
'''


def diagnostic_source():
    swift = COMMON
    for name in ("JSONValue.swift", "ISO8601.swift", "RuntimeStorageUsage.swift", "CaptureRun.swift"):
        swift += (ROOT / "Tivano/Core/Support" / name).read_text() + "\n"
    swift += 'enum AppInfo { static let libraryName = "StorageFixtureOnly" }\n'
    swift += "enum StoragePaths {\n" + declaration(
        ROOT / "Tivano/Core/Support/StoragePaths.swift", "    nonisolated static let root: URL =") + "()\n}\n"
    swift += declaration(WATCH, "final class DiagnosticDirectory {") + "\n"
    swift += "enum HangWatchdog {\n"
    for name in ("keptReports", "reportByteLimit", "reportMaxAge", "reportsLock", "log"):
        swift += constant(WATCH, "private static let " + name)
    for marker in ("    static func measureDiagnostics()", "    static func clearDiagnostics()",
                   "    private static func reportsFolder()", "    private static func completedReports(",
                   "    private static func maintainReports()", "    private static func trimReports("):
        swift += declaration(WATCH, marker) + "\n"
    swift += "}\n"
    swift += declaration(ROOT / "Tivano/Services/Store/DecisionLedger.swift", "actor DecisionLedger {") + "\n"
    swift += "enum Storage {}\n" + (ROOT / "Tivano/Services/Store/Storage+Diagnostics.swift").read_text()
    return swift + DIAGNOSTIC_CHECKS


DIAGNOSTIC_CHECKS = r'''
func report(_ index: Int, size: Int64 = 10, age: TimeInterval = 0) throws -> URL {
    let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
    let name = "hang-" + ISO8601.string(from: date).replacingOccurrences(of: ":", with: "-") + ".txt"
    let url = HangWatchdog.reportsFolder().appendingPathComponent(name)
    try Fixture.bytes(url, size)
    try Fixture.age(url, age)
    return url
}
func reportDirectory() throws -> DiagnosticDirectory {
    guard let result = try DiagnosticDirectory.open(HangWatchdog.reportsFolder(), create: true) else {
        throw CheckFailure("Missing report directory")
    }
    return result
}
func ledgerFile(_ name: String) -> URL { DecisionLedger.directory.appendingPathComponent(name) }

@main struct Checks {
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        _ = Fixture.root
        try require(geteuid() != 0, "Permission fixtures require an unprivileged user")
        try require(CaptureRun.isEnabled && CaptureRun.storageRoot?.path == Fixture.root.appendingPathComponent("capture/storage").path, "Capture routing escaped fixture")
        try require(StoragePaths.root == CaptureRun.storageRoot, "Storage root ignored Capture")
        let test = CommandLine.arguments[1]
        switch test {
        case "diagnostic-accounting":
            let newest = try report(3, size: 13, age: 1)
            let older = try report(2, size: 7, age: 2)
            let unknown = HangWatchdog.reportsFolder().appendingPathComponent("hang-not-a-date.txt")
            let temporary = HangWatchdog.reportsFolder().appendingPathComponent(".hang-in-progress.tmp")
            try Fixture.write(unknown); try Fixture.write(temporary)
            try Fixture.write(ledgerFile("ledger.jsonl"), Data("{}\n".utf8))
            try Fixture.write(ledgerFile("ledger.1.jsonl"), Data("{}\n{}\n".utf8))
            let ledgerUnknown = ledgerFile("recovery.jsonl")
            try Fixture.write(ledgerUnknown)
            let usage = try await Storage.measureDiagnostics()
            try require(usage == RuntimeStorageUsage(totalBytes: 29, cleanableBytes: 13), "Statistics include unknown/current files or omit candidates")
            try await Storage.clearDiagnostics()
            try require(Fixture.exists(newest) && !Fixture.exists(older), "Cleanup did not preserve newest report")
            try require(Fixture.exists(ledgerFile("ledger.jsonl")) && !Fixture.exists(ledgerFile("ledger.1.jsonl")), "Cleanup removed current ledger or retained previous")
            try require([unknown, temporary, ledgerUnknown].allSatisfy(Fixture.exists), "Unknown/in-progress files were removed")
            try require(try await Storage.measureDiagnostics() == RuntimeStorageUsage(totalBytes: 16, cleanableBytes: 0), "Post-cleanup statistics disagree")
        case "report-count":
            var created: [URL] = []
            for i in 0..<14 { created.append(try report(i, age: Double(14 - i) * 60)) }
            let directory = try reportDirectory()
            try HangWatchdog.trimReports(in: directory)
            let files = try HangWatchdog.completedReports(in: directory)
            try require(files.count == HangWatchdog.keptReports, "Count rotation failed")
            try require(Set(files.map(\.name)) == Set(created.suffix(HangWatchdog.keptReports).map(\.lastPathComponent)), "Count rotation retained oldest reports")
        case "report-age":
            let old = try report(1, age: HangWatchdog.reportMaxAge + 60)
            let latest = try report(2, age: 1)
            try HangWatchdog.trimReports(in: reportDirectory())
            try require(!Fixture.exists(old) && Fixture.exists(latest), "Age rotation failed")
        case "report-capacity":
            let old = try report(1, size: HangWatchdog.reportByteLimit / 2 + 1, age: 3)
            let mid = try report(2, size: HangWatchdog.reportByteLimit / 2 + 1, age: 2)
            let latest = try report(3, size: 10, age: 1)
            try HangWatchdog.trimReports(in: reportDirectory())
            try require(!Fixture.exists(old) && Fixture.exists(mid) && Fixture.exists(latest), "Capacity rotation order failed")
        case "report-latest-aged":
            let latest = try report(1, age: HangWatchdog.reportMaxAge + 60)
            try HangWatchdog.trimReports(in: reportDirectory())
            try require(!Fixture.exists(latest), "Automatic retention kept the only report beyond the age limit")
        case "report-latest-oversize":
            let latest = try report(1, size: HangWatchdog.reportByteLimit + 1)
            try HangWatchdog.trimReports(in: reportDirectory())
            try require(!Fixture.exists(latest), "Automatic retention kept an oversized report beyond the byte limit")
        case "ledger-rotation":
            let ledger = DecisionLedger.shared
            await ledger.append(.string("seed"))
            try Fixture.bytes(ledgerFile("ledger.jsonl"), DecisionLedger.fileLimit - 1)
            await ledger.append(.string("next"))
            let before = try await ledger.measureDiagnostics()
            try require(before.cleanableBytes == DecisionLedger.fileLimit - 1, "Ledger did not rotate at byte boundary")
            let current = try Data(contentsOf: ledgerFile("ledger.jsonl"))
            await ledger.append(.string(String(repeating: "x", count: Int(DecisionLedger.fileLimit))))
            try require(try Data(contentsOf: ledgerFile("ledger.jsonl")) == current, "Oversized record modified current ledger")
            try require(try await ledger.measureDiagnostics() == before, "Oversized record rotated/deleted history")
            await ledger.append(.string("after"))
            let lines = try String(contentsOf: ledgerFile("ledger.jsonl"), encoding: .utf8).split(separator: "\n")
            try require(lines.count == 2 && lines.allSatisfy { JSONValue.parse(String($0)) != nil }, "Oversized record left a partial JSONL entry")
        case "ledger-age":
            try Fixture.write(ledgerFile("ledger.jsonl"), Data("{}\n".utf8))
            try Fixture.write(ledgerFile("ledger.1.jsonl"))
            try Fixture.age(ledgerFile("ledger.jsonl"), DecisionLedger.previousMaxAge + 60)
            try Fixture.age(ledgerFile("ledger.1.jsonl"), DecisionLedger.previousMaxAge + 60)
            let ledger = DecisionLedger.shared
            let usage = try await ledger.measureDiagnostics()
            try require(usage == RuntimeStorageUsage(totalBytes: 3), "Age maintenance must expire previous, not current ledger")
        case "ledger-exact-limit":
            // JSON quotes plus newline account for three bytes.
            await DecisionLedger.shared.append(.string(String(repeating: "x", count: Int(DecisionLedger.fileLimit) - 3)))
            try require(try await DecisionLedger.shared.measureDiagnostics() == RuntimeStorageUsage(totalBytes: DecisionLedger.fileLimit), "Exact-limit record was dropped")
        case "partial-failure":
            _ = try report(3, age: 1)
            let removed = try report(2, age: 2)
            try Fixture.write(ledgerFile("ledger.jsonl"), Data("{}\n".utf8))
            let outside = Fixture.root.appendingPathComponent("outside-sentinel")
            try Fixture.write(outside)
            try FileManager.default.createSymbolicLink(at: ledgerFile("ledger.1.jsonl"), withDestinationURL: outside)
            try await expectAsyncError("partial cleanup failure must propagate") { try await Storage.clearDiagnostics() }
            try require(!Fixture.exists(removed), "Fixture did not exercise partial completion")
            try require(try Data(contentsOf: outside) == Data("fixture".utf8), "Partial failure touched link target")
            try require(Fixture.exists(ledgerFile("ledger.jsonl")), "Partial failure removed active ledger")
            try await expectAsyncError("measurement must not turn unreadable ledger into zero") { _ = try await Storage.measureDiagnostics() }
        case "links-and-names":
            let directory = try reportDirectory()
            let outside = Fixture.root.appendingPathComponent("outside-sentinel")
            try Fixture.write(outside)
            let symlink = try report(1, age: 2)
            try FileManager.default.removeItem(at: symlink)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
            let hardlink = try report(2, age: 1)
            try FileManager.default.removeItem(at: hardlink)
            try FileManager.default.linkItem(at: outside, to: hardlink)
            try require(try HangWatchdog.measureDiagnostics() == RuntimeStorageUsage(), "Diagnostic statistics included linked bytes")
            try HangWatchdog.clearDiagnostics()
            try require(Fixture.exists(symlink) && Fixture.exists(hardlink), "Linked diagnostic entries were removed")
            try expectError("symlink append") { try directory.append(symlink.lastPathComponent, data: Data("bad".utf8), limit: 100) }
            try expectError("hardlink append") { try directory.append(hardlink.lastPathComponent, data: Data("bad".utf8), limit: 100) }
            for name in ["../outside-sentinel", ".", "..", "", "a/b", "a\0b"] {
                try expectError("unsafe name \(name.debugDescription)") { try directory.writeNew(name, data: Data()) }
            }
            try require(try Data(contentsOf: outside) == Data("fixture".utf8), "A linked target was modified")
        case "ancestor-symlink":
            let real = try Fixture.directory("physical")
            let alias = Fixture.root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
            try expectError("symlinked ancestor") { _ = try DiagnosticDirectory.open(alias.appendingPathComponent("nested"), create: true) }
            try require(!Fixture.exists(real.appendingPathComponent("nested")), "Creation followed an ancestor symlink")
            // This deliberately documents the product's rejection of ordinary
            // symlink paths; fixture physicalization is not a product fix.
            try require(try DiagnosticDirectory.open(real) != nil, "Physical fixture unexpectedly rejected")
        case "permissions":
            let folder = try Fixture.directory("permissions")
            let directory = try DiagnosticDirectory.open(folder)!
            try directory.writeNew("candidate", data: Data("x".utf8))
            let file = try directory.file("candidate")!
            defer { chmod(folder.path, 0o700) }
            try require(chmod(folder.path, 0o500) == 0, "Cannot establish read-only fixture")
            try expectError("unlink permission denial") { try directory.remove(file) }
            try expectError("write permission denial") { try directory.writeNew("new", data: Data()) }
            try require(chmod(folder.path, 0o000) == 0, "Cannot establish unreadable fixture")
            try expectError("directory read permission denial") { _ = try DiagnosticDirectory.open(folder) }
        case "stale-snapshot":
            let directory = try reportDirectory()
            try directory.writeNew("old", data: Data("original".utf8))
            let old = try directory.file("old")!
            try directory.move(old, to: "saved")
            try directory.writeNew("old", data: Data("replacement".utf8))
            try expectError("replacement inode delete") { try directory.remove(old) }
            try expectError("replacement inode rename") { try directory.move(old, to: "other") }
            let replacement = try directory.file("old")!
            try expectError("rename over existing destination") { try directory.move(replacement, to: "saved") }
            try directory.append("old", data: Data("more".utf8), limit: 100)
            try expectError("grown file snapshot") { try directory.remove(replacement) }
        case "overflow":
            let a = DiagnosticDirectory.File(name: "a", size: Int64.max, modified: Date(), device: 0, inode: 1)
            let b = DiagnosticDirectory.File(name: "b", size: 1, modified: Date(), device: 0, inode: 2)
            try expectError("byte total overflow") { _ = try DiagnosticDirectory.totalBytes([a, b]) }
        case "capture-isolation":
            let unrelated = try Fixture.directory("unrelated-library")
            let sentinel = unrelated.appendingPathComponent("ledger.1.jsonl")
            try Fixture.write(sentinel)
            _ = try report(2, age: 1); _ = try report(1, age: 2)
            await DecisionLedger.shared.append(.string("fixture"))
            try await Storage.clearDiagnostics()
            try require(HangWatchdog.reportsFolder().path.hasPrefix(CaptureRun.storageRoot!.path + "/"), "Reports escaped Capture root")
            try require(DecisionLedger.directory.path.hasPrefix(CaptureRun.storageRoot!.path + "/"), "Ledger escaped Capture root")
            try require(try Data(contentsOf: sentinel) == Data("fixture".utf8), "Capture touched unrelated fixture library")
        case "concurrent-ledger":
            let ledger = DecisionLedger.shared
            await ledger.append(.string("seed"))
            try Fixture.bytes(ledgerFile("ledger.jsonl"), DecisionLedger.fileLimit - 8)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<200 {
                    group.addTask { await ledger.append(.string("record-\(i)")) }
                    group.addTask { try await ledger.clearDiagnostics() }
                    group.addTask {
                        let usage = try await ledger.measureDiagnostics()
                        try require(usage.totalBytes >= usage.cleanableBytes && usage.cleanableBytes >= 0, "Concurrent ledger measurement inconsistent")
                    }
                }
                try await group.waitForAll()
            }
            let text = try String(contentsOf: ledgerFile("ledger.jsonl"), encoding: .utf8)
            let lines = text.split(separator: "\n")
            try require(text.hasSuffix("\n") && lines.count == 200 && lines.allSatisfy { JSONValue.parse(String($0)) != nil }, "Concurrent cleanup lost/truncated current records")
        case "concurrent-reports":
            _ = try report(0)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 1...60 {
                    group.addTask {
                        // Only publication is synthesized; sampling is never included.
                        try HangWatchdog.reportsLock.withLock {
                            let directory = try reportDirectory()
                            let stamp = ISO8601.string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))).replacingOccurrences(of: ":", with: "-")
                            try directory.writeNew("hang-\(stamp).txt", data: Data("finished-\(i)".utf8))
                            try HangWatchdog.trimReports(in: directory)
                        }
                    }
                    group.addTask { try HangWatchdog.clearDiagnostics() }
                    group.addTask {
                        let usage = try HangWatchdog.measureDiagnostics()
                        try require(usage.totalBytes >= usage.cleanableBytes && usage.totalBytes > 0, "Concurrent report snapshot inconsistent")
                    }
                }
                try await group.waitForAll()
            }
            let files = try HangWatchdog.completedReports(in: reportDirectory())
            try require(!files.isEmpty && files.count <= HangWatchdog.keptReports, "Concurrent cleanup lost all reports or exceeded count bound")
        default: throw CheckFailure("Unknown case \(test)")
        }
        print("PASS \(test)")
    }
}
'''


def updater_source():
    swift = COMMON
    swift += (ROOT / "Tivano/Core/Support/RuntimeStorageUsage.swift").read_text() + "\n"
    swift += 'extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\n'
    swift += declaration(ROOT / "Tivano/App/UpdateChecker.swift", "struct AppVersion:") + "\n"
    swift += declaration(UPDATER, "enum AutoUpdateState:") + "\n"
    swift += declaration(UPDATER, "enum AutoUpdateFailure:") + "\n"
    swift += r'''
// These stubs represent application state, not cleanup policy.
enum AppInfo {
    static let version = "2.0.0"
    static let isDevelopment = ProcessInfo.processInfo.environment["FIXTURE_DEV"] == "1"
}
enum CaptureRun {
    static let isEnabled = ProcessInfo.processInfo.environment["FIXTURE_CAPTURE"] == "1"
}
enum StoragePaths { static var root: URL { Fixture.root.appendingPathComponent("library") } }
struct AvailableUpdate: Sendable {
    var version: String
    var downloadURL = URL(string: "https://invalid.fixture/update.dmg")!
    var fallbackDownloadURL: URL? = nil
    var sha256: String? = nil
}
struct UpdateInstallError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
@MainActor final class UpdateInstallProgress { var isInstallRunning = false }
@MainActor final class AppUpdater {
    var prepareTask: Task<Void, Never>?
    var installTask: Task<Void, Never>?
    var handedOff = false
    var isSilentHandoff = false
    var isPoweringOff = false
    var isClearingStorage = false
    var automaticEnabled = true
    var deferredPreparation: AvailableUpdate?
    var downloadCalls = 0
    func download(_ url: URL, reportsProgress: Bool) async throws -> URL {
        downloadCalls += 1
        throw UpdateInstallError("Fixture forbids network downloads")
    }
    func stage(image: URL, expectedVersion: String, background: Bool) async throws -> URL {
        throw UpdateInstallError("Fixture forbids mounting or staging an installer")
    }
    nonisolated static func checksum(of image: URL) async throws -> String {
        throw UpdateInstallError("Fixture does not produce disk images")
    }
    var autoUpdate: AutoUpdateState = .idle
    var progress = UpdateInstallProgress()
    var idleTimer: DispatchSourceTimer?
    var scheduleCalls = 0
    func scheduleIdleInstall() { scheduleCalls += 1 }
    nonisolated static func verifySignature(of app: URL) throws {
        // Explicit deterministic signature verdict. No claim about Apple signing.
        if ProcessInfo.processInfo.environment["FIXTURE_BAD_SIGNATURE"] == "1" {
            throw CheckFailureSignature()
        }
        if ProcessInfo.processInfo.environment["FIXTURE_REPLACE_VALIDATION"] == "1" {
            let source = app.deletingLastPathComponent()
            let saved = Fixture.root.appendingPathComponent("validated-during-signature")
            try FileManager.default.moveItem(at: source, to: saved)
            try FileManager.default.copyItem(at: saved, to: source)
            try Fixture.write(app.appendingPathComponent("unvalidated"))
        }
    }
    struct CheckFailureSignature: Error {}
'''
    for marker in ("    private var updatesRoot: URL", "    private func stagedApp(",
                   "    func prepareInBackground(", "    func autoUpdateSettingChanged()"):
        swift += declaration(UPDATER, marker) + "\n"
    source = UPDATER.read_text()
    installer_start = source.index('    private nonisolated static let installerScript = """')
    installer_end = source.index('\n    """', installer_start) + len('\n    """')
    swift += source[installer_start:installer_end].replace("private ", "") + "\n"
    start = source.index("    private var storageIsInUse: Bool")
    end = source.index("    /// Off hands the update back", start)
    swift += source[start:end].replace("private ", "") + "\n}\n"
    return swift + UPDATER_CHECKS


UPDATER_CHECKS = r'''
func stage(_ version: String, installedVersion: String? = nil) throws -> URL {
    let folder = StoragePaths.root.appendingPathComponent("Updates/" + version)
    let app = folder.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
    let info: [String: Any] = ["CFBundleIdentifier": "invalid.fixture.storage", "CFBundlePackageType": "APPL",
                               "CFBundleShortVersionString": installedVersion ?? version,
                               "CFBundleVersion": "1", "CFBundleExecutable": "fixture"]
    try Fixture.write(app.appendingPathComponent("Contents/Info.plist"), PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
    try Fixture.write(app.appendingPathComponent("Contents/MacOS/fixture"))
    try Fixture.write(app.appendingPathComponent("Contents/Resources/payload"), Data(repeating: 65, count: 100))
    return folder
}
@main struct Checks {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        _ = Fixture.root
        let test = CommandLine.arguments[1]
        let updater = AppUpdater()
        let appName = Bundle.main.bundleURL.lastPathComponent
        switch test {
        case "updater-versions":
            for invalid in ["", " 1.0", "1.0 ", "../1", "1/2", "1.2-beta", "1..2", "1.2.3.4", "vv1", "１.2", "999999999999999999999999999"] {
                try require(AppUpdater.storageVersion(invalid) == nil, "Accepted unsafe version \(invalid)")
            }
            let old = try stage("1.9.9"), equal = try stage("2.0.0"), future = try stage("2.0.1")
            let ignored = StoragePaths.root.appendingPathComponent("Updates/unknown/recovery.patch")
            try Fixture.write(ignored)
            let usage = try await updater.measureStorage()
            let oldBytes = try AppUpdater.storageFolder(old, appName: appName, currentVersion: AppInfo.version).bytes
            let equalBytes = try AppUpdater.storageFolder(equal, appName: appName, currentVersion: AppInfo.version).bytes
            try require(usage.cleanableBytes == oldBytes + equalBytes && usage.totalBytes > usage.cleanableBytes, "Version accounting boundary wrong")
            try await updater.clearObsoleteStorage()
            try require(!Fixture.exists(old) && !Fixture.exists(equal) && Fixture.exists(future) && Fixture.exists(ignored), "Updater deleted future/unknown data or retained obsolete data")
            try require(!updater.isClearingStorage && updater.scheduleCalls == 1, "Cleanup did not release exclusion")
        case "updater-installer":
            let old = try stage("1.0.0"), active = try stage("3.0.0")
            try Fixture.write(active.appendingPathComponent("install.sh"))
            try Fixture.write(active.appendingPathComponent("install.log"))
            let usage = try await updater.measureStorage()
            try require(usage.totalBytes > usage.cleanableBytes && usage.cleanableBytes > 0, "Legacy installer markers blocked unrelated safe updates")
            try await updater.clearObsoleteStorage()
            try require(!Fixture.exists(old) && Fixture.exists(active), "Cleanup touched installer-owned storage or skipped unrelated obsolete data")
            try require(!updater.isClearingStorage && updater.scheduleCalls == 1, "Cleanup leaked exclusion")
        case "updater-busy":
            let old = try stage("1.0.0")
            for state in 0..<9 {
                let busy = AppUpdater()
                switch state {
                case 0: busy.prepareTask = Task {}
                case 1: busy.installTask = Task {}
                case 2: busy.handedOff = true
                case 3: busy.isSilentHandoff = true
                case 4: busy.isPoweringOff = true
                case 5: busy.progress.isInstallRunning = true
                case 6: busy.autoUpdate = .downloading(version: "3.0.0")
                case 7: busy.autoUpdate = .ready(version: "3.0.0")
                default: busy.isClearingStorage = true
                }
                try require(try await busy.measureStorage().cleanableBytes == 0, "Busy state \(state) offers cleanup")
                try await expectAsyncError("busy state \(state)") { try await busy.clearObsoleteStorage() }
                try require(Fixture.exists(old), "Busy cleanup deleted staged app")
            }
        case "updater-unknown":
            let old = try stage("1.0.0")
            try Fixture.write(old.appendingPathComponent("recovery.patch"))
            try await expectAsyncError("unknown version-folder contents") { try await updater.clearObsoleteStorage() }
            try require(Fixture.exists(old.appendingPathComponent("recovery.patch")), "Unknown file deleted")
        case "updater-partial-cleanup":
            let safe = try stage("1.0.0"), unknown = try stage("1.1.0"), future = try stage("3.0.0")
            let recovery = unknown.appendingPathComponent("recovery.patch")
            try Fixture.write(recovery)
            try await expectAsyncError("partial cleanup reports rejected directory") { try await updater.clearObsoleteStorage() }
            try require(!Fixture.exists(safe) && Fixture.exists(future), "Safe cleanup skipped eligible data or removed a future update")
            try require(try Data(contentsOf: recovery) == Data("fixture".utf8), "Partial cleanup removed unknown recovery data")
        case "updater-busy-after-measure":
            let old = try stage("1.0.0")
            try require(try await updater.measureStorage().cleanableBytes > 0, "Fixture had no eligible update")
            updater.autoUpdate = .downloading(version: "3.0.0")
            try await expectAsyncError("stale measurement cannot authorize cleanup during update") { try await updater.clearObsoleteStorage() }
            try require(Fixture.exists(old), "Cleanup trusted stale idle state")
        case "updater-late-hardlink":
            let folder = try stage("1.0.0")
            let checked = try AppUpdater.storageFolder(folder, appName: appName, currentVersion: AppInfo.version)
            let outside = Fixture.root.appendingPathComponent("late-link-sentinel")
            try Fixture.write(outside)
            let linked = folder.appendingPathComponent(appName + "/Contents/Resources/shared")
            try FileManager.default.linkItem(at: outside, to: linked)
            try expectError("deletion rechecks links after validation") { try AppUpdater.removeStorageFolder(checked, appName: appName) }
            try require(Fixture.exists(linked), "Late hardlink was removed")
            try require(try Data(contentsOf: outside) == Data("fixture".utf8), "Late hardlink target changed")
        case "updater-replaced-during-validation":
            let folder = try stage("1.0.0")
            setenv("FIXTURE_REPLACE_VALIDATION", "1", 1)
            try expectError("directory replaced during signature validation") {
                _ = try AppUpdater.storageFolder(folder, appName: appName, currentVersion: AppInfo.version)
            }
            try require(Fixture.exists(folder.appendingPathComponent(appName + "/unvalidated")), "Replacement was removed during validation")
        case "updater-legacy-empty-installer":
            let safe = try stage("1.0.0"), legacy = try stage("1.1.0")
            try FileManager.default.removeItem(at: legacy.appendingPathComponent(appName))
            try Fixture.write(legacy.appendingPathComponent("install.sh"))
            try Fixture.write(legacy.appendingPathComponent("install.log"))
            try require(try await updater.measureStorage().cleanableBytes > 0, "Legacy marker-only directory poisoned statistics")
            try await updater.clearObsoleteStorage()
            try require(!Fixture.exists(safe) && Fixture.exists(legacy), "Legacy completion was guessed or unrelated cleanup blocked")
        case "updater-abandoned-manifest", "updater-abandoned-pending", "updater-abandoned-empty-manifest":
            let old = try stage("1.0.0"), future = try stage("3.0.0")
            let job = StoragePaths.root.appendingPathComponent("Updates/.cleanup-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let name = test == "updater-abandoned-pending" ? "manifest.pending" : "manifest.json"
            let bytes = test == "updater-abandoned-empty-manifest" ? Data() : Data("{partial".utf8)
            try Fixture.write(job.appendingPathComponent(name), bytes)
            let usage = try await updater.measureStorage()
            try require(usage.cleanableBytes > 0, "Abandoned metadata blocked storage measurement")
            try require(try AppUpdater.cleanupBytes(job) == Int64(bytes.count), "Abandoned metadata was not counted")
            try await updater.clearObsoleteStorage()
            try require(!Fixture.exists(job) && !Fixture.exists(old) && Fixture.exists(future), "Abandoned metadata blocked safe cleanup or touched pending update")
        case "updater-manifest-publication":
            let job = try Fixture.directory("Updates/.cleanup-" + UUID().uuidString)
            try require(chmod(job.path, 0o700) == 0, "Cannot secure metadata fixture")
            let descriptor = try AppUpdater.openStorageDirectory(job)
            defer { Darwin.close(descriptor) }
            let bytes = Data("{\"complete\":true}".utf8)
            try AppUpdater.publishCleanupManifest(bytes, job: job, descriptor: descriptor)
            let published = job.appendingPathComponent("manifest.json")
            try require(try Data(contentsOf: published) == bytes, "Published manifest was incomplete")
            try require(!Fixture.exists(job.appendingPathComponent("manifest.pending")), "Publication left pending file")
            try expectError("atomic publication never overwrites a committed manifest") {
                try AppUpdater.publishCleanupManifest(Data("replacement".utf8), job: job, descriptor: descriptor)
            }
            try require(try Data(contentsOf: published) == bytes, "Failed publication replaced committed manifest")
            try AppUpdater.resumeCleanup(job)
            try require(!Fixture.exists(job), "Failed publication metadata could not be recovered")
        case "updater-malformed-manifest-with-payload":
            let folder = try stage("1.0.0")
            let checked = try AppUpdater.storageFolder(folder, appName: appName, currentVersion: AppInfo.version)
            let job = try AppUpdater.quarantineStorageFolder(checked, appName: appName)
            let sentinel = job.appendingPathComponent("payload/" + appName + "/Contents/Resources/payload")
            let before = try Data(contentsOf: sentinel)
            try Fixture.write(job.appendingPathComponent("manifest.json"), Data("{partial".utf8))
            try expectError("malformed manifest with payload cannot be discarded") { try AppUpdater.resumeCleanup(job) }
            try expectError("payload without valid manifest cannot be advertised as cleanable") { _ = try AppUpdater.cleanupBytes(job) }
            try require(try Data(contentsOf: sentinel) == before, "Malformed manifest bypassed payload protection")
        case "updater-abandoned-metadata-links":
            for kind in ["symlink", "hardlink", "unknown"] {
                let job = try Fixture.directory("Updates/.cleanup-" + UUID().uuidString)
                try require(chmod(job.path, 0o700) == 0, "Cannot secure metadata fixture")
                let outside = Fixture.root.appendingPathComponent("outside-" + kind)
                try Fixture.write(outside)
                let metadata = job.appendingPathComponent(kind == "unknown" ? "recovery.patch" : "manifest.pending")
                switch kind {
                case "symlink": try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
                case "hardlink": try FileManager.default.linkItem(at: outside, to: metadata)
                default: try Fixture.write(metadata)
                }
                try expectError("abandoned metadata must not include \(kind)") { try AppUpdater.resumeCleanup(job) }
                try require(Fixture.exists(metadata) && (try Data(contentsOf: outside)) == Data("fixture".utf8), "Recovery removed unsafe metadata or changed target")
            }
        case "updater-empty-cleanup-job":
            let folder = try stage("1.0.0")
            let checked = try AppUpdater.storageFolder(folder, appName: appName, currentVersion: AppInfo.version)
            let job = try AppUpdater.quarantineStorageFolder(checked, appName: appName)
            try FileManager.default.removeItem(at: job.appendingPathComponent("payload"))
            try FileManager.default.removeItem(at: job.appendingPathComponent("manifest.json"))
            try require(try AppUpdater.cleanupBytes(job) == 0, "Empty finalization remnant is not measurable")
            try await updater.clearObsoleteStorage()
            try require(!Fixture.exists(job), "Empty finalization remnant cannot be retried")
        case "updater-replaced-version", "updater-replaced-package":
            let folder = try stage("1.0.0")
            let checked = try AppUpdater.storageFolder(folder, appName: appName, currentVersion: AppInfo.version)
            let preserved = Fixture.root.appendingPathComponent("validated-copy")
            let replaced = test == "updater-replaced-version" ? folder : folder.appendingPathComponent(appName)
            try FileManager.default.moveItem(at: replaced, to: preserved)
            _ = try stage("1.0.0")
            let sentinel = folder.appendingPathComponent(appName + "/Contents/Resources/unvalidated")
            try Fixture.write(sentinel)
            try expectError("replacement after signature validation") { try AppUpdater.removeStorageFolder(checked, appName: appName) }
            try require(Fixture.exists(preserved) && Fixture.exists(sentinel), "Validation/deletion identity mismatch removed a replacement")
        case "updater-completed-installer", "updater-completed-empty-installer":
            let folder = try stage("1.0.0")
            try Fixture.write(folder.appendingPathComponent("install.sh"), Data(AppUpdater.installerScript.utf8))
            try Fixture.write(folder.appendingPathComponent("install.log"))
            try Fixture.write(folder.appendingPathComponent("install.complete"), Data("complete\n".utf8))
            if test == "updater-completed-empty-installer" {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(appName))
            }
            try require(try await updater.measureStorage().cleanableBytes > 0, "Completed installer was permanently protected")
            try await updater.clearObsoleteStorage()
            try require(!Fixture.exists(folder), "Completed installer leftovers were retained")
        case "updater-quarantine-retry":
            let folder = try stage("1.0.0")
            let checked = try AppUpdater.storageFolder(folder, appName: appName, currentVersion: AppInfo.version)
            let job = try AppUpdater.quarantineStorageFolder(checked, appName: appName)
            let package = job.appendingPathComponent("payload/" + appName)
            try FileManager.default.removeItem(at: package.appendingPathComponent("Contents/Info.plist"))
            let resources = package.appendingPathComponent("Contents/Resources")
            try require(chmod(resources.path, 0o000) == 0, "Cannot simulate interrupted cleanup")
            try expectError("permission failure leaves retry journal") { try AppUpdater.resumeCleanup(job) }
            try require(Fixture.exists(job.appendingPathComponent("manifest.json")), "Failure lost cleanup journal")
            try require(chmod(resources.path, 0o700) == 0, "Cannot restore permissions")
            // A partially removed bundle cannot pass signature verification. Retry must use
            // the persisted identities, not ask the signing service to accept the remnant.
            setenv("FIXTURE_BAD_SIGNATURE", "1", 1)
            let remaining = try await updater.measureStorage()
            try require(remaining.totalBytes > 0 && remaining.totalBytes == remaining.cleanableBytes, "Partial cleanup became unmeasurable")
            try await updater.clearObsoleteStorage()
            try require(!Fixture.exists(job), "Interrupted cleanup could not resume")
        case "updater-quarantine-replacement":
            let folder = try stage("1.0.0")
            let checked = try AppUpdater.storageFolder(folder, appName: appName, currentVersion: AppInfo.version)
            let job = try AppUpdater.quarantineStorageFolder(checked, appName: appName)
            let payload = job.appendingPathComponent("payload")
            let saved = Fixture.root.appendingPathComponent("saved-payload")
            try FileManager.default.moveItem(at: payload, to: saved)
            let sentinel = payload.appendingPathComponent("unvalidated")
            try Fixture.write(sentinel)
            try expectError("quarantine payload identity changed") { try AppUpdater.resumeCleanup(job) }
            try require(Fixture.exists(saved) && Fixture.exists(sentinel), "Retry deleted substituted payload")
        case "updater-version-mismatch":
            let folder = try stage("1.0.0", installedVersion: "9.0.0")
            try await expectAsyncError("bundle and folder version mismatch") { try await updater.clearObsoleteStorage() }
            try require(Fixture.exists(folder), "Mismatched bundle deleted")
        case "updater-signature":
            let folder = try stage("1.0.0")
            try await expectAsyncError("stubbed rejected signature") { try await updater.clearObsoleteStorage() }
            try require(Fixture.exists(folder), "Rejected bundle deleted")
        case "updater-internal-link":
            let folder = try stage("1.0.0")
            let framework = folder.appendingPathComponent(appName + "/Contents/Frameworks/Fixture.framework")
            try Fixture.write(framework.appendingPathComponent("Versions/A/Fixture"))
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Fixture").path, withDestinationPath: "Versions/Current/Fixture")
            try require(try await updater.measureStorage().cleanableBytes > 0, "Standard internal framework links rejected")
            try await updater.clearObsoleteStorage()
            try require(!Fixture.exists(folder), "Validated obsolete bundle with internal links was not removed")
        case "updater-external-link":
            let folder = try stage("1.0.0")
            let outside = Fixture.root.appendingPathComponent("outside-sentinel")
            try Fixture.write(outside)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(appName + "/Contents/Resources/escape"), withDestinationURL: outside)
            let externalTree = try Fixture.directory("external-tree")
            let nestedSentinel = externalTree.appendingPathComponent("keep.txt")
            try Fixture.write(nestedSentinel)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(appName + "/Contents/Resources/directory-escape"), withDestinationURL: externalTree)
            let attributes = try FileManager.default.attributesOfItem(atPath: outside.path)
            let inode = attributes[.systemFileNumber] as? NSNumber
            try require(try await updater.measureStorage().cleanableBytes > 0, "External package link blocked cleanup estimate")
            try await updater.clearObsoleteStorage()
            try require(Fixture.exists(outside), "External symlink target path removed")
            try require(try Data(contentsOf: outside) == Data("fixture".utf8), "External symlink target content changed")
            try require(try FileManager.default.attributesOfItem(atPath: outside.path)[.systemFileNumber] as? NSNumber == inode, "External symlink target replaced")
            try require(Fixture.exists(externalTree) && Fixture.exists(nestedSentinel), "Cleanup followed an external directory link")
            try require(try Data(contentsOf: nestedSentinel) == Data("fixture".utf8), "External directory contents changed")
            try require(!Fixture.exists(folder), "Obsolete package containing an external link was retained")
        case "updater-replay", "updater-no-replay", "updater-failed-cleanup-replay":
            let old = try stage("1.0.0")
            let future = try stage("3.0.0")
            // Exercise the real enqueue gate without copying its conditions. Then
            // run the real cleanup/defer and real preparation against a staged app.
            updater.isClearingStorage = true
            updater.prepareInBackground(AvailableUpdate(version: "3.0.0"))
            try require(updater.deferredPreparation?.version == "3.0.0" && updater.prepareTask == nil, "Preparation was dropped or started while cleanup owned storage")
            updater.isClearingStorage = false
            if test == "updater-no-replay" {
                updater.automaticEnabled = false
                updater.autoUpdateSettingChanged()
            }
            if test == "updater-failed-cleanup-replay" {
                try Fixture.write(old.appendingPathComponent("recovery.patch"))
                try await expectAsyncError("cleanup error still releases deferred work") { try await updater.clearObsoleteStorage() }
                try require(Fixture.exists(old.appendingPathComponent("recovery.patch")), "Failed cleanup removed unknown data")
            } else {
                try await updater.clearObsoleteStorage()
                try require(!Fixture.exists(old), "Replay fixture did not finish obsolete cleanup")
            }
            let preparation = updater.prepareTask
            if test == "updater-no-replay" {
                try require(preparation == nil && updater.autoUpdate == .idle, "Disabling auto update replayed preparation")
            } else {
                try require(preparation != nil, "Cleanup completion failed to replay deferred preparation")
                await preparation?.value
                try require(updater.autoUpdate == .ready(version: "3.0.0"), "Replayed production preparation did not reuse verified future bundle")
            }
            try require(updater.deferredPreparation == nil && !updater.isClearingStorage, "Cleanup retained deferred work or exclusion")
            try require(updater.downloadCalls == 0 && Fixture.exists(future), "Replay tried network or removed the staged future bundle")
        case "updater-package-root-link":
            let folder = try stage("1.0.0")
            let app = folder.appendingPathComponent(appName)
            let physical = Fixture.root.appendingPathComponent("physical-package.app")
            try FileManager.default.moveItem(at: app, to: physical)
            try FileManager.default.createSymbolicLink(at: app, withDestinationURL: physical)
            try await expectAsyncError("symlinked package root") { try await updater.clearObsoleteStorage() }
            try require(Fixture.exists(physical.appendingPathComponent("Contents/Resources/payload")) && Fixture.exists(app), "Cleanup followed or removed package-root link")
        case "updater-hardlink":
            let folder = try stage("1.0.0")
            let outside = Fixture.root.appendingPathComponent("outside-sentinel")
            try Fixture.write(outside)
            try FileManager.default.linkItem(at: outside, to: folder.appendingPathComponent(appName + "/Contents/Resources/shared"))
            try await expectAsyncError("hardlinked bytes are not exclusively reclaimable") { _ = try await updater.measureStorage() }
            try await expectAsyncError("hardlinked package cannot be cleaned") { try await updater.clearObsoleteStorage() }
            try require(Fixture.exists(folder) && Fixture.exists(outside), "Hardlinked package or target was removed")
            try require(try Data(contentsOf: outside) == Data("fixture".utf8), "Hardlink target content changed")
        case "updater-ancestor":
            let folder = try stage("1.0.0")
            let root = updater.updatesRoot
            let physical = StoragePaths.root.appendingPathComponent("physical-updates")
            try FileManager.default.moveItem(at: root, to: physical)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: physical)
            try await expectAsyncError("symlinked updates root") { try await updater.clearObsoleteStorage() }
            try require(Fixture.exists(physical.appendingPathComponent(folder.lastPathComponent)), "Cleanup followed root symlink")
        case "updater-permissions":
            try require(geteuid() != 0, "Permission fixtures require unprivileged user")
            let folder = try stage("1.0.0")
            defer { chmod(folder.path, 0o700) }
            try require(chmod(folder.path, 0o000) == 0, "Cannot deny fixture permissions")
            try await expectAsyncError("permission failure must not become zero usage") { _ = try await updater.measureStorage() }
            try await expectAsyncError("permission failure must propagate from cleanup") { try await updater.clearObsoleteStorage() }
        case "updater-capture", "updater-dev":
            let folder = try stage("1.0.0")
            try require(try await updater.measureStorage() == RuntimeStorageUsage(), "Disabled updater scanned storage")
            try await updater.clearObsoleteStorage()
            try require(Fixture.exists(folder) && updater.scheduleCalls == 0, "Disabled updater touched storage")
        default: throw CheckFailure("Unknown updater case \(test)")
        }
        print("PASS \(test) (signature/application-state fixtures)")
    }
}
'''

def ui_state_source():
    swift = COMMON + "\nimport Observation\n"
    swift += (ROOT / "Tivano/Core/Support/RuntimeStorageUsage.swift").read_text() + "\n"
    swift += r'''
// Only I/O is controlled here; the state transitions are extracted production code.
@MainActor enum Backend {
    static var reads: [CheckedContinuation<RuntimeStorageUsage, Error>] = []
    static var removals: [CheckedContinuation<Void, Error>] = []
    static func measure() async throws -> RuntimeStorageUsage {
        try await withCheckedThrowingContinuation { reads.append($0) }
    }
    static func clear() async throws {
        try await withCheckedThrowingContinuation { removals.append($0) }
    }
}
@MainActor enum Storage {
    static func measureDiagnostics() async throws -> RuntimeStorageUsage { try await Backend.measure() }
    static func clearDiagnostics() async throws { try await Backend.clear() }
}
@MainActor final class AppUpdater {
    static let shared = AppUpdater()
    func measureStorage() async throws -> RuntimeStorageUsage { try await Backend.measure() }
    func clearObsoleteStorage() async throws { try await Backend.clear() }
}
'''
    swift += "@MainActor\n@Observable\n" + declaration(
        ROOT / "Tivano/App/Views/Settings/StorageSettingsSections.swift", "private final class RuntimeStorageState {") + "\n"
    return swift + UI_STATE_CHECKS


UI_STATE_CHECKS = r'''
@MainActor func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        try require(ContinuousClock.now < deadline, "State transition timed out")
        await Task.yield()
    }
}
@main struct Checks {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        _ = Fixture.root
        let test = CommandLine.arguments[1]
        let state = RuntimeStorageState(kind: .diagnostics)
        switch test {
        case "ui-stale-measurement":
            let first = Task { await state.measure() }
            try await waitFor { Backend.reads.count == 1 }
            let second = Task { await state.measure() }
            try await waitFor { Backend.reads.count == 2 }
            let latest = RuntimeStorageUsage(totalBytes: 100, cleanableBytes: 30)
            Backend.reads[1].resume(returning: latest)
            await second.value
            Backend.reads[0].resume(returning: RuntimeStorageUsage(totalBytes: 200, cleanableBytes: 80))
            await first.value
            try require(state.usage == latest && !state.isMeasuring && state.canClear, "Late measurement replaced the newer result")
        case "ui-cancelled-measurement":
            let first = Task { await state.measure() }
            try await waitFor { Backend.reads.count == 1 }
            first.cancel()
            Backend.reads[0].resume(returning: RuntimeStorageUsage(totalBytes: 100, cleanableBytes: 30))
            await first.value
            try require(state.usage == nil && !state.isMeasuring && !state.canClear, "Cancelled measurement left stale data or busy state")
            let second = Task { await state.measure() }
            try await waitFor { Backend.reads.count == 2 }
            Backend.reads[1].resume(returning: RuntimeStorageUsage(totalBytes: 50, cleanableBytes: 10))
            await second.value
            try require(state.canClear && state.usage?.totalBytes == 50, "Measurement did not recover after cancellation")
        case "ui-cleanup-reentry":
            let first = Task { await state.measure() }
            try await waitFor { Backend.reads.count == 1 }
            Backend.reads[0].resume(returning: RuntimeStorageUsage(totalBytes: 100, cleanableBytes: 30))
            await first.value
            state.clear()
            state.clear()
            try await waitFor { Backend.removals.count == 1 }
            await state.measure()
            try require(state.isClearing && !state.canClear && state.usage == nil && Backend.reads.count == 1,
                        "Refresh or duplicate cleanup bypassed in-progress protection")
            Backend.removals[0].resume(throwing: CocoaError(.fileWriteNoPermission))
            try await waitFor { Backend.reads.count == 2 }
            Backend.reads[1].resume(returning: RuntimeStorageUsage(totalBytes: 80, cleanableBytes: 10))
            try await waitFor { !state.isMeasuring }
            try require(state.cleanupError != nil && state.usage?.totalBytes == 80 && state.canClear && Backend.removals.count == 1,
                        "Partial failure was hidden, not remeasured, or cleanup was duplicated")
            state.clear()
            try await waitFor { Backend.removals.count == 2 }
            Backend.removals[1].resume(returning: ())
            try await waitFor { Backend.reads.count == 3 }
            Backend.reads[2].resume(returning: RuntimeStorageUsage(totalBytes: 70))
            try await waitFor { !state.isMeasuring }
            try require(state.cleanupError == nil && !state.canClear && !state.isClearing, "Successful retry retained stale error or busy state")
        case "ui-measurement-error":
            let read = Task { await state.measure() }
            try await waitFor { Backend.reads.count == 1 }
            Backend.reads[0].resume(throwing: CocoaError(.fileReadNoPermission))
            await read.value
            state.clear()
            await Task.yield()
            try require(state.usage == nil && state.measurementError != nil && !state.canClear && Backend.removals.isEmpty,
                        "Failed measurement became zero/success or enabled deletion")
        default: throw CheckFailure("Unknown UI case \(test)")
        }
        print("PASS \(test) (production state, controlled I/O; not visual validation)")
    }
}
'''

UI_STATE_CASES = ["ui-stale-measurement", "ui-cancelled-measurement", "ui-cleanup-reentry", "ui-measurement-error"]

DIAGNOSTIC_CASES = [
    "diagnostic-accounting", "report-count", "report-age", "report-capacity",
    "report-latest-aged", "report-latest-oversize", "ledger-rotation", "ledger-age",
    "ledger-exact-limit", "partial-failure", "links-and-names", "ancestor-symlink",
    "permissions", "stale-snapshot", "overflow", "capture-isolation",
    "concurrent-ledger", "concurrent-reports",
]
UPDATER_CASES = [
    "updater-versions", "updater-installer", "updater-busy", "updater-unknown",
    "updater-version-mismatch", "updater-signature", "updater-internal-link",
    "updater-external-link", "updater-hardlink", "updater-ancestor", "updater-package-root-link",
    "updater-permissions", "updater-capture", "updater-dev",
    "updater-replay", "updater-no-replay", "updater-failed-cleanup-replay",
    "updater-partial-cleanup", "updater-busy-after-measure", "updater-late-hardlink",
    "updater-replaced-version", "updater-replaced-package", "updater-completed-installer",
    "updater-completed-empty-installer", "updater-quarantine-retry", "updater-quarantine-replacement",
    "updater-replaced-during-validation", "updater-legacy-empty-installer", "updater-empty-cleanup-job",
    "updater-abandoned-manifest", "updater-abandoned-pending", "updater-abandoned-empty-manifest",
    "updater-manifest-publication", "updater-malformed-manifest-with-payload", "updater-abandoned-metadata-links",
]


def main():
    if sys.platform != "darwin" or os.geteuid() == 0:
        raise SystemExit("Requires macOS and an unprivileged user; do not run via sudo.")
    failures = []
    scratch = ROOT / "build.noindex"
    scratch.mkdir(exist_ok=True)
    # Foundation can canonicalize /private/var back to /var. Use the worktree's
    # physical scratch path; ancestor-symlink refusal has its own fixture.
    with tempfile.TemporaryDirectory(prefix="tivano-storage-checks-", dir=scratch) as temporary:
        base = Path(temporary).resolve()
        for group, make_source, cases in (("diagnostics", diagnostic_source, DIAGNOSTIC_CASES),
                                          ("updater", updater_source, UPDATER_CASES),
                                          ("ui-state", ui_state_source, UI_STATE_CASES)):
            try:
                source = make_source()
            except ValueError as error:
                failures.append(group + " extraction (no cases executed)")
                print(str(error), file=sys.stderr)
                continue
            build = base / group
            build.mkdir()
            swift = build / "Checks.swift"
            swift.write_text(source)
            app = build / "Fixture.app"
            executable = app / "Contents/MacOS/checks"
            executable.parent.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "invalid.fixture.checks",
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "checks",
                "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "1",
            }))
            environment = os.environ.copy()
            environment.update(HOME=str(build), TMPDIR=str(build),
                               CLANG_MODULE_CACHE_PATH=str(build / "module-cache"),
                               SWIFT_MODULECACHE_PATH=str(build / "module-cache"))
            compile_result = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "6", "-D", "DEBUG", "-parse-as-library",
                 "-module-cache-path", str(build / "module-cache"), str(swift), "-o", str(executable)],
                cwd=build, env=environment, timeout=180, capture_output=True, text=True,
            )
            if compile_result.returncode:
                print(compile_result.stdout + compile_result.stderr, file=sys.stderr)
                failures.append(group + " compilation (no cases executed)")
                continue
            for case in cases:
                root = build / case
                root.mkdir()
                environment_case = environment.copy()
                environment_case.update(HOME=str(root), TMPDIR=str(root),
                                        TIVANO_STORAGE_FIXTURE=str(root),
                                        FIXTURE_DEV="1" if case == "updater-dev" else "0",
                                        FIXTURE_CAPTURE="1" if case == "updater-capture" else "0",
                                        FIXTURE_BAD_SIGNATURE="1" if case == "updater-signature" else "0")
                command = [str(executable), case]
                if group == "diagnostics":
                    command += ["--website-captures", str(root / "capture")]
                try:
                    result = subprocess.run(command, cwd=root, env=environment_case,
                                            timeout=60, capture_output=True, text=True)
                except subprocess.TimeoutExpired:
                    failures.append(case + " timeout")
                    print("FAIL " + case + ": timed out", file=sys.stderr)
                    continue
                if result.returncode:
                    failures.append(case)
                    print("FAIL " + case + "\n" + result.stdout + result.stderr, file=sys.stderr)
                else:
                    print(result.stdout.strip())
    if failures:
        raise SystemExit("FAILED: " + ", ".join(failures))
    print("PASS: isolated runtime storage cases; real signing/sampling/handoff remain untested")


if __name__ == "__main__":
    main()
