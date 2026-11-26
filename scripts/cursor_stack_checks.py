#!/usr/bin/env python3
"""Offline guard: hover cursors use SwiftUI pointerStyle, not the global NSCursor stack.

NSCursor.push/pop in hover handlers restores whatever cursor was underneath on pop (often the
text I-beam), after the pointer has already left for chrome with no cursor rects, so the
I-beam sticks app-wide. Only the AppKit drag handle, which pairs push/pop around one drag in
mouseDown/mouseUp, may use the stack.

Also enforces cursor-claim invariants: floating chrome surfaces and standalone panels claim
`.pointerStyle(.default)`, `NoWindowDragView` installs a cursor rect, `LinkHover.swift`
resets hover state in `.onDisappear`, and `MarkdownView(` is never wrapped directly in
container-level `.textSelection(.enabled)`.
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

CLAIMS = (
    ('Tivano/UI/Chrome/Chrome.swift', 'ChromeGlassSurface'),
    ('Tivano/UI/Chrome/Chrome.swift', 'FloatingGlassSurface'),
    ('Tivano/UI/Chrome/Chrome.swift', 'SidebarTrayModifier'),
    ('Tivano/UI/Chrome/Chrome.swift', 'ChromeIconButton'),
    ('Tivano/UI/Chrome/Chrome.swift', 'ChromeMenuButton'),
    ('Tivano/UI/Chrome/Chrome.swift', 'ChromeCircleButton'),
    ('Tivano/UI/Chrome/Popovers.swift', 'presentedChrome'),
    ('Tivano/UI/Chrome/Popovers.swift', 'PopoverItem'),
    ('Tivano/UI/Markdown/MarkdownView.swift', 'CopyButton'),
    ('Tivano/App/Views/Chat/ChatView.swift', 'ChatChromeRow'),
    ('Tivano/App/Views/Chat/SubagentPanel.swift', 'SubagentPanel'),
    ('Tivano/App/Views/Chat/SubagentPanel.swift', 'SubagentWorkingBox'),
    ('Tivano/App/Views/Chat/HydraPanel.swift', 'HydraPanel'),
    ('Tivano/App/Views/Chat/HydraPanel.swift', 'HydraHeadsButton'),
    ('Tivano/App/Views/Chat/HydraPanel.swift', 'HydraHeadFooter'),
    ('Tivano/App/Views/Palette/CommandPalette.swift', 'CommandPalette'),
    ('Tivano/App/Views/Composer/UsageLimitTab.swift', 'UsageLimitTabSurface'),
    ('Tivano/App/Views/Composer/FollowUpQueueTab.swift', 'FollowUpQueueTab'),
    ('Tivano/App/Views/Composer/RequestCards.swift', 'ApprovalCard'),
    ('Tivano/App/Views/Terminal/TerminalPanel.swift', 'TerminalPanel'),
    ('Tivano/App/Views/Settings/SettingsView.swift', 'SettingsPageChrome'),
)

DECL_BOUNDARY = re.compile(
    r'^(?P<indent>[ \t]*)(?:(?:struct|class|enum|extension|func|private|fileprivate|final)\b|@|//\s*MARK\b)'
)
MARKDOWN_VIEW_CALL = re.compile(r'MarkdownView\(')


def declaration_span(text, name):
    lines = text.splitlines()
    start_pattern = re.compile(
        rf'^(?P<indent>[ \t]*)(?:(?:private|fileprivate|final)\s+)*(?:struct|class|enum|extension|func)\s+{re.escape(name)}\b'
    )
    start_index = None
    start_indent = 0
    for idx, line in enumerate(lines):
        match = start_pattern.match(line)
        if match:
            start_index = idx
            start_indent = len(match.group('indent'))
            break
    if start_index is None:
        return None
    end_index = len(lines)
    for idx in range(start_index + 1, len(lines)):
        boundary = DECL_BOUNDARY.match(lines[idx])
        if boundary and len(boundary.group('indent')) <= start_indent:
            end_index = idx
            break
    return '\n'.join(lines[start_index:end_index])


def strip_line_comments(text):
    return '\n'.join(line.split('//', 1)[0] for line in text.splitlines())


def main():
    if not TIVANO_DIR.is_dir():
        print('FAIL: Tivano/ source directory not found')
        return 1
    failures = []
    texts = {}
    for path in sorted(TIVANO_DIR.rglob('*.swift')):
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding='utf-8')
        texts[rel] = text
        lines = text.splitlines()
        code_lines = [line.split('//', 1)[0] for line in lines]
        if rel not in ALLOWED:
            for number, (line, code) in enumerate(zip(lines, code_lines), 1):
                if STACK_CALL.search(code) and ('NSCursor' in code or 'cursor' in code.lower()):
                    failures.append(f'{rel}:{number}: {line.strip()}')
        for idx, code in enumerate(code_lines):
            if MARKDOWN_VIEW_CALL.search(code):
                if any('.textSelection(.enabled)' in candidate for candidate in code_lines[idx:idx + 4]):
                    failures.append(f'{rel}:{idx + 1}: MarkdownView( followed by .textSelection(.enabled)')

    def read_rel(rel):
        if rel in texts:
            return texts[rel]
        path = ROOT / rel
        if not path.is_file():
            return None
        text = path.read_text(encoding='utf-8')
        texts[rel] = text
        return text

    for rel in HOVER_FILES:
        text = read_rel(rel)
        if text is None:
            failures.append(f'{rel}: missing (hover cursor modifier moved; update this check)')
        elif 'pointerStyle(' not in text:
            failures.append(f'{rel}: no pointerStyle( (hover cursor must be declarative)')

    for rel, name in CLAIMS:
        text = read_rel(rel)
        if text is None:
            failures.append(f'{rel}: missing (cannot check {name})')
            continue
        span = declaration_span(text, name)
        if span is None:
            failures.append(f'{rel}: declaration {name} not found')
        elif 'pointerStyle(.default)' not in strip_line_comments(span):
            failures.append(f'{rel}: {name} missing pointerStyle(.default)')

    chrome_rel = 'Tivano/UI/Chrome/Chrome.swift'
    chrome_text = read_rel(chrome_rel)
    if chrome_text is None:
        failures.append(f'{chrome_rel}: missing (cannot check NoWindowDragView)')
    else:
        span = declaration_span(chrome_text, 'NoWindowDragView')
        if span is None:
            failures.append(f'{chrome_rel}: declaration NoWindowDragView not found')
        elif 'addCursorRect' not in strip_line_comments(span):
            failures.append(f'{chrome_rel}: NoWindowDragView missing addCursorRect')

    link_hover_rel = 'Tivano/UI/Markdown/LinkHover.swift'
    link_hover_text = read_rel(link_hover_rel)
    if link_hover_text is None:
        failures.append(f'{link_hover_rel}: missing (cannot check .onDisappear)')
    elif '.onDisappear' not in strip_line_comments(link_hover_text):
        failures.append(f'{link_hover_rel}: missing .onDisappear')

    # The composer's AppKit text view puts up the I-beam; the SwiftUI around it never sets the
    # arrow back (its pointer style does not change), so the field must restore it on exit.
    composer_rel = 'Tivano/App/Views/Composer/ComposerTextView.swift'
    composer_text = read_rel(composer_rel)
    if composer_text is None:
        failures.append(f'{composer_rel}: missing (cannot check the I-beam hand-back)')
    else:
        span = declaration_span(composer_text, 'ComposerNSTextView')
        code = strip_line_comments(span or '')
        if 'override func mouseExited' not in code or 'NSCursor.arrow.set()' not in code:
            failures.append(f'{composer_rel}: ComposerNSTextView must restore the arrow when the pointer leaves it')

    if failures:
        print('FAIL: cursor_stack_checks:')
        for failure in failures:
            print('  ' + failure)
        return 1
    print('PASS: cursor_stack_checks')
    return 0


if __name__ == '__main__':
    sys.exit(main())
