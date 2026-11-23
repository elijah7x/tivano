#!/usr/bin/env python3
"""Offline guard for live agy retry status visibility across AntigravitySession and ACPSession.

agy writes silent model-request retries only to its glog file, not stdout/stderr.
`AntigravitySession` provides the log path (`makeLogFileURL`), retry log parser
(`parseRetryDetails` / `retryLabelKey`), `.info` notice formatter (`retryNotice`),
and `AntigravityLogTailer`. `ACPSession` passes `--log-file` in `agy acp` launch
arguments, starts `AntigravityLogTailer` after the process starts, toggles
`setTurnActive(true)` at prompt start and `setTurnActive(false)` in `finishPrompt`,
deduplicates retry notices per attempt, and shuts the tailer down on `stop`,
`handleClose`, failed startup, and `deinit` so HydraWatchdog and isTransientFailure
stay untouched, while ThreadRuntime records Antigravity .info notices in
providerLastWarning for Hydra's stalled-head report.
"""
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SESSION = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'
ACP = ROOT / 'Tivano/Services/Providers/ACPSession.swift'
RUNTIME = ROOT / 'Tivano/App/Runtime/ThreadRuntime.swift'
CATALOG = ROOT / 'Tivano/Resources/Localizable.xcstrings'

RETRY_REGEX_TEXT = r'run\.go:\d+\] Run: attempt (\d+) failed \((?:request failed: )?(.+)\), retrying in ([0-9.]+)(ms|s|m)'
RETRY_REGEX = re.compile(RETRY_REGEX_TEXT)

EXPECTED_ZH_HANS = {
    'Antigravity: the model request failed (%@); agy is retrying, attempt %lld.':
        'Antigravity：模型请求失败（%@），agy 正在重试，第 %lld 次。',
    'no response for 5 minutes': '5 分钟没有回应',
    'connection dropped': '连接中断',
    'network/DNS error': '网络或 DNS 错误',
    'rate limited': '被限流',
    'server busy': '服务器繁忙',
    'request failed': '请求失败',
}
EXPECTED_LANGUAGES = {'fr', 'ja', 'ko', 'zh-Hans', 'zh-Hant'}


def fail(message):
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def between(text, start, end, label):
    for marker in (start, end):
        count = text.count(marker)
        if count != 1:
            fail(f'{label}: marker {marker!r} found {count} times, expected 1')
    start_idx = text.index(start)
    end_idx = text.index(end)
    if start_idx >= end_idx:
        fail(f'{label}: marker {start!r} does not precede {end!r}')
    return text[start_idx:end_idx]


def require(region, markers, label):
    for marker in markers:
        if marker not in region:
            fail(f'{label} is missing required marker: {marker!r}')


def map_retry_label(reason):
    lowered = reason.lower()
    if 'stream idle timeout' in lowered:
        return 'no response for 5 minutes'
    if lowered.endswith(': eof') or 'unexpected eof' in lowered:
        return 'connection dropped'
    if 'no such host' in lowered or 'i/o timeout' in lowered:
        return 'network/DNS error'
    if '429' in lowered or 'resource_exhausted' in lowered:
        return 'rate limited'
    if '503' in lowered or 'capacity' in lowered:
        return 'server busy'
    return 'request failed'


def parse_retry_line(line):
    match = RETRY_REGEX.search(line)
    if not match:
        return None
    attempt = int(match.group(1))
    reason = match.group(2)
    return attempt, map_retry_label(reason)


def check_sources():
    for path in (SESSION, ACP):
        if not path.is_file():
            fail(f'{path.relative_to(ROOT)} is missing')
    session = SESSION.read_text(encoding='utf-8')
    acp = ACP.read_text(encoding='utf-8')

    # Helpers and tailer in AntigravitySession.swift.
    retry_section = between(session, '// MARK: - Retry log tailing', '// MARK: - Turn outcome', 'AntigravitySession retry section')
    require(
        retry_section,
        [
            'FileManager.default.homeDirectoryForCurrentUser',
            '.gemini/antigravity-cli/log',
            RETRY_REGEX_TEXT,
            'AppText.localized("Antigravity: the model request failed (%@); agy is retrying, attempt %lld.")',
            'Notice(level: .info,',
        ],
        'AntigravitySession retry section',
    )
    if '/Users/' in retry_section:
        fail('AntigravitySession retry section must not hardcode a /Users/ path')

    notice_fn = between(retry_section, 'static func retryNotice(', 'static func loginHint(', 'retryNotice()')
    for forbidden in ('.error', '.warning'):
        if forbidden in notice_fn:
            fail(f'retryNotice() must emit .info only, found forbidden level {forbidden!r}')

    require(session, ['final class AntigravityLogTailer'], 'AntigravitySession.swift')
    activate_fn = between(session, 'func setTurnActive(_ active: Bool)', 'func shutDown()', 'setTurnActive()')
    require(activate_fn, ['skipBacklog()'], 'setTurnActive() skips the previous turn backlog')
    if 'poll()\n                let timer' in activate_fn:
        fail('setTurnActive() must not replay the previous turn backlog')

    # Lifecycle and deduping in ACPSession.swift.
    deinit_fn = between(acp, 'isolated deinit {', 'var isRunning: Bool', 'ACPSession deinit')
    require(deinit_fn, ['antigravityLogTailer?.shutDown()'], 'ACPSession deinit')

    launch_fn = between(acp, 'private func launchArguments(logFileURL: URL?) -> [String]', 'func start() async throws -> String', 'ACPSession.launchArguments()')
    agy_branch = between(launch_fn, 'case .antigravity:', 'case .cursor:', 'ACPSession.launchArguments() .antigravity')
    require(agy_branch, ['antigravityLaunchArguments(logFileURL: logFileURL)'], 'ACPSession.launchArguments() .antigravity')
    agy_launch = between(acp, 'private func antigravityLaunchArguments(logFileURL: URL?) -> [String]', 'func start() async throws -> String', 'ACPSession.antigravityLaunchArguments()')
    require(agy_launch, ['"--log-file"', 'logFileURL.path'], 'ACPSession.antigravityLaunchArguments()')

    start_fn = between(acp, 'private func start(applyingSelection: Bool) async throws -> String', 'private var clientCapabilities: JSONValue', 'ACPSession.start()')
    require(
        start_fn,
        [
            'AntigravitySession.makeLogFileURL()',
            'launchArguments(logFileURL: logFileURL)',
            'try connection.start()',
            'AntigravityLogTailer(',
            'AntigravitySession.parseRetryDetails(line)',
            'emitAntigravityRetryNotice(',
            'antigravityLogTailer?.shutDown()',
        ],
        'ACPSession.start()',
    )
    if start_fn.index('AntigravityLogTailer(') < start_fn.index('try connection.start()'):
        fail('ACPSession.start() must create AntigravityLogTailer after connection.start() launches the process')

    emit_fn = between(acp, 'private func emitAntigravityRetryNotice(', 'private static func antigravityErrorText(', 'emitAntigravityRetryNotice()')
    require(
        emit_fn,
        [
            'guard promptActive, !isStopping else { return }',
            'antigravityEmittedRetryAttempts.insert(attempt).inserted',
            'AntigravitySession.retryNotice(',
        ],
        'emitAntigravityRetryNotice()',
    )
    for forbidden in ('.error', '.warning'):
        if forbidden in emit_fn:
            fail(f'emitAntigravityRetryNotice() must emit .info only, found forbidden level {forbidden!r}')

    send_fn = between(acp, 'func send(_ input: TurnInput) async throws', 'private func continuePromptPreparation(', 'ACPSession.send()')
    require(send_fn, ['antigravityEmittedRetryAttempts.removeAll()', 'antigravityLogTailer?.setTurnActive(true)'], 'ACPSession.send()')

    interrupt_fn = between(acp, 'func interrupt() async', 'func compact() async throws', 'ACPSession.interrupt()')
    require(interrupt_fn, ['stop()', 'connection.notify("session/cancel"', 'self.connection?.close()'], 'ACPSession.interrupt()')

    stop_fn = between(acp, 'func stop() {', 'private func emitAntigravityRetryNotice(', 'ACPSession.stop()')
    require(stop_fn, ['antigravityLogTailer?.shutDown()', 'antigravityEmittedRetryAttempts.removeAll()'], 'ACPSession.stop()')

    finish_fn = between(acp, 'private func finishPrompt(', 'private func handleClose(', 'ACPSession.finishPrompt()')
    require(finish_fn, ['antigravityLogTailer?.setTurnActive(false)', 'antigravityEmittedRetryAttempts.removeAll()'], 'ACPSession.finishPrompt()')

    close_fn = between(acp, 'private func handleClose(', '// MARK: - Mapping', 'ACPSession.handleClose()')
    require(close_fn, ['antigravityLogTailer?.shutDown()'], 'ACPSession.handleClose()')

    if not RUNTIME.is_file():
        fail(f'{RUNTIME.relative_to(ROOT)} is missing')
    runtime = RUNTIME.read_text(encoding='utf-8')
    notice_branch = between(
        runtime,
        'case .notice(let notice):',
        'case .usageLimit(let resetsAt):',
        'ThreadRuntime.swift .notice branch',
    )
    require(
        notice_branch,
        ['notice.level != .info || sessionSignature?.provider == .antigravity', 'providerLastWarning = notice.message'],
        'ThreadRuntime.swift .notice branch',
    )


def check_localizations():
    if not CATALOG.is_file():
        fail(f'{CATALOG.relative_to(ROOT)} is missing')
    try:
        catalog = json.loads(CATALOG.read_text(encoding='utf-8'))
    except ValueError as error:
        fail(f'{CATALOG.relative_to(ROOT)} is not valid JSON: {error}')
    strings = catalog.get('strings')
    if not isinstance(strings, dict):
        fail(f'{CATALOG.relative_to(ROOT)} has no strings dictionary')

    for key, expected_zh in EXPECTED_ZH_HANS.items():
        entry = strings.get(key)
        if not isinstance(entry, dict):
            fail(f'{CATALOG.relative_to(ROOT)} is missing key {key!r}')
        localizations = entry.get('localizations')
        if not isinstance(localizations, dict):
            fail(f'{CATALOG.relative_to(ROOT)} key {key!r} is missing localizations')
        missing_langs = sorted(EXPECTED_LANGUAGES - set(localizations.keys()))
        if missing_langs:
            fail(f'{CATALOG.relative_to(ROOT)} key {key!r} is missing languages: {missing_langs}')
        zh_val = localizations.get('zh-Hans', {}).get('stringUnit', {}).get('value')
        if zh_val != expected_zh:
            fail(f'{CATALOG.relative_to(ROOT)} key {key!r} zh-Hans={zh_val!r}, expected {expected_zh!r}')


def check_parser_mirror():
    cases = [
        (
            'I1118 10:09:39.657907     771 run.go:317] Run: attempt 1 failed '
            '(request failed: Post "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse": EOF), '
            'retrying in 4s',
            (1, 'connection dropped'),
        ),
        (
            'I1122 10:52:03.471245   60994 run.go:308] Run: attempt 1 failed '
            '(stream reading error: unexpected EOF), retrying in 4s',
            (1, 'connection dropped'),
        ),
        (
            'I1115 22:55:01.000000     123 run.go:317] Run: attempt 2 failed '
            '(request failed: stream idle timeout (5m0s): context deadline exceeded), '
            'retrying in 6.505268531s',
            (2, 'no response for 5 minutes'),
        ),
        (
            'I1118 10:09:39.657907     771 run.go:317] Run: attempt 1 failed '
            '(request failed: dial tcp: lookup oauth2.googleapis.com: no such host), '
            'retrying in 4s',
            (1, 'network/DNS error'),
        ),
        (
            'I1118 10:10:00.000000     771 run.go:317] Run: attempt 3 failed '
            '(request failed: HTTP 429 RESOURCE_EXHAUSTED), retrying in 500ms',
            (3, 'rate limited'),
        ),
        (
            'I1118 10:10:10.000000     771 run.go:317] Run: attempt 4 failed '
            '(request failed: 503 high capacity), retrying in 1.5m',
            (4, 'server busy'),
        ),
        (
            'I1118 10:10:20.000000     771 run.go:317] Run: attempt 5 failed '
            '(request failed: some other error), retrying in 8s',
            (5, 'request failed'),
        ),
        (
            'I1118 10:09:39.657907     771 run.go:100] Run: started turn',
            None,
        ),
    ]
    for line, expected in cases:
        actual = parse_retry_line(line)
        if actual != expected:
            fail(f'parse_retry_line({line!r}) = {actual!r}, expected {expected!r}')


def main():
    check_sources()
    check_localizations()
    check_parser_mirror()
    print('OK: agy ACP retry status log tailing, .info notice guards, localizations, and parser mirror passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
