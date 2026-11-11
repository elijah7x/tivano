#!/usr/bin/env python3
"""Offline source guard for failed-turn continuation and transient retries."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = 'Tivano/App/Runtime/ThreadRuntime.swift'
AUTO_CONTINUE = 'Tivano/App/Runtime/AutoContinue.swift'
TIMELINE_ROWS = 'Tivano/App/Views/Chat/TimelineRows.swift'
THREAD_TIMELINE = 'Tivano/App/Views/Chat/ThreadTimeline.swift'
CATALOG = 'Tivano/Resources/Localizable.xcstrings'


def block(source, marker, path):
    count = source.count(marker)
    if count != 1:
        raise ValueError(f'{path}: marker {marker!r} found {count} times, expected 1')
    start = source.index(marker)
    opening = source.find('{', start)
    if opening < 0:
        raise ValueError(f'{path}: no opening brace after {marker!r}')
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(f'{path}: no closing brace for {marker!r}')


def require(source, marker, path, failures):
    if marker not in source:
        failures.append(f'{path}: missing {marker!r}')


def main():
    failures = []
    sources = {}
    for path in (RUNTIME, AUTO_CONTINUE, TIMELINE_ROWS, THREAD_TIMELINE, CATALOG):
        try:
            sources[path] = (ROOT / path).read_text(encoding='utf-8')
        except OSError as error:
            print(f'FAIL: {path}: {error}', file=sys.stderr)
            return 1

    try:
        send = block(sources[RUNTIME],
                     '    @discardableResult\n    func sendContinuation(after turnID: UUID, text: String) -> Bool {',
                     RUNTIME)
        # The guards live in the helper sendContinuation calls before and after loading.
        send += block(sources[RUNTIME], '    private func canContinue(after turnID: UUID) -> Bool {', RUNTIME)
        finalize = block(sources[RUNTIME], '    private func finalizeTurn(', RUNTIME)
        schedule = block(sources[AUTO_CONTINUE], '    func scheduleTransientRetry(', AUTO_CONTINUE)
        end_row = block(sources[TIMELINE_ROWS], 'struct TurnEndRow: View {', TIMELINE_ROWS)
    except ValueError as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1

    for marker in ('canContinue(after: turnID)', 'phase == .idle', '!isReverting', '!thread.isArchived', 'turns.last',
                   'turn.id == turnID', 'turn.status == .failed', 'turn.status == .interrupted',
                   'thread.provider == .antigravity', 'thread.providerSessionID?.isEmpty != false'):
        require(send, marker, RUNTIME, failures)
    for marker in ('status == .failed', '!userStopped', 'thread.provider == .antigravity',
                   '!thread.isHydraHead', 'AntigravitySession.isTransientFailure(error)',
                   'app.autoContinue.scheduleTransientRetry(threadID, turnID: turnID)',
                   'continues = true'):
        require(finalize, marker, RUNTIME, failures)
    for marker in ('static let failedTurnContinueMessage', 'static let transientRetryLimit = 2',
                   'static let transientRetryDelays: [TimeInterval] = [3, 9]',
                   'static let transientRetryJitter: TimeInterval = 1'):
        require(sources[AUTO_CONTINUE], marker, AUTO_CONTINUE, failures)
    for marker in ('Self.transientRetryLimit', 'Self.transientRetryDelays[retry.attempts - 1]'):
        require(schedule, marker, AUTO_CONTINUE, failures)
    require(sources[AUTO_CONTINUE], 'runtime.sendContinuation(after: turnID, text: Self.failedTurnContinueMessage)',
            AUTO_CONTINUE, failures)
    for marker in ('let continueAction: (() -> Void)?', 'Button(Chrome.localized("Continue")',
                   '.disabled(continueDisabled)'):
        require(end_row, marker, TIMELINE_ROWS, failures)
    for marker in ('runtime.sendContinuation(after: turnID, text: AutoContinue.failedTurnContinueMessage)',
                   'runtime.sendContinuation(after: summary.turnID, text: AutoContinue.failedTurnContinueMessage)',
                   '!thread.isHydraHead', '[.antigravity, .codex, .claude].contains(thread.provider)'):
        require(sources[THREAD_TIMELINE], marker, THREAD_TIMELINE, failures)

    try:
        catalog = json.loads(sources[CATALOG])
    except json.JSONDecodeError as error:
        print(f'FAIL: {CATALOG}: invalid JSON: {error}', file=sys.stderr)
        return 1
    translations = {
        'Continue': '继续',
        'Continue head': '继续此 head',
        'Connection to Antigravity dropped. Continuing the same conversation in %lld s (attempt %lld of %lld)…':
            '与 Antigravity 的连接中断，%1$lld 秒后在同一对话中继续（第 %2$lld/%3$lld 次）…',
        'Antigravity head %@ lost its connection; continuing the same conversation in %lld s (attempt %lld of %lld)…':
            'Antigravity head %1$@ 连接中断，%2$lld 秒后在同一对话中继续（第 %3$lld/%4$lld 次）…',
    }
    for key, expected in translations.items():
        value = catalog.get('strings', {}).get(key, {}).get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value')
        if value != expected:
            failures.append(f'{CATALOG}: {key!r} zh-Hans is {value!r}, expected {expected!r}')

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('OK: failed-turn continuation, transient retry, timeline action and localization contracts are present')
    return 0


if __name__ == '__main__':
    sys.exit(main())
