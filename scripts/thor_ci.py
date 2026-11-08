#!/usr/bin/env python3
"""Poll an owner remote and record full verification results (Python 3.9+)."""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


# The launch agent runs an installed copy outside the checkout, because each run
# replaces the checkout with the commit under test.
ROOT = Path(os.environ.get('TIVANO_CI_REPO') or Path(__file__).resolve().parent.parent).resolve()
HASH = re.compile(r'[0-9a-fA-F]{40}\Z')
STATUS_FIELDS = ('finished_at', 'started_at', 'failed', 'reason', 'artifacts', 'environment')


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def stop_process(process):
    # verify.py starts checks in separate sessions; killing only its group leaks them.
    descendants = {process.pid}
    try:
        rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True, timeout=5)
        pairs = [tuple(map(int, row.split())) for row in rows.splitlines()]
        while True:
            children = {pid for pid, parent in pairs if parent in descendants}
            if children <= descendants:
                break
            descendants |= children
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    for pid in descendants:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for pid in descendants:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def capture(command, timeout=30):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'):
        env.pop(name, None)
    process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, errors='replace',
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        stop_process(process)
        raise
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def git(*arguments, **options):
    result = capture(['git', '-C', str(ROOT), *arguments], **options)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'git failed: ' + ' '.join(arguments))
    return result.stdout.strip()


def config(name, default=None):
    result = capture(['git', '-C', str(ROOT), 'config', '--get', name])
    if result.returncode == 1:
        return default
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'cannot read ' + name)
    return result.stdout.strip()


def settings():
    if config('tivano.ci.owned', 'false').lower() != 'true':
        raise ValueError('poll/run require tivano.ci.owned=true in a dedicated CI checkout')
    remote = config('tivano.ci.remote', 'owner')
    if (remote == 'origin' or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*', remote)
            or config('remote.' + remote + '.url') is None):
        raise ValueError('tivano.ci.remote must name a configured remote other than origin')
    branch = config('tivano.ci.branch', 'dev')
    git('check-ref-format', 'refs/heads/' + branch)
    gui = config('tivano.ci.gui', 'true').lower()
    if gui not in ('true', 'false'):
        raise ValueError('tivano.ci.gui must be true or false')
    timeout = int(config('tivano.ci.timeout', '10800'))
    if timeout <= 0:
        raise ValueError('tivano.ci.timeout must be a positive number of seconds')
    return remote, branch, gui == 'true', timeout


def results_directory():
    common = (ROOT / git('rev-parse', '--git-common-dir')).resolve()
    sources = {ROOT, common.parent}
    for field in git('worktree', 'list', '--porcelain', '-z').split('\0'):
        if field.startswith('worktree '):
            sources.add(Path(field[9:]).resolve())
    override = os.environ.get('TIVANO_ARTIFACTS_ROOT')
    artifacts = Path(override) if override is not None else common.parent.parent
    if not artifacts.is_absolute():
        raise ValueError('TIVANO_ARTIFACTS_ROOT must be an absolute external path')
    results = artifacts / 'ci-results'
    for path in (artifacts, results):
        for candidate in (Path(os.path.abspath(path)), path.resolve()):
            if any(candidate == source or source in candidate.parents for source in sources):
                raise ValueError('CI results must be outside every source checkout')
            if any((parent / '.git').exists() for parent in (candidate, *candidate.parents)):
                raise ValueError('CI results must be outside every Git worktree')
    return results.resolve()


def read_record(path):
    try:
        with path.open(encoding='utf-8') as handle:
            record = json.load(handle)
    except FileNotFoundError:
        return None
    if not isinstance(record, dict):
        raise ValueError('invalid result record: ' + str(path))
    return record


def atomic_json(path, record):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix='.' + path.name + '.', delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(record, handle, ensure_ascii=True, allow_nan=False)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temporary), str(path))
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink()


def save_record(results, record):
    atomic_json(results / (record['sha'] + '.json'), record)
    atomic_json(results / 'latest.json', record)


def poll_log(results, message):
    with (results / 'poll.log').open('a', encoding='utf-8') as handle:
        handle.write(timestamp() + ' ' + ' '.join(str(message).splitlines()) + '\n')


def expire_stale(results, timeout):
    now = datetime.now(timezone.utc)
    latest = read_record(results / 'latest.json')
    for path in sorted(results.glob('*.json')):
        if not HASH.fullmatch(path.stem):
            continue
        try:
            record = read_record(path)
            if not record or record.get('state') != 'running':
                continue
            started = datetime.fromisoformat(record['started_at'].replace('Z', '+00:00'))
            seconds = (now - started).total_seconds()
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            poll_log(results, 'cannot inspect ' + path.name + ': ' + str(error))
            continue
        if seconds <= timeout + 600:
            continue
        record.update(state='fail', reason='stale', finished_at=timestamp(),
                      seconds=round(seconds, 3), verify_exit=None)
        record.setdefault('failed', [])
        record.setdefault('artifacts', None)
        atomic_json(path, record)
        if latest and latest.get('sha') == path.stem:
            atomic_json(results / 'latest.json', record)


def environment():
    values = {}
    for name, command in (('sw_vers', ['sw_vers']),
                          ('swift', ['xcrun', 'swiftc', '--version']),
                          ('git', ['git', '--version'])):
        try:
            result = capture(command, timeout=15)
            output = result.stdout.strip()
            if result.returncode or not output:
                output = 'unavailable: ' + (result.stderr.strip() or str(result.returncode))
            values[name] = output.splitlines()[0] if name == 'swift' else output
        except (OSError, subprocess.SubprocessError) as error:
            values[name] = 'unavailable: ' + str(error)
    return values


def summary(log_path):
    artifacts = None
    with log_path.open(encoding='utf-8', errors='replace') as handle:
        for line in handle:
            if line.startswith('Artifacts: '):
                artifacts = line[len('Artifacts: '):].strip()
    if not artifacts:
        return None, [], 'missing Artifacts line; summary.json unavailable'
    try:
        run = Path(artifacts)
        if not run.is_absolute():
            run = ROOT / run
        report = read_record(run / 'summary.json')
        if report is None:
            raise ValueError('missing summary.json')
        if not isinstance(report.get('build'), dict) or not isinstance(report.get('checks'), dict):
            raise ValueError('summary.json requires build and checks objects')
        rows = [('build', report['build']), *report['checks'].items()]
        if any(not isinstance(row, dict) or not isinstance(row.get('status'), str)
               for _, row in rows):
            raise ValueError('summary.json contains an invalid check status')
        failed = [name for name, row in rows if row['status'] not in ('PASS', 'not selected')]
        return str(run.resolve()), failed, None
    except (OSError, ValueError) as error:
        return artifacts, [], 'cannot read summary: ' + str(error)


def ignore_interrupts():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)


def execute(results, sha, gui, timeout, lock_fd):
    started = time.monotonic()
    record = {'sha': sha, 'state': 'running', 'started_at': timestamp(), 'subject': ''}
    process = None
    reason = None
    exit_code = None
    artifacts = None
    failed = []
    log_path = results / (sha + '.log')
    try:
        record['subject'] = git('show', '-s', '--format=%s', sha)
        record['environment'] = environment()
        with log_path.open('w', encoding='utf-8') as log:
            git('checkout', '--detach', '--force', sha, timeout=120)
            git('clean', '-fdx', '-e', 'build.noindex', timeout=120)
            save_record(results, record)
            if not (ROOT / 'scripts/verify.py').is_file():
                raise RuntimeError('commit predates scripts/verify.py')
            command = ['nice', '-n', '10', sys.executable, 'scripts/verify.py', '--all']
            if gui:
                command.append('--gui')
            env = dict(os.environ, PYTHONUNBUFFERED='1', PYTHONDONTWRITEBYTECODE='1')
            # Keep the lock held if this supervisor dies while verify is still running.
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True,
                                       pass_fds=(lock_fd,))
            try:
                exit_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                stop_process(process)
                exit_code = process.returncode
                reason = 'timeout after ' + str(timeout) + ' seconds'
        artifacts, failed, summary_error = summary(log_path)
        if reason is None:
            if exit_code != 0:
                reason = 'verify exited with status ' + str(exit_code)
            elif failed:
                reason = 'verify exited successfully but summary contains unsuccessful checks'
            if summary_error:
                reason = (reason + '; ' if reason else '') + summary_error
    except KeyboardInterrupt:
        ignore_interrupts()
        reason = 'interrupted'
        if process is not None:
            stop_process(process)
            exit_code = process.returncode
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        reason = str(error)
        if process is not None and process.poll() is None:
            stop_process(process)
            exit_code = process.returncode
    ignore_interrupts()
    record.update(state='pass' if reason is None and exit_code == 0 else 'fail',
                  finished_at=timestamp(), seconds=round(time.monotonic() - started, 3),
                  verify_exit=exit_code, artifacts=artifacts, failed=failed)
    record.setdefault('environment', {})
    if reason:
        record['reason'] = reason
    save_record(results, record)
    print(json.dumps(record, ensure_ascii=True))
    return 0 if record['state'] == 'pass' else 1


def run(args):
    remote, branch, gui, timeout = settings()
    results = results_directory()
    results.mkdir(parents=True, exist_ok=True)
    with (results / '.lock').open('a') as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('busy')
            return 0
        expire_stale(results, timeout)
        if args.command == 'poll':
            try:
                git('fetch', remote, '--prune', timeout=120)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                poll_log(results, 'fetch failed: ' + str(error))
                return 0
            revision = 'refs/remotes/' + remote + '/' + branch
            # Explicitly requested commits (ci_gate.py kick) go before the branch tip.
            for request in sorted((results / 'requests').glob('*')):
                done = read_record(results / (request.name + '.json'))
                if not HASH.fullmatch(request.name) or (done and done.get('state') in ('pass', 'fail')):
                    request.unlink()
                    continue
                try:
                    git('cat-file', '-e', request.name + '^{commit}')
                except (OSError, RuntimeError, subprocess.SubprocessError):
                    poll_log(results, 'requested commit not on the build host: ' + request.name)
                    request.unlink()
                    continue
                request.unlink()
                return execute(results, request.name, gui, timeout, lock.fileno())
        else:
            revision = args.sha
        sha = git('rev-parse', '--verify', '--end-of-options', revision + '^{commit}')
        if not HASH.fullmatch(sha):
            raise ValueError('expected a 40-character commit hash')
        previous = read_record(results / (sha + '.json'))
        if previous and previous.get('state') in ('pass', 'fail') and not getattr(args, 'force', False):
            return 0
        return execute(results, sha, gui, timeout, lock.fileno())


def status(sha):
    try:
        record = read_record(results_directory() / (sha + '.json'))
        if record is None:
            return {'sha': sha, 'state': 'missing'}
        if record.get('sha') != sha or record.get('state') not in ('pass', 'fail', 'running'):
            raise ValueError('invalid result record')
        result = {'sha': sha, 'state': record['state']}
        result.update({key: record[key] for key in STATUS_FIELDS if key in record})
        return result
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        return {'sha': sha, 'state': 'fail', 'reason': 'status unavailable: ' + str(error)}


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('poll', help='fetch the configured branch and check a new commit')
    manual = commands.add_parser('run', help='check an already-fetched commit')
    manual.add_argument('sha')
    manual.add_argument('--force', action='store_true', help='rerun a completed commit')
    query = commands.add_parser('status', help='print one JSON line for a full commit hash')
    query.add_argument('sha')
    commands.add_parser('latest', help='print the most recently written result')
    queued = commands.add_parser('request', help='queue a full commit hash for the next poll')
    queued.add_argument('sha')
    args = parser.parse_args()
    if args.command == 'status':
        if not HASH.fullmatch(args.sha):
            query.error('sha must be a full 40-character hexadecimal commit hash')
        print(json.dumps(status(args.sha.lower()), ensure_ascii=True))
        return 0
    if args.command == 'request':
        if not HASH.fullmatch(args.sha):
            queued.error('sha must be a full 40-character hexadecimal commit hash')
        requests = results_directory() / 'requests'
        requests.mkdir(parents=True, exist_ok=True)
        (requests / args.sha.lower()).touch()
        print('requested ' + args.sha.lower())
        return 0
    if args.command == 'latest':
        try:
            record = read_record(results_directory() / 'latest.json')
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            record = {'state': 'fail', 'reason': 'latest unavailable: ' + str(error)}
        print(json.dumps(record if record is not None else {'state': 'missing'}, ensure_ascii=True))
        return 0
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    previous_int = signal.signal(signal.SIGINT, interrupted)
    try:
        return run(args)
    except KeyboardInterrupt:
        print('interrupted', file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('thor_ci: ' + str(error), file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)


if __name__ == '__main__':
    sys.exit(main())
