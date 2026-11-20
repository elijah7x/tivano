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
    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('PASS: Codex rewind uses thread/revert with a fork fallback; every thread sends developer instructions.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
