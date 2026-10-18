"""Bounded Messages API fixture; never simulates ACP or executes tools."""
import http.server
import json
import re
import shlex
import threading
import time


class Model:
    def __init__(self, root, marker):
        self.root, self.marker = root, marker
        self.lock = threading.Lock()
        self.sent = set()
        self.requests = 0
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 2 * 1024 * 1024:
                    self.send_error(413)
                    return
                body = json.loads(self.rfile.read(size))
                messages = body.get('messages', [])
                text = json.dumps(messages)
                matches = re.findall(r'NATIVE_FIXTURE:' + re.escape(marker) + r':(standard|ptc|minimal|creator):(file|mcp|tool-failure|bad-mcp)', text)
                if not matches:
                    with owner.lock, (root / 'model-events.jsonl').open('a') as handle:
                        handle.write(json.dumps({'mode': 'negative', 'scenario': 'unexpected-model-request',
                                                 'first': True, 'toolResults': [], 'tools': []}) + '\n')
                    self.send_error(400, 'Missing fixture tag')
                    return
                mode, scenario = matches[-1]
                key = mode + '/' + scenario
                with owner.lock:
                    owner.requests += 1
                    if owner.requests > 40:
                        self.send_error(429)
                        return
                    first = key not in owner.sent
                    owner.sent.add(key)
                    event = {'time': time.time(), 'mode': mode, 'scenario': scenario,
                             'tools': [t['name'] for t in body.get('tools', [])], 'first': first,
                             'toolCalls': [{'id': b.get('id'), 'name': b.get('name')} for m in messages
                                           for b in (m.get('content', []) if isinstance(m.get('content'), list) else [])
                                           if isinstance(b, dict) and b.get('type') == 'tool_use'],
                             'toolResults': [b for m in messages for b in (m.get('content', []) if isinstance(m.get('content'), list) else [])
                                             if isinstance(b, dict) and b.get('type') == 'tool_result']}
                    with (root / 'model-events.jsonl').open('a') as handle:
                        handle.write(json.dumps(event) + '\n')
                if scenario == 'file':
                    command = 'printf %s ' + shlex.quote(marker) + ' > ' + shlex.quote(str(root / 'scratch' / (mode + '-file.txt')))
                    name, arguments = 'bash', {'command': command}
                elif scenario == 'tool-failure':
                    name, arguments = 'bash', {'command': 'printf %s ' + shlex.quote('TOOL_FIXTURE_FAILURE_' + marker) + ' >&2; exit 17'}
                else:
                    name = 'mcp__custom-native-fixture__' + ('touch' if scenario == 'mcp' else 'fail')
                    arguments = {'mode': mode, 'marker': marker}
                if name == 'bash' and mode != 'minimal':
                    arguments['description'] = 'Native fixture ' + marker
                if mode == 'ptc':
                    code = 'const result = await tools[' + json.dumps(name) + '](' + json.dumps(arguments) + '); const text = typeof result === "string" ? result : JSON.stringify(result); console.log(text);'
                    if scenario in ('tool-failure', 'bad-mcp'):
                        code += ' if ((result && typeof result.exitCode === "number" && result.exitCode !== 0) || (result && result.isError === true) || text.includes("[exit code: 17]") || text.includes("MCP_FIXTURE_FAILURE_")) throw new Error(text);'
                    name, arguments = 'run_code', {'description': 'Native fixture ' + marker, 'code': code}
                block = {'type': 'tool_use', 'id': 'native-' + mode + '-' + scenario, 'name': name, 'input': {}} if first else {'type': 'text', 'text': ''}
                delta = {'type': 'input_json_delta', 'partial_json': json.dumps(arguments)} if first else {'type': 'text_delta', 'text': 'FIXTURE_DONE_' + marker}
                events = [
                    ('message_start', {'message': {'id': 'native-fixture', 'type': 'message', 'role': 'assistant',
                        'model': body.get('model', 'fixture'), 'content': [], 'stop_reason': None,
                        'usage': {'input_tokens': 10, 'output_tokens': 0}}}),
                    ('content_block_start', {'index': 0, 'content_block': block}),
                    ('content_block_delta', {'index': 0, 'delta': delta}),
                    ('content_block_stop', {'index': 0}),
                    ('message_delta', {'delta': {'stop_reason': 'tool_use' if first else 'end_turn', 'stop_sequence': None},
                                       'usage': {'output_tokens': 2}}), ('message_stop', {})]
                payload = ''.join('event: ' + kind + '\ndata: ' + json.dumps({'type': kind, **value}) + '\n\n' for kind, value in events).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
