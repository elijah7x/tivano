import Foundation

/// The small surface Tivano needs of the Pi coding harness (`pi`, the npm
/// package `@earendil-works/pi-coding-agent`): where its login lives, its model
/// catalog over RPC, and the gate extension that routes tool approvals to the app.
///
/// Pi signs in per provider under `~/.pi/agent/auth.json` (or `PI_CODING_AGENT_DIR`
/// when set); a bare provider API key in the environment also counts as signed in.
enum PiCLI {
    /// Pi's `--thinking` levels, which the effort strings map to 1:1.
    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Where the gate extension and each session's gate file live: in this edition's own
    /// library, so Release and Dev never load or overwrite each other's gate.
    static var supportDirectory: URL {
        StoragePaths.directory("pi")
    }

    /// `PI_CODING_AGENT_DIR` when set, else `<home>/.pi/agent`.
    static func configDirectory(environment: [String: String]) -> URL {
        if let directory = environment["PI_CODING_AGENT_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? LoginEnvironment.homeDirectory
        return URL(fileURLWithPath: home).appendingPathComponent(".pi/agent", isDirectory: true)
    }

    /// `auth.json` as an object with at least one key (the keys are provider names
    /// such as anthropic, openai), else any provider API key in the environment.
    static func authStatus(executable: URL, environment: [String: String]) async -> ProviderStatus.Auth {
        let file = configDirectory(environment: environment).appendingPathComponent("auth.json")
        if let data = try? Data(contentsOf: file),
           let json = JSONValue.parse(data),
           let object = json.object, !object.isEmpty {
            return .signedIn(object.keys.sorted().joined(separator: ", "))
        }
        for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "OPENROUTER_API_KEY", "GROQ_API_KEY", "MISTRAL_API_KEY", "DEEPSEEK_API_KEY", "XAI_API_KEY"] {
            if let value = environment[key], !value.isEmpty {
                return .signedIn(nil)
            }
        }
        return .signedOut
    }

    /// Asks a throwaway `pi --mode rpc` process for its state and model catalog.
    static func listModels(executable: URL, environment: [String: String]) async throws -> [ModelOption] {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? LoginEnvironment.homeDirectory
        var launchEnvironment = environment
        launchEnvironment["PI_SKIP_VERSION_CHECK"] = "1"
        let process = StdioProcess(
            executable: executable,
            arguments: ["--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files"],
            directory: URL(fileURLWithPath: home),
            environment: launchEnvironment,
            framing: .lines
        )
        do {
            try process.start()
        } catch {
            throw ProviderError.failed("Pi could not start: \(error.localizedDescription)")
        }
        process.send(["type": "get_state", "id": "state"])
        process.send(["type": "get_available_models", "id": "models"])
        var stateResponse: JSONValue?
        var modelsResponse: JSONValue?
        let timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            process.terminate()
        }
        for await message in process.messages {
            switch message["id"]?.string {
            case "state":
                stateResponse = message
            case "models":
                modelsResponse = message
            default:
                break
            }
            if stateResponse != nil, modelsResponse != nil { break }
        }
        timeout.cancel()
        process.terminate()

        let stateData = stateResponse?["data"] ?? stateResponse ?? .null
        let currentProvider = stateData["model"]?["provider"]?.string
        let currentID = stateData["model"]?["id"]?.string
        let items = modelsResponse?["data"]?["models"]?.array ?? modelsResponse?["models"]?.array ?? []
        var options: [ModelOption] = []
        for item in items {
            guard let provider = item["provider"]?.string, let id = item["id"]?.string else { continue }
            let reasoning = item["reasoning"]?.bool == true
            let fullID = "\(provider)/\(id)"
            let isCurrent: Bool = {
                guard let currentProvider, let currentID else { return false }
                if currentID.contains("/") { return fullID == currentID }
                return provider == currentProvider && id == currentID
            }()
            options.append(ModelOption(
                id: fullID,
                name: item["name"]?.string ?? id,
                detail: provider,
                efforts: reasoning ? thinkingLevels : [],
                defaultEffort: reasoning ? "medium" : nil,
                isDefault: isCurrent
            ))
        }
        guard !options.isEmpty else {
            throw ProviderError.failed("Pi listed no models.")
        }
        return options.sorted { ($0.detail ?? "", $0.name) < ($1.detail ?? "", $1.name) }
    }

    /// Writes the gate extension where `pi --mode rpc` can load it and returns its
    /// path. Rewritten only when its text changed, so a new build's extension
    /// replaces the old one.
    static func installExtension() throws -> URL {
        let directory = supportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tivano-gate.ts")
        let data = Data(extensionSource.utf8)
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
        }
        return file
    }

    /// The gate Tivano loads into every RPC session with `-e`. Pi itself keeps
    /// approving everything (`--approve`) or nothing (`--no-approve`); this extension
    /// gates the tools instead: every call that could change something is asked over
    /// `ctx.ui.select`, which in RPC mode surfaces on stdout as an
    /// `extension_ui_request` the app answers. Read-only tools pass straight through.
    /// Supervised asks for all of them, Auto-accept edits waves file changes through,
    /// Auto also passes shell commands that only read, and Full access returns before
    /// asking anything. Plan mode and the final report block the tools outright.
    static let extensionSource: String = #"""
    import fs from "node:fs";
    import { Type } from "typebox";

    const readOnly = new Set(["read", "grep", "find", "ls"]);

    const positiveInteger = (value) => /^[0-9]+$/.test(value);
    const anyValue = (value) => value.length > 0;
    const readOnlyBinaries = {
      ls: { short: "ABCFGHLOPRSUacdfghiklmnopqrstux1", long: [] },
      cat: { short: "benstuv", long: [] },
      head: { short: "qv", long: [], values: { "-n": positiveInteger, "-c": positiveInteger } },
      tail: { short: "qv", long: [], values: { "-n": positiveInteger, "-c": positiveInteger } },
      wc: { short: "clmwL", long: [] },
      pwd: { short: "LP", long: [], maxOperands: 0 },
      echo: { short: "n", long: [] },
      grep: {
        short: "EFGHILRabcchilnoqrsvwx", long: ["--color=never", "--color=auto", "--color=always"],
        values: { "-e": anyValue, "-f": anyValue, "-A": positiveInteger, "-B": positiveInteger, "-C": positiveInteger, "-m": positiveInteger },
      },
      rg: {
        short: "AFHILNPSUabcchilnoqsuvwxi", long: ["--files", "--hidden", "--no-ignore", "--no-ignore-vcs", "--fixed-strings", "--line-number", "--count", "--files-with-matches", "--files-without-match", "--no-heading", "--heading", "--no-config", "--color=never", "--color=auto", "--color=always"],
        values: { "-e": anyValue, "-f": anyValue, "-g": anyValue, "-t": anyValue, "-T": anyValue, "-A": positiveInteger, "-B": positiveInteger, "-C": positiveInteger, "-m": positiveInteger, "--glob": anyValue, "--type": anyValue, "--type-not": anyValue, "--max-count": positiveInteger },
      },
      sort: { short: "bcdfghinru", long: [], values: { "-k": anyValue, "-t": anyValue }, maxOperands: 1 },
      uniq: { short: "cdui", long: [], values: { "-f": positiveInteger, "-s": positiveInteger, "-w": positiveInteger }, maxOperands: 1 },
    };
    const gitDiffFlags = ["--stat", "--shortstat", "--numstat", "--name-only", "--name-status", "--check", "--patch", "--no-patch", "--raw", "--no-ext-diff", "--no-textconv", "--color=never", "--color=auto", "--color=always"];
    const readOnlyGit = {
      status: { short: "sbz", long: ["--short", "--branch", "--porcelain", "--porcelain=v1", "--porcelain=v2", "--untracked-files=no", "--untracked-files=normal", "--untracked-files=all", "--ignored"] },
      diff: { short: "pws", long: [...gitDiffFlags, "--cached", "--staged", "--exit-code", "--quiet"], values: { "-U": positiveInteger } },
      log: { short: "p", long: [...gitDiffFlags, "--oneline", "--graph", "--all", "--decorate", "--no-decorate", "--reverse", "--first-parent", "--no-merges"], values: { "-n": positiveInteger, "--max-count": positiveInteger } },
      show: { short: "ps", long: [...gitDiffFlags, "--oneline"], values: { "-U": positiveInteger } },
      branch: { short: "arv", long: ["--all", "--remotes", "--list", "--show-current"], maxOperands: 0 },
    };

    function readGate() {
      try {
        const file = process.env.TIVANO_PI_GATE || "";
        return JSON.parse(fs.readFileSync(file, "utf8"));
      } catch {
        return {};
      }
    }

    function simpleCommandWords(command) {
      // Deliberately reject even quoted substitutions/metacharacters when uncertain.
      if (typeof command !== "string" || /[\x00-\x08\x0a-\x1f\x7f$`\\<>;&|]/.test(command)) return null;
      const words = [];
      let word = "", quote = null, started = false;
      for (const char of command) {
        if (quote) {
          if (char === quote) quote = null;
          else word += char;
          started = true;
        } else if (char === "'" || char === '"') {
          quote = char;
          started = true;
        } else if (char === " " || char === "\t") {
          if (started) words.push(word);
          word = "";
          started = false;
        } else {
          if (/[(){}*?\[\]~#!]/.test(char) || /\s/.test(char)) return null;
          word += char;
          started = true;
        }
      }
      if (quote) return null;
      if (started) words.push(word);
      return words.length > 0 ? words : null;
    }

    function allowedArguments(args, rule) {
      let operands = 0, options = true;
      const values = rule.values || {};
      for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        if (options && arg === "--") { options = false; continue; }
        if (!options || !arg.startsWith("-") || arg === "-") { operands++; continue; }
        if (rule.long.includes(arg)) continue;
        if (arg.startsWith("--")) {
          const equal = arg.indexOf("=");
          const key = equal < 0 ? arg : arg.slice(0, equal);
          if (!Object.hasOwn(values, key)) return false;
          const value = equal < 0 ? args[++i] : arg.slice(equal + 1);
          if (value === undefined || !values[key](value)) return false;
          continue;
        }
        for (let j = 1; j < arg.length; j++) {
          const key = "-" + arg[j];
          if (Object.hasOwn(values, key)) {
            const value = j + 1 < arg.length ? arg.slice(j + 1) : args[++i];
            if (value === undefined || !values[key](value)) return false;
            break;
          }
          if (!rule.short.includes(arg[j])) return false;
        }
      }
      return operands <= (rule.maxOperands ?? Infinity);
    }

    function readOnlyFind(args) {
      const predicates = {
        "-name": anyValue, "-iname": anyValue, "-path": anyValue, "-ipath": anyValue,
        "-type": (value) => /^[bcdflps]$/.test(value),
        "-maxdepth": positiveInteger, "-mindepth": positiveInteger,
        "-mtime": (value) => /^[+-]?[0-9]+$/.test(value),
      };
      let expression = false;
      for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        if (!expression && !arg.startsWith("-")) continue;
        expression = true;
        if (["-print", "-print0", "-empty"].includes(arg)) continue;
        if (!Object.hasOwn(predicates, arg)) return false;
        const value = args[++i];
        if (value === undefined || !predicates[arg](value)) return false;
      }
      return true;
    }

    function isReadOnlyCommand(command, approved) {
      const words = simpleCommandWords(command);
      if (!words) return false;
      const binary = words[0];
      if (binary === "git") {
        const subcommand = words[1];
        if (!Object.hasOwn(readOnlyGit, subcommand) || !allowedArguments(words.slice(2), readOnlyGit[subcommand])) return false;
        // Keep normal Git queries usable without config-selected executables.
        const safe = ["git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false", "-c", "format.pretty=medium", "-c", "diff.submodule=short", subcommand];
        if (["diff", "log", "show"].includes(subcommand)) safe.push("--no-ext-diff", "--no-textconv");
        safe.push(...words.slice(2));
        approved.command = safe.map((word) => "'" + word.replace(/'/g, "'\\''") + "'").join(" ");
        return true;
      }
      if (binary === "find") return readOnlyFind(words.slice(1));
      if (!Object.hasOwn(readOnlyBinaries, binary) || !allowedArguments(words.slice(1), readOnlyBinaries[binary])) return false;
      if (binary === "rg") approved.command = ["rg", "--no-config", ...words.slice(1)].map((word) => "'" + word.replace(/'/g, "'\\''") + "'").join(" ");
      return true;
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
                const text = await tool.call(params);
                return { content: [{ type: "text", text }], details: {} };
              },
            });
          }
        }
      } catch (error) {
        console.error("tivano mcp: " + (error instanceof Error ? error.message : String(error)));
      }
      pi.on("before_agent_start", async (event, ctx) => {
        const gate = readGate();
        const extra = [];
        if (gate.finalReport) extra.push("Reply with your final report now: no tools, one message.");
        if (gate.interactionMode === "plan") extra.push("You are in plan mode: read-only. Do not edit files or run commands that change anything; investigate, then end with the plan as markdown.");
        if (typeof gate.systemPrompt === "string" && gate.systemPrompt.length > 0) extra.push(gate.systemPrompt);
        if (extra.length === 0) return;
        return { systemPrompt: event.systemPrompt + "\n\n" + extra.join("\n\n") };
      });

      pi.on("tool_call", async (event, ctx) => {
        const gate = readGate();
        if (gate.finalReport) return { block: true, reason: "Final report: no tools" };
        if (readOnly.has(event.toolName)) return;
        if (gate.interactionMode === "plan") return { block: true, reason: "Plan mode is read-only" };
        if (gate.runtimeMode === "fullAccess") return;
        const kind = event.toolName === "bash" ? "command" : (event.toolName === "edit" || event.toolName === "write") ? "fileChange" : "tool";
        if (kind === "fileChange" && (gate.runtimeMode === "autoAcceptEdits" || gate.runtimeMode === "auto")) return;
        if (kind === "command" && gate.runtimeMode === "auto") {
          const approved = {};
          if (isReadOnlyCommand(event.input && event.input.command, approved)) {
            if (approved.command) event.input.command = approved.command;
            return;
          }
        }
        const input = {};
        for (const [key, value] of Object.entries(event.input || {})) {
          input[key] = typeof value === "string" && value.length > 20000 ? value.slice(0, 20000) : value;
        }
        const payload = { kind, toolName: event.toolName, toolCallId: event.toolCallId, input };
        const answer = await ctx.ui.select("tivano-gate " + JSON.stringify(payload), ["Allow", "Allow for session", "Deny"]);
        if (answer === "Allow" || answer === "Allow for session") return undefined;
        return { block: true, reason: "The user declined this " + (kind === "command" ? "command" : kind === "fileChange" ? "file change" : "tool call") };
      });
    }
    """#
}
