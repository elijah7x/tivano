#!/usr/bin/env python3
"""Offline guard: `agy acp` launch flags and ACP mode mapping stay aligned with Tivano modes.

Interactive Antigravity chats run over `agy acp` in `ACPSession` rather than
headless stream-json with `--settings` / `--mode` flags. `launchArguments(logFileURL:)` (via `antigravityLaunchArguments(logFileURL:)`)
launches `agy acp --add-dir <cwd> [--log-file <path>]` and appends
`--dangerously-skip-permissions` only for `.fullAccess`. Mode selection happens
over ACP in `updateAntigravitySelection`: `.plan` interaction selects `"plan"`,
otherwise `.supervised` -> `"default"`, `.autoAcceptEdits` -> `"accept-edits"`,
`.auto` -> `"auto"`, and `.fullAccess` -> `"default"`. The source assertions fail
loudly if markers drift or stream-json mode probes return, and the extracted
launch-argument and mode-mapping blocks are compiled and executed against every
`(RuntimeMode, InteractionMode)` combination.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ACP = ROOT / 'Tivano/Services/Providers/ACPSession.swift'
SESSION = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'

LAUNCH_MARKER = 'private func launchArguments(logFileURL: URL?) -> [String]'
AGY_LAUNCH_MARKER = 'private func antigravityLaunchArguments(logFileURL: URL?) -> [String]'
START_MARKER = 'private func start(applyingSelection: Bool) async throws -> String'
UPDATE_SELECTION_MARKER = 'private func updateSelection('
AGY_SELECTION_MARKER = 'private func updateAntigravitySelection('

SWIFT_TEMPLATE = r'''import Foundation

enum ProviderKind {
    case antigravity
    case other
}

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

struct SessionConfiguration {
    var provider: ProviderKind = .antigravity
    var runtimeMode: RuntimeMode
}

struct LaunchHarness {
    var configuration: SessionConfiguration
    var workingDirectory: String

__AGY_LAUNCH_FN__

    func launchArguments(logFileURL: URL?) -> [String] {
        switch configuration.provider {
__LAUNCH_BRANCH__
        default:
            []
        }
    }
}

struct ModeHarness {
    func wantedMode(runtimeMode: RuntimeMode, interaction: InteractionMode) -> String {
__WANTED_MODE_BLOCK__
        return wantedMode
    }
}

func expectArgs(_ actual: [String], _ expected: [String], _ label: String) {
    precondition(actual == expected, "\(label): expected \(expected), got \(actual)")
}

func expectMode(_ actual: String, _ expected: String, _ label: String) {
    precondition(actual == expected, "\(label): expected \(expected), got \(actual)")
}

@main struct Checks {
    static func main() {
        let cwd = "/tmp/work"
        let logURL = URL(fileURLWithPath: "/tmp/agy.log")
        let baseWithLog = ["acp", "--add-dir", cwd, "--log-file", logURL.path]
        let baseWithoutLog = ["acp", "--add-dir", cwd]

        for mode in [RuntimeMode.supervised, .autoAcceptEdits, .auto] {
            let harness = LaunchHarness(configuration: SessionConfiguration(runtimeMode: mode), workingDirectory: cwd)
            expectArgs(harness.launchArguments(logFileURL: logURL), baseWithLog, "\(mode) + log")
            expectArgs(harness.launchArguments(logFileURL: nil), baseWithoutLog, "\(mode) + no log")
        }

        let fullAccessHarness = LaunchHarness(configuration: SessionConfiguration(runtimeMode: .fullAccess), workingDirectory: cwd)
        expectArgs(fullAccessHarness.launchArguments(logFileURL: logURL),
                   baseWithLog + ["--dangerously-skip-permissions"], "fullAccess + log")
        expectArgs(fullAccessHarness.launchArguments(logFileURL: nil),
                   baseWithoutLog + ["--dangerously-skip-permissions"], "fullAccess + no log")

        let modeHarness = ModeHarness()
        expectMode(modeHarness.wantedMode(runtimeMode: .supervised, interaction: .build), "default", "supervised + build")
        expectMode(modeHarness.wantedMode(runtimeMode: .supervised, interaction: .plan), "plan", "supervised + plan")
        expectMode(modeHarness.wantedMode(runtimeMode: .autoAcceptEdits, interaction: .build), "accept-edits", "autoAcceptEdits + build")
        expectMode(modeHarness.wantedMode(runtimeMode: .autoAcceptEdits, interaction: .plan), "plan", "autoAcceptEdits + plan")
        expectMode(modeHarness.wantedMode(runtimeMode: .auto, interaction: .build), "auto", "auto + build")
        expectMode(modeHarness.wantedMode(runtimeMode: .auto, interaction: .plan), "plan", "auto + plan")
        expectMode(modeHarness.wantedMode(runtimeMode: .fullAccess, interaction: .build), "default", "fullAccess + build")
        expectMode(modeHarness.wantedMode(runtimeMode: .fullAccess, interaction: .plan), "plan", "fullAccess + plan")

        print("PASS: agy acp launch args and ACP mode mapping match supervised/accept-edits/auto/fullAccess/plan.")
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


def between(text, start, end, path=ACP):
    for marker in (start, end):
        count = text.count(marker)
        if count != 1:
            fail(f'{path.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    start_index = text.index(start)
    end_index = text.index(end)
    if end_index <= start_index:
        fail(f'{path.relative_to(ROOT)}: marker {end!r} appears before {start!r}')
    return text[start_index:end_index]


def extract_block(text, marker, path=ACP):
    count = text.count(marker)
    if count != 1:
        fail(f'{path.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    start = text.index(marker)
    opening = text.find('{', start + len(marker))
    if opening < 0:
        fail(f'{path.relative_to(ROOT)}: no opening brace for {marker!r}')
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
    fail(f'{path.relative_to(ROOT)}: no closing brace for {marker!r}')


def require(snippet, tokens, label, path=ACP):
    for token in tokens:
        if token not in snippet:
            fail(f'{path.relative_to(ROOT)}: {label} is missing {token!r}')


def check_sources():
    acp = source(ACP)
    session = source(SESSION)

    start_fn = extract_block(acp, START_MARKER)
    require(
        start_fn,
        [
            'launchArguments(logFileURL: logFileURL)',
            'try Task.checkCancellation()',
            'guard !isStopping else { throw ProviderError.notRunning }',
            'applySelection(',
        ],
        'start(applyingSelection:)',
    )

    launch_fn = extract_block(acp, LAUNCH_MARKER)
    launch_branch = between(launch_fn, 'case .antigravity:', 'case .cursor:')
    if 'antigravityLaunchArguments(logFileURL: logFileURL)' not in launch_branch:
        fail(f'{ACP.relative_to(ROOT)}: launchArguments() .antigravity branch must delegate to antigravityLaunchArguments(logFileURL:)')
    agy_launch_fn = extract_block(acp, AGY_LAUNCH_MARKER)
    require(
        agy_launch_fn,
        [
            '"acp"',
            '"--add-dir"',
            'workingDirectory',
            '"--log-file"',
            'logFileURL.path',
            'configuration.runtimeMode == .fullAccess',
            '"--dangerously-skip-permissions"',
        ],
        'antigravityLaunchArguments()',
    )
    for forbidden in ('"--settings"', '"--mode"', 'agentMode'):
        if forbidden in agy_launch_fn:
            fail(f'{ACP.relative_to(ROOT)}: antigravityLaunchArguments must not carry stream-json flag {forbidden!r}')

    update_selection_fn = extract_block(acp, UPDATE_SELECTION_MARKER)
    require(
        update_selection_fn,
        [
            'if configuration.provider == .antigravity',
            'try await updateAntigravitySelection(',
        ],
        'updateSelection()',
    )

    agy_selection_fn = extract_block(acp, AGY_SELECTION_MARKER)
    require(
        agy_selection_fn,
        [
            'if interaction == .plan',
            'wantedMode = "plan"',
            'case .supervised: "default"',
            'case .autoAcceptEdits: "accept-edits"',
            'case .auto: "auto"',
            'case .fullAccess: "default"',
            'guard availableModeIDs.contains(wantedMode) else {',
            'Antigravity did not offer the requested permission or plan mode.',
            'if wantedMode != currentMode',
            'setConfigOption(modeConfigID, value: wantedMode)',
            'deadlineRequest(connection, "session/set_mode"',
            'try checkSelectionActive(generation)',
        ],
        'updateAntigravitySelection()',
    )

    wanted_mode_block = between(
        agy_selection_fn,
        'let wantedMode: String',
        '// A missing mode would leave the turn',
    )

    for removed in ('supportsSettingsFlag', 'AntigravitySettingsFlagCache', 'modeArguments'):
        if removed in session:
            fail(f'{SESSION.relative_to(ROOT)}: removed stream-json mode helper {removed!r} must not return')

    return launch_branch, agy_launch_fn, wanted_mode_block


def check_behaviour(launch_branch, agy_launch_fn, wanted_mode_block):
    for placeholder in ('__LAUNCH_BRANCH__', '__AGY_LAUNCH_FN__', '__WANTED_MODE_BLOCK__'):
        if placeholder not in SWIFT_TEMPLATE:
            fail(f'SWIFT_TEMPLATE is missing {placeholder} placeholder')
    swift_source = (
        SWIFT_TEMPLATE
        .replace('__LAUNCH_BRANCH__', launch_branch)
        .replace('__AGY_LAUNCH_FN__', agy_launch_fn)
        .replace('__WANTED_MODE_BLOCK__', wanted_mode_block)
    )
    with tempfile.TemporaryDirectory(prefix='tivano-antigravity-mode-') as temp:
        directory = Path(temp)
        swift, binary = directory / 'Checks.swift', directory / 'checks'
        swift.write_text(swift_source, encoding='utf-8')
        build = subprocess.run(
            ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(binary)],
            capture_output=True,
            text=True,
        )
        if build.returncode != 0:
            fail(f'extracted ACP mode mapping does not compile:\n{build.stderr.strip()}')
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        if run.returncode != 0:
            fail(f'ACP mode mapping is wrong:\n{(run.stderr or run.stdout).strip()}')
        print(run.stdout.strip())


def main():
    launch_branch, agy_launch_fn, wanted_mode_block = check_sources()
    check_behaviour(launch_branch, agy_launch_fn, wanted_mode_block)


if __name__ == '__main__':
    main()
