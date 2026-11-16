#!/usr/bin/env python3
"""Offline source guard for DeepSeek Harness row patches against its 0.2.2 schema.

dsh rejects `tools.config.mode` (z.never since 0.2.1-rc.2), adds agent-team delegation rows
in 0.2.2-rc.3, and its persistent bash prints a different exit-code marker.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = ROOT / 'Tivano/Services/Providers'
PATCHES = PROVIDERS / 'DshPatches.swift'
BOOTSTRAP = PROVIDERS / 'DshMarketplaceBootstrap.swift'
ACP = PROVIDERS / 'ACPSession.swift'
DELEGATION = ('tool-subagent-control', 'tool-subagent', 'tool-subagent-fork', 'tool-workflow',
              'command-goal', 'tool-goal', 'agent-team', 'tool-agent-team')


def patch(source, name):
    match = re.search(r'static let ' + name + r' = #"""\n(.*?)\n\s*"""#', source, re.S)
    if not match:
        raise ValueError(f'DshPatches.swift: patch {name!r} not found')
    return match.group(1)


def rows(content):
    found, current = {}, None
    for line in content.splitlines():
        text = line.strip()
        if text.startswith('- id: '):
            current = text[len('- id: '):]
            found[current] = []
        elif current and text:
            found[current].append(text)
    return found


def main():
    for path in (PATCHES, BOOTSTRAP, ACP):
        if not path.is_file():
            print(f'FAIL: {path.relative_to(ROOT)} is missing', file=sys.stderr)
            return 1
    source = PATCHES.read_text(encoding='utf-8')
    failures = []
    try:
        ptc, minimal, no_delegation = (rows(patch(source, n)) for n in ('ptc', 'minimal', 'noDelegation'))
    except ValueError as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    for name, table in (('ptc', ptc), ('minimal', minimal), ('noDelegation', no_delegation)):
        if 'tools' in table:
            failures.append(f'DshPatches.{name} must not configure the removed tools.config.mode row')
    if ptc.get('tool-executor-native') != ['disabled: true'] or ptc.get('tool-executor-ptc') != ['disabled: false']:
        failures.append('DshPatches.ptc must disable tool-executor-native and enable tool-executor-ptc')
    for name, table in (('minimal', minimal), ('noDelegation', no_delegation)):
        for row in DELEGATION:
            if table.get(row) != ['disabled: true']:
                failures.append(f'DshPatches.{name} must disable delegation row {row}')
    for path in (PATCHES, BOOTSTRAP):
        if 'command-goal|agent-team|tool-agent-team)' not in path.read_text(encoding='utf-8'):
            failures.append(f'{path.name}: delegation package regex must cover agent-team and tool-agent-team')
    acp = ACP.read_text(encoding='utf-8')
    for marker in ('"[exit code: "', '"[Command finished with exit code "'):
        if marker not in acp:
            failures.append(f'ACPSession.swift: dsh bash exit-code parsing is missing {marker}')
    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('PASS: dsh patches use executor rows, disable every delegation row, and read both exit-code markers.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
