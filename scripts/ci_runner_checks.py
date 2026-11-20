#!/usr/bin/env python3
"""Offline checks for build-host CI runner, gate status contract and verify selection."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parent.parent

FAKE_VERIFY_SOURCE = r"""#!/usr/bin/env python3
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sys
import tempfile


@dataclass(frozen=True)
class Check:
    name: str
    triggers: tuple


CHECKS = (
    Check('src_check', ('src/',)),
)


def matches(path, trigger):
    return path == trigger.rstrip('/') or path.startswith(trigger.rstrip('/') + '/')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--only')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--gui', action='store_true')
    args = parser.parse_args()

    artifacts_root = Path(os.environ['TIVANO_ARTIFACTS_ROOT']).resolve()
    invocations_log = artifacts_root / 'verify-invocations.log'
    with invocations_log.open('a', encoding='utf-8') as handle:
        handle.write(json.dumps(sys.argv[1:]) + '\n')

    control_path = artifacts_root / 'fake-verify-control.json'
    control = {}
    if control_path.is_file():
        control = json.loads(control_path.read_text(encoding='utf-8'))

    runs_dir = artifacts_root / 'fake-verify-runs'
    runs_dir.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix='run-', dir=str(runs_dir))).resolve()

    only = set(args.only.split(',')) if args.only else None
    build_status = 'not selected' if args.skip_build else control.get('build', 'PASS')
    checks = {}
    for item in CHECKS:
        if only is not None and item.name not in only:
            checks[item.name] = {'status': 'not selected'}
        else:
            checks[item.name] = {'status': control.get(item.name, 'PASS')}

    summary = {
        'build': {'status': build_status},
        'checks': checks,
    }
    (run_dir / 'summary.json').write_text(json.dumps(summary) + '\n', encoding='utf-8')
    print('Artifacts: ' + str(run_dir))
    failed = [
        row['status']
        for row in [summary['build'], *checks.values()]
        if row['status'] not in ('PASS', 'not selected')
    ]
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
"""


class CheckFailure(RuntimeError):
    pass


def expect(condition, message):
    if not condition:
        raise CheckFailure(message)


def load_module(name, path):
    if not path.is_file():
        raise CheckFailure(f'missing expected file: {path}')
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise CheckFailure(f'cannot load module spec from {path}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_symbols(module, label, names):
    missing = [name for name in names if not hasattr(module, name)]
    if missing:
        raise CheckFailure(f'{label} is missing expected symbol(s): {", ".join(missing)}')


def git(repo, *args):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'):
        env.pop(key, None)
    result = subprocess.run(
        ['git', '-C', str(repo), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f'exit {result.returncode}'
        raise CheckFailure(f'git {" ".join(args)} failed in {repo}: {detail}')
    return result.stdout.strip()


def commit_and_push(seed_repo, ci_checkout, message, updates, fetch=True):
    for rel_path, content in updates.items():
        target = seed_repo / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding='utf-8')
    git(seed_repo, 'add', *updates.keys())
    git(seed_repo, 'commit', '-q', '-m', message)
    sha = git(seed_repo, 'rev-parse', 'HEAD')
    git(seed_repo, 'push', '-q', 'owner', 'dev')
    if fetch:
        git(ci_checkout, 'fetch', '-q', 'owner', '--prune')
    return sha


def invocation_count(log_path):
    if not log_path.is_file():
        return 0
    return len(log_path.read_text(encoding='utf-8').splitlines())


def set_verify_control(artifacts_root, **overrides):
    control_path = artifacts_root / 'fake-verify-control.json'
    control_path.write_text(json.dumps(overrides) + '\n', encoding='utf-8')


def run_namespace(**kwargs):
    defaults = {'command': 'run', 'sha': None, 'only': None, 'force': False}
    defaults.update(kwargs)
    return argparse.Namespace(**defaults)


def verify_namespace(**kwargs):
    defaults = {
        'only': None,
        'gui': False,
        'all': False,
        'slow': False,
        'skip_build': False,
        'build': False,
        'full_speed': False,
        'jobs': None,
        'isolated_derived_data': False,
    }
    defaults.update(kwargs)
    return argparse.Namespace(**defaults)


def setup_repos(temp_root):
    owner_repo = temp_root / 'owner.git'
    seed_repo = temp_root / 'seed'
    ci_checkout = temp_root / 'ci-checkout'

    owner_repo.mkdir()
    git(owner_repo, 'init', '--bare', '-q')
    git(owner_repo, 'symbolic-ref', 'HEAD', 'refs/heads/dev')

    seed_repo.mkdir()
    git(seed_repo, 'init', '-q', '-b', 'dev')
    git(seed_repo, 'config', 'user.name', 'CI Runner Check')
    git(seed_repo, 'config', 'user.email', 'ci-runner-check@example.invalid')
    git(seed_repo, 'config', 'commit.gpgsign', 'false')

    initial_files = {
        'scripts/verify.py': FAKE_VERIFY_SOURCE,
        'CHANGELOG.md': '## [Unreleased]\n',
        'config/dev.xcconfig': 'MARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 1\nOTHER_KEY = alpha\n',
        'src/app.txt': 'v1\n',
    }
    for rel_path, content in initial_files.items():
        target = seed_repo / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding='utf-8')
    git(seed_repo, 'add', '.')
    git(seed_repo, 'commit', '-q', '-m', 'Initial commit')
    git(seed_repo, 'remote', 'add', 'owner', str(owner_repo))
    git(seed_repo, 'push', '-q', 'owner', 'dev')

    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'):
        env.pop(key, None)
    clone = subprocess.run(
        ['git', 'clone', '-q', '--no-hardlinks', '--origin', 'owner', '--branch', 'dev',
         str(owner_repo), str(ci_checkout)],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if clone.returncode != 0:
        raise CheckFailure(f'git clone failed: {clone.stderr.strip() or clone.stdout.strip()}')

    git(ci_checkout, 'config', 'tivano.ci.owned', 'true')
    commit_a = git(seed_repo, 'rev-parse', 'HEAD')
    return seed_repo, ci_checkout, commit_a


def test_reuse(thor_ci, ci_gate, seed_repo, ci_checkout, artifacts_root, results, commit_a):
    invocations_log = artifacts_root / 'verify-invocations.log'
    set_verify_control(artifacts_root)

    before = invocation_count(invocations_log)
    expect(thor_ci.run(run_namespace(sha=commit_a)) == 0, 'commit A run must pass')
    expect(invocation_count(invocations_log) == before + 1, 'commit A must run verify')
    rec_a = thor_ci.read_record(results / (commit_a + '.json'))
    expect(rec_a is not None and rec_a.get('state') == 'pass', 'commit A record must be pass')
    expect(rec_a.get('artifacts') is not None, 'commit A must record artifacts')

    # Positive reuse: CHANGELOG.md + MARKETING_VERSION line only.
    commit_b = commit_and_push(
        seed_repo, ci_checkout, 'Bump version and changelog',
        {
            'CHANGELOG.md': '## [Unreleased]\n- Release prep\n',
            'config/dev.xcconfig': 'MARKETING_VERSION = 1.0.1\nCURRENT_PROJECT_VERSION = 1\nOTHER_KEY = alpha\n',
        },
    )
    before = invocation_count(invocations_log)
    expect(thor_ci.run(run_namespace(sha=commit_b)) == 0, 'commit B reuse must pass')
    expect(invocation_count(invocations_log) == before, 'commit B must reuse pass without running verify')
    rec_b = thor_ci.read_record(results / (commit_b + '.json'))
    expect(rec_b is not None and rec_b.get('state') == 'pass', 'commit B record must be pass')
    expect(rec_b.get('reused_from') == commit_a, f'commit B reused_from must be {commit_a}, got {rec_b.get("reused_from")}')
    parsed_b = ci_gate.parse_status(json.dumps(thor_ci.status(commit_b)), commit_b)
    expect(parsed_b.get('reused_from') == commit_a, 'ci_gate.parse_status must preserve reused_from')

    # Negative case: the nearest pass covered no GUI checks, so it cannot stand in for a GUI run.
    path_b = results / (commit_b + '.json')
    rec_b_nogui = dict(rec_b, gui=False)
    path_b.write_text(json.dumps(rec_b_nogui) + '\n', encoding='utf-8')
    commit_b2 = commit_and_push(
        seed_repo, ci_checkout, 'Changelog only after a non-GUI pass',
        {'CHANGELOG.md': '## [Unreleased]\n- Release prep 2\n'},
    )
    before = invocation_count(invocations_log)
    expect(thor_ci.run(run_namespace(sha=commit_b2)) == 0, 'commit B2 must pass by running verify')
    expect(invocation_count(invocations_log) == before + 1, 'pass without GUI coverage must not be reused')

    # Negative case 1: non-version xcconfig line.
    commit_c = commit_and_push(
        seed_repo, ci_checkout, 'Change non-version xcconfig line',
        {'config/dev.xcconfig': 'MARKETING_VERSION = 1.0.1\nCURRENT_PROJECT_VERSION = 1\nOTHER_KEY = beta\n'},
    )
    before = invocation_count(invocations_log)
    expect(thor_ci.run(run_namespace(sha=commit_c)) == 0, 'commit C must pass')
    expect(invocation_count(invocations_log) == before + 1, 'non-version xcconfig edit must run verify')
    rec_c = thor_ci.read_record(results / (commit_c + '.json'))
    expect('reused_from' not in rec_c, 'non-version xcconfig edit must not set reused_from')

    # Negative case 2: file under src/.
    commit_d = commit_and_push(
        seed_repo, ci_checkout, 'Change src file',
        {'src/app.txt': 'v2\n'},
    )
    before = invocation_count(invocations_log)
    expect(thor_ci.run(run_namespace(sha=commit_d)) == 0, 'commit D must pass')
    expect(invocation_count(invocations_log) == before + 1, 'src/ edit must run verify')
    rec_d = thor_ci.read_record(results / (commit_d + '.json'))
    expect('reused_from' not in rec_d, 'src/ edit must not set reused_from')

    # Negative case 3: differing environment.
    commit_e = commit_and_push(
        seed_repo, ci_checkout, 'Changelog only with changed env',
        {'CHANGELOG.md': '## [Unreleased]\n- Release prep\n- Second entry\n'},
    )
    orig_env_fn = thor_ci.environment
    thor_ci.environment = lambda: {'sw_vers': 'different', 'swift': 'different', 'git': 'different'}
    try:
        before = invocation_count(invocations_log)
        expect(thor_ci.run(run_namespace(sha=commit_e)) == 0, 'commit E must pass')
        expect(invocation_count(invocations_log) == before + 1, 'environment mismatch must run verify')
        rec_e = thor_ci.read_record(results / (commit_e + '.json'))
        expect('reused_from' not in rec_e, 'environment mismatch must not set reused_from')
    finally:
        thor_ci.environment = orig_env_fn


def test_rerun(thor_ci, ci_gate, seed_repo, ci_checkout, artifacts_root, results):
    commit_f = commit_and_push(
        seed_repo, ci_checkout, 'Commit for rerun check',
        {'src/app.txt': 'v3-fail-then-pass\n'},
    )
    set_verify_control(artifacts_root, build='PASS', src_check='FAIL')
    expect(thor_ci.run(run_namespace(sha=commit_f)) == 1, 'initial failing run must return 1')
    rec_fail = thor_ci.read_record(results / (commit_f + '.json'))
    expect(rec_fail is not None and rec_fail.get('state') == 'fail', 'initial record must be fail')
    expect(rec_fail.get('failed') == ['src_check'], f'expected failed=["src_check"], got {rec_fail.get("failed")}')
    expect(rec_fail.get('gui') is True, 'run record must store its GUI coverage')
    orig_artifacts = Path(rec_fail['artifacts'])

    with (results / '.lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)

        # Rerun when still failing stays fail.
        code_fail = thor_ci.rerun_checks(results, commit_f, ['src_check'], True, 60, lock.fileno())
        expect(code_fail == 1, 'rerun with src_check still failing must return 1')
        rec_still_fail = thor_ci.read_record(results / (commit_f + '.json'))
        expect(rec_still_fail.get('state') == 'fail', 'record must stay fail when rerun still fails')
        reruns_1 = rec_still_fail.get('reruns') or []
        expect(
            len(reruns_1) == 1
            and reruns_1[0].get('check') == 'src_check'
            and reruns_1[0].get('old_status') == 'FAIL'
            and reruns_1[0].get('new_status') == 'FAIL',
            f'unexpected reruns after failing rerun: {reruns_1}',
        )

        # A rerun that skips the requested check keeps its failure.
        set_verify_control(artifacts_root, build='PASS', src_check='not selected')
        expect(thor_ci.rerun_checks(results, commit_f, ['src_check'], True, 60, lock.fileno()) == 1,
               'rerun that did not run the check must return 1')
        rec_skip = thor_ci.read_record(results / (commit_f + '.json'))
        expect(rec_skip.get('state') == 'fail' and rec_skip.get('failed') == ['src_check'],
               f'skipped rerun must keep the failure, got {rec_skip}')
        skip_summary = json.loads((orig_artifacts / 'summary.json').read_text(encoding='utf-8'))
        expect(skip_summary['checks']['src_check']['status'] == 'FAIL', 'skipped rerun must not overwrite FAIL')
        expect(len(rec_skip.get('reruns') or []) == 1, 'skipped rerun must not add history')

        # A rerun with different GUI coverage or toolchain is refused.
        set_verify_control(artifacts_root, build='PASS', src_check='PASS')
        def refused(gui, needle):
            try:
                thor_ci.rerun_checks(results, commit_f, ['src_check'], gui, 60, lock.fileno())
            except ValueError as error:
                return needle in str(error)
            return False
        expect(refused(False, 'GUI coverage'), 'rerun with different GUI coverage must be refused')
        real_environment = thor_ci.environment
        thor_ci.environment = lambda: {'sw_vers': 'changed', 'swift': 'changed', 'git': 'changed'}
        try:
            expect(refused(True, 'toolchain changed'), 'rerun on a changed toolchain must be refused')
        finally:
            thor_ci.environment = real_environment
        expect(thor_ci.read_record(results / (commit_f + '.json')).get('state') == 'fail',
               'refused reruns must leave the fail record untouched')

        # Rerun when now passing turns record pass and merges summary.json.
        set_verify_control(artifacts_root, build='PASS', src_check='PASS')
        code_pass = thor_ci.rerun_checks(results, commit_f, ['src_check'], True, 60, lock.fileno())
        expect(code_pass == 0, 'rerun with src_check passing must return 0')
        rec_pass = thor_ci.read_record(results / (commit_f + '.json'))
        expect(rec_pass.get('state') == 'pass', 'record must turn pass after passing rerun')
        expect(rec_pass.get('failed') == [], f'passed rerun must clear failed list, got {rec_pass.get("failed")}')
        reruns_2 = rec_pass.get('reruns') or []
        expect(
            len(reruns_2) == 2
            and reruns_2[1].get('check') == 'src_check'
            and reruns_2[1].get('old_status') == 'FAIL'
            and reruns_2[1].get('new_status') == 'PASS',
            f'unexpected reruns after passing rerun: {reruns_2}',
        )
        merged_summary = json.loads((orig_artifacts / 'summary.json').read_text(encoding='utf-8'))
        expect(merged_summary['build']['status'] == 'PASS', 'merged summary build status must stay PASS')
        expect(merged_summary['checks']['src_check']['status'] == 'PASS', 'merged summary check status must be PASS')
        parsed_rerun = ci_gate.parse_status(json.dumps(thor_ci.status(commit_f)), commit_f)
        expect(len(parsed_rerun.get('reruns') or []) == 2, 'status must expose reruns history')

    # Rerun on a record with build not PASS raises ValueError (run outside the .lock holder).
    commit_g = commit_and_push(
        seed_repo, ci_checkout, 'Commit with build failure',
        {'src/app.txt': 'v4-build-fail\n'},
    )
    set_verify_control(artifacts_root, build='FAIL', src_check='PASS')
    expect(thor_ci.run(run_namespace(sha=commit_g)) == 1, 'build failure run must return 1')
    with (results / '.lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        raised = False
        try:
            thor_ci.rerun_checks(results, commit_g, ['src_check'], True, 60, lock.fileno())
        except ValueError:
            raised = True
        expect(raised, 'rerun_checks on a record with build not PASS must raise ValueError')


def test_stale(thor_ci, results):
    dead_proc = subprocess.Popen([sys.executable, '-c', 'pass'])
    dead_proc.wait(timeout=10)

    sha_dead = 'a' * 40
    sha_live = 'b' * 40
    host = socket.gethostname()

    # Hold .lock from a separate process while running expire_stale so only pid_is_gone can expire sha_dead,
    # and sha_live with a live pid stays running.
    holder_code = (
        'import fcntl, sys; '
        f'f = open({str(results / ".lock")!r}, "a"); '
        'fcntl.flock(f.fileno(), fcntl.LOCK_EX); '
        'sys.stdout.write("LOCKED\\n"); sys.stdout.flush(); '
        'sys.stdin.read()'
    )
    lock_holder = subprocess.Popen(
        [sys.executable, '-c', holder_code],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready = lock_holder.stdout.readline().strip()
        expect(ready == 'LOCKED', f'lock holder process failed to acquire lock: {ready!r}')

        thor_ci.save_record(results, {
            'sha': sha_dead,
            'state': 'running',
            'started_at': thor_ci.timestamp(),
            'subject': 'dead pid record',
            'pid': dead_proc.pid,
            'host': host,
        })
        thor_ci.save_record(results, {
            'sha': sha_live,
            'state': 'running',
            'started_at': thor_ci.timestamp(),
            'subject': 'live pid record',
            'pid': lock_holder.pid,
            'host': host,
        })

        thor_ci.expire_stale(results, timeout=10800)

        rec_dead = thor_ci.read_record(results / (sha_dead + '.json'))
        expect(
            rec_dead is not None and rec_dead.get('state') == 'fail' and rec_dead.get('reason') == 'stale',
            f'dead pid running record must become fail/stale, got {rec_dead}',
        )
        rec_live = thor_ci.read_record(results / (sha_live + '.json'))
        expect(
            rec_live is not None and rec_live.get('state') == 'running',
            f'live pid running record with held lock must stay running, got {rec_live}',
        )
    finally:
        if lock_holder.stdin:
            lock_holder.stdin.close()
        lock_holder.wait(timeout=10)
        for sha in (sha_dead, sha_live):
            path = results / (sha + '.json')
            if path.exists():
                path.unlink()


def test_queue_drain(thor_ci, ci_gate, seed_repo, ci_checkout, artifacts_root, results):
    set_verify_control(artifacts_root)
    req_sha_1 = commit_and_push(seed_repo, ci_checkout, 'Queued commit 1', {'src/app.txt': 'q1\n'}, fetch=False)
    req_sha_2 = commit_and_push(seed_repo, ci_checkout, 'Queued commit 2', {'src/app.txt': 'q2\n'}, fetch=False)
    tip_sha = commit_and_push(seed_repo, ci_checkout, 'Dev tip commit', {'src/app.txt': 'q3\n'}, fetch=False)
    missing_sha = 'e' * 40

    requests_dir = results / 'requests'
    requests_dir.mkdir(parents=True, exist_ok=True)
    for sha in (req_sha_1, req_sha_2, missing_sha):
        (requests_dir / sha).write_text(
            json.dumps({'sha': sha, 'requested_at': thor_ci.timestamp()}) + '\n',
            encoding='utf-8',
        )

    poll_code = thor_ci.run(run_namespace(command='poll'))
    expect(poll_code == 0, f'poll must exit 0 after draining valid requests and tip, got {poll_code}')

    for label, sha in (('req1', req_sha_1), ('req2', req_sha_2), ('tip', tip_sha)):
        rec = thor_ci.read_record(results / (sha + '.json'))
        expect(rec is not None and rec.get('state') == 'pass', f'{label} ({sha}) must be processed to pass')
    expect(not (requests_dir / req_sha_1).exists(), 'processed request 1 must be removed')
    expect(not (requests_dir / req_sha_2).exists(), 'processed request 2 must be removed')

    missing_req_path = requests_dir / missing_sha
    expect(missing_req_path.is_file(), 'request for unknown sha must be kept')
    missing_req = json.loads(missing_req_path.read_text(encoding='utf-8'))
    expect(
        isinstance(missing_req.get('error'), str) and missing_sha in missing_req['error'],
        f'unknown sha request must record error field, got {missing_req}',
    )
    latest_error = thor_ci.read_record(results / 'latest-error.json')
    expect(
        latest_error is not None and missing_sha in latest_error.get('message', ''),
        f'latest-error.json must record unknown sha error, got {latest_error}',
    )
    parsed_missing = ci_gate.parse_status(json.dumps(thor_ci.status(tip_sha)), tip_sha)
    expect('latest_error' in parsed_missing, 'status must attach latest_error when present')

    missing_req_path.unlink()
    (results / 'latest-error.json').unlink()


def test_notify(thor_ci, seed_repo, ci_checkout, artifacts_root, results):
    notify_log = artifacts_root / 'notify.log'
    notify_cmd = (
        f'printf "%s|%s|%s\\n" "$TIVANO_CI_STATE" "$TIVANO_CI_SHA" "$TIVANO_CI_FAILED" >> {shlex.quote(str(notify_log))}'
    )
    git(ci_checkout, 'config', 'tivano.ci.notify', notify_cmd)

    commit_h = commit_and_push(seed_repo, ci_checkout, 'Commit for notify fail', {'src/app.txt': 'notify-1\n'})
    set_verify_control(artifacts_root, build='PASS', src_check='FAIL')
    expect(thor_ci.run(run_namespace(sha=commit_h)) == 1, 'notify fail test run must return 1')
    expect(notify_log.is_file(), 'notify command must create notify.log')
    lines = notify_log.read_text(encoding='utf-8').splitlines()
    expect(
        lines == [f'fail|{commit_h}|src_check'],
        f'unexpected notify output: {lines}',
    )

    git(ci_checkout, 'config', 'tivano.ci.notify', 'echo notify-boom >&2; exit 42')
    commit_i = commit_and_push(seed_repo, ci_checkout, 'Commit for failing notify', {'src/app.txt': 'notify-2\n'})
    set_verify_control(artifacts_root)
    code = thor_ci.run(run_namespace(sha=commit_i))
    expect(code == 0, f'failing notify command must not change pass result, got {code}')
    rec_i = thor_ci.read_record(results / (commit_i + '.json'))
    expect(rec_i is not None and rec_i.get('state') == 'pass', 'record must remain pass when notify fails')
    poll_log_text = (results / 'poll.log').read_text(encoding='utf-8')
    expect('notify failed (42): notify-boom' in poll_log_text, f'poll.log must record failing notify, got: {poll_log_text}')


def test_verify_selection(real_verify):
    require_symbols(real_verify, 'scripts/verify.py', ('CHECKS', 'matches', 'selection', 'build_selection'))
    require_symbols(
        real_verify,
        'scripts/verify.py',
        ('resolve_default_base', 'resolve_throttle_policy', 'acquire_derived_data', 'low_priority_prefix'),
    )
    checks_by_name = {item.name: item for item in real_verify.CHECKS}
    for required_check in ('ci_runner_checks', 'standalone_task_checks', 'data_safety_audit_checks'):
        expect(required_check in checks_by_name, f'scripts/verify.py CHECKS is missing {required_check}')

    # Storage.swift triggers fast standalone_task_checks and slow data_safety_audit_checks.
    changed_storage = ['Tivano/Services/Store/Storage.swift']
    default_sel = real_verify.selection(verify_namespace(), changed_storage)
    expect(default_sel['standalone_task_checks']['selected'] is True, 'default mode must select matching fast check')
    expect(default_sel['data_safety_audit_checks']['selected'] is False, 'default mode must not select slow check')
    expect(
        default_sel['data_safety_audit_checks']['reason'] == 'slow: runs on build host (use --slow)',
        f'unexpected slow skip reason: {default_sel["data_safety_audit_checks"]}',
    )
    expect(
        all(not default_sel[c.name]['selected'] for c in real_verify.CHECKS if c.layer != 'fast'),
        'default mode must select only fast checks',
    )

    slow_sel = real_verify.selection(verify_namespace(slow=True), changed_storage)
    expect(slow_sel['data_safety_audit_checks']['selected'] is True, '--slow must select matching slow check')
    expect(slow_sel['standalone_task_checks']['selected'] is True, '--slow must keep matching fast check')

    all_sel = real_verify.selection(verify_namespace(all=True), changed_storage)
    expect(
        all(all_sel[c.name]['selected'] for c in real_verify.CHECKS if c.layer in ('fast', 'slow')),
        '--all must select all fast and slow checks',
    )
    expect(
        all(not all_sel[c.name]['selected'] for c in real_verify.CHECKS if c.layer == 'gui'),
        '--all without --gui must not select gui checks',
    )

    build_scripts, _ = real_verify.build_selection(verify_namespace(), ['scripts/thor_ci.py'])
    expect(build_scripts is False, 'change only under scripts/ must not select build')
    build_tivano, _ = real_verify.build_selection(verify_namespace(), ['Tivano/App/AppModel.swift'])
    expect(build_tivano is True, 'change under Tivano/ must select build')


def test_verify_local_ergonomics(real_verify, temp_root):
    r = temp_root / 'base-detect'
    r.mkdir()
    git(r, 'init', '-q', '-b', 'dev')
    git(r, 'config', 'user.name', 'CI Runner Check')
    git(r, 'config', 'user.email', 'ci-runner-check@example.invalid')
    git(r, 'config', 'commit.gpgsign', 'false')

    def commit_file(rel_path, content, message):
        target = r / rel_path
        target.write_text(content, encoding='utf-8')
        git(r, 'add', rel_path)
        git(r, 'commit', '-q', '-m', message)
        return git(r, 'rev-parse', 'HEAD')

    # Auto-base detection.
    commit_file('dev.txt', 'dev0\n', 'c_dev0')
    base = real_verify.resolve_default_base(repo=r)
    expect(base == 'dev', f'expected dev on initial dev branch, got {base!r}')

    git(r, 'checkout', '-q', '-b', 'preview')
    commit_file('pre.txt', 'pre1\n', 'c_pre1')
    base = real_verify.resolve_default_base(repo=r)
    expect(base == 'preview', f'expected preview on preview branch, got {base!r}')

    git(r, 'checkout', '-q', '-b', 'task-pre', 'preview')
    commit_file('pre.txt', 'pre2\n', 'c_pre2')
    base = real_verify.resolve_default_base(repo=r)
    expect(base == 'preview', f'expected preview on task-pre branch, got {base!r}')

    git(r, 'checkout', '-q', 'dev')
    commit_file('dev.txt', 'dev1\n', 'c_dev1')
    git(r, 'checkout', '-q', '-b', 'task-dev', 'dev')
    commit_file('dev.txt', 'dev2\n', 'c_dev2')
    base = real_verify.resolve_default_base(repo=r)
    expect(base == 'dev', f'expected dev on task-dev branch, got {base!r}')

    git(r, 'checkout', '-q', '-b', 'squash-to-dev', 'dev')
    git(r, 'merge', '-q', '--squash', 'preview')
    git(r, 'commit', '-q', '-m', 'squash preview onto dev')
    base = real_verify.resolve_default_base(repo=r)
    expect(base == 'dev', f'expected dev after squash-merging preview onto dev, got {base!r}')

    # Throttle policy on non-CI repo.
    default_policy = real_verify.resolve_throttle_policy(
        verify_namespace(), repo=r, environ={}, cpu_count=10, platform_name='darwin',
    )
    expect(
        default_policy == {'full_speed': False, 'low_priority': True, 'jobs': 8},
        f'unexpected default throttle policy: {default_policy}',
    )

    full_speed_flag = real_verify.resolve_throttle_policy(
        verify_namespace(full_speed=True), repo=r, environ={}, cpu_count=10, platform_name='darwin',
    )
    expect(
        full_speed_flag == {'full_speed': True, 'low_priority': False, 'jobs': 0},
        f'unexpected full_speed=True throttle policy: {full_speed_flag}',
    )

    full_speed_env = real_verify.resolve_throttle_policy(
        verify_namespace(), repo=r, environ={'TIVANO_VERIFY_FULL_SPEED': '1'},
        cpu_count=10, platform_name='darwin',
    )
    expect(
        full_speed_env == {'full_speed': True, 'low_priority': False, 'jobs': 0},
        f'unexpected TIVANO_VERIFY_FULL_SPEED throttle policy: {full_speed_env}',
    )

    git(r, 'config', 'tivano.verify.fullSpeed', 'true')
    try:
        full_speed_cfg = real_verify.resolve_throttle_policy(
            verify_namespace(), repo=r, environ={}, cpu_count=10, platform_name='darwin',
        )
        expect(
            full_speed_cfg == {'full_speed': True, 'low_priority': False, 'jobs': 0},
            f'unexpected tivano.verify.fullSpeed throttle policy: {full_speed_cfg}',
        )
    finally:
        git(r, 'config', '--unset', 'tivano.verify.fullSpeed')

    git(r, 'config', 'tivano.ci.owned', 'true')
    try:
        ci_policy = real_verify.resolve_throttle_policy(
            verify_namespace(), repo=r, environ={}, cpu_count=10, platform_name='darwin',
        )
        expect(
            ci_policy == {'full_speed': True, 'low_priority': False, 'jobs': 0},
            f'unexpected CI throttle policy: {ci_policy}',
        )
    finally:
        git(r, 'config', '--unset', 'tivano.ci.owned')

    jobs_policy = real_verify.resolve_throttle_policy(
        verify_namespace(jobs=6), repo=r, environ={}, cpu_count=10, platform_name='darwin',
    )
    expect(jobs_policy.get('jobs') == 6, f'expected jobs=6, got {jobs_policy}')

    bad_jobs_raised = False
    try:
        real_verify.resolve_throttle_policy(
            verify_namespace(jobs=-1), repo=r, environ={}, cpu_count=10, platform_name='darwin',
        )
    except ValueError:
        bad_jobs_raised = True
    expect(bad_jobs_raised, 'jobs=-1 must raise ValueError')

    expect(
        real_verify.low_priority_prefix(False, 'darwin') == [],
        'low_priority_prefix(False, "darwin") must return []',
    )
    darwin_prefix = real_verify.low_priority_prefix(True, 'darwin')
    expect('-b' not in darwin_prefix, f'low_priority_prefix must never contain -b, got {darwin_prefix}')
    if Path('/usr/sbin/taskpolicy').exists():
        expect(
            'utility' in darwin_prefix,
            f'low_priority_prefix(True, "darwin") must include utility, got {darwin_prefix}',
        )

    def close_fd(fd):
        if fd is None:
            return
        if hasattr(fd, 'close'):
            fd.close()
        else:
            os.close(fd)

    # Shared DerivedData lock and fallback.
    art = temp_root / 'ext-art'
    p1, fd1, m1 = real_verify.acquire_derived_data(art, repo=r, environ={})
    try:
        expect(m1 == 'shared', f'expected shared mode, got {m1!r}')
        expect(fd1 is not None, 'expected open fd for shared DerivedData')
        expect(
            str(p1).endswith('private-artifacts/verify-derived.noindex'),
            f'unexpected shared DerivedData path: {p1!r}',
        )

        p2, fd2, m2 = real_verify.acquire_derived_data(art, repo=r, environ={})
        try:
            expect(fd2 is None, f'expected fd is None when shared lock is busy, got {fd2!r}')
            expect('shared busy' in m2, f'expected "shared busy" in mode, got {m2!r}')
            expect(
                str(p2).endswith('build.noindex/verify-derived'),
                f'unexpected fallback DerivedData path: {p2!r}',
            )
        finally:
            close_fd(fd2)
    finally:
        close_fd(fd1)

    p3, fd3, m3 = real_verify.acquire_derived_data(art, repo=r, environ={})
    try:
        expect(m3 == 'shared', f'expected shared mode after lock release, got {m3!r}')
        expect(fd3 is not None, 'expected open fd after lock release')
    finally:
        close_fd(fd3)

    _, fd_iso, m_iso = real_verify.acquire_derived_data(art, isolated=True, repo=r, environ={})
    try:
        expect(m_iso == 'worktree-local', f'expected worktree-local for isolated=True, got {m_iso!r}')
        expect(fd_iso is None, f'expected fd is None for isolated=True, got {fd_iso!r}')
    finally:
        close_fd(fd_iso)

    git(r, 'config', 'tivano.ci.owned', 'true')
    try:
        _, fd_ci, m_ci = real_verify.acquire_derived_data(art, repo=r, environ={})
        try:
            expect(m_ci == 'worktree-local', f'expected worktree-local for CI repo, got {m_ci!r}')
            expect(fd_ci is None, f'expected fd is None for CI repo, got {fd_ci!r}')
        finally:
            close_fd(fd_ci)
    finally:
        git(r, 'config', '--unset', 'tivano.ci.owned')


def test_pending_wait(thor_ci, ci_gate, results):
    failed = None
    for path in sorted(results.glob('*.json')):
        record = thor_ci.read_record(path) if thor_ci.HASH.fullmatch(path.stem) else None
        if record and record.get('state') == 'fail':
            failed = path.stem
            break
    expect(failed is not None, 'pending-wait test needs a fail record from earlier tests')
    request = results / 'requests' / failed
    request.parent.mkdir(parents=True, exist_ok=True)
    request.write_text(json.dumps({'sha': failed, 'only': ['src_check']}) + '\n', encoding='utf-8')
    try:
        pending_status = thor_ci.status(failed)
    finally:
        request.unlink()
    expect((pending_status.get('pending') or {}).get('only') == ['src_check'],
           f'status must expose a queued rerun, got {pending_status}')
    expect('pending' not in thor_ci.status(failed), 'status must drop pending once the request is gone')

    replies = [dict(pending_status), dict(pending_status),
               {'sha': failed, 'state': 'pass', 'finished_at': 'now'}]
    real_remote, real_interval = ci_gate.remote_status, ci_gate.POLL_INTERVAL
    ci_gate.remote_status = lambda config, sha, timeout=None: json.dumps(replies.pop(0))
    ci_gate.POLL_INTERVAL = 0
    try:
        code = ci_gate.check(('host', '/r', '/e', 'label'), failed, True, 60)
        expect(code == 0 and not replies, 'check --wait must wait past a failure with a queued rerun')
        replies[:] = [{'sha': failed, 'state': 'fail', 'failed': ['src_check']}]
        expect(ci_gate.check(('host', '/r', '/e', 'label'), failed, True, 60) == 1,
               'check --wait must stop on a failure with nothing queued')
    finally:
        ci_gate.remote_status, ci_gate.POLL_INTERVAL = real_remote, real_interval


def main():
    temp_root = Path(tempfile.mkdtemp(prefix='tivano-ci-runner-')).resolve()
    artifacts_root = Path(tempfile.mkdtemp(prefix='tivano-ci-artifacts-')).resolve()
    orig_ci_repo = os.environ.get('TIVANO_CI_REPO')
    orig_artifacts = os.environ.get('TIVANO_ARTIFACTS_ROOT')
    try:
        seed_repo, ci_checkout, commit_a = setup_repos(temp_root)
        os.environ['TIVANO_CI_REPO'] = str(ci_checkout)
        os.environ['TIVANO_ARTIFACTS_ROOT'] = str(artifacts_root)

        thor_ci = load_module('thor_ci', REPO_ROOT / 'scripts/thor_ci.py')
        require_symbols(
            thor_ci, 'scripts/thor_ci.py',
            ('ROOT', 'results_directory', 'run', 'rerun_checks', 'expire_stale',
             'environment', 'read_record', 'save_record', 'status', 'timestamp'),
        )
        expect(thor_ci.ROOT == ci_checkout, f'thor_ci.ROOT ({thor_ci.ROOT}) must equal temp checkout ({ci_checkout})')
        results = thor_ci.results_directory()
        expect(
            results == (artifacts_root / 'ci-results').resolve(),
            f'results_directory ({results}) must stay inside temp artifacts root ({artifacts_root})',
        )

        ci_gate = load_module('ci_gate', REPO_ROOT / 'scripts/ci_gate.py')
        require_symbols(ci_gate, 'scripts/ci_gate.py', ('parse_status', 'normalize_only', 'executor_command'))

        real_verify = load_module('real_verify', REPO_ROOT / 'scripts/verify.py')

        test_reuse(thor_ci, ci_gate, seed_repo, ci_checkout, artifacts_root, results, commit_a)
        test_rerun(thor_ci, ci_gate, seed_repo, ci_checkout, artifacts_root, results)
        test_stale(thor_ci, results)
        test_queue_drain(thor_ci, ci_gate, seed_repo, ci_checkout, artifacts_root, results)
        test_notify(thor_ci, seed_repo, ci_checkout, artifacts_root, results)
        test_pending_wait(thor_ci, ci_gate, results)
        test_verify_selection(real_verify)
        test_verify_local_ergonomics(real_verify, temp_root)
    except CheckFailure as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    finally:
        if orig_ci_repo is None:
            os.environ.pop('TIVANO_CI_REPO', None)
        else:
            os.environ['TIVANO_CI_REPO'] = orig_ci_repo
        if orig_artifacts is None:
            os.environ.pop('TIVANO_ARTIFACTS_ROOT', None)
        else:
            os.environ['TIVANO_ARTIFACTS_ROOT'] = orig_artifacts
        shutil.rmtree(temp_root, ignore_errors=True)
        shutil.rmtree(artifacts_root, ignore_errors=True)

    print('OK: CI runner reuse, rerun, stale, queue drain, notify and verify selection checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
