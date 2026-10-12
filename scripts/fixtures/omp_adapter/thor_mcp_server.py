#!/usr/bin/env python3
"""Private stdio MCP fixture. No access outside T08_MCP_ROOT."""
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['T08_MCP_ROOT']).resolve()
root.mkdir(parents=True, exist_ok=True)
names = ['read_marker', 'write_marker', 'tool_error', 'rpc_error', 'disconnect', 'successful_error_text']
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request['method']
    response = {'jsonrpc': '2.0', 'id': request['id']}
    if method == 'initialize':
        response['result'] = {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}},
                              'serverInfo': {'name': 'Thor T08 private fixture', 'version': '1'}}
    elif method == 'tools/list':
        response['result'] = {'tools': [{'name': name, 'description': 'Private T08 ' + name,
            'inputSchema': {'type': 'object', 'properties': {'marker': {'type': 'string'}}, 'required': ['marker']}}
            for name in names]}
    elif method == 'tools/call':
        name = request['params']['name']
        marker = request['params']['arguments']['marker']
        if Path(marker).name != marker:
            response['error'] = {'code': -32602, 'message': 'marker must be a basename'}
        else:
            with (root / 'calls.jsonl').open('a') as log:
                log.write(json.dumps({'name': name, 'marker': marker}) + '\n')
            if name == 'disconnect':
                sys.exit(7)
            elif name == 'rpc_error':
                response['error'] = {'code': -32000, 'message': 'THOR_RPC_FAILURE'}
            else:
                if name == 'write_marker':
                    (root / marker).write_text('thor-mcp-ok')
                    text = 'thor-mcp-ok'
                elif name == 'read_marker':
                    text = (root / 'seed.txt').read_text()
                elif name == 'tool_error':
                    text = 'THOR_MCP_FAILURE'
                else:
                    text = 'Error: this is successful quoted content'
                response['result'] = {'content': [{'type': 'text', 'text': text}], 'isError': name == 'tool_error'}
    else:
        response['error'] = {'code': -32601, 'message': 'unknown method'}
    print(json.dumps(response), flush=True)
