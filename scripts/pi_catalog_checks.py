#!/usr/bin/env python3
"""Offline guard: Tivano's Pi model probe loads pi's extensions.

`PiCLI.listModels` reads the catalog from a throwaway `pi --mode rpc`. It used to
pass `--no-extensions`, which hid every provider an extension registers (Pi's
Google Antigravity lives in `pi-multi-account` since pi 0.71 removed the built-in)
and kept static lists the extensions replace, so the model picker missed models a
Pi chat offers and listed ones it does not. Chat sessions load extensions; the
probe must match them.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Tivano/Services/Providers/PiCLI.swift'


def main():
    text = SOURCE.read_text(encoding='utf-8')
    start = text.find('static func listModels(')
    if start < 0:
        print(f'FAIL: {SOURCE.relative_to(ROOT)}: listModels not found; update the check', file=sys.stderr)
        return 1
    match = re.search(r'arguments:\s*\[([^\]]*)\]', text[start:])
    if not match or '"--mode", "rpc"' not in match.group(1):
        print('FAIL: listModels no longer starts `pi --mode rpc` with an arguments list; update the check',
              file=sys.stderr)
        return 1
    if '--no-extensions' in match.group(1) or '"-ne"' in match.group(1):
        print('FAIL: the Pi catalog probe disables extensions, so providers they register '
              '(google-antigravity) never reach the model list', file=sys.stderr)
        return 1
    print('PASS: the Pi catalog probe loads extensions like a Pi chat session.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
