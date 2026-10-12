#!/usr/bin/env python3
"""Actual compiled MCPBridge/config + real OMP gate, using private stdio server.

Pass --integration <successful t08_thor_integration artifact dir>. Model calls
are exclusively loopback. Checks approvals, tool isError and server/file markers.
Retains a baseline false-success reproduction separately from fixed acceptance.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

from omp_gate_stress import ModelServer, PREFIX, gate
from omp_offline_stress import RPC

ROOT = Path(__file__).resolve().parents[1]


def run_case(rpc, gate_file, markers, name, tool, state, allowed, answer=None, expected_approvals=0, device=True):
    gate_file.write_text(json.dumps(state))
    inputs = {'marker': name + '.txt'}
    registered = 'mcp__thor__' + tool
    actual_tool = 'write' if device else registered
    actual_input = {'path': 'xd://' + registered, 'content': json.dumps(inputs)} if device else inputs
    identity = rpc.send('prompt', message=PREFIX + json.dumps({'id': name, 'tool': actual_tool, 'input': actual_input}))
    approvals, ends = [], []

    def consume(event):
        if event.get('type') == 'extension_error':
            raise RuntimeError('extension error: ' + str(event))
        if event.get('type') == 'extension_ui_request' and event.get('method') == 'select':
            title = event.get('title', '')
            if not title.startswith('tivano-gate '):
                raise RuntimeError('unexpected approval title')
            payload = json.loads(title[len('tivano-gate '):])
            inner = bool(approvals) or not device
            if payload.get('kind') != 'tool' or payload.get('toolName') != (registered if inner else 'write') or payload.get('input') != (inputs if inner else actual_input):
                raise RuntimeError('MCP approval payload mismatch: ' + str(payload))
            approvals.append(payload)
            rpc.send('extension_ui_response', value=answer or 'Deny', **{'id': event['id']})
        if event.get('type') == 'tool_execution_end':
            ends.append(event)
        return event.get('type') == 'prompt_result' and event.get('id') == identity

    completion = rpc.until(consume)
    if completion.get('status') != 'completed' or len(ends) != 1:
        raise RuntimeError('MCP prompt/tool completion mismatch')
    if len(approvals) != expected_approvals:
        raise RuntimeError('approval count mismatch: ' + str(len(approvals)))
    if ends[0].get('isError', False) is not (not allowed):
        raise RuntimeError('MCP tool falsely succeeded or failed: ' + json.dumps(ends[0]))
    called = [json.loads(line) for line in (markers / 'calls.jsonl').read_text().splitlines()] if (markers / 'calls.jsonl').exists() else []
    matches = [c for c in called if c['marker'] == inputs['marker']]
    expected_call = allowed or tool in ('tool_error', 'rpc_error', 'disconnect')
    if len(matches) != (1 if expected_call else 0):
        raise RuntimeError('server call marker disagrees with gate')
    exists = (markers / inputs['marker']).exists()
    if exists != (allowed and tool == 'write_marker'):
        raise RuntimeError('file marker disagrees with gate')
    if exists and (markers / inputs['marker']).read_text() != 'thor-mcp-ok':
        raise RuntimeError('wrong marker content')
    return {'name': name, 'passed': True, 'approvals': approvals, 'tool_end': ends[0], 'server_calls': len(matches), 'file_exists': exists}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--integration', type=Path, required=True)
    args = parser.parse_args()
    integration = args.integration.resolve()
    parent = ROOT / 'build.noindex/t08-thor/mcp'
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    markers = out / 'mcp-markers'; markers.mkdir()
    (markers / 'seed.txt').write_text('thor-read-中文🙂')
    home = out / 'home'; home.mkdir()
    gate_file = out / 'gate.json'; gate_file.write_text(json.dumps(gate()))
    settings = out / 'settings.yml'; settings.write_text('autoResume: false\nasync:\n  enabled: false\n')
    bridge = Path((integration / 'exported-bridge-path.txt').read_text())
    extension = Path((integration / 'exported-extension-path.txt').read_text())
    # Keep the actual Swift-generated configuration shape and server definition;
    # only relocate this run's marker directory, so repeated acceptance is independent.
    configuration = json.loads((integration / 'exported-mcp-config.json').read_text())
    configuration['mcpServers']['thor']['env']['T08_MCP_ROOT'] = str(markers)
    config = out / 'task-config.json'
    config.write_text(json.dumps(configuration, indent=2))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), ModelServer)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    provider = out / 'offline-provider.ts'
    provider.write_text('''export default function(pi) {
 pi.registerProvider("tivano-offline", {baseUrl:"http://127.0.0.1:PORT/v1",apiKey:"offline-only",api:"openai-completions",
 models:[{id:"offline",name:"Thor MCP loopback",reasoning:false,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:1048576,maxTokens:4096}]});
}'''.replace('PORT', str(server.server_port)))
    env = {'PATH': os.environ.get('PATH', ''), 'HOME': str(home), 'TMPDIR': str(out), 'NO_PROXY': '127.0.0.1,localhost',
           'TIVANO_OMP_GATE': str(gate_file), 'TIVANO_MCP_BRIDGE': str(bridge), 'TIVANO_MCP_CONFIG': str(config)}
    executable = os.environ.get('T08_OMP') or shutil.which('omp')
    results, regression = [], {}
    rpc = None

    def start(label, source, configuration=config):
        directory = out / label; directory.mkdir()
        environment = dict(env, TIVANO_MCP_CONFIG=str(configuration))
        command = [executable, '--mode', 'rpc-ui', '--approval-mode', 'yolo', '--config', str(settings),
                   '--no-extensions', '--no-skills', '--no-rules', '-e', str(source), '-e', str(provider), '--model', 'tivano-offline/offline']
        (directory / 'command.json').write_text(json.dumps(command, indent=2))
        process = RPC(command, directory, environment, 45)
        process.request('get_available_commands')
        state = process.request('get_state')
        if state.get('data', {}).get('model', {}).get('provider') != 'tivano-offline':
            process.close(); raise RuntimeError('refusing non-loopback model')
        return process

    try:
        baseline_source = subprocess.check_output(['git', 'show', '300db74dad06d43a421b48b5ca2c0d166ca9cdc7:Tivano/Services/Providers/OmpCLI.swift'], cwd=ROOT, text=True)
        baseline = out / 'baseline-gate.ts'
        baseline.write_text(baseline_source.split('private static let extensionSource = #"""', 1)[1].split('"""#', 1)[0])
        rpc = start('baseline', baseline)
        # Record the actual defect: MCP isError was returned as successful OMP prose.
        prior = run_case(rpc, gate_file, markers, 'baseline-false-success', 'tool_error', gate(), True)
        regression = {'baseline_false_success_observed': prior['tool_end'].get('isError', False) is False,
                      'baseline_result': prior, 'baseline_commit': '300db74dad06d43a421b48b5ca2c0d166ca9cdc7'}
        rpc.close(); rpc = start('fixed', extension)
        cases = [
            ('supervised-write-approve', 'write_marker', gate('supervised'), True, 'Approve', 2),
            ('supervised-write-deny', 'write_marker', gate('supervised'), False, 'Deny', 1),
            ('supervised-read-approve', 'read_marker', gate('supervised'), True, 'Approve', 2),
            ('auto-write-deny', 'write_marker', gate('autoAcceptEdits'), False, 'Deny', 1),
            ('auto-write-approve', 'write_marker', gate('autoAcceptEdits'), True, 'Approve', 2),
            ('auto-read-deny', 'read_marker', gate('autoAcceptEdits'), False, 'Deny', 1),
            ('full-write', 'write_marker', gate(), True, None, 0),
            ('full-read', 'read_marker', gate(), True, None, 0),
            ('plan-write', 'write_marker', gate(interaction='plan'), False, None, 0),
            ('plan-read', 'read_marker', gate(interaction='plan'), False, None, 0),
            ('final-write', 'write_marker', gate(final=True), False, None, 0),
            ('final-read', 'read_marker', gate(final=True), False, None, 0),
            ('mcp-error', 'tool_error', gate(), False, None, 0),
            ('rpc-error', 'rpc_error', gate(), False, None, 0),
            ('success-quoting-error', 'successful_error_text', gate(), True, None, 0),
            ('server-disconnect', 'disconnect', gate(), False, None, 0),
        ]
        for name, tool, state, allowed, answer, count in cases:
            results.append(run_case(rpc, gate_file, markers, name, tool, state, allowed, answer, count))
        rpc.close()
        bad = out / 'failed-config.json'; bad.write_text(json.dumps({'mcpServers': {'thor': {'command': str(out / 'missing-server')}}}))
        rpc = start('failed-bridge-server', extension, bad)
        results.append(run_case(rpc, gate_file, markers, 'registration-failed', 'write_marker', gate(), False))
        text = (out / 'failed-bridge-server/stderr.log').read_text()
        if 'tivano mcp: skipping thor:' not in text:
            raise RuntimeError('bridge failure diagnostic missing')
        regression['fixed_errors_are_failed'] = True
        summary = {'passed': bool(results) and all(r['passed'] for r in results), 'results': results, 'regression': regression,
                   'artifacts': str(out), 'bridge': str(bridge), 'config': str(config), 'scope': 'Actual compiled App bridge/config; real MCP stdio and real OMP, loopback model; no GUI or storage shims.'}
    except Exception as error:
        summary = {'passed': False, 'error': str(error), 'results': results, 'regression': regression, 'artifacts': str(out)}
    finally:
        if rpc: rpc.close()
        server.shutdown(); server.server_close()
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
