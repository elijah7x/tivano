#!/usr/bin/env python3
"""Compile real DSH/ACP Swift sources and run offline fault cases (macOS).

Run: python3 scripts/dsh_adapter_stress.py
Artifacts: build.noindex/dsh-adapter/run-*/summary.json and kit/sources.json.
No application launch, real DSH, credentials, network or shortened deadlines.
"""
import argparse
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
    'probe-timeout': 'Unanswered catalog selection fails within the external 60-second budget.',
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', action='append', choices=CASES, help='Run selected case(s); default all')
    args = parser.parse_args()
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
    policy = out / 'offline.sb'
    policy.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n'
                      '(allow file-write* (subpath ' + json.dumps(str(out)) + ') (literal "/dev/null"))\n')
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

    def run(command, directory, timeout, env):
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
    deadline = time.monotonic() + 180 + len(selected) * 70
    results = []
    summary = {'artifacts': str(out), 'results': results, 'passed': False}
    try:
        sources = runpy.run_path(str(kit / 'prepare.py'))['prepare'](root, kit)
        compile_dir = out / 'compile'
        env = environment(compile_dir)
        command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                   '-target', 'arm64-apple-macos15.0', '-module-name', 'DSHAdapterStress', '-module-cache-path', str(compile_dir / 'cache'),
                   '-o', str(kit / 'adapter')] + sources
        (kit / 'compile-command.json').write_text(json.dumps(command, indent=2) + '\n')
        stage = run(command, compile_dir, 180, env)
        summary['compile'] = stage
        if stage['exit'] or stage['timeout']:
            raise RuntimeError('Compilation failed; see compile/process.log')
        for name in selected:
            directory = out / name
            env = environment(directory)
            env['DSH_TEST_CASE'] = name
            (directory / 'lease').write_text(str(out))
            (directory / 'unchanged.txt').write_text('before')
            try:
                budget = min(60, max(0, deadline - time.monotonic()))
                if budget <= 0:
                    raise RuntimeError('Global run budget exhausted')
                stage = run([str(kit / 'adapter'), str(peer)], directory, budget, env)
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
                row['error'] = 'External timeout (60 seconds); production deadlines unchanged'
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
            results.append(row)
            print(json.dumps(row, ensure_ascii=False), flush=True)
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
