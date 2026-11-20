#!/usr/bin/env python3
"""Run XcodeGen and restore project.yml's options.knownRegions in project.pbxproj."""
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT_YML = ROOT / 'project.yml'
PBXPROJ = ROOT / 'Tivano.xcodeproj' / 'project.pbxproj'

KNOWN_REGIONS_RE = re.compile(
    r'^(?P<indent>[ \t]*)knownRegions = \(\n'
    r'(?P<body>(?:[ \t]+[^\n]*,\n)*)'
    r'(?P=indent)\);$',
    re.MULTILINE,
)


def _unquote_yaml_scalar(value):
    text = value.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ('"', "'"):
        return text[1:-1]
    if ' #' in text:
        text = text.split(' #', 1)[0].rstrip()
    return text


def project_known_regions(text):
    """Parse options.knownRegions from project.yml without a YAML dependency."""
    lines = text.splitlines()
    options_index = None
    for index, raw_line in enumerate(lines):
        line = raw_line.rstrip()
        if re.match(r'^options:\s*(?:#.*)?$', line):
            options_index = index
            break
    if options_index is None:
        raise ValueError('project.yml is missing top-level options: block')

    known_index = None
    for index in range(options_index + 1, len(lines)):
        line = lines[index].rstrip()
        stripped = line.lstrip(' ')
        if not stripped or stripped.startswith('#'):
            continue
        if len(line) == len(stripped):
            break
        if re.match(r'^  knownRegions:\s*(?:#.*)?$', line):
            known_index = index
            break
    if known_index is None:
        raise ValueError('project.yml options: block is missing knownRegions:')

    regions = []
    for index in range(known_index + 1, len(lines)):
        line = lines[index].rstrip()
        stripped = line.lstrip(' ')
        if not stripped or stripped.startswith('#'):
            continue
        indent = len(line) - len(stripped)
        if indent < 4:
            break
        match = re.match(r'^    -\s+(.+?)\s*$', line)
        if not match:
            raise ValueError(f'unexpected line in options.knownRegions: {line!r}')
        value = _unquote_yaml_scalar(match.group(1))
        if not value:
            raise ValueError('empty entry in options.knownRegions')
        regions.append(value)

    if not regions:
        raise ValueError('project.yml options.knownRegions list is empty')
    return regions


def format_pbxproj_region(region):
    """Quote a knownRegions entry the way Xcode does when needed."""
    if re.fullmatch(r'[A-Za-z0-9_.]+', region):
        return region
    escaped = region.replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'


def _find_known_regions_match(pbxproj_text):
    matches = list(KNOWN_REGIONS_RE.finditer(pbxproj_text))
    if len(matches) != 1:
        raise ValueError(
            f'expected exactly 1 knownRegions block in project.pbxproj, found {len(matches)}'
        )
    return matches[0]


def pbxproj_known_regions(text):
    """Parse the single knownRegions list from a project.pbxproj string."""
    match = _find_known_regions_match(text)
    regions = []
    for raw_line in match.group('body').splitlines():
        item = raw_line.strip()
        if not item:
            continue
        if item.endswith(','):
            item = item[:-1].rstrip()
        if len(item) >= 2 and item[0] == '"' and item[-1] == '"':
            item = item[1:-1].replace('\\"', '"').replace('\\\\', '\\')
        regions.append(item)
    return regions


def rewrite_known_regions(pbxproj_text, regions):
    """Replace the single knownRegions block in pbxproj_text with regions."""
    if not regions:
        raise ValueError('regions list must not be empty')
    match = _find_known_regions_match(pbxproj_text)
    indent = match.group('indent')
    body = match.group('body')
    entry_indent = None
    for line in body.splitlines():
        if line.strip():
            entry_indent = line[:len(line) - len(line.lstrip(' \t'))]
            break
    if entry_indent is None:
        entry_indent = indent + '\t'
    formatted_entries = ''.join(
        f'{entry_indent}{format_pbxproj_region(region)},\n'
        for region in regions
    )
    replacement = f'{indent}knownRegions = (\n{formatted_entries}{indent});'
    return pbxproj_text[:match.start()] + replacement + pbxproj_text[match.end():]


def main():
    if shutil.which('xcodegen') is None:
        sys.exit('xcodegen is not on PATH; install XcodeGen to generate Tivano.xcodeproj')
    try:
        subprocess.run(['xcodegen', 'generate', '--quiet'], cwd=ROOT, check=True)
    except FileNotFoundError:
        sys.exit('xcodegen is not on PATH; install XcodeGen to generate Tivano.xcodeproj')
    try:
        regions = project_known_regions(PROJECT_YML.read_text(encoding='utf-8'))
        pbxproj_text = PBXPROJ.read_text(encoding='utf-8')
        updated = rewrite_known_regions(pbxproj_text, regions)
    except (OSError, ValueError) as error:
        sys.exit(f'Failed to restore knownRegions: {error}')
    if updated != pbxproj_text:
        PBXPROJ.write_text(updated, encoding='utf-8')
    return 0


if __name__ == '__main__':
    sys.exit(main())
