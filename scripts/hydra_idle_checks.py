#!/usr/bin/env python3
"""Offline guard for agy ACP turn-timeout absence, output visibility, and Hydra's silent-head backstop.

agy's old headless print timeout was a whole-turn cap that killed a working head.
Under `agy acp`, `ACPSession` must not add a whole-turn timeout flag to
Antigravity's launch arguments or wrap `session/prompt` in a turn deadline, and
it must expose `lastOutputAt` from the child process for `.antigravity` so
HydraWatchdog can see liveness. Meanwhile, Hydra's watchdog must still stop a
completely silent Antigravity head at `abandonedAfter` (1800 s) even when edits
or a running tool make the stalled-head branch skip it.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ACP = ROOT / 'Tivano/Services/Providers/ACPSession.swift'
HYDRA = ROOT / 'Tivano/App/AppModel+Hydra.swift'


def function_body(text, marker):
    if text.count(marker) != 1:
        return None
    start = text.find(marker)
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
    for path in (ACP, HYDRA):
        if not path.is_file():
            failures.append(f'{path.relative_to(ROOT)} is missing')
    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1

    acp = ACP.read_text(encoding='utf-8')
    hydra = HYDRA.read_text(encoding='utf-8')

    launch_body = function_body(acp, 'private func launchArguments(logFileURL: URL?) -> [String]')
    if launch_body is None:
        failures.append('could not extract ACPSession.launchArguments(logFileURL:); update the extraction marker')
    else:
        if launch_body.count('case .antigravity:') != 1 or launch_body.count('case .cursor:') != 1:
            failures.append('could not extract .antigravity branch in ACPSession.launchArguments(logFileURL:)')
        else:
            agy_branch = launch_body[launch_body.index('case .antigravity:'):launch_body.index('case .cursor:')]
            agy_launch = function_body(acp, 'private func antigravityLaunchArguments(logFileURL: URL?) -> [String]') or ''
            if 'antigravityLaunchArguments(logFileURL: logFileURL)' not in agy_branch or not agy_launch:
                failures.append('ACPSession .antigravity launchArguments must delegate to antigravityLaunchArguments(logFileURL:)')
            if '"acp"' not in agy_launch or '"--add-dir"' not in agy_launch:
                failures.append('ACPSession .antigravity launchArguments must launch `acp --add-dir`')
            if re.search(r'"--[a-z-]*timeout', agy_launch):
                failures.append('ACPSession .antigravity launchArguments must not pass a whole-turn timeout flag')
    if '"--print-timeout"' in acp:
        failures.append('ACPSession must not pass `--print-timeout`')

    last_output = function_body(acp, 'var lastOutputAt: Date?')
    if last_output is None:
        failures.append('could not extract ACPSession.lastOutputAt; update the extraction marker')
    else:
        if 'configuration.provider == .antigravity' not in last_output or 'process?.lastOutputAt' not in last_output:
            failures.append('ACPSession.lastOutputAt must expose process?.lastOutputAt for .antigravity so HydraWatchdog sees output')

    send_body = function_body(acp, 'func send(_ input: TurnInput) async throws')
    if send_body is None:
        failures.append('could not extract ACPSession.send(_:); update the extraction marker')
    else:
        if 'connection.request("session/prompt"' not in send_body:
            failures.append('ACPSession.send(_:) must invoke connection.request("session/prompt", ...) directly without a whole-turn deadline')
        if 'deadlineRequest(connection, "session/prompt"' in send_body:
            failures.append('ACPSession.send(_:) must not wrap session/prompt in deadlineRequest')

    if not re.search(r'static\s+let\s+abandonedAfter\s*:\s*TimeInterval\s*=\s*1800\b', hydra):
        failures.append('HydraWatchdog must declare abandonedAfter as 1800 seconds')

    body = function_body(hydra, 'private func watchHydraHeads()')
    if body is None:
        failures.append('could not extract watchHydraHeads(); update the extraction marker')
    else:
        markers = {
            'abandoned': 'if head.provider == .antigravity, idle >= HydraWatchdog.abandonedAfter',
            'running tool skip': 'if hasRunningTool {',
            'no-edit stall condition': 'headRuntime.hydraEditCount == 0',
        }
        positions = {}
        for name, marker in markers.items():
            position = body.find(marker)
            positions[name] = position
            if position < 0:
                failures.append(f'watchHydraHeads() is missing the {name} marker: {marker}')
        if positions['abandoned'] >= 0:
            for name in ('running tool skip', 'no-edit stall condition'):
                if positions[name] >= 0 and positions['abandoned'] > positions[name]:
                    failures.append(f'the abandonedAfter check must appear before the {name}')

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('OK: agy ACP has no whole-turn cap, exposes lastOutputAt, and Hydra stops silent heads before its running-tool/edit skips')
    return 0


if __name__ == '__main__':
    sys.exit(main())
