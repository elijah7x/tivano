import Foundation

/// The JavaScript bridge that exposes the connected MCP servers' tools to the
/// providers that load a file Tivano installs: Pi (an extension) and
/// Command Code (a mod). Both dynamic-import it and call `loadMCPTools()`.
///
/// Plain ESM JavaScript (Node 18+, no npm dependencies). The server list comes
/// from the file at `TIVANO_MCP_CONFIG`
/// (`{"mcpServers": { id: {command, args, env} | {type: "http", url, headers} }}`);
/// when the variable is unset or the file is missing, nothing is registered.
enum MCPBridge {
    private static var localizedErrors: String {
        JSONValue.object([
            "invalid MCP response": .string(String(localized: "invalid MCP response")),
            "invalid MCP error response": .string(String(localized: "invalid MCP error response")),
            "invalid MCP tool result": .string(String(localized: "invalid MCP tool result")),
            "invalid MCP response JSON": .string(String(localized: "invalid MCP response JSON")),
            "invalid MCP tools list": .string(String(localized: "invalid MCP tools list")),
            "invalid MCP response content type": .string(String(localized: "invalid MCP response content type")),
            "MCP response ID or envelope mismatch": .string(String(localized: "MCP response ID or envelope mismatch")),
            "empty MCP response": .string(String(localized: "empty MCP response")),
            "MCP response exceeds 16 MiB": .string(String(localized: "MCP response exceeds 16 MiB")),
            "MCP request timed out": .string(String(localized: "MCP request timed out")),
            "process output closed": .string(String(localized: "process output closed")),
            "cancelled": .string(String(localized: "cancelled")),
            "timed out": .string(String(localized: "timed out")),
            "process exited": .string(String(localized: "process exited")),
            "MCP HTTP error (status %lld)": .string(String(localized: "MCP HTTP error (status %lld)")),
        ]).compactString
    }

    static let mcpBridgeSource: String = #"""
    import fs from "node:fs";
    import { spawn } from "node:child_process";

    const PROTOCOL_VERSION = "\#(MCPWire.protocolVersion)";
    const errorMessages = \#(localizedErrors);
    class BridgeError extends Error {
      constructor(key, ...values) {
        let text = errorMessages[key] || key;
        for (const value of values) text = text.replace(/%lld|%@/, String(value));
        super(text);
      }
    }
    const CONNECT_TIMEOUT_MS = 15000;
    const REQUEST_TIMEOUT_MS = 120000;
    const RESPONSE_LIMIT = 16 * 1024 * 1024;
    const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
    const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

    // https://modelcontextprotocol.io/specification/2025-06-18/basic
    function responseFor(message, id) {
      if (!object(message) || own(message, "method") || message.id !== id) return null;
      if (message.jsonrpc !== "2.0" || own(message, "result") === own(message, "error")) {
        throw new BridgeError("invalid MCP response");
      }
      if (own(message, "result") && !object(message.result)) throw new BridgeError("invalid MCP response");
      if (own(message, "error") && (!object(message.error) || !Number.isInteger(message.error.code) || typeof message.error.message !== "string")) {
        throw new BridgeError("invalid MCP error response");
      }
      return message;
    }

    function resultOf(message) {
      if (own(message, "error")) throw new Error(message.error.message || "request failed");
      return message.result;
    }

    // Geometric growth avoids both repeated whole-line copies and a retained
    // object per tiny transport chunk.
    function byteBuffer() {
      let storage = Buffer.alloc(0);
      let length = 0;
      return {
        append(piece) {
          const needed = length + piece.length;
          if (needed > RESPONSE_LIMIT) throw new BridgeError("MCP response exceeds 16 MiB");
          if (needed > storage.length) {
            const next = Buffer.alloc(Math.min(RESPONSE_LIMIT, Math.max(needed, storage.length * 2, 4096)));
            storage.copy(next, 0, 0, length);
            storage = next;
          }
          piece.copy(storage, length);
          length = needed;
        },
        text() { return storage.toString("utf8", 0, length); },
        clear() { length = 0; },
        release() { storage = Buffer.alloc(0); length = 0; },
      };
    }

    function configServers() {
      try {
        const file = process.env.TIVANO_MCP_CONFIG || "";
        if (!file) return {};
        const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
        if (parsed && typeof parsed === "object" && parsed.mcpServers && typeof parsed.mcpServers === "object") return parsed.mcpServers;
      } catch (error) {
        console.error("tivano mcp: could not read config: " + errorText(error));
      }
      return {};
    }

    function errorText(error) {
      return error instanceof Error ? error.message : String(error);
    }

    function contentText(content) {
      const items = Array.isArray(content) ? content : [];
      return items.map((item) => (item && item.type === "text" && typeof item.text === "string" ? item.text : "[image]")).join("\n");
    }

    function describe(entry, fallback) {
      if (entry && typeof entry.description === "string" && entry.description) return entry.description;
      return fallback;
    }

    function schemaOf(entry) {
      if (entry && entry.inputSchema && typeof entry.inputSchema === "object") return entry.inputSchema;
      return { type: "object" };
    }

    function validContent(item) {
      if (!object(item)) return false;
      switch (item.type) {
        case "text": return typeof item.text === "string";
        case "image": case "audio":
          return typeof item.data === "string" && typeof item.mimeType === "string";
        case "resource_link": return typeof item.uri === "string" && typeof item.name === "string";
        case "resource":
          return object(item.resource) && typeof item.resource.uri === "string"
            && (!own(item.resource, "mimeType") || typeof item.resource.mimeType === "string")
            && (own(item.resource, "text") ? typeof item.resource.text === "string" : typeof item.resource.blob === "string");
        default: return false;
      }
    }

    async function withTimeout(connect) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(new BridgeError("timed out")), CONNECT_TIMEOUT_MS);
      try { return await connect(controller.signal); }
      finally { clearTimeout(timer); }
    }

    function wrapTools(server, entries, callTool) {
      return entries.map((entry) => {
        const callResult = async (args) => {
          try {
            const result = await callTool(entry.name, args && typeof args === "object" ? args : {});
            if (!object(result) || !Array.isArray(result.content) ||
                (own(result, "isError") && typeof result.isError !== "boolean") ||
                (own(result, "structuredContent") && !object(result.structuredContent)) ||
                result.content.some((item) => !validContent(item))) {
              throw new BridgeError("invalid MCP tool result");
            }
            const isError = !!result.isError;
            return { text: contentText(result.content) || (isError ? "tool failed" : ""), isError };
          } catch (error) {
            return { text: errorText(error), isError: true };
          }
        };
        return {
          server,
          name: String(entry.name),
          description: describe(entry, String(entry.name)),
          inputSchema: schemaOf(entry),
          callResult,
          // Existing Pi/Command Code callers keep their text-only contract.
          call: async (args) => {
            const result = await callResult(args);
            return (result.isError ? "Error: " : "") + result.text;
          },
        };
      });
    }

    function connectStdio(server, entry, signal) {
      return new Promise((resolve, reject) => {
        let child = null;
        let id = 0;
        const pending = new Map();
        const writes = new Set();
        const buffer = byteBuffer();
        let settled = false;
        let closed = null;
        let killTimer = null;
        const fail = (error) => {
          if (closed) return;
          closed = error;
          signal.removeEventListener("abort", abort);
          for (const finish of [...pending.values()]) finish(error);
          for (const finish of [...writes]) finish(error);
          buffer.release();
          if (child) {
            child.stdin.destroy();
            child.stdout.destroy();
            if (child.exitCode === null && child.signalCode === null) {
              child.kill("SIGTERM");
              killTimer = setTimeout(() => {
                if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
              }, 1000);
              killTimer.unref();
            }
          }
          if (!settled) { settled = true; reject(error); }
        };
        const abort = () => fail(signal.reason || new BridgeError("cancelled"));
        if (signal.aborted) { abort(); return; }
        signal.addEventListener("abort", abort, { once: true });
        try {
          child = spawn(entry.command, Array.isArray(entry.args) ? entry.args : [], {
            env: { ...process.env, ...((entry.env && typeof entry.env === "object") ? entry.env : {}) },
            stdio: ["pipe", "pipe", "ignore"],
          });
        } catch (error) { fail(error); return; }
        child.on("error", fail);
        child.on("exit", () => {
          if (killTimer) clearTimeout(killTimer);
          fail(new BridgeError("process exited"));
        });
        child.stdin.on("error", fail);
        child.stdout.on("error", fail);
        child.stdout.on("end", () => fail(new BridgeError("process output closed")));
        child.stdout.on("data", (data) => {
          if (closed) return;
          try {
            let start = 0;
            while (start < data.length) {
              const newline = data.indexOf(10, start);
              const end = newline < 0 ? data.length : newline;
              const piece = data.subarray(start, end);
              buffer.append(piece);
              if (newline < 0) break;
              const line = buffer.text().trim();
              buffer.clear();
              start = newline + 1;
              if (!line) continue;
              let message;
              try { message = JSON.parse(line); } catch { throw new BridgeError("invalid MCP response JSON"); }
              if (!object(message) || !pending.has(message.id)) continue;
              const response = responseFor(message, message.id);
              if (response) pending.get(message.id)(null, response);
            }
          } catch (error) { fail(error); }
        });
        const send = (method, params) => new Promise((resolveSend, rejectSend) => {
          if (closed) { rejectSend(closed); return; }
          const message = { jsonrpc: "2.0", id: id++, method };
          if (params !== undefined) message.params = params;
          let done = false;
          const finish = (error, response) => {
            if (done) return;
            done = true;
            clearTimeout(timer);
            pending.delete(message.id);
            if (error) rejectSend(error); else resolveSend(response);
          };
          const timer = setTimeout(() => fail(new BridgeError("MCP request timed out")), REQUEST_TIMEOUT_MS);
          pending.set(message.id, finish);
          try {
            child.stdin.write(JSON.stringify(message) + "\n", (error) => { if (error) fail(error); });
          } catch (error) { fail(error); }
        });
        const request = async (method, params) => resultOf(await send(method, params));
        const notify = (method, params) => new Promise((resolveNotify, rejectNotify) => {
          if (closed) { rejectNotify(closed); return; }
          const message = { jsonrpc: "2.0", method };
          if (params !== undefined) message.params = params;
          let done = false;
          const finish = (error) => {
            if (done) return;
            done = true;
            clearTimeout(timer);
            writes.delete(finish);
            if (error) rejectNotify(error); else resolveNotify();
          };
          const timer = setTimeout(() => fail(new BridgeError("MCP request timed out")), REQUEST_TIMEOUT_MS);
          writes.add(finish);
          try {
            child.stdin.write(JSON.stringify(message) + "\n", (error) => {
              if (error) fail(error);
              else finish(closed);
            });
          } catch (error) { fail(error); }
        });
        const callTool = (name, args) => request("tools/call", { name, arguments: args });
        (async () => {
          await request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "Tivano" } });
          await notify("notifications/initialized", {});
          const tools = await listTools(request);
          if (closed) throw closed;
          settled = true;
          resolve(wrapTools(server, tools, callTool));
        })().catch(fail);
      });
    }

    async function listTools(request) {
      let cursor = undefined;
      const tools = [];
      let bytes = 0;
      for (;;) {
        const result = await request("tools/list", cursor === undefined ? {} : { cursor });
        if (!object(result) || !Array.isArray(result.tools)) throw new BridgeError("invalid MCP tools list");
        bytes += Buffer.byteLength(JSON.stringify(result));
        if (bytes > RESPONSE_LIMIT) throw new BridgeError("MCP response exceeds 16 MiB");
        for (const tool of result.tools) {
          if (!object(tool) || typeof tool.name !== "string" || !object(tool.inputSchema)
              || (own(tool, "description") && typeof tool.description !== "string")) {
            throw new BridgeError("invalid MCP tools list");
          }
          tools.push(tool);
        }
        cursor = result.nextCursor;
        if (!cursor) return tools;
        if (typeof cursor !== "string") throw new BridgeError("invalid MCP tools list");
      }
    }

    // Node 18+ fetch accepts AbortSignal; cancel the body after the matching
    // SSE event rather than waiting for the server to close the stream.
    // https://nodejs.org/api/globals.html#fetch
    // https://nodejs.org/api/webstreams.html
    async function postMessage(url, headers, payload, sessionId, signal) {
      const controller = new AbortController();
      const abort = () => controller.abort(signal.reason || new BridgeError("cancelled"));
      if (signal.aborted) abort();
      else signal.addEventListener("abort", abort, { once: true });
      const timer = setTimeout(() => controller.abort(new BridgeError("MCP request timed out")), REQUEST_TIMEOUT_MS);
      let reader = null;
      try {
        const requestHeaders = { ...(headers || {}), "Content-Type": "application/json", Accept: "application/json, text/event-stream" };
        if (sessionId) requestHeaders["mcp-session-id"] = sessionId;
        const response = await fetch(url, { method: "POST", headers: requestHeaders, body: JSON.stringify(payload), signal: controller.signal });
        if (!response.ok) throw new BridgeError("MCP HTTP error (status %lld)", response.status);
        const nextSession = response.headers.get("mcp-session-id") || sessionId || null;
        if (!own(payload, "id")) return { message: null, sessionId: nextSession };
        if (!response.body) throw new BridgeError("empty MCP response");
        reader = response.body.getReader();
        const contentType = (response.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
        const sse = contentType === "text/event-stream";
        if (!sse && contentType !== "application/json") throw new BridgeError("invalid MCP response content type");
        let bytes = 0;
        const body = byteBuffer();
        const lineBuffer = byteBuffer();
        let skipLF = false;
        const eventData = byteBuffer();
        let hasEventData = false;
        let firstLine = true;
        const dispatchLine = () => {
          let line = lineBuffer.text();
          lineBuffer.clear();
          if (firstLine) { line = line.replace(/^\uFEFF/, ""); firstLine = false; }
          if (line === "") {
            if (!hasEventData) return null;
            const data = eventData.text();
            eventData.clear();
            hasEventData = false;
            let parsed;
            try { parsed = JSON.parse(data); } catch { throw new BridgeError("invalid MCP response JSON"); }
            return responseFor(parsed, payload.id);
          }
          if (line === "data" || line.startsWith("data:")) {
            if (hasEventData) eventData.append(Buffer.from("\n"));
            eventData.append(Buffer.from(line === "data" ? "" : line.slice(5).replace(/^ /, "")));
            hasEventData = true;
          }
          return null;
        };
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          bytes += value.byteLength;
          if (bytes > RESPONSE_LIMIT) throw new BridgeError("MCP response exceeds 16 MiB");
          const chunk = Buffer.from(value.buffer, value.byteOffset, value.byteLength);
          if (!sse) { body.append(chunk); continue; }
          let start = 0;
          for (let index = 0; index < chunk.length; index++) {
            const byte = chunk[index];
            if (skipLF) {
              skipLF = false;
              if (byte === 10) { start = index + 1; continue; }
            }
            if (byte !== 10 && byte !== 13) continue;
            if (index > start) lineBuffer.append(chunk.subarray(start, index));
            const message = dispatchLine();
            if (message) return { message, sessionId: nextSession };
            skipLF = byte === 13;
            start = index + 1;
          }
          if (start < chunk.length) lineBuffer.append(chunk.subarray(start));
        }
        if (sse) throw new BridgeError("empty MCP response");
        let parsed;
        try { parsed = JSON.parse(body.text()); }
        catch { throw new BridgeError("invalid MCP response JSON"); }
        const message = responseFor(parsed, payload.id);
        if (!message) throw new BridgeError("MCP response ID or envelope mismatch");
        return { message, sessionId: nextSession };
      } catch (error) {
        throw controller.signal.aborted ? controller.signal.reason : error;
      } finally {
        clearTimeout(timer);
        signal.removeEventListener("abort", abort);
        controller.abort();
        if (reader) { try { await reader.cancel(); } catch {} finally { reader.releaseLock(); } }
      }
    }

    async function connectRemote(server, entry, signal) {
      const url = entry.url;
      const headers = (entry.headers && typeof entry.headers === "object") ? entry.headers : {};
      let sessionId = null;
      let id = 0;
      const request = async (method, params) => {
        const payload = { jsonrpc: "2.0", id: id++, method };
        if (params !== undefined) payload.params = params;
        const outcome = await postMessage(url, headers, payload, sessionId, signal);
        sessionId = outcome.sessionId;
        return resultOf(outcome.message);
      };
      const notify = async (method, params) => {
        const payload = { jsonrpc: "2.0", method };
        if (params !== undefined) payload.params = params;
        const outcome = await postMessage(url, headers, payload, sessionId, signal);
        sessionId = outcome.sessionId;
      };
      await request("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "Tivano" } });
      await notify("notifications/initialized", {});
      const tools = await listTools(request);
      const callTool = (name, args) => request("tools/call", { name, arguments: args });
      return wrapTools(server, tools, callTool);
    }

    export async function loadMCPTools() {
      const servers = configServers();
      const tools = [];
      for (const server of Object.keys(servers)) {
        const entry = servers[server];
        try {
          if (entry && typeof entry === "object" && entry.type === "http" && typeof entry.url === "string") {
            tools.push(...await withTimeout((signal) => connectRemote(server, entry, signal)));
          } else if (entry && typeof entry === "object" && typeof entry.command === "string") {
            tools.push(...await withTimeout((signal) => connectStdio(server, entry, signal)));
          }
        } catch (error) {
          console.error("tivano mcp: skipping " + server + ": " + errorText(error));
        }
      }
      return tools;
    }
    """#

    /// Writes the bridge where the Pi extension and the Command Code mod can
    /// import it, and returns its path. Rewritten only when its text changed,
    /// so a new build's bridge replaces the old one.
    static func installBridge() throws -> URL {
        let directory = StoragePaths.directory("MCP")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tivano-mcp-bridge.mjs")
        let data = Data(mcpBridgeSource.utf8)
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
        }
        return file
    }
}
