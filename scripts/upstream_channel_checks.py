#!/usr/bin/env python3
"""Offline source guard: Claude's stable release channel, ACP config-option mode switches, and pi project trust."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CLI_UPDATES = ROOT / 'Tivano/Services/Providers/CLIUpdates.swift'
ACP = ROOT / 'Tivano/Services/Providers/ACPSession.swift'
PI = ROOT / 'Tivano/Services/Providers/PiSession.swift'
PI_RPC = ROOT / 'Tivano/Services/Providers/PiRPCSession.swift'


def main():
    for path in (CLI_UPDATES, ACP, PI, PI_RPC):
        if not path.is_file():
            print(f'FAIL: {path.relative_to(ROOT)} is missing', file=sys.stderr)
            return 1
    updates = CLI_UPDATES.read_text(encoding='utf-8')
    acp = ACP.read_text(encoding='utf-8')
    failures = []
    for kind in ('npm', 'bun', 'pnpm'):
        if re.search(r'return \.' + kind + r'\([^\n]*tag: "latest"\)', updates):
            failures.append(f'CLIUpdates.swift: .{kind} channel must take its tag from packageTag, not hardcode "latest"')
    if 'case .stable: return "stable"' not in updates:
        failures.append('CLIUpdates.swift: packageTag must map Claude stable to the npm "stable" dist-tag')
    if 'case .stable: return try await registryVersion("@anthropic-ai/claude-code", tag: "stable"' not in updates:
        failures.append('CLIUpdates.swift: unmanagedVersion must read Claude stable from the "stable" dist-tag')
    start = acp.find('case "config_option_update":')
    end = acp.find('case "session_info_update":', start)
    if start < 0 or end < 0:
        failures.append('ACPSession.swift: config_option_update case not found')
    elif '.modeChanged(' not in acp[start:end]:
        failures.append('ACPSession.swift: config_option_update must emit .modeChanged when the mode changes')
    # pi's --approve/--no-approve only decide project-local trust; tool approval is Tivano's gate.
    for pi_path in (PI, PI_RPC):
        if re.search(r'"--(no-)?approve"', pi_path.read_text(encoding='utf-8')):
            failures.append(f'{pi_path.name} must not pass --approve/--no-approve (they trust or ignore project files)')
    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('PASS: Claude stable channel uses its dist-tag; ACP config-option mode switches reach the UI; pi leaves project trust to the user.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
