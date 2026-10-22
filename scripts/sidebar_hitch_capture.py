#!/usr/bin/env python3
"""Capture one existing process with xctrace; never launch or control the app.

Interface reference: `xcrun xctrace help record` and `xcrun xctrace help export`.
Use a separate output directory for each interaction capture and idle baseline.
The operator controls the UI and records click timestamps separately. Command
start timestamps precede attachment and are not the trace's recording zero.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time


def positive_integer(value):
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def timestamp():
    return {
        "utc": datetime.now(timezone.utc).isoformat(timespec="microseconds"),
        "monotonic_ns": time.monotonic_ns(),
    }


def save_manifest(output, manifest):
    temporary = output / "manifest.json.tmp"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output / "manifest.json")


def run_stage(name, command, output, manifest):
    stage = {
        "command": command,
        "stdout": f"{name}.stdout.log",
        "stderr": f"{name}.stderr.log",
        "started": timestamp(),
        "ended": None,
        "returncode": None,
        "status": "running",
    }
    manifest["stages"][name] = stage
    save_manifest(output, manifest)
    print(f"{name}: {shlex.join(command)}", flush=True)
    try:
        with (output / stage["stdout"]).open("xb") as stdout:
            with (output / stage["stderr"]).open("xb") as stderr:
                result = subprocess.run(
                    command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                    check=False,
                )
        stage["returncode"] = result.returncode
        stage["status"] = "succeeded" if result.returncode == 0 else "failed"
        return result.returncode
    except KeyboardInterrupt:
        stage["status"] = "interrupted"
        stage["error"] = "Interrupted; subprocess return code unavailable."
        return 130
    except OSError as error:
        stage["status"] = "failed"
        stage["error"] = str(error)
        return 1
    finally:
        stage["ended"] = timestamp()
        stage["elapsed_seconds"] = (
            stage["ended"]["monotonic_ns"] - stage["started"]["monotonic_ns"]
        ) / 1_000_000_000
        save_manifest(output, manifest)


def capture(args, output, manifest):
    trace = output / "sidebar.trace"
    toc = output / "toc.xml"
    result = run_stage("record", [
        "xcrun", "xctrace", "record",
        "--template", args.template,
        "--attach", str(args.pid),
        "--time-limit", f"{args.duration}s",
        "--output", str(trace),
    ], output, manifest)
    if result != 0:
        return result if result > 0 else 1
    if not trace.exists():
        manifest["error"] = "xctrace returned success but sidebar.trace is missing."
        return 1

    result = run_stage("export", [
        "xcrun", "xctrace", "export", "--input", str(trace),
        "--toc", "--output", str(toc),
    ], output, manifest)
    if result != 0:
        return result if result > 0 else 1
    if not toc.is_file() or toc.stat().st_size == 0:
        manifest["error"] = "xctrace returned success but toc.xml is missing or empty."
        return 1

    print("Read the recorded table inventory (schema names depend on Xcode):")
    print(shlex.join(["cat", str(toc)]))
    print("Export all recorded data tables, including available sampling tables:")
    print(shlex.join([
        "xcrun", "xctrace", "export", "--input", str(trace),
        "--xpath", "/trace-toc/run/data/table",
        "--output", str(output / "tables.xml"),
    ]))
    print("For a smaller export, select a run/table from toc.xml and narrow the XPath.")
    print("Inspect exported column definitions before interpreting values or time units.")
    print("Command start is not trace zero; reconcile trace timing with operator timestamps.")
    print("Hotspot percentages alone do not establish a cause or a frame duration.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=positive_integer, required=True,
                        help="explicit PID of the already-running target")
    parser.add_argument("--duration", type=positive_integer, default=15,
                        help="recording time limit in whole seconds (default: 15)")
    parser.add_argument("--output", type=Path, required=True,
                        help="new or empty local evidence directory; never overwritten")
    parser.add_argument("--template", choices=("Time Profiler", "Animation Hitches"),
                        default="Time Profiler")
    args = parser.parse_args()
    output = args.output.expanduser().absolute()
    try:
        if output.is_symlink():
            parser.error("output must not be a symbolic link")
        output.mkdir(parents=True, exist_ok=True)
        if any(output.iterdir()):
            parser.error(f"refusing nonempty output directory: {output}")
        # Exclusive creation prevents simultaneous captures from sharing a directory.
        with (output / "manifest.json").open("x", encoding="utf-8") as handle:
            handle.write("{}\n")
    except OSError as error:
        parser.error(str(error))

    manifest = {
        "pid": args.pid,
        "template": args.template,
        "duration_seconds": args.duration,
        "output": str(output),
        "started": timestamp(),
        "ended": None,
        "status": "running",
        "exit_status": None,
        "clock_note": "Command boundary clocks, not recording zero; monotonic_ns is local to this host.",
        "stages": {},
    }
    exit_status = 1
    try:
        save_manifest(output, manifest)
        exit_status = capture(args, output, manifest)
    except KeyboardInterrupt:
        exit_status = 130
        manifest["error"] = "Interrupted."
    except OSError as error:
        manifest["error"] = str(error)
    finally:
        manifest["ended"] = timestamp()
        manifest["exit_status"] = exit_status
        manifest["status"] = "succeeded" if exit_status == 0 else "failed"
        try:
            save_manifest(output, manifest)
        except OSError as error:
            print(f"Cannot finish manifest: {error}", file=sys.stderr)
            exit_status = 1
    print(f"Evidence retained: {output}", flush=True)
    if exit_status != 0:
        print("Capture/export failed; inspect manifest.json and stage logs. No retry performed.",
              file=sys.stderr)
    return exit_status


if __name__ == "__main__":
    sys.exit(main())
