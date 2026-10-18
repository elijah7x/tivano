#!/usr/bin/env python3
"""tivano-dsh-offline-hydra-v1: simulated ACP backend, never a tool executor."""
import fcntl
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time
import uuid

IDENTITY = 'tivano-dsh-offline-hydra-v1'
if '--version' in sys.argv:
    print('dsh 0.2.1 offline-hydra-fixture')
    sys.exit(0)
home = Path(os.environ['DSH_HOME']).resolve(strict=True)
manifest = json.loads((home / 'fixture.json').read_text())
assert manifest['fixture'] == IDENTITY
fixture = home.parent
assert Path(__file__).resolve() == fixture / 'fake-cli'
assert (fixture / 'lease').is_file()
guard_paths = [Path(sys.argv[i + 1]) for i, arg in enumerate(sys.argv[:-1])
               if arg == '--patch' and Path(sys.argv[i + 1]).name == 'report-guard.yml']
guarded = bool(guard_paths)
for patch in guard_paths:
    resolved = patch.resolve(strict=True)
    assert resolved.is_relative_to(fixture.parent.resolve())
    assert 'id: tivano-report-guard' in resolved.read_text()
    assert (resolved.parent / 'report-guard.mjs').is_file()
if '--dump-config' in sys.argv:
    print('[]')
    sys.exit(0)

pid = os.getpid()
identity = str(uuid.uuid4())
log = (home / ('wire-' + identity + '.jsonl')).open('x', buffering=1)
lock = threading.RLock()
sid = None
pending = None
closed = False


def record(event, **fields):
    with lock:
        log.write(json.dumps(dict(event=event, pid=pid, identity=identity,
                                  sessionID=sid, guarded=guarded, at=time.time(), **fields)) + '\n')


def emit(frame):
    with lock:
        print(json.dumps(dict(jsonrpc='2.0', **frame)), flush=True)


def reply(request, result):
    emit({'id': request['id'], 'result': result})


def update(kind, **fields):
    emit({'method': 'session/update', 'params': {'sessionId': sid,
          'update': dict(sessionUpdate=kind, **fields)}})


def text(value):
    update('agent_message_chunk', content={'type': 'text', 'text': value})


def state_path():
    assert sid and sid.startswith('offline-') and '/' not in sid
    return home / (sid + '.json')


def config():
    return [{'id': 'model', 'category': 'model', 'type': 'select',
             'currentValue': 'deepseek-account/v4-flash',
             'options': [{'value': 'deepseek-account/v4-flash', 'name': 'Offline Flash'}]}]


def quit_peer(*_):
    global closed
    with lock:
        if closed:
            return
        closed = True
        record('exit')
    os._exit(0)


def watch_lease():
    while (fixture / 'lease').exists():
        time.sleep(0.5)
    quit_peer()


def heartbeat():
    index = 0
    while True:
        time.sleep(15)
        with lock:
            if pending is None:
                return
            index += 1
            # Activity only: no tool execution, filesystem edit, or MCP request.
            update('agent_message_chunk', content={'type': 'text', 'text': 'Offline work heartbeat.\n'})
            record('heartbeat', count=index)


signal.signal(signal.SIGTERM, quit_peer)
signal.signal(signal.SIGINT, quit_peer)
# Lifetime locks bound actual ACP processes, including catalog sessions.
slot = None
for number in range(2):
    candidate = (home / ('slot-' + str(number))).open('a')
    try:
        fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
        slot = candidate
        break
    except BlockingIOError:
        candidate.close()
if slot is None:
    record('failure', errorType='ConcurrencyLimit')
    quit_peer()
record('start', parentPID=os.getppid())
threading.Thread(target=watch_lease, daemon=True).start()
try:
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get('method')
        params = request.get('params', {})
        record('method', method=method)
        if method == 'initialize':
            if guarded:
                emit({'method': 'tivano/report_guard_ready', 'params': {'version': 1}})
                record('readiness')
            reply(request, {'protocolVersion': 1, 'agentCapabilities': {'sessionCapabilities': {'resume': {}}}})
        elif method == 'session/new':
            assert not params.get('mcpServers'), 'MCP is outside this fixture'
            sid = 'offline-' + str(uuid.uuid4())
            state_path().write_text(json.dumps({'role': None, 'prompts': 0}))
            record('new')
            reply(request, {'sessionId': sid, 'configOptions': config()})
        elif method == 'session/resume':
            assert not params.get('mcpServers')
            sid = params['sessionId']
            assert state_path().is_file(), 'Unknown resume session'
            record('resume')
            reply(request, {'sessionId': sid, 'configOptions': config()})
        elif method in ('session/set_config_option', 'session/set_model'):
            reply(request, {'configOptions': config()})
        elif method == 'session/prompt':
            prompt = '\n'.join(item.get('text', '') for item in params.get('prompt', []) if item.get('type') == 'text')
            state = json.loads(state_path().read_text())
            if state['role'] is None:
                state['role'] = 'head' if 'OFFLINE_HEAD_TASK' in prompt else 'lead'
            state['prompts'] += 1
            state_path().write_text(json.dumps(state))
            record('prompt', role=state['role'], count=state['prompts'])
            if state['role'] == 'lead':
                assert not guarded, 'Ordinary lead follow-up must not be a guarded report'
                if state['prompts'] == 1:
                    assert 'OFFLINE_LEAD_START' in prompt
                    delegation = [{'task': 'Offline marker', 'prompt': 'OFFLINE_HEAD_TASK: return the fixture marker; do not delegate or use tools.'}]
                    text('```hydra\n' + json.dumps(delegation) + '\n```')
                else:
                    assert state['prompts'] == 2 and manifest['marker'] in prompt
                    record('report_received', markerMatched=True)
                    text('OFFLINE_LEAD_RECEIVED_' + manifest['marker'])
                reply(request, {'stopReason': 'end_turn'})
            elif manifest['scenario'] == 'budget' and not guarded:
                assert state['prompts'] == 1
                pending = request
                text('Offline work started.\n')
                threading.Thread(target=heartbeat, daemon=True).start()
            else:
                assert state['prompts'] == (2 if manifest['scenario'] == 'budget' else 1)
                assert guarded == (manifest['scenario'] == 'budget')
                text(manifest['marker'])
                record('head_report')
                reply(request, {'stopReason': 'end_turn'})
        elif method == 'session/cancel':
            with lock:
                if pending is not None:
                    record('cancelled_prompt')
                    reply(pending, {'stopReason': 'cancelled'})
                    pending = None
            if 'id' in request:
                reply(request, {})
        elif method in ('shutdown', 'exit'):
            if 'id' in request:
                reply(request, {})
            break
        elif 'id' in request:
            emit({'id': request['id'], 'error': {'code': -32601, 'message': 'Unsupported offline fixture method'}})
except BaseException as error:
    record('failure', errorType=type(error).__name__)
    raise
finally:
    quit_peer()
