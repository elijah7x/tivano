#!/usr/bin/env python3
"""Stress a real omp RPC process against a loopback-only, deterministic model.

Run: python3 scripts/omp_offline_stress.py --rounds 10 --workers 4
Requires omp and Python 3; no login, paid model or running Tivano is used.
This exercises omp's wire contract, not Tivano's Swift event reducer or UI.
Artifacts go to a temporary directory unless --output is supplied.
"""

import argparse
import collections
import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time


class ModelServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        messages = body.get("messages", [])
        prompt = str(next((m.get("content", "") for m in reversed(messages)
                           if m.get("role") == "user"), ""))
        slow = "slow" in prompt
        large = "large" in prompt
        payload = "".join(f"{i:05x}:离线🙂e\u0301\n" for i in range(32768 if large else 16))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.chunk({"role": "assistant", "content": ""})
            # Large chunks probe line framing; tiny chunks probe repeated deltas.
            pieces = [payload] if large else list(payload)
            for piece in pieces:
                if slow:
                    time.sleep(0.04)
                self.chunk({"content": piece})
            self.chunk({}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def chunk(self, delta, finish=None):
        value = {"id": "offline", "object": "chat.completion.chunk", "created": 0,
                 "model": "offline", "choices": [{"index": 0, "delta": delta,
                                                    "finish_reason": finish}]}
        self.wfile.write(("data: " + json.dumps(value, ensure_ascii=False) + "\n\n").encode())
        self.wfile.flush()


class RPC:
    def __init__(self, command, directory, environment, timeout):
        self.timeout = timeout
        self.events = queue.Queue()
        self.counts = collections.Counter()
        self.serial = 0
        self.log_path = directory / "rpc.jsonl"
        self.log = self.log_path.open("w", encoding="utf-8")
        self.stderr = (directory / "stderr.log").open("w", encoding="utf-8")
        self.process = subprocess.Popen(command, cwd=directory, env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, text=True, encoding="utf-8",
                                        start_new_session=True)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            for line in self.process.stdout:
                self.log.write(line)
                self.log.flush()
                try:
                    self.events.put(json.loads(line))
                except json.JSONDecodeError:
                    self.events.put({"reader_error": "non-JSON stdout"})
        finally:
            self.events.put({"reader_error": "omp stdout closed"})

    def send(self, kind, **fields):
        self.serial += 1
        identity = f"stress-{self.serial}"
        self.process.stdin.write(json.dumps({"type": kind, "id": identity, **fields}) + "\n")
        self.process.stdin.flush()
        return identity

    def until(self, predicate):
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("RPC deadline exceeded")
            try:
                event = self.events.get(timeout=remaining)
            except queue.Empty as error:
                raise RuntimeError("RPC deadline exceeded") from error
            if "reader_error" in event:
                raise RuntimeError(event["reader_error"])
            self.counts[event.get("type", "unknown")] += 1
            if event.get("type") == "response" and event.get("success") is False:
                raise RuntimeError(f"RPC failure: {event}")
            if predicate(event):
                return event

    def request(self, kind):
        identity = self.send(kind)
        return self.until(lambda e: e.get("type") == "response" and e.get("id") == identity)

    def turn(self, scenario):
        started = time.monotonic()
        identity = self.send("prompt", message=f"offline stress {scenario}")
        if scenario == "slow":
            self.until(lambda e: e.get("type") == "message_update")
            self.send("abort")
        # agent_end alone is not the contract OmpSession uses to finish a turn.
        result = self.until(lambda e: e.get("type") == "prompt_result" and e.get("id") == identity)
        expected = "aborted" if scenario == "slow" else "completed"
        if result.get("status") != expected:
            raise RuntimeError(f"{scenario}: expected {expected}, received {result}")
        if scenario != "slow":
            messages = [json.loads(line) for line in self.log_path.read_text().splitlines()]
            final = next((e.get("message", {}) for e in reversed(messages)
                          if e.get("type") == "message_end" and e.get("message", {}).get("role") == "assistant"), {})
            text = "".join(part.get("text", "") for part in final.get("content", []) if part.get("type") == "text")
            count = 32768 if scenario == "large" else 16
            wanted = "".join(f"{i:05x}:离线🙂e\u0301\n" for i in range(count))
            if text != wanted:
                raise RuntimeError(f"{scenario}: final Unicode content mismatch ({len(text)} vs {len(wanted)})")
        return {"scenario": scenario, "seconds": time.monotonic() - started, "status": result["status"]}

    def close(self):
        # Native subagents belong to this fixture's process group too.
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.reader.join(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()
        self.stderr.close()


def worker(index, args, root, port, gate_source):
    directory = root / f"worker-{index}"
    directory.mkdir()
    home = directory / "home"
    home.mkdir()
    settings = directory / "settings.yml"
    settings.write_text("autoResume: false\nbash:\n  autoBackground:\n    enabled: false\nasync:\n  enabled: false\ntask:\n  maxRecursionDepth: 1\n")
    gate = directory / "gate.json"
    gate.write_text(json.dumps({"runtimeMode": "fullAccess", "interactionMode": "build",
                                "finalReport": False, "allowTask": False}))
    extension = directory / "tivano-gate.ts"
    extension.write_text(gate_source)
    provider = directory / "offline-provider.ts"
    # ProviderConfig is defined by omp's extensibility/extensions/types.ts.
    provider.write_text(f'''export default function(pi) {{
  pi.registerProvider("tivano-offline", {{
    baseUrl: "http://127.0.0.1:{port}/v1", apiKey: "offline-only",
    api: "openai-completions",
    models: [{{ id: "offline", name: "Offline stress", reasoning: false,
      input: ["text"], cost: {{ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }},
      contextWindow: 1048576, maxTokens: 262144 }}]
  }});
}}
''')
    # Do not inherit model credentials, user extensions, MCP configuration or agent dirs.
    environment = {"PATH": os.environ.get("PATH", ""), "HOME": str(home),
                   "TMPDIR": str(directory), "XDG_CONFIG_HOME": str(home / ".config"),
                   "TIVANO_OMP_GATE": str(gate), "NO_PROXY": "127.0.0.1,localhost"}
    command = [args.omp, "--mode", "rpc-ui", "--approval-mode", "yolo",
               "--config", str(settings), "--no-extensions", "--no-skills", "--no-rules", "--no-title", "--no-lsp", "--no-pty",
               "-e", str(extension), "-e", str(provider), "--model", "tivano-offline/offline"]
    rpc = RPC(command, directory, environment, args.timeout)
    result = {"worker": index, "completed": 0, "passed": False, "turns": []}
    try:
        commands = rpc.request("get_available_commands")
        if not any(c.get("name") == "tivano-gate"
                   for c in commands.get("data", commands).get("commands", [])):
            raise RuntimeError("Tivano gate extension did not load")
        state = rpc.request("get_state")
        model = state.get("data", state).get("model", {})
        if model.get("provider") != "tivano-offline":
            raise RuntimeError("offline provider was not selected; refusing prompts")
        for _ in range(args.rounds):
            for scenario in ("tiny", "large", "slow", "recovery"):
                result["turns"].append(rpc.turn(scenario))
                result["completed"] += 1
        result["passed"] = True
    except Exception as error:
        result["error"] = str(error)
    finally:
        rpc.close()
        result["events"] = dict(rpc.counts)
        result["pid"] = rpc.process.pid
        result["exit_status"] = rpc.process.returncode
        result["stdout_bytes"] = rpc.log_path.stat().st_size
        result["stderr_bytes"] = (directory / "stderr.log").stat().st_size
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omp", default=shutil.which("omp"))
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.omp or min(args.rounds, args.workers, args.timeout) <= 0:
        parser.error("omp must be installed and rounds, workers, timeout must be positive")
    if args.rounds > 10 or args.workers > 4 or args.timeout > 30:
        parser.error("limit: 10 rounds (40 turns) per worker, 4 workers and 30s per operation")
    args.omp = str(Path(args.omp).resolve())
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="tivano-omp-stress-"))
    root.mkdir(parents=True, exist_ok=True)
    source = (Path(__file__).resolve().parents[1] / "Tivano/Services/Providers/OmpCLI.swift").read_text()
    marker = 'private static let extensionSource = #"""'
    gate_source = source.split(marker, 1)[1].split('"""#', 1)[0]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ModelServer)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = [pool.submit(worker, i, args, root, server.server_port, gate_source)
                       for i in range(args.workers)]
            results = []
            for future in futures:
                try:
                    results.append(future.result())
                except Exception as error:
                    results.append({"passed": False, "error": str(error)})
    finally:
        server.shutdown()
        server.server_close()
    summary = {"passed": all(r["passed"] for r in results), "artifacts": str(root),
               "workers": results, "scope": "real omp RPC; deterministic loopback model; no Swift/UI coverage"}
    (root / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
