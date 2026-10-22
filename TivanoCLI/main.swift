import Foundation
import Darwin

private enum CLIText {
    static let bundle: Bundle = {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var bytes = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&bytes, &size) == 0 else { return .main }
        let executable = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app) ?? .main
    }()
    static func localized(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: "Localizable") }
    static let usage = """
    Tivano local control (the app must already be running and manually enabled in Settings > Alpha).
    Commands: info | providers | projects | threads | thread UUID | history UUID
      create --workspace local|worktree --provider ID [--project UUID] [--model ID]
      send UUID --text TEXT [--continuation automatic|fresh|providerSession|transcript]
      send UUID --stdin [--continuation MODE]
      interrupt UUID --turn UUID
      operation INSTANCE/UUID/TIMESTAMP
      settings get | settings set textGeneration automatic|claude|codex|off
      settings set antiSlopEnabled|performanceMode|showsSkylight true|false
    List flags: --limit N --cursor TOKEN
    Thread flags: --archive active|archived|all --role normal|helper|head|all
      --affiliation all|standalone|project|missing_project [--project UUID] [--search TEXT]
    Writes: --operation INSTANCE/UUID/TIMESTAMP reuses an existing ticket in that instance only.
    Save the ticket printed before delivery. A disconnect is not failure; query the ticket instead of repeating the write.
    JSON output reports acceptance, not task success. Expired/restarted outcomes are unknown. No automatic retries or app launch.
    """
}

private struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var stdin = false

    init(_ values: [String]) throws {
        var index = 0
        while index < values.count {
            let value = values[index]
            if value == "--stdin" {
                guard !stdin else { throw ControlFailure(code: .invalidRequest) }
                stdin = true
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
        guard flags.isEmpty, !stdin else { throw ControlFailure(code: .invalidRequest) }
    }
}

private enum CLI {
    static let edition: ControlEdition = {
        #if DEBUG
        .dev
        #else
        .release
        #endif
    }()

    static func run() -> Int32 {
        do {
            let values = Array(CommandLine.arguments.dropFirst())
            if values.isEmpty || values == ["--help"] || values == ["help"] {
                print(CLIText.localized(CLIText.usage))
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
            FileHandle.standardError.write(Data((CLIText.localized("Open the correct edition of Tivano yourself and enable Local control in Settings > Alpha. Use --help for syntax. Never blindly retry a write after a disconnect.") + "\n").utf8))
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
            return .create(ControlCreate(ticket: ticket, projectID: try args.uuid("--project"), workspace: workspace, provider: provider, model: args.take("--model")))
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
            if key == .textGeneration {
                guard let choice = ControlTextGeneration(rawValue: values[2]) else { throw ControlFailure(code: .invalidRequest) }
                value = .textGeneration(choice)
            } else {
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
}

exit(CLI.run())
