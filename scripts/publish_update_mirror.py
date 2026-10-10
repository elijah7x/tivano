#!/usr/bin/env python3
"""Sync a verified canonical static feed and its DMG through a restricted SSH key.
No GitHub publication or release is performed. Run after the canonical feed is live.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

FEED = "https://elijah7x.github.io/tivano/updates.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="SSH alias with the mirror-only identity")
    parser.add_argument("--via", help="Optional SSH host that owns the mirror publishing identity")
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--feed", type=Path, help="Previously verified canonical manifest; otherwise fetch Pages")
    args = parser.parse_args()
    for alias in [args.host, args.via]:
        if alias is not None and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", alias):
            raise ValueError("Expected an SSH alias, not shell syntax")
    if args.feed:
        raw = args.feed.read_bytes()
    else:
        with urllib.request.urlopen(FEED, timeout=30) as response:
            raw = response.read(1_048_577)
    if len(raw) > 1_048_576:
        raise ValueError("Feed exceeds 1 MiB")
    feed = json.loads(raw)
    if feed.get("schema_version") != 1 or len(feed["releases"]) != 1:
        raise ValueError("Expected schema 1 with one stable release")
    release = feed["releases"][0]
    tag = release["tag_name"]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Expected stable vX.Y.Z")
    if release.get("draft") or release.get("prerelease") or not release.get("published_at"):
        raise ValueError("Release is not published stable")
    if len(release["assets"]) != 1:
        raise ValueError("Expected exactly one installer")
    asset = release["assets"][0]
    name = f"Tivano-{tag[1:]}.dmg"
    expected = f"https://github.com/elijah7x/tivano/releases/download/{tag}/{name}"
    image = args.dmg.read_bytes()
    if args.dmg.name != name or asset["name"] != name or asset["browser_download_url"] != expected:
        raise ValueError("Unexpected canonical DMG")
    if len(image) != asset["size"] or hashlib.sha256(image).hexdigest() != asset["sha256"]:
        raise ValueError("DMG checksum/size does not match the canonical feed")
    payload = json.dumps({"feed": feed, "dmg": base64.b64encode(image).decode()}).encode()
    if len(payload) > 67_108_864:
        raise ValueError("Publication exceeds the receiver's 64 MiB cap")
    command = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"]
    if args.via:
        # Alias characters were checked above; no installer data becomes shell syntax.
        command += [args.via, f"ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes {args.host}"]
    else:
        command += [args.host]
    subprocess.run(command, input=payload, check=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
