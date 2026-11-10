#!/usr/bin/env python3
"""Exercise the production Kimi Code ACP turn handling against an offline fault peer.

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

# Case -> number of session/prompt requests the harness sends.
CASES = {'reply': 1, 'empty-end-turn': 1, 'thought-only': 1, 'tool-only': 1,
         'empty-after-reply': 2, 'prompt-auth': 1, 'start-auth': 0}

PEER = r'''
import json, os, pathlib, sys
case = os.environ['DSH_TEST_CASE']
root = pathlib.Path(os.environ['DSH_TEST_ROOT'])
(root / 'peer.pid').write_text(str(os.getpid()))
auth = {'code': -32000, 'message': 'Authentication required: token expired'}
prompts = 0
def send(value):
    print(json.dumps({'jsonrpc': '2.0', **value}), flush=True)
def update(body):
    send({'method': 'session/update', 'params': {'sessionId': 'fixture-session', 'update': body}})
for line in sys.stdin:
    message = json.loads(line)
    with (root / 'wire.jsonl').open('a') as log:
        log.write(json.dumps(message) + '\n')
    method = message.get('method')
    ident = message.get('id')
    if method == 'initialize':
        # Kimi advertises a login method; ACPSession only maps an auth error to
        # `kimi login` when authMethods is non-empty.
        send({'id': ident, 'result': {'protocolVersion': 1,
              'agentInfo': {'name': 'kimi', 'version': 'offline'},
              'agentCapabilities': {'loadSession': True},
              'authMethods': [{'id': 'login', 'name': 'Login'}]}})
    elif method == 'session/new':
        if case == 'start-auth':
            send({'id': ident, 'error': auth})
        else:
            # Supervised + build asks Kimi for its `default` mode; it must be advertised.
            send({'id': ident, 'result': {'sessionId': 'fixture-session', 'modes': {
                'currentModeId': 'default',
                'availableModes': [{'id': v, 'name': v} for v in ['default', 'auto', 'yolo', 'plan']]}}})
    elif method == 'session/prompt':
        prompts += 1
        if case == 'prompt-auth':
            send({'id': ident, 'error': auth})
            continue
        if case == 'reply' or (case == 'empty-after-reply' and prompts == 1):
            update({'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'fixture reply'}})
        elif case == 'thought-only':
            update({'sessionUpdate': 'agent_thought_chunk', 'content': {'type': 'text', 'text': 'fixture thought'}})
        elif case == 'tool-only':
            update({'sessionUpdate': 'tool_call', 'toolCallId': 'fixture-tool', 'title': 'Read file',
                    'kind': 'read', 'status': 'pending', 'rawInput': {'path': 'fixture.txt'}})
            update({'sessionUpdate': 'tool_call_update', 'toolCallId': 'fixture-tool', 'status': 'completed'})
        send({'id': ident, 'result': {'stopReason': 'end_turn'}})
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
        let configuration = SessionConfiguration(provider: .kimi,
            executable: URL(fileURLWithPath: CommandLine.arguments[1]), workingDirectory: root,
            environment: environment, runtimeMode: .supervised, interactionMode: .build)
        let session = ACPSession(configuration: configuration)
        var ends: [(status: String, error: String?)] = []
        var text = ""
        var failed = false
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(message: message) }
        }
        session.onEvent = { event in
            switch event {
            case .turnCompleted(let status, let error): ends.append((String(describing: status), error))
            case .messageDelta(_, let value): text += value
            default: break
            }
        }
        do {
            // Per turn: expected status and a substring its error must contain (nil = no error).
            let turns: [(status: String, error: String?)]
            switch name {
            case "reply", "thought-only", "tool-only": turns = [("completed", nil)]
            case "empty-end-turn": turns = [("failed", "without a reply")]
            case "empty-after-reply": turns = [("completed", nil), ("failed", "without a reply")]
            case "prompt-auth": turns = [("failed", "kimi login")]
            case "start-auth": turns = []
            default: throw Failure(message: "Unknown case")
            }
            var startError: Error?
            do { _ = try await session.start() } catch { startError = error }
            if name == "start-auth" {
                try require(startError != nil, "Auth failure on session/new did not fail start()")
                try require((startError?.localizedDescription ?? "").contains("kimi login"),
                            "start() error lost the kimi login guidance: \(startError?.localizedDescription ?? "nil")")
                try require(!session.isRunning, "Failed startup retained its connection")
                try require(ends.isEmpty, "Startup failure also completed a turn")
            } else {
                if let startError { throw startError }
                for (index, expected) in turns.enumerated() {
                    let turn = index + 1
                    try await session.send(TurnInput(text: "offline fixture", images: [], model: nil,
                        effort: nil, runtimeMode: .supervised, interactionMode: .build))
                    let deadline = Date.now.addingTimeInterval(8)
                    while ends.count < turn, Date.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try require(ends.count == turn, "Turn \(turn): missing or duplicate completion (\(ends.count) ends)")
                    let end = ends[index]
                    try require(end.status == expected.status, "Turn \(turn): status \(end.status), expected \(expected.status): \(end.error ?? "no error")")
                    if let needle = expected.error {
                        try require((end.error ?? "").contains(needle), "Turn \(turn): error lacks '\(needle)': \(end.error ?? "nil")")
                    } else {
                        try require(end.error == nil, "Turn \(turn): unexpected error \(end.error ?? "")")
                    }
                }
                let expectedText = name == "reply" || name == "empty-after-reply" ? "fixture reply" : ""
                try require(text == expectedText, "Message text '\(text)', expected '\(expectedText)'")
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
    if not Path('/usr/bin/sandbox-exec').exists():
        raise SystemExit('sandbox-exec required; refusing an unsandboxed run')
    root = Path(__file__).resolve().parents[1]
    parent = root / 'build.noindex/kimi-code'
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='offline-', dir=parent))
    kit = out / 'kit'
    kit.mkdir()
    shutil.copy(root / 'scripts/fixtures/dsh_adapter/Shims.swift', kit)
    (kit / 'Harness.swift').write_text(HARNESS)
    (kit / 'peer.py').write_text(PEER)
    peer = kit / 'kimi-fixture'
    peer.write_text('#!/bin/sh\nexec ' + shlex.quote(str(Path(sys.executable).resolve()))
                    + ' ' + shlex.quote(str(kit / 'peer.py')) + '\n')
    peer.chmod(0o700)
    policy = out / 'offline.sb'
    policy.write_text(runpy.run_path(str(root / 'scripts/dsh_adapter_stress.py'))['sandbox_policy'](out))
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
                return None
        return process.returncode

    compiler = subprocess.check_output(['/usr/bin/xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    status = run([compiler, '-swift-version', '5', '-parse-as-library',
                  '-target', 'arm64-apple-macos15.0', '-sdk', sdk, '-module-name', 'KimiAdapterStress',
                  '-module-cache-path', str(out / 'compile/cache'), '-o', str(kit / 'adapter'), *sources], 'compile', 180)
    if status != 0:
        print((out / 'compile/process.log').read_text()[-4000:], file=sys.stderr)
    else:
        for case, prompt_count in CASES.items():
            status = run([str(kit / 'adapter'), str(peer)], case, 30)
            problems = []
            if status != 0:
                problems.append('harness exit ' + str(status))
            log_file = out / case / 'process.log'
            log = log_file.read_text() if log_file.exists() else ''
            if ('PASS ' + case) not in log or 'FAIL' in log:
                problems.append('missing PASS marker or FAIL reported')
            wire_file = out / case / 'wire.jsonl'
            wire = [json.loads(line) for line in wire_file.read_text().splitlines()] if wire_file.exists() else []
            methods = [event.get('method') for event in wire]
            if methods[:2] != ['initialize', 'session/new']:
                problems.append('unexpected handshake: ' + ', '.join(map(str, methods[:2])))
            if methods.count('session/prompt') != prompt_count:
                problems.append('prompt count %d, expected %d' % (methods.count('session/prompt'), prompt_count))
            pid_file = out / case / 'peer.pid'
            alive = False
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), 0)
                    alive = True
                except ProcessLookupError:
                    pass
            if alive:
                problems.append('peer still alive')
            results.append({'case': case, 'exit': status, 'passed': not problems, 'problems': problems})
    summary = {'artifacts': str(out), 'passed': len(results) == len(CASES) and all(r['passed'] for r in results),
               'results': results, 'providerEvidence': 'simulated ACP peer; no authenticated model calls'}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
