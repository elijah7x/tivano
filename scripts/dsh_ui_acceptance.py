#!/usr/bin/env python3
"""Plan or run existing isolated GUI probes; never install or build Tivano.

Plan (no writes):
  python3 scripts/dsh_ui_acceptance.py --app /absolute/Test.app --output /tmp/ui-new
Run only AFTER explicit owner launch authorization, with a known -O Debug build:
  python3 scripts/dsh_ui_acceptance.py --app /absolute/Test.app --output /tmp/ui-new \
    --run --owner-authorized --confirm-debug-capture \
    --build-source '<revision + local changes>' --build-command '<actual build command>' \
    --window-conditions '<display, scale, foreground, typography and materials>'
Read existing evidence only (JSON to stdout, no writes or launches):
  python3 scripts/dsh_ui_acceptance.py --analyze /tmp/ui-new --baseline /tmp/ui-baseline

Requires an unlocked interactive macOS desktop and Screen Recording permission for
HeavyLoadProbe screenshots. Keep the capture window foreground and undisturbed.
No Accessibility automation, real providers, account login, or plugin actions run.
Settings stills and geometry are optionally captured after all measured phases;
they do not establish pixel coverage during the timing samples.
Exit 0 means plan/analysis output or process completion, never GUI acceptance.
"""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys


CASES = {
    'settings': ('settings-interaction.json', ['--settings-interaction-probe', '--settings-probe-captures'], 170),
    'stationary-text': ('heavy-load.json', ['--heavy-load-probe',
                         '--stationary-load-probe', '--text-only-load-probe'], 140),
    'segmented-tools': ('heavy-load.json', ['--heavy-load-probe'], 140),
}
SETTINGS_PHASES = ['idle-switch', 'idle-heartbeat', 'load-switch',
                   'load-heartbeat-covered', 'load-heartbeat-chat']
HEAVY_PHASES = ['idle-before', 'three-thread-load', 'idle-after']
LIMITS = [
    'Synthetic CaptureRun only: does not prove App real Hydra, accounts, providers, MCP or plugins.',
    'Heartbeat gaps and driver callback intervals are not FPS or input-to-photon latency.',
    'No numeric performance gate is introduced; historical 5.1 ms and p95 observations are not thresholds.',
    'Lead must actually inspect screenshots; saved paths alone are not visual acceptance.',
    'Stationary replay and programmatic scrolling do not prove real wheel interaction.',
    'Persistence is disabled by the existing probes after history loading; disk cost is excluded.',
    'Timing comparison requires repeated matched foreground A/B/A or paired runs and owner assessment.',
]


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def emit(value):
    print(json.dumps(value, ensure_ascii=False, indent=2))


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def read_json(path):
    try:
        value = json.loads(path.read_text())
        return {'path': str(path), 'status': 'read', 'raw': value}
    except FileNotFoundError:
        return {'path': str(path), 'status': 'missing'}
    except (OSError, ValueError) as error:
        return {'path': str(path), 'status': 'unreadable', 'error': str(error)}


def analyze_case(directory, name):
    report_name, _, _ = CASES[name]
    evidence = read_json(directory / report_name)
    raw = evidence.get('raw')
    raw = raw if isinstance(raw, dict) else {}
    phases = raw.get('phases', [])
    phases = phases if isinstance(phases, list) else []
    expected = SETTINGS_PHASES if name == 'settings' else HEAVY_PHASES
    phase_records = []
    issues = []
    for phase_name in expected:
        matches = [p for p in phases if isinstance(p, dict) and p.get('name') == phase_name]
        phase_records.append({'name': phase_name, 'records': matches,
                              'status': matches[0].get('status', 'missing') if len(matches) == 1 else 'missing-or-duplicate'})
        if len(matches) != 1 or matches[0].get('status') != 'completed':
            issues.append(phase_name + ': missing, duplicate or incomplete')
    if raw.get('status') != 'completed':
        issues.append('probe did not report completed')
    if name == 'settings':
        if raw.get('lockedScreenDiagnostic') is not False:
            issues.append('foreground validity missing or locked-screen diagnostic')
        if raw.get('loadStopped') is not True or raw.get('runtimeRunning') != [False] * 3:
            issues.append('load cleanup not confirmed')
        for phase in phases:
            if isinstance(phase, dict) and phase.get('name') in SETTINGS_PHASES[2:]:
                if phase.get('loadRunningAtEverySample') is not True:
                    issues.append(str(phase.get('name')) + ': continuous sampled load not confirmed')
        visual = read_json(directory / 'settings-visual.json').get('raw', {})
        visual = visual if isinstance(visual, dict) else {}
        captures = visual.get('captures', [])
        captures = captures if isinstance(captures, list) else []
        expected_pages = {'general', 'providers', 'models'}
        valid_visual = (visual.get('outsideMeasuredPhases') is True and len(captures) == 3
                        and all(isinstance(c, dict) for c in captures)
                        and {c.get('page') for c in captures} == expected_pages
                        and all(c.get('status') == 'captured' and c.get('appActive') is True
                                and c.get('keyWindow') is True and c.get('scale', 0) > 0
                                and c.get('displayID', 0) > 0
                                and len(c.get('framePoints', [])) == 4 and c['framePoints'][2:] == [1200, 800]
                                and c.get('screenshot') == 'settings-' + c['page'] + '.png'
                                and (directory / c['screenshot']).is_file() for c in captures))
        if not valid_visual:
            issues.append('settings post-phase screenshot/geometry evidence missing or invalid')
        reconciliation = {'status': 'not-provided-by-settings-probe',
                          'reason': 'extended stationary load is cancelled at finish; use separate HeavyLoadProbe exact reconciliation'}
    else:
        threads = raw.get('threads', [])
        threads = threads if isinstance(threads, list) else []
        text_only = name == 'stationary-text'
        counts = {'messageDeltasSent': 240, 'messageDeltasReconciledInFinalText': 240,
                  'toolGroupsReconciled': 0 if text_only else 20,
                  'completedMessagesReconciled': 1 if text_only else 20,
                  'providerEventsSent': 242 if text_only else 321,
                  'providerEventsReconciledFromState': 242 if text_only else 321}
        exact = len(threads) == 3 and all(
            isinstance(t, dict) and all(t.get(k) == v for k, v in counts.items())
            and all(t.get(k) is True for k in ['exactFinalText', 'completionSent',
                                              'completionWaitSucceeded', 'matches'])
            and t.get('isRunning') is False for t in threads)
        reconciliation = {'status': 'reconciled' if exact else 'unverified-or-mismatch',
                          'expectedPerThread': counts, 'rawThreads': threads}
        if not exact:
            issues.append('exact text/tool/event reconciliation incomplete or mismatched')
        for phase in phases:
            if not isinstance(phase, dict):
                continue
            if phase.get('eligibleForComparison') is not True:
                issues.append(str(phase.get('name')) + ': probe admission guard not satisfied')
            if phase.get('eligibleForTimingComparison') is not True:
                issues.append(str(phase.get('name')) + ': timing comparison ineligible')
    screenshots = [{'path': str(p), 'visualReview': 'pending-lead-inspection'}
                   for p in sorted(directory.glob('*.png')) if p.is_file()]
    if not screenshots:
        issues.append('screenshots missing')
    return {'case': name, 'probeStatus': raw.get('status', evidence['status']),
            'acceptance': 'not-established', 'issues': issues, 'expectedPhases': phase_records,
            'reconciliation': reconciliation, 'screenshots': screenshots,
            'probeEvidence': evidence, 'ownerAssessment': read_json(directory / 'owner-assessment.json'),
            'windowEvidence': (read_json(directory / 'settings-visual.json') if name == 'settings'
                               else raw.get('windowState', 'not-emitted; probe guards and operator notes only'))}


def analyze(root):
    return {'directory': str(root), 'manifest': read_json(root / 'driver.json'),
            'cases': [analyze_case(root / name, name) for name in CASES],
            'acceptance': 'not-established', 'limitations': LIMITS}


def isolated_path(path):
    task_build = Path(__file__).resolve().parents[1] / 'build.noindex'
    if path != task_build and task_build in path.parents:
        return True
    home = Path.home().resolve()
    forbidden = [Path('/Applications'), home / 'Applications', home / 'Library',
                 home / '.tivano', home / '.tivano-dev']
    return not any(path == p or p in path.parents for p in forbidden)


def stop_owned(process):
    # An unreaped direct child retains its PID; never look up or kill apps by name.
    if process.poll() is not None:
        return 'already-exited'
    process.terminate()
    try:
        process.wait(timeout=5)
        return 'terminated-owned-child'
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=5)
            return 'killed-owned-child'
        except subprocess.TimeoutExpired:
            return 'owned-child-exit-unverified'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--analyze', type=Path)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--owner-authorized', action='store_true')
    parser.add_argument('--confirm-debug-capture', action='store_true',
                        help='Attest this exact executable is an optimized Debug build with CaptureRun isolation; Release ignores capture flags')
    parser.add_argument('--build-source', help='Actual source revision and local-change identity for this build')
    parser.add_argument('--build-command', help='Actual build command/settings, including -O Debug provenance')
    parser.add_argument('--window-conditions', help='Operator record of display/scale, foreground, fonts/materials and baseline matching')
    args = parser.parse_args()
    if args.analyze:
        if args.run or args.app or args.output:
            parser.error('--analyze cannot be combined with --run, --app or --output')
        result = analyze(args.analyze.expanduser().resolve())
        result['baseline'] = analyze(args.baseline.expanduser().resolve()) if args.baseline else {'status': 'missing'}
        result['performanceComparison'] = 'not-assessed; no automatic pass or historical cutoff'
        emit(result)
        return 0
    if not args.app or not args.output:
        parser.error('--app and --output are required for plan/run')
    if args.baseline:
        parser.error('--baseline is only used with --analyze')
    app = args.app.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if not isolated_path(app) or not isolated_path(output):
        parser.error('use a separate test app and artifacts outside Applications and real Tivano data/preferences')
    if app == output or app in output.parents or output in app.parents:
        parser.error('app and artifact directories must not contain each other')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable = (app / 'Contents/MacOS' / info['CFBundleExecutable']).resolve()
    if app not in executable.parents or not executable.is_file():
        parser.error('bundle executable must be a regular file inside the explicit app')
    commands = {name: [str(executable), '--website-captures', str(output / name), *flags]
                for name, (_, flags, _) in CASES.items()}
    manifest = {'schemaVersion': 1, 'created': now(), 'mode': 'run' if args.run else 'plan',
                'app': str(app), 'executable': str(executable), 'binarySHA256': digest(executable),
                'bundleID': info.get('CFBundleIdentifier'), 'version': info.get('CFBundleShortVersionString'),
                'build': info.get('CFBundleVersion'), 'buildSourceOperatorSupplied': args.build_source,
                'buildCommandOperatorSupplied': args.build_command,
                'windowConditionsOperatorSupplied': args.window_conditions,
                'debugCaptureAttested': args.confirm_debug_capture,
                'output': str(output), 'commands': commands,
                'shellCommands': {k: shlex.join(v) for k, v in commands.items()},
                'externalDeadlinesSeconds': {k: v[2] for k, v in CASES.items()},
                'authorization': 'Explicit owner permission required before --run; CLI attestation is not permission itself.',
                'seed': 'WebsiteCaptures.prepare; existing three thread histories, unchanged probe traffic and phases',
                'settingsScreenshots': 'post-phase only; no screenshot work inside measured phases',
                'limitations': LIMITS, 'runs': []}
    if not args.run:
        emit(manifest)
        return 0
    if sys.platform != 'darwin':
        parser.error('--run requires macOS')
    if not (args.owner_authorized and args.confirm_debug_capture and args.build_source
            and args.build_command and args.window_conditions):
        parser.error('--run requires owner authorization, Debug CaptureRun attestation, build source/command and window conditions')
    # Refuse reuse: WebsiteCaptures.prepare resets storage and defaults under its output.
    output.mkdir(parents=True, exist_ok=False)
    save(output / 'driver.json', manifest)
    failed = False
    for name, command in commands.items():
        directory = output / name
        directory.mkdir()
        record = {'case': name, 'command': command, 'started': now(), 'status': 'starting'}
        manifest['runs'].append(record)
        save(output / 'driver.json', manifest)
        process = None
        interrupted = False
        try:
            with (directory / 'stdout.log').open('wb') as stdout, (directory / 'stderr.log').open('wb') as stderr:
                process = subprocess.Popen(command, cwd=str(app.parent), stdout=stdout, stderr=stderr,
                                           stdin=subprocess.DEVNULL, start_new_session=True)
                record.update(pid=process.pid, status='running')
                save(output / 'driver.json', manifest)
                record['returncode'] = process.wait(timeout=CASES[name][2])
                record['status'] = 'exited' if process.returncode == 0 else 'failed'
        except subprocess.TimeoutExpired:
            record['status'] = 'timeout'
        except KeyboardInterrupt:
            record['status'] = 'interrupted'
            interrupted = True
        except OSError as error:
            record.update(status='blocked', error=str(error))
        finally:
            if process is not None:
                record['cleanup'] = stop_owned(process)
                record['returncode'] = process.returncode
            record['finished'] = now()
            save(output / 'driver.json', manifest)
        failed = failed or record['status'] != 'exited'
        if interrupted or record.get('cleanup') == 'owned-child-exit-unverified':
            break
    result = analyze(output)
    result['baseline'] = {'status': 'missing; use --analyze with --baseline for retained evidence'}
    save(output / 'analysis.json', result)
    emit(result)
    return 1 if failed else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print('blocked: ' + str(error), file=sys.stderr)
        sys.exit(2)
