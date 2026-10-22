// Appended to a copy of the native CLI with only its final entry-point call removed.
// Parsing is exercised directly; ControlClient is never constructed.
extension CLI {
    static func parserChecks() throws {
        let ticket = ControlTicket(instance: UUID())
        let thread = UUID()
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw ControlFailure(code: .internalError, detail: label) }
            count += 1; print("PASS \(label)")
        }
        func parse(_ values: [String]) throws -> ControlCommand {
            var args = try Arguments(values)
            let result = try command(&args, ticket: ticket)
            try args.finished()
            return result
        }
        func rejects(_ values: [String], _ label: String) throws {
            do { _ = try parse(values) } catch let failure as ControlFailure {
                guard [.invalidRequest, .bounds].contains(failure.code) else { throw failure }
                count += 1; print("PASS \(label)"); return
            }
            throw ControlFailure(code: .internalError, detail: label)
        }
        guard case .create(let create) = try parse(["create", "--workspace", "local", "--provider", "codex"]) else { throw ControlFailure(code: .internalError) }
        try check(create.projectID == nil && create.workspace == .local && create.ticket == ticket, "create parser requires explicit scope/provider without cwd inheritance")
        try rejects(["create", "--provider", "codex"], "workspace is mandatory")
        try rejects(["create", "--workspace", "local"], "provider is mandatory")
        guard case .submit(let send) = try parse(["send", thread.uuidString, "--text", "text with spaces", "--continuation", "providerSession"]) else { throw ControlFailure(code: .internalError) }
        try check(send.threadID == thread && send.text == "text with spaces" && send.continuation == .providerSession, "send parser preserves explicit text and exact continuation")
        try rejects(["send", thread.uuidString, "--text", String(repeating: "界", count: LocalControl.maxText / 3 + 1)], "send text has a UTF-8 byte bound")
        try rejects(["send", thread.uuidString], "send requires explicit text or bounded stdin")
        try rejects(["history", thread.uuidString, "--limit", "51"], "history page limit is bounded")
        try rejects(["settings", "set", "externalControlEnabled", "true"], "CLI cannot grant its own permission")
        try rejects(["settings", "set", "alphaEnabled", "true"], "CLI cannot enable Alpha")
        try rejects(["settings", "set", "showsSkylight", "yes"], "boolean settings reject invalid values")
        try rejects(["settings", "set", "textGeneration", "unknown"], "textGeneration rejects invalid enums")
        guard case .settingsSet(let setting) = try parse(["settings", "set", "showsSkylight", "false"]) else { throw ControlFailure(code: .internalError) }
        try check(setting.value == .bool(false), "allowlisted settings use typed values")
        try rejects(["info", "--socket", "/tmp/arbitrary"], "CLI has no arbitrary socket override")
        try rejects(["info", "--stdin"], "stdin is accepted only for text submission")
        try rejects(["providers", "--login", "codex"], "CLI has no provider login surface")
        try rejects(["send", thread.uuidString, "--text", "one", "--text", "two"], "duplicate flags reject")
        try check(ControlTicket(ticket.string) == ticket, "operation tickets round-trip with instance/ID/issuance")
        guard case .operation(let query) = try parse(["operation", ticket.string]) else { throw ControlFailure(code: .internalError) }
        try check(query == ticket, "operation query preserves old instance rather than rewriting ticket")
        guard case .threads(let threads) = try parse(["threads", "--archive", "archived", "--role", "head", "--affiliation", "missing_project", "--search", "metadata"]) else { throw ControlFailure(code: .internalError) }
        try check(threads.archive == .archived && threads.role == .head && threads.affiliation == .missing_project, "thread filters remain typed and explicit")
        #if DEBUG
        try check(edition == .dev, "Dev CLI edition is compiled, not selected by an external flag")
        #else
        try check(edition == .release, "Release CLI edition is compiled, not selected by an external flag")
        #endif
        print("CLI PARSER CHECKS COMPLETE: \(count)")
    }
}

try CLI.parserChecks()
