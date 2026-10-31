import AppKit
import SwiftTerm

/// A shell running in a pseudo terminal, kept alive while its thread is open.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let threadID: UUID
    let directory: String
    var title: String
    private(set) var isRunning = true
    /// The shell's file name, to tell it from a program it was replaced by with `exec`.
    let shellName: String

    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private var bridge: TerminalBridge?

    init(threadID: UUID, directory: String, title: String, command: String?) {
        self.threadID = threadID
        self.directory = directory
        self.title = title
        shellName = (LoginEnvironment.userShell() as NSString).lastPathComponent
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        view.font = TerminalFont.preferred()
        view.optionAsMetaKey = true
        let bridge = TerminalBridge(session: self)
        self.bridge = bridge
        view.processDelegate = bridge

        let shell = LoginEnvironment.userShell()
        var environment = LoginEnvironment.current
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Tivano"
        environment["TIVANO_PROJECT_ROOT"] = directory
        let pairs = environment.map { "\($0.key)=\($0.value)" }
        let execName = "-" + shellName
        var arguments: [String] = []
        if let command {
            arguments = ["-l", "-i", "-c", "\(command); exec \(shell) -l"]
        }
        view.startProcess(executable: shell, args: arguments, environment: pairs, execName: execName, currentDirectory: directory)
    }

    /// The appearance last applied: setting the colours again clears SwiftTerm's attribute
    /// caches and redraws the whole screen, so the host applies them only on a change.
    private var appliedDark: Bool?

    func applyAppearance(isDark: Bool) {
        guard appliedDark != isDark else { return }
        appliedDark = isDark
        view.nativeBackgroundColor = isDark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.985, alpha: 1)
        view.nativeForegroundColor = isDark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        // The caret and the selection follow the theme's accent, like every other
        // insertion point in the app.
        let accent = Chrome.accentNSColor
        view.caretColor = accent
        view.selectedTextBackgroundColor = accent.withAlphaComponent(0.3)
    }

    func terminate() {
        guard isRunning else { return }
        view.terminate()
        isRunning = false
    }

    /// Whether the shell owns the foreground of its terminal: true at the prompt, false while
    /// a job it started (vim, claude, less) has the terminal. Read from the kernel's view of
    /// the shell, since the pty's master side answers no `tcgetpgrp` to a process it is not
    /// the controlling terminal of.
    nonisolated static func foregroundJobIsTheShell(_ shell: pid_t) -> Bool {
        guard shell > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, shell]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_tpgid == info.kp_eproc.e_pgid
    }

    /// Whether something other than the shell's prompt holds the terminal: a job in its own
    /// group, a command the shell runs in its group (job control off), or a program the shell
    /// was replaced by with `exec`. Unlike foregroundJobIsTheShell, a failed read means not
    /// busy, so a vanished shell never holds an update back.
    nonisolated static func foregroundJobIsRunning(_ shell: pid_t, shellName: String) -> Bool {
        guard shell > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, shell]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        let foreground = info.kp_eproc.e_tpgid
        guard foreground > 0 else { return false }
        if foreground != info.kp_eproc.e_pgid { return true }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !command.isEmpty, !shellName.hasPrefix(command) { return true }
        return processes(inGroup: foreground).contains { $0 != shell }
    }

    nonisolated static func jobIsRunning(_ shell: pid_t, shellName: String) -> Bool {
        guard shell > 0 else { return false }
        if foregroundJobIsRunning(shell, shellName: shellName) { return true }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return true }
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 4)
        size = list.count * MemoryLayout<kinfo_proc>.stride
        // A failed snapshot cannot establish that it is safe to quit.
        guard sysctl(&name, 4, &list, &size, nil, 0) == 0 else { return true }
        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).contains {
            $0.kp_eproc.e_ppid == shell && $0.kp_proc.p_pid != shell
        }
    }

    nonisolated private static func processes(inGroup group: pid_t) -> [pid_t] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 4)
        size = list.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid)
    }

    fileprivate func processEnded() {
        isRunning = false
    }
}

/// Receives SwiftTerm callbacks, which arrive on the main thread.
private final class TerminalBridge: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: TerminalSession?

    init(session: TerminalSession) {
        self.session = session
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let session = self.session
        Task { @MainActor in session?.processEnded() }
    }
}

@MainActor
@Observable
final class TerminalStore {
    private(set) var sessions: [UUID: [TerminalSession]] = [:]
    var selection: [UUID: UUID] = [:]

    /// Whether a foreground job currently owns a terminal.
    var hasForegroundJob: Bool {
        sessions.values.contains { list in
            list.contains { session in
                session.isRunning && TerminalSession.foregroundJobIsRunning(session.view.process.shellPid, shellName: session.shellName)
            }
        }
    }

    /// Background jobs also need to finish before an update can quit their shell.
    var hasRunningJob: Bool {
        sessions.values.contains { list in
            list.contains { session in
                session.isRunning && TerminalSession.jobIsRunning(session.view.process.shellPid, shellName: session.shellName)
            }
        }
    }

    func sessions(for threadID: UUID) -> [TerminalSession] {
        sessions[threadID] ?? []
    }

    func selected(for threadID: UUID) -> TerminalSession? {
        let list = sessions(for: threadID)
        return list.first { $0.id == selection[threadID] } ?? list.last
    }

    @discardableResult
    func open(threadID: UUID, directory: String, title: String? = nil, command: String? = nil) -> TerminalSession {
        let number = sessions(for: threadID).count + 1
        let session = TerminalSession(threadID: threadID, directory: directory, title: title ?? String(format: Chrome.localized("Terminal %lld"), number), command: command)
        sessions[threadID, default: []].append(session)
        selection[threadID] = session.id
        return session
    }

    func run(_ script: ProjectScript, threadID: UUID, directory: String) {
        open(threadID: threadID, directory: directory, title: script.name, command: script.command)
    }

    func ensureTerminal(threadID: UUID, directory: String) {
        if sessions(for: threadID).isEmpty {
            open(threadID: threadID, directory: directory)
        }
    }

    /// Replaces an exited shell with a fresh one in the same place in the row, keeping the
    /// tab's name and its directory, so a shell that quit is one click from working again.
    @discardableResult
    func restart(_ session: TerminalSession) -> TerminalSession {
        session.terminate()
        let fresh = TerminalSession(
            threadID: session.threadID,
            directory: session.directory,
            title: session.title,
            command: nil
        )
        if let index = sessions[session.threadID]?.firstIndex(where: { $0.id == session.id }) {
            sessions[session.threadID]?[index] = fresh
        } else {
            sessions[session.threadID, default: []].append(fresh)
        }
        selection[session.threadID] = fresh.id
        return fresh
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        sessions[session.threadID]?.removeAll { $0.id == session.id }
        if selection[session.threadID] == session.id {
            selection[session.threadID] = sessions[session.threadID]?.last?.id
        }
    }

    func closeAll(for threadID: UUID) {
        for session in sessions(for: threadID) { session.terminate() }
        sessions[threadID] = nil
        selection[threadID] = nil
    }

    func terminateAll() {
        for list in sessions.values {
            for session in list { session.terminate() }
        }
    }
}
