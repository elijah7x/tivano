import Foundation

/// Row patches for `dsh --profile acp --patch`.
/// Row ids are dsh internals and can change between versions.
enum DshPatches {
    static func disableOnlyIDs(_ content: String) -> Set<String> {
        var ids = Set<String>()
        var entry: [String] = []
        func finishEntry() {
            guard entry.count == 2, entry[1] == "  disabled: true",
                  entry[0].range(of: #"^- id: \S+$"#, options: .regularExpression) != nil else { return }
            ids.insert(String(entry[0].dropFirst("- id: ".count)))
        }
        for line in content.split(whereSeparator: \.isNewline) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("- ") {
                finishEntry()
                entry = []
            }
            entry.append(String(line))
        }
        finishEntry()
        return ids
    }

    static func enabledDelegationRows(inDump dump: String) -> [String] {
        var rows: [String] = []
        var seen = Set<String>()
        var row: (id: String, indent: String)?
        var name: String?
        var disabled: String?
        func finishRow() {
            guard let row, let name, disabled != "true",
                  name.range(of: #"^@deepseek-ai/dsh-(tool-subagent|tool-workflow|tool-goal|command-goal)([-/].*)?$"#, options: .regularExpression) != nil,
                  seen.insert(row.id).inserted else { return }
            rows.append(row.id)
        }
        for line in dump.split(whereSeparator: \.isNewline) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty || clean.hasPrefix("#") { continue }
            let indent = String(line.prefix(while: { $0.isWhitespace }))
            let isRow = line.range(of: #"^\s*- id: \S+\s*$"#, options: .regularExpression) != nil
            if let current = row, indent.count <= current.indent.count || isRow {
                finishRow()
                row = nil
            }
            if isRow {
                row = (String(clean.dropFirst("- id: ".count)).trimmingCharacters(in: .whitespaces), indent)
                name = nil
                disabled = nil
                continue
            }
            guard let row, indent == row.indent + "  " else { continue }
            if clean.hasPrefix("name:") {
                var value = String(clean.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first,
                   (first == "'" || first == "\""), value.last == first {
                    value = String(value.dropFirst().dropLast())
                }
                name = value
            } else if clean.hasPrefix("disabled:") {
                disabled = String(clean.dropFirst("disabled:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        finishRow()
        return rows
    }

    static let ptc = #"""
    - id: tools
      config:
        mode: ptc
    
    """#

    static let minimal = #"""
    - id: agent-instructions
      disabled: true
    - id: tool-bash
      disabled: true
    - id: tool-pwsh
      disabled: true
    - id: tool-fs
      disabled: true
    - id: tool-fs-search
      disabled: true
    - id: tool-jobs
      disabled: true
    - id: tool-skill
      disabled: true
    - id: command-goal
      disabled: true
    - id: tool-goal
      disabled: true
    - id: plan-mode
      disabled: true
    - id: tool-subagent-control
      disabled: true
    - id: tool-subagent
      disabled: true
    - id: tool-subagent-fork
      disabled: true
    - id: tool-workflow
      disabled: true
    - id: tool-todo
      disabled: true
    - id: tool-web
      disabled: true
    - id: tools
      config:
        mode: native
    - id: system-prompt
      config:
        includeHarnessIdentity: false
        includeRuntimeContext: false
        personaPrefix: You are a helpful software engineer assistant.
    - insert:
        - id: persistent-shell
          name: cordis:group
          group: true
          isolate:
            terminals: true
          config:
            - id: pty
              name: '@deepseek-ai/dsh-terminal'
            - id: terminal-bash
              name: '@deepseek-ai/dsh-terminal-bash'
              disabled: !!js process.platform === 'win32'
              config:
                timeoutMs: 300000
            - id: persistent-bash
              name: '@deepseek-ai/dsh-tool-bash-persistent'
              disabled: !!js process.platform === 'win32'
              config:
                timeoutMs: 300000
                description: |-
                  Run commands in a bash shell
                  * When invoking this tool, the contents of the "command" parameter does NOT need to be XML-escaped.
                  * Network access depends on the task environment. Prefer configured mirrors/proxies when they are available.
                  * State is persistent across command calls and discussions with the user.
                  * To inspect a particular line range of a file, e.g. lines 10-25, try 'sed -n 10,25p /path/to/the/file'.
                  * Please avoid commands that may produce a very large amount of output.
                  * Please run long lived commands in the background, e.g. 'sleep 10 &' or start a server in the background.
            - id: terminal-pwsh
              name: '@deepseek-ai/dsh-terminal-bash'
              disabled: !!js process.platform !== 'win32'
              config:
                shellDialect: pwsh
                timeoutMs: 300000
            - id: persistent-pwsh
              name: '@deepseek-ai/dsh-tool-pwsh-persistent'
              disabled: !!js process.platform !== 'win32'
              config:
                timeoutMs: 300000
                description: |-
                  Run commands in a PowerShell shell
                  * When invoking this tool, the contents of the "command" parameter does NOT need to be XML-escaped.
                  * You don't have access to the internet via this tool.
                  * State is persistent across command calls and discussions with the user.
                  * Use native Windows paths (C:\...) and $env:NAME variables; this is PowerShell, not bash.
                  * Please avoid commands that may produce a very large amount of output.
                  * Please run long lived commands in the background, e.g. 'Start-Job' or start a server with Start-Process.
    
    """#

    // Mirrors dsh-web-app/presets/cordis.patch.yml; ACP also needs the host inspect services.
    /// Rows only some versions have (`working_directory` arrived in 0.2.1).
    /// Disable-only entries for rows a DSH version lacks are skipped generally.
    static let minimalOptional = #"""
    - id: tool-working-directory
      disabled: true
    
    """#

    static let creator = #"""
    - id: tool-plugin-manager
      disabled: false
    - id: skill-filesystem
      config:
        customSkillDirs:
          - !!js process.getBuiltinModule('node:path').join(process.getBuiltinModule('node:path').dirname(process.getBuiltinModule('node:module').createRequire(baseUrl).resolve('@deepseek-ai/dsh-agent-preset/package.json')), 'skills')
    - insert:
        - id: cordis-host-runner
          name: '@deepseek-ai/dsh-cordis-host-runner'
        - id: cordis-inspect-providers
          name: '@deepseek-ai/dsh-tool-cordis/host'
        - id: tool-cordis
          name: '@deepseek-ai/dsh-tool-cordis'
        - id: present
          name: '@deepseek-ai/dsh-tool-present'
    
    """#

    static let noDelegation = #"""
    - id: tool-subagent-control
      disabled: true
    - id: tool-subagent
      disabled: true
    - id: tool-subagent-fork
      disabled: true
    - id: tool-workflow
      disabled: true
    - id: command-goal
      disabled: true
    - id: tool-goal
      disabled: true
    
    """#
}
