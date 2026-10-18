#!/usr/bin/env python3
"""Credential-free stdio MCP peer. Only writes beneath the runner-owned root."""
import json
import os
from pathlib import Path
import sys
import time


def main():
    root = Path(sys.argv[1])
    marker = sys.argv[2]
    if root != root.resolve() or not root.name.startswith('tivano-dsh-app-native-'):
        raise SystemExit('noncanonical fixture root')
    manifest = json.loads((root / 'manifest.json').read_text())
    if manifest['marker'] != marker:
        raise SystemExit('marker mismatch')

    def record(event):
        event.update(pid=os.getpid(), ppid=os.getppid(), time=time.time())
        # Independent of both the model response and App timeline.
        fd = os.open(root / 'mcp-events.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (json.dumps(event) + '\n').encode())
        finally:
            os.close(fd)

    record({'event': 'start'})
    for line in sys.stdin:
        request = json.loads(line)
        if 'id' not in request:
            continue
        method = request.get('method')
        record({'event': 'request', 'method': method, 'id': request['id']})
        if method == 'initialize':
            if (root / 'fail-initialize').exists():
                record({'event': 'initialize-failure', 'marker': marker})
                print(json.dumps({'jsonrpc': '2.0', 'id': request['id'],
                                  'error': {'code': -32603, 'message': 'Owned fixture initialization failure'}}), flush=True)
                continue
            result = {'protocolVersion': request['params']['protocolVersion'], 'capabilities': {'tools': {}},
                      'serverInfo': {'name': 'native-fixture', 'version': '1'}}
        elif method == 'tools/list':
            schema = {'type': 'object', 'properties': {'marker': {'type': 'string'}, 'mode': {'type': 'string'}},
                      'required': ['marker', 'mode'], 'additionalProperties': False}
            result = {'tools': [{'name': name, 'description': 'Isolated native fixture ' + name, 'inputSchema': schema}
                                for name in ('touch', 'fail')]}
        elif method == 'tools/call':
            args = request['params'].get('arguments', {})
            name = request['params'].get('name')
            mode = args.get('mode')
            if args.get('marker') != marker or mode not in ('standard', 'ptc', 'minimal', 'creator'):
                result = {'isError': True, 'content': [{'type': 'text', 'text': 'Fixture arguments rejected'}]}
            elif name == 'touch':
                target = root / 'scratch' / (mode + '-mcp.txt')
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'w') as handle:
                    handle.write(marker)
                record({'event': 'effect', 'mode': mode, 'marker': marker, 'path': str(target), 'tool': name})
                result = {'content': [{'type': 'text', 'text': 'MCP_EFFECT_' + marker}]}
            else:
                record({'event': 'failure', 'mode': mode, 'marker': marker, 'tool': name})
                result = {'isError': True, 'content': [{'type': 'text', 'text': 'MCP_FIXTURE_FAILURE_' + marker}]}
        elif method == 'ping':
            result = {}
        else:
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32601, 'message': 'Unknown method'}}), flush=True)
            continue
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
    record({'event': 'eof'})


if __name__ == '__main__':
    main()
