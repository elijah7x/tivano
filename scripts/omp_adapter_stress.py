#!/usr/bin/env python3
"""Compile the real OMP Swift adapter and exercise fault/lifecycle fixtures.

Default: 28 fake-CLI cases, 40 lifecycles at concurrency 4, then 12 real-OMP
loopback-model checks. No App launch, credentials or cloud requests.
Use --fake-only to omit real OMP. All dependency shims are in sources.json.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--omp', default=shutil.which('omp'))
    parser.add_argument('--cycles', type=int, default=10, help='1..10 per worker; four workers')
    parser.add_argument('--fake-only', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin' or not 1 <= args.cycles <= 10:
        parser.error('macOS and 1..10 cycles are required')
    if not args.fake_only and not args.omp:
        parser.error('install omp or use --fake-only')
    root = Path(__file__).resolve().parents[1]
    parent = args.output.resolve() if args.output else root / 'build.noindex/omp-adapter'
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    kit = out / 'kit'
    shutil.copytree(root / 'scripts/fixtures/omp_adapter', kit)
    fake = out / 'fake'; fake.mkdir()
    (kit / 'fake_omp.py').chmod(0o700)
    env = dict(os.environ, T08_ROOT=str(root), T08_KIT=str(kit), T08_STORAGE=str(fake), T08_GROUPED='1')
    if args.omp:
        env['T08_OMP'] = str(Path(args.omp).resolve())
    deadline = time.monotonic() + 180
    stages = []

    def run(name, command, timeout=60, environment=None):
        started = time.monotonic()
        process = subprocess.Popen(command, cwd=root, env=environment or env,
                                   start_new_session=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        expired = False
        try:
            text, _ = process.communicate(timeout=min(timeout, max(1, deadline - started)))
        except subprocess.TimeoutExpired:
            expired = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                text, _ = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                text, _ = process.communicate()
        finally:
            # This process group was created for this stage; never target user processes.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        (out / (name + '.log')).write_text(text)
        stages.append({'stage': name, 'exit': process.returncode, 'timeout': expired,
                       'seconds': time.monotonic() - started})
        if expired or process.returncode:
            raise RuntimeError(name + ' failed; see ' + str(out / (name + '.log')))

    results = {}
    try:
        run('prepare', [sys.executable, str(kit / 'prepare.py')])
        sources = json.loads((kit / 'source-arguments.json').read_text())
        command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                   '-module-name', 'T08Stress', '-o', str(kit / 'adapter')]
        run('compile', command + sources + [str(kit / f) for f in ['TimelineTypes.swift', 'Shims.swift', 'Harness.swift']])
        run('fake', [str(kit / 'adapter'), str(kit / 'fake_omp.py'), str(args.cycles)], 75)
        results['fake'] = json.loads((fake / 'summary.json').read_text())
        if results['fake'].get('passed') is not True:
            raise RuntimeError('fake adapter assertions failed')
        if not args.fake_only:
            run('real', [sys.executable, str(kit / 'run_real.py')], 160)
            results['real'] = json.loads((kit / 'real/summary-real.json').read_text())
            if results['real'].get('passed') is not True:
                raise RuntimeError('real adapter assertions failed')
        results['passed'] = True
    except Exception as error:
        results['passed'] = False
        results['error'] = str(error)
    results['stages'] = stages
    results['artifacts'] = str(out)
    results['scope'] = 'Real Swift adapter; fake CLI and optional real OMP with localhost model. Persistence/Hydra prompt/MCP/catalog dependencies shimmed; no GUI.'
    (out / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
    return 0 if results['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
