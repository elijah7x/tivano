#!/usr/bin/env python3
"""Offline guard: ACP automatic permission approval and ephemeral runner approval policy.

`ACPSession.automaticOption(for:options:)` auto-approves read-only tools (`.read`, `.search`)
alongside `.edit` under `.autoAcceptEdits`, while keeping `.command`, `.web`, `.mcp`, `.agent`
and `.other` gated for explicit approval, honoring `configuration.deniesShell` for `.command`
even under `.fullAccess`, and denying automatic approval under `.supervised`.
`EphemeralAgentRunner.approvalOptionID(for:)` continues to approve only `.fileChange` and
decline/cancel `.command`, `.tool`, `.permissions`, and `.plan`.

Both functions are extracted verbatim from their Swift sources (failing loudly on missing
markers or parse errors) and compiled into a minimal Swift test program to verify behavior.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ACP = ROOT / 'Tivano/Services/Providers/ACPSession.swift'
EPHEMERAL = ROOT / 'Tivano/App/Control/EphemeralAgentRunner.swift'

HANDLE_REQUEST_MARKER = 'private func handleRequest(_ id: RPCID, _ method: String, _ params: JSONValue)'
AUTOMATIC_OPTION_MARKER = 'private func automaticOption(for kind: ToolCall.Kind, options: [JSONValue]) -> String?'
DSH_KIND_MARKER = 'private static func dshKind(_ title: String?) -> ToolCall.Kind'
APPROVAL_OPTION_MARKER = 'private static func approvalOptionID(for request: ApprovalRequest) -> String'

SWIFT_TEMPLATE = r'''import Foundation

struct ToolCall {
    enum Kind: String, CaseIterable {
        case command
        case read
        case edit
        case search
        case web
        case mcp
        case agent
        case other
    }
}

enum RuntimeMode {
    case supervised
    case autoAcceptEdits
    case auto
    case fullAccess
}

enum JSONValue: Equatable {
    case string(String)
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

struct SessionConfiguration {
    var deniesShell: Bool
}

struct PermissionHarness {
    var configuration: SessionConfiguration
    var runtimeMode: RuntimeMode

__AUTOMATIC_OPTION_FN__

__DSH_KIND_FN__

    func evaluate(for kind: ToolCall.Kind, options: [JSONValue]) -> String? {
        automaticOption(for: kind, options: options)
    }

    static func inferredDshKind(_ title: String?) -> ToolCall.Kind {
        dshKind(title)
    }
}

struct ApprovalRequest {
    enum Kind {
        case command
        case fileChange
        case tool
        case permissions
        case plan
    }

    struct Option {
        enum Role {
            case approve
            case approveAlways
            case decline
            case cancel
        }

        var id: String
        var title: String
        var role: Role
    }

    var kind: Kind
    var options: [Option]
}

enum EphemeralApprovalHarness {
__APPROVAL_OPTION_ID_FN__

    static func evaluate(for request: ApprovalRequest) -> String {
        approvalOptionID(for: request)
    }
}

func permissionOption(id: String, kind: String) -> JSONValue {
    .object(["optionId": .string(id), "kind": .string(kind)])
}

func expectOptional(_ actual: String?, _ expected: String?, _ label: String) {
    precondition(actual == expected, "\(label): expected \(String(describing: expected)), got \(String(describing: actual))")
}

func expectString(_ actual: String, _ expected: String, _ label: String) {
    precondition(actual == expected, "\(label): expected \(expected), got \(actual)")
}

@main struct Checks {
    static func main() {
        let bothAllowOptions: [JSONValue] = [
            permissionOption(id: "reject-once", kind: "reject_once"),
            permissionOption(id: "allow-always", kind: "allow_always"),
            permissionOption(id: "allow-once", kind: "allow_once"),
        ]
        let allowAlwaysOnlyOptions: [JSONValue] = [
            permissionOption(id: "reject-once", kind: "reject_once"),
            permissionOption(id: "allow-always", kind: "allow_always"),
        ]
        let rejectOnlyOptions: [JSONValue] = [
            permissionOption(id: "reject-once", kind: "reject_once"),
            permissionOption(id: "reject-always", kind: "reject_always"),
        ]

        let autoAllowedKinds: Set<ToolCall.Kind> = [.edit, .read, .search]
        let manualKinds: Set<ToolCall.Kind> = [.command, .web, .mcp, .agent, .other]
        precondition(
            autoAllowedKinds.union(manualKinds) == Set(ToolCall.Kind.allCases),
            "ToolCall.Kind partition must cover all cases"
        )

        // (a) .autoAcceptEdits + deniesShell=true
        let autoAcceptDenyShell = PermissionHarness(
            configuration: SessionConfiguration(deniesShell: true),
            runtimeMode: .autoAcceptEdits
        )
        for kind in ToolCall.Kind.allCases {
            if autoAllowedKinds.contains(kind) {
                expectOptional(
                    autoAcceptDenyShell.evaluate(for: kind, options: bothAllowOptions),
                    "allow-once",
                    "autoAcceptEdits + deniesShell=true + \(kind.rawValue) (allow_once preferred)"
                )
                expectOptional(
                    autoAcceptDenyShell.evaluate(for: kind, options: allowAlwaysOnlyOptions),
                    "allow-always",
                    "autoAcceptEdits + deniesShell=true + \(kind.rawValue) (allow_always fallback)"
                )
                expectOptional(
                    autoAcceptDenyShell.evaluate(for: kind, options: rejectOnlyOptions),
                    nil,
                    "autoAcceptEdits + deniesShell=true + \(kind.rawValue) (no allow option)"
                )
            } else {
                expectOptional(
                    autoAcceptDenyShell.evaluate(for: kind, options: bothAllowOptions),
                    nil,
                    "autoAcceptEdits + deniesShell=true + \(kind.rawValue)"
                )
                expectOptional(
                    autoAcceptDenyShell.evaluate(for: kind, options: allowAlwaysOnlyOptions),
                    nil,
                    "autoAcceptEdits + deniesShell=true + \(kind.rawValue) (allow_always only)"
                )
            }
        }

        // (b) .autoAcceptEdits + deniesShell=false
        let autoAcceptAllowShell = PermissionHarness(
            configuration: SessionConfiguration(deniesShell: false),
            runtimeMode: .autoAcceptEdits
        )
        for kind in ToolCall.Kind.allCases {
            let expectedBoth: String? = autoAllowedKinds.contains(kind) ? "allow-once" : nil
            let expectedFallback: String? = autoAllowedKinds.contains(kind) ? "allow-always" : nil
            expectOptional(
                autoAcceptAllowShell.evaluate(for: kind, options: bothAllowOptions),
                expectedBoth,
                "autoAcceptEdits + deniesShell=false + \(kind.rawValue) (allow_once)"
            )
            expectOptional(
                autoAcceptAllowShell.evaluate(for: kind, options: allowAlwaysOnlyOptions),
                expectedFallback,
                "autoAcceptEdits + deniesShell=false + \(kind.rawValue) (allow_always)"
            )
        }

        // (c) .supervised denies automatic approval for all ToolCall.Kind values
        for deniesShell in [false, true] {
            let supervised = PermissionHarness(
                configuration: SessionConfiguration(deniesShell: deniesShell),
                runtimeMode: .supervised
            )
            for kind in ToolCall.Kind.allCases {
                expectOptional(
                    supervised.evaluate(for: kind, options: bothAllowOptions),
                    nil,
                    "supervised + deniesShell=\(deniesShell) + \(kind.rawValue)"
                )
            }
        }

        // (d) .fullAccess allows all when deniesShell=false, still blocks .command when deniesShell=true
        let fullAccessAllowShell = PermissionHarness(
            configuration: SessionConfiguration(deniesShell: false),
            runtimeMode: .fullAccess
        )
        for kind in ToolCall.Kind.allCases {
            expectOptional(
                fullAccessAllowShell.evaluate(for: kind, options: bothAllowOptions),
                "allow-once",
                "fullAccess + deniesShell=false + \(kind.rawValue) (allow_once)"
            )
            expectOptional(
                fullAccessAllowShell.evaluate(for: kind, options: allowAlwaysOnlyOptions),
                "allow-always",
                "fullAccess + deniesShell=false + \(kind.rawValue) (allow_always)"
            )
        }

        let fullAccessDenyShell = PermissionHarness(
            configuration: SessionConfiguration(deniesShell: true),
            runtimeMode: .fullAccess
        )
        for kind in ToolCall.Kind.allCases {
            let expectedBoth: String? = (kind == .command) ? nil : "allow-once"
            let expectedFallback: String? = (kind == .command) ? nil : "allow-always"
            expectOptional(
                fullAccessDenyShell.evaluate(for: kind, options: bothAllowOptions),
                expectedBoth,
                "fullAccess + deniesShell=true + \(kind.rawValue) (allow_once)"
            )
            expectOptional(
                fullAccessDenyShell.evaluate(for: kind, options: allowAlwaysOnlyOptions),
                expectedFallback,
                "fullAccess + deniesShell=true + \(kind.rawValue) (allow_always)"
            )
        }

        // (e) EphemeralAgentRunner.approvalOptionID(for:)
        let fullApprovalOptions: [ApprovalRequest.Option] = [
            .init(id: "opt-approve-always", title: "Always", role: .approveAlways),
            .init(id: "opt-approve", title: "Allow", role: .approve),
            .init(id: "opt-cancel", title: "Cancel", role: .cancel),
            .init(id: "opt-decline", title: "Decline", role: .decline),
        ]
        let fallbackApproveOptions: [ApprovalRequest.Option] = [
            .init(id: "opt-approve-always", title: "Always", role: .approveAlways),
            .init(id: "opt-decline", title: "Decline", role: .decline),
        ]
        let fallbackCancelOptions: [ApprovalRequest.Option] = [
            .init(id: "opt-approve", title: "Allow", role: .approve),
            .init(id: "opt-cancel", title: "Cancel", role: .cancel),
        ]

        expectString(
            EphemeralApprovalHarness.evaluate(for: ApprovalRequest(kind: .fileChange, options: fullApprovalOptions)),
            "opt-approve",
            "ephemeral fileChange prefers approve"
        )
        expectString(
            EphemeralApprovalHarness.evaluate(for: ApprovalRequest(kind: .fileChange, options: fallbackApproveOptions)),
            "opt-approve-always",
            "ephemeral fileChange falls back to approveAlways"
        )
        expectString(
            EphemeralApprovalHarness.evaluate(for: ApprovalRequest(kind: .fileChange, options: [])),
            "allow",
            "ephemeral fileChange defaults to allow"
        )

        let declinedKinds: [(String, ApprovalRequest.Kind)] = [
            ("command", .command),
            ("tool", .tool),
            ("permissions", .permissions),
            ("plan", .plan),
        ]
        for (label, kind) in declinedKinds {
            expectString(
                EphemeralApprovalHarness.evaluate(for: ApprovalRequest(kind: kind, options: fullApprovalOptions)),
                "opt-decline",
                "ephemeral \(label) prefers decline"
            )
            expectString(
                EphemeralApprovalHarness.evaluate(for: ApprovalRequest(kind: kind, options: fallbackCancelOptions)),
                "opt-cancel",
                "ephemeral \(label) falls back to cancel"
            )
            expectString(
                EphemeralApprovalHarness.evaluate(for: ApprovalRequest(kind: kind, options: [])),
                "decline",
                "ephemeral \(label) defaults to decline"
            )
        }

        // (f) dshKind classifies web_search as .web so autoAcceptEdits does not auto-approve network search
        precondition(
            PermissionHarness.inferredDshKind("web_search") == .web,
            "dshKind(web_search) must be .web"
        )
        precondition(
            PermissionHarness.inferredDshKind("web_fetch") == .web,
            "dshKind(web_fetch) must be .web"
        )
        precondition(
            PermissionHarness.inferredDshKind("glob") == .search
                && PermissionHarness.inferredDshKind("grep") == .search,
            "dshKind(glob/grep) must remain .search"
        )
        expectOptional(
            autoAcceptDenyShell.evaluate(for: PermissionHarness.inferredDshKind("web_search"), options: bothAllowOptions),
            nil,
            "autoAcceptEdits must not auto-approve dsh web_search"
        )

        print("PASS: ACP automaticOption and EphemeralAgentRunner approvalOptionID match permission contracts.")
    }
}
'''


def fail(message):
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def source(path):
    if not path.is_file():
        fail(f'{path.relative_to(ROOT)} is missing')
    return path.read_text(encoding='utf-8')


def extract_block(text, marker, path):
    count = text.count(marker)
    if count != 1:
        fail(f'{path.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    start = text.index(marker)
    opening = text.find('{', start + len(marker))
    if opening < 0:
        fail(f'{path.relative_to(ROOT)}: no opening brace for {marker!r}')
    depth = 0
    in_string = False
    in_line_comment = False
    block_comment_depth = 0
    index = opening
    length = len(text)
    while index < length:
        ch = text[index]
        nxt = text[index + 1] if index + 1 < length else ''
        if in_line_comment:
            if ch == '\n':
                in_line_comment = False
            index += 1
            continue
        if block_comment_depth > 0:
            if ch == '/' and nxt == '*':
                block_comment_depth += 1
                index += 2
                continue
            if ch == '*' and nxt == '/':
                block_comment_depth -= 1
                index += 2
                continue
            index += 1
            continue
        if in_string:
            if ch == '\\':
                index += 2
                continue
            if ch == '"':
                in_string = False
            index += 1
            continue
        if ch == '/' and nxt == '/':
            in_line_comment = True
            index += 2
            continue
        if ch == '/' and nxt == '*':
            block_comment_depth = 1
            index += 2
            continue
        if ch == '"':
            in_string = True
            index += 1
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
        index += 1
    fail(f'{path.relative_to(ROOT)}: no closing brace for {marker!r}')


def require(snippet, tokens, label, path):
    for token in tokens:
        if token not in snippet:
            fail(f'{path.relative_to(ROOT)}: {label} is missing {token!r}')


def check_sources():
    acp = source(ACP)
    ephemeral = source(EPHEMERAL)

    handle_request_fn = extract_block(acp, HANDLE_REQUEST_MARKER, ACP)
    require(
        handle_request_fn,
        ['if !isPlan, !isQuestion, let optionID = automaticOption(for: call.kind, options: options)'],
        'handleRequest()',
        ACP,
    )

    automatic_option_fn = extract_block(acp, AUTOMATIC_OPTION_MARKER, ACP)
    require(
        automatic_option_fn,
        [
            'if configuration.deniesShell, kind == .command { return nil }',
            'case .fullAccess: true',
            'case .autoAcceptEdits: kind == .edit || kind == .read || kind == .search',
            'default: false',
            '$0["kind"]?.string == "allow_once"',
            '$0["kind"]?.string == "allow_always"',
        ],
        'automaticOption(for:options:)',
        ACP,
    )

    dsh_kind_fn = extract_block(acp, DSH_KIND_MARKER, ACP)
    require(
        dsh_kind_fn,
        [
            'case "glob", "grep": .search',
            'case "web_fetch", "web_search": .web',
        ],
        'dshKind(_:)',
        ACP,
    )

    approval_option_fn = extract_block(ephemeral, APPROVAL_OPTION_MARKER, EPHEMERAL)
    require(
        approval_option_fn,
        [
            'case .fileChange:',
            'case .command, .tool, .permissions, .plan:',
            '$0.role == .approve',
            '$0.role == .approveAlways',
            '$0.role == .decline',
            '$0.role == .cancel',
        ],
        'approvalOptionID(for:)',
        EPHEMERAL,
    )

    return automatic_option_fn, dsh_kind_fn, approval_option_fn


def check_behaviour(automatic_option_fn, dsh_kind_fn, approval_option_fn):
    for placeholder in ('__AUTOMATIC_OPTION_FN__', '__DSH_KIND_FN__', '__APPROVAL_OPTION_ID_FN__'):
        if placeholder not in SWIFT_TEMPLATE:
            fail(f'SWIFT_TEMPLATE is missing {placeholder} placeholder')
    swift_source = (
        SWIFT_TEMPLATE
        .replace('__AUTOMATIC_OPTION_FN__', automatic_option_fn)
        .replace('__DSH_KIND_FN__', dsh_kind_fn)
        .replace('__APPROVAL_OPTION_ID_FN__', approval_option_fn)
    )
    with tempfile.TemporaryDirectory(prefix='tivano-acp-permission-') as temp:
        directory = Path(temp)
        swift, binary = directory / 'Checks.swift', directory / 'checks'
        swift.write_text(swift_source, encoding='utf-8')
        build = subprocess.run(
            ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)],
            capture_output=True,
            text=True,
        )
        if build.returncode != 0:
            fail(f'extracted ACP permission checks do not compile:\n{build.stderr.strip()}')
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        if run.returncode != 0:
            fail(f'ACP permission checks failed:\n{(run.stderr or run.stdout).strip()}')
        print(run.stdout.strip())


def main():
    automatic_option_fn, dsh_kind_fn, approval_option_fn = check_sources()
    check_behaviour(automatic_option_fn, dsh_kind_fn, approval_option_fn)


if __name__ == '__main__':
    main()
