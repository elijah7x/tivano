#!/usr/bin/env python3
"""Plan by default. --run launches only an explicitly identified task-built Dev app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from model import Model

MODES = ('standard', 'ptc', 'minimal', 'creator')
SCENARIOS = ('file', 'mcp', 'tool-failure', 'bad-mcp')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def processes():
    text = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,lstart=,command='], text=True, timeout=2)
    result = {}
    for line in text.splitlines():
        parts = line.split(None, 8)
        if len(parts) == 9:
            pid, ppid, pgid = map(int, parts[:3])
            result[pid] = {'pid': pid, 'ppid': ppid, 'pgid': pgid,
                           'birth': ' '.join(parts[3:8]), 'command': parts[8]}
    return result


def descendants(snapshot, parent, known):
    parents = {parent} | {pid for pid, row in known.items() if snapshot.get(pid, {}).get('birth') == row['birth']}
    while True:
        children = {pid for pid, row in snapshot.items() if row['ppid'] in parents}
        if children <= parents:
            break
        parents |= children
    return {pid: snapshot[pid] for pid in parents if pid in snapshot}


def reconcile(root, marker, modes=MODES, scenarios=SCENARIOS):
    app = json.loads((root / 'app-result.json').read_text())
    events = [json.loads(line) for line in (root / 'mcp-events.jsonl').read_text().splitlines()]
    wire = [json.loads(line) for line in (root / 'model-events.jsonl').read_text().splitlines()]
    errors = []
    if app.get('stage') != 'finished' or app.get('failure') or app.get('marker') != marker:
        errors.append('App did not finish without failure')
    rows = app.get('rows', [])
    if len(rows) != len(modes) * len(scenarios) + 1 or app.get('modes') != list(modes) or app.get('scenarios') != list(scenarios):
        errors.append('Selected matrix scope/turn count differs from the actual App report')
    broken = [r for r in rows if r.get('scenario') == 'mcp-startup']
    if len(broken) != 1 or broken[0].get('turnStatus') != 'failed' or broken[0].get('sessionID') is not None:
        errors.append('MCP initialization failure did not remain a failed unadmitted session')
    if not any(e['event'] == 'initialize-failure' and e.get('marker') == marker for e in events):
        errors.append('No independent native MCP initialization failure')
    if any(e['scenario'] == 'unexpected-model-request' for e in wire):
        errors.append('Unexpected model request, including possible MCP-stripped fallback')
    rows = [r for r in rows if r.get('scenario') != 'mcp-startup']
    for mode in modes:
        sessions = {r.get('sessionID') for r in rows if r.get('mode') == mode}
        if len(sessions) != 1 or None in sessions:
            errors.append(mode + ': missing/stale/replaced session')
        for scenario in scenarios:
            selected = [r for r in rows if r.get('mode') == mode and r.get('scenario') == scenario]
            traffic = [e for e in wire if e['mode'] == mode and e['scenario'] == scenario]
            if len(selected) != 1 or not traffic or sum(e['first'] for e in traffic) != 1:
                errors.append(mode + '/' + scenario + ': App/model reconciliation missing')
                continue
            row = selected[0]
            call_id = 'native-' + mode + '-' + scenario
            returned = [b for e in traffic if not e['first'] for b in e['toolResults'] if b.get('tool_use_id') == call_id]
            if not row['tools'] or not returned:
                errors.append(mode + '/' + scenario + ': no App tools/native returned tool result')
            if mode == 'ptc':
                calls = [c for e in traffic for c in e.get('toolCalls', []) if c.get('id') == call_id]
                if not any('run_code' in e['tools'] for e in traffic) or not any(c.get('name') == 'run_code' for c in calls) or len(row['tools']) != 1:
                    errors.append('PTC run_code schema, actual native history and App tool count did not reconcile')
            if scenario == 'mcp' and 'MCP_EFFECT_' + marker not in json.dumps(returned):
                errors.append(mode + ': native MCP result missing independent effect marker')
            if scenario == 'bad-mcp' and 'MCP_FIXTURE_FAILURE_' + marker not in json.dumps(returned):
                errors.append(mode + ': native MCP failure result missing')
            if scenario in ('file', 'mcp'):
                target = root / 'scratch' / (mode + '-' + scenario + '.txt')
                if target.is_symlink() or not target.is_file() or target.read_text() != marker:
                    errors.append(mode + '/' + scenario + ': independent content mismatch')
                if row['turnStatus'] != 'completed' or not any(t['status'] == 'completed' for t in row['tools']):
                    errors.append(mode + '/' + scenario + ': App did not show completion')
            else:
                if not any(t['status'] == 'failed' for t in row['tools']):
                    errors.append(mode + '/' + scenario + ': failure not visible')
                if any(t.get('editPaths') and t['status'] == 'completed' for t in row['tools']):
                    errors.append(mode + '/' + scenario + ': failed call presented a successful edit')
        for kind in ('effect', 'failure'):
            matched = [e for e in events if e['event'] == kind and e.get('mode') == mode and e.get('marker') == marker]
            if len(matched) != 1:
                errors.append(mode + ': independent MCP ' + kind + ' must occur exactly once')
    expected_files = {mode + '-' + surface + '.txt' for mode in modes for surface in ('file', 'mcp') if surface in scenarios}
    if {p.name for p in (root / 'scratch').iterdir()} != expected_files:
        errors.append('Unexpected scratch modification or missing expected file')
    return {'errors': errors, 'approvalObserved': any(r.get('approvalObserved') for r in rows),
            'approvalAcceptance': 'observed-only; no approval means not covered', 'app': app}


def supervise(root, app, dsh, *flags):
    command = [app, '--website-captures', root, '--dsh-offline-native-probe',
               '--dsh-test-executable', dsh, '--dsh-test-home', str(Path(root) / 'dsh-home'), *flags]
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL)
    write(Path(root) / 'app-process.json', {'pid': child.pid, 'ppid': os.getpid(), 'command': command})
    code = child.wait()
    write(Path(root) / 'app-exit.json', {'returncode': code})
    # Keep the group leader unreaped until the runner finishes owned-process cleanup.
    sys.stdin.buffer.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--no-pty', action='store_true', help='Explicitly select Standard/PTC/Creator only; never an automatic fallback')
    parser.add_argument('--mcp-only', action='store_true', help='Explicitly select MCP call cases plus startup failure')
    parser.add_argument('--app', type=Path, help='Task-built Tivano Dev.app bundle')
    parser.add_argument('--build-root', type=Path, help='Explicit task build products root')
    parser.add_argument('--source-identity', help='Lead-supplied worktree revision/diff identity (attestation, not proof)')
    parser.add_argument('--dsh', type=Path, help='Installed native executable; never installs')
    parser.add_argument('--dsh-runtime-root', type=Path, help='Installed @deepseek-ai/dsh package or DeepSeek Harness.app root, read-only sandbox exception')
    args = parser.parse_args()
    modes = ('standard', 'ptc', 'creator') if args.no_pty else MODES
    scenarios = ('mcp', 'bad-mcp') if args.mcp_only else SCENARIOS
    flags = (['--dsh-native-no-pty'] if args.no_pty else []) + (['--dsh-native-mcp-only'] if args.mcp_only else [])
    plan = {'scope': 'AppModel -> ThreadRuntime -> ACPSession -> installed native DSH -> local tools/MCP',
            'modes': modes, 'scenarios': scenarios, 'deadlineSeconds': 300,
            'network': 'only the allocated local model port', 'default': 'plan only',
            'requires': ['task-built Dev app', 'WebsiteCaptures prepare/run wiring', 'explicit --run'],
            'permissionMode': 'fullAccess inside outer sandbox; workspace-write/approvals excluded (macOS rejects nested sandbox)',
            'notCovered': ['cloud decisions', 'UI', 'arbitrary plugins', 'workspace-write/approvals']}
    if not args.run:
        print(json.dumps(plan, indent=2))
        return 0
    if not all((args.app, args.build_root, args.dsh, args.dsh_runtime_root, args.source_identity)):
        parser.error('--run requires --app --build-root --source-identity --dsh --dsh-runtime-root')
    app, build, dsh = (p.resolve(strict=True) for p in (args.app, args.build_root, args.dsh))
    if not app.is_relative_to(build) or build == Path('/') or any(str(p).startswith('/Applications/') for p in (app, build)):
        parser.error('App must be inside the explicit task build root, never /Applications')
    native_root = args.dsh_runtime_root.resolve(strict=True)
    owner_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    if native_root == owner_home or native_root in owner_home.parents or not dsh.is_relative_to(native_root):
        parser.error('Native runtime root must be the installed package, not a home/ancestor')
    package_file = native_root / 'package.json'
    if package_file.is_file():
        package = json.loads(package_file.read_text())
        if package.get('name') != '@deepseek-ai/dsh':
            parser.error('Native runtime root is not @deepseek-ai/dsh')
        native_artifact = package_file
        native_version = str(package.get('version', 'unknown'))
    else:
        native_artifact = native_root / 'Contents/Resources/app.asar'
        expected_cli = native_root / 'Contents/Resources/runtime/cli/bin/dsh'
        if dsh != expected_cli or not native_artifact.is_file():
            parser.error('Native bundle does not contain the expected installed CLI/archive')
        native_version = 'desktop archive identity recorded; CLI version reported by App'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleName') != 'Tivano Dev' and info.get('CFBundleDisplayName') != 'Tivano Dev':
        parser.error('Only the Dev edition is accepted')
    executable = (app / 'Contents/MacOS' / info['CFBundleExecutable']).resolve(strict=True)
    if not executable.is_relative_to(app) or not os.access(executable, os.X_OK) or not os.access(dsh, os.X_OK):
        parser.error('Invalid app/native executable')
    if b'Offline native preparation rejected:' not in executable.read_bytes():
        parser.error('App lacks the DEBUG native fixture admission guard')
    if not Path('/usr/bin/sandbox-exec').is_file():
        parser.error('sandbox-exec required; no unconfined fallback')
    root = Path(tempfile.mkdtemp(prefix='tivano-dsh-app-native-', dir='/private/tmp')).resolve()
    marker = str(uuid.uuid4())
    for name in ('home', 'dsh-home', 'tmp', 'scratch'):
        (root / name).mkdir()
    fixture = Path(__file__).resolve().parent
    shutil.copyfile(fixture / 'mcp.py', root / 'mcp.py')
    model = Model(root, marker)
    port = model.server.server_address[1]
    manifest = {'fixture': 'tivano-dsh-app-native-v1', 'marker': marker, 'port': str(port),
                'dsh': str(dsh), 'dshSHA256': sha(dsh), 'app': str(executable), 'appSHA256': sha(executable),
                'python': str(Path(sys.executable).resolve()), 'mcpSHA256': sha(root / 'mcp.py'),
                'runnerSHA256': sha(Path(__file__)), 'modelSHA256': sha(fixture / 'model.py'),
                'dshArtifact': str(native_artifact), 'dshArtifactSHA256': sha(native_artifact),
                'dshVersion': native_version,
                'sourceIdentityAttestation': args.source_identity}
    temporary_items = Path(subprocess.check_output(
        ['/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR'], text=True, timeout=5).strip()).resolve() / 'TemporaryItems'
    replacement_prefix = str(temporary_items / ('NSIRD_' + info['CFBundleName'] + '_'))
    if not re.fullmatch(r'[/A-Za-z0-9_ -]+', replacement_prefix):
        parser.error('Unexpected Foundation temporary path; cannot safely form sandbox rule')
    replacement_pattern = '^' + replacement_prefix + '[A-Za-z0-9]+(/|$)'
    protected_replacements = list(temporary_items.glob('NSIRD_' + info['CFBundleName'] + '_*'))
    protected_terminals = list(Path('/dev').glob('ttys[0-9]*'))
    manifest['atomicReplacementPattern'] = replacement_pattern
    manifest['protectedExistingReplacementsJSON'] = json.dumps([str(p) for p in protected_replacements])
    manifest['protectedExistingTerminalsJSON'] = json.dumps([str(p) for p in protected_terminals])
    write(root / 'manifest.json', manifest)
    # No inbound allowance, no wildcard loopback allowance, no public network.
    sandbox = root / 'offline.sb'
    quote = lambda path: json.dumps(str(path))
    sandbox.write_text('(version 1) (allow default) (deny network*)\n'
                       f'(allow network-outbound (remote ip "localhost:{port}"))\n'
                       f'(deny file-read* (subpath {quote(owner_home)}))\n'
                       + ''.join(f'(allow file-read* (subpath {quote(path)}))\n'
                                 for path in (app, native_root, fixture))
                       + '(deny file-write*)\n'
                       + f'(allow file-write* (subpath {quote(root)}))\n'
                       + f'(allow file-write* (regex #{json.dumps(replacement_pattern)}))\n'
                       + ''.join(f'(deny file-write* (subpath {quote(path)}))\n' for path in protected_replacements)
                       + '(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/ptmx"))\n'
                       + '(allow file-write* (regex #"^/dev/ttys[0-9]+$"))\n'
                       + ''.join(f'(deny file-write* (literal {quote(path)}))\n' for path in protected_terminals))
    env = {'HOME': str(root / 'home'), 'DSH_HOME': str(root / 'dsh-home'), 'TMPDIR': str(root / 'tmp'),
           'PATH': str(dsh.parent) + ':/opt/homebrew/bin:/usr/bin:/bin', 'LANG': 'en_US.UTF-8',
           'DSH_TELEMETRY_DISABLED': '1', 'DEEPSEEK_API_KEY': 'offline-fixture-only',
           'DEEPSEEK_BASE_URL': f'http://127.0.0.1:{port}/anthropic', 'NO_PROXY': '127.0.0.1,localhost'}
    owned, result, process = {}, {'status': 'failed', 'errors': []}, None
    started = time.monotonic()
    model.start()
    print(json.dumps({'output': str(root), 'marker': marker}), flush=True)
    try:
        with (root / 'app.log').open('wb') as log:
            process = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(sandbox), sys.executable, '-B',
                                        str(Path(__file__).resolve()), '--supervise', str(root), str(executable), str(dsh), *flags],
                                       env=env, stdin=subprocess.PIPE, stdout=log, stderr=log, start_new_session=True)
            while time.monotonic() - started < 285:
                if process.poll() is not None:
                    raise RuntimeError('Sandbox/supervisor exited before completing the App run')
                snapshot = processes()
                owned.update(descendants(snapshot, process.pid, owned))
                write(root / 'owned-processes.json', list(owned.values()))
                if (root / 'app-exit.json').exists():
                    break
                time.sleep(0.5)
            else:
                raise RuntimeError('Overall deadline reached')
            exit_record = json.loads((root / 'app-exit.json').read_text())
            if exit_record['returncode'] != 0:
                raise RuntimeError('App exited unsuccessfully')
            result.update(reconcile(root, marker, modes, scenarios))
    except Exception as error:
        result['errors'].append(str(error))
    finally:
        if process is not None:
            snapshot = processes()
            owned.update(descendants(snapshot, process.pid, owned))
            for sig in (signal.SIGTERM, signal.SIGKILL):
                current = processes()
                for pid, record in owned.items():
                    if current.get(pid, {}).get('birth') == record['birth']:
                        try:
                            os.kill(pid, sig)
                        except ProcessLookupError:
                            pass
                time.sleep(0.2)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                result['errors'].append('Supervisor did not exit')
            current = processes()
            survivors = [pid for pid, record in owned.items() if current.get(pid, {}).get('birth') == record['birth']]
            result['cleanup'] = {'observedOwnedSurvivors': survivors,
                                 'directories': 'retained as evidence; no user directory removed',
                                 'limit': 'Detached descendants escaping observation are not proven absent'}
            if survivors:
                result['errors'].append('Observed owned process survived cleanup')
        model.close()
        result['status'] = 'failed' if result['errors'] else 'reconciled-with-cleanup-limit'
        result['elapsedSeconds'] = time.monotonic() - started
        result['manifest'] = manifest
        result['scope'] = plan
        write(root / 'result.json', result)
    print(json.dumps({'status': result['status'], 'output': str(root)}))
    return 1 if result['errors'] else 0


if __name__ == '__main__':
    if len(sys.argv) >= 5 and sys.argv[1] == '--supervise':
        supervise(*sys.argv[2:])
    else:
        raise SystemExit(main())
