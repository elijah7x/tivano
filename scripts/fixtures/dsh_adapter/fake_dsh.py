#!/usr/bin/env python3
"""Offline ACP peer. All inbound frames, including typed IDs, are retained."""
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time

root = Path(os.environ['DSH_TEST_ROOT'])
case = os.environ['DSH_TEST_CASE']
label = os.environ.get('DSH_TEST_LABEL', 'one')
sid = 'session-' + label
alive = root / ('alive-' + str(os.getpid()))
alive.write_text(label)
log = (root / ('wire-' + str(os.getpid()) + '.jsonl')).open('a', buffering=1)
lease = root / 'lease'


def quit_peer(*_):
    alive.unlink(missing_ok=True)
    os._exit(0)


def watchdog():
    while lease.exists():
        time.sleep(0.1)
    quit_peer()


signal.signal(signal.SIGTERM, quit_peer)
threading.Thread(target=watchdog, daemon=True).start()


def emit(value):
    print(json.dumps(dict(jsonrpc='2.0', **value)), flush=True)


def reply(request, result):
    emit({'id': request['id'], 'result': result})


def update(update_type, session=None, **fields):
    emit({'method': 'session/update', 'params': {'sessionId': session or sid, 'update': dict(sessionUpdate=update_type, **fields)}})


def permission(identifier, tool='tool', session=None):
    emit({'id': identifier, 'method': 'session/request_permission', 'params': {
        'sessionId': session or sid, 'toolCall': {'toolCallId': tool},
        'options': [{'optionId': 'allow', 'kind': 'allow_once', 'name': 'Allow'}, {'optionId': 'deny', 'kind': 'reject_once', 'name': 'Deny'}]}})


def config():
    if case == 'probe-unusable-route':
        return [{'id': 'model', 'category': 'model', 'type': 'select',
                 'currentValue': '["deepseek-official","deepseek-v4-flash"]',
                 'options': [{'group': route, 'name': route, 'options': [
                     {'value': json.dumps([route, 'deepseek-v4-' + model], separators=(',', ':')), 'name': model}
                     for model in ['pro', 'flash']]} for route in ['deepseek-official', 'deepseek-account']]}]
    return [{'id': 'model', 'category': 'model', 'type': 'select', 'currentValue': 'deepseek-account/v4-flash',
             'options': [{'group': 'deepseek-account', 'name': 'Account', 'options': [
                 {'value': 'deepseek-account/v4-flash', 'name': 'Flash'},
                 {'value': 'deepseek-account/v4-pro', 'name': 'Pro'}]}]}]


pending = None
answers = []
selected_model = 'deepseek-account/v4-flash'
try:
    for line in sys.stdin:
        request = json.loads(line)
        log.write(json.dumps(request) + '\n')
        method = request.get('method')
        params = request.get('params', {})
        if method is None:
            answers.append(request)
            needed = 2 if case == 'typed-ids' else 1
            if pending and case not in ('cancel', 'acp-cancel', 'cancel-rebuild') and len(answers) >= needed:
                reply(pending, {'stopReason': 'end_turn'})
                pending = None
        elif method == 'initialize':
            if case == 'final-report' and any(arg.endswith('/report-guard.yml') for arg in sys.argv[1:]):
                emit({'method': 'tivano/report_guard_ready', 'params': {'version': 1}})
            if case == 'startup-failure':
                emit({'id': request['id'], 'error': {'code': -32603, 'message': 'Fixture startup failed'}})
            else:
                capabilities = {} if case == 'resume-unsupported' else {'resume': {}}
                reply(request, {'protocolVersion': 1, 'agentCapabilities': {'sessionCapabilities': capabilities}})
        elif method == 'session/resume':
            if case == 'resume-timeout':
                continue
            if case == 'resume-permission':
                permission('old-permission', session='foreign')
                reply(request, {'sessionId': params['sessionId'], 'configOptions': config()})
                continue
            message = {'resume-auth': 'Authentication required', 'resume-lock': 'database is locked', 'resume-missing': 'Session not found'}[case]
            emit({'id': request['id'], 'error': {'code': -32000, 'message': message}})
        elif method == 'session/new':
            if case == 'mixed-mcp' and any(s['name'] == 'broken' for s in params['mcpServers']):
                emit({'id': request['id'], 'error': {'code': -32603, 'message': 'MCP initialization failed', 'data': {'details': 'mcp-client(broken): refused; healthy initialized'}}})
            else:
                reply(request, {'sessionId': sid, 'configOptions': config()})
        elif method in ('session/set_config_option', 'session/set_model'):
            if case not in ('selection-timeout', 'probe-timeout'):
                selected_model = params.get('value', params.get('modelId', selected_model))
                if case == 'probe-unusable-route' and ('deepseek-official' in selected_model or os.environ.get('DEEPSEEK_API_KEY')):
                    emit({'id': request['id'], 'error': {'code': -32602, 'message': 'Unavailable fixture credential route'}})
                    continue
                state = config()
                state[0]['currentValue'] = selected_model
                reply(request, {'configOptions': state})
        elif method == 'session/prompt':
            if case == 'final-report':
                if not any(arg.endswith('/report-guard.yml') for arg in sys.argv[1:]):
                    (root / 'fixture-tool-executed').write_text('unexpected report tool')
                    update('tool_call', toolCallId='report-tool', title='bash', status='completed')
                update('agent_message_chunk', content={'type': 'text', 'text': 'final report'})
                reply(request, {'stopReason': 'end_turn'})
                continue
            if case == 'event-flood':
                for _ in range(2000):
                    update('agent_message_chunk', content={'type': 'text', 'text': 'x'})
                reply(request, {'stopReason': 'end_turn'})
                reply(request, {'stopReason': 'end_turn'})
                continue
            if case in ('dsh-bash-exit', 'acp-bash-exit'):
                for identifier, title, output, metadata in [
                    ('failure', 'bash', 'failed command\n[exit code: 17]', {}),
                    ('body', 'bash', '[exit code: 17]\nordinary output', {}),
                    ('ptc', 'run_code', '[exit code: 17]', {}),
                    ('read', 'read', '[exit code: 17]', {}),
                    ('typed', 'bash', '[exit code: 17]', {'rawOutput': {'exitCode': 0}}),
                ]:
                    update('tool_call', toolCallId=identifier, title=title, status='in_progress')
                    update('tool_call_update', toolCallId=identifier, status='completed',
                           content=[{'type': 'content', 'content': {'type': 'text', 'text': output}}], **metadata)
            if case == 'incremental-kind':
                update('tool_call', toolCallId='tool', kind='execute', title='bash', status='pending')
                update('tool_call_update', toolCallId='tool', title='Running fixture command', status='completed')
            if case == 'acp-permission':
                pending = request
                permission('acp-permission')
                continue
            if case == 'wrong-session':
                update('agent_message_chunk', session='foreign', content={'type': 'text', 'text': 'FOREIGN'})
                permission('foreign-approval', session='foreign')
            if case == 'late-input':
                update('tool_call', toolCallId='tool', title='bash', status='pending')
                update('tool_call_update', toolCallId='tool', rawInput={'command': 'echo late-approval-detail'})
                pending = request
                permission('late')
                continue
            if case == 'typed-ids':
                pending = request
                permission(1, 'integer')
                permission('1', 'string')
                continue
            if case in ('cancel', 'acp-cancel', 'cancel-rebuild'):
                pending = request
                permission('cancel-me')
                continue
            if case in ('failed-edit', 'failed-write'):
                title = case.removeprefix('failed-')
                raw = {'file_path': str(root / 'unchanged.txt'), 'old_string': 'before', 'new_string': 'after'} if title == 'edit' else {'file_path': str(root / 'unchanged.txt'), 'content': 'after'}
                update('tool_call', toolCallId='tool', title=title, status='pending', rawInput=raw)
                update('tool_call_update', toolCallId='tool', status='failed', rawOutput={'stderr': 'Permission denied'})
            update('agent_message_chunk', content={'type': 'text', 'text': label})
            reply(request, {'stopReason': 'end_turn'})
            if case == 'two-turns':
                reply(request, {'stopReason': 'end_turn'})
        elif method == 'session/cancel':
            if pending:
                reply(pending, {'stopReason': 'cancelled'})
                pending = None
        else:
            emit({'id': request.get('id'), 'error': {'code': -32601, 'message': 'unsupported fixture method'}})
finally:
    quit_peer()
