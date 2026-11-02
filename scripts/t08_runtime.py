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
PARENT = Path(os.environ.get('T08_OUTPUT', ROOT / 'build.noindex/t08-acceptance')).resolve()


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
                 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'Fixture title'}, 'finish_reason': None}]}
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
    debug = Path(os.environ.get('T08_DERIVED_DATA', PARENT / 'DerivedData')).resolve() / 'Build/Products/Debug'
    mac = debug / 'Tivano Dev.app/Contents/MacOS'
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-DDEBUG', '-I', str(debug),
               '-F', str(debug / 'PackageFrameworks'), '-F', str(debug), '-Xlinker', '-rpath', '-Xlinker', str(mac),
               '-Xlinker', '-rpath', '-Xlinker', str(debug / 'PackageFrameworks'), str(mac / 'Tivano Dev.debug.dylib'),
               str(ROOT / 'scripts/fixtures/omp_adapter/Integration.swift'), '-o', str(out / 'integration')]
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True; server.evidence = out
    threading.Thread(target=server.serve_forever, daemon=True).start()
    (extensions / 'offline.ts').write_text('''export default function(pi) {
 pi.registerProvider("tivano-offline", {baseUrl:"http://127.0.0.1:PORT/v1",apiKey:"offline-only",api:"openai-completions",
 models:[{id:"offline",name:"Runtime loopback fixture",reasoning:false,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:1048576,maxTokens:4096},
 {id:"reasoning",name:"fixture reasoning loopback",reasoning:true,input:["text"],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:1048576,maxTokens:4096,compat:{supportsReasoningEffort:true}}]});
}'''.replace('PORT', str(server.server_port)))
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(home), 'TMPDIR': str(tmp),
           'NO_PROXY': '127.0.0.1,localhost', 'LANG': 'en_US.UTF-8', 'T08_EVIDENCE': str(out),
           'T08_OMP': os.environ.get('T08_OMP') or shutil.which('omp'), 'T08_PYTHON': sys.executable,
           'T08_MCP_SERVER': str(ROOT / 'scripts/fixtures/omp_adapter/mcp_server.py')}
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


def claude_fixtures():
    """Run extracted ownership/recovery code with fake accounts and usage reads.

    This entry never opens the app, a provider CLI, Keychain or user storage.
    The ordinary OMP integration above retains its existing dependencies.
    """
    def declaration(path, marker):
        source = (ROOT / path).read_text()
        start = source.index(marker)
        opening = source.index('{', start)
        depth, end = 1, opening + 1
        while depth:
            depth += (source[end] == '{') - (source[end] == '}')
            end += 1
        return source[start:end].replace('private ', '')

    runtime = 'Tivano/App/Runtime/ThreadRuntime.swift'
    continuation = 'Tivano/App/Runtime/AutoContinue.swift'
    source = r'''
import Foundation
enum ProviderKind { case claude, codex; var isAPIKeyBased: Bool { false } }
struct ProviderAccount { var id = UUID(); var provider = ProviderKind.claude; var isDefault = false }
struct ChatThread {
    var id = UUID(); var provider = ProviderKind.claude
    var claudeAccountID: UUID?; var claudeUsesDefaultAccount: Bool?
    var hasStartedTurn = false; var providerSessionID: String?; var parentThreadID: UUID?
}
final class Accounts {
    var values: [ProviderAccount] = []
    func account(id: UUID) -> ProviderAccount? { values.first { $0.id == id } }
    func accounts(for provider: ProviderKind) -> [ProviderAccount] { values.filter { $0.provider == provider } }
}
struct PlanLimits {
    struct Window { var percent: Double; var resetsAt: Date? }
    var windows: [Window]
}
final class Registry {
    let accounts = Accounts()
    var limits: [UUID: PlanLimits] = [:]
    var reads: [UUID] = []
    func refreshClaudePlanLimits(accountID: UUID, force: Bool = false) async -> PlanLimits? {
        reads.append(accountID); return limits[accountID]
    }
    func executable(for provider: ProviderKind) -> URL? { nil }
    func environment(for provider: ProviderKind) -> [String: String] {
        fatalError("Claude must not read the global selected account")
    }
}
final class Settings { func apiKey(for provider: ProviderKind) -> String { "" } }
final class AppModel {
    let providers = Registry(); let settings = Settings(); var threads: [ChatThread] = []
    func thread(_ id: UUID) -> ChatThread? { threads.first { $0.id == id } }
}
enum PlanLimitsReader {
    static func exposesLimits(_ provider: ProviderKind) -> Bool { true }
    static func read(_ provider: ProviderKind, apiKey: String) async -> PlanLimits? { nil }
    static func read(_ provider: ProviderKind, executable: URL, environment: [String: String]) async -> PlanLimits? {
        fatalError("Bound Claude usage must use the per-account reader")
    }
}
enum UsageLimitSignal { static func supportsResetTime(_ date: Date) -> Bool { date > .now } }
struct ACPSelectionError: Error {}
struct ClaudeAccountValidationError: LocalizedError {
    var errorDescription: String? { "session not found" }
}
struct ClaudeCredentialError: LocalizedError {
    var errorDescription: String? { "session not found" }
}
struct FixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
final class ThreadRuntime {
'''
    source += '\n'.join(declaration(runtime, marker) for marker in [
        '    static func claudeAccountForChat(',
        '    private static func startsOver(',
        '    private static func lostConversation('])
    source += '\n}\nenum UsagePanel {\n'
    source += declaration('Tivano/App/Views/Usage/UsagePanel.swift', '    private static func claudeHeadAccountIDs(')
    source += '\n}\nfinal class AutoContinue { var app: AppModel?; init(_ app: AppModel) { self.app = app }\n'
    source += declaration(continuation, '    private func readResetTime(')
    source += r'''
}
@main struct Checks {
    static func main() async {
        let app = AppModel(), a = ProviderAccount(), b = ProviderAccount()
        let external = ProviderAccount(isDefault: true)
        app.providers.accounts.values = [external, a, b]
        let earlier = Date.now.addingTimeInterval(600), later = Date.now.addingTimeInterval(3600)
        app.providers.limits[a.id] = PlanLimits(windows: [.init(percent: 100, resetsAt: later)])
        app.providers.limits[b.id] = PlanLimits(windows: [.init(percent: 100, resetsAt: earlier)])
        var parent = ChatThread(claudeAccountID: a.id)
        let child = ChatThread(parentThreadID: parent.id)
        let legacy = ChatThread(hasStartedTurn: true, providerSessionID: "old")
        let fresh = ChatThread()
        app.threads = [parent, child, legacy, fresh]
        precondition(ThreadRuntime.claudeAccountForChat(child, app: app)?.id == a.id)
        precondition(ThreadRuntime.claudeAccountForChat(legacy, app: app)?.id == external.id)
        precondition(ThreadRuntime.claudeAccountForChat(fresh, app: app) == nil)
        let reader = AutoContinue(app)
        let reset = await reader.readResetTime(.claude, claudeAccountID: a.id)
        precondition(reset == later && app.providers.reads == [a.id])
        let unbound = await reader.readResetTime(.claude)
        precondition(unbound == nil && app.providers.reads == [a.id])
        let lead = ChatThread(provider: .codex)
        let headA = ChatThread(claudeAccountID: a.id, parentThreadID: lead.id)
        let headB = ChatThread(claudeAccountID: b.id, parentThreadID: lead.id)
        let waiting = ChatThread(parentThreadID: lead.id)
        app.threads += [lead, headA, headB, waiting]
        precondition(UsagePanel.claudeHeadAccountIDs([headA, headB, headA, waiting, lead], app: app) == [a.id, b.id])
        precondition(UsagePanel.claudeHeadAccountIDs([waiting], app: app).isEmpty)
        app.providers.accounts.values.removeAll { $0.id == a.id }
        precondition(UsagePanel.claudeHeadAccountIDs([headA, headB], app: app) == [b.id])
        precondition(ThreadRuntime.claudeAccountForChat(child, app: app) == nil)
        parent.providerSessionID = "old"
        let missing = FixtureError(message: "No conversation found with session ID old")
        precondition(ThreadRuntime.startsOver(after: missing, resuming: parent))
        precondition(!ThreadRuntime.startsOver(after: missing, resuming: fresh))
        precondition(!ThreadRuntime.startsOver(after: ClaudeAccountValidationError(), resuming: parent))
        precondition(!ThreadRuntime.startsOver(after: ClaudeCredentialError(), resuming: parent))
        precondition(!ThreadRuntime.startsOver(after: FixtureError(message: "connection timed out"), resuming: parent))
        print("Claude ownership, bound reset lookup and recovery classification passed; synthetic dependencies only.")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix='tivano-claude-runtime-') as temporary:
        directory = Path(temporary)
        swift = directory / 'Checks.swift'
        binary = directory / 'checks'
        swift.write_text(source)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                        str(swift), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True,
                       env={'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(directory)})
    return 0


if __name__ == '__main__':
    raise SystemExit(claude_fixtures() if '--claude-fixtures' in sys.argv else main())
