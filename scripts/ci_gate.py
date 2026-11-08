#!/usr/bin/env python3
"""Require a passing build-host CI record for a local commit before release."""

import argparse
import json
import posixpath
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POLL_INTERVAL = 60
SSH_TIMEOUT = 60


def configuration():
    values = {}
    for key in ("tivano.ci.host", "tivano.ci.root", "tivano.ci.executor", "tivano.ci.label"):
        result = subprocess.run(
            ["git", "config", "--get", key], cwd=ROOT, capture_output=True, text=True
        )
        if result.returncode not in (0, 1):
            raise RuntimeError(f"Cannot read {key}: {result.stderr.strip()}")
        values[key] = result.stdout.strip() if result.returncode == 0 else ""
    missing = [key for key, value in values.items() if not value]
    if missing:
        raise RuntimeError(
            f"Missing CI configuration: {', '.join(missing)}. Set these repository values:\n"
            "  git config tivano.ci.host <ssh-alias>\n"
            "  git config tivano.ci.root <absolute-build-host-ci-checkout-path>\n"
            "  git config tivano.ci.executor <absolute-build-host-path-to-installed-thor_ci.py>\n"
            "  git config tivano.ci.label <build-host-launch-agent-label>"
        )
    host, root = values["tivano.ci.host"], values["tivano.ci.root"]
    executor, label = values["tivano.ci.executor"], values["tivano.ci.label"]
    if host.startswith("-") or any(character.isspace() for character in host):
        raise RuntimeError("tivano.ci.host must be an SSH alias, not SSH options.")
    if not posixpath.isabs(root) or not posixpath.isabs(executor):
        raise RuntimeError("tivano.ci.root and tivano.ci.executor must be absolute paths on the build host.")
    # The executor lives outside the checkout it replaces on every run.
    if posixpath.normpath(executor).startswith(posixpath.normpath(root) + "/"):
        raise RuntimeError("tivano.ci.executor must be installed outside tivano.ci.root.")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
        raise RuntimeError("tivano.ci.label must be a launch agent label.")
    return host, root, executor, label


def resolve_commit(rev):
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--end-of-options", f"{rev}^{{commit}}"],
        cwd=ROOT, capture_output=True, text=True,
    )
    sha = result.stdout.strip()
    if result.returncode or not re.fullmatch(r"[0-9a-f]{40}", sha):
        detail = result.stderr.strip() or "expected a 40-character commit SHA"
        raise RuntimeError(f"Cannot resolve {rev!r}: {detail}")
    return sha


def remote(host, command, timeout=SSH_TIMEOUT):
    try:
        result = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"SSH to {host} timed out after {timeout:g} seconds.") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "no error output"
        raise RuntimeError(f"SSH to {host} failed ({result.returncode}): {detail}")
    return result.stdout


def executor_command(config, *arguments):
    host, root, executor, label = config
    return f"TIVANO_CI_REPO={shlex.quote(root)} " + " ".join(
        shlex.quote(part) for part in ("/usr/bin/python3", executor, *arguments))


def remote_status(config, sha, timeout=SSH_TIMEOUT):
    return remote(config[0], executor_command(config, "status", sha), timeout)


def kick(config, sha, timeout=SSH_TIMEOUT):
    host, root, executor, label = config
    # Queue the exact commit, then start the launch agent so the run gets its session and PATH.
    remote(host, executor_command(config, "request", sha)
           + f" && launchctl kickstart gui/$(id -u)/{label}", timeout)
    print(f"Build-host CI requested {sha[:12]} on {host}.", flush=True)


def parse_status(raw, sha):
    try:
        record = json.loads(raw)
    except ValueError as error:
        raise RuntimeError(f"Build-host status is not valid JSON: {error}") from error
    if not isinstance(record, dict):
        raise RuntimeError("Build-host status must be a JSON object.")
    if record.get("sha") != sha:
        raise RuntimeError(f"Build-host status SHA does not match {sha}: {record.get('sha')!r}")
    if record.get("state") not in ("pass", "fail", "running", "missing"):
        raise RuntimeError(f"Unknown build-host CI state: {record.get('state')!r}")
    if "failed" in record and not isinstance(record["failed"], list):
        raise RuntimeError("Build-host status 'failed' must be a list.")
    return record


def report_status(record, sha):
    short = sha[:12]
    state = record["state"]
    if state == "pass":
        print(f"Build-host CI passed for {short}; finished_at: {record.get('finished_at', 'not reported')}.", flush=True)
    elif state == "fail":
        print(f"Build-host CI failed for {short}.", file=sys.stderr, flush=True)
        for failed in record.get("failed", []):
            print(f"  Failed: {failed}", file=sys.stderr, flush=True)
        for key in ("reason", "artifacts"):
            if key in record:
                print(f"  {key}: {record[key]}", file=sys.stderr, flush=True)
    elif state == "running":
        print(f"Build-host CI is still running for {short}.", flush=True)
    else:
        print(
            f"The build host has not checked {short}; run python3 scripts/ci_gate.py kick to trigger it.",
            flush=True,
        )


def check(config, sha, wait, wait_timeout):
    deadline = time.monotonic() + wait_timeout if wait else None
    kicked = False

    def request_timeout():
        if deadline is None:
            return SSH_TIMEOUT
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f"Timed out after {wait_timeout} seconds waiting for build-host CI for {sha[:12]}.")
        return min(SSH_TIMEOUT, remaining)

    while True:
        record = parse_status(remote_status(config, sha, request_timeout()), sha)
        report_status(record, sha)
        state = record["state"]
        if state == "pass":
            return 0
        if state == "fail" or not wait:
            return 1
        if state == "missing" and not kicked:
            kick(config, sha, request_timeout())
            kicked = True
        time.sleep(min(POLL_INTERVAL, request_timeout()))


def positive_seconds(value):
    try:
        seconds = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive number of seconds") from error
    if seconds <= 0:
        raise argparse.ArgumentTypeError("must be a positive number of seconds")
    return seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check_parser = commands.add_parser("check", help="Require a passing CI record")
    check_parser.add_argument("rev", nargs="?", default="dev")
    check_parser.add_argument("--wait", action="store_true", help="Wait for running or missing CI")
    check_parser.add_argument("--wait-timeout", type=positive_seconds, default=10800, metavar="SECONDS")
    status_parser = commands.add_parser("status", help="Print the raw remote status JSON")
    status_parser.add_argument("rev", nargs="?", default="dev")
    kick_parser = commands.add_parser("kick", help="Queue a commit on the build host and start its CI agent")
    kick_parser.add_argument("rev", nargs="?", default="dev")
    args = parser.parse_args()
    try:
        config = configuration()
        sha = resolve_commit(args.rev)
        if args.command == "kick":
            kick(config, sha)
            return 0
        if args.command == "status":
            sys.stdout.write(remote_status(config, sha))
            return 0
        return check(config, sha, args.wait, args.wait_timeout)
    except (OSError, RuntimeError, UnicodeError) as error:
        print(f"CI gate: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("CI gate: interrupted.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
