#!/usr/bin/env python3
"""Offline guard: no removeAll predicate reads a ForEach element binding.

Inside `ForEach($items) { $item in ... }`, `item` reads through a Binding back
into `items`. A predicate such as `items.removeAll { $0.id == item.id }` reads
it while removeAll holds exclusive access to the same array, which traps with
"Simultaneous accesses" (Release 2.5.12 crashed removing a model preset).
Capture the value first: `let id = item.id; items.removeAll { $0.id == id }`.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Tivano'
FOR_EACH = re.compile(r'ForEach\(\$[\w.]+\)\s*\{\s*\$(\w+)\s+in\b')
REMOVE_ALL = re.compile(r'\.removeAll\s*(?:\(\s*where:\s*)?\{')
# Files whose ForEach($...) sites must be found, so a parser drift cannot pass silently.
KNOWN = ('Tivano/App/Views/Settings/ChimeraPresetsSection.swift',
         'Tivano/App/Views/Settings/MCPSettingsPage.swift',
         'Tivano/App/Views/Chat/ChatView.swift')


def closing(text, open_index):
    """Index just past the brace matching text[open_index] == '{'."""
    depth = 0
    for index in range(open_index, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return index + 1
    return len(text)


def main():
    failures, sites, seen = [], 0, set()
    for path in sorted(SOURCES.rglob('*.swift')):
        text = path.read_text(encoding='utf-8')
        relative = path.relative_to(ROOT).as_posix()
        for loop in FOR_EACH.finditer(text):
            sites += 1
            seen.add(relative)
            element = re.compile(r'(?<![\w$.])' + re.escape(loop.group(1)) + r'\b')
            body = text[loop.end():closing(text, text.index('{', loop.start()))]
            for removal in REMOVE_ALL.finditer(body):
                predicate = body[removal.end() - 1:closing(body, removal.end() - 1)]
                if element.search(predicate):
                    line = text.count('\n', 0, loop.end() + removal.start()) + 1
                    failures.append(f'{relative}:{line}: removeAll predicate reads element binding '
                                    f'`{loop.group(1)}`; capture the value before removeAll')
    missing = [name for name in KNOWN if name not in seen]
    if missing:
        print(f'FAIL: no ForEach($...) site found in {", ".join(missing)}; update KNOWN or the parser',
              file=sys.stderr)
        return 1
    for failure in failures:
        print(failure)
    if failures:
        print(f'FAIL: {len(failures)} removeAll predicate(s) read a ForEach element binding', file=sys.stderr)
        return 1
    print(f'OK: {sites} ForEach($...) site(s) remove elements without reading their own binding')
    return 0


if __name__ == '__main__':
    sys.exit(main())
