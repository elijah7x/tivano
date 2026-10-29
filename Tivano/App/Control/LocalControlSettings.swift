import SwiftUI

struct LocalControlSettingsRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ChromeRow(title: "Local control", detail: "Let a command-line client control this running edition of Tivano. Other processes in your account can use this access. Approvals stay in Tivano. No network listener or automatic app launch.") {
            SettingsSwitch(isOn: $settings.externalControlEnabled)
                .accessibilityLabel(Text("Local control"))
        }
        ChromeRowDivider()
        ChromeRow(title: "Local control status", detail: status) {
            if model.settings.isExternalControlEnabled && !model.localControl.listening {
                ChromeTextButton(symbol: "arrow.clockwise", title: "Retry", help: "Retry local control", isEnabled: true) {
                    model.localControl.refreshListening()
                }
            }
        }
    }

    private var status: String {
        if !model.settings.isExternalControlEnabled { return "Disabled" }
        return model.localControl.listening ? "Listening for this account only" : "Local control could not start. Retry after resolving the socket or permission conflict."
    }
}

/// Installation is deliberately outside the disabled Alpha feature group: the owner
/// can install/remove a command without opening either external-control gate.
struct CLIInstallationSettings: View {
    @Environment(AppModel.self) private var model
    private var edition: ControlEdition { model.localControl.edition }
    private var binDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true) }
    private var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + ControlCLIInstaller.helperName) }

    @State private var status: ControlCLIInstaller.Status = .notInstalled

    var body: some View {
        ChromeCard {
            ChromeRow(title: "CLI command", detail: detail, localizesDetail: false) {
                HStack {
                    ChromeTextButton(symbol: "terminal", title: installTitle, help: installTitle, isEnabled: true) { install() }
                    ChromeTextButton(symbol: "trash", title: "Uninstall CLI", help: "Uninstall CLI", isEnabled: canUninstall, isDestructive: true) { uninstall() }
                }
            }
        }
        .onAppear(perform: refresh)
        // A command removed or replaced in Terminal shows up when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var commandPath: String { "~/.local/bin/" + ControlCLIInstaller.commandName(edition) }

    private var installTitle: String {
        switch status {
        case .notInstalled, .conflict: "Install CLI"
        case .installed: "Reinstall CLI"
        case .needsRepair: "Repair CLI"
        }
    }

    private var canUninstall: Bool {
        (status == .installed || status == .needsRepair) && model.settings.cliInstallationTarget != nil
    }

    /// The current state first, so it is clear at a glance whether the command is there.
    private var detail: String {
        let state = switch status {
        case .notInstalled: Chrome.localized("Not installed.")
        case .installed: String(format: Chrome.localized("Installed at %@."), commandPath)
        case .needsRepair: Chrome.localized("Installed, but it points to an older copy of Tivano. Repair it to use this one.")
        case .conflict: String(format: Chrome.localized("%@ already exists and belongs to another command."), commandPath)
        }
        return state + "\n" + Chrome.localized("Install the command in ~/.local/bin on your request only. Installation never enables local control. Add that directory to PATH yourself if needed; Tivano does not edit shell configuration.")
    }

    private func refresh() {
        status = ControlCLIInstaller.status(directory: binDirectory, helper: helper, name: ControlCLIInstaller.commandName(edition), previousTarget: model.settings.cliInstallationTarget)
    }

    private func install() {
        do {
            try ControlCLIInstaller.install(directory: binDirectory, helper: helper, name: ControlCLIInstaller.commandName(edition), previousTarget: model.settings.cliInstallationTarget)
            model.settings.cliInstallationTarget = helper.path
            refresh()
            model.alert = AppAlert(title: "CLI command installed", message: String(format: Chrome.localized("Command: %@. Local-control permission has not changed."), binDirectory.appendingPathComponent(ControlCLIInstaller.commandName(edition)).path))
        } catch { showFailure(error) }
    }

    private func uninstall() {
        do {
            try ControlCLIInstaller.uninstall(directory: binDirectory, name: ControlCLIInstaller.commandName(edition), previousTarget: model.settings.cliInstallationTarget)
            model.settings.cliInstallationTarget = nil
            refresh()
        } catch { showFailure(error) }
    }

    private func showFailure(_ error: Error) {
        refresh()
        model.alert = AppAlert(title: "Could not change the CLI command", message: (error as? ControlFailure)?.code == .conflict
                              ? "Tivano will not replace or remove another command. Resolve the collision in ~/.local/bin and try again."
                              : "Check the app location and permissions for ~/.local/bin, then try again.")
    }
}
