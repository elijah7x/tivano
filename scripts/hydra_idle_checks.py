#!/usr/bin/env python3
"""Offline guard for agy's turn timeout and Hydra's silent-head backstop.

agy's 30-minute print timeout was a whole-turn cap that killed a working head.
It must stay disabled, and Hydra's watchdog must stop a completely silent head
even when edits or a running tool make the existing stalled-head branch skip it.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
AGY = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'
HYDRA = ROOT / 'Tivano/App/AppModel+Hydra.swift'


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
    agy = AGY.read_text(encoding='utf-8')
    hydra = HYDRA.read_text(encoding='utf-8')

    if '"--print-timeout", "0"' not in agy:
        failures.append('AntigravitySession must pass `--print-timeout` as `0`')
    if '"--print-timeout", "30m"' in agy:
        failures.append('AntigravitySession must not restore the 30m whole-turn cap')
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
    print('OK: agy has no whole-turn cap and Hydra stops silent heads before its running-tool/edit skips')
    return 0


if __name__ == '__main__':
    sys.exit(main())
