#!/usr/bin/env python3
"""Offline source guard for optimistic first-turn bubble rendering and fresh-thread load skip."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = 'Tivano/App/Runtime/ThreadRuntime.swift'
APP_MODEL = 'Tivano/App/AppModel.swift'


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


def main():
    failures = []
    try:
        runtime = (ROOT / RUNTIME).read_text(encoding='utf-8')
        app_model = (ROOT / APP_MODEL).read_text(encoding='utf-8')
    except OSError as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1

    try:
        start_turn = block(runtime, '    private func startTurn(', RUNTIME)
        begin_guard = block(start_turn, 'guard await app.beginThreadTurnAsync(threadID) else {', RUNTIME)
        runtime_init = block(runtime, '    init(threadID: UUID, app: AppModel) {', RUNTIME)
        new_thread = block(app_model, '    func newThread(affiliation choice: NewThreadAffiliation,', APP_MODEL)
        take_fresh = block(app_model, '    func takeFreshThread(_ id: UUID) -> Bool {', APP_MODEL)
    except ValueError as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1

    append_pos = start_turn.find('append(userItem)')
    starting_pos = start_turn.find('phase = .starting')
    begin_pos = start_turn.find('await app.beginThreadTurnAsync(threadID)')
    if append_pos < 0:
        failures.append(f'{RUNTIME}: startTurn is missing append(userItem)')
    if starting_pos < 0:
        failures.append(f'{RUNTIME}: startTurn is missing phase = .starting')
    if begin_pos < 0:
        failures.append(f'{RUNTIME}: startTurn is missing await app.beginThreadTurnAsync(threadID)')
    if append_pos >= 0 and begin_pos >= 0 and append_pos >= begin_pos:
        failures.append(f'{RUNTIME}: append(userItem) must precede await app.beginThreadTurnAsync(threadID)')
    if starting_pos >= 0 and begin_pos >= 0 and starting_pos >= begin_pos:
        failures.append(f'{RUNTIME}: phase = .starting must precede await app.beginThreadTurnAsync(threadID)')

    for marker in ('remove(userItem.id)', 'turns.removeAll', 'currentTurnID = nil', 'phase = .idle'):
        if marker not in begin_guard:
            failures.append(f'{RUNTIME}: beginThreadTurnAsync failure branch missing rollback {marker!r}')
    owner_pos = begin_guard.find('if currentTurnID == turn.id')
    reset_pos = begin_guard.find('currentTurnID = nil')
    if owner_pos < 0 or reset_pos < 0 or owner_pos > reset_pos:
        failures.append(f'{RUNTIME}: failure rollback must reset turn state only while this turn still owns it')

    if 'let fresh = app.takeFreshThread(threadID)' not in runtime_init:
        failures.append(f'{RUNTIME}: init must consume takeFreshThread(threadID) unconditionally, before any prefetch condition')
    if 'completeHistoryLoad()' not in runtime_init:
        failures.append(f'{RUNTIME}: init fresh-thread path must call completeHistoryLoad()')

    if 'freshThreadIDs.insert(thread.id)' not in new_thread:
        failures.append(f'{APP_MODEL}: newThread must insert thread.id into freshThreadIDs')
    if 'freshThreadIDs.remove(id)' not in take_fresh:
        failures.append(f'{APP_MODEL}: takeFreshThread must remove id from freshThreadIDs')

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('OK: optimistic first-send bubble ordering, rollback and fresh-thread load skip are intact')
    return 0


if __name__ == '__main__':
    sys.exit(main())
