#!/usr/bin/env python3
"""Offline, backed-up separation of the former shared Tivano library.

Preview by default. --apply requires all old apps to be closed. Never launch apps.
"""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


def exists(path):
    return path.exists() or path.is_symlink()


def rewrite_json(root, replacements):
    """Rewrite only absolute path prefixes in JSON string values, not prose."""
    def transform(value):
        if isinstance(value, str):
            for old, new in replacements:
                if value == old or value.startswith(old + "/"):
                    return new + value[len(old):]
                if value == "file://" + old or value.startswith("file://" + old + "/"):
                    return "file://" + new + value[len("file://" + old):]
            return value
        if isinstance(value, list):
            return [transform(item) for item in value]
        if isinstance(value, dict):
            return {key: transform(item) for key, item in value.items()}
        return value

    for path in root.rglob("*.json"):
        if path.is_symlink():
            raise RuntimeError(f"Refusing linked JSON file: {path}")
        original = json.loads(path.read_text())
        updated = transform(original)
        if original != updated:
            temporary = path.with_name(path.name + ".separating")
            temporary.write_text(json.dumps(updated, ensure_ascii=False, indent=2) + "\n")
            os.chmod(temporary, path.stat().st_mode & 0o777)
            temporary.replace(path)


def running_apps():
    result = subprocess.run(["ps", "-axo", "comm="], check=True, capture_output=True, text=True)
    names = ("/Tivano.app/", "/Tivano Dev.app/", "/Droppy Code.app/", "/Droppy Code Dev.app/", "/Cody.app/")
    return [line.strip() for line in result.stdout.splitlines() if any(name in line for name in names)]


def separate(home, apply=False):
    support = home / "Library/Application Support"
    release = support / "Tivano"
    dev = support / "Tivano Dev"
    upstream = support / "Droppy Code"
    state = home / ".tivano"
    old_state = home / ".droppy-code"
    dev_state = home / ".tivano-dev"
    marker = support / ".tivano-separated-v2.json"
    pending = support / ".tivano-separation-in-progress.json"
    if pending.exists():
        raise RuntimeError(f"An earlier separation needs recovery; inspect {pending} and its backup before retrying.")
    if marker.exists():
        print("Separation already completed; no changes made.")
        return
    print("Production library:", release)
    print("Independent Dev library:", dev)
    print("Dev library, state and preferences will be archived, then reset.")
    print("Droppy Code receives a separate snapshot; its old Git worktrees belong to Tivano.")
    if not apply:
        print("Preview only. Quit all Tivano/Droppy apps, then run with --apply.")
        return
    active = running_apps()
    if active:
        raise RuntimeError("Quit all Tivano/Droppy apps first: " + ", ".join(active))
    support.mkdir(parents=True, exist_ok=True)
    with contextlib.ExitStack() as stack:
        # Use the old lock inodes; never delete them. This excludes old shared builds.
        for name in (".tivano-library.lock", ".tivano-migration.lock", ".tivano-release-library.lock", ".tivano-dev-library.lock"):
            handle = stack.enter_context((support / name).open("a+"))
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if running_apps():
            raise RuntimeError("An app started during preflight; close it before retrying.")
        if release.is_symlink():
            raise RuntimeError("Unexpected linked Tivano library; inspect it manually before separation.")
        if upstream.is_symlink() and upstream.resolve() != release.resolve():
            raise RuntimeError("Unexpected Droppy Code alias; refusing to modify it.")
        if state.is_symlink() and state.resolve() != old_state.resolve():
            raise RuntimeError("Unexpected Tivano state alias; refusing to modify it.")
        for path in (dev, dev_state, old_state):
            if path.is_symlink():
                raise RuntimeError(f"Unexpected alias: {path}")
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
        backup = support / "Tivano Backups" / ("separation-" + stamp)
        backup.mkdir(parents=True, mode=0o700)
        manifest = {}
        for index, path in enumerate((release, dev, upstream, state, old_state, dev_state)):
            if exists(path):
                destination = backup / f"{index}-{path.name}"
                shutil.copytree(path, destination, symlinks=True)
                manifest[str(path)] = {"backup": str(destination), "alias": os.readlink(path) if path.is_symlink() else None}
        (backup / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # Validate/rewrite a staged library before changing any live path.
        staged = backup / "prepared-Tivano"
        source = release if release.exists() else upstream
        if source.exists():
            shutil.copytree(source, staged, symlinks=True)
        else:
            staged.mkdir()
        for path in staged.rglob("*"):
            if path.is_symlink():
                raise RuntimeError(f"Library contains an alias requiring manual review: {path}")
        rewrite_json(staged, [(str(upstream), str(release)), (str(old_state), str(state))])
        preferences = backup / "Tivano-Dev-preferences.plist"
        exported = subprocess.run(["defaults", "export", "dev.tivano.Tivano.dev", str(preferences)], capture_output=True)
        if exported.returncode and (home / "Library/Preferences/dev.tivano.Tivano.dev.plist").exists():
            raise RuntimeError("Cannot back up Dev preferences; no live changes made.")
        # If a later step fails, backups and manifest remain available. Do not mark success.
        print("Backup:", backup)
        pending.write_text(json.dumps({"backup": str(backup)}, indent=2) + "\n")
        if state.is_symlink():
            state.unlink()
            old_state.rename(state)
            old_state.mkdir()
            # Git registers absolute worktree paths outside the worktree itself.
            for gitfile in (state / "worktrees").rglob(".git"):
                if gitfile.is_file():
                    subprocess.run(["git", "-C", str(gitfile.parent), "worktree", "repair", str(gitfile.parent)], check=True)
        elif not state.exists():
            state.mkdir()
        if upstream.is_symlink():
            upstream.unlink()
            # Restore Droppy's separate snapshot, not a new compatibility alias.
            shutil.copytree(backup / "0-Tivano", upstream, symlinks=True)
            rewrite_json(upstream, [(str(release), str(upstream))])
        if release.exists():
            release.rename(backup / "previous-live-Tivano")
        staged.rename(release)
        for path in (dev, dev_state):
            if path.exists():
                path.rename(backup / ("previous-live-" + path.name))
            path.mkdir()
        if exported.returncode == 0:
            subprocess.run(["defaults", "delete", "dev.tivano.Tivano.dev"], check=True)
        marker.write_text(json.dumps({"backup": str(backup), "version": 2}, indent=2) + "\n")
        pending.unlink()
        print("Separated. Production data stays in Tivano; Dev starts empty. No app launched.")
        print("Provider CLI logins and external project folders remain provider/user-owned.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Back up and separate offline data")
    args = parser.parse_args()
    try:
        separate(Path.home(), args.apply)
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Separation stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
