import Foundation
import Darwin
import os

private enum CLIText {
    static let appURL: URL? = {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var bytes = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&bytes, &size) == 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }()
    static let bundle: Bundle = appURL.flatMap(Bundle.init(url:)) ?? .main
    static func localized(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: "Localizable") }
    static let usage = """
    Tivano local control (the app must already be running and manually enabled in Settings › Connections).
    Commands: info | providers | projects | threads | thread UUID | history UUID
      create --workspace local|worktree --provider ID [--project UUID] [--model ID] [--hydra on|off]
      send UUID --text TEXT [--continuation automatic|fresh|providerSession|transcript]
      send UUID --stdin [--continuation MODE]
      interrupt UUID --turn UUID
      operation INSTANCE/UUID/TIMESTAMP
      settings get | settings set textGeneration automatic|claude|codex|grok|pi|off
      settings set weatherWindow true|false
    List flags: --limit N --cursor TOKEN
    Thread flags: --archive active|archived|all --role normal|helper|head|all
      --affiliation all|standalone|project|missing_project [--project UUID] [--search TEXT]
    Writes: --operation INSTANCE/UUID/TIMESTAMP reuses an existing ticket in that instance only.
    Save the ticket printed before delivery. A disconnect is not failure; query the ticket instead of repeating the write.
    JSON output reports acceptance, not task success. Expired/restarted outcomes are unknown. No automatic retries or app launch.
    """
    static let agentUsage = """
    Agent bridge (no Local control switch needed; starts Tivano hidden if it is not running):
      agent models [--json]
      agent run [--json] --cwd DIR [--model ID] [--session SID]   (prompt from stdin, NDJSON events on stdout)
    """
}

private struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var stdin = false
    var before = false

    init(_ values: [String]) throws {
        var index = 0
        while index < values.count {
            let value = values[index]
            if value == "--stdin" {
                guard !stdin else { throw ControlFailure(code: .invalidRequest) }
                stdin = true
                index += 1
            } else if value == "--before" {
                guard !before else { throw ControlFailure(code: .invalidRequest) }
                before = true
                index += 1
            } else if value.hasPrefix("--") {
                guard index + 1 < values.count, flags[value] == nil, !values[index + 1].hasPrefix("--") else { throw ControlFailure(code: .invalidRequest) }
                flags[value] = values[index + 1]
                index += 2
            } else { positional.append(value); index += 1 }
        }
    }

    mutating func take(_ name: String) -> String? { flags.removeValue(forKey: name) }
    mutating func uuid(_ name: String) throws -> UUID? {
        guard let value = take(name) else { return nil }
        guard let id = UUID(uuidString: value) else { throw ControlFailure(code: .invalidRequest) }
        return id
    }
    mutating func page(defaultLimit: Int = 50) throws -> ControlPage {
        let raw = take("--limit")
        let limit = raw.flatMap(Int.init) ?? defaultLimit
        guard raw == nil || Int(raw!) != nil else { throw ControlFailure(code: .invalidRequest) }
        guard (1...100).contains(limit) else { throw ControlFailure(code: .bounds) }
        return ControlPage(limit: limit, cursor: take("--cursor"))
    }
    func finished() throws {
        guard flags.isEmpty, !stdin, !before else { throw ControlFailure(code: .invalidRequest) }
    }
}

private enum CLI {
    static let edition: ControlEdition = {
        #if TIVANO_PREVIEW
        .preview
        #elseif DEBUG
        .dev
        #else
        .release
        #endif
    }()

    static func run() -> Int32 {
        let values = Array(CommandLine.arguments.dropFirst())
        if values.first == "agent" {
            return runAgent(Array(values.dropFirst()))
        }
        do {
            if values.isEmpty || values == ["--help"] || values == ["help"] {
                print(CLIText.localized(CLIText.usage))
                print(CLIText.localized(CLIText.agentUsage))
                return 0
            }
            var arguments = try Arguments(values)
            let rawTicket = arguments.take("--operation")
            let ticket: ControlTicket?
            if let rawTicket {
                guard let parsed = ControlTicket(rawTicket) else { throw ControlFailure(code: .invalidRequest) }
                ticket = parsed
            } else { ticket = nil }
            let client = try ControlClient(edition: edition, expectedInstance: ticket?.instance)
            let command = try command(&arguments, ticket: ticket ?? ControlTicket(instance: client.welcome.instance))
            try arguments.finished()
            if let ticket, command.ticket == nil { _ = ticket; throw ControlFailure(code: .invalidRequest) }
            if let ticket = command.ticket {
                let message = String(format: CLIText.localized("Operation ticket: %@"), ticket.string)
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            let response = try client.request(command)
            let output = try LocalControl.encoder().encode(response) + Data([10])
            if response.error != nil {
                FileHandle.standardError.write(output)
                return 2
            }
            FileHandle.standardOutput.write(output)
            if case .operation(let outcome) = response.result {
                if outcome.state == .failed { return 3 }
                if outcome.state == .unknown { return 4 }
            }
            return 0
        } catch {
            let failure = error as? ControlFailure ?? ControlFailure(code: .invalidRequest)
            if let data = try? LocalControl.encoder().encode(ControlResponse(error: failure)) {
                FileHandle.standardError.write(data + Data([10]))
            }
            FileHandle.standardError.write(Data((CLIText.localized("Open the correct edition of Tivano yourself and enable Local control in Settings › Connections. Use --help for syntax. Never blindly retry a write after a disconnect.") + "\n").utf8))
            return 2
        }
    }

    private static func command(_ args: inout Arguments, ticket: ControlTicket) throws -> ControlCommand {
        guard let name = args.positional.first else { throw ControlFailure(code: .invalidRequest) }
        let values = Array(args.positional.dropFirst())
        func id() throws -> UUID {
            guard values.count == 1, let id = UUID(uuidString: values[0]) else { throw ControlFailure(code: .invalidRequest) }
            return id
        }
        switch name {
        case "info": guard values.isEmpty else { throw ControlFailure(code: .invalidRequest) }; return .info
        case "providers": guard values.isEmpty else { throw ControlFailure(code: .invalidRequest) }; return .providers
        case "projects": guard values.isEmpty else { throw ControlFailure(code: .invalidRequest) }; return .projects(try args.page())
        case "threads":
            guard values.isEmpty else { throw ControlFailure(code: .invalidRequest) }
            let page = try args.page()
            guard let archive = ControlArchiveFilter(rawValue: args.take("--archive") ?? "active"),
                  let role = ControlRoleFilter(rawValue: args.take("--role") ?? "normal"),
                  let affiliation = ControlAffiliationFilter(rawValue: args.take("--affiliation") ?? "all") else { throw ControlFailure(code: .invalidRequest) }
            return .threads(ControlThreadQuery(page: page, archive: archive, role: role, affiliation: affiliation,
                                               projectID: try args.uuid("--project"), search: args.take("--search")))
        case "thread": return .thread(try id())
        case "history":
            let threadID = try id()
            let page = try args.page(defaultLimit: 25)
            guard page.limit <= 50 else { throw ControlFailure(code: .bounds) }
            return .history(ControlHistoryQuery(threadID: threadID, page: page))
        case "create":
            guard values.isEmpty, let workspace = args.take("--workspace").flatMap(ControlWorkspaceMode.init(rawValue:)),
                  let provider = args.take("--provider"), !provider.isEmpty else { throw ControlFailure(code: .invalidRequest) }
            let hydra: Bool?
            switch args.take("--hydra") {
            case nil: hydra = nil
            case "on": hydra = true
            case "off": hydra = false
            default: throw ControlFailure(code: .invalidRequest)
            }
            return .create(ControlCreate(ticket: ticket, projectID: try args.uuid("--project"), workspace: workspace, provider: provider, model: args.take("--model"), hydra: hydra))
        case "branch":
            let threadID = try id()
            guard let turnID = try args.uuid("--turn") else { throw ControlFailure(code: .invalidRequest) }
            let mode: ControlBranchMode = args.before ? .before : .through
            args.before = false
            return .branch(ControlBranch(ticket: ticket, threadID: threadID, turnID: turnID, mode: mode))
        case "send":
            let threadID = try id()
            guard let mode = ControlContinuation(rawValue: args.take("--continuation") ?? "automatic") else { throw ControlFailure(code: .invalidRequest) }
            let text: String
            if args.stdin {
                guard args.take("--text") == nil else { throw ControlFailure(code: .invalidRequest) }
                args.stdin = false
                text = try readStdin()
            } else {
                guard let value = args.take("--text") else { throw ControlFailure(code: .invalidRequest) }
                text = value
            }
            guard text.utf8.count <= LocalControl.maxText else { throw ControlFailure(code: .bounds) }
            return .submit(ControlSubmit(ticket: ticket, threadID: threadID, text: text, continuation: mode))
        case "interrupt":
            let threadID = try id()
            guard let turnID = try args.uuid("--turn") else { throw ControlFailure(code: .invalidRequest) }
            return .interrupt(ControlInterrupt(ticket: ticket, threadID: threadID, turnID: turnID))
        case "operation":
            guard values.count == 1, let ticket = ControlTicket(values[0]) else { throw ControlFailure(code: .invalidRequest) }
            return .operation(ticket)
        case "settings":
            if values == ["get"] { return .settingsGet }
            guard values.count == 3, values[0] == "set", let key = ControlSettingKey(rawValue: values[1]) else { throw ControlFailure(code: .invalidRequest) }
            let value: ControlSettingValue
            switch key {
            case .textGeneration:
                guard let choice = ControlTextGeneration(rawValue: values[2]) else { throw ControlFailure(code: .invalidRequest) }
                value = .textGeneration(choice)
            case .weatherWindow:
                guard ["true", "false"].contains(values[2]) else { throw ControlFailure(code: .invalidRequest) }
                value = .bool(values[2] == "true")
            }
            return .settingsSet(ControlSettingsWrite(ticket: ticket, key: key, value: value))
        default: throw ControlFailure(code: .invalidRequest)
        }
    }

    private static func readStdin() throws -> String {
        guard isatty(STDIN_FILENO) == 0 else { throw ControlFailure(code: .invalidRequest) }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ControlFailure(code: .bounds) }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining * 1_000)) > 0 else { throw ControlFailure(code: .unavailable) }
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ControlFailure(code: .invalidRequest) }
            if count == 0 { break }
            guard data.count + count <= LocalControl.maxText else { throw ControlFailure(code: .bounds) }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ControlFailure(code: .invalidRequest) }
        return text
    }

    private struct AgentCLIError: Error {
        let code: ControlAgentErrorCode
        let message: String
    }

    private struct AgentRunOptions {
        let cwd: String
        let model: String?
        let session: String?
    }

    private struct AgentModelsErrorEnvelope: Encodable {
        struct Payload: Encodable {
            let code: String
            let message: String
        }
        let version = 1
        let models: [ControlAgentModel] = []
        let error: Payload
    }

    private final class AgentSignalController: @unchecked Sendable {
        private struct State: Sendable {
            var client: ControlClient?
            var receivedSignal: Int32 = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private var sources: [DispatchSourceSignal] = []

        func install() {
            _ = signal(SIGINT, SIG_IGN)
            _ = signal(SIGTERM, SIG_IGN)
            let queue = DispatchQueue.global(qos: .userInitiated)
            for sig in [SIGINT, SIGTERM] {
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler { [weak self] in
                    self?.handle(sig)
                }
                source.resume()
                sources.append(source)
            }
        }

        func attach(_ client: ControlClient) {
            let pending: Int32 = state.withLock { current in
                current.client = client
                return current.receivedSignal
            }
            if pending != 0 {
                client.interrupt()
            }
        }

        var exitCodeIfSignaled: Int32? {
            switch state.withLock({ $0.receivedSignal }) {
            case SIGINT: 130
            case SIGTERM: 143
            default: nil
            }
        }

        private func handle(_ sig: Int32) {
            let client: ControlClient? = state.withLock { current in
                if current.receivedSignal == 0 { current.receivedSignal = sig }
                return current.client
            }
            if let client {
                client.interrupt()
            } else {
                Darwin._exit(sig == SIGINT ? 130 : 143)
            }
        }

        deinit {
            for source in sources { source.cancel() }
        }
    }

    private static func runAgent(_ args: [String]) -> Int32 {
        guard let subcommand = args.first else {
            writeAgentEvent(.error(.bad_request, "Missing agent subcommand. Expected 'models' or 'run'."))
            return 1
        }
        let rest = Array(args.dropFirst())
        switch subcommand {
        case "models":
            return runAgentModels(rest)
        case "run":
            return runAgentRun(rest)
        default:
            writeAgentEvent(.error(.bad_request, "Unknown agent subcommand '\(subcommand)'. Expected 'models' or 'run'."))
            return 1
        }
    }

    private static func runAgentModels(_ args: [String]) -> Int32 {
        do {
            var sawJSON = false
            for token in args {
                if token == "--json" {
                    guard !sawJSON else { throw AgentCLIError(code: .bad_request, message: "Duplicate flag '--json'.") }
                    sawJSON = true
                } else {
                    throw AgentCLIError(code: .bad_request, message: "Unexpected argument '\(token)'.")
                }
            }
            let client = try ControlClient.connectLaunching(edition: edition, app: CLIText.appURL)
            guard client.welcome.methods.contains("agentModels") else {
                throw AgentCLIError(code: .app_unavailable, message: "This Tivano version has no agent bridge; update Tivano.")
            }
            let response = try client.request(.agentModels)
            if let failure = response.error {
                throw failure
            }
            guard case .agentModels(let models) = response.result else {
                throw AgentCLIError(code: .internal, message: "Unexpected response from Tivano.")
            }
            let data = try LocalControl.encoder().encode(models) + Data([10])
            writeStdoutData(data)
            return 0
        } catch {
            let (code, message) = mapAgentError(error)
            writeModelsError(code: code, message: message)
            return 1
        }
    }

    private static func runAgentRun(_ args: [String]) -> Int32 {
        let signals = AgentSignalController()
        do {
            let options = try parseAgentRunOptions(args)
            signals.install()
            let prompt = try readAgentStdin()
            let client = try ControlClient.connectLaunching(edition: edition, app: CLIText.appURL)
            signals.attach(client)
            guard client.welcome.methods.contains("agentRun") else {
                throw AgentCLIError(code: .app_unavailable, message: "This Tivano version has no agent bridge; update Tivano.")
            }
            var terminalExit: Int32?
            do {
                try client.stream(.agentRun(ControlAgentRun(cwd: options.cwd, model: options.model, session: options.session, prompt: prompt))) { response in
                    if let failure = response.error {
                        let (code, message) = mapAgentError(failure)
                        writeAgentEvent(.error(code, message))
                        terminalExit = 1
                        return false
                    }
                    guard case .agentEvent(let line) = response.result else {
                        writeAgentEvent(.error(.internal, "Unexpected response from Tivano."))
                        terminalExit = 1
                        return false
                    }
                    writeStdoutLine(line.json)
                    if line.type == "done" {
                        terminalExit = 0
                        return false
                    }
                    if line.type == "error" {
                        terminalExit = 1
                        return false
                    }
                    return true
                }
            } catch let failure as ControlFailure where failure.code == .unavailable && failure.detail == "closed" {
                if let code = signals.exitCodeIfSignaled { return code }
                writeAgentEvent(.error(.internal, "connection closed"))
                return 1
            }
            if let exitCode = terminalExit { return exitCode }
            if let code = signals.exitCodeIfSignaled { return code }
            writeAgentEvent(.error(.internal, "connection closed"))
            return 1
        } catch {
            if let code = signals.exitCodeIfSignaled { return code }
            let (code, message) = mapAgentError(error)
            writeAgentEvent(.error(code, message))
            return 1
        }
    }

    private static func parseAgentRunOptions(_ args: [String]) throws -> AgentRunOptions {
        var sawJSON = false
        var rawCwd: String?
        var model: String?
        var session: String?
        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--json":
                guard !sawJSON else { throw AgentCLIError(code: .bad_request, message: "Duplicate flag '--json'.") }
                sawJSON = true
                index += 1
            case "--cwd":
                guard rawCwd == nil else { throw AgentCLIError(code: .bad_request, message: "Duplicate flag '--cwd'.") }
                guard index + 1 < args.count else { throw AgentCLIError(code: .bad_request, message: "Missing value for '--cwd'.") }
                let value = args[index + 1]
                guard !value.isEmpty, !value.hasPrefix("--") else { throw AgentCLIError(code: .bad_request, message: "Invalid value for '--cwd'.") }
                rawCwd = value
                index += 2
            case "--model":
                guard model == nil else { throw AgentCLIError(code: .bad_request, message: "Duplicate flag '--model'.") }
                guard index + 1 < args.count else { throw AgentCLIError(code: .bad_request, message: "Missing value for '--model'.") }
                let value = args[index + 1]
                guard !value.isEmpty, !value.hasPrefix("--") else { throw AgentCLIError(code: .bad_request, message: "Invalid value for '--model'.") }
                model = value
                index += 2
            case "--session":
                guard session == nil else { throw AgentCLIError(code: .bad_request, message: "Duplicate flag '--session'.") }
                guard index + 1 < args.count else { throw AgentCLIError(code: .bad_request, message: "Missing value for '--session'.") }
                let value = args[index + 1]
                guard !value.isEmpty, !value.hasPrefix("--") else { throw AgentCLIError(code: .bad_request, message: "Invalid value for '--session'.") }
                session = value
                index += 2
            default:
                throw AgentCLIError(code: .bad_request, message: "Unexpected argument '\(token)'.")
            }
        }
        guard let rawCwd else {
            throw AgentCLIError(code: .bad_request, message: "Missing required '--cwd' option.")
        }
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let cwdURL = rawCwd.hasPrefix("/")
            ? URL(fileURLWithPath: rawCwd).standardizedFileURL
            : URL(fileURLWithPath: rawCwd, relativeTo: base).standardizedFileURL
        return AgentRunOptions(cwd: cwdURL.path, model: model, session: session)
    }

    private static func readAgentStdin() throws -> String {
        guard isatty(STDIN_FILENO) == 0 else {
            throw AgentCLIError(code: .bad_request, message: "Prompt must be piped on stdin.")
        }
        // A blocking read: poll() does not report FIFOs as readable on macOS, and the
        // caller (BeRead) closes stdin once the prompt is written.
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw AgentCLIError(code: .internal, message: "Failed to read prompt from stdin.")
            }
            if count == 0 { break }
            guard data.count + count <= LocalControl.maxAgentPrompt else {
                throw AgentCLIError(code: .bad_request, message: "Prompt exceeds the \(LocalControl.maxAgentPrompt)-byte limit.")
            }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentCLIError(code: .bad_request, message: "Prompt is not valid UTF-8.")
        }
        return text
    }

    private static func mapAgentError(_ error: Error) -> (ControlAgentErrorCode, String) {
        if let cliError = error as? AgentCLIError {
            return (cliError.code, cliError.message)
        }
        if let failure = error as? ControlFailure {
            if failure.code == .unavailable {
                if failure.detail == "launch_timeout" {
                    return (.app_unavailable, "Tivano did not start within 15 seconds.")
                }
                if failure.detail == "launch_failed" {
                    return (.app_unavailable, "Could not launch Tivano.")
                }
            }
            let code: ControlAgentErrorCode
            switch failure.code {
            case .unavailable, .disabled, .shutdown, .permission, .editionMismatch, .protocolMismatch, .instanceMismatch:
                code = .app_unavailable
            case .bounds:
                return (.bad_request, "The prompt is too large: the JSON-encoded request must fit in \(LocalControl.maxFrame) bytes.")
            case .invalidRequest:
                code = .bad_request
            default:
                code = .internal
            }
            return (code, failure.code.message)
        }
        return (.internal, "Unexpected internal error.")
    }

    private static func writeStdoutData(_ data: Data) {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func writeStdoutLine(_ line: String) {
        writeStdoutData(Data((line + "\n").utf8))
    }

    private static func writeAgentEvent(_ event: ControlAgentEvent) {
        writeStdoutLine(event.line.json)
    }

    private static func writeModelsError(code: ControlAgentErrorCode, message: String) {
        let envelope = AgentModelsErrorEnvelope(error: .init(code: code.rawValue, message: message))
        if let data = try? LocalControl.encoder().encode(envelope) {
            writeStdoutData(data + Data([10]))
        } else {
            writeStdoutLine(#"{"version":1,"models":[],"error":{"code":"internal","message":"encoding"}}"#)
        }
    }
}

exit(CLI.run())
