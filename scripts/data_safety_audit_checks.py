#!/usr/bin/env python3
"""Compile extracted production safety methods and run isolated Git/Store fixtures.

Lead-only: this is an executable acceptance script, not a source-only check. No app,
network, real library or existing repository is used. Artifacts and all fresh test
repositories are retained outside the checkout, including on failure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
from local_control_domain_checks import declaration

ROOT = Path(__file__).resolve().parents[1]
GIT = "Tivano/Services/Git/Git.swift"
STORE = "Tivano/Services/Store/Storage.swift"
TIMELINE = "Tivano/Core/Models/Timeline.swift"
CASES = (
    "sync-nonoverlap", "sync-overlap", "staged-unrelated", "staged-overlap",
    "file-shapes", "capture-rebase", "invalid-ref", "query-status", "query-cat-file",
    "query-check-ignore", "query-ls-files", "query-truncated", "apply-failure",
    "tracked-artifacts", "dirty-worktree", "repository-lock", "before-ref", "after-ref",
    "attachments-bad-json", "attachments-bad-schema", "attachments-missing-turn",
    "attachments-missing-revision", "attachments-wrong-turn-id", "attachments-unreadable", "attachments-orphan",
    "attachments-save-before", "attachments-save-during", "attachment-import", "claims", "thread-save-scale", "unborn-head", "non-repository", "apply-success",
)

SWIFT_SUPPORT = r'''
import Foundation
import Synchronization
import CryptoKit
import Darwin

enum AppText { static func localized(_ key: String) -> String { key } }
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
func auditWait(_ semaphore: DispatchSemaphore, timeout: DispatchTime = .distantFuture) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
        }
    }
}
enum Audit {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AUDIT_ROOT"]!)
    static let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AUDIT_GIT"]!)
    static let fault = ProcessInfo.processInfo.environment["AUDIT_FAULT"] ?? ""
    static func requireInside(_ url: URL) throws {
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw ShellError("Fixture refused a path outside AUDIT_ROOT")
        }
    }
}
enum GitLane { case read, checkpoint, long }

// Only the process transport is substituted. All safety methods below are extracted
// unchanged; every non-injected command executes real Git in the fixture repository.
struct Git: Sendable {
    let directory: URL
    init(_ path: String) { directory = URL(fileURLWithPath: path) }
    @discardableResult
    func run(_ arguments: [String], environment extra: [String: String] = [:],
             input: Data? = nil, timeout: TimeInterval? = nil, lane: GitLane? = nil) async throws -> ShellResult {
        try Audit.requireInside(directory)
        if let index = extra["GIT_INDEX_FILE"] { try Audit.requireInside(URL(fileURLWithPath: index)) }
        let text = String(decoding: input ?? Data(), as: UTF8.self)
        let committing = arguments == ["update-ref", "--stdin"] && text.contains("\ncommit\n")
        let injected = (Audit.fault == "before-ref" && committing)
            || (Audit.fault == "apply" && arguments.first == "apply")
            || (Audit.fault == "status" && arguments.first == "status")
            || (Audit.fault == "cat-file" && arguments.first == "cat-file")
            || (Audit.fault == "check-ignore" && arguments.first == "check-ignore")
            || (Audit.fault == "ls-files" && arguments.first == "ls-files")
        if injected { return ShellResult(status: 91, stdout: Data(), stderr: Data("injected failure".utf8)) }
        if Audit.fault == "truncated", arguments.first == "cat-file" {
            return ShellResult(status: 0, stdout: Data("blob".utf8), stderr: Data())
        }
        let files = Audit.root.appendingPathComponent("process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let inURL = files.appendingPathComponent("stdin")
        let outURL = files.appendingPathComponent("stdout")
        let errURL = files.appendingPathComponent("stderr")
        try (input ?? Data()).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: inURL)
        let stdout = try FileHandle(forWritingTo: outURL)
        let stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = Audit.git
        process.arguments = ["-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let status = process.terminationStatus
        let record: [String: Any] = ["cwd": directory.path, "arguments": arguments, "status": status,
                                     "index": extra["GIT_INDEX_FILE"] ?? "real"]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: files.appendingPathComponent("command.json"))
        if committing, status == 0, Audit.fault == "after-ref" {
            throw ShellError("injected failure after the real ref transaction, before index publication")
        }
        return ShellResult(status: status, stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL))
    }
/* GIT_METHODS */
}

struct Attachment: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var path: String
    var mimeType: String
    var url: URL { URL(fileURLWithPath: path) }
}
enum MimeType { static func of(_ ext: String) -> String { "application/octet-stream" } }
// Presentation/provider payloads are leaves, not under test. ThreadDocument's real
// decoder, turn-index schema, StoredTurn/File, ThreadSave and DiskWriter are retained.
struct TimelineItem: Codable, Equatable, Sendable { var id: String; var attachment: Attachment? }
struct TurnRecord: Codable, Equatable, Sendable { var id: UUID }
struct FollowUpPrompt: Codable, Equatable, Sendable { var id: UUID }
struct HydraMergeRecord: Codable, Equatable, Sendable { var id: UUID }
struct ThreadContinuation: Codable, Equatable, Sendable { var attachments: [Attachment]? }
struct Library: Codable, Sendable {}
enum DocumentPrefetch { static let shared = Empty(); struct Empty { func forget(_ id: UUID) {} } }
enum CensusGate {
    static let enabled = Mutex(false)
    static let entered = DispatchSemaphore(value: 0)
    static let resume = DispatchSemaphore(value: 0)
    static func pauseIfRequested() {
        guard enabled.withLock({ $0 }) else { return }
        entered.signal()
        resume.wait()
    }
}
enum Storage {
    static let root = URL(fileURLWithPath: CommandLine.arguments[2])
    static var threadsDirectory: URL { root.appendingPathComponent("threads") }
    static var attachmentsDirectory: URL { root.appendingPathComponent("attachments") }
    static func threadURL(_ id: UUID) -> URL { threadsDirectory.appendingPathComponent("\(id).json") }
    static func prepareLibraryWrite(_ library: Library, to url: URL) throws {}
/* STORE_METHODS */
}
enum HeadFilter {
/* HEAD_FILTER */
}
/* MODELS */
/* DISK_WRITER */
/* CLAIMS */
extension CheckoutClaims {
    static func ageForFixture(owner: UUID) {
        for root in Array(claims.keys) {
            for path in Array((claims[root] ?? [:]).keys) where claims[root]?[path]?.owner == owner {
                claims[root]?[path]?.date = Date(timeIntervalSince1970: 1)
            }
        }
    }
}
/* LOCKS */
/* TOUCHED_PATHS */

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ShellError(message) }
}
func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main struct Runner {
    @MainActor static func main() async {
        do {
            let a = CommandLine.arguments
            let action = a[1]
            let directory = URL(fileURLWithPath: a[2])
            try Audit.requireInside(directory)
            let git = Git(directory.path)
            switch action {
            case "save-scale":
                try FileManager.default.createDirectory(at: Storage.threadsDirectory, withIntermediateDirectories: true)
                var rows: [[String: Any]] = []
                for count in [100, 1000, 10000] {
                    var head = ThreadDocument(threadID: UUID())
                    let ids = (0..<count).map { _ in UUID() }
                    head.turnIndex = ids.map { ThreadTurnReference(id: $0, revision: 1) }
                    let all = Dictionary(uniqueKeysWithValues: ids.map { ($0, StoredTurn(turn: TurnRecord(id: $0), items: [], itemPositions: [:])) })
                    try require(DiskWriter.shared.writeThreadSynchronously(ThreadSave(head: head, dirtyTurns: all)), "scale fixture seed failed")
                    var times: [Double] = []
                    for revision in 2...4 {
                        head.turnIndex?[count - 1].revision = UInt64(revision)
                        let start = Date.now
                        let ok = DiskWriter.shared.writeThreadSynchronously(ThreadSave(head: head, dirtyTurns: [ids.last!: all[ids.last!]!]))
                        times.append(Date.now.timeIntervalSince(start) * 1000)
                        try require(ok, "scale fixture update failed")
                    }
                    rows.append(["turns": count, "single_dirty_turn_save_ms": times])
                    // Missing unchanged history must still reject publication.
                    let savedHead = try Data(contentsOf: Storage.threadURL(head.threadID))
                    try FileManager.default.removeItem(at: Storage.turnURL(head.threadID, ids[0]))
                    try require(!DiskWriter.shared.writeThreadSynchronously(ThreadSave(head: head, dirtyTurns: [:])), "missing history was accepted")
                    try require(try Data(contentsOf: Storage.threadURL(head.threadID)) == savedHead, "failed save replaced the head")
                    // A legitimate head shrink may prune only after publishing the new head.
                    head.turnIndex = Array(head.turnIndex!.suffix(1))
                    try require(DiskWriter.shared.writeThreadSynchronously(ThreadSave(head: head, dirtyTurns: [:])), "shrunk head failed")
                    let remaining = try FileManager.default.contentsOfDirectory(atPath: Storage.turnsURL(head.threadID).path)
                    try require(Set(remaining) == [ids.last!.uuidString + ".json"], "obsolete turns were not pruned")
                }
                try emit(["samples": rows, "scope": "synthetic minimal turns; actual DiskWriter, warm filesystem"])
            case "capture": try emit(["tree": try await git.captureTree()])
            case "rebase":
                guard let result = try await git.captureTree(paths: ["f"], onto: a[4], from: a[3]) else { throw ShellError("unexpected preparation conflict") }
                try emit(["tree": result.tree, "source": result.sourceTree])
            case "sync":
                let lease = try await git.repositoryWriteLease()
                defer { withExtendedLifetime(lease) {} }
                try await git.synchronizeCheckout(from: a[3], sourceTree: a[4], to: a[5], branch: "refs/heads/main")
                try emit(["ok": true])
            case "repository": try emit(["isRepository": await git.isRepository()])
            case "query":
                let values: [String]
                switch a[3] {
                case "dirty": values = try await git.dirtyPaths()
                case "ignored": values = Array(try await git.ignoredPaths(among: ["f"]))
                case "tracked": values = Array(try await git.trackedPaths(among: ["f"]))
                default: values = Array(try await git.presentPaths(among: ["f"], in: a[4]))
                }
                try emit(["paths": values])
            case "apply":
                try emit(["conflicts": try await git.apply(String(contentsOfFile: a[3], encoding: .utf8))])
            case "remove": try await git.removeWorktree(at: a[3]); try emit(["ok": true])
            case "filter":
                let result = try await HeadFilter.hydraWork(in: git, from: a[3], to: a[4])
                try emit(["paths": result.paths, "dropped": result.droppedBuildOutputFiles])
            case "build-clean":
                let work = WorktreeUsage(path: directory.path, size: 0, buildFiles: [directory.appendingPathComponent(".build").path], buildFilesSize: 0, changedFiles: 0, isRegistered: true)
                try await Storage.removeBuildFiles(of: work); try emit(["ok": true])
            case "lock":
                let lease = try await git.repositoryWriteLease()
                defer { withExtendedLifetime(lease) {} }
                if a.count > 3 {
                    try Data().write(to: URL(fileURLWithPath: a[3]))
                    let end = ContinuousClock.now.advanced(by: .seconds(15))
                    while !FileManager.default.fileExists(atPath: a[4]) {
                        guard ContinuousClock.now < end else { throw ShellError("fixture lock release timed out") }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
                try emit(["ok": true])
            case "sweep": await Storage.sweepOrphanedAttachments(); try emit(["ok": true])
            case "save-before", "save-during":
                let attachment = try JSONDecoder().decode(Attachment.self, from: Data(contentsOf: directory.appendingPathComponent("attachment.json")))
                var head = ThreadDocument(threadID: UUID())
                head.items = [TimelineItem(id: "saved", attachment: attachment)]
                let snapshot = ThreadSave(head: head, dirtyTurns: [:])
                let written = DispatchSemaphore(value: 0)
                let success = Mutex(false)
                if action == "save-before" {
                    let entered = DispatchSemaphore(value: 0)
                    let release = DispatchSemaphore(value: 0)
                    let blocker = Task.detached { await DiskWriter.shared.performMaintenance { _ in entered.signal(); release.wait() } }
                    _ = await auditWait(entered)
                    DiskWriter.shared.writeThread(snapshot) { ok in success.withLock { $0 = ok }; written.signal() }
                    let sweep = Task.detached { await Storage.sweepOrphanedAttachments() }
                    release.signal()
                    await blocker.value
                    await sweep.value
                } else {
                    CensusGate.enabled.withLock { $0 = true }
                    let sweep = Task.detached { await Storage.sweepOrphanedAttachments() }
                    _ = await auditWait(CensusGate.entered)
                    DiskWriter.shared.writeThread(snapshot) { ok in success.withLock { $0 = ok }; written.signal() }
                    let progressed = await auditWait(written, timeout: .now() + .seconds(3))
                    if progressed { written.signal() }
                    let imported = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        DiskWriter.shared.withFileMutation { imported.signal() }
                    }
                    let importProgressed = await auditWait(imported, timeout: .now() + .seconds(3))
                    CensusGate.resume.signal()
                    await sweep.value
                    try require(progressed && importProgressed, "census blocked writer or synchronous import")
                }
                _ = await auditWait(written)
                try require(success.withLock { $0 }, "queued save failed")
                try require(FileManager.default.fileExists(atPath: attachment.path), "queued reference lost its attachment")
                try emit(["ok": true])
            case "import":
                let imported = try Storage.importAttachment(from: directory.appendingPathComponent("old-source.bin"))
                await Storage.sweepOrphanedAttachments()
                try require(FileManager.default.fileExists(atPath: imported.path), "new import inherited an orphan's age")
                try emit(["ok": true])
            case "claims":
                let active = UUID(), removed = UUID(), helper = UUID()
                CheckoutClaims.claim(["live"], root: directory.path, owner: active)
                CheckoutClaims.ageForFixture(owner: active)
                CheckoutClaims.claim(["old"], root: directory.path, owner: removed)
                CheckoutClaims.retainOwners([active], root: directory.path)
                CheckoutClaims.claim(["late"], root: directory.path, owner: removed)
                let remaining = CheckoutClaims.foreign(["live", "old", "late"], root: directory.path, owner: UUID(), since: .distantPast)
                try require(remaining == ["live"], "deleted owner remained or live owner expired")
                CheckoutClaims.deactivate(owner: helper)
                try require(CheckoutClaims.othersActive(root: directory.path, owner: helper, since: .distantPast), "archiving helper revoked parent's work")
                CheckoutClaims.activate(owner: removed)
                CheckoutClaims.claim(["restored"], root: directory.path, owner: removed)
                try require(CheckoutClaims.foreign(["restored"], root: directory.path, owner: active, since: .distantPast) == ["restored"], "unarchive did not permit new claims")
                CheckoutClaims.deactivate(owner: active)
                CheckoutClaims.claim(["late-active"], root: directory.path, owner: active)
                try require(CheckoutClaims.foreign(["live", "late-active"], root: directory.path, owner: removed, since: .distantPast).isEmpty, "archive admitted a late callback")
                try emit(["ok": true])
            default: throw ShellError("unknown fixture action")
            }
        } catch {
            try? emit(["error": error.localizedDescription])
            exit(1)
        }
    }
}
'''


def build_source():
    sources = set()

    def decl(path, marker):
        sources.add(path)
        return declaration(path, marker)

    def whole(path):
        sources.add(path)
        return (ROOT / path).read_text()

    methods = [
        "    func repositoryWriteLease(", "    func output(", "    static func check(",
        "    func isRepository(", "    func hasCommits(", "    func captureTree(paths: [String])",
        "    func captureTree(paths: [String], onto", "    private func blobData(",
        "    private func fileMode(", "    func treeHash(", "    func commitHash(",
        "    func updateRef(_ ref: String, to commit: String) async", "    func changedPaths(",
        "    func dirtyPaths(", "    func ignoredPaths(", "    func trackedPaths(",
        "    func presentPaths(", "    private static func nulSeparated(",
        "    func synchronizeCheckout(", "    func captureTree()", "    func diff(from:",
        "    func removeWorktree(", "    func apply(_ patch:",
    ]
    git_methods = "\n".join(decl(GIT, marker) for marker in methods)
    # Foundation may ignore TMPDIR on macOS. Relocate only scratch-index storage.
    git_methods = git_methods.replace("fileManager.temporaryDirectory", 'Audit.root.appendingPathComponent("tmp")')
    git_methods += "\n" + next(line for line in (ROOT / GIT).read_text().splitlines() if "private static let diffPathChunk =" in line)
    sweep = decl(STORE, "    nonisolated static func sweepOrphanedAttachments(")
    # The sole behavioral observation hook pauses after census, before any deletion.
    # It is absent from product source and does not replace the writer or its queue.
    needle = "            let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)"
    if sweep.count(needle) != 1:
        raise ValueError("attachment census hook moved; update fixture deliberately")
    sweep = sweep.replace(needle, "            CensusGate.pauseIfRequested()\n" + needle)
    storage = "\n".join(decl(STORE, marker) for marker in (
        "    nonisolated static func turnsURL(", "    nonisolated static func turnURL(",
        "    nonisolated static func unreadableFolder(", "    static func importAttachment(from",
        "    static func importAttachment(data:")) + "\n" + sweep
    usage = "Tivano/Services/Store/StorageUsage.swift"
    usage_text = whole(usage)
    names_start = usage_text.index("    static let buildFolderNames:")
    names_end = usage_text.index("\n    ]", names_start) + len("\n    ]")
    storage += "\n" + usage_text[names_start:names_end] + "\n" + decl(usage, "    nonisolated static func removeBuildFiles(")
    models = whole("Tivano/Core/Support/Coding.swift")
    models += "\n" + "\n".join(decl(TIMELINE, marker) for marker in (
        "struct ContextUsage:", "struct ThreadTurnReference:", "struct ThreadDocument:"))
    models += "\n" + "\n".join(decl(STORE, marker) for marker in (
        "private struct StoredContinuation:", "struct StoredTurn:", "private struct StoredTurnFile:", "struct ThreadSave:"))
    models += "\n" + decl(usage, "struct WorktreeUsage:")
    models += "\n" + "\n".join(decl("Tivano/Core/Support/Shell.swift", marker) for marker in ("struct ShellResult:", "struct ShellError:"))
    locks = whole("Tivano/Core/Support/SharedLibraryLease.swift")
    lock_url = whole("Tivano/Core/Support/SharedResourceLock.swift")
    location = "FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]"
    if lock_url.count(location) != 1:
        raise ValueError("resource lock path changed; isolation adapter needs review")
    locks += "\n" + lock_url.replace(location, 'Audit.root.appendingPathComponent("support")')
    filter_method = decl("Tivano/App/AppModel+Hydra.swift", "    private static func hydraWork(in copyGit:")
    touched = whole("Tivano/Services/Git/TouchedPaths.swift")
    # The unused matches helper requires DiffFile; a leaf stub keeps the real file intact.
    touched += '\nstruct DiffFile { var path: String; var oldPath: String? }\n'
    replacements = {
        "GIT_METHODS": git_methods, "STORE_METHODS": storage, "MODELS": models,
        "DISK_WRITER": decl(STORE, "final class DiskWriter:"),
        "CLAIMS": whole("Tivano/Core/Support/CheckoutClaims.swift"), "LOCKS": locks,
        "HEAD_FILTER": filter_method.replace("private static func", "static func", 1),
        "TOUCHED_PATHS": touched,
    }
    result = SWIFT_SUPPORT
    for key, value in replacements.items():
        result = result.replace("/* " + key + " */", value)
    return result, sorted(sources)


class Fixtures:
    def __init__(self, output, binary, git, env, record):
        self.output, self.binary, self.git_executable, self.env, self.record = output, binary, git, env, record

    def run(self, argv, cwd, expected=0, fault="", timeout=45):
        cwd = cwd.resolve()
        if self.output not in cwd.parents:
            raise ValueError("refusing command outside fixture artifacts")
        env = dict(self.env, AUDIT_FAULT=fault)
        result = subprocess.run([str(x) for x in argv], cwd=cwd, env=env, capture_output=True, timeout=timeout)
        self.record["commands"].append({"argv": [str(x) for x in argv], "cwd": str(cwd), "fault": fault,
                                        "exit": result.returncode, "stdout": result.stdout.decode(errors="replace"),
                                        "stderr": result.stderr.decode(errors="replace")})
        if (expected == 0 and result.returncode != 0) or (expected != 0 and result.returncode == 0):
            raise AssertionError(f"unexpected exit {result.returncode}: {argv}\n{result.stdout.decode(errors='replace')}\n{result.stderr.decode(errors='replace')}")
        return result.stdout.decode().strip()

    def git(self, repo, *args):
        return self.run([self.git_executable, *args], repo)

    def app(self, repo, action, *args, expected=0, fault=""):
        return json.loads(self.run([self.binary, action, repo, *args], repo, expected, fault))

    def seed(self, case):
        repo = Path(tempfile.mkdtemp(prefix=case + "-", dir=self.output / "repos"))
        self.git(repo, "init", "--initial-branch=main", "--template=")
        self.git(repo, "config", "user.name", "Data safety fixture")
        self.git(repo, "config", "user.email", "fixture@example.invalid")
        self.git(repo, "config", "core.fileMode", "true")
        for name, data in {"f": lines(), "u": "untouched\n", "gone": "delete me\n", "old-name": "rename me\n"}.items():
            (repo / name).write_text(data)
        (repo / "binary").write_bytes(bytes(range(256)))
        (repo / "mode").write_text("#!/bin/sh\nexit 0\n")
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-m", "base")
        return repo, self.git(repo, "rev-parse", "HEAD")

    def sync_fixture(self, case):
        repo, head = self.seed(case)
        own = lines({2: "team"})
        (repo / "f").write_text(own)
        source = self.app(repo, "capture")["tree"]
        self.git(repo, "checkout", "-b", "remote-result")
        (repo / "f").write_text(lines({2: "team", 12: "remote"}))
        if case == "file-shapes":
            (repo / "binary").write_bytes(b"\0new binary\xff")
            (repo / "mode").chmod(0o755)
            (repo / "gone").unlink()
            (repo / "old-name").rename(repo / "new-name")
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-m", "remote result")
        remote = self.git(repo, "rev-parse", "HEAD")
        self.git(repo, "checkout", "main")
        late = lines({2: "team", 12 if case == "sync-overlap" else 18: "user-late"})
        (repo / "f").write_text(late)
        if case == "staged-unrelated":
            (repo / "u").write_text("user staged\n")
            self.git(repo, "add", "u")
        if case == "staged-overlap":
            self.git(repo, "add", "f")
        index_before = (repo / ".git/index").read_bytes()
        fail = case in {"sync-overlap", "staged-overlap", "before-ref", "after-ref"}
        self.app(repo, "sync", head, source, remote, expected=int(fail), fault=case if case.endswith("-ref") else "")
        if fail:
            expected_head = remote if case == "after-ref" else head
            assert self.git(repo, "rev-parse", "HEAD") == expected_head
            assert (repo / ".git/index").read_bytes() == index_before
            journals = list((repo / ".git/tivano-recovery").glob("*/index.before"))
            assert journals and journals[0].read_bytes() == index_before
            if case != "staged-overlap":
                recovery = journals[0].parent
                manifest = json.loads((recovery / "recovery.json").read_text())
                assert (recovery / "sync.patch").stat().st_size > 0
                assert (recovery / "index.after").exists()
                assert self.git(repo, "show", manifest["recoveryRef"] + "/working:f") + "\n" == late
            assert "user-late" in (repo / "f").read_text()
            if case == "sync-overlap":
                assert (repo / "f").read_text() == late
            if case == "staged-overlap":
                assert (repo / "f").read_text() == late
        else:
            assert not self.git(repo, "for-each-ref", "--format=%(refname)", "refs/tivano/recovery")
            assert not list((repo / ".git/tivano-recovery").glob("*/index.before"))
            assert self.git(repo, "rev-parse", "HEAD") == remote
            assert (repo / "f").read_text() == lines({2: "team", 12: "remote", 18: "user-late"})
            if case == "staged-unrelated":
                assert self.git(repo, "show", ":u") == "user staged"
                assert self.git(repo, "diff", "--cached", "--name-only") == "u"
            if case == "file-shapes":
                assert (repo / "binary").read_bytes() == b"\0new binary\xff"
                assert (repo / "mode").stat().st_mode & 0o111
                assert not (repo / "gone").exists() and not (repo / "old-name").exists()
                assert (repo / "new-name").read_text() == "rename me\n"

    def case(self, name):
        if name in {"sync-nonoverlap", "sync-overlap", "staged-unrelated", "staged-overlap", "file-shapes", "before-ref", "after-ref"}:
            return self.sync_fixture(name)
        repo, head = self.seed(name)
        if name == "thread-save-scale":
            result = self.app(repo, "save-scale")
            (self.output / "save-scale.json").write_text(json.dumps(result, indent=2))
        elif name == "capture-rebase":
            self.git(repo, "checkout", "-b", "upstream")
            (repo / "f").write_text(lines({12: "remote"}))
            self.git(repo, "commit", "-am", "remote")
            remote = self.git(repo, "rev-parse", "HEAD")
            self.git(repo, "checkout", "main")
            (repo / "f").write_text(lines({2: "team"}))
            captured = self.app(repo, "rebase", head, remote)
            assert self.git(repo, "show", captured["source"] + ":f") + "\n" == lines({2: "team"})
            assert self.git(repo, "show", captured["tree"] + ":f") + "\n" == lines({2: "team", 12: "remote"})
        elif name == "unborn-head":
            self.git(repo, "checkout", "--orphan", "unborn")
            assert self.app(repo, "query", "tracked")["paths"] == ["f"]
            self.git(repo, "rm", "--cached", "f")
            assert self.app(repo, "query", "tracked")["paths"] == []
        elif name == "non-repository":
            folder = repo / "plain-folder"
            folder.mkdir()
            isolated = self.output / "non-git-folder"
            isolated.mkdir()
            assert not self.app(isolated, "repository")["isRepository"]
        elif name == "apply-success":
            (repo / "f").write_text(lines({2: "patch"}))
            patch = self.git(repo, "diff", "--binary") + "\n"
            patchfile = self.output / "success.patch"
            patchfile.write_text(patch)
            (repo / "f").write_text(lines({4: "user"}))
            assert self.app(repo, "apply", patchfile)["conflicts"] == []
            assert (repo / "f").read_text() == lines({2: "patch", 4: "user"})
            assert not self.git(repo, "for-each-ref", "--format=%(refname)", "refs/tivano/recovery")
        elif name == "invalid-ref":
            self.app(repo, "query", "present", "refs/heads/absent", expected=1)
        elif name.startswith("query-"):
            fault = name.removeprefix("query-")
            query = {"status": "dirty", "check-ignore": "ignored", "ls-files": "tracked"}.get(fault, "present")
            self.app(repo, "query", query, "HEAD", expected=1, fault=fault)
        elif name == "apply-failure":
            (repo / "f").write_text(lines({2: "patch"}))
            patch = self.git(repo, "diff", "--binary") + "\n"
            (repo / "change.patch").write_text(patch)
            (repo / "f").write_text(lines({18: "user"}))
            self.app(repo, "apply", repo / "change.patch", expected=1, fault="apply")
            refs = self.git(repo, "for-each-ref", "--format=%(refname)", "refs/tivano/recovery").splitlines()
            saved = next(ref for ref in refs if ref.endswith("/before-apply"))
            assert self.git(repo, "show", saved + ":f") + "\n" == lines({18: "user"})
            assert (repo / "f").read_text() == lines({18: "user"})
        elif name == "tracked-artifacts":
            (repo / ".gitignore").write_text(".build/\n.swiftpm/\n")
            for path in [".swiftpm/config", ".commandcode/state", "keep.noindex/source", ".build/config"]:
                destination = repo / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text("tracked\n")
                self.git(repo, "add", "-f", path)
            self.git(repo, "add", ".gitignore")
            self.git(repo, "commit", "-m", "tracked cache-like source")
            base = self.git(repo, "rev-parse", "HEAD^{tree}")
            (repo / ".swiftpm/config").write_text("changed\n")
            (repo / ".commandcode/state").unlink()
            (repo / "keep.noindex/source").write_text("changed\n")
            (repo / ".swiftpm/new").write_text("new tracked\n")
            self.git(repo, "add", "-f", ".swiftpm/new")
            (repo / "keep.noindex/cache").write_text("untracked cache\n")
            after = self.app(repo, "capture")["tree"]
            paths = set(self.app(repo, "filter", base, after)["paths"])
            assert paths == {".swiftpm/config", ".commandcode/state", "keep.noindex/source", ".swiftpm/new"}
            self.app(repo, "build-clean")
            assert (repo / ".build/config").read_text() == "tracked\n"
        elif name in {"dirty-worktree", "repository-lock"}:
            linked = repo.parent / (repo.name + "-linked")
            self.git(repo, "worktree", "add", "--detach", linked, head)
            if name == "dirty-worktree":
                (linked / "f").write_text("unpreserved edit\n")
                self.app(repo, "remove", linked, expected=1)
                assert (linked / "f").read_text() == "unpreserved edit\n"
            else:
                ready, release = repo / "ready", repo / "release"
                with (repo / "holder.log").open("w") as log:
                    holder = subprocess.Popen([str(self.binary), "lock", str(repo), str(ready), str(release)], cwd=repo, env=self.env, stdout=log, stderr=subprocess.STDOUT)
                    try:
                        deadline = time.monotonic() + 10
                        while not ready.exists() and holder.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.02)
                        assert ready.exists(), "lock holder did not start"
                        self.app(linked, "lock", expected=1)
                        release.touch()
                        assert holder.wait(timeout=10) == 0
                        self.app(linked, "lock")
                    finally:
                        if holder.poll() is None:
                            holder.kill()
                            holder.wait()
        elif name == "claims":
            self.app(repo, "claims")
        else:
            threads, attachments = repo / "threads", repo / "attachments"
            threads.mkdir(); attachments.mkdir()
            thread_id, turn_id, attachment_id = (str(uuid.uuid4()).upper() for _ in range(3))
            attachment = attachments / (attachment_id + ".bin")
            attachment.write_bytes(b"old attachment")
            os.utime(attachment, (1, 1))
            item = {"id": "attachment", "attachment": {"id": attachment_id, "name": "old", "path": str(attachment), "mimeType": "application/octet-stream"}}
            (repo / "attachment.json").write_text(json.dumps(item["attachment"]))
            document = threads / (thread_id + ".json")
            if name == "attachments-bad-json":
                document.write_text("{")
            elif name == "attachments-bad-schema":
                document.write_text(json.dumps({"threadID": 7}))
            elif name in {"attachments-missing-turn", "attachments-missing-revision", "attachments-wrong-turn-id"}:
                document.write_text(json.dumps({"threadID": thread_id, "turnIndex": [{"id": turn_id, "revision": 2}]}))
                if name != "attachments-missing-turn":
                    folder = threads / (thread_id + ".turns"); folder.mkdir()
                    revision = "1" if name.endswith("revision") else "2"
                    stored_id = str(uuid.uuid4()) if name.endswith("turn-id") else turn_id
                    (folder / (turn_id + ".json")).write_text(json.dumps({"revisions": {revision: {"turn": {"id": stored_id}, "items": [], "itemPositions": {}}}}))
            elif name == "attachments-unreadable":
                folder = threads / "Unreadable"; folder.mkdir()
                (folder / "original.bad").write_text("quarantined non-JSON history")
            elif name == "attachments-orphan":
                document.write_text(json.dumps({"threadID": thread_id, "items": [item]}))
                orphan = attachments / (str(uuid.uuid4()).upper() + ".bin")
                orphan.write_bytes(b"orphan"); os.utime(orphan, (1, 1))
            elif name == "attachment-import":
                (repo / "old-source.bin").write_bytes(b"source")
                os.utime(repo / "old-source.bin", (1, 1))
                self.app(repo, "import")
                return
            action = {"attachments-save-before": "save-before", "attachments-save-during": "save-during"}.get(name, "sweep")
            self.app(repo, action)
            assert attachment.exists(), "referenced or uncertain attachment was deleted"
            if name == "attachments-orphan":
                assert not orphan.exists(), "healthy orphan was not deleted"


def lines(changes=None):
    changes = changes or {}
    return "".join(changes.get(i, f"line-{i}") + "\n" for i in range(24))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path, nargs="?", help="fresh external directory; defaults to mkdtemp")
    parser.add_argument("--git", help="Git with cat-file -Z support")
    parser.add_argument("--case", choices=CASES)
    args = parser.parse_args()
    if sys.flags.optimize:
        parser.error("run without -O or PYTHONOPTIMIZE; fixture assertions must remain enabled")
    output = args.artifacts.expanduser().resolve() if args.artifacts else Path(tempfile.mkdtemp(prefix="tivano-data-safety-")).resolve()
    if output == ROOT or ROOT in output.parents or (args.artifacts and output.exists()):
        parser.error("use a fresh artifact directory outside the checkout")
    output.mkdir(parents=True, exist_ok=not bool(args.artifacts), mode=0o700)
    for name in ("repos", "home", "tmp", "config"):
        (output / name).mkdir(mode=0o700)
    git = Path(args.git or shutil.which("git") or "/usr/bin/git").resolve()
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(output / "home"),
           "TMPDIR": str(output / "tmp") + "/", "XDG_CONFIG_HOME": str(output / "config"),
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
           "GIT_ATTR_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
           "AUDIT_ROOT": str(output), "AUDIT_GIT": str(git), "LC_ALL": "C"}
    source, inputs = build_source()
    generated = output / "DataSafety.swift"
    generated.write_text(source)
    binary = output / "data-safety-checks"
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-j", "4",
               "-target", arch + "-apple-macosx15.0", "-module-cache-path", str(output / "ModuleCache"),
               str(generated), "-o", str(binary)]
    record = {"scope": "extracted production safety methods, real Git, actual DiskWriter queue; not App end-to-end",
              "adaptations": ["Git.run process transport with explicit fault injection", "lock support root and temporary Git indexes relocated to AUDIT_ROOT",
                              "one pause hook after attachment census", "head filter access widened for fixture",
                              "fixture-only CheckoutClaims extension dates a live claim to 1970",
                              "provider/UI leaf models and library/prefetch dependencies stubbed"],
              "sources": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in inputs},
              "generated_sha256": hashlib.sha256(source.encode()).hexdigest(),
              "compile_command": command, "cases": [], "commands": []}

    def save():
        (output / "results.json").write_text(json.dumps(record, indent=2) + "\n")

    save()
    try:
        with (output / "compile.log").open("w") as log:
            result = subprocess.run(command, cwd=output, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as error:
        record["compile_error"] = str(error)
        save()
        print(f"FAIL compiling extracted source: {error}; evidence: {output}", file=sys.stderr)
        return 1
    record["compile_exit"] = result.returncode
    save()
    if result.returncode:
        print(f"FAIL compiling extracted source: {output / 'compile.log'}", file=sys.stderr)
        return 1
    fixtures = Fixtures(output, binary, git, env, record)
    for case in (args.case,) if args.case else CASES:
        try:
            fixtures.case(case)
            record["cases"].append({"name": case, "pass": True})
        except Exception as error:
            record["cases"].append({"name": case, "pass": False, "error": str(error)})
        save()
    passed = all(case["pass"] for case in record["cases"])
    print(f"{'PASS' if passed else 'FAIL'}: {len(record['cases'])} cases; evidence: {output}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
