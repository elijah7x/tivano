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

private struct LinkCase: Decodable {
    let url: String
    let base: String?
}

private func makeURL(_ raw: String) -> URL {
    if let url = URL(string: raw) { return url }
    if !raw.contains("/"), let url = URL(string: "./" + raw) { return url }
    fputs("FAIL: cannot construct URL from \(raw)\n", stderr)
    exit(1)
}

private func requireEquatable<T: Equatable>(_ value: T) -> T { value }

@main
struct Checks {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("FAIL: expected cases JSON path argument\n", stderr)
            exit(1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cases = try JSONDecoder().decode([LinkCase].self, from: data)
        for item in cases {
            let url = makeURL(item.url)
            let resolved = requireEquatable(MarkdownLinkTarget.resolve(url, base: item.base))
            precondition(resolved == MarkdownLinkTarget.resolve(url, base: item.base))
            let row: [String: String]
            switch resolved {
            case .web(let webURL):
                row = ["kind": "web", "value": webURL.absoluteString]
            case .file(let fileURL):
                if !fileURL.isFileURL {
                    fputs("FAIL: expected file URL for \(item.url), got \(fileURL)\n", stderr)
                    exit(1)
                }
                row = ["kind": "file", "value": fileURL.path]
            case .missing(let path):
                row = ["kind": "missing", "value": path]
            }
            let encoded = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print(String(decoding: encoded, as: UTF8.self))
        }
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

        report.parent.mkdir(parents=True)
        report.write_bytes(b'%PDF-1.4\n')
        notes_dir.mkdir(parents=True)
        swift_file.parent.mkdir(parents=True)
        swift_file.write_text('let a = 1\n', encoding='utf-8')
        root_swift = base / 'Foo.swift'
        root_swift.write_text('let b = 2\n', encoding='utf-8')
        space_file.write_text('# My File\n', encoding='utf-8')

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

        checks_swift = directory / 'Checks.swift'
        cases_json = directory / 'cases.json'
        binary = directory / 'checks'
        checks_swift.write_text(SWIFT_MAIN, encoding='utf-8')
        cases_json.write_text(
            json.dumps([{'url': c['url'], 'base': c['base']} for c in cases]),
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

        lines = run.stdout.splitlines()
        if len(lines) != len(cases):
            fail(f'expected {len(cases)} output lines, got {len(lines)}')

        for index, (case, line) in enumerate(zip(cases, lines)):
            try:
                actual = json.loads(line)
            except json.JSONDecodeError as error:
                fail(f"case {index} ({case['label']}): invalid JSON line {line!r}: {error}")
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

    print(f'PASS: MarkdownLinkTarget resolved all {len(cases)} local, missing and web link cases.')


if __name__ == '__main__':
    main()
