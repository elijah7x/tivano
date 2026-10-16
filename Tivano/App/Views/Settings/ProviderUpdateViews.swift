import SwiftUI

/// Presentational CLI update status for one provider. The caller supplies the state
/// and the actions; this view does not check or install anything itself.
struct ProviderUpdateViewState {
    enum Phase {
        case checking
        case current
        case available
        case waiting
        case updating
        case updated
        case failed
    }

    var phase: Phase = .current
    var installed: String?
    var latest: String?
    var command: String?
    var error: String?
    var updateFailed = false
    var monitoringEnabled = true
    var customBinaryPath = false
    var channelKnown = false
}

struct ProviderUpdateSubtitle: View {
    let state: ProviderUpdateViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Text(verbatim: line)
                    .font(.ui(size: 11))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var lines: [String] {
        var status: [String] = []
        if let phaseLine {
            status.append(phaseLine)
        }
        if !state.monitoringEnabled {
            status.append(Chrome.localized("Update monitoring is off."))
        }
        if let protectionLine {
            status.append(protectionLine)
        }
        return status.isEmpty ? [versionLine] : [versionLine, status.joined(separator: " ")]
    }

    /// The installed version, or an explicit unknown. A current result with no latest
    /// version has not confirmed anything, so it never adds "Up to date".
    private var versionLine: String {
        if let installed = providerUpdateText(state.installed) {
            return String(format: Chrome.localized("Version %@"), installed)
        }
        return Chrome.localized("Version unknown")
    }

    private var phaseLine: String? {
        switch state.phase {
        case .checking:
            return Chrome.localized("Checking for updates…")
        case .current:
            guard state.monitoringEnabled else { return nil }
            if let error = providerUpdateText(state.error) { return error }
            guard providerUpdateText(state.latest) != nil else {
                return Chrome.localized("The latest version could not be verified.")
            }
            guard providerUpdateText(state.installed) != nil else { return nil }
            return Chrome.localized("Up to date.")
        case .available:
            return availableLine
        case .waiting:
            return Chrome.localized("Waiting until its active tasks finish.")
        case .updating:
            if let latest = providerUpdateText(state.latest) {
                return String(format: Chrome.localized("Updating to %@…"), latest)
            }
            return Chrome.localized("Updating…")
        case .updated:
            if providerUpdateText(state.installed) != nil {
                return Chrome.localized("Updated.")
            }
            return Chrome.localized("The installed version could not be confirmed after updating.")
        case .failed:
            let error = providerUpdateText(state.error)
            if state.updateFailed {
                if let error {
                    return String(format: Chrome.localized("The update failed: %@"), error)
                }
                return Chrome.localized("The update failed.")
            }
            if let error {
                return String(format: Chrome.localized("The update check failed: %@"), error)
            }
            return Chrome.localized("The update check failed.")
        }
    }

    private var availableLine: String {
        if let latest = providerUpdateText(state.latest) {
            return String(format: Chrome.localized("%@ is available."), latest)
        }
        return Chrome.localized("An update is available.")
    }

    /// A check has not resolved the channel yet; a custom path is already known.
    private var protectionLine: String? {
        if state.customBinaryPath {
            return Chrome.localized("A custom binary path is set, so Tivano will not update it.")
        }
        if state.phase == .checking || state.channelKnown { return nil }
        if providerUpdateText(state.error) != nil { return nil }
        return Chrome.localized("The install channel is unknown, so Tivano will not update it.")
    }

    private var color: Color {
        switch state.phase {
        case .failed:
            return Chrome.danger
        case .updated:
            return providerUpdateText(state.installed) == nil ? Chrome.warning : Chrome.success
        case .available:
            return blocksProviderUpdate(state) ? Chrome.warning : Chrome.accent
        default:
            if state.customBinaryPath { return Chrome.warning }
            if !state.channelKnown, state.phase != .checking { return Chrome.warning }
            return Chrome.secondaryText
        }
    }
}

struct ProviderUpdateAction: View {
    let state: ProviderUpdateViewState
    let onCheck: () -> Void
    let onUpdate: () -> Void

    var body: some View {
        switch choice {
        case .none:
            EmptyView()
        case .update:
            glassButton(
                Chrome.localized("Update"),
                help: commandHelp("Runs %@.", fallback: "Updates this provider's command-line tool."),
                enabled: true,
                action: onUpdate
            )
        case .retryUpdate:
            glassButton(
                Chrome.localized("Retry update"),
                help: commandHelp("Runs %@ again.", fallback: "Runs the update again."),
                enabled: true,
                action: onUpdate
            )
        case .checkAgain:
            glassButton(
                Chrome.localized("Check again"),
                help: Chrome.localized("Checks for updates again. Nothing is installed."),
                enabled: true,
                action: onCheck
            )
        case .waiting:
            glassButton(
                Chrome.localized("Waiting…"),
                help: Chrome.localized("Waiting until its active tasks finish."),
                enabled: false,
                action: {}
            )
        case .updating:
            glassButton(
                Chrome.localized("Updating…"),
                help: commandHelp("Running %@.", fallback: "Updating…"),
                enabled: false,
                action: {}
            )
        }
    }

    private enum Choice {
        case none
        case update
        case retryUpdate
        case checkAgain
        case waiting
        case updating
    }

    private var choice: Choice {
        if !state.monitoringEnabled, state.phase != .waiting, state.phase != .updating { return .none }
        switch state.phase {
        case .current:
            return state.latest == nil && providerUpdateText(state.installed) != nil && !blocksProviderUpdate(state) ? .update : .none
        case .checking, .updated:
            return .none
        case .waiting:
            return .waiting
        case .updating:
            return .updating
        case .available:
            return blocksProviderUpdate(state) ? .checkAgain : .update
        case .failed:
            return blocksProviderUpdate(state) || !state.updateFailed ? .checkAgain : .retryUpdate
        }
    }

    private func commandHelp(_ template: String, fallback: String) -> String {
        guard let command = providerUpdateText(state.command) else { return Chrome.localized(fallback) }
        return String(format: Chrome.localized(template), command)
    }

    @ViewBuilder
    private func glassButton(_ title: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: enabled ? action : {}) {
            Text(verbatim: title)
                .frame(height: Chrome.rowButtonLabelHeight)
        }
        .buttonStyle(.glass)
        .disabled(!enabled)
        .help(Text(verbatim: help))
        .accessibilityLabel(Text(verbatim: title))

        if help == title {
            button
        } else {
            button.accessibilityHint(Text(verbatim: help))
        }
    }
}

struct ProviderUpdateMonitoringRow: View {
    let state: ProviderUpdateViewState
    @Binding var isOn: Bool

    var body: some View {
        ChromeRow(title: "Check for updates", detail: detail) {
            SettingsSwitch(isOn: $isOn)
                .accessibilityLabel(Text(verbatim: Chrome.localized("Check for updates")))
        }
    }

    /// `ChromeRow` looks the detail up again. Format the whole sentence first; the command
    /// stays a value, and a second lookup of that sentence misses and leaves it unchanged.
    private var detail: String {
        if state.customBinaryPath {
            return Chrome.localized("A custom binary path is set, so Tivano will not update it. It still compares the installed version with the newest release every six hours.")
        }
        if !state.channelKnown {
            return Chrome.localized("The install channel is unknown, so Tivano will not update it. It still compares the installed version with the newest release every six hours.")
        }
        if let command = providerUpdateText(state.command) {
            return String(format: Chrome.localized("Updates with %@. Tivano compares the installed version with the newest release every six hours."), command)
        }
        return Chrome.localized("Tivano compares the installed version with the newest release every six hours.")
    }
}

private func providerUpdateText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func blocksProviderUpdate(_ state: ProviderUpdateViewState) -> Bool {
    state.customBinaryPath || !state.channelKnown
}
