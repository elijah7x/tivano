#!/usr/bin/env python3
"""Thor T08 serial build/OMP compatibility checks; never launches the App.

Run from the task worktree. Evidence stays in build.noindex/t08-thor.
Existing CLI stress runners isolate HOME and use loopback models only.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build.noindex/t08-thor'
PROGRESS = Path('/Volumes/ExHeart/forked/tivano/port-tasks/reports/T08-thor-progress.json')
BASE = '300db74dad06d43a421b48b5ca2c0d166ca9cdc7'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--omp', default=os.environ.get('T08_OMP') or shutil.which('omp'))
    args = parser.parse_args()
    if not args.build_only and not args.omp:
        parser.error('OMP missing from PATH; pass --omp or T08_OMP for an existing installation')
    OUT.mkdir(parents=True, exist_ok=True)
    parent = OUT / 'serial'; parent.mkdir(exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    commands = [('build-verified', [
        'xcodebuild', '-project', 'Tivano.xcodeproj', '-scheme', 'Tivano',
        '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64',
        '-derivedDataPath', str(OUT / 'DerivedData'),
        '-clonedSourcePackagesDirPath', '/Volumes/ExHeart/forked/tivano/DerivedData/SourcePackages',
        '-skipPackagePluginValidation', '-skipMacroValidation', 'CODE_SIGNING_ALLOWED=NO', 'build'
    ])]
    if not args.build_only:
        commands += [
            ('adapter', [sys.executable, 'scripts/omp_adapter_stress.py', '--omp', args.omp, '--output', str(out / 'adapter')]),
            ('gate', [sys.executable, 'scripts/omp_gate_stress.py', '--omp', args.omp, '--rounds', '2', '--output', str(out / 'gate')]),
            ('rpc', [sys.executable, 'scripts/omp_offline_stress.py', '--omp', args.omp, '--rounds', '3', '--workers', '4', '--output', str(out / 'rpc')]),
            ('native', [sys.executable, 'scripts/omp_native_stress.py', '--omp', args.omp, '--output', str(out / 'native')]),
        ]
    results = []
    for name, command in commands:
        log = out / (name + '.log')
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        summaries = []
        if name != 'build-verified':
            for path in sorted((out / name).rglob('summary.json')):
                try:
                    data = json.loads(path.read_text())
                    summaries.append({'path': str(path), 'passed': data.get('passed') is True})
                except (ValueError, OSError):
                    summaries.append({'path': str(path), 'passed': False})
        passed = result.returncode == 0 and (('** BUILD SUCCEEDED **' in log.read_text()) if name == 'build-verified' else bool(summaries) and all(s['passed'] for s in summaries))
        results.append({'group': name, 'command': command, 'exit': result.returncode, 'passed': passed,
                        'started': started, 'log': str(log), 'summaries': summaries})
        (out / 'serial-results.json').write_text(json.dumps(results, indent=2) + '\n')
        progress = json.loads(PROGRESS.read_text())
        progress.update(updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), base_commit=BASE,
                        current_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                        next='Continue CLI, actual MCP and Store integration; GUI awaits authorization')
        progress['completed'].append(name + (': passed' if passed else ': failed (retained evidence)'))
        progress['logs'].append(str(log))
        if not passed:
            progress['blockers'].append(name + ': see ' + str(log))
        PROGRESS.write_text(json.dumps(progress, indent=2) + '\n')
    return 0 if all(r['passed'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
