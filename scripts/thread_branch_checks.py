#!/usr/bin/env python3
"""Offline checks for ThreadBranch.slice(_:at:), ThreadBranchOrigin Codable round-trip,
legacy ChatThread decoding, and randomized slice invariants.

Compiles production Core sources directly with swiftc into a temporary directory;
no App launch, network, Keychain or user data is touched.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

CORE_SOURCES = (
    "Tivano/Core/Models/ThreadBranch.swift",
    "Tivano/Core/Models/Timeline.swift",
    "Tivano/Core/Models/Library.swift",
    "Tivano/Core/Models/FileChangeSummary.swift",
    "Tivano/Core/Models/TokenSpend.swift",
    "Tivano/Core/Models/ThreadContinuation.swift",
    "Tivano/Core/Models/LocalControl.swift",
    "Tivano/Core/Models/ProviderAccount.swift",
    "Tivano/Core/Models/Chimera.swift",
    "Tivano/Core/Models/Hydra2.swift",
    "Tivano/Core/Models/Provider.swift",
    "Tivano/Core/Models/DshAgentMode.swift",
    "Tivano/Core/Models/ZaiRegion.swift",
    "Tivano/Core/Support/Coding.swift",
    "Tivano/Core/Support/Text.swift",
    "Tivano/Core/Support/JSONValue.swift",
    "Tivano/Core/Support/CaptureRun.swift",
    "Tivano/Core/Support/PermissionLowering.swift",
)

SHIMS_SWIFT = r'''import Foundation

struct HydraPair: Codable, Hashable, Sendable {
    var id = UUID()
}

struct HydraHeadInfo: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case running
        case completed
        case failed
        case stopped
    }

    var targetCheckout: String?
}

struct HydraLaunch: Sendable {
    var isChimera = false
    var chimeraPresets: [String] = []
    var chimeraAutoDispatch = false
}

enum HydraPrompts {
    static func v2Policy(_ launch: HydraLaunch) -> String { "" }
    static func withoutDelegationBlock(_ text: String) -> String { text }
}
'''


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def strip_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    source = re.sub(r"//[^\n]*", "", source)
    return source


def extract_braced(source: str, marker: str, label: str) -> str:
    count = source.count(marker)
    if count != 1:
        fail(f"{label}: expected marker {marker!r} once, found {count}")
    start = source.index(marker)
    opening = source.find("{", start)
    if opening < 0:
        fail(f"{label}: marker {marker!r} has no opening brace")
    depth = 0
    for index in range(opening, len(source)):
        ch = source[index]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    fail(f"{label}: unbalanced braces for {marker!r}")
    return ""


def discover_string_enums(*sources: str) -> dict[str, str]:
    enums: dict[str, str] = {}
    for text in sources:
        clean = strip_comments(text)
        for match in re.finditer(r"\benum\s+([A-Za-z_][A-Za-z0-9_]*)\s*:[^{]*\{", clean):
            name = match.group(1)
            opening = match.end() - 1
            depth = 0
            body_end = -1
            for pos in range(opening, len(clean)):
                if clean[pos] == "{":
                    depth += 1
                elif clean[pos] == "}":
                    depth -= 1
                    if depth == 0:
                        body_end = pos
                        break
            if body_end < 0:
                continue
            body = clean[opening + 1:body_end]
            case_match = re.search(
                r"\bcase\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*=\s*\"([^\"]+)\")?",
                body,
            )
            if case_match and name not in enums:
                enums[name] = case_match.group(2) or case_match.group(1)
    return enums


def build_branch_origin_fixture(branch_text: str, library_text: str) -> str:
    if "struct ThreadBranchOrigin" in branch_text:
        origin_block = extract_braced(branch_text, "struct ThreadBranchOrigin", "ThreadBranch.swift")
    elif "struct ThreadBranchOrigin" in library_text:
        origin_block = extract_braced(library_text, "struct ThreadBranchOrigin", "Library.swift")
    else:
        fail("missing marker 'struct ThreadBranchOrigin' in ThreadBranch.swift and Library.swift")

    clean = strip_comments(origin_block)
    opening = clean.find("{")
    body = clean[opening + 1:-1]
    enums = discover_string_enums(origin_block, branch_text, library_text)

    fields: list[tuple[str, str]] = []
    depth = 0
    lines = body.splitlines()
    for idx, raw_line in enumerate(lines):
        line = raw_line.strip()
        if depth == 0 and line:
            if not re.match(r"^(?:public\s+|internal\s+|private\s+)?static\b", line):
                typed = re.match(
                    r"^(?:public\s+|internal\s+|private\s+)?(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^={]+?)(?:\s*=\s*[^\{]+)?$",
                    line,
                )
                inferred = None if typed else re.match(
                    r"^(?:public\s+|internal\s+|private\s+)?(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^\{]+)$",
                    line,
                )
                next_nonempty = next((l.strip() for l in lines[idx + 1:] if l.strip()), "")
                if typed and not next_nonempty.startswith("{"):
                    fields.append((typed.group(1), typed.group(2).strip()))
                elif inferred and not next_nonempty.startswith("{"):
                    rhs = inferred.group(2).strip()
                    if "UUID(" in rhs:
                        fields.append((inferred.group(1), "UUID"))
                    elif "Date" in rhs or rhs == ".now":
                        fields.append((inferred.group(1), "Date"))
                    elif rhs in ("true", "false"):
                        fields.append((inferred.group(1), "Bool"))
                    elif rhs.startswith('"'):
                        fields.append((inferred.group(1), "String"))
                    elif re.match(r"^-?\d+$", rhs):
                        fields.append((inferred.group(1), "Int"))
                    else:
                        fail(f"ThreadBranchOrigin inferred property {inferred.group(1)} = {rhs!r} has unknown type")
        depth += raw_line.count("{") - raw_line.count("}")

    if not fields:
        fail("could not extract any stored properties from struct ThreadBranchOrigin")

    payload: dict[str, object] = {}
    for index, (name, raw_type) in enumerate(fields, start=1):
        base_type = raw_type.rstrip("?").strip()
        short_type = base_type.split(".")[-1]
        if base_type == "UUID":
            payload[name] = f"11111111-2222-3333-4444-5555555555{index:02x}"
        elif base_type == "String":
            payload[name] = f"sample-{name}"
        elif base_type == "Date":
            payload[name] = "2026-01-15T12:34:56Z"
        elif base_type == "Bool":
            payload[name] = True
        elif base_type in ("Int", "Int64", "UInt64"):
            payload[name] = index
        elif base_type in ("Double", "TimeInterval"):
            payload[name] = 1.5
        elif base_type == "[String]":
            payload[name] = ["sample"]
        elif base_type == "[UUID]":
            payload[name] = [f"11111111-2222-3333-4444-5555555555{index:02x}"]
        elif short_type == "ThreadBranchPoint":
            payload[name] = {"through": {"turnID": f"11111111-2222-3333-4444-5555555555{index:02x}"}}
        elif short_type in enums:
            payload[name] = enums[short_type]
        elif base_type == "ProviderKind":
            payload[name] = "codex"
        else:
            fail(f"unrecognized ThreadBranchOrigin field type: {name}: {raw_type}")

    return json.dumps(payload, sort_keys=True)


MAIN_SWIFT_TEMPLATE = r'''import Foundation
import Darwin

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message) }
}

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func bool(percent: Int = 50) -> Bool {
        Int(next() % 100) < percent
    }

    mutating func uuid() -> UUID {
        let hi = next()
        let lo = next()
        let bytes: uuid_t = (
            UInt8((hi >> 56) & 0xFF), UInt8((hi >> 48) & 0xFF), UInt8((hi >> 40) & 0xFF), UInt8((hi >> 32) & 0xFF),
            UInt8((hi >> 24) & 0xFF), UInt8((hi >> 16) & 0xFF), UInt8(((hi >> 8) & 0x0F) | 0x40), UInt8(hi & 0xFF),
            UInt8(((lo >> 56) & 0x3F) | 0x80), UInt8((lo >> 48) & 0xFF), UInt8((lo >> 40) & 0xFF), UInt8((lo >> 32) & 0xFF),
            UInt8((lo >> 24) & 0xFF), UInt8((lo >> 16) & 0xFF), UInt8((lo >> 8) & 0xFF), UInt8(lo & 0xFF)
        )
        return UUID(uuid: bytes)
    }
}

func makeThreeTurnDocument(withIndex: Bool = true, withPositions: Bool = true) -> (doc: ThreadDocument, turns: [UUID]) {
    let baseDate = Date(timeIntervalSince1970: 1_760_000_000)
    let t0 = UUID(), t1 = UUID(), t2 = UUID()
    var doc = ThreadDocument(threadID: UUID())
    doc.continuation = ThreadContinuation(sourceThreadID: UUID(), sourceTitle: "Earlier", context: "forwarded context")

    let u0 = TimelineItem(id: "u0", turnID: t0, date: baseDate.addingTimeInterval(1), content: .user(UserMessage(text: "First question")))
    let r0 = TimelineItem(id: "r0", turnID: t0, date: baseDate.addingTimeInterval(2), content: .reasoning(ReasoningBlock(text: "Think 0", isStreaming: false)))
    let tool0 = TimelineItem(id: "tool0", turnID: t0, date: baseDate.addingTimeInterval(3), content: .tool(ToolCall(kind: .command, title: "ls", detail: nil, output: "README.md", status: .completed)))
    let a0 = TimelineItem(id: "a0", turnID: t0, date: baseDate.addingTimeInterval(4), content: .assistant(AssistantMessage(text: "First answer", isStreaming: false)))
    let e0 = TimelineItem(id: "e0", turnID: t0, date: baseDate.addingTimeInterval(5), content: .turnEnd(TurnSummary(turnID: t0, status: .completed, duration: 4, filesChanged: 0, additions: 0, deletions: 0, changes: nil)))

    let u1 = TimelineItem(id: "u1", turnID: t1, date: baseDate.addingTimeInterval(11), content: .user(UserMessage(text: "Second question")))
    let tool1 = TimelineItem(id: "tool1", turnID: t1, date: baseDate.addingTimeInterval(12), content: .tool(ToolCall(kind: .edit, title: "edit App.swift", detail: "App.swift", output: "applied", status: .completed, edits: [FileEdit(path: "App.swift", diff: "+let x = 1", additions: 1, deletions: 0)])))
    let a1 = TimelineItem(id: "a1", turnID: t1, date: baseDate.addingTimeInterval(13), content: .assistant(AssistantMessage(text: "Second answer", isStreaming: false)))
    let e1 = TimelineItem(id: "e1", turnID: t1, date: baseDate.addingTimeInterval(14), content: .turnEnd(TurnSummary(turnID: t1, status: .completed, duration: 3, filesChanged: 1, additions: 1, deletions: 0, changes: nil)))

    let u2 = TimelineItem(id: "u2", turnID: t2, date: baseDate.addingTimeInterval(21), content: .user(UserMessage(text: "Third question")))
    let a2 = TimelineItem(id: "a2", turnID: t2, date: baseDate.addingTimeInterval(22), content: .assistant(AssistantMessage(text: "Third answer", isStreaming: false)))
    let e2 = TimelineItem(id: "e2", turnID: t2, date: baseDate.addingTimeInterval(23), content: .turnEnd(TurnSummary(turnID: t2, status: .completed, duration: 2, filesChanged: 0, additions: 0, deletions: 0, changes: nil)))

    doc.turns = [
        TurnRecord(id: t0, index: 0, startedAt: baseDate.addingTimeInterval(1), completedAt: baseDate.addingTimeInterval(5), status: .completed, userItemID: "u0", providerAnchor: "anchor-0"),
        TurnRecord(id: t1, index: 1, startedAt: baseDate.addingTimeInterval(11), completedAt: baseDate.addingTimeInterval(14), status: .completed, userItemID: "u1", providerAnchor: "anchor-1"),
        TurnRecord(id: t2, index: 2, startedAt: baseDate.addingTimeInterval(21), completedAt: baseDate.addingTimeInterval(23), status: .completed, userItemID: "u2", providerAnchor: "anchor-2"),
    ]
    doc.items = [u0, r0, tool0, a0, e0, u1, tool1, a1, e1, u2, a2, e2]
    if withIndex {
        doc.turnIndex = [
            ThreadTurnReference(id: t0, revision: 1),
            ThreadTurnReference(id: t1, revision: 2),
            ThreadTurnReference(id: t2, revision: 3),
        ]
    }
    if withPositions {
        var positions: [String: Double] = [:]
        for (idx, item) in doc.items.enumerated() {
            positions[item.id] = Double(idx + 1) * 10.0
        }
        doc.itemPositions = positions
    }
    return (doc, [t0, t1, t2])
}

func assertConsistent(_ sliced: ThreadBranchSlice, original: ThreadDocument, expectedTurns: [TurnRecord], expectedDraft: String?, label: String) throws {
    let expectedTurnIDs = expectedTurns.map(\.id)
    let keptTurnIDSet = Set(expectedTurnIDs)
    let origByID = Dictionary(uniqueKeysWithValues: original.items.map { ($0.id, $0) })

    try require(sliced.document.threadID == original.threadID, "\(label): threadID changed")
    try require(sliced.document.turns == expectedTurns, "\(label): kept turns must equal expected prefix")
    try require(sliced.lastTurn == expectedTurns.last, "\(label): lastTurn mismatch")
    try require(sliced.draft == expectedDraft, "\(label): draft mismatch (got \(String(describing: sliced.draft)), expected \(String(describing: expectedDraft)))")
    try require(sliced.document.continuation == nil, "\(label): continuation must be nil")

    let keptItemIDs = Set(sliced.document.items.map(\.id))
    try require(keptItemIDs.count == sliced.document.items.count, "\(label): duplicate item IDs")
    for item in sliced.document.items {
        if let tid = item.turnID {
            try require(keptTurnIDSet.contains(tid), "\(label): kept item \(item.id) references unkept turn \(tid)")
        }
        try require(origByID[item.id] == item, "\(label): item \(item.id) content or id was mutated")
    }
    for origItem in original.items where origItem.turnID.map({ keptTurnIDSet.contains($0) }) == true {
        try require(keptItemIDs.contains(origItem.id), "\(label): missing item \(origItem.id) from kept turn")
    }

    if let refs = sliced.document.turnIndex {
        try require(refs.map(\.id) == expectedTurnIDs, "\(label): turnIndex ids disagree with kept turns")
        if let origRefs = original.turnIndex {
            try require(refs == Array(origRefs.prefix(expectedTurns.count)), "\(label): turnIndex revisions changed")
        }
    } else if !expectedTurns.isEmpty {
        try require(original.turnIndex == nil, "\(label): non-empty slice dropped turnIndex")
    }

    if let positions = sliced.document.itemPositions {
        try require(Set(positions.keys).isSubset(of: keptItemIDs), "\(label): dangling keys in itemPositions")
        if let origPositions = original.itemPositions {
            for id in keptItemIDs {
                try require(positions[id] == origPositions[id], "\(label): itemPosition changed for \(id)")
            }
        }
    } else if !keptItemIDs.isEmpty {
        try require(original.itemPositions == nil, "\(label): non-empty slice dropped itemPositions")
    }
}

func testFirstMiddleLast() throws {
    let (doc, turns) = makeThreeTurnDocument(withIndex: true, withPositions: true)
    let (t0, t1, t2) = (turns[0], turns[1], turns[2])

    // First turn
    let b0 = try requireSlice(doc, at: .before(turnID: t0), "first .before")
    try assertConsistent(b0, original: doc, expectedTurns: [], expectedDraft: "First question", label: "first .before")
    try require(b0.document.items.isEmpty, "first .before should have no items")

    let th0 = try requireSlice(doc, at: .through(turnID: t0), "first .through")
    try assertConsistent(th0, original: doc, expectedTurns: Array(doc.turns.prefix(1)), expectedDraft: nil, label: "first .through")
    try require(th0.document.items.map(\.id) == ["u0", "r0", "tool0", "a0", "e0"], "first .through item ids")

    // Middle turn
    let b1 = try requireSlice(doc, at: .before(turnID: t1), "middle .before")
    try assertConsistent(b1, original: doc, expectedTurns: Array(doc.turns.prefix(1)), expectedDraft: "Second question", label: "middle .before")
    try require(b1.document.items.map(\.id) == ["u0", "r0", "tool0", "a0", "e0"], "middle .before item ids")

    let th1 = try requireSlice(doc, at: .through(turnID: t1), "middle .through")
    try assertConsistent(th1, original: doc, expectedTurns: Array(doc.turns.prefix(2)), expectedDraft: nil, label: "middle .through")
    try require(th1.document.items.map(\.id) == ["u0", "r0", "tool0", "a0", "e0", "u1", "tool1", "a1", "e1"], "middle .through item ids")
    if case .tool(let call) = th1.document.items.first(where: { $0.id == "tool1" })?.content {
        try require(call.kind == .edit && call.edits.count == 1 && call.edits[0].path == "App.swift", "tool1 edits preserved")
    } else {
        throw CheckFailure("tool1 item missing or wrong content")
    }

    // Last turn
    let b2 = try requireSlice(doc, at: .before(turnID: t2), "last .before")
    try assertConsistent(b2, original: doc, expectedTurns: Array(doc.turns.prefix(2)), expectedDraft: "Third question", label: "last .before")
    try require(b2.document.items.map(\.id) == ["u0", "r0", "tool0", "a0", "e0", "u1", "tool1", "a1", "e1"], "last .before item ids")

    let th2 = try requireSlice(doc, at: .through(turnID: t2), "last .through")
    try assertConsistent(th2, original: doc, expectedTurns: doc.turns, expectedDraft: nil, label: "last .through")
    try require(th2.document.items.map(\.id) == doc.items.map(\.id), "last .through keeps all items")

    // Legacy document without turnIndex / itemPositions
    let (legacy, legacyTurns) = makeThreeTurnDocument(withIndex: false, withPositions: false)
    let lb1 = try requireSlice(legacy, at: .before(turnID: legacyTurns[1]), "legacy middle .before")
    try assertConsistent(lb1, original: legacy, expectedTurns: Array(legacy.turns.prefix(1)), expectedDraft: "Second question", label: "legacy middle .before")
    try require(lb1.document.turnIndex == nil && lb1.document.itemPositions == nil, "legacy keeps nil turnIndex and itemPositions")

    print("PASS first/middle/last both modes, tool items, ids, draft, turnIndex/itemPositions")
}

func requireSlice(_ doc: ThreadDocument, at point: ThreadBranchPoint, _ label: String) throws -> ThreadBranchSlice {
    guard let sliced = ThreadBranch.slice(doc, at: point) else {
        throw CheckFailure("\(label): expected non-nil slice")
    }
    return sliced
}

func testUnknownAndInvalidStates() throws {
    let (base, turns) = makeThreeTurnDocument()
    let unknown = UUID()
    try require(ThreadBranch.slice(base, at: .before(turnID: unknown)) == nil, "unknown id .before must be nil")
    try require(ThreadBranch.slice(base, at: .through(turnID: unknown)) == nil, "unknown id .through must be nil")

    let empty = ThreadDocument(threadID: UUID())
    try require(ThreadBranch.slice(empty, at: .before(turnID: unknown)) == nil, "empty doc .before must be nil")
    try require(ThreadBranch.slice(empty, at: .through(turnID: unknown)) == nil, "empty doc .through must be nil")

    // Running target turn
    var runningTarget = base
    runningTarget.turns[1].status = .running
    try require(ThreadBranch.slice(runningTarget, at: .before(turnID: turns[1])) == nil, "running target .before must be nil")
    try require(ThreadBranch.slice(runningTarget, at: .through(turnID: turns[1])) == nil, "running target .through must be nil")

    // Running earlier kept turn
    try require(ThreadBranch.slice(runningTarget, at: .before(turnID: turns[2])) == nil, "running earlier turn .before must be nil")
    try require(ThreadBranch.slice(runningTarget, at: .through(turnID: turns[2])) == nil, "running earlier turn .through must be nil")

    // Running later unkept turn should not block slicing an earlier completed turn
    let beforeRunning = try requireSlice(runningTarget, at: .through(turnID: turns[0]), "completed before later running turn")
    try assertConsistent(beforeRunning, original: runningTarget, expectedTurns: Array(runningTarget.turns.prefix(1)), expectedDraft: nil, label: "completed before later running")

    // Streaming assistant item on target and earlier kept turns
    var streamingAssistant = base
    let a1Index = streamingAssistant.items.firstIndex { $0.id == "a1" }!
    streamingAssistant.items[a1Index].content = .assistant(AssistantMessage(text: "partial", isStreaming: true))
    try require(ThreadBranch.slice(streamingAssistant, at: .before(turnID: turns[1])) == nil, "streaming assistant on target .before must be nil")
    try require(ThreadBranch.slice(streamingAssistant, at: .through(turnID: turns[1])) == nil, "streaming assistant on target .through must be nil")
    try require(ThreadBranch.slice(streamingAssistant, at: .before(turnID: turns[2])) == nil, "streaming assistant on earlier turn .before must be nil")
    try require(ThreadBranch.slice(streamingAssistant, at: .through(turnID: turns[2])) == nil, "streaming assistant on earlier turn .through must be nil")
    let beforeStream = try requireSlice(streamingAssistant, at: .through(turnID: turns[0]), "completed before later streaming assistant")
    try assertConsistent(beforeStream, original: streamingAssistant, expectedTurns: Array(streamingAssistant.turns.prefix(1)), expectedDraft: nil, label: "completed before later streaming assistant")

    // Streaming reasoning item on target and earlier kept turns
    var streamingReasoning = base
    let r0Index = streamingReasoning.items.firstIndex { $0.id == "r0" }!
    streamingReasoning.items[r0Index].content = .reasoning(ReasoningBlock(text: "thinking...", isStreaming: true))
    try require(ThreadBranch.slice(streamingReasoning, at: .before(turnID: turns[0])) == nil, "streaming reasoning on target .before must be nil")
    try require(ThreadBranch.slice(streamingReasoning, at: .through(turnID: turns[0])) == nil, "streaming reasoning on target .through must be nil")
    try require(ThreadBranch.slice(streamingReasoning, at: .before(turnID: turns[1])) == nil, "streaming reasoning on earlier turn .before must be nil")
    try require(ThreadBranch.slice(streamingReasoning, at: .through(turnID: turns[1])) == nil, "streaming reasoning on earlier turn .through must be nil")

    print("PASS unknown id, running turns, streaming assistant/reasoning items")
}

func testNilTurnIDNotices() throws {
    let (base, turns) = makeThreeTurnDocument(withIndex: true, withPositions: true)
    let baseDate = Date(timeIntervalSince1970: 1_760_000_000)
    var doc = base
    let nEarly = TimelineItem(id: "notice-early", turnID: nil, date: baseDate.addingTimeInterval(0.5), content: .notice(Notice(level: .info, message: "Early notice")))
    let nInsideT0 = TimelineItem(id: "notice-t0", turnID: nil, date: baseDate.addingTimeInterval(2.5), content: .notice(Notice(level: .warning, message: "Mid-turn notice")))
    let nLate = TimelineItem(id: "notice-late", turnID: nil, date: baseDate.addingTimeInterval(30.0), content: .notice(Notice(level: .info, message: "Late notice")))

    var items: [TimelineItem] = [nEarly]
    for item in doc.items {
        items.append(item)
        if item.id == "r0" { items.append(nInsideT0) }
    }
    items.append(nLate)
    doc.items = items
    doc.itemPositions?["notice-early"] = 1.0
    doc.itemPositions?["notice-t0"] = 25.0
    doc.itemPositions?["notice-late"] = 999.0

    let through0 = try requireSlice(doc, at: .through(turnID: turns[0]), "notices .through(t0)")
    try assertConsistent(through0, original: doc, expectedTurns: Array(doc.turns.prefix(1)), expectedDraft: nil, label: "notices .through(t0)")
    let through0IDs = Set(through0.document.items.map(\.id))
    try require(through0IDs.contains("notice-early"), "early nil-turnID notice before cut must be kept")
    try require(through0IDs.contains("notice-t0"), "in-turn nil-turnID notice before cut must be kept")
    try require(!through0IDs.contains("notice-late"), "late nil-turnID notice after cut must be dropped")
    try require(through0.document.itemPositions?["notice-late"] == nil, "late notice position must not dangle")

    let before1 = try requireSlice(doc, at: .before(turnID: turns[1]), "notices .before(t1)")
    try assertConsistent(before1, original: doc, expectedTurns: Array(doc.turns.prefix(1)), expectedDraft: "Second question", label: "notices .before(t1)")
    let before1IDs = Set(before1.document.items.map(\.id))
    try require(before1IDs.contains("notice-early") && before1IDs.contains("notice-t0"), "notices before cut kept in .before")
    try require(!before1IDs.contains("notice-late"), "notice after cut dropped in .before")

    print("PASS nil-turnID notice items before/after cut")
}

func testCodableAndLegacyThread() throws {
    let originJSON = __ORIGIN_JSON__
    let originData = Data(originJSON.utf8)
    let decoded1 = try JSONDecoder.storage.decode(ThreadBranchOrigin.self, from: originData)
    let encoded1 = try JSONEncoder.storage.encode(decoded1)
    let decoded2 = try JSONDecoder.storage.decode(ThreadBranchOrigin.self, from: encoded1)
    let encoded2 = try JSONEncoder.storage.encode(decoded2)
    try require(decoded1 == decoded2, "ThreadBranchOrigin Codable round-trip equality failed")
    try require(encoded1 == encoded2, "ThreadBranchOrigin canonical encoding not stable")

    var thread = ChatThread(projectID: nil, provider: .codex, model: nil, effort: nil, runtimeMode: .supervised)
    let fixedDate = Date(timeIntervalSince1970: 1_768_480_496)
    thread.createdAt = fixedDate
    thread.updatedAt = fixedDate
    thread.branchOrigin = decoded1
    thread.providerForkPending = true
    let encodedThread = try JSONEncoder.storage.encode(thread)
    let decodedThread = try JSONDecoder.storage.decode(ChatThread.self, from: encodedThread)
    try require(decodedThread.id == thread.id, "branched ChatThread id round-trip")
    try require(decodedThread.branchOrigin == decoded1, "ChatThread branchOrigin round-trip")
    try require(decodedThread.providerForkPending == true, "ChatThread providerForkPending round-trip")

    let legacyID = UUID()
    let legacyData = Data("{\"id\":\"\(legacyID.uuidString)\"}".utf8)
    let legacy = try JSONDecoder.storage.decode(ChatThread.self, from: legacyData)
    try require(legacy.id == legacyID, "legacy ChatThread id")
    try require(legacy.branchOrigin == nil, "legacy ChatThread missing branchOrigin must decode nil")
    try require(legacy.providerForkPending == false, "legacy ChatThread missing providerForkPending must decode false")

    print("PASS ThreadBranchOrigin Codable round-trip and legacy ChatThread decoding")
}

func testRandomizedStress(iterations: Int = 2_000) throws {
    var rng = SplitMix64(state: 0x5449_5641_4E4F_0061)
    var validSlices = 0
    var rejectedSlices = 0

    for iteration in 0..<iterations {
        let baseDate = Date(timeIntervalSince1970: 1_760_000_000 + Double(iteration * 1000))
        let turnCount = rng.int(in: 0...12)
        let hasTurnIndex = rng.bool(percent: 65)
        let hasPositions = rng.bool(percent: 65)
        let hasContinuation = rng.bool(percent: 40)

        var doc = ThreadDocument(threadID: rng.uuid())
        if hasContinuation {
            doc.continuation = ThreadContinuation(sourceThreadID: rng.uuid(), sourceTitle: "Prev \(iteration)", context: "ctx-\(iteration)")
        }
        var turnIndex: [ThreadTurnReference] = []
        var positions: [String: Double] = [:]
        var userTexts: [UUID: String] = [:]
        var hasStreamingByTurn: [UUID: Bool] = [:]
        var seq = 0

        func nextDate() -> Date {
            seq += 1
            return baseDate.addingTimeInterval(Double(seq))
        }
        func addItem(_ item: TimelineItem) {
            doc.items.append(item)
            if hasPositions {
                positions[item.id] = Double(seq) * 1.5
            }
        }

        if rng.bool(percent: 30) {
            let nID = "n-pre-\(iteration)-\(seq)"
            addItem(TimelineItem(id: nID, turnID: nil, date: nextDate(), content: .notice(Notice(level: .info, message: "pre"))))
        }

        for k in 0..<turnCount {
            let tid = rng.uuid()
            let statusRoll = rng.int(in: 0...99)
            let status: TurnStatus = statusRoll < 78 ? .completed : (statusRoll < 86 ? .interrupted : (statusRoll < 92 ? .failed : .running))
            let promptText = "prompt-\(iteration)-\(k)"
            userTexts[tid] = promptText
            let userItemID = "u-\(iteration)-\(k)"
            addItem(TimelineItem(id: userItemID, turnID: tid, date: nextDate(), content: .user(UserMessage(text: promptText))))

            var turnStreaming = false
            let extraItems = rng.int(in: 0...4)
            for m in 0..<extraItems {
                let itemID = "i-\(iteration)-\(k)-\(m)"
                let kindRoll = rng.int(in: 0...5)
                let content: TimelineItem.Content
                switch kindRoll {
                case 0:
                    let streaming = rng.bool(percent: 5)
                    if streaming { turnStreaming = true }
                    content = .assistant(AssistantMessage(text: "reply-\(k)-\(m)", isStreaming: streaming))
                case 1:
                    let streaming = rng.bool(percent: 5)
                    if streaming { turnStreaming = true }
                    content = .reasoning(ReasoningBlock(text: "reason-\(k)-\(m)", isStreaming: streaming))
                case 2:
                    let toolStatus: ToolCall.Status = rng.bool(percent: 80) ? .completed : .failed
                    content = .tool(ToolCall(kind: .command, title: "cmd-\(m)", detail: nil, output: "out", status: toolStatus))
                case 3:
                    content = .plan(ProposedPlan(markdown: "plan-\(m)", state: .proposed))
                case 4:
                    content = .todos([TodoStep(text: "step-\(m)", status: .done)])
                default:
                    content = .notice(Notice(level: .info, message: "turn-notice-\(m)"))
                }
                addItem(TimelineItem(id: itemID, turnID: tid, date: nextDate(), content: content))
                if rng.bool(percent: 10) {
                    let nID = "n-mid-\(iteration)-\(k)-\(m)"
                    addItem(TimelineItem(id: nID, turnID: nil, date: nextDate(), content: .notice(Notice(level: .info, message: "mid"))))
                }
            }
            if status != .running && rng.bool(percent: 70) {
                let endID = "e-\(iteration)-\(k)"
                addItem(TimelineItem(id: endID, turnID: tid, date: nextDate(), content: .turnEnd(TurnSummary(turnID: tid, status: status, duration: 1, filesChanged: 0, additions: 0, deletions: 0, changes: nil))))
            }

            hasStreamingByTurn[tid] = turnStreaming
            let record = TurnRecord(id: tid, index: k, startedAt: baseDate.addingTimeInterval(Double(k * 10)), completedAt: status == .running ? nil : baseDate.addingTimeInterval(Double(k * 10 + 5)), status: status, userItemID: userItemID)
            doc.turns.append(record)
            if hasTurnIndex {
                turnIndex.append(ThreadTurnReference(id: tid, revision: UInt64(rng.int(in: 1...9))))
            }
        }

        if rng.bool(percent: 30) {
            let nID = "n-post-\(iteration)-\(seq)"
            addItem(TimelineItem(id: nID, turnID: nil, date: nextDate(), content: .notice(Notice(level: .info, message: "post"))))
        }

        if hasTurnIndex { doc.turnIndex = turnIndex }
        if hasPositions { doc.itemPositions = positions }

        // Unknown turn always yields nil.
        let unknownID = rng.uuid()
        try require(ThreadBranch.slice(doc, at: .before(turnID: unknownID)) == nil, "stress[\(iteration)]: unknown .before")
        try require(ThreadBranch.slice(doc, at: .through(turnID: unknownID)) == nil, "stress[\(iteration)]: unknown .through")

        guard turnCount > 0 else { continue }
        let targetIndex = rng.int(in: 0...(turnCount - 1))
        let targetID = doc.turns[targetIndex].id
        let blocked = (0...targetIndex).contains { idx in
            let turn = doc.turns[idx]
            return turn.status == .running || hasStreamingByTurn[turn.id] == true
        }

        for modeIsBefore in [false, true] {
            let point: ThreadBranchPoint = modeIsBefore ? .before(turnID: targetID) : .through(turnID: targetID)
            let label = "stress[\(iteration)] target=\(targetIndex)/\(turnCount) mode=\(modeIsBefore ? "before" : "through")"
            let result = ThreadBranch.slice(doc, at: point)
            if blocked {
                try require(result == nil, "\(label): expected nil for running/streaming prefix")
                rejectedSlices += 1
                continue
            }
            guard let sliced = result else {
                throw CheckFailure("\(label): expected non-nil slice")
            }
            validSlices += 1
            let expectedCount = modeIsBefore ? targetIndex : targetIndex + 1
            let expectedDraft = modeIsBefore ? userTexts[targetID] : nil
            try assertConsistent(sliced, original: doc, expectedTurns: Array(doc.turns.prefix(expectedCount)), expectedDraft: expectedDraft, label: label)

            // Slice of slice stability
            if let last = sliced.document.turns.last {
                let resliced = try requireSlice(sliced.document, at: .through(turnID: last.id), "\(label): reslice at last")
                try require(resliced.document == sliced.document && resliced.lastTurn == sliced.lastTurn && resliced.draft == nil, "\(label): reslicing at last turn was not stable")

                let earlierIdx = rng.int(in: 0...(sliced.document.turns.count - 1))
                let earlierID = sliced.document.turns[earlierIdx].id
                for subBefore in [false, true] {
                    let subPoint: ThreadBranchPoint = subBefore ? .before(turnID: earlierID) : .through(turnID: earlierID)
                    let nested = try requireSlice(sliced.document, at: subPoint, "\(label): nested slice")
                    let direct = try requireSlice(doc, at: subPoint, "\(label): direct slice")
                    try require(nested.document == direct.document && nested.lastTurn == direct.lastTurn && nested.draft == direct.draft, "\(label): slice(slice(doc)) diverged from slice(doc)")
                }
            }
        }
    }

    try require(validSlices > 0 && rejectedSlices > 0, "stress test must exercise both valid (\(validSlices)) and rejected (\(rejectedSlices)) slices")
    print("PASS randomized stress (\(iterations) docs, \(validSlices) valid slices, \(rejectedSlices) rejected slices)")
}

do {
    try testFirstMiddleLast()
    try testUnknownAndInvalidStates()
    try testNilTurnIDNotices()
    try testCodableAndLegacyThread()
    try testRandomizedStress(iterations: 2_000)
    print("OK: thread branch slice and Codable checks passed")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
'''


def main() -> int:
    if sys.flags.optimize:
        fail("run without -O or PYTHONOPTIMIZE; assertions must remain enabled")

    for rel in CORE_SOURCES:
        if not (ROOT / rel).is_file():
            fail(f"missing required source file: {rel}")

    branch_text = (ROOT / "Tivano/Core/Models/ThreadBranch.swift").read_text(encoding="utf-8")
    library_text = (ROOT / "Tivano/Core/Models/Library.swift").read_text(encoding="utf-8")

    for marker in (
        "enum ThreadBranchPoint",
        "case before(turnID: UUID)",
        "case through(turnID: UUID)",
        "enum ThreadBranchFailure",
        "struct ThreadBranchSlice",
        "enum ThreadBranch",
        "static func slice(",
    ):
        if marker not in branch_text:
            fail(f"Tivano/Core/Models/ThreadBranch.swift: missing required marker {marker!r}")

    for marker in ("branchOrigin", "providerForkPending"):
        if marker not in library_text:
            fail(f"Tivano/Core/Models/Library.swift: missing required marker {marker!r}")

    origin_json = build_branch_origin_fixture(branch_text, library_text)
    main_swift = MAIN_SWIFT_TEMPLATE.replace("__ORIGIN_JSON__", json.dumps(origin_json))

    try:
        swiftc = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True, timeout=30).strip()
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True, timeout=30).strip()
    except (OSError, subprocess.SubprocessError) as error:
        fail(f"could not locate swiftc / macOS SDK via xcrun: {error}")

    with tempfile.TemporaryDirectory(prefix="tivano-thread-branch-checks-") as temp:
        directory = Path(temp)
        shims_path = directory / "Shims.swift"
        main_path = directory / "main.swift"
        binary = directory / "thread-branch-checks"
        shims_path.write_text(SHIMS_SWIFT, encoding="utf-8")
        main_path.write_text(main_swift, encoding="utf-8")

        compile_cmd = [
            swiftc,
            "-swift-version", "6",
            "-sdk", sdk,
            "-j", "4",
            "-module-cache-path", str(directory / "ModuleCache"),
            *[str(ROOT / path) for path in CORE_SOURCES],
            str(shims_path),
            str(main_path),
            "-o", str(binary),
        ]
        compiled = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True, text=True, timeout=120)
        if compiled.returncode != 0:
            detail = (compiled.stderr or compiled.stdout).strip()
            fail(f"swiftc failed (exit {compiled.returncode}):\n{detail}")

        run = subprocess.run([str(binary)], cwd=directory, capture_output=True, text=True, timeout=60)
        if run.stdout:
            print(run.stdout, end="")
        if run.stderr:
            print(run.stderr, end="", file=sys.stderr)
        if run.returncode != 0:
            fail(f"compiled thread-branch-checks exited with status {run.returncode}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
