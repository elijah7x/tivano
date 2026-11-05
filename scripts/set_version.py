#!/usr/bin/env python3
"""Set an edition's version, or explicitly let Release catch up to Dev."""
import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("edition", choices=["dev", "release"])
parser.add_argument("version", help="Numeric x.y.z, or 'catch-up-dev' for release")
args = parser.parse_args()
path = ROOT / "config" / f"{args.edition}.xcconfig"
version = args.version
if version == "catch-up-dev":
    if args.edition != "release":
        parser.error("Only Release may catch up to Dev")
    version = re.search(r"^MARKETING_VERSION\s*=\s*(\d+\.\d+\.\d+)\s*$", (ROOT / "config/dev.xcconfig").read_text(), re.M)[1]
preview = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+)-preview\.[1-9][0-9]*", version)
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) and not (args.edition == "release" and preview):
    parser.error("Version must be numeric x.y.z; the app adds Dev's prefix")
numeric = preview[1] if preview else version
full = version if preview else "$(MARKETING_VERSION)"
text = path.read_text()
build = int(re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*(\d+)\s*$", text, re.M)[1]) + 1
text = re.sub(r"^MARKETING_VERSION\s*=.*$", f"MARKETING_VERSION = {numeric}", text, flags=re.M)
text = re.sub(r"^CURRENT_PROJECT_VERSION\s*=.*$", f"CURRENT_PROJECT_VERSION = {build}", text, flags=re.M)
if re.search(r"^TIVANO_RELEASE_VERSION\s*=", text, re.M):
    text = re.sub(r"^TIVANO_RELEASE_VERSION\s*=.*$", f"TIVANO_RELEASE_VERSION = {full}", text, flags=re.M)
else:
    text = re.sub(r"^(MARKETING_VERSION[^\n]*)$", rf"\1\nTIVANO_RELEASE_VERSION = {full}", text, flags=re.M)
path.write_text(text)
print(f"{args.edition}: {'dev-' if args.edition == 'dev' else ''}{version} (build {build})")
