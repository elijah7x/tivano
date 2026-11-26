#!/usr/bin/env python3
"""Offline source guards: Codex rewind uses app-server's thread/revert (thread/rollback was removed) and threadParameters sends developerInstructions on every thread."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CODEX_SESSION = ROOT / 'Tivano/Services/Providers/CodexSession.swift'
COMMENT = re.compile(r'"(?:[^"\\]|\\.)*"|//[^\n]*|/\*[\s\S]*?\*/')


def block(source, marker):
    count = source.count(marker)
    if count != 1:
        raise ValueError(f'marker {marker!r} found {count} times, expected 1')
    start = source.index(marker)
    depth = 0
    for index in range(source.index('{', start), len(source)):
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(f'no closing brace for {marker!r}')


def main():
    if not CODEX_SESSION.is_file():
        print(f'FAIL: {CODEX_SESSION.relative_to(ROOT)} is missing', file=sys.stderr)
        return 1
    code = COMMENT.sub(lambda m: m.group(0) if m.group(0).startswith('"') else ' ',
                       CODEX_SESSION.read_text(encoding='utf-8'))
    try:
        rollback = block(code, 'func rollback(from targetID: String)')
        thread_params = block(code, 'private var threadParameters')
        branch_fork = block(code, 'func fork(thread originalID: String, through lastTurnID: String)')
    except ValueError as error:
        print(f'FAIL: CodexSession.swift: {error}', file=sys.stderr)
        return 1
    failures = []
    if '"thread/rollback"' in code:
        failures.append('CodexSession.swift must not call the removed "thread/rollback"')
    for marker in ('"thread/revert"', '"beforeTurnId": .string(targetID)', 'forkHistory(before: targetID'):
        if marker not in rollback:
            failures.append(f'CodexSession.swift: rollback(from:) is missing {marker!r}')
    if '"thread/revert"' not in code[code.index(rollback) + len(rollback):] and '"thread/revert"' not in code[:code.index(rollback)]:
        failures.append('CodexSession.swift: "thread/revert" must be listed with the mutating requests')
    required_params = ('voiceInstructions', 'configuration.hydra', 'Self.ordinaryThreadInstructions')
    if (not all(marker in thread_params for marker in required_params)
            or thread_params.count('params["developerInstructions"]') < 3):
        failures.append(
            'CodexSession.swift: threadParameters must send developerInstructions on every thread '
            '(voice, Hydra and ordinary) so a resumed thread drops stale instructions'
        )
    # The server that forks a thread holds it as its writer, so a branch fork made on the
    # source chat's live connection could not be resumed by the branch's own session
    # ("already has an active writer"); it must run in a server of its own that has exited.
    for marker in ('Self.connect(', '"thread/fork"', 'closeAndWait('):
        if marker not in branch_fork:
            failures.append(f'CodexSession.swift: fork(thread:through:) is missing {marker!r}')
    if 'self.connection' in branch_fork or re.search(r'\bguard let connection\b', branch_fork):
        failures.append('CodexSession.swift: fork(thread:through:) must not fork on the live session connection')
    if '"thread/archive", ["threadId": .string(originalID)]' in branch_fork:
        failures.append('CodexSession.swift: fork(thread:through:) must never archive the source thread')
    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('PASS: Codex rewind uses thread/revert with a fork fallback; every thread sends developer instructions; branch forks run in their own app-server.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
