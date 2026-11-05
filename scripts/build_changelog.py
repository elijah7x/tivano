#!/usr/bin/env python3
"""Extracts release sections from CHANGELOG.md.

Run: python3 scripts/build_changelog.py --section <version>
Prints the `## [<version>]` section with `###` headings promoted to `##`, which is
what scripts/publish_release.sh posts as release notes and the app's About page
reads into its cards. `### Thanks` bullets land outside the sections.

The website JSON builder that used to live here went away with the site.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"

RELEASE_RE = re.compile(r"^## \[(\d+(?:\.\d+)*|[0-9]+\.[0-9]+\.[0-9]+-preview\.[1-9][0-9]*)\](?: - (\d{4}-\d{2}-\d{2}))?\s*$")


def split_releases(text):
    releases = []
    current = None
    for line in text.splitlines():
        m = RELEASE_RE.match(line)
        if m:
            if current is not None:
                releases.append(current)
            current = {"version": m.group(1), "date": m.group(2), "lines": []}
            continue
        if current is not None:
            current["lines"].append(line)
    if current is not None:
        releases.append(current)
    return releases


def extract_section(version):
    text = CHANGELOG.read_text(encoding="utf-8")
    releases = split_releases(text)
    for rel in releases:
        if rel["version"] == version:
            lines = list(rel["lines"])
            while lines and not lines[0].strip():
                lines.pop(0)
            while lines and not lines[-1].strip():
                lines.pop()
            out = []
            for line in lines:
                if line.startswith("### "):
                    out.append("## " + line[4:])
                else:
                    out.append(line)
            return "\n".join(out) + "\n"
    return None


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--section":
        version = sys.argv[2]
        section = extract_section(version)
        if section is None:
            print(f"No ## [{version}] section in CHANGELOG.md", file=sys.stderr)
            return 1
        sys.stdout.write(section)
        return 0
    print("Usage: build_changelog.py --section <version>", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
