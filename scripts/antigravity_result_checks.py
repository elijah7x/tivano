#!/usr/bin/env python3
"""Offline guard for Antigravity turn outcomes, transient classification, and ACP turn lifecycle.

One-shot review turns (`AntigravitySession.oneShotReply`) still use headless
stream-json, where `agy` can report a transient model error, retry it, stream a
successful reply, then end with status ERROR and the earlier attempt's error.
`turnOutcome` and `isTransientFailure` remain in `AntigravitySession` and are
extracted and compiled against fixtures so this check exercises their behavior
rather than only matching source text.

Interactive Antigravity chats now run through `ACPSession`. This check also
guards the ACP-era guarantees: 90 s deadlines for the four Antigravity startup
methods (`initialize`, `authenticate`, `session/new`, `session/resume`),
`oauth-personal` authentication retry with `loginHint`, `!isStopping` /
`stopAndWait` / `handleClose` lifecycle handling, and per-turn token spend
recorded once per finished prompt from `usage.totalTokens` without cumulative
delta tracking or charging `usage_update` context occupancy.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SESSION = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'
ACP = ROOT / 'Tivano/Services/Providers/ACPSession.swift'
TIMELINE_ROWS = ROOT / 'Tivano/App/Views/Chat/TimelineRows.swift'
CATALOG = ROOT / 'Tivano/Resources/Localizable.xcstrings'

START = 'struct TurnOutcome: Equatable {'
END = '// MARK: - Model and Effort Normalization'
TRANSIENT_SIGNATURE = 'nonisolated static func isTransientFailure(_ message: String) -> Bool'
START_TIMEOUT_KEY = 'Antigravity did not finish starting in time.'
START_TIMEOUT_ZH = 'Antigravity 未能及时完成启动。'
EXPECTED_LANGUAGES = {'fr', 'ja', 'ko', 'zh-Hans', 'zh-Hant'}


def fail(message):
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def source(path=SESSION):
    if not path.is_file():
        fail(f'{path.relative_to(ROOT)} is missing')
    return path.read_text(encoding='utf-8')


def section(text, start, end, path=SESSION):
    for marker in (start, end):
        count = text.count(marker)
        if count != 1:
            fail(f'{path.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    start_idx = text.index(start)
    end_idx = text.index(end)
    if end_idx <= start_idx:
        fail(f'{path.relative_to(ROOT)}: marker {end!r} appears before {start!r}')
    return text[start_idx:end_idx]


def between(text, start, end, path=SESSION):
    if text.count(start) != 1 or text.count(end) != 1:
        fail(f'{path.relative_to(ROOT)}: cannot extract source region {start!r} ... {end!r}')
    start_idx = text.index(start)
    end_idx = text.index(end)
    if end_idx <= start_idx:
        fail(f'{path.relative_to(ROOT)}: marker {end!r} appears before {start!r}')
    return text[start_idx:end_idx]


def require(text, markers, path=SESSION):
    for marker in markers:
        if marker not in text:
            fail(f'{path.relative_to(ROOT)} is missing required behavior: {marker!r}')


def check_sources():
    text = source(SESSION)
    acp = source(ACP)

    # AntigravitySession helpers: turnOutcome, isTransientFailure, loginHint, and oneShotReply.
    section(text, '// MARK: - Turn outcome', END, path=SESSION)
    section(text, START, END, path=SESSION)
    require(text, [
        'static func turnOutcome(',
        TRANSIENT_SIGNATURE,
        'static func loginHint(in text: String) -> String?',
    ], path=SESSION)
    if 'Antigravity did not answer. Is `agy` signed in?' in text or 'Antigravity did not answer. Is `agy` signed in?' in acp:
        fail('old signed-in timeout message must not reappear')

    one_shot = text[text.index('nonisolated static func oneShotReply(streamJSON output: String)'):] \
        if text.count('nonisolated static func oneShotReply(streamJSON output: String)') == 1 \
        else fail(f'{SESSION.relative_to(ROOT)}: oneShotReply marker not found uniquely')
    require(one_shot, [
        'if message["event"]?.string == "result"',
        'break',
        'latestError = (index, error)',
        'errorMessages.insert(error)',
        'completedIndex = index',
        'replyAfterError = false',
        'hasReply: latestError == nil ? (streamed != nil || response != nil) : replyAfterError',
        'latestCascadeErrorIndex: latestError?.index',
        'cascadeErrorMessages: errorMessages',
        'hasCompletedToolWork: completedToolWork',
        'turnOutcome(',
    ], path=SESSION)
    tool_branch = between(one_shot, 'else if stepType == "tool"', 'if let error = errorMessage(in: step)', path=SESSION)
    require(tool_branch, ['completedIndex = nil'], path=SESSION)
    if 'latestError' in tool_branch or 'errorMessages' in tool_branch:
        fail('oneShotReply tool steps must not be recorded as model/cascade failures')

    # ACPSession interactive Antigravity lifecycle, 90 s startup deadlines, auth, and per-turn spend.
    is_running = between(acp, 'var isRunning: Bool', 'var lastOutputAt: Date?', path=ACP)
    require(is_running, ['!isStopping', '!connection.isClosed'], path=ACP)

    start_fn = between(
        acp,
        'private func start(applyingSelection: Bool) async throws -> String',
        'private var clientCapabilities: JSONValue',
        path=ACP,
    )
    require(start_fn, [
        'deadlineRequest(connection, "initialize"',
        '"oauth-personal"',
        'deadlineRequest(connection, "authenticate"',
        'AntigravitySession.loginHint(in: evidence)',
        'Self.antigravityStartError(error, tail: process.errorTail)',
    ], path=ACP)

    deadline_fn = between(acp, 'private func deadlineRequest(', 'private static func miniMaxFailure(', path=ACP)
    require(deadline_fn, [
        'if configuration.provider == .antigravity',
        '"initialize"',
        '"authenticate"',
        '"session/new"',
        '"session/resume"',
        'timeout = 90',
        'withDeadline(seconds: timeout',
    ], path=ACP)

    send = between(acp, 'func send(_ input: TurnInput) async throws', 'private func continuePromptPreparation(', path=ACP)
    require(send, [
        '!isStopping',
        'ProviderError.notRunning',
        'self.finishPrompt(result["stopReason"]?.string, error: nil, generation: generation, usage: result["usage"])',
    ], path=ACP)
    if send.index('!isStopping') > send.index('promptActive = true'):
        fail('ACPSession.send(_:) must guard against !isStopping before starting a turn')

    stop_and_wait = between(acp, 'func stopAndWait(timeout: TimeInterval) async', 'func stop() {', path=ACP)
    require(stop_and_wait, ['stop()', 'closeAndWait(timeout: timeout)'], path=ACP)

    stop_fn = between(acp, 'func stop() {', 'private func emitAntigravityRetryNotice(', path=ACP)
    require(stop_fn, ['isStopping = true', 'promptActive = false'], path=ACP)

    finish = between(acp, 'private func finishPrompt(', 'private func handleClose(', path=ACP)
    require(finish, [
        'guard promptActive, generation == nil || promptGeneration == generation else { return }',
        'promptActive = false',
        'if configuration.provider == .antigravity, let usage, !usage.isNull',
        'usage["totalTokens"]?.int',
        'TokenLedger.shared.record(spend: total)',
        'onEvent?(.tokenSpend(TokenSpend(',
        'provider: .antigravity',
        'AntigravitySession.loginHint(in: evidence)',
    ], path=ACP)
    if finish.index('promptActive = false') > finish.index('TokenLedger.shared.record(spend: total)'):
        fail('finishPrompt must clear promptActive before recording per-turn token spend')
    for forbidden_delta in ('reportedSpend', 'spendBaseline', 'cumulativeSpend'):
        if forbidden_delta in finish:
            fail(f'ACPSession.finishPrompt must record per-turn usage.totalTokens directly, not {forbidden_delta!r}')

    usage_update = between(acp, 'case "usage_update":', 'private func handleRequest(', path=ACP)
    require(usage_update, ['onEvent?(.usage(ContextUsage(usedTokens: used, windowTokens: size)))'], path=ACP)
    if 'TokenLedger' in usage_update or '.tokenSpend' in usage_update:
        fail('usage_update reports context occupancy only and must not bill TokenLedger or emit .tokenSpend')

    closed = between(acp, 'private func handleClose(', '// MARK: - Mapping', path=ACP)
    require(closed, [
        'if configuration.provider == .antigravity',
        'AntigravitySession.loginHint(in: tail)',
        'guard !isStopping else { return }',
        'onEvent?(.exited(error: detail))',
    ], path=ACP)
    agy_close = closed[closed.rindex('if configuration.provider == .antigravity'):]
    if agy_close.index('guard !isStopping else { return }') > agy_close.index('onEvent?(.exited(error: detail))'):
        fail('handleClose must suppress .exited when isStopping is true')

    if not TIMELINE_ROWS.is_file():
        fail(f'{TIMELINE_ROWS.relative_to(ROOT)} is missing')
    rows_text = TIMELINE_ROWS.read_text(encoding='utf-8')
    label = between(
        rows_text,
        'static func label(for call: ToolCall) -> String',
        'private static func countedFiles',
        path=TIMELINE_ROWS,
    )
    require(label, ['call.kind == .other', '"Using tool"', '"Used tool"'], path=TIMELINE_ROWS)

    if not CATALOG.is_file():
        fail(f'{CATALOG.relative_to(ROOT)} is missing')
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))
    strings = catalog.get('strings') or {}
    for key, expected_zh in (
        (START_TIMEOUT_KEY, START_TIMEOUT_ZH),
        ('Using tool', '正在使用工具'),
        ('Used tool', '已用工具'),
    ):
        entry = strings.get(key)
        if not isinstance(entry, dict):
            fail(f'{CATALOG.relative_to(ROOT)} is missing key {key!r}')
        localizations = entry.get('localizations') or {}
        missing_langs = sorted(EXPECTED_LANGUAGES - set(localizations.keys()))
        if missing_langs:
            fail(f'{CATALOG.relative_to(ROOT)} key {key!r} is missing languages: {missing_langs}')
        zh_val = localizations.get('zh-Hans', {}).get('stringUnit', {}).get('value')
        if zh_val != expected_zh:
            fail(f'{CATALOG.relative_to(ROOT)} key {key!r} zh-Hans={zh_val!r}, expected {expected_zh!r}')


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
    knownConversationErrors: Set<String> = [],
    hasCompletedToolWork: Bool = false,
    replyOnlyInResult: Bool = false,
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
        knownConversationErrors: knownConversationErrors,
        hasCompletedToolWork: hasCompletedToolWork,
        replyOnlyInResult: replyOnlyInResult,
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
                 "expected \\(status), recovered=\\(recovered); got \\(actual)")
}}

@main
struct Checks {{
    @MainActor
    static func main() {{
        let eof = "API error (attempt 1): unexpected EOF"
        let later = "API error (attempt 2): connection reset"
        let stale = "The stream was interrupted. Please continue the task you were working on."

        // A recovered attempt completes despite its stale ERROR status and error.
        expect(outcome(status: "ERROR", hasReply: true, completedResponseIndex: 8,
                       latestCascadeErrorIndex: 3, cascadeErrorMessages: [eof], resultError: eof),
               .completed, true)
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true, completedResponseIndex: 8,
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
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true,
                       completedResponseIndex: nil, latestCascadeErrorIndex: 9,
                       cascadeErrorMessages: [eof], resultError: eof), .failed)
        // Explicit terminal reasons outrank reply evidence and stale status.
        expect(outcome(status: "ERROR", finishedReason: "print_timeout", hasReply: true,
                       completedResponseIndex: 8, latestCascadeErrorIndex: 3,
                       cascadeErrorMessages: [eof], resultError: eof), .failed)
        expect(outcome(status: "ERROR", finishedReason: "interrupted"), .interrupted)
        expect(outcome(interruptRequested: true, status: "ERROR", finishedReason: "print_timeout"),
               .interrupted)
        expect(outcome(status: "SUCCESS"), .completed)
        expect(outcome(status: "SUCCESS", finishedReason: "error"), .failed)
        expect(outcome(status: "CANCELED", finishedReason: "error"), .failed)
        expect(outcome(status: "ERROR", completedResponseIndex: 8,
                       latestCascadeErrorIndex: 3, cascadeErrorMessages: [eof], resultError: eof),
               .failed)
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true,
                       completedResponseIndex: 109, knownConversationErrors: [stale], resultError: stale),
               .completed, true) // sticky error from an earlier turn.
        // A result-only error the conversation never reported is a fresh failure.
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true,
                       completedResponseIndex: 109, resultError: "stream idle timeout"), .failed)
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: false,
                       completedResponseIndex: 109, resultError: stale), .failed)
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true,
                       completedResponseIndex: nil, resultError: stale), .failed)
        expect(outcome(status: "ERROR", finishedReason: "error", hasDeniedActions: true,
                       hasReply: true, completedResponseIndex: 109, resultError: stale), .failed)
        // (a) ERROR/error with reply only in result["response"] (completedResponseIndex nil),
        // known sticky error, and no cascade error this turn -> completed.
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true,
                       completedResponseIndex: nil, knownConversationErrors: [stale],
                       replyOnlyInResult: true, resultError: stale),
               .completed, true)
        // A streamed interim reply, then a tool (completedResponseIndex cleared), then a
        // known sticky result error: the turn never closed its reply, so it fails.
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true,
                       completedResponseIndex: nil, knownConversationErrors: [stale],
                       hasCompletedToolWork: true, resultError: stale),
               .failed)
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true,
                       completedResponseIndex: nil,
                       knownConversationErrors: ["request failed: stream idle timeout (5m0s)"],
                       replyOnlyInResult: true,
                       resultError: "API error (attempt 1): request failed: stream idle timeout (5m0s)"),
               .completed, true)
        // (b) Same with knownConversationErrors empty and no reply -> failed.
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: false,
                       completedResponseIndex: nil, knownConversationErrors: [], resultError: stale),
               .failed)
        // (c) Cascade error this turn and no reply after it -> failed.
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: false,
                       completedResponseIndex: nil, latestCascadeErrorIndex: 3,
                       cascadeErrorMessages: [eof], knownConversationErrors: [eof],
                       hasCompletedToolWork: true, resultError: eof),
               .failed)
        // An unknown result error stays a failure even after completed tool work.
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: true,
                       completedResponseIndex: nil, knownConversationErrors: [],
                       hasCompletedToolWork: true,
                       resultError: "API error (attempt 1): request failed: stream idle timeout (5m0s)"),
               .failed)
        expect(outcome(status: "ERROR", finishedReason: "error", hasReply: false,
                       completedResponseIndex: nil, knownConversationErrors: [],
                       hasCompletedToolWork: true, resultError: stale),
               .failed)
        expect(outcome(status: "ERROR", finishedReason: "error", hasDeniedActions: true,
                       hasReply: true, completedResponseIndex: nil, knownConversationErrors: [],
                       hasCompletedToolWork: true, resultError: stale),
               .failed)
        // Tool failures are nonfatal and never become a known conversation error.
        expect(outcome(status: "ERROR", hasReply: true, completedResponseIndex: 8,
                       resultError: "tool execution failed"), .failed)
        // WAITING retains its permission-denied distinction.
        expect(outcome(status: "WAITING"), .completed)
        expect(outcome(status: "WAITING", hasDeniedActions: true), .failed)

        precondition(AntigravityTurnOutcome.isTransientFailure("API error: unexpected EOF"))
        precondition(AntigravityTurnOutcome.isTransientFailure("stream idle timeout"))
        precondition(AntigravityTurnOutcome.isTransientFailure("dial tcp: no such host"))
        precondition(AntigravityTurnOutcome.isTransientFailure("TLS handshake timeout"))
        precondition(AntigravityTurnOutcome.isTransientFailure("Antigravity did not finish starting in time."))
        precondition(AntigravityTurnOutcome.isTransientFailure("Antigravity 未能及时完成启动。"))
        precondition(AntigravityTurnOutcome.isTransientFailure("Antigravity did not start within 90 seconds. Try sending again."))
        precondition(AntigravityTurnOutcome.isTransientFailure("Antigravity 在 90 秒内没有启动。请重新发送。"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("rpc error: UNAVAILABLE"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("API error (attempt 8): UNAVAILABLE (code 503)"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("No capacity"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("429 Individual quota exhausted"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("RESOURCE_EXHAUSTED: quota"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("invalid model selection"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("print_timeout: DEADLINE_EXCEEDED"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("Please sign in before retrying"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("unknown flag: --effort"))
        precondition(!AntigravityTurnOutcome.isTransientFailure("model has no \\"high\\" effort"))
        print("PASS: Antigravity turnOutcome, transient classification, and ACP turn lifecycle/spend guards passed.")
    }}
}}
'''


def check_behaviour():
    block = section(source(SESSION), START, END, path=SESSION)
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
