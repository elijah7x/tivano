#!/usr/bin/env python3
"""Forced SSH command for an unprivileged, mirror-only publisher.
Input: {"feed": <canonical GitHub feed>, "dmg": <base64 DMG>}.
No shell commands, arbitrary filenames, remote fetches or credentials.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path("/var/www/tivano")
PUBLIC = "https://elijah.ac.cn/tivano"
MAX_INPUT = 67_108_864


def version(tag):
    if not isinstance(tag, str) or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Expected stable vX.Y.Z")
    return tuple(map(int, tag[1:].split(".")))


def atomic_write(path, data):
    fd, temp = tempfile.mkstemp(prefix=".publish-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def publish(payload):
    feed = payload["feed"]
    if feed.get("schema_version") != 1 or len(feed["releases"]) != 1:
        raise ValueError("Expected schema 1 with one release")
    release = feed["releases"][0]
    tag = release["tag_name"]
    current = version(tag)
    if release.get("draft") or release.get("prerelease") or not release.get("published_at"):
        raise ValueError("Only published stable releases")
    name = f"Tivano-{tag[1:]}.dmg"
    if len(release["assets"]) != 1:
        raise ValueError("Expected exactly one installer")
    asset = release["assets"][0]
    canonical = f"https://github.com/elijah7x/tivano/releases/download/{tag}/{name}"
    if asset["name"] != name or asset["browser_download_url"] != canonical:
        raise ValueError("Unexpected canonical installer")
    image = base64.b64decode(payload["dmg"], validate=True)
    digest = hashlib.sha256(image).hexdigest()
    if not image or asset["size"] != len(image) or asset["sha256"] != digest:
        raise ValueError("Installer size/checksum mismatch")
    ROOT.mkdir(mode=0o755, exist_ok=True)
    with (ROOT / ".publish.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest = ROOT / "updates.json"
        if manifest.exists():
            previous = json.loads(manifest.read_text())
            if previous.get("schema_version") != 1:
                raise ValueError("Unknown existing schema")
            if any(version(r["tag_name"]) > current for r in previous["releases"]):
                raise ValueError("Refusing feed downgrade")
        directory = ROOT / "releases" / tag
        directory.mkdir(mode=0o755, parents=True, exist_ok=True)
        destination = directory / name
        if destination.exists():
            if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
                raise ValueError("Refusing to replace an immutable installer")
        else:
            atomic_write(destination, image)
        asset["browser_download_url"] = f"{PUBLIC}/releases/{tag}/{name}"
        data = (json.dumps(feed, ensure_ascii=False, indent=2) + "\n").encode()
        if len(data) > 1_048_576:
            raise ValueError("Feed too large")
        atomic_write(manifest, data)
        print(json.dumps({"tag": tag, "size": len(image), "sha256": digest}))


if __name__ == "__main__":
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            raise ValueError("Input exceeds 64 MiB")
        publish(json.loads(raw))
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit(str(error))
