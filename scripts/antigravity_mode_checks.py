#!/usr/bin/env python3
"""Offline guard: `agy` supervised mode pins Default via `--settings` when supported.

Starting in `agy` 1.5.7, unsaved headless sessions default to Auto mode and
auto-approve workspace edits. Passing no mode flag made Tivano's `.supervised`
mode silently run as Auto. When the CLI advertises `--settings` in `--help`,
`AntigravitySession` now passes `--settings '{"agentMode":""}'` (session-only,
never saved) so supervised runs stay in Default mode; older `agy` binaries exit
2 on unknown flags, so the capability probe caches `--help` per executable path
and treats failures or timeouts as unsupported. Plan, accept-edits, and full
access mappings remain unchanged. The source assertions fail loudly if markers
drift or `start()` drops the probe, and the extracted `modeArguments` function
is compiled and executed directly against every mode combination.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SESSION = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'

START_MARKER = 'func start() async throws -> String'
MODE_MARKER = 'private func modeArguments('
PROBE_MARKER = 'private static func supportsSettingsFlag('
CACHE_MARKER = 'private actor AntigravitySettingsFlagCache'

SWIFT_TEMPLATE = r'''import Foundation

enum RuntimeMode {
    case supervised
    case autoAcceptEdits
    case auto
    case fullAccess
}

enum InteractionMode {
    case build
    case plan
}

struct ModeHarness {
    __MODE_ARGUMENTS__

    func arguments(runtimeMode: RuntimeMode, interaction: InteractionMode, supportsSettingsFlag: Bool) -> [String] {
        modeArguments(runtimeMode: runtimeMode, interaction: interaction, supportsSettingsFlag: supportsSettingsFlag)
    }
}

func expect(_ actual: [String], _ expected: [String], _ label: String) {
    precondition(actual == expected, "\(label): expected \(expected), got \(actual)")
}

@main struct Checks {
    static func main() {
        let harness = ModeHarness()

        let supervisedSupported = harness.arguments(runtimeMode: .supervised, interaction: .build, supportsSettingsFlag: true)
        expect(supervisedSupported, ["--settings", "{\"agentMode\":\"\"}"], "supervised + build + supported")
        let payload = supervisedSupported[1]
        precondition(payload == "{\"agentMode\":\"\"}", "supervised settings JSON must be exact, got \(payload)")
        let parsed = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: String]
        precondition(parsed == ["agentMode": ""], "supervised settings JSON must decode to [agentMode: \"\"], got \(String(describing: parsed))")

        expect(harness.arguments(runtimeMode: .supervised, interaction: .build, supportsSettingsFlag: false),
               [], "supervised + build + unsupported")

        expect(harness.arguments(runtimeMode: .supervised, interaction: .plan, supportsSettingsFlag: true),
               ["--mode", "plan"], "supervised + plan + supported")
        expect(harness.arguments(runtimeMode: .supervised, interaction: .plan, supportsSettingsFlag: false),
               ["--mode", "plan"], "supervised + plan + unsupported")

        expect(harness.arguments(runtimeMode: .autoAcceptEdits, interaction: .build, supportsSettingsFlag: true),
               ["--mode", "accept-edits"], "autoAcceptEdits + build + supported")
        expect(harness.arguments(runtimeMode: .autoAcceptEdits, interaction: .build, supportsSettingsFlag: false),
               ["--mode", "accept-edits"], "autoAcceptEdits + build + unsupported")
        expect(harness.arguments(runtimeMode: .autoAcceptEdits, interaction: .plan, supportsSettingsFlag: true),
               ["--mode", "plan"], "autoAcceptEdits + plan + supported")
        expect(harness.arguments(runtimeMode: .autoAcceptEdits, interaction: .plan, supportsSettingsFlag: false),
               ["--mode", "plan"], "autoAcceptEdits + plan + unsupported")

        expect(harness.arguments(runtimeMode: .auto, interaction: .build, supportsSettingsFlag: true),
               ["--mode", "accept-edits"], "auto + build + supported")
        expect(harness.arguments(runtimeMode: .auto, interaction: .build, supportsSettingsFlag: false),
               ["--mode", "accept-edits"], "auto + build + unsupported")
        expect(harness.arguments(runtimeMode: .auto, interaction: .plan, supportsSettingsFlag: true),
               ["--mode", "plan"], "auto + plan + supported")
        expect(harness.arguments(runtimeMode: .auto, interaction: .plan, supportsSettingsFlag: false),
               ["--mode", "plan"], "auto + plan + unsupported")

        expect(harness.arguments(runtimeMode: .fullAccess, interaction: .build, supportsSettingsFlag: true),
               ["--mode", "accept-edits", "--dangerously-skip-permissions"], "fullAccess + build + supported")
        expect(harness.arguments(runtimeMode: .fullAccess, interaction: .build, supportsSettingsFlag: false),
               ["--mode", "accept-edits", "--dangerously-skip-permissions"], "fullAccess + build + unsupported")
        expect(harness.arguments(runtimeMode: .fullAccess, interaction: .plan, supportsSettingsFlag: true),
               ["--mode", "plan", "--dangerously-skip-permissions"], "fullAccess + plan + supported")
        expect(harness.arguments(runtimeMode: .fullAccess, interaction: .plan, supportsSettingsFlag: false),
               ["--mode", "plan", "--dangerously-skip-permissions"], "fullAccess + plan + unsupported")

        print("PASS: agy supervised pins Default via --settings when supported and preserves plan/accept-edits/fullAccess.")
    }
}
'''


def fail(message):
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def source(path):
    if not path.is_file():
        fail(f'{path.relative_to(ROOT)} is missing')
    return path.read_text(encoding='utf-8')


def between(text, start, end):
    for marker in (start, end):
        count = text.count(marker)
        if count != 1:
            fail(f'{SESSION.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    start_index = text.index(start)
    end_index = text.index(end)
    if end_index <= start_index:
        fail(f'{SESSION.relative_to(ROOT)}: marker {end!r} appears before {start!r}')
    return text[start_index:end_index]


def extract_block(text, marker):
    count = text.count(marker)
    if count != 1:
        fail(f'{SESSION.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    start = text.index(marker)
    opening = text.find('{', start + len(marker))
    if opening < 0:
        fail(f'{SESSION.relative_to(ROOT)}: no opening brace for {marker!r}')
    depth = 0
    in_string = False
    in_line_comment = False
    block_comment_depth = 0
    index = opening
    length = len(text)
    while index < length:
        ch = text[index]
        nxt = text[index + 1] if index + 1 < length else ''
        if in_line_comment:
            if ch == '\n':
                in_line_comment = False
            index += 1
            continue
        if block_comment_depth > 0:
            if ch == '/' and nxt == '*':
                block_comment_depth += 1
                index += 2
                continue
            if ch == '*' and nxt == '/':
                block_comment_depth -= 1
                index += 2
                continue
            index += 1
            continue
        if in_string:
            if ch == '\\':
                index += 2
                continue
            if ch == '"':
                in_string = False
            index += 1
            continue
        if ch == '/' and nxt == '/':
            in_line_comment = True
            index += 2
            continue
        if ch == '/' and nxt == '*':
            block_comment_depth = 1
            index += 2
            continue
        if ch == '"':
            in_string = True
            index += 1
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
        index += 1
    fail(f'{SESSION.relative_to(ROOT)}: no closing brace for {marker!r}')


def require(snippet, tokens, label):
    for token in tokens:
        if token not in snippet:
            fail(f'{SESSION.relative_to(ROOT)}: {label} is missing {token!r}')


def check_sources():
    session = source(SESSION)

    start_fn = between(session, START_MARKER, MODE_MARKER)
    require(
        start_fn,
        [
            'await Self.supportsSettingsFlag(',
            'modeArguments(',
            'supportsSettingsFlag:',
            # A stop() during the --help probe must not be followed by a launch.
            'try Task.checkCancellation()',
            'if isStopping { throw ProviderError.notRunning }',
        ],
        'start()',
    )

    mode_fn = extract_block(session, MODE_MARKER)
    require(
        mode_fn,
        [
            'case .supervised:',
            'if supportsSettingsFlag',
            '"--settings"',
            r'"{\"agentMode\":\"\"}"',
            '"--mode", "plan"',
            '"--mode", "accept-edits"',
            '"--dangerously-skip-permissions"',
        ],
        'modeArguments()',
    )

    probe_fn = extract_block(session, PROBE_MARKER)
    require(
        probe_fn,
        [
            'settingsFlagCache',
            'Shell.run(',
            '["--help"]',
            'timeout:',
            'timedOut',
            'result.succeeded',
            '"--settings"',
            # A failed probe is unknown, not unsupported: never silently drop the flag.
            'return nil',
            'probed ?? true',
        ],
        'supportsSettingsFlag()',
    )

    cache_actor = extract_block(session, CACHE_MARKER)
    require(
        cache_actor,
        [
            'resolvingSymlinksInPath().standardizedFileURL.path',
            'cached[',
            # Re-probe when the binary at the same path is replaced; cache only definite answers.
            '.modificationDate',
            '.size',
            'if let result {',
        ],
        'AntigravitySettingsFlagCache',
    )

    return mode_fn


def check_behaviour(mode_fn):
    if '__MODE_ARGUMENTS__' not in SWIFT_TEMPLATE:
        fail('SWIFT_TEMPLATE is missing __MODE_ARGUMENTS__ placeholder')
    with tempfile.TemporaryDirectory(prefix='tivano-antigravity-mode-') as temp:
        directory = Path(temp)
        swift, binary = directory / 'Checks.swift', directory / 'checks'
        swift.write_text(SWIFT_TEMPLATE.replace('__MODE_ARGUMENTS__', mode_fn), encoding='utf-8')
        build = subprocess.run(
            ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)],
            capture_output=True,
            text=True,
        )
        if build.returncode != 0:
            fail(f'extracted modeArguments does not compile:\n{build.stderr.strip()}')
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        if run.returncode != 0:
            fail(f'mode argument mapping is wrong:\n{(run.stderr or run.stdout).strip()}')
        print(run.stdout.strip())


def main():
    mode_fn = check_sources()
    check_behaviour(mode_fn)


if __name__ == '__main__':
    main()
