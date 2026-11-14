#!/usr/bin/env python3
"""Offline guard against array element bindings in SwiftUI ForEach loops.

Release 2.5.12 crashed when a removeAll predicate read a ForEach($items)
element binding while removeAll held exclusive access to the same array. Release
2.5.27 (#51) crashed when a TextField value action used an element binding's
stale index after a delete or reorder. Iterate values and create each row's
Binding with an ID-based lookup instead.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Tivano'
FOR_EACH = re.compile(r'ForEach\s*\(\s*\$')
BY_ID = re.compile(r'first\(where:\s*\{\s*\$0\.id\s*==\s*id\s*\}\)')
BY_ID_INDEX = re.compile(r'firstIndex\(where:\s*\{\s*\$0\.id\s*==\s*id\s*\}\)')
CONVERTED = ('Tivano/App/Views/Settings/ChimeraPresetsSection.swift',
             'Tivano/App/Views/Settings/MCPSettingsPage.swift',
             'Tivano/App/Views/Chat/ChatView.swift')


def main():
    paths = sorted(SOURCES.rglob('*.swift'))
    if not paths:
        print(f'FAIL: no Swift files found under {SOURCES}', file=sys.stderr)
        return 1

    failures, sources = [], {}
    for path in paths:
        text = path.read_text(encoding='utf-8')
        relative = path.relative_to(ROOT).as_posix()
        sources[relative] = text
        for loop in FOR_EACH.finditer(text):
            line = text.count('\n', 0, loop.start()) + 1
            failures.append(f'{relative}:{line}: ForEach($...) element bindings index the array and trap '
                            'after a delete/reorder; bind by id instead')

    for name in CONVERTED:
        text = sources.get(name)
        if text is None or not BY_ID.search(text) or not BY_ID_INDEX.search(text):
            print(f'FAIL: {name} no longer contains its by-id Binding lookup; '
                  'restore it or update the sanity marker', file=sys.stderr)
            return 1

    for failure in failures:
        print(failure)
    if failures:
        print(f'FAIL: {len(failures)} ForEach($...) element-binding loop(s) found', file=sys.stderr)
        return 1
    print(f'OK: no ForEach($...) element-binding loops in {len(paths)} Swift files; '
          'stable-ID sanity markers present')
    return 0


if __name__ == '__main__':
    sys.exit(main())
