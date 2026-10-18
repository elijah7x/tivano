#!/usr/bin/env python3
"""Explicit account opt-in: actual Swift ACP/DSH/Shell, four modes and report resume.
At most eight short model prompts, concurrency two; no app UI or credential reads.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dsh', required=True)
    parser.add_argument('--dsh-home', required=True)
    parser.add_argument('--real-account', action='store_true', required=True)
    parser.add_argument('--compile-only', action='store_true', help='Compile the harness without starting DSH or sending prompts')
    args = parser.parse_args()
    if not Path(args.dsh).is_absolute() or not os.access(args.dsh, os.X_OK):
        parser.error('--dsh must be an installed absolute executable path')
    if not Path(args.dsh_home).is_dir():
        parser.error('--dsh-home must exist; the runner never reads its credentials')
    root = Path(__file__).resolve().parents[1]
    parent = root / 'build.noindex/dsh-live'; parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    kit = out / 'kit'
    shutil.copytree(root / 'scripts/fixtures/dsh_adapter', kit)
    sources = runpy.run_path(str(kit / 'prepare.py'))['prepare'](root, kit)
    sources.remove(str(kit / 'Harness.swift'))
    sources.remove(str(kit / 'Shims.swift'))
    shim = (kit / 'Shims.swift').read_text()
    start, end = shim.index('struct ShellResult:'), shim.index('enum Storage {')
    shim = shim[:start] + shim[end:]
    shim = shim.replace('    static func load() async {}', '    static func load() async {}\n    static func which(_ name: String) -> URL? { nil }')
    (kit / 'LiveShims.swift').write_text(shim)
    # Compile Shell/OutputCollector/OnceContinuation verbatim; the login-shell discovery
    # remains deliberately shimmed so no user shell hooks or credentials are imported.
    shell = root / 'Tivano/Core/Support/Shell.swift'
    (kit / 'ShellProcess.swift').write_text(shell.read_text().split('enum LoginEnvironment {')[0])
    sources += [str(kit / name) for name in ('LiveShims.swift', 'ShellProcess.swift', 'LiveHarness.swift')]
    manifest = {'sources': sources, 'sha256': {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in sources},
                'shell_source_sha256': hashlib.sha256(shell.read_bytes()).hexdigest(),
                'shims': ['LoginEnvironment: temporary HOME and explicit environment, no shell lookup',
                          'MCP configuration empty', 'App contexts and attachment storage unused'],
                'limits': {'prompts': 8, 'concurrency': 2, 'turn_seconds': 60, 'global_seconds': 300}}
    (out / 'sources.json').write_text(json.dumps(manifest, indent=2))
    for directory in ('home', 'tmp', 'cache'):
        (out / directory).mkdir()
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(out / 'home'),
           'TMPDIR': str(out / 'tmp') + '/', 'DSH_HOME': str(Path(args.dsh_home).resolve()),
           'DSH_TEST_ROOT': str(out), 'DSH_TELEMETRY_DISABLED': '1', 'LANG': 'en_US.UTF-8',
           'CLANG_MODULE_CACHE_PATH': str(out / 'cache')}
    compiler = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                '-target', 'arm64-apple-macos15.0', '-module-name', 'DSHLiveStress',
                '-module-cache-path', str(out / 'cache'), '-o', str(kit / 'live')] + sources
    with (out / 'compile.log').open('w') as log:
        build = subprocess.run(compiler, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    print('artifacts=' + str(out), flush=True)
    if build.returncode:
        print('Compilation failed; see compile.log')
        return build.returncode
    if args.compile_only:
        print('Live harness compiled; no DSH process or account request started')
        return 0
    # Swift's real request/turn deadlines and stopAndWait own CLI cleanup. The foreground
    # runner deliberately does not abruptly kill its Swift child or unrelated dsh processes.
    with (out / 'run.log').open('w') as log:
        result = subprocess.run([str(kit / 'live'), args.dsh], cwd=root, env=env,
                                stdout=log, stderr=subprocess.STDOUT)
    report = out / 'live-result.json'
    if report.exists():
        print(report.read_text())
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
