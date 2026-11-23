#!/usr/bin/env python3
"""Offline source guard for ZCode builtinConfig, runtimePreferences, tool error isolation, and turn resultType."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ZCODE_CLI = ROOT / 'Tivano/Services/Providers/ZCodeCLI.swift'
ZCODE_SESSION = ROOT / 'Tivano/Services/Providers/ZCodeSession.swift'

COMMENT_OR_STRING = re.compile(r'"(?:[^"\\]|\\.)*"|//[^\n]*|/\*[\s\S]*?\*/')


def strip_comments(text):
    return COMMENT_OR_STRING.sub(lambda m: m.group(0) if m.group(0).startswith('"') else ' ', text)


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
    for path in (ZCODE_CLI, ZCODE_SESSION):
        if not path.is_file():
            print(f'FAIL: {path.relative_to(ROOT)} is missing', file=sys.stderr)
            return 1

    cli_code = strip_comments(ZCODE_CLI.read_text(encoding='utf-8'))
    session_code = strip_comments(ZCODE_SESSION.read_text(encoding='utf-8'))

    try:
        builtin_config = block(cli_code, 'static func builtinConfig(', ZCODE_CLI.relative_to(ROOT))
        runtime_prefs = block(cli_code, 'static func runtimePreferences()', ZCODE_CLI.relative_to(ROOT))
        handle_notification = block(session_code, 'private func handleNotification(', ZCODE_SESSION.relative_to(ROOT))
    except ValueError as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1

    if '.zcode/v2/runtime/provider' not in builtin_config or 'revision' not in builtin_config:
        failures.append('ZCodeCLI.swift: builtinConfig() must prefer the newest runtime zcode-builtin.json revision')

    mode_match = re.search(
        r'settings\?\["toolSearchMode"\]\?\.string,\s*\[([^\]]+)\]\.contains\(mode\)',
        runtime_prefs,
    )
    if not mode_match:
        failures.append('ZCodeCLI.swift: runtimePreferences() must filter toolSearchMode against an explicit mode list')
    else:
        allowed_modes = mode_match.group(1)
        if '"native"' in allowed_modes:
            failures.append('ZCodeCLI.swift: runtimePreferences() must not forward toolSearchMode "native"')
        for mode in ('"auto"', '"local"', '"off"'):
            if mode not in allowed_modes:
                failures.append(f'ZCodeCLI.swift: runtimePreferences() toolSearchMode list is missing {mode}')

    switch_marker = 'switch type {'
    if switch_marker not in handle_notification:
        failures.append('ZCodeSession.swift: handleNotification(_:_:) is missing `switch type`')
    else:
        pre_switch = handle_notification[:handle_notification.index(switch_marker)]
        error_guard = re.search(r'if\b[^\n{]*payload\["error"\][^\n{]*\{', pre_switch)
        if not error_guard:
            failures.append('ZCodeSession.swift: generic payload["error"] early-return guard not found before switch type')
        elif 'type != "tool.updated"' not in error_guard.group(0):
            failures.append('ZCodeSession.swift: generic payload["error"] early-return must exclude type == "tool.updated"')

        turn_completed_marker = 'case "turn.completed":'
        default_marker = 'default:'
        if turn_completed_marker not in handle_notification or default_marker not in handle_notification:
            failures.append('ZCodeSession.swift: case "turn.completed" block not found in handleNotification(_:_:)')
        else:
            start = handle_notification.index(turn_completed_marker)
            end = handle_notification.index(default_marker, start)
            turn_completed = handle_notification[start:end]
            for marker in (
                'payload["resultType"]?.string',
                'payload["usage"]',
                'turnUsage =',
                '"cancelled"',
                '.interrupted',
                '"error_"',
                '.failed',
                'AppText.localized("ZCode reported an error.")',
                '.completed',
            ):
                if marker not in turn_completed:
                    failures.append(f'ZCodeSession.swift: turn.completed is missing {marker!r}')

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('PASS: ZCode builtinConfig, runtimePreferences, tool.updated error isolation, and turn.completed resultType contracts hold.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
