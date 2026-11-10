#!/usr/bin/env python3
"""Offline guard: `agy --effort` only carries an effort the model declares.

Antigravity's CLI exits before the first turn with `invalid model selection`
when `--effort` names a level the model does not take, and rejects the flag
entirely for a model the account lists without effort levels (an account that
lost access to `gemini-4-argon` got `--effort is not supported`). `normalize`
used to resolve every unknown model to `"high"`, so launching one of those failed
and looked like a crash. It now resolves the effort against the model's catalog row
and passes only what that row declares; an unknown model gets an explicitly
requested effort and nothing else. The source assertions below fail loudly if a
caller drops the catalog, and the extracted production functions are compiled so
the resolution itself is exercised, not just its shape.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SESSION = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'
RUNTIME = ROOT / 'Tivano/App/Runtime/ThreadRuntime.swift'
REGISTRY = ROOT / 'Tivano/Services/Providers/ProviderRegistry.swift'

START = '// MARK: - Model and Effort Normalization'
END = '// MARK: - Catalog'
SIGNATURE = ('static func normalize(model: String?, effort: String?, catalog: [ModelOption]) '
             '-> (model: String?, effort: String?)')
OLD_DEFAULT = 'resolvedEffort = baseSlug == "gpt-oss-120b" ? "medium" : "high"'
SEED_ROW = ('ModelOption(id: "gemini-4-argon", name: "Gemini 4 Argon", '
            'efforts: ["low", "medium", "high"], defaultEffort: "medium")')


def fail(message):
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def source(path):
    if not path.is_file():
        fail(f'{path.relative_to(ROOT)} is missing')
    return path.read_text(encoding='utf-8')


def section(text, start, end):
    for marker in (start, end):
        count = text.count(marker)
        if count != 1:
            fail(f'{SESSION.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    return text[text.index(start):text.index(end)]


def check_sources():
    session = source(SESSION)
    if SIGNATURE not in session:
        fail(f'normalize does not take the catalog: expected {SIGNATURE!r}')
    if OLD_DEFAULT in session:
        fail('normalize still resolves every unknown model to an invented default '
             f'({OLD_DEFAULT!r}); unknown models must only send what was requested')
    if 'catalog: Self.addingSeedRows(configuration.modelCatalog, seed: ProviderRegistry.antigravitySeed)' not in session:
        fail('start() does not merge antigravitySeed into the restored catalog, so a cached '
             'catalog without gemini-4-argon still sends its effort')
    calls = [match.end() for match in re.finditer(r'(?<!func )normalize\(', session)]
    if not calls:
        fail('no normalize call site found; the caller guard would pass silently')
    for start in calls:
        line = session[session.rfind('\n', 0, start):session.find('\n', start)]
        if 'catalog:' not in line:
            fail(f'normalize call site does not pass the catalog: {line.strip()!r}')

    runtime = source(RUNTIME)
    catalog = runtime.find('modelCatalog:')
    if catalog < 0:
        fail(f'{RUNTIME.relative_to(ROOT)}: SessionConfiguration no longer passes modelCatalog')
    if '.antigravity' not in runtime[catalog:catalog + 400]:
        fail('the session modelCatalog expression does not include .antigravity, '
             'so normalize runs with an empty catalog')

    registry = source(REGISTRY)
    seed = registry.find('static let antigravitySeed')
    if seed < 0:
        fail(f'{REGISTRY.relative_to(ROOT)}: antigravitySeed is gone')
    if 'gemini-4-argon' not in registry[seed:seed + 2000]:
        fail('antigravitySeed has no gemini-4-argon row, so a cached catalog '
             'without it treats Argon as unknown')
    if SEED_ROW not in registry[seed:seed + 2000]:
        fail(f'antigravitySeed gemini-4-argon row changed shape: expected {SEED_ROW!r}')


def fixture(block):
    return f'''import Foundation

struct ModelOption {{
    var id: String
    var name: String
    var efforts: [String] = []
    var defaultEffort: String?
}}

enum AntigravityNormalization {{
{block}}}

func expect(_ result: (model: String?, effort: String?), _ model: String?, _ effort: String?) {{
    precondition(result.model == model && result.effort == effort,
                 "expected (model: \(String(describing: model)), effort: \(String(describing: effort))), got \(result)")
}}

@main struct Checks {{
    static func main() {{
        let row = ModelOption(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash",
                              efforts: ["low", "medium", "high"], defaultEffort: "high")
        let argon = ModelOption(id: "gemini-4-argon", name: "Gemini 4 Argon",
                                efforts: ["low", "medium", "high"], defaultEffort: "medium")
        let fixed = ModelOption(id: "gemini-fixed", name: "Gemini Fixed", efforts: [])
        let pro = ModelOption(id: "gemini-3.1-pro", name: "Gemini 3.1 Pro",
                              efforts: ["low", "high"], defaultEffort: "high")
        let claude = ModelOption(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", efforts: [])
        let catalog = [argon, fixed, row, pro, claude]

        // A model that declares no effort gets no --effort, whatever was requested.
        expect(AntigravityNormalization.normalize(model: "gemini-4-argon", effort: "high", catalog: catalog),
               "gemini-4-argon", "high")
        expect(AntigravityNormalization.normalize(model: "gemini-4-argon", effort: "xhigh", catalog: catalog),
               "gemini-4-argon", "medium")
        expect(AntigravityNormalization.normalize(model: "gemini-fixed", effort: "high", catalog: catalog),
               "gemini-fixed", nil)
        // A declared effort is kept; a declared default replaces an undeclared request.
        expect(AntigravityNormalization.normalize(model: "gemini-3.8-flash", effort: "low", catalog: catalog),
               "gemini-3.8-flash", "low")
        expect(AntigravityNormalization.normalize(model: "gemini-3.8-flash", effort: nil, catalog: catalog),
               "gemini-3.8-flash", "high")
        expect(AntigravityNormalization.normalize(model: "gemini-3.8-flash", effort: "xhigh", catalog: catalog),
               "gemini-3.8-flash", "high")
        // Legacy effort suffixes still collapse onto the base slug.
        expect(AntigravityNormalization.normalize(model: "gemini-3.8-flash-high", effort: nil, catalog: catalog),
               "gemini-3.8-flash", "high")
        // The two known adjustments hold inside the row's efforts.
        expect(AntigravityNormalization.normalize(model: "gemini-3.1-pro", effort: "medium", catalog: catalog),
               "gemini-3.1-pro", "high")
        // Claude takes no effort.
        expect(AntigravityNormalization.normalize(model: "claude-sonnet-4-6", effort: "high", catalog: catalog),
               "claude-sonnet-4-6", nil)
        // An unknown model gets only what was requested.
        expect(AntigravityNormalization.normalize(model: "gemini-9-unknown", effort: nil, catalog: catalog),
               "gemini-9-unknown", nil)
        expect(AntigravityNormalization.normalize(model: "gemini-9-unknown", effort: "low", catalog: catalog),
               "gemini-9-unknown", "low")
        // Without a catalog the two known slugs keep their historical default.
        expect(AntigravityNormalization.normalize(model: "gemini-3.1-pro", effort: nil, catalog: []),
               "gemini-3.1-pro", "high")
        expect(AntigravityNormalization.normalize(model: "gpt-oss-120b", effort: "high", catalog: []),
               "gpt-oss-120b", "medium")
        expect(AntigravityNormalization.normalize(model: nil, effort: "high", catalog: catalog), nil, nil)
        let cached = AntigravityNormalization.addingSeedRows([row, pro], seed: [argon, row])
        precondition(cached.map(\.id) == ["gemini-3.8-flash", "gemini-3.1-pro", "gemini-4-argon"],
                     "seed rows must fill a cached catalog without duplicating it, got \(cached.map(\.id))")
        expect(AntigravityNormalization.normalize(model: "gemini-4-argon", effort: "low", catalog: cached),
               "gemini-4-argon", "low")
        print("PASS: --effort follows the model's declared efforts; effort-free and unknown models send none unasked.")
    }}
}}
'''


def check_behaviour():
    block = section(source(SESSION), START, END)
    with tempfile.TemporaryDirectory(prefix='tivano-antigravity-effort-') as temp:
        directory = Path(temp)
        swift, binary = directory / 'Checks.swift', directory / 'checks'
        swift.write_text(fixture(block))
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                                str(swift), '-o', str(binary)], capture_output=True, text=True)
        if build.returncode != 0:
            fail(f'extracted normalize does not compile:\n{build.stderr.strip()}')
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        if run.returncode != 0:
            fail(f'effort resolution is wrong:\n{(run.stderr or run.stdout).strip()}')
        print(run.stdout.strip())


def main():
    check_sources()
    check_behaviour()


if __name__ == '__main__':
    main()
