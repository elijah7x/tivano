#!/usr/bin/env python3
"""Headless acceptance against the actual Debug App module, not storage/CLI shims.

Requires the unsigned build in build.noindex/t08-thor/DerivedData. This loads
Tivano's debug dylib into a CLI executable; never invokes TivanoApp/SwiftUI main,
open, NSApplication.run, or an installed App. CaptureRun is asserted before writes.
Uses official CLI queries for existing login only; no credentials are inspected.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from omp_offline_stress import RPC

ROOT = Path(__file__).resolve().parents[1]
PARENT = ROOT / 'build.noindex/t08-thor'


def main():
    out = Path(tempfile.mkdtemp(prefix='run-', dir=make_dir(PARENT / 'integration')))
    debug = PARENT / 'DerivedData/Build/Products/Debug'
    mac = debug / 'Tivano Dev.app/Contents/MacOS'
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-DDEBUG',
               '-I', str(debug), '-F', str(debug / 'PackageFrameworks'), '-F', str(debug),
               '-Xlinker', '-rpath', '-Xlinker', str(mac), '-Xlinker', '-rpath', '-Xlinker', str(debug / 'PackageFrameworks'),
               str(mac / 'Tivano Dev.debug.dylib'), str(ROOT / 'scripts/fixtures/omp_adapter/ThorIntegration.swift'), '-o', str(out / 'integration')]
    env = dict(os.environ, T08_EVIDENCE=str(out), T08_OMP=os.environ.get('T08_OMP') or shutil.which('omp'), T08_PYTHON=sys.executable,
               T08_MCP_SERVER=str(ROOT / 'scripts/fixtures/omp_adapter/thor_mcp_server.py'))
    results = []

    def run(name, cmd, cwd=ROOT, timeout=180):
        with (out / (name + '.log')).open('wb') as log:
            result = subprocess.run(cmd, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        results.append({'name': name, 'command': cmd, 'exit': result.returncode, 'log': str(out / (name + '.log'))})
        (out / 'commands.json').write_text(json.dumps(results, indent=2) + '\n')
        return result.returncode == 0

    try:
        if not run('compile', command):
            raise RuntimeError('headless harness compile failed')
        for kind in ['models', 'usage']:
            with (out / (kind + '-home.json')).open('wb') as stdout, (out / (kind + '.stderr')).open('wb') as stderr:
                cmd = [env['T08_OMP'], kind, '--json', '--no-extensions']
                result = subprocess.run(cmd, cwd=env['HOME'], env=env, stdout=stdout, stderr=stderr, timeout=60)
                results.append({'name': kind, 'command': cmd, 'cwd': env['HOME'], 'exit': result.returncode})
                if result.returncode:
                    raise RuntimeError('official CLI query failed: ' + kind)
        project = make_dir(out / 'cli-current')
        rpc = RPC([env['T08_OMP'], '--mode', 'rpc', '--no-session', '--no-extensions', '--no-skills', '--no-rules'], project, env, 30)
        try:
            (out / 'current-state.json').write_text(json.dumps(rpc.request('get_state'), indent=2))
        finally:
            rpc.close()
        executable = str(out / 'integration')
        groups = [('cli', ['--cli'], 'capture-cli', 'cli-integration-summary.json'),
                  ('store', [], 'capture-store', 'store-integration-summary.json'),
                  ('ledger-reload', ['--ledger-reload'], 'capture-store', 'ledger-reload-summary.json'),
                  ('second-root', ['--second-root'], 'capture-second', 'second-root-summary.json')]
        passed = True
        for name, extra, folder, summary in groups:
            ok = run(name, [executable, '--website-captures', str(out / folder)] + extra)
            data = json.loads((out / summary).read_text())
            passed = passed and ok and data.get('passed') is True
        summary = {'passed': passed, 'commands': results, 'artifacts': str(out),
                   'scope': 'Actual App Debug module in a CLI process; no App/GUI launch. Synthetic runtime events are marked. Official real-login CLI catalog/usage plus injected failures.'}
    except Exception as error:
        summary = {'passed': False, 'error': str(error), 'commands': results, 'artifacts': str(out)}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 0 if summary['passed'] else 1


def make_dir(path):
    path.mkdir(parents=True, exist_ok=True)
    return path


if __name__ == '__main__':
    raise SystemExit(main())
