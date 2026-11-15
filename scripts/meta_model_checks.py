#!/usr/bin/env python3
"""Offline guard: Meta's model list keeps Muse Wonder and Muse Ember.

Meta's /models also serves `muse-wonder-1.0` and `muse-ember-1.0`, both chat models
that take and default to `reasoning_effort: "max"`. MetaAPI used to accept only
`muse-spark*` ids, so both vanished from the picker and lost vision and max effort.
The same endpoint lists non-chat ids (`muse-image-1.0`, `muse-voice-transcribe-1.0`)
that fail on chat/completions, so a bare `muse-` prefix must never be accepted.
The prefixes are evaluated here the way the Swift helpers do.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
META_API = ROOT / 'Tivano/Services/Providers/MetaAPI.swift'
META_SESSION = ROOT / 'Tivano/Services/Providers/MetaSession.swift'

failures = []


def fail(message):
    failures.append(message)


def require(text, marker, where):
    if marker not in text:
        fail(f'{where}: marker not found: {marker}')
        return False
    return True


def function_body(text, signature, where):
    if text.count(signature) != 1:
        fail(f'{where}: expected exactly one `{signature}`')
        return ''
    start = text.index(signature)
    depth, opened = 0, False
    for index in range(text.index('{', start), len(text)):
        if text[index] == '{':
            depth += 1
            opened = True
        elif text[index] == '}':
            depth -= 1
            if opened and depth == 0:
                return text[start:index + 1]
    fail(f'{where}: unterminated `{signature}`')
    return ''


def main():
    api = META_API.read_text(encoding='utf-8')
    session = META_SESSION.read_text(encoding='utf-8')

    match = re.search(r'static let chatModelPrefixes = \[([^\]]*)\]', api)
    if not match:
        fail('MetaAPI.swift: `chatModelPrefixes` array not found')
        prefixes = []
    else:
        prefixes = re.findall(r'"([^"]*)"', match.group(1))
        for expected in ('muse-spark', 'muse-wonder', 'muse-ember'):
            if expected not in prefixes:
                fail(f'MetaAPI.swift: chatModelPrefixes lacks {expected}')
        if any(not p.startswith('muse-') or p == 'muse-' for p in prefixes):
            fail(f'MetaAPI.swift: chatModelPrefixes must name Muse chat families only, got {prefixes}')

    def accepted(model_id):
        return any(model_id.lower().startswith(p) for p in prefixes)

    for model_id in ('muse-spark-1.3', 'muse-wonder-1.0', 'muse-ember-1.0'):
        if not accepted(model_id):
            fail(f'chat model {model_id} would be rejected')
    for model_id in ('muse-image-1.0', 'muse-voice-transcribe-1.0'):
        if accepted(model_id):
            fail(f'non-chat model {model_id} would be accepted')

    has_prefix = function_body(api, 'private static func hasChatPrefix(_ id: String) -> Bool', 'MetaAPI.swift')
    require(has_prefix, 'chatModelPrefixes', 'hasChatPrefix')
    option = function_body(api, 'static func option(for id: String) -> ModelOption?', 'MetaAPI.swift')
    if 'default:' in option:
        default_branch = option[option.index('default:'):]
        require(default_branch, 'guard hasChatPrefix(id) else { return nil }', 'option(for:) default branch')
    else:
        fail('option(for:): default branch not found')
    for model_id in ('muse-wonder-1.0', 'muse-ember-1.0'):
        require(option, f'case "{model_id}":', 'option(for:)')
    vision = function_body(api, 'static func isVisionModel(_ id: String?) -> Bool', 'MetaAPI.swift')
    require(vision, 'hasChatPrefix(id)', 'isVisionModel')

    max_effort = function_body(api, 'private static func supportsMaxEffort(_ id: String) -> Bool', 'MetaAPI.swift')
    for marker in ('"muse-spark-1.3"', 'hasPrefix("muse-wonder")', 'hasPrefix("muse-ember")'):
        require(max_effort, marker, 'supportsMaxEffort')
    efforts = function_body(api, 'static func efforts(for id: String) -> [String]', 'MetaAPI.swift')
    require(efforts, 'supportsMaxEffort(id) ? maxEfforts : standardEfforts', 'efforts(for:)')
    if not re.search(r'static let maxEfforts = \[[^\]]*"max"', api):
        fail('MetaAPI.swift: maxEfforts must include "max"')
    if re.search(r'static let standardEfforts = \[[^\]]*"max"', api):
        fail('MetaAPI.swift: standardEfforts must not include "max"')

    # The session must not downgrade max for the models MetaAPI grants it to.
    require(session, 'MetaAPI.efforts(for:', 'MetaSession.swift')

    if failures:
        for message in failures:
            print(f'FAIL: {message}', file=sys.stderr)
        return 1
    print('PASS: Meta keeps Muse Spark/Wonder/Ember, rejects non-chat Muse ids, and grants max effort to 1.3, Wonder and Ember.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
