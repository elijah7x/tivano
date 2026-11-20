#!/usr/bin/env python3
"""Offline check for proportional markdown typography, list marker alignment, nested list spacing, and prose run segmentation."""
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]

RECENT_CACHE = ROOT / 'Tivano/Core/Support/RecentCache.swift'
MARKDOWN_PARSER = ROOT / 'Tivano/UI/Markdown/MarkdownParser.swift'
TYPE_SCALE = ROOT / 'Tivano/UI/Theme/TypeScale.swift'
MARKDOWN_VIEW = ROOT / 'Tivano/UI/Markdown/MarkdownView.swift'
PROSE_RUN_VIEW = ROOT / 'Tivano/UI/Markdown/ProseRunView.swift'
LINK_PARAGRAPH_VIEW = ROOT / 'Tivano/UI/Markdown/LinkParagraphView.swift'
TIMELINE_ROWS = ROOT / 'Tivano/App/Views/Chat/TimelineRows.swift'


def fail(message: str) -> None:
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def require_contains(source: str, needle: str, label: str) -> None:
    if needle not in source:
        fail(f'expected {needle!r} in {label}')


def mask_comments_and_strings(source: str) -> str:
    pattern = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')
    return pattern.sub(lambda match: re.sub(r'[^\n]', ' ', match.group(0)), source)


def extract_braced_block(source: str, header: str, label: str, include_header: bool) -> str:
    idx = source.find(header)
    if idx < 0:
        fail(f'missing marker {header!r} in {label}')
    if source.find(header, idx + len(header)) >= 0:
        fail(f'ambiguous marker {header!r} in {label}')
    masked = mask_comments_and_strings(source)
    brace_start = masked.find('{', idx + len(header) - 1)
    if brace_start < 0:
        fail(f'missing opening brace after {header!r} in {label}')
    depth = 0
    for pos in range(brace_start, len(masked)):
        ch = masked[pos]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                if include_header:
                    return source[idx:pos + 1]
                return source[brace_start + 1:pos]
    fail(f'unbalanced braces for {header!r} in {label}')
    return ''


def extract_unique_decl(source: str, pattern: str, label: str, strip_access: bool = False) -> str:
    masked = mask_comments_and_strings(source)
    matches = list(re.finditer(pattern, masked))
    if not matches:
        fail(f'missing declaration {pattern!r} in {label}')
    if len(matches) > 1:
        fail(f'ambiguous declaration {pattern!r} in {label} ({len(matches)} matches)')
    match = matches[0]
    search_from = match.start()
    if match.group(0).endswith('('):
        paren_depth = 0
        pos = match.end() - 1
        while pos < len(masked):
            ch = masked[pos]
            if ch == '(':
                paren_depth += 1
            elif ch == ')':
                paren_depth -= 1
                if paren_depth == 0:
                    search_from = pos + 1
                    break
            pos += 1
        else:
            fail(f'unbalanced parameter list for {pattern!r} in {label}')
    brace_start = masked.find('{', search_from)
    if brace_start < 0:
        fail(f'missing opening brace for {pattern!r} in {label}')
    depth = 0
    for pos in range(brace_start, len(masked)):
        ch = masked[pos]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                decl = source[match.start():pos + 1]
                if strip_access:
                    header_len = brace_start - match.start()
                    header = re.sub(r'\b(?:private|fileprivate)\s+', '', decl[:header_len])
                    return header + decl[header_len:]
                return decl
    fail(f'unbalanced braces for {pattern!r} in {label}')
    return ''


SWIFT_HARNESS_TEMPLATE = '''import AppKit
import Foundation
import SwiftUI

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct HydraPersona: Hashable, Sendable {
    var name: String
}

struct HydraMentionTarget: Hashable, Sendable {
    var url: URL
}

@MainActor
enum LinkParagraphView {
    static let dimmedLabel = NSColor.secondaryLabelColor

    static func mutableAttributed(
        source: String,
        pointSize: CGFloat,
        codePointSize: CGFloat = TypeScale.shared.code(12),
        dimmed: Bool,
        streaming: Bool = false,
        mentions: [HydraPersona] = [],
        targets: [String: HydraMentionTarget] = [:],
        paragraphStyle: NSParagraphStyle? = nil
    ) -> NSMutableAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: ThemeTypeface.nsFont(size: pointSize),
            .foregroundColor: dimmed ? dimmedLabel : NSColor.labelColor,
        ]
        if let paragraphStyle {
            attributes[.paragraphStyle] = paragraphStyle
        }
        return NSMutableAttributedString(string: source, attributes: attributes)
    }
}

__MARKDOWN_SEGMENT_DECL__

@MainActor
enum MarkdownView {
__CAN_MERGE_DECL__

__SEGMENTS_DECL__

__INTER_BLOCK_GAP_DECL__
}

@MainActor
enum ProseRunRepresentable {
__APPEND_DECL__

__SEPARATE_DECL__
}

@MainActor
@main
struct MarkdownTypographyChecks {
    private struct BuiltLine {
        let text: String
        let marker: String?
        let markerWidth: CGFloat
        let style: NSParagraphStyle
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \\(message)\\n", stderr)
            exit(1)
        }
    }

    private static func approxEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func buildAttributed(_ markdown: String, pointSize: CGFloat) -> NSAttributedString {
        let blocks = MarkdownParser.parse(markdown)
        let out = NSMutableAttributedString()
        let spacing = TypeScale.proseParagraphSpacing(pointSize)
        for block in blocks {
            ProseRunRepresentable.append(
                block,
                depth: 0,
                indent: 0,
                dimmed: false,
                afterSpacing: spacing,
                pointSize: pointSize,
                mentions: [],
                targets: [:],
                to: out
            )
        }
        return out
    }

    private static func inspectLines(in attributed: NSAttributedString) -> [BuiltLine] {
        let nsString = attributed.string as NSString
        let totalLength = nsString.length
        var lines: [BuiltLine] = []
        var offset = 0
        while offset < totalLength {
            let range = nsString.lineRange(for: NSRange(location: offset, length: 0))
            var contentEnd = range.location + range.length
            while contentEnd > range.location {
                let ch = nsString.character(at: contentEnd - 1)
                if ch == 0x0A || ch == 0x0D {
                    contentEnd -= 1
                } else {
                    break
                }
            }
            let contentRange = NSRange(location: range.location, length: contentEnd - range.location)
            let lineText = nsString.substring(with: contentRange)
            guard contentRange.length > 0,
                  let style = attributed.attribute(.paragraphStyle, at: contentRange.location, effectiveRange: nil) as? NSParagraphStyle else {
                fputs("FAIL: missing NSParagraphStyle on line '\\(lineText)'\\n", stderr)
                exit(1)
            }
            var marker: String? = nil
            var markerWidth: CGFloat = 0
            if let tabRange = lineText.range(of: "\\t") {
                let prefix = String(lineText[..<tabRange.lowerBound])
                let utf16PrefixLen = (prefix as NSString).length
                marker = prefix
                let markerAttr = NSMutableAttributedString(
                    attributedString: attributed.attributedSubstring(
                        from: NSRange(location: contentRange.location, length: utf16PrefixLen)
                    )
                )
                markerAttr.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: markerAttr.length))
                markerWidth = markerAttr.size().width
            }
            lines.append(BuiltLine(text: lineText, marker: marker, markerWidth: markerWidth, style: style))
            offset = range.location + range.length
        }
        return lines
    }

    static func main() {
        // a) Baseline TypeScale metrics at default 15pt.
        expect(TypeScale.proseLineSpacing(15) == 6.0, "TypeScale.proseLineSpacing(15) must be 6.0, got \\(TypeScale.proseLineSpacing(15))")
        expect(TypeScale.proseParagraphSpacing(15) == 20, "TypeScale.proseParagraphSpacing(15) must be 20, got \\(TypeScale.proseParagraphSpacing(15))")

        for serif in [false, true] {
            TypeScale.shared.serif = serif
            for pointSizeInt in 11...18 {
                let pointSize = CGFloat(pointSizeInt)
                let lineSpacing = TypeScale.proseLineSpacing(pointSize)

                // a) List item spacing must exceed line spacing at every zoom size.
                expect(
                    TypeScale.proseListItemSpacing(pointSize, depth: 0) > lineSpacing,
                    "proseListItemSpacing(\\(pointSize), depth: 0) must exceed proseLineSpacing(\\(pointSize)) (serif=\\(serif))"
                )
                expect(
                    TypeScale.proseListItemSpacing(pointSize, depth: 1) > lineSpacing,
                    "proseListItemSpacing(\\(pointSize), depth: 1) must exceed proseLineSpacing(\\(pointSize)) (serif=\\(serif))"
                )

                // b) Heading scale ordering and bottom spacing bound.
                let h1 = TypeScale.proseHeadingPointSize(pointSize, level: 1)
                let h2 = TypeScale.proseHeadingPointSize(pointSize, level: 2)
                let h3 = TypeScale.proseHeadingPointSize(pointSize, level: 3)
                let h4 = TypeScale.proseHeadingPointSize(pointSize, level: 4)
                expect(
                    h1 > h2 && h2 > h3 && h3 >= h4 && h4 == pointSize,
                    "heading scale invalid at \\(pointSize)pt (serif=\\(serif)): h1=\\(h1), h2=\\(h2), h3=\\(h3), h4=\\(h4)"
                )
                expect(
                    TypeScale.proseHeadingBottomSpacing(pointSize, level: 1) < TypeScale.proseParagraphSpacing(pointSize),
                    "proseHeadingBottomSpacing(\\(pointSize), level: 1) must be < proseParagraphSpacing(\\(pointSize))"
                )

                // c) Nested list last-item regression.
                let nestedMarkdown = """
                1. One
                   - sub
                   - sub
                2. Two
                   - sub
                   - sub
                3. Three
                   - sub
                   - sub
                4. Four
                   - sub
                   - sub

                Trailing paragraph
                """
                let nestedLines = inspectLines(in: buildAttributed(nestedMarkdown, pointSize: pointSize))
                expect(nestedLines.count == 13, "expected 13 built lines in nested list check, got \\(nestedLines.count)")
                let expectedChild = max(0, TypeScale.proseListChildSpacing(pointSize) - lineSpacing)
                let expectedGroup = max(0, TypeScale.proseListGroupSpacing(pointSize) - lineSpacing)
                let expectedParagraph = max(0, TypeScale.proseParagraphSpacing(pointSize) - lineSpacing)
                expect(
                    !approxEqual(expectedChild, expectedParagraph, tolerance: 0.5),
                    "proseListChildSpacing must remain distinct from proseParagraphSpacing at \\(pointSize)pt"
                )
                for itemIndex in 0..<4 {
                    let parentLine = nestedLines[itemIndex * 3]
                    let firstSub = nestedLines[itemIndex * 3 + 1]
                    let secondSub = nestedLines[itemIndex * 3 + 2]
                    expect(parentLine.marker == "\\(itemIndex + 1).", "expected marker '\\(itemIndex + 1).' on line '\\(parentLine.text)'")
                    expect(firstSub.text.hasSuffix("\\tsub") && secondSub.text.hasSuffix("\\tsub"), "expected nested '- sub' lines under item \\(itemIndex + 1)")
                    expect(
                        approxEqual(parentLine.style.paragraphSpacing, expectedChild),
                        "item '\\(parentLine.text)' paragraphSpacing (\\(parentLine.style.paragraphSpacing)) must equal expectedChild (\\(expectedChild)) at \\(pointSize)pt serif=\\(serif)"
                    )
                    if itemIndex < 3 {
                        expect(
                            approxEqual(secondSub.style.paragraphSpacing, expectedGroup),
                            "second sub-bullet of item \\(itemIndex + 1) paragraphSpacing (\\(secondSub.style.paragraphSpacing)) must equal expectedGroup (\\(expectedGroup)) at \\(pointSize)pt serif=\\(serif)"
                        )
                    } else {
                        expect(
                            approxEqual(secondSub.style.paragraphSpacing, expectedParagraph),
                            "second sub-bullet of item 4 paragraphSpacing (\\(secondSub.style.paragraphSpacing)) must equal expectedParagraph (\\(expectedParagraph)) at \\(pointSize)pt serif=\\(serif)"
                        )
                    }
                }
                expect(nestedLines[12].text == "Trailing paragraph", "expected trailing paragraph at index 12")

                // d) Marker gutter & zoom safety.
                let unorderedLines = inspectLines(in: buildAttributed("- a\\n- b", pointSize: pointSize))
                let taskLines = inspectLines(in: buildAttributed("- [x] a\\n- [ ] b", pointSize: pointSize))
                let ordered1Lines = inspectLines(in: buildAttributed("1. a\\n9. b", pointSize: pointSize))
                let ordered2Lines = inspectLines(in: buildAttributed("9. a\\n10. b\\n11. c\\n12. d", pointSize: pointSize))
                let ordered3Lines = inspectLines(in: buildAttributed("99. a\\n100. b\\n101. c", pointSize: pointSize))

                expect(unorderedLines.count == 2, "expected 2 unordered lines")
                expect(taskLines.count == 2, "expected 2 task lines")
                expect(ordered1Lines.count == 2, "expected 2 1-digit ordered lines")
                expect(ordered2Lines.count == 4, "expected 4 2-digit ordered lines")
                expect(ordered3Lines.count == 3, "expected 3 3-digit ordered lines")

                for group in [unorderedLines, taskLines, ordered1Lines, ordered2Lines, ordered3Lines] {
                    for line in group {
                        expect(line.marker != nil, "expected marker tab on '\\(line.text)'")
                        expect(!line.style.tabStops.isEmpty, "expected tabStops on '\\(line.text)'")
                        let tabLocation = line.style.tabStops[0].location
                        expect(
                            approxEqual(tabLocation, line.style.headIndent),
                            "tabStops[0].location (\\(tabLocation)) must equal headIndent (\\(line.style.headIndent)) on '\\(line.text)' at \\(pointSize)pt serif=\\(serif)"
                        )
                        expect(
                            line.style.firstLineHeadIndent + line.markerWidth < tabLocation,
                            "marker '\\(line.marker ?? "")' overflowed tabStop: \\(line.style.firstLineHeadIndent) + \\(line.markerWidth) >= \\(tabLocation) at \\(pointSize)pt serif=\\(serif)"
                        )
                    }
                }

                expect(
                    approxEqual(unorderedLines[0].style.headIndent, ordered1Lines[0].style.headIndent),
                    "unordered (\\(unorderedLines[0].style.headIndent)) and 1-digit ordered (\\(ordered1Lines[0].style.headIndent)) top-level headIndent must match at \\(pointSize)pt serif=\\(serif)"
                )

                expect(ordered2Lines[0].marker == "9.", "expected marker '9.' in 9..12 list")
                expect(ordered2Lines[1].marker == "10.", "expected marker '10.' in 9..12 list")
                let right9 = ordered2Lines[0].style.firstLineHeadIndent + ordered2Lines[0].markerWidth
                let right10 = ordered2Lines[1].style.firstLineHeadIndent + ordered2Lines[1].markerWidth
                expect(
                    abs(right9 - right10) <= 1.0,
                    "right edges of '9.' (\\(right9)) and '10.' (\\(right10)) must match within 1.0pt at \\(pointSize)pt serif=\\(serif)"
                )
            }
        }

        // e) Segment safety.
        let proseMarkdown = """
        # Heading

        First paragraph.

        - Item one
        - Item two

        Second paragraph.
        """
        let proseBlocks = MarkdownParser.parse(proseMarkdown)
        expect(proseBlocks.count == 4, "expected 4 blocks in proseMarkdown, got \\(proseBlocks.count)")
        expect(
            MarkdownView.segments(proseBlocks) == [.prose(proseBlocks)],
            "MarkdownView.segments must merge paragraphs + headings + pure prose lists into a single .prose segment"
        )

        let quoteMarkdown = """
        Before quote.

        > Quoted line

        After quote.
        """
        let quoteBlocks = MarkdownParser.parse(quoteMarkdown)
        expect(quoteBlocks.count == 3, "expected 3 blocks in quoteMarkdown, got \\(quoteBlocks.count)")
        expect(
            MarkdownView.segments(quoteBlocks) == [.prose([quoteBlocks[0]]), .block(quoteBlocks[1]), .prose([quoteBlocks[2]])],
            "MarkdownView.segments must emit .quote as .block"
        )

        let codeListMarkdown = """
        Intro.

        - Item with code

          ```swift
          let x = 1
          ```

        Outro.
        """
        let codeListBlocks = MarkdownParser.parse(codeListMarkdown)
        expect(codeListBlocks.count == 3, "expected 3 blocks in codeListMarkdown, got \\(codeListBlocks.count)")
        if case .list(_, _, let items) = codeListBlocks[1],
           items.count == 1,
           case .code = items[0].children.first {
            // Expected list containing fenced code block child.
        } else {
            fputs("FAIL: expected .list containing a fenced code block child\\n", stderr)
            exit(1)
        }
        expect(
            MarkdownView.segments(codeListBlocks) == [.prose([codeListBlocks[0]]), .block(codeListBlocks[1]), .prose([codeListBlocks[2]])],
            "MarkdownView.segments must emit a .list containing a fenced code block child as .block"
        )
    }
}
'''


def render_template(template: str, replacements: dict[str, str]) -> str:
    rendered = template
    for token, value in replacements.items():
        if rendered.count(token) != 1:
            fail(f'internal harness template token mismatch for {token!r}')
        rendered = rendered.replace(token, value, 1)
    return rendered


def main() -> None:
    required = (
        RECENT_CACHE,
        MARKDOWN_PARSER,
        TYPE_SCALE,
        MARKDOWN_VIEW,
        PROSE_RUN_VIEW,
        LINK_PARAGRAPH_VIEW,
        TIMELINE_ROWS,
    )
    for path in required:
        if not path.is_file():
            fail(f'missing source file: {path.relative_to(ROOT)}')

    timeline_rows_src = TIMELINE_ROWS.read_text(encoding='utf-8')
    require_contains(timeline_rows_src, 'static let rowSpacing: CGFloat = 24', 'TimelineRows.swift')

    markdown_view_src = MARKDOWN_VIEW.read_text(encoding='utf-8')
    markdown_segment_decl = extract_unique_decl(
        markdown_view_src,
        r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public)\s+)*enum\s+MarkdownSegment\b',
        'MarkdownView.swift',
        strip_access=True,
    )
    can_merge_decl = extract_unique_decl(
        markdown_view_src,
        r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public|nonisolated|@MainActor)\s+)*static\s+func\s+canMergeIntoProseRun\s*\(',
        'MarkdownView.swift',
        strip_access=True,
    )
    segments_decl = extract_unique_decl(
        markdown_view_src,
        r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public|nonisolated|@MainActor)\s+)*static\s+func\s+segments\s*\(',
        'MarkdownView.swift',
        strip_access=True,
    )
    inter_block_gap_decl = extract_unique_decl(
        markdown_view_src,
        r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public|nonisolated|@MainActor)\s+)*static\s+func\s+interBlockGap\s*\(',
        'MarkdownView.swift',
        strip_access=True,
    )

    prose_run_src = PROSE_RUN_VIEW.read_text(encoding='utf-8')
    prose_run_body = extract_braced_block(
        prose_run_src,
        'struct ProseRunRepresentable: NSViewRepresentable {',
        'ProseRunView.swift',
        include_header=False,
    )
    append_decl = extract_unique_decl(
        prose_run_body,
        r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public|nonisolated|@MainActor)\s+)*static\s+func\s+append\s*\(',
        'ProseRunView.swift',
        strip_access=True,
    )
    separate_decl = extract_unique_decl(
        prose_run_body,
        r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public|nonisolated|@MainActor)\s+)*static\s+func\s+separate\s*\(',
        'ProseRunView.swift',
        strip_access=True,
    )

    harness_source = render_template(
        SWIFT_HARNESS_TEMPLATE,
        {
            '__MARKDOWN_SEGMENT_DECL__': markdown_segment_decl,
            '__CAN_MERGE_DECL__': can_merge_decl,
            '__SEGMENTS_DECL__': segments_decl,
            '__INTER_BLOCK_GAP_DECL__': inter_block_gap_decl,
            '__APPEND_DECL__': append_decl,
            '__SEPARATE_DECL__': separate_decl,
        },
    )

    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, timeout=30).strip()
    if not sdk:
        fail('xcrun returned an empty macosx SDK path')

    machine = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    with tempfile.TemporaryDirectory(prefix='tivano-markdown-typography-') as temp:
        temp_dir = Path(temp)
        harness_path = temp_dir / 'checks.swift'
        binary_path = temp_dir / 'markdown-typography-checks'
        module_cache = temp_dir / 'ModuleCache'
        harness_path.write_text(harness_source, encoding='utf-8')

        compile_cmd = [
            'xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '6',
            '-target', f'{machine}-apple-macosx26.0',
            '-sdk', sdk,
            '-module-cache-path', str(module_cache),
            str(RECENT_CACHE),
            str(MARKDOWN_PARSER),
            str(TYPE_SCALE),
            str(harness_path),
            '-o', str(binary_path),
        ]
        compiled = subprocess.run(compile_cmd, capture_output=True, text=True, timeout=90)
        if compiled.returncode != 0:
            fail(f'swiftc failed:\n{compiled.stdout}\n{compiled.stderr}')

        executed = subprocess.run([str(binary_path)], capture_output=True, text=True, timeout=30)
        if executed.returncode != 0:
            fail(f'check binary failed:\n{executed.stdout}\n{executed.stderr}')

    print('PASS: markdown_typography_checks (TypeScale metrics, heading scale, nested list spacing, marker gutter 11..18pt sans/serif, segment safety, TimelineMetrics.rowSpacing)')


if __name__ == '__main__':
    main()
