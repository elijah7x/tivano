#!/usr/bin/env python3
"""Actual AppModel -> ThreadRuntime -> OmpSession factory -> real OMP -> Store.

No GUI/App entry. Only a private Capture root and HOME, official installed OMP,
a private real MCP stdio server and a loopback model. All owned children share
the runner's new process group and are cleaned without touching existing Apps.
"""
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

from omp_gate_stress import ModelServer, PREFIX

ROOT = Path(__file__).resolve().parents[1]
PARENT = ROOT / 'build.noindex/t08-thor'


class Handler(ModelServer):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        body = json.loads(raw)
        with (self.server.evidence / 'model-requests.jsonl').open('a') as log:
            log.write(json.dumps(body, ensure_ascii=False) + '\n')
        user = next((m.get('content', '') for m in reversed(body.get('messages', [])) if m.get('role') == 'user'), '')
        if isinstance(user, list):
            user = '\n'.join(p.get('text', '') for p in user if isinstance(p, dict))
        case = False
        if PREFIX in str(user):
            suffix = str(user).split(PREFIX, 1)[1].lstrip()
            try:
                _, end = json.JSONDecoder().raw_decode(suffix)
                case = not suffix[end:].strip()
            except json.JSONDecodeError:
                pass
        if case:
            self.rfile = io.BytesIO(raw)
            super().do_POST()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        chunk = {'id': 'title', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'offline',
                 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'Thor fixture title'}, 'finish_reason': None}]}
        self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
        chunk['choices'][0] = {'index': 0, 'delta': {}, 'finish_reason': 'stop'}
        self.wfile.write(('data: ' + json.dumps(chunk) + '\n\ndata: [DONE]\n\n').encode())
        self.wfile.flush()


def main():
    parent = PARENT / 'runtime'
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    home = out / 'home'; home.mkdir()
    extensions = home / '.omp/agent/extensions'; extensions.mkdir(parents=True)
    tmp = out / 'tmp'; tmp.mkdir()
    debug = PARENT / 'DerivedData/Build/Products/Debug'
    mac = debug / 'Tivano Dev.app/Contents/MacOS'
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-DDEBUG', '-I', str(debug),
               '-F', str(debug / 'PackageFrameworks'), '-F', str(debug), '-Xlinker', '-rpath', '-Xlinker', str(mac),
               '-Xlinker', '-rpath', '-Xlinker', str(debug / 'PackageFrameworks'), str(mac / 'Tivano Dev.debug.dylib'),
               str(ROOT / 'scripts/fixtures/omp_adapter/ThorIntegration.swift'), '-o', str(out / 'integration')]
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True; server.evidence = out
    threading.Thread(target=server.serve_forever, daemon=True).start()
    (extensions / 'offline.ts').write_text('''export default function(pi) {
 pi.registerProvider("tivano-offline", {baseUrl:"http://127.0.0.1:PORT/v1",apiKey:"offline-only",api:"openai-completions",
 models:[{id:"offline",name:"Thor runtime loopback",reasoning:false,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:1048576,maxTokens:4096},
 {id:"reasoning",name:"Thor reasoning loopback",reasoning:true,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:1048576,maxTokens:4096,compat:{supportsReasoningEffort:true}}]});
}'''.replace('PORT', str(server.server_port)))
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(home), 'TMPDIR': str(tmp),
           'NO_PROXY': '127.0.0.1,localhost', 'LANG': 'en_US.UTF-8', 'T08_EVIDENCE': str(out),
           'T08_OMP': os.environ.get('T08_OMP') or shutil.which('omp'), 'T08_PYTHON': sys.executable,
           'T08_MCP_SERVER': str(ROOT / 'scripts/fixtures/omp_adapter/thor_mcp_server.py')}
    process = None
    stages = []
    try:
        with (out / 'compile.log').open('w') as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        stages.append({'command': command, 'exit': result.returncode, 'stage': 'compile'})
        if result.returncode:
            raise RuntimeError('compile failed')
        command = [str(out / 'integration'), '--website-captures', str(out / 'capture-runtime'), '--runtime']
        with (out / 'runtime.log').open('w') as log:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            result = process.wait(timeout=200)
        stages.append({'command': command, 'exit': result, 'stage': 'runtime'})
        data = json.loads((out / 'runtime-integration-summary.json').read_text())
        requests = [json.loads(line) for line in (out / 'model-requests.jsonl').read_text().splitlines()]
        selection = any(r.get('model') == 'reasoning' and r.get('reasoning_effort') == 'high' for r in requests)
        if not selection:
            raise RuntimeError('valid model/high effort did not reach actual provider request')
        if any('Must not reach model' in json.dumps(r.get('messages', [])) for r in requests):
            raise RuntimeError('invalid model/effort consumed a model request')
        summary = {'passed': result == 0 and data.get('passed') is True, 'valid_model_effort_effective': selection, 'invalid_selections_model_requests': 0, 'stages': stages, 'artifacts': str(out),
                   'scope': 'Actual compiled App factory and runtime, real OMP/MCP, actual Store, loopback model, no GUI/credentials/storage substitutes.'}
    except Exception as error:
        summary = {'passed': False, 'error': str(error), 'stages': stages, 'artifacts': str(out)}
    finally:
        if process:
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            if process.poll() is None:
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=3)
        server.shutdown(); server.server_close()
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
