import Foundation

/// The small surface Tivano needs of omp (oh-my-pi, `omp`, https://omp.sh): whether
/// it is signed in, its model catalog, and the two files Tivano installs for its
/// sessions.
///
/// omp keeps its logins in `~/.omp/agent/agent.db`, a database nothing outside omp
/// should read, so the CLI is asked instead: `omp models --json` lists the models of
/// every provider omp can use right now, and an empty list means nothing is signed in.
enum OmpCLI {
    /// omp's `--thinking` levels, which Tivano's effort strings map to 1:1. omp has an
    /// `auto` of its own that the effort slider does not offer.
    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Where the MCP extension and the settings file live.
    static var supportDirectory: URL {
        StoragePaths.directory("omp")
    }

    /// Distinct provider names with at least one usable model, else signed out; unknown
    /// when omp could not be asked.
    static func authStatus(executable: URL, environment: [String: String]) async -> ProviderStatus.Auth {
        guard let models = try? await catalog(executable: executable, environment: environment) else { return .unknown }
        let providers = Set(models.compactMap { $0["provider"]?.string }).sorted()
        return providers.isEmpty ? .signedOut : .signedIn(providers.joined(separator: ", "))
    }

    /// The chat models omp can use, with the model omp itself is set to marked as the default.
    static func listModels(executable: URL, environment: [String: String]) async throws -> [ModelOption] {
        async let current = currentModel(executable: executable, environment: environment)
        let items = try await catalog(executable: executable, environment: environment)
        let currentSelector = await current
        var options: [ModelOption] = []
        for item in items {
            guard let provider = item["provider"]?.string, let id = item["id"]?.string else { continue }
            let fullID = "\(provider)/\(id)"
            // The model's own effort levels; a model that does not reason has none.
            let efforts = (item["thinking"]?.array ?? []).compactMap(\.string)
            options.append(ModelOption(
                id: fullID,
                name: item["name"]?.string ?? id,
                detail: provider,
                efforts: efforts,
                defaultEffort: efforts.contains("medium") ? "medium" : efforts.first,
                isDefault: fullID == currentSelector
            ))
        }
        guard !options.isEmpty else {
            throw ProviderError.failed(String(localized: "omp listed no models."))
        }
        return options.sorted { ($0.detail ?? "", $0.name) < ($1.detail ?? "", $1.name) }
    }

    /// `omp models --json`: no session and no frame size limit, unlike the same list over RPC.
    private static func catalog(executable: URL, environment: [String: String]) async throws -> [JSONValue] {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? LoginEnvironment.homeDirectory
        let result = try await Shell.run(
            executable,
            ["models", "--json", "--no-extensions"],
            in: URL(fileURLWithPath: home),
            environment: environment,
            timeout: 30
        )
        guard result.succeeded, let models = JSONValue.parse(result.stdout)?["models"]?.array else {
            throw ProviderError.failed(String(format: String(localized: "omp could not list its models. %@"), result.failureMessage))
        }
        return models
    }

    /// `provider/id` of the model omp starts on, from a throwaway `omp --mode rpc` process.
    private static func currentModel(executable: URL, environment: [String: String]) async -> String? {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? LoginEnvironment.homeDirectory
        let process = StdioProcess(
            executable: executable,
            arguments: ["--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-rules"],
            directory: URL(fileURLWithPath: home),
            environment: environment,
            framing: .lines
        )
        do {
            try process.start()
        } catch {
            return nil
        }
        process.send(["type": "get_state", "id": "state"])
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            process.terminate()
        }
        var selector: String?
        for await message in process.messages where message["id"]?.string == "state" {
            if let model = (message["data"] ?? message)["model"],
               let provider = model["provider"]?.string, let id = model["id"]?.string {
                selector = "\(provider)/\(id)"
            }
            break
        }
        timeout.cancel()
        process.terminate()
        return selector
    }

    /// Writes `text` into the support directory and returns its path. Rewritten only when
    /// the text changed, so a new build's file replaces the old one.
    private static func install(_ name: String, _ text: String) throws -> URL {
        let directory = supportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        let data = Data(text.utf8)
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
        }
        return file
    }

    /// The settings overlay one session runs with (`--config`), a file of its own because
    /// the team a chat leads is its own.
    ///
    /// A shell command or a subagent that runs long is moved to the background by omp, and
    /// its result wakes the agent again with a turn nobody asked for and the app never saw
    /// begin (`bash.autoBackground`, and `async`, which covers `task`); here they are waited
    /// for, as they are for every other provider. Hydra heads never run as omp subagents: they
    /// are App-run threads, and the gate (`extensionSource`) keeps the `task` tool closed.
    ///
    /// A chat is one omp session, and the app names it by path when it resumes one (`--resume`).
    /// A launch with no path is a new conversation, which omp would not start if the user's own
    /// config has `autoResume` on: it continues the folder's latest session instead, so a new
    /// chat in a project opens with another chat's conversation in it. Off here.
    static func writeLaunchSettings(id: String, hydra: HydraLaunch?, leadModel: String?) throws -> URL {
        let lines = ["autoResume: false", "bash:", "  autoBackground:", "    enabled: false", "async:", "  enabled: false", "task:", "  maxRecursionDepth: 1"]
        let file = try launchDirectory("launch").appendingPathComponent("\(id).yml")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
        return file
    }

    /// Where this launch's gate file goes (see `OmpSession.writeGate`); the session writes it.
    static func gateFile(id: String) throws -> URL {
        try launchDirectory("gates").appendingPathComponent("\(id).json")
    }

    /// Each session owns its files until it stops; age alone cannot identify an inactive session.
    private static func launchDirectory(_ name: String) throws -> URL {
        let directory = supportDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes the gate extension where omp can load it with `-e` and returns its path. Rewritten
    /// only when its text changed, so a new build's extension replaces the old one.
    static func installExtension() throws -> URL {
        try install("tivano-gate.ts", extensionSource)
    }

    /// The name of the slash command the gate extension registers. Its presence in omp's command
    /// list is how the session knows the gate loaded; it is no command for the user.
    static let gateCommand = "tivano-gate"

    /// OMP runs in yolo; this pre-execution hook independently enforces App permissions.
    /// `allowTask` must be false with Hydra, and true only without Hydra in Full access.
    /// Missing or invalid state denies all tools; the registered command is the readiness handshake.
    /// Hook semantics: https://github.com/can1357/oh-my-pi/blob/main/docs/extensions.md
    private static let extensionSource = #"""
    import fs from "node:fs";
    import { Type } from "typebox";

    // The tools that only read, or only report back. A tool omp adds later is not one of them.
    const readOnly = new Set(["read", "grep", "glob", "find", "ast_grep", "web_search", "todo", "wait", "think", "ask", "yield"]);

    function readGate() {
      try {
        const gate = JSON.parse(fs.readFileSync(process.env.TIVANO_OMP_GATE || "", "utf8"));
        if (!gate || typeof gate !== "object" || Array.isArray(gate)
            || !["supervised", "autoAcceptEdits", "fullAccess"].includes(gate.runtimeMode)
            || !["build", "plan"].includes(gate.interactionMode)
            || typeof gate.finalReport !== "boolean" || typeof gate.allowTask !== "boolean") return null;
        return gate;
      } catch {
        return null;
      }
    }

    // `write` to `xd://<tool>` is how omp calls a tool an extension registered: that tool is the call.
    function deviceOf(path) {
      if (typeof path !== "string" || !path.startsWith("xd://")) return undefined;
      return path.slice("xd://".length).split(/[?/#]/)[0] || undefined;
    }

    export default async function (pi) {
      try {
        const bridge = process.env.TIVANO_MCP_BRIDGE ? await import(process.env.TIVANO_MCP_BRIDGE) : null;
        if (bridge) {
          for (const tool of await bridge.loadMCPTools()) {
            pi.registerTool({
              name: "mcp__" + tool.server + "__" + tool.name,
              label: tool.server + " · " + tool.name,
              description: tool.description,
              parameters: Type.Unsafe(tool.inputSchema),
              async execute(toolCallId, params) {
                const result = await tool.callResult(params);
                // MCP errors must become failed OMP tool results, not successful prose.
                // Do not infer failure from text: a successful tool can quote "Error:".
                if (result.isError) throw new Error(result.text);
                return { content: [{ type: "text", text: result.text }], details: {} };
              },
            });
          }
        }
      } catch (error) {
        console.error("tivano mcp: " + (error instanceof Error ? error.message : String(error)));
      }

      // Also covers eval agent() and workpool spawns, which do not use the task tool.
      pi.on("before_subagent_spawn", async () => {
        const gate = readGate();
        if (!gate || gate.finalReport || gate.interactionMode === "plan"
            || gate.runtimeMode !== "fullAccess" || !gate.allowTask) {
          return { block: true, reason: "Declined: OMP subagents require Full access with Hydra off." };
        }
      });

      pi.on("tool_call", async (event, ctx) => {
        const gate = readGate();
        if (!gate) return { block: true, reason: "Declined: the App tool gate is missing or invalid." };
        const device = event.toolName === "write" ? deviceOf(event.input && event.input.path) : undefined;
        const name = device ?? event.toolName;
        if (gate.finalReport) return { block: true, reason: "Declined: this is the final report, with no tools." };
        if (name === "task" && (gate.allowTask !== true || gate.runtimeMode !== "fullAccess")) {
          return { block: true, reason: "Declined: OMP subagents require Full access with Hydra off." };
        }
        if (readOnly.has(name)) return;
        if (gate.interactionMode === "plan") return { block: true, reason: "Declined: plan mode is read-only." };
        if (gate.runtimeMode === "fullAccess") return;
        const kind = name === "bash" || name === "eval" ? "command"
          : !device && ["write", "edit", "ast_edit", "notebook"].includes(event.toolName) ? "fileChange" : "tool";
        if (kind === "fileChange" && gate.runtimeMode === "autoAcceptEdits") return;
        if (!ctx.hasUI) return { block: true, reason: "Declined: App approval is unavailable." };
        const input = {};
        for (const [key, value] of Object.entries(event.input || {})) {
          input[key] = typeof value === "string" && value.length > 20000 ? value.slice(0, 20000) : value;
        }
        const payload = { kind, toolName: event.toolName, toolCallId: event.toolCallId, input };
        const answer = await ctx.ui.select("tivano-gate " + JSON.stringify(payload), ["Approve", "Deny"]);
        if (answer === "Approve") return;
        return { block: true, reason: "Declined: the user declined this " + (kind === "command" ? "command" : kind === "fileChange" ? "file change" : "tool call") + "." };
      });
      pi.registerCommand("tivano-gate", { description: "Tivano's tool gate", handler: async () => {} });
    }
    """#
}
