#!/usr/bin/env python3
"""Plan by default; --run launches only the explicitly supplied Dev bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import uuid

IDENTITY = 'tivano-dsh-offline-hydra-v1'
HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def budget_seconds(name):
    source = (SOURCE / 'Tivano/Core/Models/Hydra.swift').read_text()
    match = re.search(r'static let ' + name + r': TimeInterval = (\d+) \* 60\b', source)
    if not match:
        raise RuntimeError('Unknown production budget syntax; do not guess a timeout')
    return int(match[1]) * 60


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--source-revision', required=True, help='Operator-attested revision used to build this bundle')
    parser.add_argument('--dsh-offline-hydra-budget', action='store_true')
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    app = args.app.expanduser().resolve(strict=True)
    if app.name != 'Tivano Dev.app' or Path('/Applications') in app.parents:
        raise RuntimeError('Supply a separate task-built Tivano Dev.app, never an installed application')
    protected = [Path.home() / '.dsh', Path.home() / '.tivano-dev', Path.home() / 'Library', Path('/Applications')]
    if any(output == p.resolve() or p.resolve() in output.parents for p in protected):
        raise RuntimeError('Output must not be inside account, installed-app or Library storage')
    if app == output or app in output.parents or output in app.parents:
        raise RuntimeError('App and output must not contain one another')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    binary = (app / 'Contents/MacOS' / info['CFBundleExecutable']).resolve()
    if not binary.is_file() or app not in binary.parents or info.get('CFBundleIdentifier') != 'dev.tivano.Tivano.dev':
        raise RuntimeError('Expected a contained executable in the explicit Dev edition')
    if IDENTITY.encode() not in binary.read_bytes():
        raise RuntimeError('This binary does not contain the DEBUG offline Hydra probe')
    maximum, report = budget_seconds('maxSeconds'), budget_seconds('reportSeconds')
    timeout = maximum + report + 180 if args.dsh_offline_hydra_budget else 240
    command = [str(binary), '--website-captures', str(output), '--dsh-integration-probe',
               '--dsh-offline-hydra-probe', '--dsh-test-executable', str(output / 'fixture/fake-cli'),
               '--dsh-test-home', str(output / 'fixture/home')]
    if args.dsh_offline_hydra_budget:
        command.append('--dsh-offline-hydra-budget')
    plan = {'command': command, 'timeoutSeconds': timeout, 'sourceRevisionAttestation': args.source_revision,
            'scenario': 'budget' if args.dsh_offline_hydra_budget else 'quick',
            'mode': 'run' if args.run else 'plan-only',
            'binary': str(binary), 'binarySHA256': digest(binary),
            'bundleID': info.get('CFBundleIdentifier'), 'version': info.get('CFBundleShortVersionString'),
            'sourceSHA256': {str(p.relative_to(SOURCE)): digest(p) for p in [
                SOURCE / 'Tivano/App/Captures/DshHydraIntegrationProbe.swift',
                SOURCE / 'Tivano/App/Captures/WebsiteCaptures.swift',
                SOURCE / 'Tivano/App/Runtime/ThreadRuntime.swift',
                SOURCE / 'Tivano/App/AppModel+Hydra.swift',
                SOURCE / 'Tivano/Services/Providers/ProviderRegistry.swift',
                SOURCE / 'Tivano/Core/Models/Hydra.swift', HERE / 'fake_dsh.py', HERE / 'run.py']},
            'limits': ['simulated ACP backend', 'no native guard or MCP execution',
                       'binary/source equivalence is operator-attested, not proven']}
    print(json.dumps(plan, indent=2))
    if not args.run:
        return 0
    # Never adopt an existing output, even if it looks like an earlier fixture.
    output.mkdir(parents=True, exist_ok=False)
    output = output.resolve(strict=True)
    fixture = output / 'fixture'
    home = fixture / 'home'
    home.mkdir(parents=True)
    fake = fixture / 'fake-cli'
    shutil.copyfile(HERE / 'fake_dsh.py', fake)
    fake.chmod(0o700)
    manifest = {'fixture': IDENTITY, 'sha256': digest(fake), 'scenario': plan['scenario'], 'marker': str(uuid.uuid4())}
    write(fixture / 'manifest.json', manifest)
    shutil.copyfile(fixture / 'manifest.json', home / 'fixture.json')
    (fixture / 'lease').write_text(IDENTITY)
    scratch = output / 'scratch'
    scratch.mkdir()
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(output),
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'LANG': 'en_US.UTF-8'}
    for git_args in [['init', '-q', '-b', 'main'], ['-c', 'user.name=Offline Fixture',
                     '-c', 'user.email=offline@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'Offline fixture']]:
        subprocess.run(['/usr/bin/git', *git_args], cwd=scratch, env=env, check=True, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sandbox = output / 'offline.sb'
    sandbox.write_text('(version 1)\n(allow default)\n(deny network*)\n')
    command = ['/usr/bin/sandbox-exec', '-f', str(sandbox), *command]
    plan['launchCommand'] = command
    plan['network'] = 'denied for the App and fixture subprocesses'
    write(output / 'runner-plan.json', plan)
    failures = []
    cleanup = []
    process = None
    started = time.monotonic()
    stage = 'launch'
    try:
        # Direct execution creates a new owned process; LaunchServices could reuse a user's app.
        with (output / 'app.log').open('x') as log:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log, start_new_session=True)
            write(output / 'process.json', {'pid': process.pid, 'binarySHA256': plan['binarySHA256'], 'startedAt': time.time()})
            stage = 'app-running'
            write(output / 'runner-stage.json', {'stage': stage, 'pid': process.pid})
            try:
                code = process.wait(timeout=timeout)
                if code != 0:
                    failures.append('App exit code ' + str(code))
            except subprocess.TimeoutExpired:
                failures.append('Overall deadline exceeded')
    except BaseException as error:
        failures.append('Runner exception: ' + type(error).__name__)
    finally:
        stage = 'cleanup'
        (fixture / 'lease').unlink(missing_ok=True)
        cleanup.append('Removed only this fixture lease; its peers self-terminate')
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=8)
                cleanup.append('Terminated owned App PID')
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                cleanup.append('Killed owned App PID after bounded wait')
        # Peers check the lease every 500 ms. No process-name or unverified PID kill.
        time.sleep(1)
    result_file = output / 'dsh-hydra.json'
    try:
        result = json.loads(result_file.read_text()) if result_file.exists() else {}
    except (OSError, ValueError):
        result = {}
        failures.append('Unreadable App result')
    if result.get('status') != 'passed' or result.get('stage') != 'finished':
        failures.append('App assertions did not finish successfully')
    failures.extend(result.get('failedInvariants', []))
    streams = []
    for path in home.glob('wire-*.jsonl'):
        try:
            streams.append(list(map(json.loads, path.read_text().splitlines())))
        except (OSError, ValueError):
            failures.append('Unreadable ACP evidence: ' + path.name)
    events = sorted([e for stream in streams for e in stream], key=lambda e: e['at'])
    active = set()
    peak = 0
    for event in events:
        identity = event['identity']
        if event['event'] == 'start':
            active.add(identity)
            peak = max(peak, len(active))
        elif event['event'] == 'exit':
            active.discard(identity)
        elif event['event'] == 'failure':
            failures.append('Fake ACP protocol assertion failed')
    if not events or active or peak > 2:
        failures.append('ACP process cleanup/concurrency invariant failed')
    prompts = [e for e in events if e['event'] == 'prompt']
    leads = [e for e in prompts if e['role'] == 'lead']
    heads = [e for e in prompts if e['role'] == 'head']
    if len(leads) != 2 or len({e['sessionID'] for e in leads}) != 1 or any(e['guarded'] for e in leads):
        failures.append('Lead prompt count/session/unguarded-follow-up invariant failed')
    if len({e['sessionID'] for e in heads}) != 1 or {e['sessionID'] for e in heads} & {e['sessionID'] for e in leads}:
        failures.append('Independent head session invariant failed')
    if len([e for e in events if e['event'] == 'report_received']) != 1:
        failures.append('Correct lead report delivery not proven')
    if args.dsh_offline_hydra_budget:
        if len(heads) != 2 or heads[0]['identity'] == heads[-1]['identity'] or heads[0]['guarded'] or not heads[-1]['guarded']:
            failures.append('Budget process replacement invariant failed')
        else:
            original, final = heads
            required = [('cancelled_prompt', original['identity']), ('resume', final['identity']), ('readiness', final['identity'])]
            for name, identity in required:
                if not any(e['event'] == name and e['identity'] == identity for e in events):
                    failures.append('Missing budget event: ' + name)
            cancellations = [e for e in events if e['event'] == 'cancelled_prompt' and e['identity'] == original['identity']]
            # Measure from the App's actual head-turn start, not the later provider prompt.
            head_started = result.get('headWorkStartedAt')
            if not cancellations or not isinstance(head_started, (int, float)) or cancellations[0]['at'] - head_started < maximum:
                failures.append('Head stopped before the real production budget window')
    elif len(heads) != 1 or any(e['guarded'] for e in events):
        failures.append('Quick scenario unexpectedly entered guarded report or repeated head')
    summary = {'status': 'failed' if failures else 'passed', 'stage': 'finished',
               'quickCoordinator': 'not-run' if args.dsh_offline_hydra_budget else ('failed' if failures else 'passed'),
               'budgetScenario': ('failed' if failures else 'passed') if args.dsh_offline_hydra_budget else 'not-run',
               'failedInvariants': failures, 'cleanup': cleanup, 'unclosedACPIdentities': sorted(active),
               'peakACPSessions': peak, 'elapsedSeconds': time.monotonic() - started,
               'uncovered': plan['limits'] + ['real account', 'installed CLI', 'tool execution', 'UI']}
    write(output / 'runner-result.json', summary)
    print(json.dumps(summary, indent=2))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
