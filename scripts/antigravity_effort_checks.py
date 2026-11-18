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
    efforts_match = re.search(r'static\s+let\s+efforts\s*=\s*\[([^\]]+)\]', session)
    if not efforts_match:
        fail(f'{SESSION.relative_to(ROOT)}: static let efforts is missing')
    efforts = re.findall(r'"([^"]+)"', efforts_match.group(1))
    for level in ('xhigh', 'max'):
        if level not in efforts:
            fail(f'static let efforts must include {level!r}, got {efforts!r}')

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
    seed_end = registry.find('\n    ]', seed)
    if seed_end < 0:
        fail(f'{REGISTRY.relative_to(ROOT)}: antigravitySeed closing bracket not found')
    seed_block = registry[seed:seed_end]
    for required_id in ('gemini-4-carbon', 'gemini-4-hydrogen', 'gemini-4-argon'):
        if f'id: "{required_id}"' not in seed_block:
            fail(f'antigravitySeed is missing {required_id!r}')
    for removed_id in ('gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-3.1-pro'):
        if removed_id in seed_block:
            fail(f'antigravitySeed still contains removed model {removed_id!r}')


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
                 "expected (model: \\(String(describing: model)), effort: \\(String(describing: effort))), got \\(result)")
}}

@main struct Checks {{
    static func main() {{
        let carbon = ModelOption(id: "gemini-4-carbon", name: "Gemini 4 Carbon",
                                 efforts: ["low", "medium", "high"], defaultEffort: "high")
        let row = ModelOption(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash",
                              efforts: ["low", "medium", "high"], defaultEffort: "high")
        let argon = ModelOption(id: "gemini-4-argon", name: "Gemini 4 Argon",
                                efforts: ["low", "medium", "high"], defaultEffort: "medium")
        let orchestrator = ModelOption(id: "gemini-pro-orchestrator", name: "Orchestrator (Carbon)", efforts: [])
        let orchestratorArgon = ModelOption(id: "gemini-pro-orchestrator-argon", name: "Orchestrator (Argon)", efforts: [])
        let fixed = ModelOption(id: "gemini-fixed", name: "Gemini Fixed", efforts: [])
        let pro = ModelOption(id: "gemini-3.1-pro", name: "Gemini 3.1 Pro",
                              efforts: ["low", "high"], defaultEffort: "high")
        let claude = ModelOption(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", efforts: [])
        let hydrogen = ModelOption(id: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen",
                                   efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "high")
        let catalog = [carbon, argon, row, orchestrator, orchestratorArgon, fixed, pro, claude]

        // Effort-suffixed models resolve to `--model <base>-<effort>` with no `--effort`,
        // while non-suffixed models keep `--effort` (or none when they declare no efforts).
        let table: [(String?, String?, [ModelOption], String?, String?)] = [
            // Carbon: exact effort-suffixed ids collapse into `--model`, no `--effort`.
            ("gemini-4-carbon", "high", catalog, "gemini-4-carbon-high", nil),
            ("gemini-4-carbon", "medium", catalog, "gemini-4-carbon-medium", nil),
            ("gemini-4-carbon", "low", catalog, "gemini-4-carbon-low", nil),
            ("gemini-4-carbon", nil, catalog, "gemini-4-carbon-high", nil),
            ("gemini-4-carbon-high", nil, catalog, "gemini-4-carbon-high", nil),
            // Argon: exact effort-suffixed ids; undeclared effort falls back to defaultEffort.
            ("gemini-4-argon", "high", catalog, "gemini-4-argon-high", nil),
            ("gemini-4-argon", "xhigh", catalog, "gemini-4-argon-medium", nil),
            // Hydrogen: low/medium/high/xhigh collapse; undeclared `max` keeps `--effort`.
            ("gemini-4-hydrogen", "low", [hydrogen], "gemini-4-hydrogen-low", nil),
            ("gemini-4-hydrogen", "medium", [hydrogen], "gemini-4-hydrogen-medium", nil),
            ("gemini-4-hydrogen", "high", [hydrogen], "gemini-4-hydrogen-high", nil),
            ("gemini-4-hydrogen-xhigh", nil, [hydrogen], "gemini-4-hydrogen-xhigh", nil),
            ("gemini-4-hydrogen-max", nil, [hydrogen], "gemini-4-hydrogen", "max"),
            // Flash & GPT-OSS: exact suffixed ids in `agy models`.
            ("gemini-3.8-flash", "low", catalog, "gemini-3.8-flash-low", nil),
            ("gemini-3.8-flash", nil, catalog, "gemini-3.8-flash-high", nil),
            ("gemini-3.8-flash", "xhigh", catalog, "gemini-3.8-flash-high", nil),
            ("gemini-3.8-flash-high", nil, catalog, "gemini-3.8-flash-high", nil),
            ("gpt-oss-120b", "high", [], "gpt-oss-120b-medium", nil),
            // Non-suffixed models keep today's behaviour.
            ("gemini-pro-orchestrator", "high", catalog, "gemini-pro-orchestrator", nil),
            ("gemini-pro-orchestrator-argon", "high", catalog, "gemini-pro-orchestrator-argon", nil),
            ("gemini-fixed", "high", catalog, "gemini-fixed", nil),
            ("gemini-3.1-pro", "medium", catalog, "gemini-3.1-pro", "high"),
            ("gemini-3.1-pro", "low", catalog, "gemini-3.1-pro", "low"),
            ("gemini-3.1-pro", nil, [], "gemini-3.1-pro", "high"),
            ("claude-sonnet-4-6", "high", catalog, "claude-sonnet-4-6", nil),
            ("gemini-9-unknown", nil, catalog, "gemini-9-unknown", nil),
            ("gemini-9-unknown", "low", catalog, "gemini-9-unknown", "low"),
            (nil, "high", catalog, nil, nil),
        ]
        for (model, effort, cat, expectedModel, expectedEffort) in table {{
            expect(AntigravityNormalization.normalize(model: model, effort: effort, catalog: cat),
                   expectedModel, expectedEffort)
        }}

        let parsedXHigh = AntigravityNormalization.parseModelRow(slug: "gemini-4-hydrogen-xhigh", name: "Gemini 4 Hydrogen (XHigh)")
        precondition(parsedXHigh.baseSlug == "gemini-4-hydrogen" && parsedXHigh.baseName == "Gemini 4 Hydrogen" && parsedXHigh.effort == "xhigh",
                     "xhigh suffix must collapse before high, got \\(parsedXHigh)")
        let parsedMax = AntigravityNormalization.parseModelRow(slug: "gemini-4-hydrogen-max", name: "Gemini 4 Hydrogen (Max)")
        precondition(parsedMax.baseSlug == "gemini-4-hydrogen" && parsedMax.baseName == "Gemini 4 Hydrogen" && parsedMax.effort == "max",
                     "max suffix must collapse, got \\(parsedMax)")

        let cached = AntigravityNormalization.addingSeedRows([row, pro], seed: [argon, row])
        precondition(cached.map(\\.id) == ["gemini-3.8-flash", "gemini-3.1-pro", "gemini-4-argon"],
                     "seed rows must fill a cached catalog without duplicating it, got \\(cached.map(\\.id))")
        expect(AntigravityNormalization.normalize(model: "gemini-4-argon", effort: "low", catalog: cached),
               "gemini-4-argon-low", nil)
        print("PASS: effort-suffixed models resolve to --model <base>-<effort>; non-suffixed models keep --effort.")
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
