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
import socket
import subprocess
import sys
import tempfile
import time


# The launch agent runs an installed copy outside the checkout, because each run
# replaces the checkout with the commit under test.
ROOT = Path(os.environ.get('TIVANO_CI_REPO') or Path(__file__).resolve().parent.parent).resolve()
HASH = re.compile(r'[0-9a-fA-F]{40}\Z')
STATUS_FIELDS = ('finished_at', 'started_at', 'failed', 'reason', 'artifacts',
                 'environment', 'reused_from', 'reruns')
VERSION_KEYS = ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION',
                'TIVANO_RELEASE_VERSION', 'TivanoReleaseVersion')
VERSION_LINE = re.compile(r'\s*(?:' + '|'.join(VERSION_KEYS) + r')\s*=.*')
REQUEST_MAX_AGE_SECONDS = 86400
_interrupted = False


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


def capture(command, timeout=30, extra_env=None):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'):
        env.pop(name, None)
    if extra_env:
        env.update(extra_env)
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


def record_error(results, message):
    atomic_json(results / 'latest-error.json', {'time': timestamp(), 'message': message})


def clear_error(results):
    try:
        (results / 'latest-error.json').unlink()
    except FileNotFoundError:
        pass


def read_fetch_error_count(results):
    try:
        data = read_record(results / '.fetch-errors.json')
        if isinstance(data, dict) and isinstance(data.get('count'), int) and data['count'] >= 0:
            return data['count']
    except (OSError, ValueError):
        pass
    return 0


def write_fetch_error_count(results, count):
    atomic_json(results / '.fetch-errors.json', {'count': count, 'updated_at': timestamp()})


def clear_fetch_error_count(results):
    try:
        (results / '.fetch-errors.json').unlink()
    except FileNotFoundError:
        pass


def notify(results, state, sha='', subject='', failed=None, reason=''):
    try:
        command = config('tivano.ci.notify', '')
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        poll_log(results, 'notify failed: cannot read tivano.ci.notify: ' + str(error))
        return
    if not command:
        return
    extra_env = {
        'TIVANO_CI_STATE': str(state),
        'TIVANO_CI_SHA': str(sha or ''),
        'TIVANO_CI_SUBJECT': str(subject or ''),
        'TIVANO_CI_FAILED': ','.join(failed or []),
        'TIVANO_CI_REASON': str(reason or ''),
    }
    try:
        result = capture(['/bin/sh', '-c', command], timeout=30, extra_env=extra_env)
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or ('exit ' + str(result.returncode))
            poll_log(results, 'notify failed (' + str(result.returncode) + '): ' + detail)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        poll_log(results, 'notify failed: ' + str(error))


def notify_record(results, record, state_override=None):
    notify(
        results,
        state=state_override or record.get('state', ''),
        sha=record.get('sha', ''),
        subject=record.get('subject', ''),
        failed=record.get('failed', []),
        reason=record.get('reason', ''),
    )


def pid_is_gone(pid, host):
    if not isinstance(pid, int) or pid <= 0:
        return False
    if host is not None and host != socket.gethostname():
        return False
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        return False


def expire_stale(results, timeout, lock_held=None):
    probe_lock = None
    try:
        if lock_held is None:
            probe_lock = (results / '.lock').open('a')
            try:
                fcntl.flock(probe_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                lock_not_held = True
            except BlockingIOError:
                lock_not_held = False
        else:
            lock_not_held = bool(lock_held)
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
            pid_gone = pid_is_gone(record.get('pid'), record.get('host'))
            if not (pid_gone or lock_not_held or seconds > timeout + 600):
                continue
            record.update(state='fail', reason='stale', finished_at=timestamp(),
                          seconds=round(seconds, 3), verify_exit=None)
            record.setdefault('failed', [])
            record.setdefault('artifacts', None)
            atomic_json(path, record)
            if latest and latest.get('sha') == path.stem:
                atomic_json(results / 'latest.json', record)
            notify_record(results, record, state_override='stale')
    finally:
        if probe_lock is not None:
            probe_lock.close()


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


def ensure_metal_toolchain(results):
    # Xcode updates drop this downloadable component, and the app build then fails
    # in SwiftTerm's shaders before any check runs. Reinstall it on the build host.
    # Opt-in per host (git config tivano.ci.repair-metal true): the download is ~800 MB.
    try:
        if config('tivano.ci.repair-metal', 'false').lower() != 'true':
            return
        shown = capture(['xcodebuild', '-showComponent', 'MetalToolchain'], timeout=60)
        if 'Status: uninstalled' not in shown.stdout + shown.stderr:
            return
        poll_log(results, 'Metal Toolchain missing; downloading it')
        result = capture(['xcodebuild', '-downloadComponent', 'MetalToolchain'], timeout=3600)
        if result.returncode:
            detail = (result.stderr.strip() or result.stdout.strip())[-500:]
            poll_log(results, 'Metal Toolchain download failed: ' + detail)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        poll_log(results, 'cannot check Metal Toolchain: ' + str(error))


def summary(log_path, start_offset=0):
    artifacts = None
    with log_path.open(encoding='utf-8', errors='replace') as handle:
        if start_offset:
            handle.seek(start_offset)
        for line in handle:
            if line.startswith('Artifacts: '):
                artifacts = line[len('Artifacts: '):].strip()
    if not artifacts:
        return None, [], 'missing Artifacts line; summary.json unavailable'
    try:
        run_dir = Path(artifacts)
        if not run_dir.is_absolute():
            run_dir = ROOT / run_dir
        report = read_record(run_dir / 'summary.json')
        if report is None:
            raise ValueError('missing summary.json')
        if not isinstance(report.get('build'), dict) or not isinstance(report.get('checks'), dict):
            raise ValueError('summary.json requires build and checks objects')
        rows = [('build', report['build']), *report['checks'].items()]
        if any(not isinstance(row, dict) or not isinstance(row.get('status'), str)
               for _, row in rows):
            raise ValueError('summary.json contains an invalid check status')
        failed = [name for name, row in rows if row['status'] not in ('PASS', 'not selected')]
        return str(run_dir.resolve()), failed, None
    except (OSError, ValueError) as error:
        return artifacts, [], 'cannot read summary: ' + str(error)


def ignore_interrupts():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)


def finish_record(results, record):
    prev_term = signal.signal(signal.SIGTERM, signal.SIG_IGN)
    prev_int = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        save_record(results, record)
        notify_record(results, record)
        print(json.dumps(record, ensure_ascii=True))
    finally:
        if not _interrupted:
            signal.signal(signal.SIGTERM, prev_term)
            signal.signal(signal.SIGINT, prev_int)


def execute(results, sha, gui, timeout, lock_fd):
    started = time.monotonic()
    record = {
        'sha': sha,
        'state': 'running',
        'started_at': timestamp(),
        'subject': '',
        'pid': os.getpid(),
        'host': socket.gethostname(),
        'gui': gui,
    }
    process = None
    reason = None
    exit_code = None
    artifacts = None
    failed = []
    log_path = results / (sha + '.log')
    try:
        record['subject'] = git('show', '-s', '--format=%s', sha)
        ensure_metal_toolchain(results)
        record['environment'] = environment()
        with log_path.open('w', encoding='utf-8') as log:
            git('checkout', '--detach', '--force', sha, timeout=120)
            git('clean', '-fdx', '-e', 'build.noindex', timeout=120)
            save_record(results, record)
            if not (ROOT / 'scripts/verify.py').is_file():
                raise RuntimeError('commit predates scripts/verify.py')
            command = [sys.executable, 'scripts/verify.py', '--all']
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
    record.update(state='pass' if reason is None and exit_code == 0 else 'fail',
                  finished_at=timestamp(), seconds=round(time.monotonic() - started, 3),
                  verify_exit=exit_code, artifacts=artifacts, failed=failed)
    record.setdefault('environment', {})
    if reason:
        record['reason'] = reason
    finish_record(results, record)
    return 0 if record['state'] == 'pass' else 1


def parse_only(value):
    if isinstance(value, list):
        raw = [str(item).strip() for item in value]
    else:
        raw = [part.strip() for part in str(value).split(',')]
    if not raw or any(not item for item in raw):
        raise ValueError('--only must be a comma-separated list of check names')
    checks = []
    for item in raw:
        if item not in checks:
            checks.append(item)
    return checks


def rerun_preconditions(results, sha, only_checks):
    record = read_record(results / (sha + '.json'))
    if record is None or record.get('state') != 'fail':
        raise ValueError('rerun requires an existing fail record for ' + sha)
    artifacts = record.get('artifacts')
    if not artifacts:
        raise ValueError('rerun requires original artifacts for ' + sha)
    summary_path = Path(artifacts) / 'summary.json'
    orig_summary = read_record(summary_path)
    if (orig_summary is None or not isinstance(orig_summary.get('build'), dict)
            or not isinstance(orig_summary.get('checks'), dict)):
        raise ValueError('invalid summary.json for ' + sha)
    build_status = orig_summary['build'].get('status')
    if build_status != 'PASS':
        raise ValueError('rerun requires build status PASS, got ' + str(build_status))
    unknown = [name for name in only_checks if name not in orig_summary['checks']]
    if unknown:
        raise ValueError('unknown check names for ' + sha + ': ' + ', '.join(unknown))
    return record, summary_path, orig_summary


def rerun_checks(results, sha, only_checks, gui, timeout, lock_fd):
    orig_record, summary_path, orig_summary = rerun_preconditions(results, sha, only_checks)
    # Refuse before touching the record: a merged pass must keep one GUI coverage and toolchain.
    if orig_record.get('gui') is not gui:
        raise ValueError('GUI coverage differs from the failed run; use run --force for a full run')
    if environment() != orig_record.get('environment'):
        raise ValueError('build-host toolchain changed since the failed run; use run --force for a full run')
    started = time.monotonic()
    reruns = list(orig_record.get('reruns') or [])
    record = {
        'sha': sha,
        'state': 'running',
        'started_at': timestamp(),
        'subject': orig_record.get('subject') or '',
        'pid': os.getpid(),
        'host': socket.gethostname(),
        'artifacts': str(summary_path.parent),
        'gui': gui,
    }
    if reruns:
        record['reruns'] = reruns
    process = None
    reason = None
    exit_code = None
    log_path = results / (sha + '.log')
    try:
        if not record['subject']:
            record['subject'] = git('show', '-s', '--format=%s', sha)
        record['environment'] = environment()
        with log_path.open('a', encoding='utf-8') as log:
            log.write('\n=== rerun --only ' + ','.join(only_checks) + ' at ' + timestamp() + ' ===\n')
            log.flush()
            log_offset = log.tell()
            git('checkout', '--detach', '--force', sha, timeout=120)
            git('clean', '-fdx', '-e', 'build.noindex', timeout=120)
            save_record(results, record)
            if not (ROOT / 'scripts/verify.py').is_file():
                raise RuntimeError('commit predates scripts/verify.py')
            command = [sys.executable, 'scripts/verify.py', '--only', ','.join(only_checks), '--skip-build']
            if gui:
                command.append('--gui')
            env = dict(os.environ, PYTHONUNBUFFERED='1', PYTHONDONTWRITEBYTECODE='1')
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True,
                                       pass_fds=(lock_fd,))
            try:
                exit_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                stop_process(process)
                exit_code = process.returncode
                reason = 'timeout after ' + str(timeout) + ' seconds'
        new_artifacts, _, summary_error = summary(log_path, start_offset=log_offset)
        if summary_error is None and new_artifacts:
            new_summary = read_record(Path(new_artifacts) / 'summary.json')
            if new_summary is None or not isinstance(new_summary.get('checks'), dict):
                summary_error = 'cannot read summary: missing checks in rerun summary.json'
            else:
                now_ts = timestamp()
                for name in only_checks:
                    old_status = orig_summary['checks'].get(name, {}).get('status')
                    new_row = new_summary['checks'].get(name)
                    if not isinstance(new_row, dict) or not isinstance(new_row.get('status'), str):
                        summary_error = 'missing rerun status for ' + name
                        break
                    if new_row['status'] == 'not selected':
                        # A skipped check proves nothing; keep its previous result.
                        summary_error = 'rerun did not run ' + name
                        break
                    reruns.append({
                        'check': name,
                        'old_status': old_status,
                        'new_status': new_row['status'],
                        'time': now_ts,
                    })
                    orig_summary['checks'][name] = new_row
                if summary_error is None:
                    atomic_json(summary_path, orig_summary)
                else:
                    orig_summary = read_record(summary_path)
        rows = [('build', orig_summary['build']), *orig_summary['checks'].items()]
        failed = [name for name, row in rows if row.get('status') not in ('PASS', 'not selected')]
        if reason is None:
            if exit_code != 0:
                reason = 'verify exited with status ' + str(exit_code)
            elif summary_error:
                reason = summary_error
            elif failed:
                reason = 'merged summary contains unsuccessful checks'
    except KeyboardInterrupt:
        ignore_interrupts()
        reason = 'interrupted'
        if process is not None:
            stop_process(process)
            exit_code = process.returncode
        rows = [('build', orig_summary['build']), *orig_summary['checks'].items()]
        failed = [name for name, row in rows if row.get('status') not in ('PASS', 'not selected')]
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        reason = str(error)
        if process is not None and process.poll() is None:
            stop_process(process)
            exit_code = process.returncode
        rows = [('build', orig_summary['build']), *orig_summary['checks'].items()]
        failed = [name for name, row in rows if row.get('status') not in ('PASS', 'not selected')]
    record.update(state='pass' if reason is None and exit_code == 0 and not failed else 'fail',
                  finished_at=timestamp(), seconds=round(time.monotonic() - started, 3),
                  verify_exit=exit_code, artifacts=str(summary_path.parent), failed=failed,
                  reruns=reruns)
    record.setdefault('environment', {})
    if reason:
        record['reason'] = reason
    finish_record(results, record)
    return 0 if record['state'] == 'pass' else 1


def try_reuse(results, sha, gui):
    started = time.monotonic()
    try:
        ancestors = git('rev-list', '--first-parent', '--skip=1', '--max-count=30', sha).splitlines()
    except (OSError, RuntimeError, subprocess.SubprocessError):
        return None
    pass_sha = None
    pass_record = None
    for candidate in ancestors:
        if not HASH.fullmatch(candidate):
            continue
        try:
            rec = read_record(results / (candidate + '.json'))
        except (OSError, ValueError):
            continue
        if rec and rec.get('state') == 'pass':
            pass_sha = candidate
            pass_record = rec
            break
    if pass_sha is None:
        return None
    diff_paths = capture(['git', '-C', str(ROOT), 'diff', '--name-only', '--no-renames', '-z', pass_sha, sha],
                         timeout=30)
    if diff_paths.returncode != 0:
        return None
    changed = [path for path in diff_paths.stdout.split('\0') if path]
    allowed = {'CHANGELOG.md', 'config/dev.xcconfig', 'config/release.xcconfig'}
    if any(path not in allowed for path in changed):
        return None
    xcconfigs = [path for path in changed if path in ('config/dev.xcconfig', 'config/release.xcconfig')]
    if xcconfigs:
        diff_lines = capture(
            ['git', '-C', str(ROOT), 'diff', '-U0', '--no-color', '--no-renames', pass_sha, sha, '--', *xcconfigs],
            timeout=30,
        )
        if diff_lines.returncode != 0:
            return None
        for line in diff_lines.stdout.splitlines():
            if line.startswith(('+++ ', '--- ', '@@ ', 'diff ', 'index ', '\\ ')):
                continue
            if line.startswith(('old mode ', 'new mode ', 'deleted file ', 'new file ', 'Binary files ')):
                return None
            if line.startswith(('+', '-')) and not VERSION_LINE.fullmatch(line[1:]):
                return None
    try:
        verify_src = git('show', sha + ':scripts/verify.py', timeout=30)
        ns = {'__name__': 'verify_inspect', '__file__': str(ROOT / 'scripts/verify.py')}
        exec(compile(verify_src, str(ROOT / 'scripts/verify.py'), 'exec'), ns)
        checks = ns.get('CHECKS')
        match_fn = ns.get('matches')
        if not checks or not callable(match_fn):
            return None
        broad = ('project.yml', 'Tivano.xcodeproj/', 'scripts/verify.py')
        for path in changed:
            if any(match_fn(path, trigger) for trigger in broad):
                return None
            for item in checks:
                if any(match_fn(path, trigger) for trigger in item.triggers):
                    return None
    except Exception:
        return None
    # Coverage must match: a pass without GUI checks cannot stand in for a GUI run.
    if pass_record.get('gui') is not gui:
        return None
    current_env = environment()
    pass_env = pass_record.get('environment')
    if not isinstance(pass_env, dict) or not pass_env or pass_env != current_env:
        return None
    now_ts = timestamp()
    subject = git('show', '-s', '--format=%s', sha)
    record = {
        'sha': sha,
        'subject': subject,
        'state': 'pass',
        'started_at': now_ts,
        'finished_at': now_ts,
        'seconds': round(time.monotonic() - started, 3),
        'verify_exit': None,
        'artifacts': None,
        'failed': [],
        'environment': current_env,
        'reused_from': pass_sha,
        'gui': gui,
        'reason': 'version/changelog-only diff',
    }
    finish_record(results, record)
    return 0


def run_or_reuse(results, sha, gui, timeout, lock_fd, force=False):
    if not force:
        reused = try_reuse(results, sha, gui)
        if reused is not None:
            return reused
    return execute(results, sha, gui, timeout, lock_fd)


def load_request(request_path):
    mtime_ts = datetime.fromtimestamp(request_path.stat().st_mtime, tz=timezone.utc)
    data = {'sha': request_path.name, 'requested_at': mtime_ts.isoformat(timespec='seconds')}
    raw = request_path.read_text(encoding='utf-8').strip()
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                data.update(parsed)
        except ValueError:
            pass
    try:
        requested_dt = datetime.fromisoformat(data['requested_at'].replace('Z', '+00:00'))
    except (KeyError, ValueError, TypeError, AttributeError):
        requested_dt = mtime_ts
        data['requested_at'] = mtime_ts.isoformat(timespec='seconds')
    return data, requested_dt


def process_requests(results):
    requests_dir = results / 'requests'
    if not requests_dir.is_dir():
        clear_error(results)
        return None
    now = datetime.now(timezone.utc)
    selected = None
    last_error_msg = None
    entries = sorted(
        (p for p in requests_dir.iterdir() if not p.name.startswith('.')),
        key=lambda p: p.name,
    )
    for request in entries:
        if not HASH.fullmatch(request.name):
            request.unlink()
            continue
        req_data, requested_dt = load_request(request)
        only_raw = req_data.get('only')
        only_checks = None
        if only_raw is not None:
            try:
                only_checks = parse_only(only_raw)
            except ValueError:
                request.unlink()
                continue
        done = read_record(results / (request.name + '.json'))
        if only_checks:
            if done is None or done.get('state') != 'fail':
                request.unlink()
                continue
        elif done and done.get('state') in ('pass', 'fail'):
            request.unlink()
            continue
        try:
            git('cat-file', '-e', request.name + '^{commit}')
        except (OSError, RuntimeError, subprocess.SubprocessError):
            age = (now - requested_dt).total_seconds()
            if age > REQUEST_MAX_AGE_SECONDS:
                poll_log(results, 'requested commit not on the build host after 24h; dropping: ' + request.name)
                request.unlink()
            else:
                msg = 'requested commit not on the build host: ' + request.name
                poll_log(results, msg)
                req_data['error'] = msg
                req_data['last_error_at'] = timestamp()
                atomic_json(request, req_data)
                last_error_msg = msg
            continue
        if selected is None:
            selected = (request, only_checks)
    if last_error_msg:
        record_error(results, last_error_msg)
    else:
        clear_error(results)
    return selected


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
        expire_stale(results, timeout, lock_held=True)
        if args.command == 'poll':
            revision = 'refs/remotes/' + remote + '/' + branch
            overall = 0
            while not _interrupted:
                try:
                    git('fetch', remote, '--prune', timeout=120)
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    msg = 'fetch failed: ' + str(error)
                    poll_log(results, msg)
                    record_error(results, msg)
                    count = read_fetch_error_count(results) + 1
                    write_fetch_error_count(results, count)
                    if count > 3:
                        notify(results, state='error', reason=msg)
                    return overall
                clear_fetch_error_count(results)
                selected = process_requests(results)
                if selected is not None:
                    request_path, only_checks = selected
                    if only_checks:
                        try:
                            code = rerun_checks(results, request_path.name, only_checks, gui, timeout, lock.fileno())
                        except ValueError as error:
                            msg = 'invalid rerun request ' + request_path.name + ': ' + str(error)
                            poll_log(results, msg)
                            record_error(results, msg)
                            code = 1
                    else:
                        code = run_or_reuse(results, request_path.name, gui, timeout, lock.fileno())
                    if request_path.exists():
                        request_path.unlink()
                    if code != 0:
                        overall = 1
                    continue
                sha = git('rev-parse', '--verify', '--end-of-options', revision + '^{commit}')
                if not HASH.fullmatch(sha):
                    raise ValueError('expected a 40-character commit hash')
                previous = read_record(results / (sha + '.json'))
                if previous and previous.get('state') in ('pass', 'fail'):
                    break
                code = run_or_reuse(results, sha, gui, timeout, lock.fileno())
                if code != 0:
                    overall = 1
            return overall
        sha = git('rev-parse', '--verify', '--end-of-options', args.sha + '^{commit}')
        if not HASH.fullmatch(sha):
            raise ValueError('expected a 40-character commit hash')
        if getattr(args, 'only', None):
            only_checks = parse_only(args.only)
            return rerun_checks(results, sha, only_checks, gui, timeout, lock.fileno())
        previous = read_record(results / (sha + '.json'))
        if previous and previous.get('state') in ('pass', 'fail') and not getattr(args, 'force', False):
            return 0
        return run_or_reuse(results, sha, gui, timeout, lock.fileno(), force=getattr(args, 'force', False))


def status(sha):
    try:
        results = results_directory()
        record = read_record(results / (sha + '.json'))
        if record is None:
            result = {'sha': sha, 'state': 'missing'}
        else:
            if record.get('sha') != sha or record.get('state') not in ('pass', 'fail', 'running'):
                raise ValueError('invalid result record')
            result = {'sha': sha, 'state': record['state']}
            result.update({key: record[key] for key in STATUS_FIELDS if key in record})
        # A queued request (often a rerun of a failed record) means a newer attempt is coming.
        try:
            pending, _ = load_request(results / 'requests' / sha)
            result['pending'] = {key: pending[key] for key in ('requested_at', 'only', 'error') if key in pending}
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as error:
            result['pending'] = {'error': 'unreadable request: ' + str(error)}
        try:
            latest_error = read_record(results / 'latest-error.json')
            if isinstance(latest_error, dict) and latest_error:
                result['latest_error'] = latest_error
        except (OSError, ValueError) as error:
            result['latest_error'] = {'time': '', 'message': 'unreadable latest-error.json: ' + str(error)}
        return result
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        return {'sha': sha, 'state': 'fail', 'reason': 'status unavailable: ' + str(error)}


def running_sha_for_busy(results):
    try:
        latest = read_record(results / 'latest.json')
        if latest and latest.get('state') == 'running' and HASH.fullmatch(latest.get('sha', '')):
            return latest['sha']
        for path in sorted(results.glob('*.json')):
            if not HASH.fullmatch(path.stem):
                continue
            record = read_record(path)
            if record and record.get('state') == 'running':
                return record.get('sha') or path.stem
    except (OSError, ValueError):
        pass
    return None


def interrupted(signum, frame):
    global _interrupted
    _interrupted = True
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('poll', help='fetch the configured branch and check a new commit')
    manual = commands.add_parser('run', help='check an already-fetched commit')
    manual.add_argument('sha')
    manual_mode = manual.add_mutually_exclusive_group()
    manual_mode.add_argument('--force', action='store_true', help='rerun a completed commit')
    manual_mode.add_argument('--only', help='comma-separated check names to rerun on a failed record')
    query = commands.add_parser('status', help='print one JSON line for a full commit hash')
    query.add_argument('sha')
    commands.add_parser('latest', help='print the most recently written result')
    queued = commands.add_parser('request', help='queue a full commit hash for the next poll')
    queued.add_argument('sha')
    queued.add_argument('--only', help='comma-separated check names to rerun on a failed record')
    args = parser.parse_args()
    if args.command == 'status':
        if not HASH.fullmatch(args.sha):
            query.error('sha must be a full 40-character hexadecimal commit hash')
        print(json.dumps(status(args.sha.lower()), ensure_ascii=True))
        return 0
    if args.command == 'request':
        if not HASH.fullmatch(args.sha):
            queued.error('sha must be a full 40-character hexadecimal commit hash')
        sha = args.sha.lower()
        results = results_directory()
        only_checks = None
        if args.only is not None:
            try:
                only_checks = parse_only(args.only)
                rerun_preconditions(results, sha, only_checks)
            except (OSError, ValueError) as error:
                print('thor_ci: ' + str(error), file=sys.stderr)
                return 1
        requests = results / 'requests'
        requests.mkdir(parents=True, exist_ok=True)
        payload = {'sha': sha, 'requested_at': timestamp()}
        if only_checks:
            payload['only'] = only_checks
        atomic_json(requests / sha, payload)
        busy = False
        running_sha = None
        with (results / '.lock').open('a') as lock:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                busy = True
                running_sha = running_sha_for_busy(results)
        info = {'requested': sha, 'busy': busy, 'running_sha': running_sha}
        if only_checks:
            info['only'] = only_checks
        print(json.dumps(info, ensure_ascii=True))
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
