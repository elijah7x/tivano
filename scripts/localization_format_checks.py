#!/usr/bin/env python3
"""Offline guard: every translation keeps the printf arguments of its catalog key.

String(format:) reads each argument as the type its specifier names, so a
translation that reorders "%@ ... %lld ... %@" without positional specifiers
("%1$@", "%3$lld") makes it read an Int as an object pointer and crash.
For every key in Tivano/Resources/Localizable.xcstrings, each translated value
(including nested plural/device variations) must use the same argument
positions with the same kinds as the key.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'Tivano/Resources/Localizable.xcstrings'

# %%, then a substitution reference (%#@name@) is not an argument.
LITERAL = re.compile(r'%%|%#@[^@]*@')
SPECIFIER = re.compile(
    r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp])")
KINDS = {
    '@': 'object',
    **dict.fromkeys('dDiuUxXoOcC', 'integer'),
    **dict.fromkeys('fFeEgGaA', 'float'),
    **dict.fromkeys('sS', 'cstring'),
    'p': 'pointer',
}


def arguments(text):
    """Return ({position: kind}, [problems]) for one format string."""
    positions, problems = {}, []
    positional = sequential = False
    next_index = 1
    for match in SPECIFIER.finditer(LITERAL.sub('', text)):
        number, length, conversion = match.groups()
        kind = KINDS[conversion]
        # Width matters too: `%d` reads 32 bits of a 64-bit Int, `%Lf` a long double.
        if kind == 'integer' and conversion not in 'cC':
            kind += '64' if length in ('l', 'll', 'q', 'z', 't', 'j') or conversion in 'DUO' else '32'
        elif kind == 'float' and length == 'L':
            kind = 'long double'
        if number is None:
            sequential = True
            index, next_index = next_index, next_index + 1
        else:
            positional = True
            index = int(number)
        if positions.setdefault(index, kind) != kind:
            problems.append(f'position {index} is both {positions[index]} and {kind}')
    if positional and sequential:
        problems.append('mixes positional (%1$@) and non-positional (%@) specifiers')
    return positions, problems


def describe(positions):
    return ', '.join(f'{index}:{kind}' for index, kind in sorted(positions.items())) or 'none'


def units(node, nested=False):
    """Yield (value, nested) for every stringUnit under a localization or variation."""
    for name, child in node.items():
        if name == 'stringUnit' and isinstance(child, dict):
            if isinstance(child.get('value'), str):
                yield child['value'], nested
        elif isinstance(child, dict):
            yield from units(child, nested or name in ('variations', 'substitutions'))


def main():
    try:
        catalog = json.loads(CATALOG.read_text(encoding='utf-8'))
    except OSError as error:
        print(f'FAIL: cannot read {CATALOG.relative_to(ROOT)}: {error}', file=sys.stderr)
        return 1
    except ValueError as error:
        print(f'FAIL: {CATALOG.relative_to(ROOT)} is not valid JSON: {error}', file=sys.stderr)
        return 1
    strings = catalog.get('strings') if isinstance(catalog, dict) else None
    if not isinstance(strings, dict) or not strings:
        print(f'FAIL: {CATALOG.relative_to(ROOT)} has no "strings" entries', file=sys.stderr)
        return 1

    failures, values = [], 0
    for key, entry in strings.items():
        key_positions, key_problems = arguments(key)
        failures += [(key, '(key)', key, reason) for reason in key_problems]
        localizations = entry.get('localizations') if isinstance(entry, dict) else None
        for language, localization in (localizations or {}).items():
            if not isinstance(localization, dict):
                continue
            for value, nested in units(localization):
                values += 1
                nested = nested or '%#@' in value  # substitution definitions live elsewhere
                positions, problems = arguments(value)
                if problems:
                    failures += [(key, language, value, reason) for reason in problems]
                    continue
                if key_problems:
                    continue  # the key itself is already reported
                # A plural/device variation may drop a number ("One file"); it must not retype one.
                extra = {i: k for i, k in positions.items() if key_positions.get(i) != k}
                if nested and not extra:
                    continue
                if not nested and positions == key_positions:
                    continue
                failures.append((key, language, value,
                                 f'arguments {describe(positions)} do not match key {describe(key_positions)}'))

    for key, language, value, reason in failures:
        print(f'{key} | {language} | {value} | {reason}')
    if failures:
        print(f'FAIL: {len(failures)} localization format mismatch(es) in {len(strings)} keys', file=sys.stderr)
        return 1
    print(f'OK: {values} localized values across {len(strings)} keys keep their format arguments')
    return 0


if __name__ == '__main__':
    sys.exit(main())
