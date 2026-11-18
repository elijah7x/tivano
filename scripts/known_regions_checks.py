#!/usr/bin/env python3
"""Offline guard: project.yml, project.pbxproj, and Localizable.xcstrings agree on knownRegions."""
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT / 'scripts'
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from xcodegen_generate import (
    KNOWN_REGIONS_RE,
    pbxproj_known_regions,
    project_known_regions,
    rewrite_known_regions,
)

PROJECT_YML = ROOT / 'project.yml'
PBXPROJ = ROOT / 'Tivano.xcodeproj/project.pbxproj'
CATALOG = ROOT / 'Tivano/Resources/Localizable.xcstrings'


def main():
    for path in (PROJECT_YML, PBXPROJ, CATALOG):
        if not path.is_file():
            print(f'FAIL: {path.relative_to(ROOT)} is missing', file=sys.stderr)
            return 1

    failures = []
    try:
        yml_regions = project_known_regions(PROJECT_YML.read_text(encoding='utf-8'))
    except ValueError as error:
        failures.append(f'project.yml: {error}')
        yml_regions = None

    pbxproj_text = PBXPROJ.read_text(encoding='utf-8')
    try:
        pbx_regions = pbxproj_known_regions(pbxproj_text)
    except ValueError as error:
        failures.append(f'project.pbxproj: {error}')
        pbx_regions = None

    if yml_regions is not None and pbx_regions is not None and yml_regions != pbx_regions:
        failures.append(
            f'knownRegions mismatch: project.yml has {yml_regions!r}, '
            f'project.pbxproj has {pbx_regions!r}'
        )

    try:
        catalog = json.loads(CATALOG.read_text(encoding='utf-8'))
    except ValueError as error:
        failures.append(f'Localizable.xcstrings is not valid JSON: {error}')
        catalog = None

    if isinstance(catalog, dict) and yml_regions is not None:
        source_language = catalog.get('sourceLanguage')
        strings = catalog.get('strings')
        if not isinstance(source_language, str) or not source_language:
            failures.append('Localizable.xcstrings is missing sourceLanguage')
        if not isinstance(strings, dict) or not strings:
            failures.append('Localizable.xcstrings has no "strings" entries')
        if isinstance(source_language, str) and source_language and isinstance(strings, dict) and strings:
            catalog_languages = {source_language}
            for entry in strings.values():
                if isinstance(entry, dict):
                    localizations = entry.get('localizations')
                    if isinstance(localizations, dict):
                        catalog_languages.update(localizations.keys())
            missing_languages = sorted(catalog_languages - set(yml_regions))
            if missing_languages:
                failures.append(
                    'project.yml options.knownRegions is missing catalog language(s): '
                    + ', '.join(missing_languages)
                )

    if yml_regions is not None:
        committed_match = KNOWN_REGIONS_RE.search(pbxproj_text)
        if committed_match is None:
            failures.append('project.pbxproj has no knownRegions block to compare against')
        else:
            committed_block = committed_match.group(0)
            fragment = (
                '\t\t\tdevelopmentRegion = en;\n'
                '\t\t\tknownRegions = (\n'
                '\t\t\t\tBase,\n'
                '\t\t\t\ten,\n'
                '\t\t\t);\n'
                '\t\t\tmainGroup = 76B56C591C26030E8DC61439;\n'
            )
            rewritten = rewrite_known_regions(fragment, yml_regions)
            rewritten_match = KNOWN_REGIONS_RE.search(rewritten)
            if rewritten_match is None or rewritten_match.group(0) != committed_block:
                failures.append(
                    'rewrite_known_regions on a Base/en fragment did not produce the committed block'
                )

        try:
            rewrite_known_regions('\t\t\tdevelopmentRegion = en;\n', yml_regions)
        except ValueError:
            pass
        else:
            failures.append(
                'rewrite_known_regions did not raise ValueError when knownRegions block is missing'
            )

    if failures:
        for failure in failures:
            print(f'FAIL: {failure}', file=sys.stderr)
        return 1

    print(
        f'PASS: knownRegions match across project.yml, project.pbxproj, and Localizable.xcstrings '
        f'({len(yml_regions)} regions).'
    )
    return 0


if __name__ == '__main__':
    sys.exit(main())
