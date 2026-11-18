#!/usr/bin/env python3
"""Offline guard: hover cursors use SwiftUI pointerStyle, not the global NSCursor stack.

NSCursor.push/pop in hover handlers restores whatever cursor was underneath on pop (often the
text I-beam), after the pointer has already left for chrome with no cursor rects, so the
I-beam sticks app-wide. Only the AppKit drag handle, which pairs push/pop around one drag in
mouseDown/mouseUp, may use the stack.
"""
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
TIVANO_DIR = ROOT / 'Tivano'
ALLOWED = {'Tivano/UI/Chrome/DragHandle.swift'}
STACK_CALL = re.compile(r'NSCursor\s*\.\s*pop\s*\(|\.push\s*\(\s*\)')
HOVER_FILES = ('Tivano/UI/Markdown/LinkHover.swift', 'Tivano/UI/Common/PointingHandCursor.swift')


def main():
    if not TIVANO_DIR.is_dir():
        print('FAIL: Tivano/ source directory not found')
        return 1
    failures = []
    for path in sorted(TIVANO_DIR.rglob('*.swift')):
        rel = path.relative_to(ROOT).as_posix()
        if rel in ALLOWED:
            continue
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            code = line.split('//', 1)[0]
            if STACK_CALL.search(code) and ('NSCursor' in code or 'cursor' in code.lower()):
                failures.append(f'{rel}:{number}: {line.strip()}')
    for rel in HOVER_FILES:
        path = ROOT / rel
        if not path.is_file():
            failures.append(f'{rel}: missing (hover cursor modifier moved; update this check)')
        elif 'pointerStyle(' not in path.read_text(encoding='utf-8'):
            failures.append(f'{rel}: no pointerStyle( (hover cursor must be declarative)')
    if failures:
        print('FAIL: NSCursor stack used outside the drag handle:')
        for failure in failures:
            print('  ' + failure)
        return 1
    print('PASS: cursor_stack_checks')
    return 0


if __name__ == '__main__':
    sys.exit(main())
