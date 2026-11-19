#!/usr/bin/env python3
"""Compile real DSH/ACP Swift sources and run offline fault cases (macOS).

Run: python3 scripts/dsh_adapter_stress.py
Artifacts: build.noindex/dsh-adapter/run-*/summary.json and kit/sources.json.
No application launch, real DSH, credentials, network or shortened deadlines.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

CASES = {
    'two-turns': 'Two sequential turns each complete once, including duplicate RPC replies.',
    'resume-auth': 'Authentication error is surfaced; never silently create new history.',
    'resume-lock': 'Locked history is surfaced; never silently create new history.',
    'resume-missing': 'Explicitly missing history requires user choice; no silent session/new.',
    'mixed-mcp': 'Surface mixed MCP failure or retry selectively, retaining healthy server.',
    'wrong-session': 'Foreign session messages and permission requests produce no user events.',
    'selection-timeout': 'Unanswered model selection fails within the external 60-second budget, without a turn.',
    'probe-timeout': 'Unanswered effort switches keep the listed models; the probe ends within its 180-second deadline (ffd3ce0a4).',
    'late-input': 'Approval includes command arguments supplied by later tool_call_update.',
    'failed-edit': 'Failed edit with unchanged disk has no actual edits in final tool state.',
    'failed-write': 'Failed write with unchanged disk has no actual edits in final tool state.',
    'typed-ids': 'Integer 1 and string 1 have independent approval identities and wire decisions.',
    'parallel': 'Two live adapters receive only their own events and completions.',
    'cancel': 'interrupt cancels permission, resolves it once, and completes interrupted once.',
    'repeat-start': 'Repeated start followed by stopAndWait leaves no live peer.',
    'default-model': 'A non-Pro current model remains the default without unrequested selection.',
    'probe-unusable-route': 'Preserve Flash on the usable account route, with no fabricated API key or invalid restore.',
    'probe': 'Public probeModels returns both advertised models and reclaims its peer.',
    'resume-timeout': 'Unanswered resume fails without creating replacement history.',
    'resume-unsupported': 'Missing resume capability fails without creating replacement history.',
    'resume-permission': 'Old-session permission during resume is never automatically allowed.',
    'startup-failure': 'Failed initialize reclaims its peer before caller cleanup.',
    'bridge-disposed': 'Disposed ACP bridge fails the turn and retires the still-running dsh session.',
    'final-report': 'Report-only launch and readiness dispatch a completed simulated report; actual guard tested separately.',
    'report-guard-missing': 'Missing report guard readiness refuses to dispatch prompt.',
    'credential-records': 'Only a nonempty canonical local account grant counts as local sign-in evidence.',
    'patch-validation': 'Patch checks rerun after changes and exempt only the exact optional row/file.',
    'incremental-kind': 'Title-only updates retain protocol tool kind.',
    'dsh-bash-exit': 'DSH bash terminal exit marker is presented as failure; metadata, body text and PTC remain distinct.',
    'acp-bash-exit': 'DSH text-only exit interpretation does not affect another ACP provider.',
    'probe-default': 'Full catalog probe preserves the advertised non-Pro default.',
    'cancel-rebuild': 'Repeated cancellation and replacement complete each turn once.',
    'event-flood': 'Burst of 2000 messages and duplicate responses completes once without loss.',
    'acp-selection': 'Simulated non-DSH ACP selection and message delivery.',
    'acp-permission': 'Simulated non-DSH ACP permission roundtrip.',
    'acp-cancel': 'Simulated non-DSH ACP cancellation resolves once.',
}


def darwin_user_temp_dir():
    return Path(subprocess.check_output(['/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip()).resolve()


def sandbox_policy(out, *extra, temp=None):
    """Offline sandbox: writes stay in the run/case directory (plus any extra paths), plus
    two per-user temporary paths production code uses regardless of TMPDIR: Foundation's
    atomic-write staging (TemporaryItems) and ACPSession.probeModels' tivano-catalog working
    directory. Without them those writes fail silently, and probes pass only on hosts where
    the catalog directory happens to exist already.
    tivano-catalog is safe across concurrent probe cases: ACPSession.probeModels only calls
    createDirectory(withIntermediateDirectories: true) and sets cwd to it; neither the
    harness nor fake_dsh.py reads or writes files inside it (all test I/O uses DSH_TEST_ROOT)."""
    resolved_temp = darwin_user_temp_dir() if temp is None else temp
    allowed = ' '.join('(subpath ' + json.dumps(str(path)) + ')'
                       for path in (out, *extra, resolved_temp / 'TemporaryItems', resolved_temp / 'tivano-catalog'))
    return ('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n'
            '(allow file-write* ' + allowed + ' (literal "/dev/null"))\n')


def pack_case_budgets(selected, case_budget, jobs, default_budget=60, margin=10):
    """Longest-case-first packing of per-case budgets (with margin) over worker count."""
    if not selected:
        return 0
    slots = sorted((case_budget.get(name, default_budget) + margin for name in selected), reverse=True)
    loads = [0] * max(1, min(jobs, len(slots)))
    for slot in slots:
        idx = min(range(len(loads)), key=loads.__getitem__)
        loads[idx] += slot
    return max(max(loads), slots[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', action='append', choices=CASES, help='Run selected case(s); default all')
    parser.add_argument('--jobs', type=int, default=None, help='Concurrent case workers; default min(4, len(cases))')
    args = parser.parse_args()
    if args.jobs is not None and args.jobs < 1:
        parser.error('--jobs must be at least 1')
    if sys.platform != 'darwin':
        parser.error('macOS with Xcode Swift compiler required')
    if not Path('/usr/bin/sandbox-exec').exists():
        parser.error('sandbox-exec required; refusing an unsandboxed run')
    root = Path(__file__).resolve().parents[1]
    parent = root / 'build.noindex/dsh-adapter'
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    kit = out / 'kit'
    shutil.copytree(root / 'scripts/fixtures/dsh_adapter', kit)
    temp_dir = darwin_user_temp_dir()
    python = str(Path(sys.executable).resolve())
    # Use the same interpreter, not whichever python an inherited PATH selects.
    peer = kit / 'fake-dsh'
    peer.write_text('#!/bin/sh\nexec ' + shlex.quote(python) + ' '
                    + shlex.quote(str(kit / 'fake_dsh.py')) + ' "$@"\n')
    peer.chmod(0o700)

    def environment(directory):
        for name in ('home', 'dsh-home', 'tmp', 'cache'):
            (directory / name).mkdir(parents=True, exist_ok=True)
        env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(directory / 'home'),
               'DSH_HOME': str(directory / 'dsh-home'), 'TMPDIR': str(directory / 'tmp') + '/',
               'XDG_CACHE_HOME': str(directory / 'cache'), 'PYTHONDONTWRITEBYTECODE': '1',
               'CLANG_MODULE_CACHE_PATH': str(directory / 'cache'), 'DSH_TEST_ROOT': str(directory),
               'DSH_TELEMETRY_DISABLED': '1', 'LANG': 'en_US.UTF-8'}
        if 'DEVELOPER_DIR' in os.environ:
            env['DEVELOPER_DIR'] = os.environ['DEVELOPER_DIR']
        return env

    def run(command, directory, timeout, env, policy):
        started = time.monotonic()
        expired = False
        with (directory / 'process.log').open('w') as log:
            process = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(policy)] + command,
                                       cwd=directory, env=env, start_new_session=True,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                expired = True
                # The unreaped child still owns this group ID. Fixtures never detach;
                # their unique lease also handles Foundation-created process groups.
                (directory / 'lease').unlink(missing_ok=True)
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
            finally:
                (directory / 'lease').unlink(missing_ok=True)
        return {'exit': process.returncode, 'timeout': expired, 'seconds': time.monotonic() - started}

    selected = list(dict.fromkeys(args.case or list(CASES)))
    jobs = min(4 if args.jobs is None else args.jobs, len(selected))
    # probe-timeout waits out one 45-second switch deadline per model.
    case_budget = {'probe-timeout': 200}
    deadline = time.monotonic() + 180 + pack_case_budgets(selected, case_budget, jobs)
    results = []
    summary = {'artifacts': str(out), 'results': results, 'passed': False}

    def run_case(name):
        directory = out / name
        env = environment(directory)
        env['DSH_TEST_CASE'] = name
        case_policy = directory / 'offline.sb'
        case_policy.write_text(sandbox_policy(directory, temp=temp_dir))
        (directory / 'lease').write_text(str(out))
        (directory / 'unchanged.txt').write_text('before')
        try:
            budget = min(case_budget.get(name, 60), max(0, deadline - time.monotonic()))
            if budget <= 0:
                raise RuntimeError('Global run budget exhausted')
            stage = run([str(kit / 'adapter'), str(peer)], directory, budget, env, case_policy)
        except Exception as error:
            (directory / 'lease').unlink(missing_ok=True)
            stage = {'exit': None, 'timeout': False, 'error': str(error)}
        result_path = directory / 'result.json'
        try:
            row = json.loads(result_path.read_text()) if result_path.exists() else {
                'name': name, 'passed': False, 'error': 'No harness result'}
        except (ValueError, OSError) as error:
            row = {'name': name, 'passed': False, 'error': str(error)}
        row.update(expected=CASES[name], process=stage, providerEvidence='simulated ACP peer, not a real provider')
        row['passed'] = row.get('passed') is True and stage['exit'] == 0 and not stage['timeout']
        if stage['timeout']:
            row['error'] = f"External timeout ({case_budget.get(name, 60)} seconds); production deadlines unchanged"
        if 'observed' not in row:
            frames = []
            for path in directory.glob('wire-*.jsonl'):
                for line in path.read_text().splitlines():
                    try:
                        frames.append(json.loads(line))
                    except ValueError:
                        frames.append({'partialFrame': line})
            row['observed'] = {'wire': frames}
        # Revoking only this case's lease asks any orphan fixture to exit itself.
        # Never locate or kill unrelated processes by executable name or stale PID.
        until = time.monotonic() + 2
        while list(directory.glob('alive-*')) and time.monotonic() < until:
            time.sleep(0.1)
        remaining = [p.name for p in directory.glob('alive-*')]
        if remaining:
            row['passed'] = False
            row['cleanupUnconfirmed'] = remaining
        return row

    try:
        sources = runpy.run_path(str(kit / 'prepare.py'))['prepare'](root, kit)
        compile_dir = out / 'compile'
        env = environment(compile_dir)
        compile_policy = compile_dir / 'offline.sb'
        compile_policy.write_text(sandbox_policy(compile_dir, kit, temp=temp_dir))
        command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                   '-target', 'arm64-apple-macos15.0', '-module-name', 'DSHAdapterStress', '-module-cache-path', str(compile_dir / 'cache'),
                   '-o', str(kit / 'adapter')] + sources
        (kit / 'compile-command.json').write_text(json.dumps(command, indent=2) + '\n')
        stage = run(command, compile_dir, 180, env, compile_policy)
        summary['compile'] = stage
        if stage['exit'] or stage['timeout']:
            raise RuntimeError('Compilation failed; see compile/process.log')
        if jobs == 1:
            for name in selected:
                row = run_case(name)
                results.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
        else:
            order = sorted(range(len(selected)), key=lambda idx: (-case_budget.get(selected[idx], 60), idx))
            completed = {}
            next_index = 0
            with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
                futures = {executor.submit(run_case, selected[idx]): idx for idx in order}
                for future in concurrent.futures.as_completed(futures):
                    idx = futures[future]
                    completed[idx] = future.result()
                    while next_index in completed:
                        row = completed.pop(next_index)
                        results.append(row)
                        print(json.dumps(row, ensure_ascii=False), flush=True)
                        next_index += 1
        summary['passed'] = all(row['passed'] for row in results)
    except Exception as error:
        summary['error'] = str(error)
        completed = {row['name'] for row in results}
        for name in selected:
            if name not in completed:
                results.append({'name': name, 'expected': CASES[name], 'observed': 'not run',
                                'passed': False, 'error': 'Setup/compile blocked'})
    (out / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
