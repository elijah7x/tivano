#!/usr/bin/env python3
"""Exercise the production MiniMax ACP adapter against an offline fault peer.

No app launch, installed provider, credentials or network. Reuses the existing
ACP source extraction and fail-closed service shims; never rewrites source code.
"""
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

CASES = ('success', 'question', 'auth-required', 'permission-mismatch',
         'invalid-json', 'invalid-envelope', 'missing-result', 'unknown-stop',
         'eof', 'cancel-silent', 'internal-detail', 'internal-start',
         'effort-discovery', 'effort-switch', 'effort-revoked', 'empty-variant', 'empty-variant-api')

PEER = r'''
import json, os, pathlib, sys
case = os.environ['DSH_TEST_CASE']
root = pathlib.Path(os.environ['DSH_TEST_ROOT'])
(root / 'peer.pid').write_text(str(os.getpid()))
permission = 'bypassPermissions'
model = 'm:fixture:offline:u'
thinking_model = 'm:subscription:Flash%20%5Bpreview%5D:v:thinking%3Aextended'
plain_model = 'm:subscription:Flash%20%5Bpreview%5D:u'
effort = 'deep'
revoked = False
pending = None
def send(value):
    print(json.dumps({'jsonrpc': '2.0', **value}), flush=True)
def options():
    ids = ['m:fixture:offline:u', thinking_model, plain_model] if case.startswith('effort-') or case.startswith('empty-variant') else [model]
    if case.startswith('empty-variant'): ids.append('m:subscription:Flash%20%5Bpreview%5D:v:')
    result = [
      {'type': 'select', 'id': 'model', 'category': 'model', 'currentValue': model,
       'options': [{'value': value, 'name': value} for value in ids]},
      {'type': 'select', 'id': 'mode', 'category': 'mode', 'currentValue': 'code',
       'options': [{'value': 'code', 'name': 'Code'}, {'value': 'plan', 'name': 'Plan'}]},
      {'type': 'select', 'id': 'permissionMode', 'category': '_permission', 'currentValue': permission,
       'options': [{'value': v, 'name': v} for v in ['default', 'auto', 'bypassPermissions']]}]
    if model == thinking_model and not revoked:
        result.append({'type': 'select', 'id': 'thinkingEffort', 'category': 'thought_level',
                       'currentValue': effort,
                       'options': [{'value': v, 'name': v} for v in ['minimal', 'deep']]})
    return result
for line in sys.stdin:
    message = json.loads(line)
    with (root / 'wire.jsonl').open('a') as log:
        log.write(json.dumps(message) + '\n')
    method = message.get('method')
    ident = message.get('id')
    if method == 'initialize':
        send({'id': ident, 'result': {'protocolVersion': 1,
              'agentInfo': {'name': 'minimax-code', 'version': '0.6.12' if case.startswith('empty-variant') else 'offline'},
              'agentCapabilities': {'loadSession': True}}})
    elif method == 'session/new':
        if case == 'internal-start':
            send({'id': ident, 'error': {'code': -32603, 'message': 'Internal error',
                  'data': {'details': 'private-fixture-details Bearer fixture-secret'}}})
        elif case == 'auth-required':
            send({'id': ident, 'error': {'code': -32000, 'message': 'Authentication required: Run mcode login'}})
        else:
            send({'id': ident, 'result': {'sessionId': 'fixture-session', 'configOptions': options()}})
    elif method == 'session/set_config_option':
        if message['params']['configId'] == 'permissionMode' and case != 'permission-mismatch':
            permission = message['params']['value']
        if message['params']['configId'] == 'model':
            model = message['params']['value']
            effort = 'deep'
        if message['params']['configId'] == 'thinkingEffort':
            if model != thinking_model or revoked or message['params']['value'] not in ['minimal', 'deep']:
                send({'id': ident, 'error': {'code': -32602, 'message': 'Invalid params'}})
                continue
            effort = message['params']['value']
        # Real mcode sends the full snapshot both as a notification and in its reply.
        send({'method': 'session/update', 'params': {'sessionId': 'fixture-session',
              'update': {'sessionUpdate': 'config_option_update', 'configOptions': options()}}})
        send({'id': ident, 'result': {'configOptions': options()}})
    elif method == 'session/prompt':
        pending = ident
        if case == 'internal-detail':
            send({'id': ident, 'error': {'code': -32603, 'message': 'Internal error',
                  'data': {'details': 'fetch failed Authorization: Bearer fixture-secret'}}})
        elif case == 'invalid-json':
            print('not json', flush=True)
        elif case == 'invalid-envelope':
            send({'id': ident, 'result': {}, 'error': {'code': -1, 'message': 'both'}})
        elif case == 'missing-result':
            send({'id': ident})
        elif case == 'unknown-stop':
            send({'id': ident, 'result': {'stopReason': 'unexpected'}})
        elif case == 'eof':
            sys.exit(7)
        elif case == 'cancel-silent':
            pass
        elif case == 'question':
            send({'id': 'question-1', 'method': 'elicitation/create', 'params': {
                'sessionId': 'fixture-session', 'mode': 'form', 'message': 'Choose',
                'requestedSchema': {'type': 'object', 'required': ['answer'], 'properties': {
                    'answer': {'type': 'string', 'oneOf': [{'const': 'wire-value', 'title': 'Human label'}]}}}}})
        else:
            if case == 'effort-revoked':
                revoked = True
                send({'method': 'session/update', 'params': {'sessionId': 'fixture-session',
                      'update': {'sessionUpdate': 'config_option_update', 'configOptions': options()}}})
            send({'method': 'session/update', 'params': {'sessionId': 'fixture-session',
                'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'fixture reply'}}}})
            send({'id': ident, 'result': {'stopReason': 'end_turn'}})
    elif ident == 'question-1' and 'result' in message:
        valid = message['result'].get('content', {}).get('answer') == 'wire-value'
        send({'id': pending, 'result': {'stopReason': 'end_turn' if valid else 'refusal'}})
'''

HARNESS = r'''
import Foundation
import Darwin

struct Failure: Error { let message: String }
@main struct Harness {
    @MainActor static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let name = environment["DSH_TEST_CASE"]!
        let root = URL(fileURLWithPath: environment["DSH_TEST_ROOT"]!)
        let configuration = SessionConfiguration(provider: .minimaxCode,
            executable: URL(fileURLWithPath: CommandLine.arguments[1]), workingDirectory: root,
            environment: environment, runtimeMode: .supervised, interactionMode: .build)
        let session = ACPSession(configuration: configuration)
        var ends: [TurnStatus] = []
        var text = ""
        var questionLabel = ""
        var failed = false
        var failureDetails: [String] = []
        var exits = 0
        var latestModels: [ModelOption] = []
        let thinkingModel = "m:subscription:Flash%20%5Bpreview%5D:v:thinking%3Aextended"
        let plainModel = "m:subscription:Flash%20%5Bpreview%5D:u"
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(message: message) }
        }
        session.onEvent = { [weak session] event in
            switch event {
            case .turnCompleted(let status, let error):
                ends.append(status)
                if let error { failureDetails.append(error) }
            case .models(let list, _): latestModels = list
            case .exited: exits += 1
            case .messageDelta(_, let value): text += value
            case .question(let request):
                questionLabel = request.questions.first?.choices.first?.label ?? ""
                session?.answerQuestion(request.id, answers: ["answer": [questionLabel]])
            default: break
            }
        }
        do {
            if name == "effort-discovery" || name.hasPrefix("empty-variant") {
                let list = try await ACPSession.probeModels(provider: .minimaxCode,
                    executable: configuration.executable!, environment: environment)
                try require(list.first { $0.id == thinkingModel }?.efforts == ["minimal", "deep"], "Missing exact advertised effort scale")
                try require(list.first { $0.id == plainModel }?.efforts == [], "Variant inherited another variant's scale")
                try require(list.first { $0.isDefault }?.id == "m:fixture:offline:u", "Probe changed default model")
                if name == "empty-variant-api" {
                    try require(list.contains { $0.id.hasSuffix(":v:") }, "Working API-key variant was hidden")
                }
                if name == "empty-variant" {
                    try require(!list.contains { $0.id.hasSuffix(":v:") }, "Known broken empty variant remained selectable")
                    _ = try await session.start()
                    var rejected = false
                    do {
                        try await session.send(TurnInput(text: "must not send", images: [],
                            model: "m:subscription:Flash%20%5Bpreview%5D:v:", effort: nil,
                            runtimeMode: .supervised, interactionMode: .build))
                    } catch { rejected = error.localizedDescription.contains("thinking variant") }
                    try require(rejected, "Saved broken selection did not receive recovery guidance")
                    await session.stopAndWait(timeout: 5)
                }
                print("PASS \(name)")
                exit(0)
            }
            var startError: Error?
            do { _ = try await session.start() } catch { startError = error }
            if name == "auth-required" || name == "permission-mismatch" || name == "internal-start" {
                try require(startError != nil, "Startup must fail before prompt")
                try require(!session.isRunning, "Failed startup retained its connection")
                if name == "internal-start" {
                    let detail = startError?.localizedDescription ?? ""
                    try require(detail.contains("session/new") && detail.contains("-32603"), "Lost failure phase or code")
                    try require(!detail.contains("fixture-secret") && !detail.contains("private-fixture"), "Leaked raw diagnostic")
                    try require(exits == 0, "Startup error also emitted an exit failure")
                }
            } else {
                if let startError { throw startError }
                let count = name == "effort-switch" ? 3 : name == "success" ? 2 : 1
                for turn in 1...count {
                    let selected = name.hasPrefix("effort-") ? (turn == 2 ? plainModel : thinkingModel) : nil
                    let effort = selected == thinkingModel ? (turn == 3 ? "deep" : "minimal") : nil
                    try await session.send(TurnInput(text: "offline fixture", images: [], model: selected,
                        effort: effort, runtimeMode: .supervised, interactionMode: .build))
                    if name == "cancel-silent" { await session.interrupt() }
                    let deadline = Date.now.addingTimeInterval(8)
                    while ends.count < turn, Date.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try require(ends.count == turn, "Missing or duplicate completion")
                }
                let expected = name == "success" || name == "question" || name.hasPrefix("effort-") ? "completed"
                    : name == "cancel-silent" ? "interrupted" : "failed"
                try require(ends.allSatisfy { String(describing: $0) == expected }, "Wrong turn status")
                if name == "success" { try require(text == "fixture replyfixture reply", "Lost stream content") }
                if name == "question" { try require(questionLabel == "Human label", "Wire ID shown as title") }
                if expected != "completed" { try require(!session.isRunning, "Failed turn retained connection") }
                if name == "internal-detail" {
                    try require(failureDetails.count == 1 && exits == 0, "Duplicate failure")
                    let detail = failureDetails.first ?? ""
                    try require(detail.contains("session/prompt") && detail.contains("-32603") && detail.contains("network"), "Lost safe diagnostic")
                    try require(!detail.contains("fixture-secret") && !detail.contains("Bearer"), "Leaked secret")
                }
                if name == "effort-revoked" {
                    try require(latestModels.first { $0.id == thinkingModel }?.efforts == [], "Revoked effort survived full snapshot")
                    var rejected = false
                    do {
                        try await session.send(TurnInput(text: "must not send", images: [], model: thinkingModel,
                            effort: "deep", runtimeMode: .supervised, interactionMode: .build))
                    } catch { rejected = true }
                    try require(rejected && ends.count == 1, "Unadvertised effort reached prompt")
                }
            }
        } catch {
            failed = true
            print("FAIL \(name): \(error)")
        }
        await session.stopAndWait(timeout: 5)
        print("\(failed ? "FAIL" : "PASS") \(name)")
        exit(failed ? 1 : 0)
    }
}
'''


def main():
    if sys.platform != 'darwin':
        raise SystemExit('Requires macOS and Xcode')
    root = Path(__file__).resolve().parents[1]
    parent = root / 'build.noindex/minimax-code'
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='offline-', dir=parent))
    kit = out / 'kit'
    kit.mkdir()
    shutil.copy(root / 'scripts/fixtures/dsh_adapter/Shims.swift', kit)
    (kit / 'Harness.swift').write_text(HARNESS)
    (kit / 'peer.py').write_text(PEER)
    peer = kit / 'mcode-fixture'
    peer.write_text('#!/bin/sh\nexec ' + shlex.quote(str(Path(sys.executable).resolve()))
                    + ' ' + shlex.quote(str(kit / 'peer.py')) + '\n')
    peer.chmod(0o700)
    policy = out / 'offline.sb'
    policy.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n'
                      '(allow file-write* (subpath ' + json.dumps(str(out)) + ') (literal "/dev/null"))\n')
    sources = runpy.run_path(str(root / 'scripts/fixtures/dsh_adapter/prepare.py'))['prepare'](root, kit)
    results = []

    def run(args, name, timeout):
        directory = out / name
        directory.mkdir()
        for child in ('home', 'tmp', 'cache'):
            (directory / child).mkdir()
        env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(directory / 'home'),
               'TMPDIR': str(directory / 'tmp') + '/', 'DSH_TEST_ROOT': str(directory),
               'DSH_TEST_CASE': name, 'LANG': 'en_US.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1',
               'CLANG_MODULE_CACHE_PATH': str(directory / 'cache')}
        if 'DEVELOPER_DIR' in os.environ:
            env['DEVELOPER_DIR'] = os.environ['DEVELOPER_DIR']
        with (directory / 'process.log').open('w') as log:
            process = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(policy), *args],
                                       cwd=directory, env=env, start_new_session=True,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        return process.returncode

    compiler = subprocess.check_output(['/usr/bin/xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    status = run([compiler, '-swift-version', '5', '-parse-as-library',
                  '-target', 'arm64-apple-macos15.0', '-sdk', sdk, '-module-name', 'MiniMaxAdapterStress',
                  '-module-cache-path', str(out / 'compile/cache'), '-o', str(kit / 'adapter'), *sources], 'compile', 180)
    if status == 0:
        for case in CASES:
            status = run([str(kit / 'adapter'), str(peer)], case, 30)
            wire_file = out / case / 'wire.jsonl'
            wire = [json.loads(line) for line in wire_file.read_text().splitlines()] if wire_file.exists() else []
            prompts = [i for i, event in enumerate(wire) if event.get('method') == 'session/prompt']
            confirmations = [i for i, event in enumerate(wire) if event.get('method') == 'session/set_config_option'
                             and event.get('params', {}).get('configId') == 'permissionMode'
                             and event['params'].get('value') == 'default']
            permission_order = all(any(j < i for j in confirmations) for i in prompts)
            rejected = case in ('auth-required', 'permission-mismatch', 'internal-start', 'effort-discovery', 'empty-variant', 'empty-variant-api')
            pid_file = out / case / 'peer.pid'
            alive = False
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), 0)
                    alive = True
                except ProcessLookupError:
                    pass
            selection_values = [event['params']['value'] for event in wire
                                if event.get('method') == 'session/set_config_option'
                                and event.get('params', {}).get('configId') == 'model']
            allowed_models = {'m:fixture:offline:u',
                              'm:subscription:Flash%20%5Bpreview%5D:v:thinking%3Aextended',
                              'm:subscription:Flash%20%5Bpreview%5D:u',
                              'm:subscription:Flash%20%5Bpreview%5D:v:'}
            exact_ids = all(value in allowed_models for value in selection_values)
            passed = status == 0 and permission_order and not alive and exact_ids and (not rejected or not prompts)
            results.append({'case': case, 'exit': status, 'passed': passed, 'peerAlive': alive})
    summary = {'artifacts': str(out), 'passed': len(results) == len(CASES) and all(r['passed'] for r in results),
               'results': results, 'providerEvidence': 'simulated ACP peer; no authenticated model calls'}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
