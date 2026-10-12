#!/usr/bin/env python3
"""Check native task/eval/workpool gates using isolated real OMP processes.

Each case has its own process group, HOME, gate and loopback model server.
No user credentials, cloud requests or Tivano launch are needed.
"""
import argparse
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import time

from omp_gate_stress import ModelServer, PREFIX, gate
from omp_offline_stress import RPC


class Handler(ModelServer):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        body = json.loads(raw)
        user = next((m.get('content', '') for m in reversed(body.get('messages', []))
                     if m.get('role') == 'user'), '')
        if PREFIX in str(user):
            self.rfile = io.BytesIO(raw)
            return super().do_POST()
        parent = any(PREFIX in str(m.get('content', '')) for m in body.get('messages', [])
                     if m.get('role') == 'user')
        if not parent:
            self.server.child_requests += 1
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            for delta, finish in (({'role': 'assistant', 'content': 'child-finished'}, None), ({}, 'stop')):
                chunk = {'id': 'child', 'object': 'chat.completion.chunk', 'created': 0,
                         'model': 'offline', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
                self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def cases():
    task = {'i': 'offline native control', 'context': 'No edits, tools or network. Reply child-finished.',
            'tasks': [{'name': 'Probe', 'task': 'Reply child-finished using no tools.',
                       'solutionSpace': 'One exact reply', 'model': 'tivano-offline/offline'}]}
    agent = {'language': 'js', 'code': "const h=await agent('Reply child-finished without tools.',"
             "{model:'tivano-offline/offline'}); return await h.wait(10);", 'timeout': 10}
    pool = {'language': 'js', 'code': "const p=await workpool({name:'PoolProbe',model:'tivano-offline/offline'});"
            " await p.push('Reply child-finished without tools.');"
            " await new Promise(r=>setTimeout(r,500)); return JSON.stringify(await p.peek());", 'timeout': 10}
    for tool, args in [('task', task), ('eval-agent', agent), ('workpool', pool)]:
        yield tool + '-control', 'fullAccess', True, tool, args
    for mode in ['fullAccess', 'supervised', 'autoAcceptEdits']:
        for tool, args in [('task', task), ('device-task', task), ('eval-agent', agent), ('workpool', pool)]:
            yield tool + '-denied-' + mode, mode, False, tool, args


def run_case(name, mode, allowed, tool, inputs, executable, directory, source):
    directory.mkdir()
    home = directory / 'home'
    home.mkdir()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.child_requests = 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    rpc = None
    try:
        state = gate(mode)
        state['allowTask'] = allowed
        (directory / 'gate.json').write_text(json.dumps(state))
        (directory / 'gate.ts').write_text(source)
        settings = directory / 'settings.yml'
        settings.write_text('autoResume: false\nbash:\n  autoBackground:\n    enabled: false\nasync:\n  enabled: false\ntask:\n  maxRecursionDepth: 1\n')
        provider = directory / 'provider.ts'
        provider.write_text('export default function(pi) {pi.registerProvider("tivano-offline",'
                            '{baseUrl:"http://127.0.0.1:PORT/v1",apiKey:"offline-only",api:"openai-completions",'
                            'models:[{id:"offline",name:"offline",reasoning:false,input:["text"],'
                            'cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:100000,maxTokens:1000}]});}'
                            .replace('PORT', str(server.server_port)))
        env = {'PATH': os.environ['PATH'], 'HOME': str(home), 'TMPDIR': str(directory),
               'XDG_CONFIG_HOME': str(home / '.config'), 'TIVANO_OMP_GATE': str(directory / 'gate.json'),
               'NO_PROXY': 'localhost,127.0.0.1', 'PI_SMOL_MODEL': 'tivano-offline/offline',
               'PI_SLOW_MODEL': 'tivano-offline/offline'}
        cmd = [executable, '--mode', 'rpc-ui', '--approval-mode', 'yolo', '--config', str(settings),
               '--no-extensions', '--no-skills', '--no-rules', '--no-title', '--no-lsp', '--no-pty',
               '-e', str(directory / 'gate.ts'), '-e', str(provider), '--model', 'tivano-offline/offline']
        rpc = RPC(cmd, directory, env, 30)
        if rpc.request('get_state')['data']['model']['provider'] != 'tivano-offline':
            raise RuntimeError('Offline provider not selected; refusing prompt')
        commands = rpc.request('get_available_commands')['data']['commands']
        if not any(c.get('name') == 'tivano-gate' for c in commands):
            raise RuntimeError('Gate readiness handshake missing')
        wire_tool = 'write' if tool == 'device-task' else 'eval' if tool in ('eval-agent', 'workpool') else tool
        if tool == 'device-task':
            inputs = {'path': 'xd://task', 'content': json.dumps(inputs)}
        identity = rpc.send('prompt', message=PREFIX + json.dumps({'id': name, 'tool': wire_tool, 'input': inputs}))
        ends = []

        def consume(event):
            if event.get('type') == 'extension_error':
                raise RuntimeError('Gate extension error: ' + str(event.get('error')))
            if event.get('type') == 'extension_ui_request' and event.get('method') == 'select':
                # Approving eval's outer call must not authorize a native child.
                rpc.send('extension_ui_response', id=event['id'], value='Approve')
            if event.get('type') == 'tool_execution_end' and event.get('toolCallId') == name:
                ends.append(event)
            return event.get('type') == 'prompt_result' and event.get('id') == identity

        result = rpc.until(consume)
        if result.get('status') != 'completed' or len(ends) != 1:
            raise RuntimeError('Missing tool result or wrong terminal status')
        end = ends[0]
        text = '\n'.join(p.get('text', '') for p in end.get('result', {}).get('content', []))
        error = end.get('isError') is True or end.get('result', {}).get('isError') is True
        if allowed and error or not allowed and (('Declined:' not in text) or (tool != 'workpool' and not error)):
            raise RuntimeError('Unexpected gate result: ' + text[:800])
        deadline = time.monotonic() + (5 if allowed else 0.5)
        while time.monotonic() < deadline and (not allowed or server.child_requests == 0):
            time.sleep(0.05)
        if (server.child_requests > 0) != allowed:
            raise RuntimeError(f'Child request mismatch: {server.child_requests}; {text[:800]}')
        return {'name': name, 'passed': True, 'child_requests': server.child_requests, 'tool_text': text[:800]}
    finally:
        if rpc:
            rpc.close()
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--omp', default=shutil.which('omp'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not args.omp:
        parser.error('omp must be installed')
    parent = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='tivano-omp-native-'))
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    root = Path(__file__).resolve().parents[1]
    source = (root / 'Tivano/Services/Providers/OmpCLI.swift').read_text().split('private static let extensionSource = #"""', 1)[1].split('"""#', 1)[0]
    rows = []
    for name, mode, allowed, tool, inputs in cases():
        try:
            rows.append(run_case(name, mode, allowed, tool, inputs, str(Path(args.omp).resolve()), out / name, source))
        except Exception as error:
            rows.append({'name': name, 'passed': False, 'error': str(error)})
    summary = {'passed': len(rows) == 15 and all(r['passed'] for r in rows), 'results': rows,
               'artifacts': str(out), 'scope': 'Real OMP native spawn hooks; separate processes and loopback servers; no Swift/UI coverage.'}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
