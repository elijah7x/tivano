#!/usr/bin/env python3
"""Offline source guard for Z.ai adaptive GLM model parsing."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ZAI_API = ROOT / 'Tivano/Services/Providers/ZaiAPI.swift'

COMMENT_OR_STRING = re.compile(r'"(?:[^"\\]|\\.)*"|//[^\n]*|/\*[\s\S]*?\*/')
HARDCODED_PREFIX = re.compile(r'hasPrefix\("glm-\d+\.')


def strip_comments(text):
    return COMMENT_OR_STRING.sub(lambda m: m.group(0) if m.group(0).startswith('"') else ' ', text)


def main():
    failures = []
    if not ZAI_API.is_file():
        print(f'FAIL: {ZAI_API.relative_to(ROOT)} is missing', file=sys.stderr)
        return 1

    api_code = strip_comments(ZAI_API.read_text(encoding='utf-8'))

    if HARDCODED_PREFIX.search(api_code):
        failures.append('ZaiAPI.swift: must not hardcode a versioned GLM prefix like hasPrefix("glm-5.')

    if 'func glmVersion' not in api_code:
        failures.append('ZaiAPI.swift: missing `func glmVersion` for adaptive GLM version parsing')

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1
    print('PASS: ZaiAPI parses GLM model versions adaptively without hardcoded version prefixes.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
