#!/usr/bin/env python3
"""Exercise Tivano's gate in a real omp RPC process with a loopback model.

Run: python3 scripts/omp_gate_stress.py --rounds 1
No login, paid model or running Tivano is needed. All commands and writes target
an isolated temporary directory. This checks omp's extension/UI wire contract,
not Tivano's Swift reducer, session grants, UI or subagent-spawn hook.
"""

import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import shlex
import tempfile
import threading

from omp_offline_stress import RPC


PREFIX = "TIVANO_GATE_CASE "


class ModelServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        messages = body.get("messages", [])
        user_index = next((i for i in range(len(messages) - 1, -1, -1)
                           if messages[i].get("role") == "user"), None)
        if user_index is None:
            self.send_error(400, "No case prompt")
            return
        content = messages[user_index].get("content", "")
        if isinstance(content, list):
            content = "\n".join(part.get("text", "") for part in content if isinstance(part, dict))
        if PREFIX not in content:
            self.send_error(400, "Missing case prompt")
            return
        case = json.loads(content.split(PREFIX, 1)[1])
        called = any(m.get("tool_calls") or m.get("role") == "tool"
                     for m in messages[user_index + 1:])
        if called:
            delta, finish = {"content": "Case finished."}, "stop"
        else:
            available = {t.get("function", {}).get("name") for t in body.get("tools", [])}
            if case["tool"] not in available:
                self.send_error(400, "Requested fixture tool is unavailable")
                return
            delta = {"tool_calls": [{"index": 0, "id": case["id"], "type": "function",
                                      "function": {"name": case["tool"],
                                                   "arguments": json.dumps(case["input"])}}]}
            finish = "tool_calls"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for value, reason in (({"role": "assistant"}, None), (delta, None), ({}, finish)):
                chunk = {"id": case["id"], "object": "chat.completion.chunk", "created": 0,
                         "model": "offline", "choices": [{"index": 0, "delta": value,
                                                            "finish_reason": reason}]}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def gate(mode="fullAccess", interaction="build", final=False):
    return {"runtimeMode": mode, "interactionMode": interaction,
            "finalReport": final, "allowTask": False}


def cases():
    return [
        ("full-write", gate(), "write", True, None),
        ("full-command", gate(), "bash", True, None),
        ("supervised-write-approve", gate("supervised"), "write", True, "Approve"),
        ("supervised-write-deny", gate("supervised"), "write", False, "Deny"),
        ("supervised-command-approve", gate("supervised"), "bash", True, "Approve"),
        ("supervised-command-deny", gate("supervised"), "bash", False, "Deny"),
        ("supervised-cancel", gate("supervised"), "write", False, "cancel"),
        ("auto-write", gate("autoAcceptEdits"), "write", True, None),
        ("auto-command-deny", gate("autoAcceptEdits"), "bash", False, "Deny"),
        ("plan-write", gate(interaction="plan"), "write", False, None),
        ("plan-command", gate(interaction="plan"), "bash", False, None),
        ("plan-read", gate(interaction="plan"), "read", True, None),
        ("supervised-read", gate("supervised"), "read", True, None),
        ("final-read", gate(final=True), "read", False, None),
        ("final-write", gate(final=True), "write", False, None),
        ("missing", None, "write", False, None),
        ("malformed", "{", "write", False, None),
        ("array", [], "write", False, None),
        ("unknown-mode", {**gate(), "runtimeMode": "unexpected"}, "write", False, None),
        ("missing-field", {k: v for k, v in gate().items() if k != "allowTask"}, "write", False, None),
        ("wrong-type", {**gate(), "finalReport": "false"}, "write", False, None),
        ("recovered", gate(), "write", True, None),
        ("device-deny", gate("autoAcceptEdits"), "device", False, "Deny"),
        ("device-approve", gate("supervised"), "device", True, "Approve"),
        ("device-plan", gate(interaction="plan"), "device", False, None),
        ("device-full", gate(), "device", True, None),
        ("device-final", gate(final=True), "device", False, None),
        ("device-missing", None, "device", False, None),
        ("device-command-approve", gate("supervised"), "device-command", True, "Approve"),
        ("device-command-deny", gate("autoAcceptEdits"), "device-command", False, "Deny"),
        ("device-command-plan", gate(interaction="plan"), "device-command", False, None),
        ("device-task", gate(), "device-task", False, None),
        ("device-unknown", gate("autoAcceptEdits"), "device-unknown", False, None),
        ("device-query", gate("autoAcceptEdits"), "device-query", False, None),
        ("device-topic", gate("autoAcceptEdits"), "device-topic", False, None),
        ("device-fragment", gate("autoAcceptEdits"), "device-fragment", False, None),
        ("device-encoded", gate("autoAcceptEdits"), "device-encoded", False, None),
        ("device-array", gate("supervised"), "device-array", False, None),
    ]


def run_case(rpc, directory, gate_path, identity, state, tool, allowed, answer):
    if state is None:
        gate_path.unlink(missing_ok=True)
    else:
        replacement = gate_path.with_suffix(".tmp")
        replacement.write_text(state if isinstance(state, str) else json.dumps(state))
        replacement.replace(gate_path)
    marker = directory / (identity + ".txt")
    if tool == "read":
        inputs = {"path": str(directory / "read-fixture.txt")}
    elif tool == "bash":
        inputs = {"command": "printf gate-ok > " + shlex.quote(str(marker))}
    elif tool.startswith("device"):
        device = {
            "device-command": "bash", "device-task": "task", "device-unknown": "unknown_gate_probe",
            "device-query": "mcp__gate__probe?x=1", "device-topic": "mcp__gate__probe/docs",
            "device-fragment": "mcp__gate__probe#x", "device-encoded": "%6dcp__gate__probe",
        }.get(tool, "mcp__gate__probe")
        inner = {"command": "printf gate-ok > " + shlex.quote(str(marker))} if tool == "device-command" else {"path": str(marker)}
        inputs = {"path": "xd://" + device, "content": json.dumps([] if tool == "device-array" else inner)}
    else:
        inputs = {"path": str(marker), "content": "gate-ok"}
    prompt = rpc.send("prompt", message=PREFIX + json.dumps({"id": identity,
                      "tool": "write" if tool.startswith("device") else tool, "input": inputs}))
    approvals = []
    completions = []

    def consume(event):
        if event.get("type") == "extension_error":
            raise RuntimeError("Gate extension error: " + str(event.get("error")))
        if event.get("type") == "extension_ui_request":
            if event.get("method") in ("setWidget", "setStatus", "setTitle", "set_editor_text", "notify"):
                return False
            title = event.get("title", "")
            if event.get("method") != "select" or not title.startswith("tivano-gate "):
                raise RuntimeError("Unexpected approval request")
            payload = json.loads(title[len("tivano-gate "):])
            expected = "command" if tool in ("bash", "device-command") else "tool" if tool.startswith("device") else "fileChange"
            expected_inputs = json.loads(inputs["content"]) if tool.startswith("device") else inputs
            expected_name = "bash" if tool == "device-command" else "mcp__gate__probe" if tool.startswith("device") else tool
            # Only the real inner execution asks; the write wrapper gets no independent grant.
            if payload.get("kind") != expected or payload.get("input") != expected_inputs or payload.get("toolName") != expected_name:
                raise RuntimeError("Approval payload mismatch")
            approvals.append(event["id"])
            if answer == "cancel":
                rpc.send("extension_ui_response", cancelled=True, **{"id": event["id"]})
            else:
                rpc.send("extension_ui_response", value=answer or "Deny", **{"id": event["id"]})
        if event.get("type") == "tool_execution_end":
            completions.append(event)
        return event.get("type") == "prompt_result" and event.get("id") == prompt

    completion = rpc.until(consume)
    if completion.get("status") != "completed":
        raise RuntimeError("Prompt did not complete: " + json.dumps(completion))
    expected_approvals = 1 if answer is not None else 0
    if len(approvals) != expected_approvals:
        raise RuntimeError("Approval count mismatch")
    if len(completions) != 1:
        raise RuntimeError("Expected exactly one tool completion")
    if completions[0].get("isError", False) is not (not allowed):
        raise RuntimeError("Tool success/denial mismatch")
    if tool != "read" and marker.exists() != allowed:
        raise RuntimeError("Filesystem side effect disagrees with gate decision")
    if allowed and tool != "read" and marker.read_text() != "gate-ok":
        raise RuntimeError("Unexpected marker contents")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omp", default=shutil.which("omp"))
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.omp or args.rounds <= 0 or args.timeout <= 0:
        parser.error("omp must be installed and rounds/timeout must be positive")
    args.omp = str(Path(args.omp).resolve())
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="tivano-omp-gate-"))
    root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="run-", dir=root))
    home = directory / "home"
    home.mkdir()
    (directory / "read-fixture.txt").write_text("gate-read-ok")
    gate_path = directory / "gate.json"
    gate_path.write_text(json.dumps(gate()))
    source = (Path(__file__).resolve().parents[1] / "Tivano/Services/Providers/OmpCLI.swift").read_text()
    extension = directory / "tivano-gate.ts"
    extension.write_text(source.split('private static let extensionSource = #"""', 1)[1].split('"""#', 1)[0])
    settings = directory / "settings.yml"
    settings.write_text("autoResume: false\nbash:\n  autoBackground:\n    enabled: false\nasync:\n  enabled: false\ntask:\n  maxRecursionDepth: 1\n")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ModelServer)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    provider = directory / "offline-provider.ts"
    provider.write_text('''import fs from "node:fs";
import { Type } from "typebox";
export default function(pi) {
  pi.registerProvider("tivano-offline", {
    baseUrl: "http://127.0.0.1:PORT/v1", apiKey: "offline-only", api: "openai-completions",
    models: [{ id: "offline", name: "Offline gate", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 1048576, maxTokens: 4096 }]
  });
  pi.registerTool({ name: "mcp__gate__probe", label: "Gate probe", description: "Write a test marker",
    parameters: Type.Object({ path: Type.String() }),
    async execute(id, params) {
      fs.writeFileSync(params.path, "gate-ok");
      return { content: [{ type: "text", text: "gate-ok" }], details: {} };
    }
  });
}
'''.replace("PORT", str(server.server_port)))
    environment = {"PATH": os.environ.get("PATH", ""), "HOME": str(home),
                   "TMPDIR": str(directory), "XDG_CONFIG_HOME": str(home / ".config"),
                   "TIVANO_OMP_GATE": str(gate_path), "NO_PROXY": "127.0.0.1,localhost"}
    command = [args.omp, "--mode", "rpc-ui", "--approval-mode", "yolo",
               "--config", str(settings), "--no-extensions", "--no-skills", "--no-rules",
               "-e", str(extension), "-e", str(provider), "--model", "tivano-offline/offline"]
    results = []
    rpc = None
    try:
        rpc = RPC(command, directory, environment, args.timeout)
        commands = rpc.request("get_available_commands")
        if not any(c.get("name") == "tivano-gate" for c in commands.get("data", commands).get("commands", [])):
            raise RuntimeError("Gate readiness handshake missing")
        state = rpc.request("get_state")
        if state.get("data", state).get("model", {}).get("provider") != "tivano-offline":
            raise RuntimeError("Offline provider not selected; refusing prompts")
        for round_index in range(args.rounds):
            for name, state, tool, allowed, answer in cases():
                identity = f"case-{round_index}-{name}"
                try:
                    run_case(rpc, directory, gate_path, identity, state, tool, allowed, answer)
                    results.append({"case": identity, "passed": True})
                except Exception as error:
                    results.append({"case": identity, "passed": False, "error": str(error)})
                    raise
    except Exception as error:
        if not results or results[-1]["passed"]:
            results.append({"case": "setup", "passed": False, "error": str(error)})
    finally:
        if rpc:
            rpc.close()
        server.shutdown()
        server.server_close()
    summary = {"passed": bool(results) and all(r["passed"] for r in results),
               "expected": args.rounds * len(cases()), "results": results,
               "artifacts": str(directory)}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
