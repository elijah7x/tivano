import AppKit
import SwiftUI

/// The floating panel a user pastes an MCP key into. Opens the entry's `keysURL`
/// in the browser as it appears, so the key page sits beside the panel.
@MainActor
final class MCPKeyPanel: FloatingGuidePanel {
    static let shared = MCPKeyPanel()

    private init() { super.init(width: 380) }

    func present(entry: MCPCatalogEntry, model: AppModel) {
        if let keysURL = entry.keysURL, let url = URL(string: keysURL) {
            NSWorkspace.shared.open(url)
        }
        let content = MCPKeyPanelView(entry: entry, model: model) { [weak self] in self?.close() }
            .presentedChrome()
            .environment(model)
        present(content)
    }
}

/// The panel's content: numbered steps, one field per entry field, and Save.
struct MCPKeyPanelView: View {
    let entry: MCPCatalogEntry
    let model: AppModel
    let onDone: @MainActor () -> Void

    @FocusState private var focusedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            steps
            ForEach(entry.fields) { field in
                fieldView(field)
            }
            HStack {
                Spacer()
                Button(Chrome.localized(entry.isOAuth ? "Sign in" : "Save and connect")) {
                    save()
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.mcp.canConnect(entry))
            }
        }
        .padding(18)
        .frame(width: 380)
        // The key page opens in the browser as the panel appears, and the panel has to be
        // movable off it: a press anywhere the fields and buttons do not claim drags the
        // panel, as it does in the setup guide's panel.
        .background {
            WindowDragArea()
        }
        .background {
            WindowBackdrop(opacity: 0.5)
        }
        .onAppear { focusedField = entry.fields.first?.key }
        .onSubmit { if model.mcp.canConnect(entry) { save() } }
        .onChange(of: model.mcp.state(for: entry.id).isConnected) { _, isConnected in
            if isConnected { onDone() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            MCPIcon(entry: entry, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.name)
                    .font(.ui(size: 14, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                Text("Connect")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            Spacer(minLength: 8)
            Button {
                onDone()
            } label: {
                Image(systemName: "xmark")
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: Chrome.localized("Close")))
        }
    }

    @ViewBuilder
    private var steps: some View {
        if let keysURL = entry.keysURL, let url = URL(string: keysURL) {
            VStack(alignment: .leading, spacing: 6) {
                stepRow(1, text: Text("The page is open in your browser"), accessory: AnyView(
                    Link("Open it again", destination: url).font(.ui(.subheadline))
                ))
                stepRow(2, text: Text(verbatim: String(format: Chrome.localized("Copy the %@"), entry.fields.first.map { Chrome.localizedLowercased($0.label) } ?? Chrome.localized("key"))))
                stepRow(3, text: Text("Paste it below and save"))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                stepRow(1, text: Text(verbatim: String(format: Chrome.localized("Enter the %@"), entry.fields.first.map { Chrome.localizedLowercased($0.label) } ?? Chrome.localized("value"))))
                stepRow(2, text: Text(verbatim: Chrome.localized(entry.isOAuth ? "Sign in in your browser" : "Save")))
            }
        }
    }

    private func stepRow(_ number: Int, text: Text, accessory: AnyView? = nil) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Chrome.accent.opacity(0.18))
                    .frame(width: 18, height: 18)
                Text(verbatim: "\(number)")
                    .font(.ui(.footnote, weight: .semibold))
                    .foregroundStyle(Chrome.accent)
            }
            HStack(spacing: 4) {
                text
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.primaryText)
                if let accessory { accessory }
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: MCPField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: Chrome.localized(field.label))
                .font(.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
            HStack(spacing: 6) {
                Group {
                    switch field.kind {
                    case .secret:
                        SecureField(field.placeholder, text: draftBinding(field))
                    case .text, .path:
                        TextField(field.placeholder, text: draftBinding(field))
                    }
                }
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.ui(.callout, design: .monospaced))
                .focused($focusedField, equals: field.key)
                if field.kind == .path {
                    Button {
                        pickPath(for: field)
                    } label: {
                        Image(systemName: "folder")
                            .font(.ui(.callout))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Choose a file or folder")))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Chrome.overlay(0.06))
            }
            if let help = field.help, !help.isEmpty {
                Text(verbatim: Chrome.localized(help))
                    .font(.ui(size: 10.5))
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
    }

    private func draftBinding(_ field: MCPField) -> Binding<String> {
        Binding(
            get: { model.mcp.value(for: field, of: entry) },
            set: { model.mcp.setDraft($0, for: field, of: entry) }
        )
    }

    private func pickPath(for field: MCPField) {
        let open = NSOpenPanel()
        if entry.id == "filesystem" {
            open.canChooseDirectories = true
            open.canChooseFiles = false
        } else {
            open.canChooseDirectories = false
            open.canChooseFiles = true
        }
        open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let url = open.url else { return }
        model.mcp.setDraft(url.path, for: field, of: entry)
    }

    private func save() {
        model.mcp.connect(entry)
        onDone()
    }
}
