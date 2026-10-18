#!/usr/bin/env python3
"""Strict offline desktop marketplace inheritance regression (reviewed rc.2 API).

Run from the repository root, with an already installed CLI and Xcode:
  python3 scripts/dsh_profile_stress.py --dsh /absolute/path/to/dsh \
    --summary /tmp/dsh-profile-summary.json

No account option, installs, desktop UI, real HOME, credentials or shell hooks.
Compiles verbatim production sources through prepare.py, replacing only the entry
point with ProfileHarness.swift. That entry calls real DshCLI.prepareLaunch;
this driver never adds a bundle patch or recreates production launch composition.
Uses the existing native ACP client and loopback Messages model, sandbox-exec
network confinement, sequential CLI processes, four prompts maximum, 12 HTTP
requests maximum, 60 seconds per ACP call, 180 seconds compilation and 300 seconds
overall (cleanup may add a few seconds). At most four CLI and four harness
launches, plus one compiler invocation; fixtures never launch subprocesses.
Compiler workers/runtime descendants are not counted as independent test clients;
owned process groups are stopped, detached descendants are not verified.

All fixtures/build products are temporary. Only the requested JSON summary remains
(overwritten), including source hashes, shims, launch arguments, observations and
source-file before/after fingerprints. Missing prerequisites are BLOCKED/nonzero;
a missing inherited bundle is FAIL, never an expected failure or simulated pass.
Evidence covers Standard-mode launch composition and actual native plugin/tool
execution, not Swift ACPSession, other modes, account access or desktop UI.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import tempfile
import time

from dsh_native_stress import ACP, FakeModel, Run, Failed


BUNDLE = 'tivano-profile-fixture-bundle'
DEPENDENCY = 'tivano-profile-fixture-dependency'
BAD_BUNDLE = 'tivano-profile-fixture-broken-bundle'
BUNDLE_TOOL = 'profile_bundle_probe'
USER_TOOL = 'profile_user_probe'
LIMITS = {'global_seconds': 300, 'compile_seconds': 180, 'acp_call_seconds': 60,
          'prompts': 4, 'model_requests': 12, 'cli_concurrency': 1,
          'cli_launches': 4, 'harness_launches': 4, 'compiler_invocations': 1}


class Blocked(Exception):
    pass


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        relative = str(path.relative_to(directory))
        if path.is_symlink():
            result[relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            stat = path.stat()
            result[relative] = {'sha256': digest(path), 'mode': stat.st_mode,
                                'mtime_ns': stat.st_mtime_ns}
        elif path.is_dir():
            result[relative] = {'directory': True}
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def bounded_process(command, env, cwd, run, timeout):
    remaining = run.deadline - time.monotonic()
    if remaining <= 0:
        raise Failed('Global deadline exhausted before subprocess launch')
    with tempfile.TemporaryFile() as output:
        child = subprocess.Popen(command, env=env, cwd=cwd, stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            try:
                child.wait(timeout=min(timeout, remaining))
            except subprocess.TimeoutExpired:
                # wait timed out without reaping: the owned group ID cannot be reused.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait(timeout=2)
                raise Failed('Subprocess deadline exceeded') from None
            output.seek(0)
            text = output.read(128 * 1024).decode(errors='replace')
            if child.returncode:
                raise Failed(f'Subprocess exited {child.returncode}: {text}')
            return text
        finally:
            if child.returncode is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait(timeout=2)


def compile_harness(repo, root, env, run, evidence):
    kit = root / 'kit'
    kit.mkdir()
    fixture = repo / 'scripts/fixtures/dsh_adapter'
    shutil.copyfile(fixture / 'Shims.swift', kit / 'Shims.swift')
    shutil.copyfile(fixture / 'ProfileHarness.swift', kit / 'Harness.swift')
    sources = runpy.run_path(str(fixture / 'prepare.py'))['prepare'](repo, kit)
    manifest = json.loads((kit / 'sources.json').read_text())
    manifest.pop('reference_commit', None)
    manifest['entry_point'] = str(fixture / 'ProfileHarness.swift')
    manifest['entry_point_sha256'] = digest(fixture / 'ProfileHarness.swift')
    manifest['driver_sha256'] = digest(Path(__file__))
    manifest['prepare_sha256'] = digest(fixture / 'prepare.py')
    manifest['native_helpers_sha256'] = digest(repo / 'scripts/dsh_native_stress.py')
    manifest['scope'] = 'DshCLI.prepareLaunch supplies native executable/arguments/environment; other adapter APIs are unused'
    evidence['sources'] = manifest
    binary = kit / 'profile-harness'
    command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
               '-target', 'arm64-apple-macos15.0', '-module-name', 'DSHProfileStress',
               '-module-cache-path', str(root / 'cache'), '-o', str(binary)] + sources
    bounded_process(command, env, repo, run, 180)
    return binary


def plugin_source(tool, dependency=False):
    dependency_import = f"import {{ value }} from '{DEPENDENCY}';\n" if dependency else "const value = 'user-local';\n"
    return dependency_import + '''import { appendFileSync } from 'node:fs';
export const name = TOOL;
export const inject = ['tools'];
export function apply(ctx, config) {
  const record = phase => appendFileSync(process.env.DSH_PROFILE_EVENTS,
    JSON.stringify({phase, tool: TOOL, dependency: value, setting: config.setting}) + '\\n');
  record('startup');
  ctx.tools.register({name: TOOL, description: 'Record an isolated profile fixture event',
    parameters: {type: 'object', properties: {}, additionalProperties: false},
    output: {schema: {type: 'string'}, render: (_args, value) => [{type: 'text', text: value}]},
    execute: async () => { record('execute'); return value + ':' + config.setting; }
  });
}
'''.replace('TOOL', json.dumps(tool))


def make_profile(root):
    # dsh-app-boot 0.2.1-rc.2 loadProfileDirectory/bundlePatchFiles:
    # selected package names -> dsh.bundle.patch layers -> profile user patch.
    desktop = root / 'dsh-home/profiles/desktop'
    bundle = desktop / 'node_modules' / BUNDLE
    dependency = bundle / 'node_modules' / DEPENDENCY
    bad = desktop / 'node_modules' / BAD_BUNDLE
    for directory in (dependency, bad):
        directory.mkdir(parents=True)
    write_json(dependency / 'package.json', {'name': DEPENDENCY, 'version': '1.0.0',
               'type': 'module', 'exports': './index.mjs'})
    (dependency / 'index.mjs').write_text("export const value = 'bundle-local-dependency';\n")
    write_json(bundle / 'package.json', {'name': BUNDLE, 'version': '1.0.0',
               'type': 'module', 'dependencies': {DEPENDENCY: '1.0.0'},
               'dsh': {'bundle': {'patch': './cordis.patch.yml'}}})
    plugin = bundle / 'plugin.mjs'
    plugin.write_text(plugin_source(BUNDLE_TOOL, dependency=True))
    # JSON is a YAML subset. The selected bundle alone inserts this plugin.
    write_json(bundle / 'cordis.patch.yml', [{'insert': [{'id': 'profile-bundle-probe',
               'name': str(plugin), 'config': {'setting': 'bundle-default'}}]}])
    write_json(bad / 'package.json', {'name': BAD_BUNDLE, 'version': '1.0.0',
               'dsh': {'bundle': {'patch': './intentionally-missing.yml'}}})
    user_plugin = desktop / 'user-probe.mjs'
    user_plugin.write_text(plugin_source(USER_TOOL))
    write_json(desktop / 'cordis.patch.yml', [{'insert': [{'id': 'profile-user-probe',
               'name': str(user_plugin), 'config': {'setting': 'user-patch-value'}}]}])
    return desktop


def select(desktop, bundles):
    write_json(desktop / 'package.json', {'name': 'isolated-desktop-fixture', 'private': True,
               'dependencies': {BUNDLE: '1.0.0', BAD_BUNDLE: '1.0.0'},
               'dsh': {'profile': {'bundles': bundles}}})


def read_events(path):
    if not path.exists():
        return []
    if path.stat().st_size > 65536:
        raise Failed('Fixture event log exceeded 64 KiB')
    return [json.loads(line) for line in path.read_text().splitlines()]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dsh', required=True, help='Absolute installed executable; never installed by this runner')
    parser.add_argument('--summary', required=True)
    parser.add_argument('--mode', choices=['standard', 'ptc', 'minimal', 'creator'], default='standard')
    args = parser.parse_args()
    args.real_account = False
    if not Path(args.dsh).is_absolute() or not os.access(args.dsh, os.X_OK):
        parser.error('--dsh must be an absolute installed executable path')
    run = Run(args)
    fake = None
    evidence = {'scope': 'Production DshCLI launch arguments + native offline plugin execution',
                'mode': args.mode, 'limits': LIMITS, 'unverified': ['Other CLI versions', 'Swift ACPSession and App/UI',
                'Arbitrary marketplace packages and version exemptions', 'Detached descendants'],
                'scenarios': run.rows}
    request_count = [0]
    try:
        if not Path('/usr/bin/sandbox-exec').is_file():
            raise Blocked('macOS sandbox-exec required; no unconfined fallback')
        if not Path('/usr/bin/xcrun').is_file():
            raise Blocked('Xcode Swift compiler required')
        with tempfile.TemporaryDirectory(prefix='tivano-dsh-profile-') as temporary:
            root = Path(temporary)
            repo = Path(__file__).resolve().parents[1]
            for folder in ('home', 'dsh-home', 'tmp', 'cache', 'cwd'):
                (root / folder).mkdir()
            env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(root / 'home'),
                   'DSH_HOME': str(root / 'dsh-home'), 'DSH_TEST_ROOT': str(root),
                   'TMPDIR': str(root / 'tmp') + '/', 'LANG': 'en_US.UTF-8',
                   'CLANG_MODULE_CACHE_PATH': str(root / 'cache'), 'DSH_TELEMETRY_DISABLED': '1'}
            binary = compile_harness(repo, root, env, run, evidence)
            desktop = make_profile(root)
            user_patch = json.loads((desktop / 'cordis.patch.yml').read_text())
            fake = FakeModel()
            # Keep the existing Messages model, but reject excess HTTP requests before
            # they reach it. Serial handling also bounds fixture server thread count.
            fake.server.process_request = lambda request, address: http.server.HTTPServer.process_request(fake.server, request, address)
            original_post = fake.server.RequestHandlerClass.do_POST
            def limited_post(handler):
                request_count[0] += 1
                if request_count[0] > LIMITS['model_requests'] or time.monotonic() >= run.deadline:
                    handler.send_error(429, 'Fixture request budget exhausted')
                    for client in list(run.clients):
                        client.kill()
                    return
                original_post(handler)
            fake.server.RequestHandlerClass.do_POST = limited_post
            port = fake.server.server_address[1]
            sandbox = root / 'offline.sb'
            sandbox.write_text('(version 1) (allow default) (deny network*) '
                               f'(allow network-outbound (remote ip "localhost:{port}"))\n')
            env.update(DEEPSEEK_API_KEY='offline-fixture-only',
                       DEEPSEEK_BASE_URL=f'http://127.0.0.1:{port}/anthropic',
                       NO_PROXY='127.0.0.1,localhost', DSH_PERMISSION_MODE='danger-full-access')
            cases = [
                ('selected-bundle', [BUNDLE], BUNDLE_TOOL,
                 'Selected bundle starts and executes its tool using its local dependency'),
                ('user-patch', [BUNDLE], USER_TOOL,
                 'User patch configuration reaches a running plugin and executed tool; bundle also starts'),
                ('deselected-bundle', [], USER_TOOL,
                 'Same installed bundle deselected: no startup, execution or advertised tool; user plugin still works'),
                ('broken-bundle', [BAD_BUNDLE], USER_TOOL,
                 'Selected broken bundle produces an explicit named diagnostic, not silent success')]
            for name, bundles, tool, expected in cases:
                actual = {}
                row = {'scenario': name, 'expected': expected, 'actual': actual, 'status': 'FAIL'}
                run.rows.append(row)
                before = None
                client = None
                select(desktop, bundles)
                write_json(desktop / 'cordis.patch.yml', user_patch + (
                    [{'id': 'profile-bundle-probe', 'config': {'setting': 'user-override'}}]
                    if name == 'user-patch' else []))
                bundle_setting = 'user-override' if name == 'user-patch' else 'bundle-default'
                events_path = root / (name + '.jsonl')
                try:
                    before = snapshot(desktop)
                    actual['source_before'] = before
                    generated = bounded_process([str(binary), args.dsh, args.mode], env, root / 'cwd', run, 20)
                    plan = json.loads(generated)
                    arguments = plan.get('arguments')
                    if not isinstance(arguments, list) or not all(isinstance(a, str) for a in arguments) or not Path(plan.get('executable', '')).is_absolute():
                        raise Failed('Harness did not emit a valid production launch plan')
                    actual['launch_arguments'] = arguments
                    actual['launch_executable'] = plan['executable']
                    if len(run.clients) >= LIMITS['cli_launches'] or any(c.process.poll() is None for c in run.clients):
                        raise Failed('CLI launch/concurrency budget exhausted')
                    start = len(fake.events)
                    rejected = None
                    try:
                        client = ACP(run, ['/usr/bin/sandbox-exec', '-f', str(sandbox), plan['executable']] + arguments,
                                     dict(plan['environment'], DSH_PROFILE_EVENTS=str(events_path)), root / 'cwd')
                        sid, _ = client.session(root / 'cwd')
                        if run.prompts >= LIMITS['prompts']:
                            raise Failed('Prompt budget exhausted')
                        fake.tool_request = ({'name': 'run_code', 'input': {'description': 'Exercise the isolated fixture tool', 'code': 'return await tools.' + tool + '({});'}}
                                             if args.mode == 'ptc' else {'name': tool, 'input': {}})
                        actual['answer'] = run.prompt(client, sid, 'Exercise the requested fixture tool, then reply DSH_OK.')
                    except Exception as error:
                        rejected = str(error)
                        actual['runtime_error'] = rejected
                    finally:
                        fake.tool_request = None
                        # ACP can fail in __init__ after registering its owned process.
                        for owned in run.clients:
                            if not owned.closed:
                                owned.close()
                    actual['events'] = read_events(events_path)
                    actual['wire_tools'] = [e['tools'] for e in fake.events[start:]]
                    actual['stderr'] = list(run.clients[-1].stderr) if run.clients else []
                    actual['http_requests_total'] = request_count[0]
                    if name == 'broken-bundle':
                        if rejected is None or actual['wire_tools'] or actual['events']:
                            raise Failed('Broken bundle did not fail closed before plugin startup or model execution')
                        diagnostic = '\n'.join(actual['stderr']) + '\n' + (rejected or '')
                        if BAD_BUNDLE not in diagnostic or not any(word in diagnostic.lower() for word in
                                ('skipping', 'cannot resolve', 'enoent', 'missing', 'not found', 'failed', 'error')):
                            raise Failed('Broken selection was silently ignored or failed without its named diagnostic')
                        if rejected and ('deadline' in rejected.lower() or 'budget' in rejected.lower()):
                            raise Failed('Timeout/budget exhaustion is not broken-bundle handling')
                    else:
                        if rejected:
                            raise Failed(rejected)
                        if not actual['wire_tools'] or 'DSH_OK' not in actual.get('answer', ''):
                            raise Failed('No completed local-model turn')
                        expected_event = {'phase': 'execute', 'tool': tool,
                                          'dependency': 'bundle-local-dependency' if tool == BUNDLE_TOOL else 'user-local',
                                          'setting': bundle_setting if tool == BUNDLE_TOOL else 'user-patch-value'}
                        if expected_event not in actual['events']:
                            raise Failed('Expected actual tool execution/config/dependency event missing')
                        if {**expected_event, 'phase': 'startup'} not in actual['events']:
                            raise Failed('Expected actual plugin startup missing')
                        if not any(('run_code' if args.mode == 'ptc' else tool) in tools for tools in actual['wire_tools']):
                            raise Failed('Executed fixture tool absent from model schema')
                        bundle_events = [e for e in actual['events'] if e.get('tool') == BUNDLE_TOOL]
                        if name == 'deselected-bundle':
                            if bundle_events or any(BUNDLE_TOOL in tools for tools in actual['wire_tools']):
                                raise Failed('Deselected bundle still loaded')
                        elif not any(e == {'phase': 'startup', 'tool': BUNDLE_TOOL,
                                          'dependency': 'bundle-local-dependency', 'setting': bundle_setting}
                                     for e in bundle_events):
                            raise Failed('Selected bundle/dependency startup missing')
                    if request_count[0] > LIMITS['model_requests']:
                        raise Failed('Model request budget exceeded')
                    row['status'] = 'PASS'
                except Exception as error:
                    row['failure'] = str(error)
                finally:
                    after = snapshot(desktop)
                    actual['source_after'] = after
                    actual['source_unchanged'] = before is not None and before == after
                    if not actual['source_unchanged']:
                        row['status'] = 'FAIL'
                        row['source_failure'] = 'Source profile/package/plugin tree changed during launch or execution'
                    print(json.dumps(row, ensure_ascii=False), flush=True)
    except Exception as error:
        run.rows.append({'scenario': 'driver', 'expected': 'Bounded isolated execution', 'actual': str(error),
                         'status': 'BLOCKED' if isinstance(error, Blocked) else 'FAIL'})
    finally:
        for client in run.clients:
            try:
                client.close()
            except Exception as error:
                run.rows.append({'scenario': 'cleanup', 'expected': 'Owned process reaped',
                                 'actual': str(error), 'status': 'FAIL'})
        run.stop.set()
        if fake:
            fake.close()
    statuses = [row['status'] for row in run.rows]
    evidence['status'] = 'PASS' if len(run.rows) == 4 and all(s == 'PASS' for s in statuses) else (
        'BLOCKED' if statuses and all(s == 'BLOCKED' for s in statuses) else 'FAIL')
    evidence['prompt_count'] = run.prompts
    evidence['model_request_count'] = request_count[0]
    evidence['cli_launch_count'] = len(run.clients)
    write_json(Path(args.summary), evidence)
    print(json.dumps({'status': evidence['status'], 'summary': args.summary}))
    return {'PASS': 0, 'FAIL': 1, 'BLOCKED': 2}[evidence['status']]


if __name__ == '__main__':
    raise SystemExit(main())
