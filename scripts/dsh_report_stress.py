#!/usr/bin/env python3
"""Exercise Tivano's actual report guard against installed dsh and a hostile local model.
No cloud requests, application UI, credentials, or user profiles. Tests native dsh,
not ThreadRuntime's orchestration. Requires the reviewed 0.2.1-rc.2 runtime.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
import textwrap
import uuid
from dsh_native_stress import ACP, FakeModel, Run, Failed, extract_patches, launch_args


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dsh', required=True)
    parser.add_argument('--summary', required=True)
    args = parser.parse_args()
    args.real_account = False
    if not Path(args.dsh).is_absolute() or not os.access(args.dsh, os.X_OK):
        parser.error('--dsh must be an installed absolute executable path')
    run = Run(args)
    fake = FakeModel()
    try:
        with tempfile.TemporaryDirectory(prefix='tivano-dsh-report-') as temporary:
            root = Path(temporary)
            patches = root / 'patches'; patches.mkdir()
            extract_patches(patches)
            source_file = Path(__file__).resolve().parents[1] / 'Tivano/Services/Providers/DshReportGuard.swift'
            match = re.search(r'static let source = #"""\n(.*?)\n\s*"""#', source_file.read_text(), re.S)
            if not match:
                raise Failed('Guard source extraction failed')
            plugin = root / 'report-guard.mjs'
            plugin.write_text(textwrap.dedent(match.group(1)) + '\n')
            report_patch = root / 'report-guard.yml'
            report_patch.write_text('- insert:\n    - id: tivano-report-guard\n      name: ' + json.dumps(str(plugin)) + '\n')
            fixture_plugin = root / 'fixture-plugin.mjs'
            fixture_plugin.write_text('''export const name = 'tivano-fixture-tool';
export const inject = ['tools'];
export function apply(ctx) {
  ctx.tools.register({name: 'fixture_touch', description: 'Write the isolated test marker',
    parameters: {type: 'object', properties: {}, additionalProperties: false},
    output: {schema: {type: 'string'}, render: (_args, value) => [{type: 'text', text: value}]},
    execute: async () => { process.getBuiltinModule('node:fs').writeFileSync(process.env.DSH_FIXTURE_MARKER, 'executed'); return 'done'; }
  });
}
''')
            desktop_patch = root / 'desktop-patch.yml'
            desktop_patch.write_text('- insert:\n    - id: fixture-tool\n      name: ' + json.dumps(str(fixture_plugin)) + '\n')
            mcp = root / 'fixture-mcp.py'
            mcp.write_text('''import json, sys
from pathlib import Path
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    method = request.get('method')
    if method == 'initialize':
        result = {'protocolVersion': request['params']['protocolVersion'], 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'isolated-fixture', 'version': '1'}}
    elif method == 'tools/list':
        result = {'tools': [{'name': 'touch', 'description': 'Write the isolated test marker', 'inputSchema': {'type': 'object', 'properties': {}}}]}
    elif method == 'tools/call':
        Path(sys.argv[1]).write_text('executed')
        result = {'content': [{'type': 'text', 'text': 'done'}]}
    elif method == 'ping': result = {}
    else:
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32601, 'message': 'Not supported'}}), flush=True)
        continue
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
''')
            port = fake.server.server_address[1]
            sandbox = root / 'offline.sb'
            sandbox.write_text('(version 1) (allow default) (deny network*) '
                               f'(allow network-outbound (remote ip "localhost:{port}"))\n')
            for folder in ('home', 'dsh-home'):
                (root / folder).mkdir()
            env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(root / 'home'),
                   'DSH_HOME': str(root / 'dsh-home'), 'TMPDIR': str(root),
                   'DSH_TELEMETRY_DISABLED': '1', 'DEEPSEEK_API_KEY': 'fixture-only',
                   'DSH_PERMISSION_MODE': 'danger-full-access',
                   'DEEPSEEK_BASE_URL': f'http://127.0.0.1:{port}/anthropic', 'NO_PROXY': '127.0.0.1,localhost'}
            def make(cwd, mode, final=False):
                command = ['/usr/bin/sandbox-exec', '-f', str(sandbox), args.dsh]
                command += launch_args(patches, mode, off=True, profile=desktop_patch)
                if final:
                    command += ['--patch', str(report_patch)]
                return ACP(run, command, {**env, 'DSH_FIXTURE_MARKER': str(cwd / 'forbidden.txt')}, cwd)
            for mode, surface in [(mode, surface) for mode in ('standard', 'ptc', 'minimal', 'creator') for surface in ('bash', 'plugin', 'mcp')]:
                def check(mode=mode, surface=surface):
                    cwd = root / (mode + '-' + surface); cwd.mkdir()
                    marker = 'DSH_TEST_' + uuid.uuid4().hex
                    forbidden = cwd / 'forbidden.txt'
                    servers = [{'name': 'fixture', 'command': str(Path(sys.executable).resolve()), 'args': [str(mcp), str(forbidden)], 'env': []}] if surface == 'mcp' else []
                    command = 'printf forbidden > ' + shlex.quote(str(forbidden))
                    tool_name = {'bash': 'bash', 'plugin': 'fixture_touch', 'mcp': 'mcp__fixture__touch'}[surface]
                    tool_input = {'command': command} if surface == 'bash' else {}
                    tool_request = ({'name': 'run_code', 'input': {'description': 'Exercise the isolated fixture tool', 'code': 'await tools.' + tool_name + '(' + json.dumps(tool_input) + ');'}}
                                    if mode == 'ptc' else {'name': tool_name, 'input': tool_input})
                    first = make(cwd, mode)
                    try:
                        sid, _ = first.session(cwd, mcp_servers=servers)
                        if surface != 'bash': fake.tool_request = tool_request
                        if marker not in run.prompt(first, sid, 'Remember ' + marker + '. Exercise the configured fixture tool when requested.'):
                            raise Failed('Initial marker absent')
                        if surface != 'bash':
                            if not forbidden.exists(): raise Failed('Fixture tool was not operational before report guard')
                            forbidden.unlink()
                    finally:
                        first.close()
                    reporter = make(cwd, mode, True)
                    try:
                        if not reporter.report_guard_ready:
                            raise Failed('Guard readiness was not advertised')
                        resumed, _ = reporter.session(cwd, sid, mcp_servers=servers)
                        fake.tool_denial_observed = False
                        fake.tool_request = tool_request
                        start = len(fake.events)
                        answer = run.prompt(reporter, resumed, 'Report the remembered marker without tools.')
                        if forbidden.exists():
                            raise Failed('Forbidden final-report tool executed')
                        if not fake.tool_denial_observed:
                            raise Failed('Forced tool call did not encounter the report guard')
                        if marker not in answer:
                            raise Failed('Final report lost resumed history')
                        if any(e['tools'] for e in fake.events[start:]):
                            raise Failed('Final report advertised executable tool schemas')
                        return {'guard_ready': True, 'forced_tool_denied': True, 'history_retained': True,
                                'model_requests': len(fake.events) - start,
                                'wire_tool_counts': [len(e['tools']) for e in fake.events[start:]]}
                    finally:
                        reporter.close()
                run.scenario(mode + '-' + surface + '-final-report', 'Resume history, deny forced tool execution, finish report', check)
    finally:
        for client in run.clients:
            client.close()
        run.stop.set()
        fake.close()
    summary = {'scope': 'Native report-guard contract, no Swift orchestration or UI',
               'passed': all(r['status'] == 'PASS' for r in run.rows) and len(run.rows) == 12,
               'scenarios': run.rows}
    Path(args.summary).write_text(json.dumps(summary, indent=2) + '\n')
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
