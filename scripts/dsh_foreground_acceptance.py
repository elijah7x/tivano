#!/usr/bin/env python3
"""Plan-only by default. See fixtures/dsh_foreground/README.md for authorization and limits."""
import argparse
import json
import math
from pathlib import Path
import plistlib
import subprocess
import sys
import time

import dsh_ui_acceptance as protocol

PHASES = protocol.HEAVY_PHASES
FIELDS = ('sourceRevision', 'localChanges', 'buildCommand', 'optimization', 'configuration',
          'buildSettings', 'architecture', 'os', 'hardware', 'display', 'window', 'fonts', 'materials',
          'workload', 'persistence', 'baselineRole')
MATCH_FIELDS = tuple(k for k in FIELDS if k not in
                     ('sourceRevision', 'localChanges', 'buildCommand', 'baselineRole'))
LIMITS = [
    'injected-system-wheel is not a human hardware wheel or input-to-photon measurement.',
    'External wheel phases remain ineligibleForTimingComparison under the existing probe contract.',
    'RSS is resident bytes, not total memory footprint; CPU is cumulative process user/system nanoseconds.',
    'Observed phase labels come from atomic report snapshots; boundaries are not exact sample timestamps.',
    'Sampling and AX observation add cost. Keep the same driver and cadence on both builds.',
    'No historical observation is a performance threshold. Overall performance is never automatically approved.',
    'Screenshot paths do not prove visual correctness or pixel coverage; lead inspection is required.',
    'CaptureRun is synthetic and disables persistence after history loading; real provider/disk cost is excluded.',
]


def load(path):
    return json.loads(path.read_text())


def inspect(root):
    result = protocol.analyze_case(root, 'segmented-tools')
    # The existing manual-wheel contract explicitly excludes normalized timing.
    issues = [i for i in result['issues'] if not i.endswith(': timing comparison ineligible')]
    manifest = protocol.read_json(root / 'foreground-driver.json')
    report = result['probeEvidence'].get('raw', {})
    run = manifest.get('raw', {}).get('run', {})
    if run.get('status') != 'completed' or run.get('appReturnCode') != 0 or run.get('helperReturnCode') != 0:
        issues.append('owned process lifecycle or sampler did not complete cleanly')
    samples, terminal = [], []
    try:
        records = [json.loads(line) for line in (root / 'samples.ndjson').read_text().splitlines()]
        samples = [r for r in records if r.get('kind') == 'sample']
        terminal = [r for r in records if r.get('kind') in ('blocked', 'completed')]
        if len(terminal) != 1 or terminal[0].get('kind') != 'completed':
            issues.append('sampler terminal evidence missing/blocked')
        previous = None
        identity = None
        for sample in samples:
            current_identity = (sample['pid'], sample['processStartSeconds'], sample['processStartMicroseconds'])
            if identity is None:
                identity = current_identity
            if current_identity != identity or sample['pid'] != run.get('pid') or sample['pid'] != report.get('pid'):
                issues.append('sample process identity mismatch')
                break
            values = [sample[k] for k in ('monotonicSeconds', 'actualIntervalSeconds', 'rssBytes',
                                          'cpuUserNanoseconds', 'cpuSystemNanoseconds')]
            if not all(isinstance(v, (int, float)) and math.isfinite(v) and v >= 0 for v in values):
                issues.append('invalid sample values')
                break
            if previous and (sample['monotonicSeconds'] <= previous['monotonicSeconds'] or
                             sample['cpuUserNanoseconds'] < previous['cpuUserNanoseconds'] or
                             sample['cpuSystemNanoseconds'] < previous['cpuSystemNanoseconds']):
                issues.append('non-monotonic clock/CPU evidence')
                break
            previous = sample
        for phase in PHASES:
            if not any(s.get('observedPhase') == phase for s in samples):
                issues.append(phase + ': no resource samples')
        if not any(r.get('kind') == 'injected-system-wheel' for r in records):
            issues.append('no injected system wheel evidence')
    except (OSError, ValueError, KeyError, TypeError) as error:
        issues.append('samples unavailable/invalid: ' + str(error))
    phases = report.get('phases', [])
    load_phases = [p for p in phases if p.get('name') == 'three-thread-load']
    if len(load_phases) != 1 or load_phases[0].get('acceptedWheelEvents', 0) < 2:
        issues.append('existing monitor did not accept at least two load-phase wheel events')
    if report.get('scrollInput') != 'external native input; no programmatic position writes':
        issues.append('not the manual-wheel protocol')
    if any(p.get('eligibleForTimingComparison') is not False for p in phases):
        issues.append('manual-wheel timing exclusion missing')
    return {'directory': str(root), 'rawMeasurement': {'probe': result['probeEvidence'],
            'manifest': manifest, 'samplesFile': str(root / 'samples.ndjson'),
            'sampleCount': len(samples), 'terminal': terminal},
            'admission': {'status': 'eligible-for-owner-review' if not issues else 'blocked',
                          'issues': sorted(set(issues)), 'reconciliation': result['reconciliation']},
            'visualReview': 'pending lead screenshot inspection',
            'performanceJudgment': 'not-assessed; normalized wheel timing comparison prohibited', 'limitations': LIMITS}


def compare(current, baseline):
    if baseline is None:
        return {'status': 'missing', 'reason': 'no retained pre-change directory supplied'}
    other = inspect(baseline)
    a = current['rawMeasurement']['manifest'].get('raw', {})
    b = other['rawMeasurement']['manifest'].get('raw', {})
    mismatches = []
    for key in MATCH_FIELDS:
        av, bv = a.get('conditions', {}).get(key), b.get('conditions', {}).get(key)
        if av is None or bv is None or av != bv:
            mismatches.append({'field': 'conditions.' + key, 'current': av, 'baseline': bv})
    for key in ('protocolHashes', 'helperSHA256', 'wheelPattern', 'nominalSampleIntervalSeconds',
                'timelineRegionWindowRelativeTopLeftPoints'):
        if not a.get(key) or a.get(key) != b.get(key):
            mismatches.append({'field': key, 'current': a.get(key), 'baseline': b.get(key)})
    ar = current['rawMeasurement']['probe'].get('raw', {})
    br = other['rawMeasurement']['probe'].get('raw', {})
    for key in ('parameters', 'persistence', 'textRenderer', 'nativeStorage', 'osVersion'):
        if ar.get(key) is None or ar.get(key) != br.get(key):
            mismatches.append({'field': 'probe.' + key, 'current': ar.get(key), 'baseline': br.get(key)})
    reasons = []
    if b.get('conditions', {}).get('baselineRole') != 'pre-change':
        reasons.append('baseline lacks explicit pre-change provenance')
    if not a.get('conditions', {}).get('sourceRevision') or not b.get('conditions', {}).get('sourceRevision'):
        reasons.append('source revision missing')
    if (a.get('conditions', {}).get('sourceRevision'), a.get('conditions', {}).get('localChanges')) == (
            b.get('conditions', {}).get('sourceRevision'), b.get('conditions', {}).get('localChanges')):
        reasons.append('same source state; repeated current runs are not pre-change A/B')
    if not a.get('binarySHA256') or not b.get('binarySHA256') or a.get('binarySHA256') == b.get('binarySHA256'):
        reasons.append('missing or identical executable identity')
    if other['admission']['status'] == 'blocked' or current['admission']['status'] == 'blocked':
        reasons.append('one or both runs fail evidence admission')
    return {'status': 'unmatched' if mismatches or reasons else 'candidate-only; owner must establish source relationship and paired repeats',
            'mismatches': mismatches, 'reasons': reasons, 'baselineEvidence': other,
            'performanceJudgment': 'not-assessed; no automatic performance gate'}


def safe_root(path):
    repo_build = Path(__file__).resolve().parents[1] / 'build.noindex'
    temp = Path('/tmp').resolve()
    return (path == repo_build or repo_build in path.parents or
            (temp in path.parents and path != temp))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'output', 'helper', 'task-build-root', 'conditions', 'analyze', 'baseline'):
        parser.add_argument('--' + name, type=Path)
    for name in ('run', 'owner-authorized', 'authorize-system-wheel', 'confirm-debug-capture', 'confirm-timeline-region'):
        parser.add_argument('--' + name, action='store_true')
    parser.add_argument('--timeline-region', nargs=4, type=float, metavar=('X', 'Y', 'WIDTH', 'HEIGHT'))
    args = parser.parse_args()
    if args.analyze:
        if args.run:
            parser.error('--analyze cannot run')
        result = inspect(args.analyze.expanduser().resolve())
        result['baselineComparison'] = compare(result, args.baseline.expanduser().resolve() if args.baseline else None)
        protocol.emit(result)
        return 0
    if not all((args.app, args.output, args.helper, args.task_build_root, args.conditions, args.timeline_region)):
        parser.error('plan/run needs --app --output --helper --task-build-root --conditions --timeline-region')
    app, output, helper, build_root = [p.expanduser().resolve() for p in
                                      (args.app, args.output, args.helper, args.task_build_root)]
    if not safe_root(build_root) or build_root not in app.parents or build_root not in helper.parents:
        parser.error('app and helper must be in an explicit task build root under build.noindex or a dedicated /tmp subdirectory')
    if not safe_root(output) or output.exists() or output == build_root or output in build_root.parents:
        parser.error('output must be a new dedicated build.noindex or /tmp directory, never an existing/root directory')
    if app == output or app in output.parents or output in app.parents or output in helper.parents:
        parser.error('output must not overlap app/helper')
    if not all(math.isfinite(v) for v in args.timeline_region):
        parser.error('timeline geometry must be finite')
    x, y, width, height = args.timeline_region
    if x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > 1200 or y + height > 800:
        parser.error('timeline region must be a positive rectangle inside the 1200x800 window')
    conditions = load(args.conditions)
    if not isinstance(conditions, dict) or any(k not in conditions or conditions[k] in (None, '', {}) for k in FIELDS):
        parser.error('conditions must provide every field: ' + ', '.join(FIELDS))
    if conditions['configuration'] != 'Debug' or conditions['optimization'] != '-O':
        parser.error('existing probe requires explicitly recorded optimized -O Debug provenance')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable = (app / 'Contents/MacOS' / info['CFBundleExecutable']).resolve()
    if app not in executable.parents or not executable.is_file():
        parser.error('CFBundleExecutable must resolve inside the task app')
    if info.get('CFBundleIdentifier') != 'dev.tivano.Tivano.dev' or b'fewer than two external wheel events entered the timeline monitor' not in executable.read_bytes():
        parser.error('App must be the Dev edition with the DEBUG manual-wheel probe compiled in')
    repo = Path(__file__).resolve().parents[1]
    sources = ['scripts/dsh_foreground_acceptance.py', 'scripts/dsh_ui_acceptance.py',
               'scripts/fixtures/dsh_foreground/wheel_sampler.m', 'Tivano/App/Captures/HeavyLoadProbe.swift']
    command = [str(executable), '--website-captures', str(output), '--heavy-load-probe', '--manual-wheel-probe']
    manifest = {'schemaVersion': 1, 'created': protocol.now(), 'conditions': conditions,
                'app': str(app), 'executable': str(executable), 'binarySHA256': protocol.digest(executable),
                'helper': str(helper), 'helperSHA256': protocol.digest(helper) if helper.is_file() else None,
                'protocolHashes': {s: protocol.digest(repo / s) for s in sources},
                'command': command, 'timelineRegionWindowRelativeTopLeftPoints': args.timeline_region,
                'nominalSampleIntervalSeconds': 0.1, 'externalDeadlineSeconds': 140,
                'wheelPattern': 'load only, 24 pixel delta alternating each second of helper uptime, nominal 10Hz',
                'inputClassification': 'injected-system-wheel', 'limitations': LIMITS}
    if not args.run:
        protocol.emit({'mode': 'plan-only; no writes, launches or input', **manifest})
        return 0
    if sys.platform != 'darwin' or not all((args.owner_authorized, args.authorize_system_wheel,
                                          args.confirm_debug_capture, args.confirm_timeline_region)):
        parser.error('--run needs macOS and all four explicit launch/input/isolation/geometry attestations')
    if not helper.is_file():
        parser.error('helper missing; lead must build it explicitly first')
    preflight = subprocess.run([str(helper), '--preflight'], capture_output=True, text=True, timeout=10)
    if preflight.returncode:
        protocol.emit({'status': 'blocked', 'preflight': preflight.stdout, 'stderr': preflight.stderr})
        return 2
    output.mkdir(parents=True, exist_ok=False)
    run = {'status': 'starting', 'lifecycle': []}
    manifest['run'] = run
    protocol.save(output / 'foreground-driver.json', manifest)
    app_process = sampler = None
    try:
        with (output / 'stdout.log').open('wb') as out, (output / 'stderr.log').open('wb') as err, \
                (output / 'samples.ndjson').open('wb') as samples, (output / 'sampler-stderr.log').open('wb') as helper_err:
            app_process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                           cwd=app.parent, start_new_session=True)
            run.update(pid=app_process.pid, status='running')
            run['lifecycle'].append({'event': 'spawned-owned-app', 'monotonicSeconds': time.monotonic()})
            sampler = subprocess.Popen([str(helper), str(app_process.pid), str(executable),
                                        str(output / 'heavy-load.json'), *map(str, args.timeline_region)],
                                       stdin=subprocess.DEVNULL, stdout=samples, stderr=helper_err, start_new_session=True)
            protocol.save(output / 'foreground-driver.json', manifest)
            deadline = time.monotonic() + 140
            while time.monotonic() < deadline:
                app_rc, helper_rc = app_process.poll(), sampler.poll()
                if helper_rc is not None and helper_rc != 0:
                    raise RuntimeError('sampler blocked; inspect samples.ndjson')
                if app_rc is not None:
                    sampler.wait(timeout=2)
                    if app_rc != 0 or sampler.returncode != 0:
                        raise RuntimeError('owned app or sampler exited unsuccessfully')
                    run['status'] = 'completed'
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError('140 second external deadline')
    except (OSError, RuntimeError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        run.update(status='blocked', reason=str(error) or 'interrupted')
    finally:
        for name, process in (('helper', sampler), ('app', app_process)):
            if process is not None:
                run[name + 'Cleanup'] = protocol.stop_owned(process)
                run[name + 'ReturnCode'] = process.returncode
                run['lifecycle'].append({'event': name + '-reaped', 'monotonicSeconds': time.monotonic(),
                                         'returnCode': process.returncode})
        protocol.save(output / 'foreground-driver.json', manifest)
    result = inspect(output)
    result['baselineComparison'] = compare(result, args.baseline.expanduser().resolve() if args.baseline else None)
    protocol.save(output / 'foreground-analysis.json', result)
    protocol.emit(result)
    return 0 if result['admission']['status'] != 'blocked' else 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print('blocked: ' + str(error), file=sys.stderr)
        sys.exit(2)
