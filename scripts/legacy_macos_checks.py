#!/usr/bin/env python3
"""Offline guard: macOS 15.0 deployment target and ChromeMaterial wrappers for macOS 26+ glass APIs."""
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
PROJECT_YML = ROOT / 'project.yml'
PBXPROJ = ROOT / 'Tivano.xcodeproj/project.pbxproj'
TIVANO_DIR = ROOT / 'Tivano'
CHROME_MATERIAL = ROOT / 'Tivano/UI/Chrome/ChromeMaterial.swift'
CHROME_MATERIAL_REL = 'Tivano/UI/Chrome/ChromeMaterial.swift'

FORBIDDEN_GLASS_PATTERNS = (
    ('.glassEffect(', re.compile(r'\.glassEffect\s*\(')),
    ('GlassEffectContainer(', re.compile(r'(?<!Chrome)GlassEffectContainer\s*\(')),
    ('.buttonStyle(.glass)', re.compile(r'\.buttonStyle\(\s*\.glass\s*\)')),
    ('.buttonStyle(.glassProminent)', re.compile(r'\.buttonStyle\(\s*\.glassProminent\s*\)')),
    ('.glassEffectID(', re.compile(r'\.glassEffectID\s*\(')),
    ('.glassEffectUnion(', re.compile(r'\.glassEffectUnion\s*\(')),
    ('.glassEffectTransition(', re.compile(r'\.glassEffectTransition\s*\(')),
)


def _strip_yaml_comment(value):
    in_single = False
    in_double = False
    escaped = False
    for index, ch in enumerate(value):
        if in_double:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == '"':
                in_double = False
        elif in_single:
            if ch == "'":
                in_single = False
        else:
            if ch == '"':
                in_double = True
            elif ch == "'":
                in_single = True
            elif ch == '#' and (index == 0 or value[index - 1].isspace()):
                return value[:index].strip()
    return value.strip()


def _find_block_key_value(lines, parent_pattern, child_pattern, target_pattern):
    """Locate `parent -> child -> target` in an indented YAML file without external deps."""
    parent_index = None
    for index, raw_line in enumerate(lines):
        if re.match(parent_pattern, raw_line.rstrip()):
            parent_index = index
            break
    if parent_index is None:
        return None, 'missing_parent'

    child_index = None
    child_indent = None
    for index in range(parent_index + 1, len(lines)):
        line = lines[index].rstrip()
        stripped = line.lstrip(' ')
        if not stripped or stripped.startswith('#'):
            continue
        if len(line) == len(stripped):
            break
        match = re.match(child_pattern, line)
        if match:
            child_index = index
            child_indent = len(match.group('indent'))
            break
    if child_index is None:
        return None, 'missing_child'

    for index in range(child_index + 1, len(lines)):
        line = lines[index].rstrip()
        stripped = line.lstrip(' ')
        if not stripped or stripped.startswith('#'):
            continue
        indent = len(line) - len(stripped)
        if indent <= child_indent:
            break
        match = re.match(target_pattern, line)
        if match:
            return _strip_yaml_comment(match.group('val')), 'ok'

    return None, 'missing_target'


def check_project_yml(text):
    failures = []
    lines = text.splitlines()

    macos_target, status = _find_block_key_value(
        lines,
        r'^options:\s*(?:#.*)?$',
        r'^(?P<indent> +)deploymentTarget:\s*(?:#.*)?$',
        r'^ +macOS:\s*(?P<val>.*)$',
    )
    if status == 'missing_parent':
        failures.append('project.yml is missing top-level options: block')
    elif status == 'missing_child':
        failures.append('project.yml options: block is missing deploymentTarget:')
    elif status == 'missing_target':
        failures.append('project.yml options.deploymentTarget is missing macOS: "15.0"')
    elif macos_target != '"15.0"':
        failures.append(
            f'project.yml options.deploymentTarget.macOS must be "15.0", got {macos_target!r}'
        )

    base_target, status = _find_block_key_value(
        lines,
        r'^settings:\s*(?:#.*)?$',
        r'^(?P<indent> +)base:\s*(?:#.*)?$',
        r'^ +MACOSX_DEPLOYMENT_TARGET:\s*(?P<val>.*)$',
    )
    if status == 'missing_parent':
        failures.append('project.yml is missing top-level settings: block')
    elif status == 'missing_child':
        failures.append('project.yml settings: block is missing base:')
    elif status == 'missing_target':
        failures.append('project.yml settings.base is missing MACOSX_DEPLOYMENT_TARGET: "15.0"')
    elif base_target != '"15.0"':
        failures.append(
            f'project.yml settings.base.MACOSX_DEPLOYMENT_TARGET must be "15.0", got {base_target!r}'
        )

    for line_no, raw_line in enumerate(lines, 1):
        match = re.match(r'^\s*MACOSX_DEPLOYMENT_TARGET:\s*(?P<val>.*)$', raw_line)
        if match:
            value = _strip_yaml_comment(match.group('val'))
            if value != '"15.0"':
                failures.append(
                    f'project.yml:{line_no}: MACOSX_DEPLOYMENT_TARGET must be "15.0", got {value!r}'
                )

    return failures


def check_pbxproj(text):
    failures = []
    target_count = 0
    for line_no, raw_line in enumerate(text.splitlines(), 1):
        if re.search(r'\bMACOSX_DEPLOYMENT_TARGET\s*=', raw_line):
            target_count += 1
            if not re.match(r'^\s*MACOSX_DEPLOYMENT_TARGET\s*=\s*15\.0;\s*$', raw_line):
                failures.append(
                    f'project.pbxproj:{line_no}: expected MACOSX_DEPLOYMENT_TARGET = 15.0;, '
                    f'got {raw_line.strip()!r}'
                )
    if target_count == 0:
        failures.append('project.pbxproj has no MACOSX_DEPLOYMENT_TARGET = lines')
    return failures, target_count


def _strip_line_comment(line):
    in_string = False
    escaped = False
    index = 0
    length = len(line)
    while index < length:
        ch = line[index]
        if in_string:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == '/' and index + 1 < length and line[index + 1] == '/':
                return line[:index]
        index += 1
    return line


def check_swift_glass_uses():
    if not TIVANO_DIR.is_dir():
        return ['Tivano/ directory is missing'], 0

    swift_files = sorted(TIVANO_DIR.rglob('*.swift'))
    if not swift_files:
        return ['no *.swift files found under Tivano/'], 0

    failures = []
    scanned = 0
    for path in swift_files:
        relative = path.relative_to(ROOT).as_posix()
        if relative == CHROME_MATERIAL_REL:
            continue
        scanned += 1
        text = path.read_text(encoding='utf-8')
        for line_no, raw_line in enumerate(text.splitlines(), 1):
            code = _strip_line_comment(raw_line)
            if not code:
                continue
            for label, pattern in FORBIDDEN_GLASS_PATTERNS:
                if pattern.search(code):
                    failures.append(
                        f'{relative}:{line_no}: raw macOS 26+ glass API {label} '
                        '(use ChromeMaterial wrappers)'
                    )
    return failures, scanned


def check_chrome_material():
    if not CHROME_MATERIAL.is_file():
        return [f'{CHROME_MATERIAL_REL} is missing']
    text = CHROME_MATERIAL.read_text(encoding='utf-8')
    if 'if #available(macOS 26.0, *)' not in text:
        return [f'{CHROME_MATERIAL_REL} is missing `if #available(macOS 26.0, *)`']
    return []


def main():
    failures = []

    if not PROJECT_YML.is_file():
        failures.append('project.yml is missing')
    else:
        failures.extend(check_project_yml(PROJECT_YML.read_text(encoding='utf-8')))

    pbx_count = 0
    if not PBXPROJ.is_file():
        failures.append('Tivano.xcodeproj/project.pbxproj is missing')
    else:
        pbx_failures, pbx_count = check_pbxproj(PBXPROJ.read_text(encoding='utf-8'))
        failures.extend(pbx_failures)

    swift_failures, scanned = check_swift_glass_uses()
    failures.extend(swift_failures)

    failures.extend(check_chrome_material())

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1

    print(
        f'PASS: macOS 15.0 deployment target verified ({pbx_count} pbxproj entries), '
        f'ChromeMaterial availability guard present, and no raw glass APIs in {scanned} Swift files.'
    )
    return 0


if __name__ == '__main__':
    sys.exit(main())
