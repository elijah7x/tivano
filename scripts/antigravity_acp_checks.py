#!/usr/bin/env python3
"""Offline guard for Antigravity's `agy acp` integration boundaries.

Verifies the structural invariants that keep Antigravity interactive chats routed
through `ACPSession`:
- `ThreadRuntime` constructs `ACPSession` for `.antigravity` and no longer
  instantiates `AntigravitySession(configuration:)`.
- `SessionSignature` relaunches Antigravity on runtime mode changes, not on
  model, effort, fast, or interaction mode changes.
- `ProviderKind.supportsImages` includes `.antigravity`.
- `ACPSession` resumes Antigravity sessions with `session/resume`.
- `ACPSession` enables elicitation for `.antigravity` in both
  `clientCapabilities` and the `elicitation/create` handler gate.
- `applyModels` and `applyConfigOptions` do not overwrite Antigravity's
  `agy models` catalog.
- The old-`agy` upgrade message is wired in `ACPSession.swift` and localized in
  `Localizable.xcstrings` (including `zh-Hans`).
- `AntigravitySession` is a helper `enum` without `ProviderSession` conformance.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ACP = ROOT / 'Tivano/Services/Providers/ACPSession.swift'
SESSION = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'
RUNTIME = ROOT / 'Tivano/App/Runtime/ThreadRuntime.swift'
PROVIDER = ROOT / 'Tivano/Core/Models/Provider.swift'
CATALOG = ROOT / 'Tivano/Resources/Localizable.xcstrings'
RUNNER = ROOT / 'Tivano/App/Control/EphemeralAgentRunner.swift'

OLD_AGY_KEY = 'Antigravity needs agy 1.5.0 or later for Tivano chats. Update the Antigravity CLI and try again.'
OLD_AGY_ZH = 'Tivano 对话需要 agy 1.5.0 或更高版本。请更新 Antigravity CLI 后重试。'
EXPECTED_LANGUAGES = {'fr', 'ja', 'ko', 'zh-Hans', 'zh-Hant'}


def fail(message):
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def source(path):
    if not path.is_file():
        fail(f'{path.relative_to(ROOT)} is missing')
    return path.read_text(encoding='utf-8')


def extract_delimited(text, marker, open_ch, close_ch, path):
    count = text.count(marker)
    if count != 1:
        fail(f'{path.relative_to(ROOT)}: marker {marker!r} found {count} times, expected 1')
    start = text.index(marker)
    opening = text.find(open_ch, start + len(marker) - (1 if marker.endswith(open_ch) else 0))
    if opening < 0:
        fail(f'{path.relative_to(ROOT)}: no opening {open_ch!r} for {marker!r}')
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
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
        index += 1
    fail(f'{path.relative_to(ROOT)}: no closing {close_ch!r} for {marker!r}')


def extract_block(text, marker, path):
    return extract_delimited(text, marker, '{', '}', path)


def extract_call(text, marker, path):
    return extract_delimited(text, marker, '(', ')', path)


def check_thread_runtime():
    runtime = source(RUNTIME)

    # 1. Session factory routes .antigravity to ACPSession and never constructs AntigravitySession.
    make_session = extract_block(runtime, 'func makeSession(resumeID: String?) -> any ProviderSession', RUNTIME)
    if not re.search(r'case\s+[^\n]*\.antigravity[^\n]*:\s*ACPSession\(configuration:\s*configuration\)', make_session):
        fail(f'{RUNTIME.relative_to(ROOT)}: makeSession() must list .antigravity in the ACPSession case')
    if 'AntigravitySession(configuration:' in runtime:
        fail(f'{RUNTIME.relative_to(ROOT)}: must no longer call AntigravitySession(configuration:)')
    runner = source(RUNNER)
    if 'AntigravitySession(configuration:' in runner or not re.search(r'case [^\n]*\.antigravity[^\n]*: ACPSession\(configuration: configuration\)', runner):
        fail(f'{RUNNER.relative_to(ROOT)}: the agent bridge must run Antigravity through ACPSession')

    # 2. SessionSignature relaunches Antigravity on runtimeMode, not model/effort/fast/interaction.
    sig_struct = extract_block(runtime, 'private struct SessionSignature: Equatable', RUNTIME)
    if re.search(r'\bvar\s+(launchModel|model)\b', sig_struct):
        fail(f'{RUNTIME.relative_to(ROOT)}: SessionSignature must not relaunch sessions on model changes')

    sig_call = extract_call(runtime, 'let signature = SessionSignature(', RUNTIME)
    field_lines = {}
    for line in sig_call.splitlines():
        stripped = line.strip()
        match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:', stripped)
        if match:
            field_lines[match.group(1)] = stripped

    for required_field in ('launchRuntimeMode', 'launchEffort', 'launchFast', 'launchInteraction'):
        if required_field not in field_lines:
            fail(f'{RUNTIME.relative_to(ROOT)}: SessionSignature(...) is missing field {required_field!r}')
    if '.antigravity' not in field_lines['launchRuntimeMode']:
        fail(f'{RUNTIME.relative_to(ROOT)}: SessionSignature.launchRuntimeMode must include .antigravity')
    for no_relaunch_field in ('launchEffort', 'launchFast', 'launchInteraction'):
        if '.antigravity' in field_lines[no_relaunch_field]:
            fail(f'{RUNTIME.relative_to(ROOT)}: SessionSignature.{no_relaunch_field} must not relaunch .antigravity')
    for model_field in ('model', 'launchModel'):
        if model_field in field_lines:
            fail(f'{RUNTIME.relative_to(ROOT)}: SessionSignature(...) must not carry {model_field!r}')


def check_provider():
    provider = source(PROVIDER)
    supports_images = extract_block(provider, 'var supportsImages: Bool', PROVIDER)
    if 'self !=' not in supports_images:
        fail(f'{PROVIDER.relative_to(ROOT)}: supportsImages shape changed unexpectedly; verify .antigravity stays included')
    if '.antigravity' in supports_images:
        fail(f'{PROVIDER.relative_to(ROOT)}: supportsImages must not exclude .antigravity')


def check_acp_session():
    acp = source(ACP)

    # 4. ACPSession resumes Antigravity with session/resume.
    open_session = extract_block(
        acp,
        'private func openSession(_ connection: JSONRPCConnection, servers: JSONValue) async throws -> JSONValue',
        ACP,
    )
    resume_match = re.search(r'if[^\n]*\.antigravity[^\n]*\{', open_session)
    if not resume_match:
        fail(f'{ACP.relative_to(ROOT)}: openSession() has no .antigravity branch for session/resume')
    resume_branch = extract_block(open_session, resume_match.group(0), ACP)
    for token in ('canResumeSessions', '"session/resume"'):
        if token not in resume_branch:
            fail(f'{ACP.relative_to(ROOT)}: openSession() .antigravity resume branch is missing {token!r}')
    if '"session/load"' in resume_branch:
        fail(f'{ACP.relative_to(ROOT)}: Antigravity must resume via session/resume, not session/load')

    # 5. Elicitation enabled for .antigravity in both clientCapabilities and elicitation/create gate.
    capabilities = extract_block(acp, 'private var clientCapabilities: JSONValue', ACP)
    elicitation_cap_match = re.search(r'if[^\n]*\.antigravity[^\n]*\{', capabilities)
    if not elicitation_cap_match:
        fail(f'{ACP.relative_to(ROOT)}: clientCapabilities does not enable elicitation for .antigravity')
    elicitation_cap_block = extract_block(capabilities, elicitation_cap_match.group(0), ACP)
    if 'capabilities["elicitation"]' not in elicitation_cap_block:
        fail(f'{ACP.relative_to(ROOT)}: clientCapabilities .antigravity branch must set capabilities["elicitation"]')

    handle_request = extract_block(acp, 'private func handleRequest(', ACP)
    gate_match = re.search(r'if\s+method\s*==\s*"elicitation/create"[^\{]+\{', handle_request, re.DOTALL)
    if not gate_match:
        fail(f'{ACP.relative_to(ROOT)}: handleRequest() is missing the elicitation/create gate')
    if 'configuration.provider == .antigravity' not in gate_match.group(0):
        fail(f'{ACP.relative_to(ROOT)}: handleRequest() elicitation/create gate must include configuration.provider == .antigravity')

    # 6. applyModels and applyConfigOptions guard-return for .antigravity without replacing catalog.
    apply_models = extract_block(acp, 'private func applyModels(_ state: JSONValue)', ACP)
    # Antigravity only records the advertised variant ids for session/set_model, then returns.
    guard_token = 'if configuration.provider == .antigravity {\n            antigravityModelIDs = Set('
    if guard_token not in apply_models:
        fail(f'{ACP.relative_to(ROOT)}: applyModels() is missing the .antigravity early-return block')
    block = apply_models[apply_models.index(guard_token):]
    if not block.split('\n        }', 1)[0].rstrip().endswith('return'):
        fail(f'{ACP.relative_to(ROOT)}: applyModels() .antigravity block must return before touching the catalog')
    for catalog_write in ('models =', 'onEvent?(.models('):
        if catalog_write not in apply_models:
            fail(f'{ACP.relative_to(ROOT)}: applyModels() missing expected {catalog_write!r} marker')
        if apply_models.index(guard_token) > apply_models.index(catalog_write):
            fail(f'{ACP.relative_to(ROOT)}: applyModels() must guard-return for .antigravity before {catalog_write!r}')

    apply_config = extract_block(acp, 'private func applyConfigOptions(_ options: [JSONValue])', ACP)
    if 'case "model":' not in apply_config or 'case "mode":' not in apply_config:
        fail(f'{ACP.relative_to(ROOT)}: applyConfigOptions() missing case "model": / case "mode": markers')
    model_case = apply_config[apply_config.index('case "model":'):apply_config.index('case "mode":')]
    if 'if configuration.provider == .antigravity' not in model_case or 'break' not in model_case:
        fail(f'{ACP.relative_to(ROOT)}: applyConfigOptions() case "model": must short-circuit .antigravity before rewriting models')
    if 'models =' not in model_case or model_case.index('if configuration.provider == .antigravity') > model_case.index('models ='):
        fail(f'{ACP.relative_to(ROOT)}: applyConfigOptions() case "model": must guard .antigravity before models =')
    guard_token = 'guard configuration.provider != .antigravity else { return }'
    if guard_token not in apply_config:
        fail(f'{ACP.relative_to(ROOT)}: applyConfigOptions() is missing {guard_token!r}')
    for catalog_write in ('models = models.map', 'onEvent?(.models('):
        if catalog_write not in apply_config:
            fail(f'{ACP.relative_to(ROOT)}: applyConfigOptions() missing expected {catalog_write!r} marker')
        if apply_config.index(guard_token) > apply_config.index(catalog_write):
            fail(f'{ACP.relative_to(ROOT)}: applyConfigOptions() must guard-return for .antigravity before {catalog_write!r}')

    # 7a. Old-agy upgrade message exists in ACPSession.swift.
    localized_old_agy = f'AppText.localized("{OLD_AGY_KEY}")'
    start_error = extract_block(acp, 'private static func antigravityStartError(', ACP)
    handle_close = extract_block(acp, 'private func handleClose(', ACP)
    if 'isUnsupportedOldAgy(' not in start_error or localized_old_agy not in start_error:
        fail(f'{ACP.relative_to(ROOT)}: antigravityStartError() must report {OLD_AGY_KEY!r} for unsupported old agy')
    if 'Self.isUnsupportedOldAgy(' not in handle_close or localized_old_agy not in handle_close:
        fail(f'{ACP.relative_to(ROOT)}: handleClose() must report {OLD_AGY_KEY!r} for unsupported old agy')


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

    entry = strings.get(OLD_AGY_KEY)
    if not isinstance(entry, dict):
        fail(f'{CATALOG.relative_to(ROOT)} is missing key {OLD_AGY_KEY!r}')
    localizations = entry.get('localizations')
    if not isinstance(localizations, dict):
        fail(f'{CATALOG.relative_to(ROOT)} key {OLD_AGY_KEY!r} has no localizations')
    missing_langs = sorted(EXPECTED_LANGUAGES - set(localizations.keys()))
    if missing_langs:
        fail(f'{CATALOG.relative_to(ROOT)} key {OLD_AGY_KEY!r} is missing languages: {missing_langs}')
    zh_val = localizations.get('zh-Hans', {}).get('stringUnit', {}).get('value')
    if not isinstance(zh_val, str) or not zh_val.strip():
        fail(f'{CATALOG.relative_to(ROOT)} key {OLD_AGY_KEY!r} has an empty zh-Hans translation')
    if zh_val != OLD_AGY_ZH:
        fail(f'{CATALOG.relative_to(ROOT)} key {OLD_AGY_KEY!r} zh-Hans={zh_val!r}, expected {OLD_AGY_ZH!r}')


def check_antigravity_session_enum():
    session = source(SESSION)
    if not re.search(r'(?m)^enum\s+AntigravitySession\s*\{', session):
        fail(f'{SESSION.relative_to(ROOT)}: AntigravitySession must be declared as a bare enum with no ProviderSession conformance')
    if re.search(r'\bclass\s+AntigravitySession\b', session):
        fail(f'{SESSION.relative_to(ROOT)}: AntigravitySession must not be a class')
    if re.search(r'\b(enum|struct|class|extension)\s+AntigravitySession\b[^\n{]*ProviderSession', session):
        fail(f'{SESSION.relative_to(ROOT)}: AntigravitySession must not conform to ProviderSession')


def check_selection_and_limits():
    """Review guards: a missing mode or model is never silently replaced, and a
    limit-truncated turn is not reported as completed."""
    acp = source(ACP)
    selection = extract_block(acp, 'private func updateAntigravitySelection(', ACP)
    for token in ('guard availableModeIDs.contains(wantedMode) else {',
                  'throw ProviderError.failed(AppText.localized("Antigravity did not offer the requested permission or plan mode.',
                  '"session/set_model"', 'antigravityModelIDs.contains',
                  'Antigravity does not offer %@ right now, so this turn uses %@.'):
        if token not in selection:
            fail(f'{ACP.relative_to(ROOT)}: updateAntigravitySelection() is missing {token!r}')
    finish = extract_block(acp, 'private func finishPrompt(', ACP)
    marker = 'configuration.provider == .antigravity, stopReason == "max_tokens" || stopReason == "max_turn_requests"'
    if marker not in finish or 'Antigravity stopped at a limit before completing the turn.' not in finish:
        fail(f'{ACP.relative_to(ROOT)}: finishPrompt() must fail Antigravity turns that stop at max_tokens/max_turn_requests')
    catalog = json.loads(source(CATALOG))['strings']
    for key in ('Antigravity does not offer %@ right now, so this turn uses %@. Refresh Antigravity\'s models in Settings and choose one again.',
                'its default model',
                'Antigravity did not offer the requested permission or plan mode. Update the Antigravity CLI and try again.',
                'Antigravity stopped at a limit before completing the turn.'):
        zh = catalog.get(key, {}).get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value')
        if not zh:
            fail(f'{CATALOG.relative_to(ROOT)}: key {key!r} needs a zh-Hans translation')


def check_error_mapping():
    """Startup deadlines map to the retryable localized timeout message, and
    failed turns retain RPCError.data details in `evidence`."""
    acp = source(ACP)
    start_error = extract_block(acp, 'private static func antigravityStartError(', ACP)
    for token in (
        'if error is SessionDeadlineError',
        'ProviderError.failed(AppText.localized("Antigravity did not finish starting in time."))',
    ):
        if token not in start_error:
            fail(f'{ACP.relative_to(ROOT)}: antigravityStartError() is missing {token!r}')
    if start_error.index('if error is SessionDeadlineError') > start_error.index('isUnsupportedOldAgy('):
        fail(f'{ACP.relative_to(ROOT)}: antigravityStartError() must map SessionDeadlineError before other checks')

    start_fn = extract_block(acp, 'private func start(applyingSelection: Bool) async throws -> String', ACP)
    auth_marker = 'deadlineRequest(connection, "authenticate", ["methodId": .string(methodID)])'
    open_marker = 'session = try await openSession(connection)'
    if auth_marker not in start_fn:
        fail(f'{ACP.relative_to(ROOT)}: start() is missing Antigravity authenticate request')
    after_auth = start_fn[start_fn.index(auth_marker):]
    if open_marker not in after_auth:
        fail(f'{ACP.relative_to(ROOT)}: start() is missing post-authenticate openSession retry')
    auth_catch = after_auth[:after_auth.index(open_marker)]
    if 'Self.antigravityStartError(error, tail: process.errorTail)' not in auth_catch:
        fail(f'{ACP.relative_to(ROOT)}: start() authenticate catch must map deadlines through antigravityStartError')

    finish = extract_block(acp, 'private func finishPrompt(', ACP)
    agy_branch = extract_block(finish, '} else if configuration.provider == .antigravity {', ACP)
    for token in (
        'let evidence = Self.antigravityErrorText(error)',
        'AntigravitySession.loginHint(in: evidence) ?? evidence',
    ):
        if token not in agy_branch:
            fail(f'{ACP.relative_to(ROOT)}: finishPrompt() .antigravity branch is missing {token!r}')


def main():
    check_thread_runtime()
    check_provider()
    check_acp_session()
    check_localizations()
    check_antigravity_session_enum()
    check_selection_and_limits()
    check_error_mapping()
    print('OK: Antigravity ACP routing, SessionSignature, images, resume, elicitation, catalog guards, old-agy message, and helper enum passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
