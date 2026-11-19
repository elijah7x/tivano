#!/usr/bin/env python3
"""Offline source guard: TextGeneration CLI arguments for grok, pi, and antigravity."""
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
TEXT_GENERATION = ROOT / 'Tivano/Services/Providers/TextGeneration.swift'
PROVIDER_REGISTRY = ROOT / 'Tivano/Services/Providers/ProviderRegistry.swift'
NEXT_FUNCTION = re.compile(r'\b(?:static func |func )')
NEXT_CASE = re.compile(r'(?m)^[ \t]*case[ \t]+')


def block_body(source, marker, relative, failures):
    count = source.count(marker)
    if count != 1:
        failures.append(f'{relative}: starting marker {marker!r} found {count} times, expected 1')
        return None
    start = source.index(marker)
    opening = source.find('{', start)
    if opening == -1:
        failures.append(f'{relative}: no opening {{ for starting marker {marker!r}')
        return None
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    failures.append(f'{relative}: no closing }} for starting marker {marker!r}')
    return None


def function_body(source, marker, relative, failures):
    count = source.count(marker)
    if count != 1:
        failures.append(f'{relative}: starting marker {marker!r} found {count} times, expected 1')
        return None
    start = source.index(marker)
    next_function = NEXT_FUNCTION.search(source, start + len(marker))
    end = next_function.start() if next_function else len(source)
    return source[start:end]


def switch_branch(body, marker, function_name, relative, failures):
    count = body.count(marker)
    if count != 1:
        failures.append(
            f'{relative}: {function_name} has starting marker {marker!r} {count} times, expected 1'
        )
        return None
    start = body.index(marker)
    next_case = NEXT_CASE.search(body, start + len(marker))
    end = next_case.start() if next_case else len(body)
    return body[start:end]


def check_text_generation(source, relative):
    failures = []
    engine_block = block_body(source, 'enum Engine: Sendable {', relative, failures)
    if engine_block is not None:
        expected_cases = (
            'case grok(executable: URL, environment: [String: String], model: String?, effort: String? = nil)',
            'case pi(executable: URL, environment: [String: String], model: String?, effort: String? = nil)',
            'case antigravity(executable: URL, environment: [String: String], model: String?, effort: String? = nil)',
        )
        for signature in expected_cases:
            if signature not in engine_block:
                failures.append(f'{relative}: enum Engine is missing exact case {signature!r}')

    review_body = function_body(source, 'static func review(', relative, failures)
    if review_body is not None:
        grok_review = switch_branch(review_body, 'case .grok(', 'review', relative, failures)
        if grok_review is not None:
            if '"--tools"' in grok_review:
                failures.append(f'{relative}: review grok branch must not pass "--tools"')
            for token in ('"--prompt-file"', '"--output-format"', '"plain"', '"--permission-mode"', '"dontAsk"', '"--disable-web-search"', '"--add-dir"'):
                if token not in grok_review:
                    failures.append(f'{relative}: review grok branch is missing {token}')

        pi_review = switch_branch(review_body, 'case .pi(', 'review', relative, failures)
        if pi_review is not None:
            if '"read,grep,find,ls"' not in pi_review:
                failures.append(f'{relative}: review pi branch is missing "read,grep,find,ls"')
            if '"--tools"' not in pi_review:
                failures.append(f'{relative}: review pi branch is missing "--tools"')
            if '"--no-tools"' in pi_review:
                failures.append(f'{relative}: review pi branch must not pass "--no-tools"')
            if '--no-extensions' in pi_review:
                failures.append(f'{relative}: review pi branch must not pass --no-extensions')
            if '"PI_SKIP_VERSION_CHECK"' not in pi_review:
                failures.append(f'{relative}: review pi branch is missing "PI_SKIP_VERSION_CHECK"')

        agy_review = switch_branch(review_body, 'case .antigravity(', 'review', relative, failures)
        if agy_review is not None:
            if 'Shell.run(' not in agy_review:
                failures.append(f'{relative}: review antigravity branch must invoke Shell.run')
            # The review request travels over stdin, never in process arguments.
            if re.search(r'"-p"|"--print"|arguments\s*\+?=\s*\[[^\]]*\bprompt\b', agy_review) is not None:
                failures.append(f'{relative}: review antigravity branch must not pass the prompt in arguments')
            if re.search(r'Shell\.run\([^)]*\binput:\s*input\b', agy_review) is None:
                failures.append(f'{relative}: review antigravity branch must send the turn on stdin')
            for token in ('NetworkPath.isUsable()', 'AntigravitySession.isTransientFailure', '"--input-format"', '"--output-format"', '"stream-json"', '"event": "user"', 'AntigravitySession.oneShotReply(streamJSON:', '"--mode"', '"plan"', '"--add-dir"'):
                if token not in agy_review:
                    failures.append(f'{relative}: review antigravity branch is missing {token}')

    # A review agy recovered inside the turn must be judged like a chat turn, not by status alone.
    session_path = ROOT / 'Tivano/Services/Providers/AntigravitySession.swift'
    session = session_path.read_text(encoding='utf-8')
    helper_start = session.find('nonisolated static func oneShotReply(streamJSON output: String)')
    helper_end = session.find('guard let result else', helper_start)
    if helper_start < 0 or helper_end < 0:
        failures.append('AntigravitySession.swift: oneShotReply(streamJSON:) helper not found')
    else:
        helper = session[helper_start:session.find('\n    }\n', helper_end)]
        for token in ('turnOutcome(', 'latestCascadeErrorIndex: latestError?.index', 'completedResponseIndex: completedIndex', 'guard outcome.status == .completed'):
            if token not in helper:
                failures.append(f'AntigravitySession.swift: oneShotReply is missing {token}')

    run_detailed_body = function_body(source, 'private static func runDetailed(', relative, failures)
    if run_detailed_body is not None:
        grok_bg = switch_branch(run_detailed_body, 'case .grok(', 'runDetailed', relative, failures)
        if grok_bg is not None:
            if re.search(r'"--tools"\s*,\s*""', grok_bg) is None:
                failures.append(f'{relative}: runDetailed grok branch must pass "--tools", ""')
            for token in ('"--prompt-file"', '"--output-format"', '"plain"', '"--permission-mode"', '"dontAsk"', '"--disable-web-search"'):
                if token not in grok_bg:
                    failures.append(f'{relative}: runDetailed grok branch is missing {token}')

        pi_bg = switch_branch(run_detailed_body, 'case .pi(', 'runDetailed', relative, failures)
        if pi_bg is not None:
            if '"--no-tools"' not in pi_bg:
                failures.append(f'{relative}: runDetailed pi branch is missing "--no-tools"')
            if '--no-extensions' in pi_bg:
                failures.append(f'{relative}: runDetailed pi branch must not pass --no-extensions')
            if '"PI_SKIP_VERSION_CHECK"' not in pi_bg:
                failures.append(f'{relative}: runDetailed pi branch is missing "PI_SKIP_VERSION_CHECK"')

        agy_bg = switch_branch(run_detailed_body, 'case .antigravity:', 'runDetailed', relative, failures)
        if agy_bg is not None:
            if 'Shell.run' in agy_bg:
                failures.append(f'{relative}: runDetailed antigravity branch must not run a process')
            if '"Antigravity is not offered for background text"' not in agy_bg:
                failures.append(f'{relative}: runDetailed antigravity branch is missing the expected rejection message')

    return failures


def check_provider_registry(source, relative):
    failures = []
    auth_body = function_body(source, 'static func auth(', relative, failures)
    if auth_body is not None:
        grok_auth = switch_branch(auth_body, 'case .grok:', 'auth', relative, failures)
        if grok_auth is not None:
            for token in ('.grok/auth.json', 'XAI_API_KEY', 'ProcessInfo.processInfo.environment', '.signedOut'):
                if token not in grok_auth:
                    failures.append(f'{relative}: auth grok branch is missing {token!r}')
    return failures


def main():
    failures = []
    sources = {}
    for relative, path in (
        ('Tivano/Services/Providers/TextGeneration.swift', TEXT_GENERATION),
        ('Tivano/Services/Providers/ProviderRegistry.swift', PROVIDER_REGISTRY),
    ):
        if path.is_file():
            sources[relative] = path.read_text(encoding='utf-8')
        else:
            failures.append(f'{relative} is missing')

    for relative, checker in (
        ('Tivano/Services/Providers/TextGeneration.swift', check_text_generation),
        ('Tivano/Services/Providers/ProviderRegistry.swift', check_provider_registry),
    ):
        if relative in sources:
            failures.extend(checker(sources[relative], relative))

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('PASS: TextGeneration CLI arguments and grok auth fallback are valid.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
