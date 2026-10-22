#!/usr/bin/env python3
"""Offline, backed-up consolidation of a source checkout and its main worktree.

prepare writes only a plan. apply/rollback never stop or start applications.
All backups, the preserved main checkout and recovered work remain in STATE.
"""
import argparse
import contextlib
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time


class Stopped(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Stopped(message)


def present(path):
    return os.path.lexists(path)


def plain(path):
    path = Path(os.path.abspath(os.path.expanduser(str(path))))
    require(path == path.resolve(), f"Linked path requires manual review: {path}")
    return path


def within(path, root):
    return path == root or root in path.parents


def overlaps(a, b):
    return within(a, b) or within(b, a)


def identity(path):
    info = path.stat()
    return [info.st_dev, info.st_ino]


def atomic_bytes(path, data, mode=0o600):
    require(not path.is_symlink(), f"Linked file: {path}")
    fd, temporary = tempfile.mkstemp(prefix=".consolidating-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode())


def read_json(path):
    require(path.is_file() and not path.is_symlink(), f"Missing or linked JSON: {path}")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"Duplicate JSON key in {path}")
            result[key] = value
        return result
    return json.loads(path.read_bytes(), object_pairs_hook=unique)


def command(args, cwd=None, data=None, *, umask=-1):
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("GIT_"):
            del env[key]
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    result = subprocess.run(args, cwd=cwd or "/", input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env, umask=umask)
    # Git stderr can contain filenames, diffs or credentials; retain no command output in logs.
    require(result.returncode == 0, f"Subprocess failed ({Path(args[0]).name}, exit {result.returncode}); inspect phase and recovery.json")
    return result.stdout


def git(root, *args):
    # launchd keeps runtime material private, but Git must recreate normal source
    # permissions. Exact original modes are restored separately after stash apply.
    # git diff otherwise refreshes cached stat information even with
    # GIT_OPTIONAL_LOCKS=0, invalidating the frozen Git metadata checkpoint.
    # https://git-scm.com/docs/git-config#Documentation/git-config.txt-diffautoRefreshIndex
    return command(["git", "-c", "diff.autoRefreshIndex=false", "-C", str(root), *args], umask=0o022)


def text_git(root, *args):
    return git(root, *args).decode().strip()


def worktrees(root):
    records = []
    for block in git(root, "worktree", "list", "--porcelain", "-z").split(b"\0\0"):
        if not block.strip(b"\0"):
            continue
        record = {}
        for field in block.split(b"\0"):
            if field:
                key, _, value = os.fsdecode(field).partition(" ")
                record[key] = value
        require("worktree" in record, "Unrecognized worktree registration")
        require(not any(key in record for key in ("bare", "prunable", "locked")),
                "Bare, stale or locked worktree requires manual review")
        records.append(record)
    return records


def refs(root):
    return text_git(root, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads")


def data_roots(home):
    support = home / "Library/Application Support"
    return [support / "Tivano", support / "Tivano Dev", home / ".tivano", home / ".tivano-dev"]


def topology(source, destination, state, home):
    require(source.parent == destination.parent and source != destination,
            "Source and destination must be distinct siblings")
    require((source / ".git").is_dir() and not (source / ".git").is_symlink(),
            "Source must own the physical Git directory")
    require((destination / ".git").is_file() and not (destination / ".git").is_symlink(),
            "Destination must be the existing main linked worktree")
    common = plain(text_git(source, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    require(common == source / ".git", "Unexpected source common-dir")
    require(plain(text_git(destination, "rev-parse", "--path-format=absolute", "--git-common-dir")) == common,
            "Destination belongs to another repository")
    trees = worktrees(source)
    branches = [item["branch"] for item in trees if "branch" in item]
    require(len(branches) == len(set(branches)), "A branch is checked out in multiple worktrees")
    require(not any(path.is_symlink() for path in common.rglob("*")),
            "Linked Git metadata requires manual migration")
    paths = [plain(item["worktree"]) for item in trees]
    require(len(set(paths)) == len(paths) and source in paths and destination in paths,
            "Unexpected worktree registrations")
    target = next(item for item in trees if item["worktree"] == str(destination))
    require(target.get("branch") == "refs/heads/main", "Destination is not checked out on main")
    for path in paths:
        require(path.is_dir(), f"Missing worktree: {path}")
        require(not overlaps(state, path), f"State overlaps worktree: {path}")
        require(path == source or not overlaps(source, path), f"Nested source worktree: {path}")
        require(path == destination or not overlaps(destination, path), f"Nested destination worktree: {path}")
        require(plain(text_git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")) == common,
                f"Worktree common-dir mismatch: {path}")
        if path != source:
            require((path / ".git").is_file() and not (path / ".git").is_symlink(), f"Invalid worktree pointer: {path}")
            git_dir = plain(text_git(path, "rev-parse", "--absolute-git-dir"))
            require(git_dir.parent == common / "worktrees", f"Unexpected worktree Git directory: {path}")
        require(plain(text_git(path, "rev-parse", "--show-toplevel")) == path, f"Unexpected checkout root: {path}")
    require(not present(common / "modules") and not present(common / "objects/info/alternates"),
            "Submodules or alternate object stores require manual migration")
    for path in (source, destination):
        require(not any(line.startswith(b"160000 ") for line in git(path, "ls-files", "--stage", "-z").split(b"\0")),
                f"Submodule checkout requires manual migration: {path}")
    for root in data_roots(home):
        plain(root)
        require(not overlaps(state, root), f"State overlaps application data: {root}")
        require(not overlaps(source, root) and not overlaps(destination, root),
                f"Checkout overlaps application data: {root}")
    for path in (source, destination):
        git_dir = plain(text_git(path, "rev-parse", "--absolute-git-dir"))
        require(not any(present(git_dir / name) for name in
                        ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "BISECT_START")),
                f"In-progress Git operation: {path}")
        require(not any(item.split(b"\n", 1)[0].lower() == b"core.worktree"
                        for item in git(path, "config", "--null", "--list").split(b"\0")),
                f"Explicit core.worktree requires manual migration: {path}")
    return common, trees


def prepare(args):
    source, destination, state, home = map(plain, (args.source, args.destination, args.state_dir, args.home))
    require(not present(state) or (state.is_dir() and not any(state.iterdir())),
            "State must be absent or empty; existing plans are never overwritten")
    common, trees = topology(source, destination, state, home)
    require(source.stat().st_dev == destination.stat().st_dev == state.parent.stat().st_dev,
            "State and checkouts must share a filesystem for reversible renames")
    plan = dict(version=1, source=str(source), destination=str(destination), state_dir=str(state),
                home=str(home), source_head=text_git(source, "rev-parse", "HEAD"),
                source_branch=text_git(source, "symbolic-ref", "--quiet", "--short", "HEAD")
                if text_git(source, "rev-parse", "--abbrev-ref", "HEAD") != "HEAD" else None,
                git_common_dir=str(common), preserved_main=str(state / "preserved-main"),
                recovery_worktree=str(state / "recovered-work"), worktrees=trees,
                source_identity=identity(source), destination_identity=identity(destination),
                common_identity=identity(common))
    state.mkdir(mode=0o700, exist_ok=True)
    atomic_json(state / "plan.json", plan)
    print(f"prepared {state}")


def load_plan(state):
    state = plain(state)
    plan = read_json(state / "plan.json")
    require(isinstance(plan, dict) and set(plan) == {
        "version", "source", "destination", "state_dir", "home", "source_head", "source_branch",
        "git_common_dir", "preserved_main", "recovery_worktree", "worktrees", "source_identity",
        "destination_identity", "common_identity"}, "Unknown plan schema")
    require(isinstance(plan["worktrees"], list) and plan["worktrees"], "Missing planned worktrees")
    require(plan.get("version") == 1 and plan.get("state_dir") == str(state), "Unknown plan or state location")
    for key in ("source", "destination", "home", "git_common_dir", "preserved_main", "recovery_worktree"):
        require(isinstance(plan.get(key), str), f"Missing plan path: {key}")
        plain(plan[key])
    require(plan["git_common_dir"] == str(Path(plan["source"]) / ".git") and
            plan["preserved_main"] == str(state / "preserved-main") and
            plan["recovery_worktree"] == str(state / "recovered-work"), "Unexpected plan topology")
    return plan


def progress(plan, phase, **changes):
    path = Path(plan["state_dir"]) / "progress.json"
    value = read_json(path) if path.exists() else {"version": 1, "source": plan["source"],
                                                 "destination": plan["destination"]}
    value.update(changes, phase=phase, updated_at=time.time())
    atomic_json(path, value)
    print(f"{phase} {plan['state_dir']}", flush=True)
    return value


def processes(roots):
    require(sys.platform == "darwin", "Offline process proof is implemented only for macOS")
    ps = command(["/bin/ps", "-axo", "pid=,comm="]).decode(errors="surrogateescape")
    active = set()
    for line in ps.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        pid, executable = int(fields[0]), fields[1]
        name = Path(executable).name
        if name in ("Tivano", "Tivano Dev", "Droppy Code", "Droppy Code Dev", "Cody") or any(
                f"/{app}.app/" in executable for app in ("Tivano", "Tivano Dev", "Droppy Code", "Droppy Code Dev", "Cody")):
            active.add((pid, "application"))
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-F", "pftn"], cwd="/", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0 and not result.stderr.strip(), "Cannot prove process quiescence with lsof")
    pid = None
    for line in result.stdout.decode(errors="surrogateescape").splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n/") and pid != os.getpid():
            name = line[1:]
            if name.endswith(" (deleted)"):
                name = name[:-10]
            path = Path(name)
            for root in roots:
                if within(path, root):
                    active.add((pid, str(root)))
    active = sorted(item for item in active if item[0] != os.getpid())
    return active


def lock_paths(plan):
    support = Path(plan["home"]) / "Library/Application Support"
    paths = [support / name for name in (".tivano-library.lock", ".tivano-migration.lock",
                                         ".tivano-release-library.lock", ".tivano-dev-library.lock")]
    for common in (plan["git_common_dir"], str(Path(plan["destination"]) / ".git")):
        digest = hashlib.sha256(common.encode()).hexdigest()
        paths.append(support / ".tivano-resource-locks" / (digest + ".lock"))
    return paths


def watch_roots(plan):
    return list(set([Path(plan["source"]), Path(plan["destination"]),
                     Path(plan["preserved_main"]), Path(plan["recovery_worktree"])] +
                    [Path(item["worktree"]) for item in plan["worktrees"]] + library_paths(plan)))


def require_quiet(plan, message):
    deadline = time.monotonic() + 3
    while True:
        active = processes(watch_roots(plan))
        if not active:
            return
        require(time.monotonic() < deadline,
                message + " (PID " + ", ".join(str(pid) for pid in sorted({pid for pid, _ in active})) + ")")
        time.sleep(0.1)


@contextlib.contextmanager
def migration_gate(plan):
    path = Path(plan["state_dir"]) / "migration-gate.lock"
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+b") as handle:
        require(identity(path) == [os.fstat(handle.fileno()).st_dev, os.fstat(handle.fileno()).st_ino],
                "Migration gate identity changed")
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def cancel_if_requested(plan):
    if present(Path(plan["state_dir"]) / "cancel-request.json"):
        progress(plan, "cancelled")
        raise Stopped("Cancelled before backup; live paths were not changed")


@contextlib.contextmanager
def offline(plan, seconds):
    deadline = time.monotonic() + seconds
    roots = watch_roots(plan)
    while True:
        with migration_gate(plan):
            cancel_if_requested(plan)
        try:
            active = processes(roots)
        except Stopped:
            require(time.monotonic() < deadline, "Offline proof timed out; process visibility was incomplete")
            print(f"waiting {plan['state_dir']}", flush=True)
            time.sleep(min(2, max(0, deadline - time.monotonic())))
            continue
        if not active:
            with contextlib.ExitStack() as stack:
                try:
                    for index, path in enumerate(lock_paths(plan)):
                        plain(path)
                        # Existing edition lock inodes are never unlinked or replaced.
                        if index < 4:
                            require(path.is_file(), f"Missing existing application lock: {path}")
                        else:
                            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                        descriptor = os.open(path, os.O_RDWR | (os.O_CREAT if index >= 4 else 0) | os.O_NOFOLLOW, 0o600)
                        handle = stack.enter_context(os.fdopen(descriptor, "r+b"))
                        require(identity(path) == [os.fstat(handle.fileno()).st_dev, os.fstat(handle.fileno()).st_ino],
                                f"Lock identity changed: {path}")
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    time.sleep(1)
                    active = processes(roots)
                    if not active:
                        yield
                        return
        for pid, path in active:
            print(f"waiting PID={pid} {path}", flush=True)
        require(time.monotonic() < deadline, "Offline wait timed out; no process was stopped")
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def file_entry(path):
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        return ["link", mode, os.readlink(path)]
    if stat.S_ISDIR(info.st_mode):
        return ["directory", mode]
    require(stat.S_ISREG(info.st_mode), f"Special file requires manual handling: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    require(info.st_size == path.stat().st_size and info.st_mtime_ns == path.stat().st_mtime_ns,
            f"File changed while reading: {path}")
    return ["file", mode, info.st_size, digest.hexdigest()]


def inventory(root):
    require(present(root), f"Missing snapshot path: {root}")
    result = {".": file_entry(root)}
    if root.is_dir() and not root.is_symlink():
        for parent, directories, files in os.walk(root, followlinks=False):
            for name in sorted(directories + files):
                path = Path(parent) / name
                result[str(path.relative_to(root))] = file_entry(path)
    return result


def digest_inventory(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def restore_worktree_metadata(root, expected, *, create_directories=False, restore_files=True):
    for relative, before in sorted(expected.items(), key=lambda item: (len(Path(item[0]).parts), item[0])):
        if relative == ".git" or relative.startswith(".git/"):
            continue
        path = root / relative
        require(within(path, root) and ".." not in Path(relative).parts, "Invalid snapshot path")
        if before[0] == "directory":
            if not present(path):
                if not create_directories:
                    continue
                require(plain(path.parent).is_dir(), f"Missing original parent: {path.parent}")
                path.mkdir(mode=before[1])
            require(path.is_dir() and not path.is_symlink(), f"Original directory changed type: {path}")
            path.chmod(before[1])
        elif restore_files and present(path):
            actual = file_entry(path)
            require(actual[0] == before[0] and actual[2:] == before[2:],
                    f"Original file content changed: {path}")
            if before[0] == "file":
                path.chmod(before[1])


def library_paths(plan):
    support = Path(plan["home"]) / "Library/Application Support"
    return [support / edition / "library.json" for edition in ("Tivano", "Tivano Dev")]


def mapped(value, plan):
    if not isinstance(value, str):
        return value
    for old, new in ((plan["source"], plan["destination"]),
                     (plan["destination"], plan["preserved_main"])):
        if value == old or value.startswith(old + "/"):
            return new + value[len(old):]
    return value


def staged_libraries(plan):
    staged = []
    issues = []
    for path in library_paths(plan):
        plain(path)
        if not path.exists():
            staged.append({"path": str(path), "exists": False})
            continue
        original = read_json(path)
        require(isinstance(original, dict) and isinstance(original.get("projects"), list) and
                isinstance(original.get("threads"), list), f"Unrecognized library schema: {path}")
        updated = copy.deepcopy(original)
        allowed = set()
        for collection in ("projects", "threads"):
            for index, item in enumerate(updated[collection]):
                require(isinstance(item, dict), f"Invalid library record: {path}")
                key = "path" if collection == "projects" else "worktreePath"
                allowed.add((collection, index, key))
                if key in item:
                    item[key] = mapped(item[key], plan)
                if collection == "threads" and item.get("hydra") is not None:
                    require(isinstance(item["hydra"], dict), f"Invalid Hydra record: {path}")
                    allowed.add((collection, index, "hydra", "targetCheckout"))
                    if "targetCheckout" in item["hydra"]:
                        item["hydra"]["targetCheckout"] = mapped(item["hydra"]["targetCheckout"], plan)
        # Unknown path-valued metadata is blocked, not guessed. Prose/history stays opaque.
        opaque = {"title", "name", "task", "summary", "activity", "providerHistoryIssue",
                  "providerSessionID", "providerResumeAt", "nativeID", "nativeTaskID", "toolUseID"}
        def inspect(value, location=()):
            if isinstance(value, dict):
                for key, child in value.items():
                    if key not in opaque:
                        inspect(child, location + (key,))
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    inspect(child, location + (index,))
            elif isinstance(value, str) and mapped(value, plan) != value and location not in allowed:
                issues.append({"library": str(path), "field": ".".join(map(str, location)), "path": value})
        inspect(original)
        payload = (json.dumps(updated, ensure_ascii=False, indent=2) + "\n").encode()
        require(json.loads(payload) == updated, f"Staged JSON mismatch: {path}")
        staged.append({"path": str(path), "exists": True, "mode": stat.S_IMODE(path.stat().st_mode),
                       "before": hashlib.sha256(path.read_bytes()).hexdigest(),
                       "after": hashlib.sha256(payload).hexdigest(), "payload": payload})
    if issues:
        atomic_json(Path(plan["state_dir"]) / "metadata-review.json", {"version": 1, "fields": issues})
        raise Stopped("Unmapped ownership/execution metadata; inspect metadata-review.json; no live changes made")
    return staged


def verify_initial(plan):
    source, destination, state, home = [Path(plan[key]) for key in ("source", "destination", "state_dir", "home")]
    common, trees = topology(source, destination, state, home)
    require(trees == plan["worktrees"], "Worktree registrations changed; prepare again in a new state directory")
    for path, key in ((source, "source_identity"), (destination, "destination_identity"), (common, "common_identity")):
        require(identity(path) == plan[key], f"Path identity changed: {path}")
    require(text_git(source, "rev-parse", "HEAD") == plan["source_head"], "Source HEAD changed; prepare again")
    branch = text_git(source, "rev-parse", "--abbrev-ref", "HEAD")
    require(branch == (plan["source_branch"] or "HEAD"), "Source branch changed; prepare again")
    require(text_git(source, "show-ref", "--verify", "--hash", "refs/heads/dev"), "Local dev is required")
    for tree in trees:
        require(tree.get("branch") != "refs/heads/dev" or tree["worktree"] == plan["source"],
                "dev is occupied by another checkout")
    for path in (Path(plan["preserved_main"]), Path(plan["recovery_worktree"])):
        require(not present(path), f"Recovery path already exists: {path}")
    require(not list(common.rglob("*.lock")), "Git lock file requires manual review")
    ignored = {os.fsdecode(path) for path in git(source, "ls-files", "--others", "--ignored", "--exclude-standard", "-z").split(b"\0") if path}
    ignored_parents = {str(parent) for path in ignored for parent in Path(path).parents if str(parent) != "."}
    for raw in git(source, "ls-tree", "-r", "--name-only", "-z", "refs/heads/dev").split(b"\0"):
        if raw:
            path = os.fsdecode(raw)
            require(path not in ignored and path not in ignored_parents and
                    not any(str(parent) in ignored for parent in Path(path).parents),
                    f"Ignored content would collide with dev: {path}")


def backup(plan, libraries):
    state = Path(plan["state_dir"])
    root = state / "backup"
    require(not present(root), "Backup already exists; inspect the earlier attempt")
    paths = [Path(plan["source"]), Path(plan["destination"])]
    paths += [Path(item["worktree"]) / ".git" for item in plan["worktrees"] if item["worktree"] != plan["source"]]
    paths += [Path(item["path"]) for item in libraries if item["exists"]]
    snapshots = [(path, inventory(path)) for path in paths]
    size = sum(entry[2] for _, entries in snapshots for entry in entries.values() if entry[0] == "file")
    require(shutil.disk_usage(state).free > size * 2 + 256 * 1024 * 1024,
            "Insufficient space for verified backup and recovery")
    root.mkdir(mode=0o700)
    manifest = []
    for index, (path, before) in enumerate(snapshots):
        target = root / f"{index:03d}"
        if path.is_dir():
            shutil.copytree(path, target, symlinks=True, copy_function=shutil.copy2)
        else:
            shutil.copy2(path, target, follow_symlinks=False)
        require(inventory(path) == before == inventory(target), f"Backup mismatch: {path}")
        entry = {"path": str(path), "backup": str(target), "inventory": before}
        manifest.append(entry)
        atomic_json(state / "backup-manifest.json", {"version": 1, "entries": manifest})
    for item in libraries:
        if item["exists"]:
            staged = state / ("staged-" + Path(item["path"]).parent.name + ".json")
            atomic_bytes(staged, item["payload"], item["mode"])
            require(hashlib.sha256(staged.read_bytes()).hexdigest() == item["after"], "Staged JSON changed")
            item["staged"] = str(staged)
    return manifest


def repair(root, plan, recovered=False):
    paths = [Path(item["worktree"]) for item in plan["worktrees"] if item["worktree"] != plan["source"]]
    paths = [Path(plan["preserved_main"]) if str(path) == plan["destination"] else path for path in paths]
    if recovered:
        paths.append(Path(plan["recovery_worktree"]))
    git(root, "worktree", "repair", *map(str, paths))
    expected = root / ".git"
    for path in [root] + paths:
        require(plain(text_git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")) == expected,
                f"Repair verification failed: {path}")


def fingerprint(plan, root):
    paths = list(dict.fromkeys([root, Path(plan["source"]), Path(plan["destination"]),
                               Path(plan["preserved_main"]), Path(plan["recovery_worktree"])]))
    paths += [Path(item["worktree"]) / ".git" for item in plan["worktrees"]
              if item["worktree"] not in (plan["source"], plan["destination"])]
    paths += library_paths(plan)
    return {str(path): {"identity": identity(path), "digest": digest_inventory(inventory(path))}
            if present(path) else None for path in paths}


def recovery_notes(plan, journal):
    state = Path(plan["state_dir"])
    atomic_json(state / "recovery.json", {
        "version": 1, "pending": journal.get("pending"), "steps": journal.get("steps", []),
        "source": plan["source"], "destination": plan["destination"],
        "preserved_main": plan["preserved_main"], "recovered_work": plan["recovery_worktree"],
        "stash_sha": journal.get("stash_sha"), "backup_manifest": str(state / "backup-manifest.json"),
        "instructions": [
            "Keep all related apps and repository writers closed. Never delete any lock inode, backup, stash or checkout.",
            "If no operation is pending and the checkpoint matches, use rollback --state-dir with this state directory.",
            "If an operation is pending, inspect its effects before changing anything; automatic rollback refuses unknown state.",
            "With source renamed: repair from destination, switch back to the recorded original branch (or detached source_head) with --no-overwrite-ignore; never force.",
            "Rename destination back to source only when source is absent and its recorded inode matches. Repair all registered linked worktrees from source.",
            "Move preserved-main back to destination using git worktree move only when destination is absent. Repair again.",
            "Restore source work only by git stash apply --index of the recorded exact stash SHA when the source index/worktree is clean; keep the stash and recovered-work.",
            "Restore each library from its manifest backup only when its current digest matches the recorded before/after digest; otherwise preserve it and reconcile manually.",
            "For interrupted stash creation, inspect refs/stash and its reflog against backup before proceeding; do not infer a stash from its position."]})


def migrate(plan, journal):
    state = Path(plan["state_dir"])
    source, destination = Path(plan["source"]), Path(plan["destination"])
    root = source
    original = next(entry["inventory"] for entry in read_json(state / "backup-manifest.json")["entries"]
                    if entry["path"] == plan["source"])
    def save():
        atomic_json(state / "journal.json", journal)
        recovery_notes(plan, journal)
    def step(name, action):
        require_quiet(plan, "A related process restarted")
        current_root = destination if present(destination / ".git" / "HEAD") else source
        require(fingerprint(plan, current_root) == journal["checkpoint"], "Frozen state changed before operation")
        journal["pending"] = name
        save()
        action()
        journal["steps"].append(name)
        journal["pending"] = None
        journal["checkpoint"] = fingerprint(plan, destination if present(destination / ".git" / "HEAD") else source)
        save()
    dirty = git(source, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    if dirty:
        def stash():
            git(source, "stash", "push", "--include-untracked", "--message", "Tivano checkout consolidation " + str(state))
            sha = text_git(source, "rev-parse", "refs/stash")
            require(sha != journal["prior_stash"], "Stash was not created")
            journal["stash_sha"] = sha
            save()
            restore_worktree_metadata(source, original, create_directories=True, restore_files=False)
            require(not git(source, "status", "--porcelain=v1", "-z", "--untracked-files=all"), "Source remains dirty after stash")
        step("stash", stash)
        step("recovery_created", lambda: git(source, "worktree", "add", "--detach", plan["recovery_worktree"], plan["source_head"]))
        def recover():
            recovered = Path(plan["recovery_worktree"])
            git(recovered, "stash", "apply", "--index", journal["stash_sha"])
            restore_worktree_metadata(recovered, original)
        step("recovery_applied", recover)
        # Compare staged/unstaged patches and untracked content, not just status letters.
        recovered = Path(plan["recovery_worktree"])
        require(hashlib.sha256(git(recovered, "diff", "--no-ext-diff", "--no-textconv", "--binary")).hexdigest() == journal["unstaged"] and
                hashlib.sha256(git(recovered, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--binary")).hexdigest() == journal["staged"],
                "Recovered patches differ; original backup and exact stash are retained")
        for relative, entry in journal["untracked"].items():
            require(file_entry(recovered / relative) == entry, f"Recovered file mismatch: {recovered / relative}")
    step("main_moved", lambda: git(source, "worktree", "move", str(destination), plan["preserved_main"]))
    step("source_renamed", lambda: source.rename(destination))
    root = destination
    step("repaired", lambda: repair(root, plan, bool(journal.get("stash_sha"))))
    step("dev_checked_out", lambda: git(root, "switch", "--no-overwrite-ignore", "dev"))
    require(refs(root) == journal["branches"], "Branch references changed")
    require(not git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all"), "Final dev checkout is dirty")
    for index, item in enumerate(journal["libraries"]):
        if item["exists"]:
            path = Path(item["path"])
            require(hashlib.sha256(path.read_bytes()).hexdigest() == item["before"], f"Library changed: {path}")
            step(f"library_{index}", lambda item=item, path=path: atomic_bytes(path, Path(item["staged"]).read_bytes(), item["mode"]))
    for relative, entry in journal["ignored"].items():
        require(file_entry(root / relative) == entry, f"Ignored file changed: {root / relative}")
    require(text_git(root, "rev-parse", "HEAD") == journal["dev_head"], "Final dev HEAD mismatch")
    require(text_git(Path(plan["preserved_main"]), "rev-parse", "HEAD") == journal["main_head"], "Preserved main HEAD mismatch")
    main_backup = next(entry for entry in read_json(state / "backup-manifest.json")["entries"]
                       if entry["path"] == plan["destination"])
    require({key: value for key, value in inventory(Path(plan["preserved_main"])).items() if key != ".git"} ==
            {key: value for key, value in main_backup["inventory"].items() if key != ".git"},
            "Preserved main files changed")
    journal["checkpoint"] = fingerprint(plan, root)
    save()
    progress(plan, "completed", recovery_worktree=plan["recovery_worktree"] if journal.get("stash_sha") else None,
             stash_sha=journal.get("stash_sha"), preserved_main=plan["preserved_main"])


def rollback_locked(plan, journal):
    state = Path(plan["state_dir"])
    source, destination = Path(plan["source"]), Path(plan["destination"])
    require(not journal.get("pending"), "Interrupted operation has unknown effects; inspect recovery.json")
    require(not journal.get("rollback_started"), "Interrupted rollback requires manual recovery.json review")
    moved = "source_renamed" in journal["steps"]
    root = destination if moved else source
    require(fingerprint(plan, root) == journal.get("checkpoint"), "State changed since checkpoint; refusing to overwrite newer work")
    require_quiet(plan, "A related process restarted")
    # Keep a second complete snapshot of the exact state being undone, including Git.
    target = state / "before-rollback"
    require(not present(target), "Rollback snapshot already exists")
    size = sum(entry[2] for entry in inventory(root).values() if entry[0] == "file")
    require(shutil.disk_usage(state).free > size + 256 * 1024 * 1024, "Insufficient rollback snapshot space")
    shutil.copytree(root, target, symlinks=True)
    require(inventory(root) == inventory(target), "Rollback snapshot mismatch")
    require(fingerprint(plan, root) == journal["checkpoint"], "State changed during rollback snapshot")
    journal["rollback_started"] = True
    atomic_json(state / "journal.json", journal)
    def undo(name, action):
        require_quiet(plan, "A related process restarted during rollback")
        require(fingerprint(plan, root) == journal["checkpoint"], "State changed during rollback")
        journal["pending"] = "rollback_" + name
        atomic_json(state / "journal.json", journal)
        recovery_notes(plan, journal)
        action()
        journal["steps"].remove(name)
        journal["pending"] = None
        journal["checkpoint"] = fingerprint(plan, root)
        atomic_json(state / "journal.json", journal)
    for index in reversed(range(len(journal["libraries"]))):
        name = f"library_{index}"
        if name in journal["steps"]:
            item = journal["libraries"][index]
            entry = next(entry for entry in read_json(state / "backup-manifest.json")["entries"] if entry["path"] == item["path"])
            require(inventory(Path(entry["backup"])) == entry["inventory"], "Library backup changed")
            undo(name, lambda item=item, entry=entry: atomic_bytes(Path(item["path"]), Path(entry["backup"]).read_bytes(), item["mode"]))
    if "dev_checked_out" in journal["steps"]:
        def original_checkout():
            args = ["switch", "--no-overwrite-ignore"]
            args += [plan["source_branch"]] if plan["source_branch"] else ["--detach", plan["source_head"]]
            git(root, *args)
        undo("dev_checked_out", original_checkout)
    if moved:
        require(not present(source), "Source path was recreated; refusing rollback")
        undo("source_renamed", lambda: destination.rename(source))
        root = source
        repair(root, plan, bool(journal.get("stash_sha")))
        journal["checkpoint"] = fingerprint(plan, root)
        atomic_json(state / "journal.json", journal)
    if "main_moved" in journal["steps"]:
        undo("main_moved", lambda: git(root, "worktree", "move", plan["preserved_main"], str(destination)))
    paths = [item["worktree"] for item in plan["worktrees"] if item["worktree"] != plan["source"]]
    if "recovery_created" in journal["steps"]:
        paths.append(plan["recovery_worktree"])
    git(root, "worktree", "repair", *paths)
    journal["checkpoint"] = fingerprint(plan, root)
    atomic_json(state / "journal.json", journal)
    if "stash" in journal["steps"]:
        require(not git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all"), "Cannot restore stash over dirty source")
        undo("stash", lambda: git(root, "stash", "apply", "--index", journal["stash_sha"]))
    require(refs(root) == journal["branches"] and text_git(root, "rev-parse", "HEAD") == plan["source_head"],
            "Rollback branch verification failed")
    original = next(entry for entry in read_json(state / "backup-manifest.json")["entries"] if entry["path"] == plan["source"])
    require(fingerprint(plan, root) == journal["checkpoint"], "State changed before restoring original metadata")
    journal["pending"] = "rollback_metadata"
    atomic_json(state / "journal.json", journal)
    recovery_notes(plan, journal)
    restore_worktree_metadata(root, original["inventory"], create_directories=True)
    journal["pending"] = None
    journal["checkpoint"] = fingerprint(plan, root)
    atomic_json(state / "journal.json", journal)
    recovery_notes(plan, journal)
    current = inventory(root)
    require({key: value for key, value in current.items() if key != ".git" and not key.startswith(".git/")} ==
            {key: value for key, value in original["inventory"].items() if key != ".git" and not key.startswith(".git/")},
            "Rollback working files differ; preserve all snapshots for manual recovery")
    for path in [str(root)] + paths:
        require(plain(text_git(Path(path), "rev-parse", "--path-format=absolute", "--git-common-dir")) == root / ".git",
                f"Rollback common-dir mismatch: {path}")
    progress(plan, "rolled_back", stash_sha=journal.get("stash_sha"), recovery_worktree=plan["recovery_worktree"])


def apply(plan, seconds):
    state = Path(plan["state_dir"])
    require(not present(state / "progress.json"), "Existing attempt requires rollback or manual review; prepare a new plan")
    progress(plan, "waiting", worker_pid=os.getpid())
    journal = None
    try:
        with offline(plan, seconds):
            # Cancellation and the first backup transition share one cross-process gate.
            with migration_gate(plan):
                cancel_if_requested(plan)
                verify_initial(plan)
                libraries = staged_libraries(plan)
                progress(plan, "backing_up")
            manifest = backup(plan, libraries)
            verify_initial(plan)
            for entry in manifest:
                require(inventory(Path(entry["path"])) == entry["inventory"], f"Frozen state changed: {entry['path']}")
            source = Path(plan["source"])
            untracked = {}
            for name in git(source, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
                if name:
                    relative = os.fsdecode(name)
                    untracked[relative] = file_entry(source / relative)
            ignored = {}
            for name in git(source, "ls-files", "--others", "--ignored", "--exclude-standard", "-z").split(b"\0"):
                if name:
                    relative = os.fsdecode(name)
                    ignored[relative] = file_entry(source / relative)
            stash_refs = text_git(source, "for-each-ref", "--format=%(objectname)", "refs/stash")
            journal = {"version": 1, "steps": [], "pending": None, "prior_stash": stash_refs,
                       "branches": refs(source), "dev_head": text_git(source, "rev-parse", "refs/heads/dev"),
                       "main_head": text_git(Path(plan["destination"]), "rev-parse", "HEAD"),
                       "unstaged": hashlib.sha256(git(source, "diff", "--no-ext-diff", "--no-textconv", "--binary")).hexdigest(),
                       "staged": hashlib.sha256(git(source, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--binary")).hexdigest(),
                       "untracked": untracked, "ignored": ignored,
                       "libraries": [{key: value for key, value in item.items() if key != "payload"} for item in libraries]}
            journal["checkpoint"] = fingerprint(plan, source)
            atomic_json(state / "journal.json", journal)
            recovery_notes(plan, journal)
            progress(plan, "migrating")
            try:
                migrate(plan, journal)
            except Exception:
                # A pending subprocess/rename can have partial effects. Never infer success.
                if journal["steps"] and not journal.get("pending"):
                    rollback_locked(plan, journal)
                raise
    except Exception:
        if journal:
            recovery_notes(plan, journal)
        existing = read_json(state / "progress.json")
        if existing.get("phase") not in ("rolled_back", "cancelled"):
            progress(plan, "failed", recovery=str(state / "recovery.json"))
        raise


def rollback(plan):
    state = Path(plan["state_dir"])
    status = read_json(state / "progress.json")
    require(status.get("phase") in ("completed", "failed"), "No completed or failed migration to roll back")
    journal = read_json(state / "journal.json")
    progress(plan, "waiting", operation="rollback")
    try:
        with offline(plan, 3600):
            rollback_locked(plan, journal)
    except Exception:
        recovery_notes(plan, journal)
        progress(plan, "failed", operation="rollback", recovery=str(state / "recovery.json"))
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    first = commands.add_parser("prepare")
    first.add_argument("--source", required=True)
    first.add_argument("--destination", required=True)
    first.add_argument("--state-dir", required=True)
    first.add_argument("--home", default=str(Path.home()))
    second = commands.add_parser("apply")
    second.add_argument("--state-dir", required=True)
    second.add_argument("--wait-seconds", type=int, default=3600)
    third = commands.add_parser("rollback")
    third.add_argument("--state-dir", required=True)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            prepare(args)
        else:
            plan = load_plan(args.state_dir)
            if args.action == "apply":
                require(0 <= args.wait_seconds <= 86400, "Wait must be between 0 and 86400 seconds")
                apply(plan, args.wait_seconds)
            else:
                rollback(plan)
    except (Stopped, OSError, ValueError, KeyError, TypeError) as error:
        print(f"stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
