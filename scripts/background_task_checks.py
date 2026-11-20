#!/usr/bin/env python3
"""Offline guard for idle-session background task retention and lost-task recovery."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP_MODEL = ROOT / 'Tivano/App/AppModel.swift'
THREAD_RUNTIME = ROOT / 'Tivano/App/Runtime/ThreadRuntime.swift'
CATALOG = ROOT / 'Tivano/Resources/Localizable.xcstrings'
CLAUDE_SESSION = ROOT / 'Tivano/Services/Providers/ClaudeSession.swift'


def function_body(text, marker):
    start = text.find(marker)
    if start < 0:
        return None
    opening = text.find('{', start + len(marker))
    if opening < 0:
        return None
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return None


def main():
    failures = []
    app_model = APP_MODEL.read_text(encoding='utf-8')
    runtime = THREAD_RUNTIME.read_text(encoding='utf-8')

    idle_stop = function_body(app_model, 'private func scheduleIdleSessionStop(leaving id: UUID?)')
    if idle_stop is None:
        failures.append('could not extract scheduleIdleSessionStop(leaving:); update the extraction marker')
    elif 'backgroundTasks.isEmpty' not in idle_stop:
        failures.append('scheduleIdleSessionStop(leaving:) must guard on backgroundTasks.isEmpty')

    handle_body = function_body(runtime, 'private func handle(_ event: ProviderEvent)')
    if handle_body is None:
        failures.append('could not extract handle(_:); update the extraction marker')
    else:
        exited_marker = 'case .exited(let error):'
        exited_start = handle_body.find(exited_marker)
        if exited_start < 0:
            failures.append('could not locate case .exited(let error): in handle(_:)')
        else:
            next_case = handle_body.find('\n        case .', exited_start + len(exited_marker))
            exited_body = handle_body[exited_start:next_case] if next_case >= 0 else handle_body[exited_start:]
            if 'wakeAfterLostBackgroundTasks' not in exited_body:
                failures.append('case .exited(let error) must call wakeAfterLostBackgroundTasks')

    wake_body = function_body(runtime, 'private func wakeAfterLostBackgroundTasks(_ lost: [String])')
    if wake_body is None:
        failures.append('could not extract wakeAfterLostBackgroundTasks(_:); update the extraction marker')
    else:
        if 'lostBackgroundWakeCount < 2' not in wake_body:
            failures.append('wakeAfterLostBackgroundTasks(_:) must cap wakes with lostBackgroundWakeCount < 2')
        if 'sessionEpoch == epoch' not in wake_body:
            failures.append('wakeAfterLostBackgroundTasks(_:) must drop the wake when the session was stopped while it waited')
        if '.claude' not in wake_body:
            failures.append('wakeAfterLostBackgroundTasks(_:) must restrict auto-wake to .claude')

    release_body = function_body(runtime, 'private func releaseSession(stop: Bool)')
    if release_body is None:
        failures.append('could not extract releaseSession(stop:); update the extraction marker')
    else:
        clear_pos = release_body.find('backgroundTasks = []')
        notice_pos = release_body.find('appendNotice')
        tasks_pos = release_body.find('backgroundTasks')
        if clear_pos < 0:
            failures.append('releaseSession(stop:) is missing backgroundTasks = []')
        elif notice_pos < 0 or tasks_pos < 0 or notice_pos > clear_pos or tasks_pos > clear_pos:
            failures.append('releaseSession(stop:) must reference backgroundTasks with appendNotice before backgroundTasks = []')

    close_body = function_body(CLAUDE_SESSION.read_text(encoding='utf-8'), 'private func didClose()')
    if close_body is None:
        failures.append('could not extract ClaudeSession.didClose(); update the extraction marker')
    elif 'if !isStopping, isStarted { backgroundTasks.removeAll() }' not in close_body:
        failures.append('ClaudeSession.didClose() must keep reported exits from emptying the runtime\'s background tasks before .exited')

    try:
        catalog = json.loads(CATALOG.read_text(encoding='utf-8'))
    except ValueError as error:
        failures.append(f'Localizable.xcstrings is not valid JSON: {error}')
        catalog = {}
    strings = catalog.get('strings', {})
    required_keys = (
        '%@ exited while background tasks were still running: %@. They were stopped.',
        'Stopped background tasks with the session: %@.',
        '%@ picked the work back up on its own.',
    )
    languages = ('zh-Hans', 'zh-Hant', 'ja', 'ko', 'fr')
    for key in required_keys:
        entry = strings.get(key)
        localizations = entry.get('localizations', {}) if isinstance(entry, dict) else {}
        for language in languages:
            value = (
                localizations
                .get(language, {})
                .get('stringUnit', {})
                .get('value')
                if isinstance(localizations, dict) else None
            )
            if not isinstance(value, str) or not value.strip():
                failures.append(f'Localizable.xcstrings is missing a {language} value for {key!r}')

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('OK: background task retention, lost-task wake, notices and localizations are intact')
    return 0


if __name__ == '__main__':
    sys.exit(main())
