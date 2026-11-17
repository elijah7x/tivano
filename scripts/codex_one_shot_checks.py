#!/usr/bin/env python3
"""Offline source guard: Codex one-shot calls disable plugins, apps, and telemetry."""
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
CODEX_SESSION = ROOT / 'Tivano/Services/Providers/CodexSession.swift'
TEXT_GENERATION = ROOT / 'Tivano/Services/Providers/TextGeneration.swift'
NEXT_FUNCTION = re.compile(r'\b(?:static func |func )')
NEXT_CASE = re.compile(r'(?m)^[ \t]*case[ \t]+')


def function_body(source, marker, relative, failures):
    count = source.count(marker)
    if count != 1:
        failures.append(f'{relative}: starting marker {marker!r} found {count} times, expected 1')
        return None
    start = source.index(marker)
    next_function = NEXT_FUNCTION.search(source, start + len(marker))
    end = next_function.start() if next_function else len(source)
    return source[start:end]


def array_declaration(source, marker, relative, failures):
    count = source.count(marker)
    if count != 1:
        failures.append(f'{relative}: starting marker {marker!r} found {count} times, expected 1')
        return None
    start = source.index(marker)
    opening = start + len(marker) - 1
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '[':
            depth += 1
        elif source[index] == ']':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    failures.append(f'{relative}: no closing ] for starting marker {marker!r}')
    return None


def codex_branch(body, function_name, relative, failures):
    marker = 'case .codex('
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


def check_codex_session(source, relative):
    failures = []
    declaration = array_declaration(
        source, 'static let oneShotConfigArguments = [', relative, failures
    )
    if declaration is not None:
        for argument in (
            'features.plugins=false',
            'features.apps=false',
            'analytics.enabled=false',
            'otel.metrics_exporter',
        ):
            if argument not in declaration:
                failures.append(f'{relative}: oneShotConfigArguments is missing {argument!r}')

    markers = {
        'listModels': 'static func listModels(',
        'readPlanLimits': 'static func readPlanLimits(',
        'consumeResetCredit': 'static func consumeResetCredit(',
        'listCommands': 'static func listCommands(',
        'connect': 'private static func connect(',
    }
    bodies = {
        name: function_body(source, marker, relative, failures)
        for name, marker in markers.items()
    }
    for name in ('listModels', 'readPlanLimits', 'consumeResetCredit'):
        if bodies[name] is not None and 'oneShot: true' not in bodies[name]:
            failures.append(f'{relative}: {name} must call connect with oneShot: true')
    if bodies['listCommands'] is not None and 'oneShot: true' in bodies['listCommands']:
        failures.append(f'{relative}: listCommands must not use one-shot arguments')
    if bodies['connect'] is not None:
        for marker in ('oneShot', 'oneShotConfigArguments'):
            if marker not in bodies['connect']:
                failures.append(f'{relative}: connect is missing {marker!r}')
    return failures


def check_text_generation(source, relative):
    failures = []
    markers = {
        'review': 'static func review(',
        'runDetailed': 'private static func runDetailed(',
    }
    argument = 'arguments += CodexSession.oneShotConfigArguments'
    output = '"--output-last-message"'
    for name, marker in markers.items():
        body = function_body(source, marker, relative, failures)
        if body is None:
            continue
        branch = codex_branch(body, name, relative, failures)
        if branch is None:
            continue
        argument_index = branch.find(argument)
        output_index = branch.find(output)
        if argument_index == -1:
            failures.append(f'{relative}: {name} Codex branch is missing {argument!r}')
        if output_index == -1:
            failures.append(f'{relative}: {name} Codex branch is missing ordering marker {output!r}')
        elif argument_index != -1 and argument_index > output_index:
            failures.append(f'{relative}: {name} must add one-shot arguments before {output}')
    return failures


def main():
    failures = []
    sources = {}
    for relative, path in (
        ('Tivano/Services/Providers/CodexSession.swift', CODEX_SESSION),
        ('Tivano/Services/Providers/TextGeneration.swift', TEXT_GENERATION),
    ):
        if path.is_file():
            sources[relative] = path.read_text(encoding='utf-8')
        else:
            failures.append(f'{relative} is missing')

    for relative, checker in (
        ('Tivano/Services/Providers/CodexSession.swift', check_codex_session),
        ('Tivano/Services/Providers/TextGeneration.swift', check_text_generation),
    ):
        if relative in sources:
            failures.extend(checker(sources[relative], relative))

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('PASS: Codex one-shot arguments are preserved for app-server and CLI calls.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
