#!/usr/bin/env python3
"""Offline guard for agy's stale result status after a recovered model failure.

agy can report a transient model error, retry it, stream a successful reply, then
end with status ERROR and the earlier attempt's error. Tivano used to fail those
completed turns. The terminal decision now requires stream evidence of recovery,
honors finished_reason, preserves launch and intentional-stop errors, and exposes
a conservative transient-failure classifier for automatic continuation. The
production decision and classifier are extracted and compiled against fixtures so
this check exercises their behavior rather than only matching source text.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SESSION = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'

START = '// MARK: - Turn outcome'
END = '// MARK: - Result handling'
TRANSIENT_SIGNATURE = 'nonisolated static func isTransientFailure(_ message: String) -> Bool'


def fail(message):
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def source():
    if not SESSION.is_file():
        fail(f'{SESSION.relative_to(ROOT)} is missing')
    return SESSION.read_text(encoding='utf-8')


def section(text, start, end):
    for marker in (start, end):
        count = text.count(marker)
        if count != 1:
            fail(f'{SESSION.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    return text[text.index(start):text.index(end)]


def between(text, start, end):
    if text.count(start) != 1 or text.count(end) != 1:
        fail(f'cannot extract source region {start!r} ... {end!r}')
    return text[text.index(start):text.index(end)]


def require(text, markers):
    for marker in markers:
        if marker not in text:
            fail(f'{SESSION.relative_to(ROOT)} is missing required behavior: {marker!r}')


def check_sources():
    text = source()
    section(text, START, END)
    require(text, [
        'guard turnActive else {',
        'hasReply: latestCascadeError == nil ? hasReply : replyAfterCascadeError',
        'replyAfterCascadeError = false',
        'static func turnOutcome(',
        TRANSIENT_SIGNATURE,
        'latestCascadeError = (index, message)',
        'cascadeErrorMessages.insert(',
        'completedAgentResponseIndex = index',
        'guard initContinuation == nil else',
        'launchError = error',
        'let hasReply = streamedText || response?.trimmed.isEmpty == false',
        'latestCascadeErrorIndex: latestCascadeError?.index',
        'cascadeErrorMessages: cascadeErrorMessages',
        'reportedErrors.insert("result|\\(trimmedResultError)")',
        'Self.log.warning(',
        'Self.agyError(in: tail)',
        'process?.failureReason',
        'process?.exitStatus',
        'authHint(in: trimmedResultError)',
    ])

    send = between(text, 'func send(_ input: TurnInput)', 'func interrupt() async')
    require(send, [
        'latestCascadeError = nil',
        'cascadeErrorMessages.removeAll()',
        'completedAgentResponseIndex = nil',
        'reportedErrors.removeAll()',
    ])
    result = between(text, 'private func handleResult', 'private func didClose')
    if result.index('guard initContinuation == nil else') > result.index('turnActive = false'):
        fail('a pre-init result is still allowed to finish a turn')
    if result.index('let hasReply =') > result.index('streamedText = false'):
        fail('reply evidence is captured after streamedText is cleared')
    closed = between(text, 'private func didClose', 'private func closeFailure')
    if closed.index('if isStopping') > closed.index('if turnActive'):
        fail('didClose handles the generic active-turn failure before intentional stop')
    tool = between(text, 'case "tool":', 'case "user_input", "checkpoint":')
    if 'latestCascadeError' in tool or 'cascadeErrorMessages' in tool:
        fail('tool ERROR steps must not be recorded as model/cascade failures')


def fixture(block):
    return f'''import Foundation

@MainActor
enum AntigravityTurnOutcome {{
{block}}}

@MainActor
func outcome(
    interruptRequested: Bool = false,
    status: String? = nil,
    finishedReason: String? = nil,
    hasDeniedActions: Bool = false,
    hasReply: Bool = false,
    completedResponseIndex: Int? = nil,
    latestCascadeErrorIndex: Int? = nil,
    cascadeErrorMessages: Set<String> = [],
    resultError: String? = nil
) -> AntigravityTurnOutcome.TurnOutcome {{
    AntigravityTurnOutcome.turnOutcome(
        interruptRequested: interruptRequested,
        status: status,
        finishedReason: finishedReason,
        hasDeniedActions: hasDeniedActions,
        hasReply: hasReply,
        completedResponseIndex: completedResponseIndex,
        latestCascadeErrorIndex: latestCascadeErrorIndex,
        cascadeErrorMessages: cascadeErrorMessages,
        resultError: resultError
    )
}}

@MainActor
func expect(
    _ actual: AntigravityTurnOutcome.TurnOutcome,
    _ status: AntigravityTurnOutcome.TurnOutcome.Status,
    _ recovered: Bool = false
) {{
    precondition(actual.status == status && actual.recovered == recovered,
                 "expected \(status), recovered=\(recovered); got \(actual)")
}}

@main
struct Checks {{
    @MainActor
    static func main() {{
        let eof = "API error (attempt 1): unexpected EOF"
        let later = "API error (attempt 2): connection reset"

        // A recovered attempt completes despite its stale ERROR status and error.
        expect(outcome(status: "ERROR", hasReply: true, completedResponseIndex: 8,
                       latestCascadeErrorIndex: 3, cascadeErrorMessages: [eof], resultError: eof),
               .completed, true)
        // Denied actions, no reply since the failure, or a blank reason (= absent).
        expect(outcome(status: "ERROR", hasDeniedActions: true, hasReply: true, completedResponseIndex: 8,
                       latestCascadeErrorIndex: 3, cascadeErrorMessages: [eof], resultError: eof),
               .failed)
        expect(outcome(status: "ERROR", hasReply: false, completedResponseIndex: 8,
                       latestCascadeErrorIndex: 3, cascadeErrorMessages: [eof], resultError: eof),
               .failed)
        expect(outcome(status: "ERROR", finishedReason: "  ", hasReply: true, completedResponseIndex: 8,
                       latestCascadeErrorIndex: 3, cascadeErrorMessages: [eof], resultError: eof),
               .completed, true)
        // A new cascade failure after that reply is not a recovery.
        expect(outcome(status: "ERROR", hasReply: true, completedResponseIndex: 8,
                       latestCascadeErrorIndex: 9, cascadeErrorMessages: [eof, later], resultError: later),
               .failed)
        expect(outcome(status: "ERROR", hasReply: true, completedResponseIndex: 8,
                       latestCascadeErrorIndex: 3, cascadeErrorMessages: [eof], resultError: later),
               .failed)
        // Explicit terminal reasons outrank reply evidence and stale status.
        expect(outcome(status: "ERROR", finishedReason: "print_timeout", hasReply: true,
                       completedResponseIndex: 8, latestCascadeErrorIndex: 3,
                       cascadeErrorMessages: [eof], resultError: eof), .failed)
        expect(outcome(status: "ERROR", finishedReason: "interrupted"), .interrupted)
        expect(outcome(interruptRequested: true, status: "ERROR", finishedReason: "print_timeout"),
               .interrupted)
        expect(outcome(status: "SUCCESS"), .completed)
        expect(outcome(status: "SUCCESS", finishedReason: "error"), .failed)
        expect(outcome(status: "ERROR", completedResponseIndex: 8,
                       latestCascadeErrorIndex: 3, cascadeErrorMessages: [eof], resultError: eof),
               .failed)
        // Tool failures are nonfatal and cannot supply recovery evidence or a stale error match.
        expect(outcome(status: "ERROR", hasReply: true, completedResponseIndex: 8,
                       resultError: "tool execution failed"), .failed)
        // WAITING retains its permission-denied distinction.
        expect(outcome(status: "WAITING"), .completed)
        expect(outcome(status: "WAITING", hasDeniedActions: true), .failed)

        precondition(AntigravityTurnOutcome.isTransientFailure("API error: unexpected EOF"))
        precondition(AntigravityTurnOutcome.isTransientFailure("TLS handshake timeout"))
        precondition(AntigravityTurnOutcome.isTransientFailure("rpc error: UNAVAILABLE"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("429 Individual quota exhausted"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("RESOURCE_EXHAUSTED: quota"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("invalid model selection"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("print_timeout: DEADLINE_EXCEEDED"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("Please sign in before retrying"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("unknown flag: --effort"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("model has no \\"high\\" effort"))
        print("PASS: recovered agy turns complete; fatal results, launch/stop handling and retry classification stay conservative.")
    }}
}}
'''


def check_behaviour():
    block = section(source(), START, END)
    with tempfile.TemporaryDirectory(prefix='tivano-antigravity-result-') as temp:
        directory = Path(temp)
        swift, binary = directory / 'Checks.swift', directory / 'checks'
        swift.write_text(fixture(block), encoding='utf-8')
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                                str(swift), '-o', str(binary)], capture_output=True, text=True)
        if build.returncode != 0:
            fail(f'extracted turn outcome does not compile:\n{build.stderr.strip()}')
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        if run.returncode != 0:
            fail(f'turn outcome or transient classification is wrong:\n{(run.stderr or run.stdout).strip()}')
        print(run.stdout.strip())


def main():
    check_sources()
    check_behaviour()


if __name__ == '__main__':
    main()
