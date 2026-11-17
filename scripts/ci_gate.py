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
MAX_CONSECUTIVE_SSH_FAILURES = 5


class SSHError(RuntimeError):
    """Raised when an SSH command to the build host fails or times out."""


def format_elapsed(seconds):
    total = max(0, int(seconds))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}h{minutes:02d}m{secs:02d}s"
    if minutes:
        return f"{minutes}m{secs:02d}s"
    return f"{secs}s"


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
        raise SSHError(f"SSH to {host} timed out after {timeout:g} seconds.") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "no error output"
        raise SSHError(f"SSH to {host} failed ({result.returncode}): {detail}")
    return result.stdout


def executor_command(config, *arguments):
    host, root, executor, label = config
    return f"TIVANO_CI_REPO={shlex.quote(root)} " + " ".join(
        shlex.quote(part) for part in ("/usr/bin/python3", executor, *arguments))


def remote_status(config, sha, timeout=SSH_TIMEOUT):
    return remote(config[0], executor_command(config, "status", sha), timeout)


def queue_and_kick(config, sha, only=None, timeout=SSH_TIMEOUT):
    host, root, executor, label = config
    # Queue the exact commit, then start the launch agent so the run gets its session and PATH.
    args = ["request", sha]
    if only is not None:
        args.extend(["--only", only])
    output = remote(
        host,
        executor_command(config, *args) + f" && launchctl kickstart gui/$(id -u)/{label}",
        timeout,
    )
    target = f"{sha[:12]} (--only {only})" if only else sha[:12]
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    info = None
    if lines:
        try:
            parsed = json.loads(lines[-1])
            if isinstance(parsed, dict) and "busy" in parsed:
                info = parsed
        except ValueError:
            pass
    if info is not None:
        if info.get("busy"):
            running = info.get("running_sha")
            current = f" (running {running[:12]})" if isinstance(running, str) and running else ""
            print(f"Build-host CI on {host} is busy{current}; queued {target} behind the current run.", flush=True)
        else:
            print(f"Build-host CI on {host} was idle; started {target} via {label}.", flush=True)
    else:
        print(f"Build-host CI requested {target} on {host}.", flush=True)


def kick(config, sha, timeout=SSH_TIMEOUT):
    queue_and_kick(config, sha, timeout=timeout)


def rerun(config, sha, only, timeout=SSH_TIMEOUT):
    queue_and_kick(config, sha, only=only, timeout=timeout)


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
    if "pending" in record and not isinstance(record["pending"], dict):
        raise RuntimeError("Build-host status 'pending' must be an object.")
    if "latest_error" in record and not isinstance(record["latest_error"], dict):
        raise RuntimeError("Build-host status 'latest_error' must be an object.")
    return record


def print_latest_error(record, elapsed=None):
    err = record.get("latest_error")
    if not err:
        return
    when = err.get("time") or "unknown time"
    message = err.get("message") or "unknown error"
    elapsed_suffix = f" [elapsed {format_elapsed(elapsed)}]" if elapsed is not None else ""
    print(f"  Latest CI error ({when}){elapsed_suffix}: {message}", file=sys.stderr, flush=True)


def report_status(record, sha, elapsed=None):
    short = sha[:12]
    state = record["state"]
    elapsed_suffix = f" (elapsed {format_elapsed(elapsed)})" if elapsed is not None else ""
    if state == "pass":
        reused = f", reused_from: {record['reused_from']}" if record.get("reused_from") else ""
        print(
            f"Build-host CI passed for {short}; finished_at: {record.get('finished_at', 'not reported')}{reused}{elapsed_suffix}.",
            flush=True,
        )
    elif state == "fail":
        print(f"Build-host CI failed for {short}{elapsed_suffix}.", file=sys.stderr, flush=True)
        for failed in record.get("failed", []):
            print(f"  Failed: {failed}", file=sys.stderr, flush=True)
        for key in ("reason", "artifacts"):
            if key in record:
                print(f"  {key}: {record[key]}", file=sys.stderr, flush=True)
    elif state == "running":
        print(f"Build-host CI is still running for {short}{elapsed_suffix}.", flush=True)
    else:
        print(
            f"The build host has not checked {short}{elapsed_suffix}; run python3 scripts/ci_gate.py kick to trigger it.",
            flush=True,
        )
    print_latest_error(record, elapsed=elapsed)


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

    if not wait:
        record = parse_status(remote_status(config, sha, request_timeout()), sha)
        report_status(record, sha)
        return 0 if record["state"] == "pass" else 1

    start_time = time.monotonic()
    ssh_failures = 0
    last_state = None
    last_error_key = None

    while True:
        try:
            record = parse_status(remote_status(config, sha, request_timeout()), sha)
            ssh_failures = 0
            elapsed = time.monotonic() - start_time
            state = record["state"]
            # A failed record with a queued rerun is not final: wait for that attempt.
            if state == "fail" and record.get("pending") is not None:
                state = "fail-pending"
            err = record.get("latest_error") or {}
            error_key = (err.get("time"), err.get("message")) if err else None
            if state != last_state:
                if state == "fail-pending":
                    only = record["pending"].get("only")
                    target = f" --only {','.join(only)}" if only else ""
                    print(f"Build-host CI has a queued attempt{target} for {sha[:12]} after a failure "
                          f"(elapsed {format_elapsed(elapsed)}); waiting for it.", flush=True)
                else:
                    report_status(record, sha, elapsed=elapsed)
                last_state = state
                last_error_key = error_key
            elif error_key != last_error_key:
                if err:
                    print_latest_error(record, elapsed=elapsed)
                last_error_key = error_key
            if state == "pass":
                return 0
            if state == "fail":
                return 1
            if state == "missing" and not kicked:
                kick(config, sha, request_timeout())
                kicked = True
        except SSHError as error:
            ssh_failures += 1
            elapsed = time.monotonic() - start_time
            print(
                f"CI gate: SSH failure {ssh_failures}/{MAX_CONSECUTIVE_SSH_FAILURES} after {format_elapsed(elapsed)}: {error}",
                file=sys.stderr,
                flush=True,
            )
            if ssh_failures > MAX_CONSECUTIVE_SSH_FAILURES:
                raise
        time.sleep(min(POLL_INTERVAL, request_timeout()))


def positive_seconds(value):
    try:
        seconds = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive number of seconds") from error
    if seconds <= 0:
        raise argparse.ArgumentTypeError("must be a positive number of seconds")
    return seconds


def normalize_only(value):
    parts = [part.strip() for part in value.split(",")]
    if not parts or any(not part for part in parts):
        raise RuntimeError("--only must be a comma-separated list of check names.")
    return ",".join(parts)


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
    rerun_parser = commands.add_parser("rerun", help="Rerun specific checks on a failed commit whose build passed")
    rerun_parser.add_argument("rev", nargs="?", default="dev")
    rerun_parser.add_argument("--only", required=True, help="Comma-separated check names to rerun")
    args = parser.parse_args()
    try:
        config = configuration()
        sha = resolve_commit(args.rev)
        if args.command == "kick":
            kick(config, sha)
            return 0
        if args.command == "rerun":
            rerun(config, sha, normalize_only(args.only))
            return 0
        if args.command == "status":
            raw = remote_status(config, sha)
            sys.stdout.write(raw)
            record = parse_status(raw, sha)
            print_latest_error(record)
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
