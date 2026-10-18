#!/usr/bin/env python3
"""Bounded native dsh ACP checks; not a test of Tivano's Swift adapter."""
import argparse
import concurrent.futures
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import tempfile
import textwrap
import threading
import time
import uuid


class Blocked(Exception):
    pass


class Failed(Exception):
    pass


MODES = [(mode, off) for mode in ('standard', 'ptc', 'minimal', 'creator')
         for off in (False, True)]
PATCHES = {'ptc': 'ptc.yml', 'minimal': 'minimal.yml',
           'minimalOptional': 'minimal-optional.yml', 'creator': 'creator.yml',
           'noDelegation': 'no-delegation.yml'}


def label(mode, off):
    return mode + ('+no-delegation' if off else '')


def opaque(value):
    return 'sha256:' + hashlib.sha256(str(value).encode()).hexdigest()[:16]


def extract_patches(destination):
    source = Path(__file__).resolve().parents[1] / 'Tivano/Services/Providers/DshPatches.swift'
    text = source.read_text()
    declarations = re.findall(r'static\s+let\s+(\w+)\s*=', text)
    matches = re.findall(r'static\s+let\s+(\w+)\s*=\s*#"""\n(.*?)\n[ \t]*"""#', text, re.S)
    if set(declarations) != set(PATCHES) or len(matches) != len(PATCHES):
        raise Blocked('Swift patch constants changed or extraction incomplete')
    if {name for name, _ in matches} != set(PATCHES):
        raise Blocked('Swift patch constant names changed')
    for name, body in matches:
        body = textwrap.dedent(body)
        if not body.strip() or '\\#(' in body:
            raise Blocked('Empty or interpolated Swift patch is unsupported')
        (destination / PATCHES[name]).write_text(body + '\n')


def launch_args(patches, mode='standard', off=False, profile=None):
    args = ['--profile', 'acp']
    if profile:
        args += ['--patch', str(profile)]
    names = {'standard': [], 'ptc': ['ptc.yml'],
             'minimal': ['minimal.yml', 'minimal-optional.yml'],
             'creator': ['creator.yml']}[mode]
    if off and mode != 'minimal':
        names = names + ['no-delegation.yml']
    for name in names:
        args += ['--patch', str(patches / name)]
    return args


class Run:
    def __init__(self, args):
        self.args = args
        self.deadline = time.monotonic() + 300
        self.rows = []
        self.sessions = []
        self.clients = []
        self.prompts = 0
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.watchdog = threading.Thread(target=self.guard, daemon=True)
        self.watchdog.start()

    def guard(self):
        if not self.stop.wait(max(0, self.deadline - time.monotonic())):
            for client in list(self.clients):
                client.kill()

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Failed('Global five-minute deadline exceeded')
        return min(60, remaining)

    def scenario(self, name, expected, action):
        try:
            actual = action()
            row = dict(scenario=name, expected=expected, actual=actual,
                       status='PASS', reason='Observed expected result')
        except Blocked as error:
            row = dict(scenario=name, expected=expected, actual=None,
                       status='SKIP', reason=str(error))
        except Exception as error:
            # Never persist provider error text: it may contain account data.
            reason = str(error) if isinstance(error, Failed) else type(error).__name__
            row = dict(scenario=name, expected=expected, actual=None,
                       status='FAIL', reason=reason)
        self.rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)

    def prompt(self, client, session, text):
        with self.lock:
            if self.args.real_account and self.prompts >= 8:
                raise Failed('Eight-prompt budget exhausted')
            self.prompts += 1
            if self.args.real_account:
                print(json.dumps({'event': 'prompt-start', 'count': self.prompts}), flush=True)
        client.text = []
        before = client.denials
        result = client.call('session/prompt', {'sessionId': session,
                             'prompt': [{'type': 'text', 'text': text}]})
        if client.denials != before:
            raise Failed('Unexpected permission or client tool request was denied')
        if result.get('stopReason') not in ('end_turn',):
            raise Failed('Prompt did not finish with end_turn')
        return ''.join(client.text)


class ACP:
    def __init__(self, run, command, env, cwd):
        run.remaining()
        if sum(c.process.poll() is None for c in run.clients) >= 2:
            raise Failed('Two-process concurrency limit')
        self.run = run
        self.pending = {}
        self.lock = threading.Lock()
        self.next_id = 0
        self.text = []
        self.denials = 0
        self.closed = False
        self.stderr = []
        self.ignored_stdout_lines = 0
        self.report_guard_ready = False
        self.process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE,
                                        start_new_session=True)
        run.clients.append(self)
        threading.Thread(target=self.read, daemon=True).start()
        threading.Thread(target=self.read_stderr, daemon=True).start()
        self.init = self.call('initialize', {'protocolVersion': 1,
            'clientInfo': {'name': 'dsh-native-stress', 'version': '1'},
            'clientCapabilities': {'fs': {'readTextFile': False, 'writeTextFile': False},
                                   'terminal': False}})

    def read_stderr(self):
        for line in self.process.stderr:
            self.stderr.append(line.decode(errors='replace')[:500])
            self.stderr = self.stderr[-8:]

    def send(self, value):
        data = (json.dumps({'jsonrpc': '2.0', **value}) + '\n').encode()
        with self.lock:
            self.process.stdin.write(data)
            self.process.stdin.flush()

    def read(self):
        try:
            while True:
                line = self.process.stdout.readline(2 * 1024 * 1024 + 1)
                if not line:
                    break
                if len(line) > 2 * 1024 * 1024:
                    break
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    # Match StdioProcess.consume: plugin/logging lines are not RPC frames.
                    self.ignored_stdout_lines += 1
                    continue
                if not isinstance(event, dict):
                    self.ignored_stdout_lines += 1
                    continue
                if 'method' in event:
                    method = event['method']
                    if 'id' in event:
                        self.denials += 1
                        if method == 'session/request_permission':
                            self.send({'id': event['id'], 'result': {'outcome': {'outcome': 'cancelled'}}})
                        else:
                            self.send({'id': event['id'], 'error': {'code': -32601, 'message': 'Denied by test client'}})
                    elif method == 'tivano/report_guard_ready':
                        self.report_guard_ready = event.get('params', {}).get('version') == 1
                    elif method == 'session/update':
                        update = event.get('params', {}).get('update', {})
                        if update.get('sessionUpdate') == 'agent_message_chunk':
                            content = update.get('content', {})
                            if content.get('type') == 'text':
                                self.text.append(content.get('text', ''))
                else:
                    target = self.pending.get(event.get('id'))
                    if target:
                        target.put(event)
        except Exception as error:
            self.reader_error = type(error).__name__
        finally:
            for target in list(self.pending.values()):
                target.put({'error': {'transport': getattr(self, 'reader_error', 'EOF')}})

    def begin(self, method, params):
        self.run.remaining()
        self.next_id += 1
        request_id = self.next_id
        target = queue.Queue()
        self.pending[request_id] = target
        self.send({'id': request_id, 'method': method, 'params': params})
        return request_id, target

    def finish(self, request, timeout=None):
        request_id, target = request
        try:
            response = target.get(timeout=min(timeout or 60, self.run.remaining()))
            if 'error' in response:
                if self.run.args.real_account:
                    error = response['error']
                    raw = (json.dumps(error) + ''.join(self.stderr)).lower()
                    flags = [word for word in ('enoent', 'eacces', 'keychain', 'credentials',
                             'no api key', 'not found', 'model', 'profile', 'plugin', 'skill',
                             'deepseek-account', 'vibe-island', 'home', 'directory', 'invalid',
                             'unauthorized', 'expired', 'authentication', 'permission') if word in raw]
                    detail = json.dumps({'code': error.get('code'), 'transport': error.get('transport'),
                                         'exit_code': self.process.poll(), 'diagnostic_flags': flags})
                else:
                    detail = json.dumps(response['error'])[:1000] + ' ' + ''.join(self.stderr)
                raise Failed('ACP request rejected or transport closed: ' + detail)
            return response.get('result', {})
        except queue.Empty:
            self.kill()
            raise Failed('ACP round deadline exceeded') from None
        finally:
            self.pending.pop(request_id, None)

    def call(self, method, params):
        try:
            return self.finish(self.begin(method, params))
        except Failed as error:
            raise Failed(method + ': ' + str(error)) from None

    def session(self, cwd, session=None, mcp_servers=None):
        params = {'cwd': str(cwd), 'mcpServers': mcp_servers or []}
        if session:
            capability = self.init.get('agentCapabilities', {}).get('sessionCapabilities', {}).get('resume')
            if capability is None or capability is False:
                raise Blocked('Native session/resume capability not advertised; no new-session fallback')
            params['sessionId'] = session
        state = self.call('session/resume' if session else 'session/new', params)
        sid = state.get('sessionId', session)
        if not isinstance(sid, str) or not sid:
            raise Failed('Missing session ID')
        if session and sid != session:
            raise Failed('Resume changed session ID')
        if sid not in self.run.sessions:
            self.run.sessions.append(sid)
            print(json.dumps({'event': 'created-session', 'session_id': sid}), flush=True)
        return sid, state

    def kill(self):
        # Never signal a process-group ID after its leader was reaped and may be reused.
        with self.lock:
            if self.closed:
                return
            if self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    # Darwin may reject signalling a process group whose leader just exited.
                    if self.process.poll() is None:
                        raise
            self.closed = True

    def close(self):
        if not self.closed:
            try:
                self.process.stdin.close()
                # Leave the child unreaped while allowing dsh to flush its session store.
                time.sleep(min(1, max(0, self.run.deadline - time.monotonic())))
            except OSError:
                pass
            self.kill()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            raise Failed('Owned process did not exit')
        return {'process_exited': self.process.returncode is not None,
                'ignored_stdout_lines': self.ignored_stdout_lines,
                'descendants': 'Owned unreaped process group stopped; detached children not verified'}


def options(option):
    result = []
    for entry in option.get('options', []):
        if 'options' in entry:
            result.extend(options(entry))
        else:
            result.append(entry)
    return result


def select_account(client, sid, state):
    config = state.get('configOptions', [])
    model = next((o for o in config if o.get('category', o.get('id')) == 'model'), None)
    if not model:
        raise Blocked('No grouped account model configuration advertised')
    choices = [v for group in model.get('options', [])
               if group.get('group') == 'deepseek-account' for v in options(group)
               if 'flash' in (v.get('name', '') + v.get('value', '')).lower()]
    if not choices:
        raise Blocked('No account-route Flash model; API fallback forbidden')
    selected = choices[0]['value']
    response = client.call('session/set_config_option', {'sessionId': sid,
                           'configId': model['id'], 'value': selected})
    config = response.get('configOptions', [])
    effort = next((o for o in config if o.get('category', o.get('id')) == 'thought_level'
                   or o.get('id') in ('reasoning_effort', 'effort', 'thought_level')), None)
    if not effort:
        raise Blocked('Low reasoning option not advertised after Flash selection')
    values = [v.get('value') for v in options(effort)]
    low = next((v for v in ('low', 'none', 'off') if v in values), None)
    if low is None:
        raise Blocked('No low/off reasoning choice; no prompt sent')
    client.call('session/set_config_option', {'sessionId': sid, 'configId': effort['id'], 'value': low})
    return opaque(selected)


def history(run, make, dirs, real):
    clients = []
    markers = ['DSH_TEST_' + uuid.uuid4().hex for _ in range(2)]
    sessions = []
    try:
        for directory in dirs:
            client = make(directory)
            clients.append(client)
            sid, state = client.session(directory)
            sessions.append(sid)
            if real:
                select_account(client, sid, state)
        if sessions[0] == sessions[1]:
            raise Failed('Different cwd processes received same session ID')
        def turn(index, remember):
            text = ('Do not use tools. Remember exactly ' + markers[index] + '. Reply only with this marker.'
                    if remember else 'Do not use tools. Reply only with the marker I asked you to remember.')
            answer = run.prompt(clients[index], sessions[index], text)
            if markers[index] not in answer or markers[1-index] in answer:
                raise Failed('Marker missing or cross-session marker contamination')
        for remember in (True, False):
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                list(pool.map(lambda i: turn(i, remember), range(2)))
        for client in clients:
            client.close()
        clients.clear()
        for i, directory in enumerate(dirs):
            client = make(directory)
            clients.append(client)
            sid, state = client.session(directory, sessions[i])
            if real:
                select_account(client, sid, state)
            turn(i, False)
        return {'session_ids': sessions, 'prompts': 6, 'new_two_turn_resume_isolated': True}
    finally:
        for client in clients:
            client.close()


class FakeModel:
    def __init__(self):
        self.events = []
        self.tool_request = None
        self.tool_denial_observed = False
        self.hold = False
        self.arrived = threading.Event()
        self.release = threading.Event()
        parent = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 0 < size <= 2 * 1024 * 1024:
                        self.send_error(413)
                        return
                    body = json.loads(self.rfile.read(size))
                    tools = [t['name'] for t in body.get('tools', [])]
                    parent.events.append({'tools': tools, 'model': opaque(body.get('model', ''))})
                    parent.arrived.set()
                    if parent.hold:
                        parent.release.wait(60)
                    # Reflect history, not a server-side session cache, to expose missing resume history.
                    messages = json.dumps(body.get('messages', []))
                    if 'Tools are disabled for the final report' in messages:
                        parent.tool_denial_observed = True
                    forced_tool = parent.tool_request
                    parent.tool_request = None
                    markers = list(dict.fromkeys(re.findall(r'DSH_TEST_[a-f0-9]{32}', messages)))
                    answer = ' '.join(markers) if markers else 'DSH_OK'
                    # Installed dsh-llm-deepseek 0.2.1-rc.2 uses the Messages API,
                    # not OpenAI chat/completions (resolveAdapterOptions/messagesApiRoot).
                    events = [
                        ('message_start', {'message': {'id': 'native-test', 'type': 'message',
                            'role': 'assistant', 'model': body.get('model', 'native-test'),
                            'content': [], 'stop_reason': None,
                            'usage': {'input_tokens': 10, 'output_tokens': 0}}}),
                        ('content_block_start', {'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
                        ('content_block_delta', {'index': 0, 'delta': {'type': 'text_delta', 'text': answer}}),
                        ('content_block_stop', {'index': 0}),
                        ('message_delta', {'delta': {'stop_reason': 'end_turn', 'stop_sequence': None},
                                           'usage': {'output_tokens': 2}}),
                        ('message_stop', {})]
                    if forced_tool is not None:
                        events[1] = ('content_block_start', {'index': 0, 'content_block': {
                            'type': 'tool_use', 'id': 'fixture-forbidden-tool',
                            'name': forced_tool['name'], 'input': {}}})
                        events[2] = ('content_block_delta', {'index': 0, 'delta': {
                            'type': 'input_json_delta', 'partial_json': json.dumps(forced_tool['input'])}})
                        events[4][1]['delta']['stop_reason'] = 'tool_use'
                    payload = ''.join('event: ' + kind + '\ndata: ' +
                                      json.dumps({'type': kind, **value}) + '\n\n'
                                      for kind, value in events).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()


def offline(run, root, patches, env, dirs):
    contract = None
    blocker = None
    fake = None
    try:
        if not run.args.offline_contract:
            raise Blocked('Offline endpoint patch and wire tool expectations are unknown; supply a reviewed --offline-contract')
        contract = json.loads(Path(run.args.offline_contract).read_text())
        if contract.get('protocol') != 'anthropic-messages':
            raise Blocked('Only the installed dsh Messages API fixture is implemented')
        if set(contract.get('tools', {})) != {label(*pair) for pair in MODES}:
            raise Blocked('Contract must specify exact wire tool sets for all eight combinations')
        if contract.get('endpoint_environment') != 'DEEPSEEK_BASE_URL':
            raise Blocked('Contract must confirm DEEPSEEK_BASE_URL endpoint override')
        if not Path('/usr/bin/sandbox-exec').is_file():
            raise Blocked('Offline network confinement requires macOS sandbox-exec; no unconfined fallback')
        fake = FakeModel()
        port = fake.server.server_address[1]
        profile = root / 'offline.patch.yml'
        profile.write_text(contract.get('patch', '[]\n'))
        env = dict(env, DEEPSEEK_API_KEY='offline-fixture-only',
                   DEEPSEEK_BASE_URL=f'http://127.0.0.1:{port}/anthropic',
                   NO_PROXY='127.0.0.1,localhost')
        sandbox = root / 'offline.sb'
        sandbox.write_text('(version 1) (allow default) (deny network*) '
                           f'(allow network-outbound (remote ip "localhost:{port}"))\n')
        def make(cwd, mode='standard', off=False):
            command = ['/usr/bin/sandbox-exec', '-f', str(sandbox), run.args.dsh]
            return ACP(run, command + launch_args(patches, mode, off, profile), env, cwd)
    except Blocked as error:
        blocker = str(error)
    except Exception:
        blocker = 'Invalid offline contract; configuration not attempted'
    try:
        for mode, off in MODES:
            name = label(mode, off)
            def check(mode=mode, off=off, name=name):
                if blocker:
                    raise Blocked(blocker)
                start = len(fake.events)
                client = make(dirs[0], mode, off)
                try:
                    sid, _ = client.session(dirs[0])
                    answer = run.prompt(client, sid, 'Do not use tools. Reply DSH_OK.')
                    events = fake.events[start:]
                    if not events or 'DSH_OK' not in answer:
                        raise Failed('No model request or missing fake reply')
                    expected = set(contract['tools'][name])
                    if any(set(event['tools']) != expected for event in events):
                        raise Failed('Observed wire tool set differs from contract')
                    return {'requests': len(events), 'tools': sorted(opaque(t) for t in expected),
                            'models': sorted({e['model'] for e in events})}
                finally:
                    client.close()
            run.scenario(name, 'Exact contract tool set received by local model', check)
        def histories():
            if blocker:
                raise Blocked(blocker)
            return history(run, make, dirs, False)
        run.scenario('history-isolation', 'Two processes, shared home, different cwd; two turns and resume', histories)
        def cancel():
            if blocker:
                raise Blocked(blocker)
            client = make(dirs[0])
            try:
                sid, _ = client.session(dirs[0])
                fake.hold = True
                fake.arrived.clear()
                request = client.begin('session/prompt', {'sessionId': sid, 'prompt': [
                    {'type': 'text', 'text': 'Do not use tools. Reply DSH_OK.'}]})
                if not fake.arrived.wait(min(10, run.remaining())):
                    raise Failed('Cancellation prompt never reached local model')
                client.send({'method': 'session/cancel', 'params': {'sessionId': sid}})
                result = client.finish(request, 10)
                if result.get('stopReason') != 'cancelled':
                    raise Failed('Cancellation did not return cancelled')
                return {'cancelled': True}
            finally:
                fake.hold = False
                fake.release.set()
                client.close()
        run.scenario('cancel', 'In-flight local-model prompt acknowledges cancellation', cancel)
    finally:
        if fake:
            fake.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dsh', required=True, help='Explicit installed executable path; never installs')
    parser.add_argument('--real-account', action='store_true')
    parser.add_argument('--dsh-home', help='Existing account home, required only with --real-account')
    parser.add_argument('--offline-contract', help='Reviewed version-specific local model patch and tool expectations JSON')
    parser.add_argument('--summary', default='dsh-native-summary.json')
    args = parser.parse_args()
    if not Path(args.dsh).is_absolute() or not os.access(args.dsh, os.X_OK):
        parser.error('--dsh must be an absolute installed executable path')
    if args.real_account != bool(args.dsh_home):
        parser.error('--real-account and --dsh-home must be supplied together')
    if args.real_account and args.offline_contract:
        parser.error('--offline-contract cannot be used with --real-account')
    run = Run(args)
    try:
        with tempfile.TemporaryDirectory(prefix='dsh-native-') as temporary:
            root = Path(temporary)
            patches = root / 'patches'
            patches.mkdir()
            dirs = [root / 'cwd-a', root / 'cwd-b']
            for directory in dirs:
                directory.mkdir()
            home = root / 'home'
            home.mkdir()
            dsh_home = Path(args.dsh_home).expanduser().resolve() if args.real_account else root / 'dsh-home'
            if args.real_account and not dsh_home.is_dir():
                raise Blocked('Account DSH_HOME does not exist')
            if not args.real_account:
                dsh_home.mkdir()
            # Credentials, API keys, proxy settings and user shell hooks are not inherited.
            env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(home),
                   'DSH_HOME': str(dsh_home), 'TMPDIR': str(root),
                   'DSH_TELEMETRY_DISABLED': '1', 'LANG': 'en_US.UTF-8'}
            extract_patches(patches)
            if args.real_account:
                profile = next((dsh_home / 'profiles' / name / 'cordis.patch.yml'
                                for name in ('desktop', 'web')
                                if (dsh_home / 'profiles' / name / 'cordis.patch.yml').is_file()), None)
                def real_history():
                    if profile is None:
                        raise Blocked('No desktop/web cordis.patch.yml; no account configuration synthesized')
                    def make(cwd):
                        return ACP(run, [args.dsh] + launch_args(patches, profile=profile), env, cwd)
                    return history(run, make, dirs, True)
                run.scenario('account-history-isolation',
                             'Account Flash low/off; six prompts; two independent sessions survive resume', real_history)
            else:
                offline(run, root, patches, env, dirs)
            run.scenario('owned-process-exit', 'All launched child processes reaped',
                         lambda: {'processes': [c.close() for c in run.clients]} if run.clients
                         else (_ for _ in ()).throw(Blocked('No process launched')))
    except BaseException as error:
        run.rows.append({'scenario': 'driver', 'expected': 'Bounded execution', 'actual': None,
                         'status': 'SKIP' if isinstance(error, Blocked) else 'FAIL',
                         'reason': str(error) if isinstance(error, (Blocked, Failed)) else type(error).__name__})
    finally:
        for client in run.clients:
            try:
                client.close()
            except Exception as error:
                run.rows.append({'scenario': 'cleanup', 'status': 'FAIL',
                                 'reason': type(error).__name__})
        run.stop.set()
    status = 'FAIL' if any(r['status'] == 'FAIL' for r in run.rows) else (
        'SKIP' if any(r['status'] == 'SKIP' for r in run.rows) else 'PASS')
    summary = {'scope': 'Native dsh only; Tivano Swift adapter NOT verified',
               'mode': 'real-account' if args.real_account else 'offline',
               'status': status, 'prompt_count': run.prompts,
               'session_ids': run.sessions, 'scenarios': run.rows,
               'limits': {'prompts_real_max': 8, 'concurrency_max': 2,
                          'round_seconds_max': 60, 'global_seconds_max': 300},
               'unverified': ['Detached descendants', 'Profile startup side effects in real-account mode']}
    Path(args.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'status': status, 'session_ids': run.sessions, 'summary_written': True}))
    return {'PASS': 0, 'FAIL': 1, 'SKIP': 2}[status]


if __name__ == '__main__':
    raise SystemExit(main())
