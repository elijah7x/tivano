#!/usr/bin/env python3
"""Prepare an external, one-shot launchd checkout migration handoff."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid


class JobError(Exception):
    pass


LAUNCHCTL = Path("/bin/launchctl")
LABEL_PREFIX = "dev.tivano.checkout-migration."
BASE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
HANDSHAKE_SECONDS = 30


def physical(value, must_exist=False):
    path = Path(os.path.abspath(os.path.expanduser(str(value))))
    for part in (path, *path.parents):
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise JobError(f"Symlink is not allowed: {part}")
    if must_exist and not path.exists():
        raise JobError(f"Path does not exist: {path}")
    return path


def inside(path, root):
    return path == root or root in path.parents


def outside(path, roots):
    for root in roots:
        if inside(path, root) or inside(root, path):
            raise JobError(f"Unsafe overlapping paths: {path} and {root}")


def private(path, directory=False):
    path = physical(path, must_exist=True)
    info = path.stat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid != os.getuid():
        raise JobError(f"Not a user-owned {'directory' if directory else 'file'}: {path}")
    if info.st_mode & 0o077 or (not directory and info.st_nlink != 1):
        raise JobError(f"Not private or has extra hard links: {path}")
    return path


def digest(path):
    physical(path, must_exist=True)
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hash_stream(stream)


def hash_stream(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        result.update(block)
    return result.hexdigest()


def identity(path):
    path = physical(path, must_exist=True)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or not os.access(path, os.X_OK):
        raise JobError(f"Not an executable file: {path}")
    return {"path": str(path), "device": info.st_dev, "inode": info.st_ino,
            "size": info.st_size, "mtime_ns": info.st_mtime_ns, "sha256": digest(path)}


def atomic(path, data):
    if path.exists() or path.is_symlink():
        raise JobError(f"Refusing to overwrite: {path}")
    fd, temporary = tempfile.mkstemp(prefix=".prepare-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def read_json(path):
    private(path)
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise JobError(f"Expected a JSON object: {path}")
    return value


def execute(arguments, *, cwd, env=None, required=True):
    result = subprocess.run([str(arg) for arg in arguments], cwd=str(cwd),
                            env=env or {"PATH": BASE_PATH}, capture_output=True,
                            text=True, timeout=120)
    if required and result.returncode:
        raise JobError(f"Command failed ({result.returncode}): {shlex.join([str(a) for a in arguments])}\n"
                       f"{result.stderr.strip() or result.stdout.strip()}")
    return result


def environment(home, git):
    return {"HOME": str(home), "PATH": str(git.parent) + ":" + BASE_PATH,
            "LANG": "en_US.UTF-8", "PYTHONUNBUFFERED": "1"}


def worktrees(source, git, home):
    result = execute([git, "-C", source, "worktree", "list", "--porcelain", "-z"],
                     cwd=source, env=environment(home, git))
    roots = [physical(item[len("worktree "):], must_exist=True)
             for item in result.stdout.split("\0") if item.startswith("worktree ")]
    if not roots:
        raise JobError("Git returned no worktree paths")
    return roots


def protected(home, source, destination, trees):
    roots = [source, destination, *trees, home / ".tivano", home / ".tivano-dev",
             home / "Library/Application Support/Tivano",
             home / "Library/Application Support/Tivano Dev"]
    return roots + [root.resolve() for root in roots]


def plist_for(record, state):
    return {"Label": record["label"],
            "ProgramArguments": [record["python"]["path"],
                                 str(state / "runtime/consolidate_checkout.py"),
                                 "apply", "--state-dir", str(state), "--wait-seconds", "3600"],
            "WorkingDirectory": str(state), "RunAtLoad": True,
            "ProcessType": "Background", "Umask": 0o077,
            "StandardOutPath": str(state / "stdout.log"),
            "StandardErrorPath": str(state / "stderr.log"),
            "EnvironmentVariables": environment(Path(record["home"]), Path(record["git"]["path"]))}


def prepare(args):
    if sys.platform != "darwin" or os.getuid() == 0:
        raise JobError("Preparation requires a non-root macOS GUI user")
    source = physical(args.source, must_exist=True)
    destination = physical(args.destination)
    state = physical(args.state_dir)
    home = physical(args.home or Path.home(), must_exist=True)
    if state.exists():
        raise JobError(f"State directory must be new: {state}")
    parent = physical(state.parent, must_exist=True)
    for ancestor in (parent, *parent.parents):
        info = ancestor.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022 or info.st_uid not in (0, os.getuid()):
            raise JobError(f"Unsafe state parent: {ancestor}")
    git_name = shutil.which("git")
    if not git_name:
        raise JobError("Git executable not found")
    git = Path(git_name).resolve(strict=True)
    python = Path(sys.executable).resolve(strict=True)
    trees = worktrees(source, git, home)
    roots = protected(home, source, destination, trees)
    outside(state, roots)
    outside(python, roots)
    outside(git, roots)
    controller = physical(Path(__file__).absolute(), must_exist=True)
    worker = physical(controller.with_name("consolidate_checkout.py"), must_exist=True)
    if not controller.is_file() or not worker.is_file():
        raise JobError("Controller and worker must be regular files")
    python_id, git_id = identity(python), identity(git)
    # The worker owns creation of its plan; it receives a fresh, absent state path.
    execute([python, "-I", worker, "prepare", "--source", source,
             "--destination", destination, "--state-dir", state, "--home", home],
            cwd=parent, env=environment(home, git))
    physical(state, must_exist=True)
    if state.stat().st_uid != os.getuid() or not state.is_dir():
        raise JobError("Worker did not create a user-owned state directory")
    state.chmod(0o700)
    plan_path = physical(state / "plan.json", must_exist=True)
    if not plan_path.is_file() or plan_path.stat().st_uid != os.getuid() or plan_path.stat().st_nlink != 1:
        raise JobError("Worker plan is not a user-owned regular file")
    plan_path.chmod(0o600)
    plan = read_json(plan_path)
    validate_plan(plan, state, source, destination, home)
    for name in ("runtime", "runtime.json", "job.plist", "HANDOFF.md", "runtime.sha256",
                 "stdout.log", "stderr.log", "controller.lock", "migration-gate.lock", "arm-attempt.json", "progress.json"):
        if (state / name).exists() or (state / name).is_symlink():
            raise JobError(f"Unexpected existing material: {state / name}")
    runtime = state / "runtime"
    runtime.mkdir(mode=0o700)
    for original in (worker, controller):
        atomic(runtime / original.name, original.read_bytes())
    record = {"version": 1, "uid": os.getuid(), "state_dir": str(state),
              "state_device": state.stat().st_dev, "state_inode": state.stat().st_ino,
              "source": str(source), "destination": str(destination), "home": str(home),
              "label": LABEL_PREFIX + uuid.uuid4().hex,
              "python": python_id, "git": git_id, "files": {}}
    atomic(state / "job.plist", plistlib.dumps(plist_for(record, state), sort_keys=True))
    controller_command = shlex.join([str(python), str(runtime / controller.name)])
    rollback_command = shlex.join([str(python), str(runtime / worker.name), "rollback", "--state-dir", str(state)])
    handoff = f"""# Checkout migration handoff

Preparation alone does not register or start a job. Use:

    {controller_command} arm --state-dir {shlex.quote(str(state))}
    {controller_command} status --state-dir {shlex.quote(str(state))}

Only an explicit ARMED result confirms that launchd has started the external
worker and that its progress phase was waiting. Then actively close Tivano and
any other application or writer identified by the worker. This controller never
quits, kills or opens any application. Do not log out or reboot during migration:
the one-shot job belongs to this GUI login session, not a persistent system daemon.
The worker waits up to 3600 seconds, then performs its offline backup and migration.

Inspect {state / 'progress.json'} and the status command for the result.
Logs: {state / 'stdout.log'} and {state / 'stderr.log'}.
The prepared plan is {plan_path}. Files and backups are never automatically deleted.
After confirmed completion, manually open the original installed application.
Automatic restart and provider conversation resumption are not guaranteed.

On failure or an unconfirmed takeover, do not blindly reopen the application,
repeat arm, or run apply. Inspect the result and logs first. Only after the worker
is no longer running and offline recovery has been reviewed, invoke rollback with:

    {rollback_command}

To cancel while the worker is waiting, run the external controller with

    {controller_command} disarm --state-dir {shlex.quote(str(state))}

Cancellation shares a lock with the first backup transition. The controller waits
for the worker to acknowledge cancellation before removing the job. Cancellation
is refused once backup or migration has begun; never stop those phases manually. After completion the lead may remove only this
job's registration (not the GUI domain) with:

    /bin/launchctl bootout gui/{os.getuid()}/{record['label']}

No permanent LaunchAgent is installed. Runtime material is private to the current
user. Hashes detect accidental edits, not malicious replacement by that same user.
"""
    atomic(state / "HANDOFF.md", handoff.encode())
    for name in ("stdout.log", "stderr.log", "controller.lock", "migration-gate.lock"):
        atomic(state / name, b"")
    for relative in ("plan.json", "job.plist", "HANDOFF.md",
                     "runtime/consolidate_checkout.py", "runtime/consolidate_checkout_job.py"):
        record["files"][relative] = digest(state / relative)
    atomic(state / "runtime.json", json_bytes(record))
    atomic(state / "runtime.sha256", (digest(state / "runtime.json") + "\n").encode())
    print(f"PREPARED (not armed)\nState: {state}\nHandoff: {state / 'HANDOFF.md'}")


def validate_plan(plan, state, source, destination, home):
    if plan.get("version") != 1:
        raise JobError("Unsupported worker plan version")
    for key, expected in (("source", source), ("destination", destination),
                          ("state_dir", state), ("home", home)):
        if plan.get(key) != str(expected):
            raise JobError(f"Worker plan mismatch: {key}")
    for key in ("source_head", "source_branch", "git_common_dir", "preserved_main", "recovery_worktree"):
        if key not in plan:
            raise JobError(f"Worker plan lacks {key}")


def load(state):
    state = private(state, directory=True)
    private(state / "runtime", directory=True)
    seal = private(state / "runtime.sha256").read_text(encoding="ascii").strip()
    if digest(private(state / "runtime.json")) != seal:
        raise JobError("Runtime manifest hash mismatch")
    record = read_json(state / "runtime.json")
    if (record.get("version") != 1 or record.get("uid") != os.getuid()
            or record.get("state_dir") != str(state)
            or record.get("state_device") != state.stat().st_dev
            or record.get("state_inode") != state.stat().st_ino
            or not re.fullmatch(re.escape(LABEL_PREFIX) + r"[0-9a-f]{32}", record.get("label", ""))):
        raise JobError("Unknown state directory or mismatched runtime identity")
    expected_files = {"plan.json", "job.plist", "HANDOFF.md", "runtime/consolidate_checkout.py",
                      "runtime/consolidate_checkout_job.py"}
    if set(record.get("files", {})) != expected_files:
        raise JobError("Unknown runtime material list")
    for relative, expected in record["files"].items():
        if digest(private(state / relative)) != expected:
            raise JobError(f"Material hash mismatch: {relative}")
    for key in ("python", "git"):
        if identity(Path(record[key]["path"])) != record[key]:
            raise JobError(f"Executable identity changed: {key}")
    with (state / "job.plist").open("rb") as stream:
        if plistlib.load(stream) != plist_for(record, state):
            raise JobError("LaunchAgent definition does not match this job")
    validate_plan(read_json(state / "plan.json"), state, Path(record["source"]),
                  Path(record["destination"]), Path(record["home"]))
    for name in ("stdout.log", "stderr.log", "controller.lock", "migration-gate.lock"):
        private(state / name)
    return state, record


def target(record):
    return f"gui/{record['uid']}/{record['label']}"


def job_print(state, record):
    # launchctl documents print's exit status, not its human-readable layout.
    return execute([LAUNCHCTL, "print", target(record)], cwd=state, required=False)


def progress(state):
    path = state / "progress.json"
    if not path.exists() and not path.is_symlink():
        return None
    value = read_json(path)
    if not isinstance(value.get("phase"), str):
        raise JobError("Worker progress lacks a phase")
    return value


def arm(state, record):
    if (state / "arm-attempt.json").exists() or progress(state) is not None:
        raise JobError("This job has already been attempted; inspect status and logs, do not repeat arm")
    allowed = {"runtime", "runtime.json", "runtime.sha256", "job.plist", "HANDOFF.md",
               "plan.json", "stdout.log", "stderr.log", "controller.lock", "migration-gate.lock"}
    if {entry.name for entry in state.iterdir()} != allowed:
        raise JobError("Unexpected state directory contents; refusing to arm")
    if {entry.name for entry in (state / "runtime").iterdir()} != {
            "consolidate_checkout.py", "consolidate_checkout_job.py"}:
        raise JobError("Unexpected runtime directory contents; refusing to arm")
    home = physical(record["home"], must_exist=True)
    source = physical(record["source"], must_exist=True)
    destination = physical(record["destination"])
    outside(state, protected(home, source, destination,
                             worktrees(source, Path(record["git"]["path"]), home)))
    if job_print(state, record).returncode == 0:
        raise JobError("Job label is already registered; refusing to adopt or overwrite it")
    atomic(state / "arm-attempt.json", json_bytes({"label": record["label"], "time_ns": time.time_ns()}))
    execute([LAUNCHCTL, "bootstrap", f"gui/{record['uid']}", state / "job.plist"], cwd=state)
    result = job_print(state, record)
    if result.returncode:
        raise JobError(f"Takeover NOT confirmed: launchctl print failed: {result.stderr.strip()}")
    deadline = time.monotonic() + HANDSHAKE_SECONDS
    while time.monotonic() < deadline:
        current = progress(state)
        if current:
            if current["phase"] != "waiting":
                raise JobError(f"Takeover NOT confirmed: worker phase is {current['phase']!r}; inspect logs")
            pid = current.get("worker_pid")
            if not isinstance(pid, int) or pid <= 0:
                raise JobError("Takeover NOT confirmed: worker PID missing")
            try:
                os.kill(pid, 0)
            except OSError as error:
                raise JobError("Takeover NOT confirmed: worker is not alive") from error
            if job_print(state, record).returncode:
                raise JobError("Takeover NOT confirmed: job registration disappeared")
            print(f"ARMED: independent worker reported waiting\nJob: {target(record)}\n"
                  f"State: {state}\nClose applications only after reviewing HANDOFF.md.")
            return
        time.sleep(0.2)
    raise JobError("Takeover NOT confirmed: no waiting handshake within 30 seconds. "
                   "Do not close applications or repeat arm; inspect status and logs. "
                   "The registered job may still start later.")


def status(state, record):
    result = job_print(state, record)
    current = progress(state)
    print(f"Job: {target(record)}")
    print("Registration: present" if result.returncode == 0 else "Registration: unconfirmed")
    if result.returncode:
        raise JobError(f"launchctl print failed ({result.returncode}): {result.stderr.strip()}; "
                       f"progress phase: {current['phase'] if current else 'not reported'}; "
                       f"logs: {state / 'stdout.log'}, {state / 'stderr.log'}")
    print(f"Progress: {current['phase'] if current else 'not reported'}")
    print(f"Logs: {state / 'stdout.log'} ; {state / 'stderr.log'}")


def disarm(state, record):
    current = progress(state)
    if not current or current["phase"] != "waiting":
        raise JobError("Disarm refused: progress must be waiting with no migration side effects. "
                       "Completed jobs can be booted out separately after review.")
    with private(state / "migration-gate.lock").open("r+") as gate:
        try:
            fcntl.flock(gate, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise JobError("Disarm refused: worker is crossing the backup boundary") from error
        current = progress(state)
        if not current or current["phase"] != "waiting":
            raise JobError("Disarm refused: worker is no longer waiting")
        atomic(state / "cancel-request.json", json_bytes({"version": 1, "requested_at": time.time()}))
    deadline = time.monotonic() + HANDSHAKE_SECONDS
    while time.monotonic() < deadline:
        current = progress(state)
        if current and current["phase"] == "cancelled":
            execute([LAUNCHCTL, "bootout", target(record)], cwd=state)
            print("DISARMED: worker acknowledged cancellation before backup")
            return
        if current and current["phase"] != "waiting":
            raise JobError("Cancellation not confirmed; no stop command was sent")
        time.sleep(0.2)
    raise JobError("Cancellation request retained, but worker acknowledgement timed out; no stop command was sent")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preparation = commands.add_parser("prepare")
    preparation.add_argument("--source", required=True)
    preparation.add_argument("--destination", required=True)
    preparation.add_argument("--state-dir", required=True)
    preparation.add_argument("--home")
    for command in ("arm", "status", "disarm"):
        commands.add_parser(command).add_argument("--state-dir", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == "prepare":
            prepare(args)
        else:
            if sys.platform != "darwin" or os.getuid() == 0:
                raise JobError("Requires a non-root macOS GUI user")
            state, record = load(physical(args.state_dir, must_exist=True))
            with (state / "controller.lock").open("r+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                {"arm": arm, "status": status, "disarm": disarm}[args.command](state, record)
    except (JobError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        if args.command == "arm":
            print("NOT ARMED: do not close applications on the strength of this attempt. "
                  "Inspect status and logs; do not repeat arm.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
