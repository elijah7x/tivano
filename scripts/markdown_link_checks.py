#!/usr/bin/env python3
"""Offline check for MarkdownLinkTarget local and web link resolution."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import quote

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'Tivano/UI/Markdown/MarkdownLinkTarget.swift'

SWIFT_MAIN = r'''import Foundation

private struct CheckInput: Decodable {
    let resolveCases: [LinkCase]
    let autolinkCases: [AutolinkCase]
}

private struct LinkCase: Decodable {
    let url: String
    let base: String?
}

private struct AutolinkCase: Decodable {
    let source: String
    let parseMarkdown: Bool
    let base: String?
}

private struct ResolvedRow: Encodable {
    let kind: String
    let value: String
}

private struct AutolinkRunRow: Encodable {
    let text: String
    let isCode: Bool
    let kind: String
    let value: String
}

private struct CheckOutput: Encodable {
    let resolve: [ResolvedRow]
    let autolink: [[AutolinkRunRow]]
}

private func makeURL(_ raw: String) -> URL {
    if let url = URL(string: raw) { return url }
    if !raw.contains("/"), let url = URL(string: "./" + raw) { return url }
    fputs("FAIL: cannot construct URL from \(raw)\n", stderr)
    exit(1)
}

private func requireEquatable<T: Equatable>(_ value: T) -> T { value }

private func resolveRow(_ resolved: MarkdownLinkTarget, label: String) -> ResolvedRow {
    switch resolved {
    case .web(let webURL):
        return ResolvedRow(kind: "web", value: webURL.absoluteString)
    case .file(let fileURL):
        if !fileURL.isFileURL {
            fputs("FAIL: expected file URL for \(label), got \(fileURL)\n", stderr)
            exit(1)
        }
        return ResolvedRow(kind: "file", value: fileURL.path)
    case .missing(let path):
        return ResolvedRow(kind: "missing", value: path)
    }
}

@main
struct Checks {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("FAIL: expected cases JSON path argument\n", stderr)
            exit(1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let input = try JSONDecoder().decode(CheckInput.self, from: data)

        var resolveRows: [ResolvedRow] = []
        for item in input.resolveCases {
            let url = makeURL(item.url)
            let resolved = requireEquatable(MarkdownLinkTarget.resolve(url, base: item.base))
            precondition(resolved == MarkdownLinkTarget.resolve(url, base: item.base))
            resolveRows.append(resolveRow(resolved, label: item.url))
        }

        let markdownOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var autolinkRows: [[AutolinkRunRow]] = []
        for item in input.autolinkCases {
            let parsed: AttributedString
            if item.parseMarkdown {
                parsed = (try? AttributedString(markdown: item.source, options: markdownOptions))
                    ?? AttributedString(item.source)
            } else {
                parsed = AttributedString(item.source)
            }
            let linked = MarkdownLinkTarget.autolinkedLocalPaths(parsed)
            if String(linked.characters) != String(parsed.characters) {
                fputs("FAIL: autolinkedLocalPaths mutated text for \(item.source)\n", stderr)
                exit(1)
            }
            var runs: [AutolinkRunRow] = []
            for run in linked.runs {
                guard let url = run.link else { continue }
                let text = String(linked[run.range].characters)
                let isCode = (run.inlinePresentationIntent ?? []).contains(.code)
                let resolved = MarkdownLinkTarget.resolve(url, base: item.base)
                let row = resolveRow(resolved, label: "\(item.source) -> \(text)")
                runs.append(AutolinkRunRow(text: text, isCode: isCode, kind: row.kind, value: row.value))
            }
            autolinkRows.append(runs)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(CheckOutput(resolve: resolveRows, autolink: autolinkRows))
        print(String(decoding: encoded, as: UTF8.self))
    }
}
'''


def fail(message: str) -> None:
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def canonical_path(path: str) -> str:
    return os.path.realpath(path) if os.path.isabs(path) else path


def has_dot_segments(path: str) -> bool:
    parts = path.split('/')
    return '.' in parts or '..' in parts


def main() -> None:
    if not TARGET.is_file():
        fail(f'missing source file: {TARGET.relative_to(ROOT)}')

    with tempfile.TemporaryDirectory(prefix='tivano-markdown-links-') as temp:
        directory = Path(temp)
        base = directory / 'base'
        report = base / 'out' / 'report.pdf'
        notes_dir = base / 'notes dir'
        swift_file = base / 'src' / 'a.swift'
        space_file = base / 'My File.md'
        nope = base / 'out' / 'nope.pdf'
        shot = base / 'shot.png'
        space_video = base / 'My Video.mov'
        promo_video = base / 'promo' / 'renders' / 'cut.mp4'
        preview_html = base / 'docs' / 'preview' / 'index.html'
        cjk_doc = base / 'Docs' / '产品' / '欢迎.md'

        report.parent.mkdir(parents=True)
        report.write_bytes(b'%PDF-1.4\n')
        notes_dir.mkdir(parents=True)
        swift_file.parent.mkdir(parents=True)
        swift_file.write_text('let a = 1\n', encoding='utf-8')
        root_swift = base / 'Foo.swift'
        root_swift.write_text('let b = 2\n', encoding='utf-8')
        space_file.write_text('# My File\n', encoding='utf-8')
        shot.write_bytes(b'\x89PNG\r\n\x1a\n')
        space_video.write_bytes(b'ftypqt  ')
        promo_video.parent.mkdir(parents=True)
        promo_video.write_bytes(b'ftypisom')
        preview_html.parent.mkdir(parents=True)
        preview_html.write_text('<!doctype html>\n', encoding='utf-8')
        cjk_doc.parent.mkdir(parents=True)
        cjk_doc.write_text('# 欢迎\n', encoding='utf-8')

        base_str = str(base)
        cases = [
            {
                'label': 'out/report.pdf with base',
                'url': 'out/report.pdf',
                'base': base_str,
                'expected': ('file', str(report)),
            },
            {
                'label': './out/../out/report.pdf with base',
                'url': './out/../out/report.pdf',
                'base': base_str,
                'expected': ('file', str(report)),
            },
            {
                'label': 'My%20File.md with base',
                'url': 'My%20File.md',
                'base': base_str,
                'expected': ('file', str(space_file)),
            },
            {
                'label': 'src/a.swift:12 with base',
                'url': 'src/a.swift:12',
                'base': base_str,
                'expected': ('file', str(swift_file)),
            },
            {
                'label': 'src/a.swift:12:3 with base',
                'url': 'src/a.swift:12:3',
                'base': base_str,
                'expected': ('file', str(swift_file)),
            },
            {
                'label': 'Foo.swift:12 with base (parsed as scheme Foo.swift)',
                'url': 'Foo.swift:12',
                'base': base_str,
                'expected': ('file', str(root_swift)),
            },
            {
                'label': 'Foo.swift:12:3 with base (parsed as scheme Foo.swift)',
                'url': 'Foo.swift:12:3',
                'base': base_str,
                'expected': ('file', str(root_swift)),
            },
            {
                'label': 'notes%20dir:3 with base (directory not stripped)',
                'url': 'notes%20dir:3',
                'base': base_str,
                'expected': ('missing', str(base / 'notes dir:3')),
            },
            {
                'label': 'notes%20dir with base (directory opens)',
                'url': 'notes%20dir',
                'base': base_str,
                'expected': ('file', str(notes_dir)),
            },
            {
                'label': 'out/report.pdf#page=2 with base',
                'url': 'out/report.pdf#page=2',
                'base': base_str,
                'expected': ('file', str(report)),
            },
            {
                'label': 'out/report.pdf?download=1#page=2 with base',
                'url': 'out/report.pdf?download=1#page=2',
                'base': base_str,
                'expected': ('file', str(report)),
            },
            {
                'label': 'absolute path of report.pdf',
                'url': quote(str(report), safe='/'),
                'base': base_str,
                'expected': ('file', str(report)),
            },
            {
                'label': 'file:// URL of report.pdf',
                'url': report.as_uri(),
                'base': base_str,
                'expected': ('file', str(report)),
            },
            {
                'label': 'out/report.pdf with base nil',
                'url': 'out/report.pdf',
                'base': None,
                'expected': ('missing', 'out/report.pdf'),
            },
            {
                'label': 'out/report.pdf with empty base',
                'url': 'out/report.pdf',
                'base': '',
                'expected': ('missing', 'out/report.pdf'),
            },
            {
                'label': 'out/nope.pdf with base',
                'url': 'out/nope.pdf',
                'base': base_str,
                'expected': ('missing', str(nope)),
            },
            {
                'label': 'out/nope.pdf:7 with base',
                'url': 'out/nope.pdf:7',
                'base': base_str,
                'expected': ('missing', str(base / 'out' / 'nope.pdf:7')),
            },
            {
                'label': 'https://example.com/a unchanged',
                'url': 'https://example.com/a',
                'base': base_str,
                'expected': ('web', 'https://example.com/a'),
            },
            {
                'label': 'mailto:a@b.c unchanged',
                'url': 'mailto:a@b.c',
                'base': base_str,
                'expected': ('web', 'mailto:a@b.c'),
            },
            {
                'label': '//example.com/a with host unchanged',
                'url': '//example.com/a',
                'base': base_str,
                'expected': ('web', '//example.com/a'),
            },
        ]

        synthetic_shot = '/Users/tivano-check-nonexistent/shot.png'
        synthetic_video = '/Users/tivano-check-nonexistent/My Video.mov'
        tilde_shot = '~/tivano-check-nonexistent/shot.png'
        autolink_cases = [
            {
                'label': 'prose /Users/.../shot.png after CJK text with trailing Chinese punctuation',
                'source': f'保存在{synthetic_shot}，请查看',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': synthetic_shot, 'isCode': False, 'kind': 'missing', 'value': synthetic_shot},
                ],
            },
            {
                'label': 'prose existing rooted shot.png after CJK text with trailing Chinese punctuation',
                'source': f'保存在{shot}，请查看',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': str(shot), 'isCode': False, 'kind': 'file', 'value': str(shot)},
                ],
            },
            {
                'label': 'inline code promo/renders/cut.mp4',
                'source': '成片在 `promo/renders/cut.mp4` 中',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': 'promo/renders/cut.mp4', 'isCode': True, 'kind': 'file', 'value': str(promo_video)},
                ],
            },
            {
                'label': 'inline code /Users/.../My Video.mov with spaces',
                'source': f'导出到 `{synthetic_video}` 完成',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': synthetic_video, 'isCode': True, 'kind': 'missing', 'value': synthetic_video},
                ],
            },
            {
                'label': 'inline code existing rooted My Video.mov with spaces',
                'source': f'导出到 `{space_video}` 完成',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': str(space_video), 'isCode': True, 'kind': 'file', 'value': str(space_video)},
                ],
            },
            {
                'label': 'prose relative docs/preview/index.html',
                'source': '打开 docs/preview/index.html，检查预览。',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': 'docs/preview/index.html', 'isCode': False, 'kind': 'file', 'value': str(preview_html)},
                ],
            },
            {
                'label': 'prose CJK relative path Docs/产品/欢迎.md',
                'source': '详见 Docs/产品/欢迎.md。',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': 'Docs/产品/欢迎.md', 'isCode': False, 'kind': 'file', 'value': str(cjk_doc)},
                ],
            },
            {
                'label': 'inline code CJK relative path Docs/产品/欢迎.md',
                'source': '查看 `Docs/产品/欢迎.md` 文档',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': 'Docs/产品/欢迎.md', 'isCode': True, 'kind': 'file', 'value': str(cjk_doc)},
                ],
            },
            {
                'label': 'inline code Foo.swift:12',
                'source': '错误在 `Foo.swift:12` 这一行',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': 'Foo.swift:12', 'isCode': True, 'kind': 'file', 'value': str(root_swift)},
                ],
            },
            {
                'label': 'prose tilde path expands through resolve',
                'source': f'保存在 {tilde_shot}，请查看',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [
                    {'text': tilde_shot, 'isCode': False, 'kind': 'missing', 'value': os.path.expanduser(tilde_shot)},
                ],
            },
            {
                'label': 'prose bare localhost and 127.0.0.1 URLs',
                'source': '访问 http://localhost:3000/preview，或者 http://127.0.0.1:8080/app。',
                'parseMarkdown': False,
                'base': base_str,
                'expected': [
                    {'text': 'http://localhost:3000/preview', 'isCode': False, 'kind': 'web', 'value': 'http://localhost:3000/preview'},
                    {'text': 'http://127.0.0.1:8080/app', 'isCode': False, 'kind': 'web', 'value': 'http://127.0.0.1:8080/app'},
                ],
            },
            {
                'label': 'no false positive on unlinked https://example.com/a/b.png in prose',
                'source': 'https://example.com/a/b.png',
                'parseMarkdown': False,
                'base': base_str,
                'expected': [],
            },
            {
                'label': 'no false positive on https://example.com/a/b.png in inline code',
                'source': '`https://example.com/a/b.png`',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [],
            },
            {
                'label': 'no false positive on and/or and CI/CD in prose',
                'source': 'Use and/or for CI/CD pipelines.',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [],
            },
            {
                'label': 'no false positive on and/or and CI/CD in inline code',
                'source': '`and/or` and `CI/CD`',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [],
            },
            {
                'label': 'no false positive on shell snippet ls -la out.png | head in prose',
                'source': 'Run ls -la out.png | head to inspect.',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [],
            },
            {
                'label': 'no false positive on shell snippet ls -la out.png | head in inline code',
                'source': 'Run `ls -la out.png | head` to inspect.',
                'parseMarkdown': True,
                'base': base_str,
                'expected': [],
            },
        ]

        checks_swift = directory / 'Checks.swift'
        cases_json = directory / 'cases.json'
        binary = directory / 'checks'
        checks_swift.write_text(SWIFT_MAIN, encoding='utf-8')
        cases_json.write_text(
            json.dumps({
                'resolveCases': [{'url': c['url'], 'base': c['base']} for c in cases],
                'autolinkCases': [
                    {'source': c['source'], 'parseMarkdown': c['parseMarkdown'], 'base': c['base']}
                    for c in autolink_cases
                ],
            }),
            encoding='utf-8',
        )

        try:
            build = subprocess.run(
                [
                    'xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(TARGET), str(checks_swift), '-o', str(binary),
                ],
                capture_output=True,
                text=True,
                timeout=120,
            )
        except (OSError, subprocess.SubprocessError) as error:
            fail(f'failed to invoke swiftc: {error}')
        if build.returncode != 0:
            detail = (build.stderr or build.stdout).strip()
            fail(f'failed to compile {TARGET.relative_to(ROOT)} (exit {build.returncode}):\n{detail}')

        try:
            run = subprocess.run(
                [str(binary), str(cases_json)],
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError) as error:
            fail(f'failed to execute compiled check binary: {error}')
        if run.returncode != 0:
            detail = (run.stderr or run.stdout).strip()
            fail(f'check binary failed (exit {run.returncode}):\n{detail}')

        try:
            payload = json.loads(run.stdout)
        except json.JSONDecodeError as error:
            fail(f'invalid JSON output {run.stdout!r}: {error}')

        resolve_rows = payload.get('resolve')
        autolink_rows = payload.get('autolink')
        if not isinstance(resolve_rows, list) or len(resolve_rows) != len(cases):
            fail(f'expected {len(cases)} resolve results, got {resolve_rows!r}')
        if not isinstance(autolink_rows, list) or len(autolink_rows) != len(autolink_cases):
            fail(f'expected {len(autolink_cases)} autolink results, got {autolink_rows!r}')

        for index, (case, actual) in enumerate(zip(cases, resolve_rows)):
            actual_kind = actual.get('kind')
            actual_value = actual.get('value')
            if not isinstance(actual_kind, str) or not isinstance(actual_value, str):
                fail(f"case {index} ({case['label']}): malformed output {actual!r}")

            expected_kind, expected_value = case['expected']
            if actual_kind != expected_kind:
                fail(
                    f"case {index} ({case['label']}): expected {expected_kind}({expected_value!r}), "
                    f"got {actual_kind}({actual_value!r})"
                )
            if expected_kind in ('file', 'missing'):
                if not has_dot_segments(expected_value) and has_dot_segments(actual_value):
                    fail(
                        f"case {index} ({case['label']}): unstandardized dot segments in "
                        f"{actual_kind}({actual_value!r})"
                    )
                if canonical_path(actual_value) != canonical_path(expected_value):
                    fail(
                        f"case {index} ({case['label']}): expected {expected_kind}({canonical_path(expected_value)!r}), "
                        f"got {actual_kind}({canonical_path(actual_value)!r}) (raw: {actual_value!r})"
                    )
            elif actual_value != expected_value:
                fail(
                    f"case {index} ({case['label']}): expected web({expected_value!r}), "
                    f"got web({actual_value!r})"
                )

        for index, (case, actual_runs) in enumerate(zip(autolink_cases, autolink_rows)):
            expected_runs = case['expected']
            if not isinstance(actual_runs, list) or len(actual_runs) != len(expected_runs):
                fail(
                    f"autolink case {index} ({case['label']}): expected {len(expected_runs)} links "
                    f"{expected_runs!r}, got {actual_runs!r}"
                )
            for run_index, (expected_run, actual_run) in enumerate(zip(expected_runs, actual_runs)):
                if actual_run.get('text') != expected_run['text'] or actual_run.get('isCode') != expected_run['isCode']:
                    fail(
                        f"autolink case {index} ({case['label']}) run {run_index}: "
                        f"expected {expected_run!r}, got {actual_run!r}"
                    )
                expected_kind = expected_run['kind']
                expected_value = expected_run['value']
                actual_kind = actual_run.get('kind')
                actual_value = actual_run.get('value')
                if actual_kind != expected_kind:
                    fail(
                        f"autolink case {index} ({case['label']}) run {run_index}: "
                        f"expected {expected_kind}({expected_value!r}), got {actual_kind}({actual_value!r})"
                    )
                if expected_kind in ('file', 'missing'):
                    if canonical_path(actual_value) != canonical_path(expected_value):
                        fail(
                            f"autolink case {index} ({case['label']}) run {run_index}: "
                            f"expected {expected_kind}({canonical_path(expected_value)!r}), "
                            f"got {actual_kind}({canonical_path(actual_value)!r}) (raw: {actual_value!r})"
                        )
                elif actual_value != expected_value:
                    fail(
                        f"autolink case {index} ({case['label']}) run {run_index}: "
                        f"expected web({expected_value!r}), got web({actual_value!r})"
                    )

    print(
        f'PASS: MarkdownLinkTarget resolved {len(cases)} link cases and '
        f'autolinked {len(autolink_cases)} prose/code cases.'
    )


if __name__ == '__main__':
    main()
