import AppKit
import SwiftUI

/// The MCP servers: connected and custom servers in rows on top, and an Add a server
/// section below where category and server chips open an inline detail panel to connect.
struct MCPSettingsPage: View {
    let query: String
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Servers flashing their success before they leave Add a server for Connected.
    @State private var celebrating: Set<String> = []
    @State private var selectedCategory: MCPCategory? = nil
    @State private var selectedID: String? = nil
    @State private var isAddingCustom = false

    private static let sortedEntries = MCPCatalog.entries.sorted { $0.name < $1.name }

    private var connected: [MCPCatalogEntry] {
        Self.sortedEntries
            .filter { !celebrating.contains($0.id) && model.mcp.state(for: $0.id).isConnected }
    }

    private var matchingUnconnected: [MCPCatalogEntry] {
        Self.sortedEntries.filter { entry in
            (!model.mcp.state(for: entry.id).isConnected || celebrating.contains(entry.id))
                && Self.matches(entry, query: query)
        }
    }

    var body: some View {
        let connected = connected
        let matchingUnconnected = matchingUnconnected
        let availableCategories = MCPCategory.allCases.filter { category in
            matchingUnconnected.contains { $0.category == category }
        }
        let activeCategory = selectedCategory.flatMap { availableCategories.contains($0) ? $0 : nil }
        let visibleEntries = activeCategory.map { category in
            matchingUnconnected.filter { $0.category == category }
        } ?? matchingUnconnected
        let selectedEntry = selectedID.flatMap { id in visibleEntries.first { $0.id == id } }

        VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
            MCPLeadCard()
            if let error = model.mcp.configurationLoadError {
                ChromeSection(title: "MCP configuration could not be loaded") {
                    ChromeCard {
                        ChromeRow(
                            title: "MCP changes are paused",
                            detail: "Your files and credentials are unchanged. Repair the configuration file, then retry."
                        ) {
                            Button("Retry") { model.mcp.retryConfigurationLoad() }
                                .chromePillButton()
                        }
                        ChromeRowDivider()
                        ChromeRow(title: "Configuration file") {
                            Text(verbatim: String(format: Chrome.localized(error.isReadFailure
                                ? "Could not read MCP configuration at %@."
                                : "Invalid MCP configuration at %@."), error.url.path))
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.danger)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            Group {
                if !connected.isEmpty {
                    ChromeSection(title: "Connected") {
                        ChromeCard {
                            ForEach(Array(connected.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { ChromeRowDivider() }
                                MCPConnectedRow(entry: entry, connection: model.mcp.connection(for: entry.id), state: model.mcp.state(for: entry.id))
                            }
                        }
                    }
                }
                MCPCustomSection(query: query)
                ChromeSection(title: "Add a server") {
                    ChromeCard {
                        VStack(alignment: .leading, spacing: 12) {
                            FlowLayout {
                                categoryChip(title: "All", category: nil, activeCategory: activeCategory)
                                ForEach(availableCategories) { category in
                                    categoryChip(title: category.title, category: category, activeCategory: activeCategory)
                                }
                            }
                            FlowLayout(spacing: 7) {
                                if visibleEntries.isEmpty {
                                    if !query.trimmed.isEmpty {
                                        Text("No servers match your search.")
                                            .font(.ui(.callout))
                                            .foregroundStyle(Chrome.secondaryText)
                                            .padding(.vertical, 5)
                                    }
                                } else {
                                    ForEach(visibleEntries) { entry in
                                        MCPServerChip(
                                            entry: entry,
                                            state: model.mcp.state(for: entry.id),
                                            isSelected: selectedID == entry.id
                                        ) {
                                            let nextID: String? = selectedID == entry.id ? nil : entry.id
                                            if reduceMotion {
                                                selectedID = nextID
                                            } else {
                                                withAnimation(.spring(duration: 0.3)) {
                                                    selectedID = nextID
                                                }
                                            }
                                        }
                                    }
                                }
                                customChip
                            }
                            if let selectedEntry {
                                MCPServerDetailPanel(
                                    entry: selectedEntry,
                                    state: model.mcp.state(for: selectedEntry.id),
                                    celebrating: celebrating.contains(selectedEntry.id)
                                ) {
                                    if reduceMotion {
                                        selectedID = nil
                                    } else {
                                        withAnimation(.spring(duration: 0.3)) {
                                            selectedID = nil
                                        }
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: selectedEntry?.id)
                        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: celebrating)
                    }
                }
            }
            .disabled(!model.mcp.isConfigurationLoaded)
            Text("Connected servers reach every provider except Antigravity when a thread starts: the CLIs at launch, the API models through Tivano itself. Antigravity's CLI only reads its own global MCP settings.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
        }
        .onChange(of: model.mcp.states) { previous, current in
            for (id, state) in current {
                // The moment a catalog server asks for a step on its side, the panel with
                // the steps opens by itself: the user came back from the browser expecting a result.
                if case .needsSetup(let guide) = state {
                    if case .needsSetup = previous[id] {
                        // Already in needsSetup before this state update.
                    } else if let entry = MCPCatalog.entry(id: id) {
                        MCPSetupPanel.shared.present(entry: entry, guide: guide, model: model)
                    }
                }
                if state.isConnected, !(previous[id]?.isConnected ?? false) {
                    if reduceMotion {
                        if selectedID == id {
                            selectedID = nil
                        }
                    } else {
                        celebrating.insert(id)
                        SettleChime.play()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(900))
                            withAnimation(.spring(duration: 0.3)) {
                                celebrating.remove(id)
                                if selectedID == id, model.mcp.state(for: id).isConnected {
                                    selectedID = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func categoryChip(title: String, category: MCPCategory?, activeCategory: MCPCategory?) -> some View {
        let isSelected = activeCategory == category
        return Button {
            let next: MCPCategory? = (category != nil && activeCategory == category) ? nil : category
            if reduceMotion {
                selectedCategory = next
            } else {
                withAnimation(.spring(duration: 0.3)) {
                    selectedCategory = next
                }
            }
        } label: {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.subheadline, weight: .medium))
                .foregroundStyle(isSelected ? Chrome.glassTint : Chrome.secondaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(
                    isSelected ? Chrome.primaryText : Chrome.overlay(0.06),
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var customChip: some View {
        Button {
            isAddingCustom = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(Chrome.inlineIconFont)
                Text("Custom")
                    .font(.ui(.callout, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        Chrome.secondaryText.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isAddingCustom, arrowEdge: .bottom) {
            MCPCustomEditor(server: nil)
                .presentedChrome()
        }
    }

    fileprivate static func matches(_ entry: MCPCatalogEntry, query: String) -> Bool {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return true }
        return entry.name.localizedCaseInsensitiveContains(trimmed)
            || entry.vendor.localizedCaseInsensitiveContains(trimmed)
            || entry.summary.localizedCaseInsensitiveContains(trimmed)
            || entry.id.localizedCaseInsensitiveContains(trimmed)
            || entry.sampleTools.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

private struct MCPLeadCard: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.ui(.body))
                .foregroundStyle(Chrome.accent)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Connected servers take priority")
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("Connect a server here and every chat can use it. Anything set up in a terminal or another app stays just as it is.")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            // The three facts live behind the `i`: stacked in the card they took
            // more room than the point they made.
            MCPHoverInfoButton(label: "About connected servers") {
                VStack(alignment: .leading, spacing: 8) {
                    fact(symbol: "lock.fill", text: "Keys stay in your Keychain")
                    fact(symbol: "arrow.uturn.backward", text: "Disconnect to go back to your own setup")
                    fact(symbol: "sparkles", text: "Every provider except Antigravity, whatever the model")
                }
                .padding(14)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Chrome.primaryText.opacity(0.05))
        )
    }

    private func fact(symbol: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Chrome.accent)
                .frame(width: 14)
            Text(verbatim: Chrome.localized(text))
        }
        .font(.ui(.callout))
        .foregroundStyle(Chrome.primaryText.opacity(0.9))
    }
}

/// A connected server: its icon, name, tool count and version, a switch for
/// handing it to providers, and a menu for refreshing, peeking at tools and leaving.
private struct MCPConnectedRow: View {
    @Environment(AppModel.self) private var model
    let entry: MCPCatalogEntry
    let connection: MCPConnection?
    let state: MCPConnectionState

    @State private var showMenu = false
    @State private var showTools = false

    var body: some View {
        let toolCount: Int = {
            if case .connected(let count) = state { return count }
            return connection?.tools.count ?? 0
        }()
        HStack(spacing: 12) {
            MCPIcon(entry: entry, size: 22)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: String(format: Chrome.localized("%lld tools · %@"), toolCount, connection?.serverVersion ?? entry.vendor))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            Spacer(minLength: 12)
            SettingsSwitch(isOn: Binding(
                get: { connection?.isEnabled ?? true },
                set: { model.mcp.setEnabled($0, for: entry) }
            ))
            Button {
                showMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: Chrome.localized("Server options")))
            .accessibilityLabel(Text(verbatim: Chrome.localized("Server options")))
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                PopoverMenu {
                    PopoverItem("Refresh", symbol: "arrow.clockwise") {
                        model.mcp.refresh(entry)
                    }
                    PopoverItem("Show tools", symbol: "wrench") {
                        showMenu = false
                        showTools = true
                    }
                    PopoverDivider()
                    PopoverItem("Disconnect", symbol: "xmark.circle", isDestructive: true) {
                        model.mcp.disconnect(entry)
                    }
                }
            }
            // On the button, not the row: hung from the row it opened in the row's middle.
            .popover(isPresented: $showTools, arrowEdge: .bottom) {
                toolsPopover
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 11)
    }

    private var toolsPopover: some View {
            PopoverMenu {
                PopoverSectionHeader(String(format: Chrome.localized("%@ tools"), entry.name))
                let tools = connection?.tools ?? []
                if tools.isEmpty {
                    PopoverNote("No tools listed yet.")
                }
                ForEach(tools) { tool in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: tool.name)
                            .font(.ui(.subheadline, design: .monospaced))
                            .foregroundStyle(Chrome.primaryText)
                        if let summary = tool.summary, !summary.isEmpty {
                            Text(verbatim: summary)
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
    }
}

/// One unconnected server chip in Add a server: icon, name and a trailing status indicator
/// when connecting, waiting on setup or failed.
private struct MCPServerChip: View {
    let entry: MCPCatalogEntry
    let state: MCPConnectionState
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                MCPIcon(entry: entry, size: 14)
                Text(verbatim: entry.name)
                    .font(.ui(.callout, weight: .medium))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                statusIndicator
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Chrome.overlay(0.06), in: Capsule(style: .continuous))
            .overlay {
                if isSelected {
                    Capsule(style: .continuous)
                        .strokeBorder(Chrome.accent, lineWidth: 1.5)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .connecting:
            WorkingSpinner(cellSize: 2)
        case .needsSetup:
            Circle()
                .fill(Chrome.warning)
                .frame(width: 6, height: 6)
        case .failed:
            Circle()
                .fill(Chrome.danger)
                .frame(width: 6, height: 6)
        case .notConnected, .connected:
            EmptyView()
        }
    }
}

/// The inline detail panel opened beneath the server chips when one is selected.
private struct MCPServerDetailPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: MCPCatalogEntry
    let state: MCPConnectionState
    let celebrating: Bool
    let onClose: () -> Void

    @State private var showTools = false
    @State private var successPopped = false

    private var toolCount: Int {
        if case .connected(let count) = state { return count }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if celebrating {
                successView
            } else {
                headerRow
                Text(verbatim: Chrome.localized(entry.summary))
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                toolsAndInfoRow
                if showTools, !entry.sampleTools.isEmpty {
                    FlowChips(entry.sampleTools)
                }
                if case .failed(let message) = state {
                    Text(verbatim: message)
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.danger)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .needsSetup(let guide) = state {
                    Text(verbatim: Chrome.localized(guide.title))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.warning)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Chrome.overlay(0.05))
        )
        .onChange(of: entry.id) { _, _ in
            showTools = false
            successPopped = false
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            MCPIcon(entry: entry, size: 24)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: entry.name)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: entry.vendor)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            MCPEntryAction(entry: entry, state: state)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
    }

    private var toolsAndInfoRow: some View {
        HStack(spacing: 6) {
            if !entry.sampleTools.isEmpty {
                Button {
                    if reduceMotion {
                        showTools.toggle()
                    } else {
                        withAnimation(.spring(duration: 0.3)) {
                            showTools.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: Chrome.localized(showTools ? "Hide tools" : "Show tools"))
                            .font(.ui(.subheadline, weight: .medium))
                        Image(systemName: showTools ? "chevron.down" : "chevron.right")
                            .font(Chrome.chevronFont)
                    }
                    .foregroundStyle(Chrome.accent)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            MCPInfoButton(entry: entry)
        }
    }

    private var successView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.ui(size: 34))
                .foregroundStyle(Chrome.success)
                .scaleEffect(successPopped ? 1 : 0.5)
            Text(verbatim: String(format: Chrome.localized("Connected · %lld tools"), toolCount))
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.primaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        .onAppear {
            if reduceMotion {
                successPopped = true
            } else {
                withAnimation(.spring(duration: 0.5, bounce: 0.4)) { successPopped = true }
            }
        }
    }
}

/// The Connect / Sign in / Fix it / Try again control for a catalog server.
private struct MCPEntryAction: View {
    @Environment(AppModel.self) private var model
    let entry: MCPCatalogEntry
    let state: MCPConnectionState

    var body: some View {
        switch state {
        case .notConnected:
            // Sign in for a server that signs in; Connect for the rest. A server that
            // needs a key gets the floating key panel, which opens the page the key is
            // made on and takes the paste (see `MCPKeyPanel`).
            Button(Chrome.localized(entry.isOAuth ? "Sign in" : "Connect")) { begin() }
                .chromePillButton()
        case .connecting:
            HStack(spacing: 6) {
                WorkingSpinner(cellSize: 3)
                Text(verbatim: Chrome.localized(entry.isOAuth ? "Waiting" : "Connecting"))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize()
            }
        case .connected:
            EmptyView()
        case .needsSetup(let guide):
            Button("Finish setup") { MCPSetupPanel.shared.present(entry: entry, guide: guide, model: model) }
                .chromePillButton(.regular, prominent: true)
        case .failed:
            Button(Chrome.localized(entry.isOAuth ? "Sign in again" : "Try again")) { begin() }
                .chromePillButton()
        }
    }

    private func begin() {
        guard model.mcp.isConfigurationLoaded else { return }
        if !entry.needsInput {
            model.mcp.connect(entry)
        } else {
            MCPKeyPanel.shared.present(entry: entry, model: model)
        }
    }
}

/// The user's own servers, between Connected and Add a server: one row each (state, switch
/// and menu like a connected row, a Connect button like the detail panel's). Hidden when
/// the user has none or a search matches none of them.
private struct MCPCustomSection: View {
    @Environment(AppModel.self) private var model
    let query: String

    private var visible: [MCPCustomServer] {
        guard !query.trimmed.isEmpty else { return model.mcp.customs }
        return model.mcp.customs.filter { MCPSettingsPage.matches($0.catalogEntry(), query: query) }
    }

    var body: some View {
        let visible = visible
        if !visible.isEmpty {
            ChromeSection(title: "Custom") {
                ChromeCard {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { ChromeRowDivider() }
                        MCPCustomRow(server: server, state: model.mcp.state(for: server.id), connection: model.mcp.connection(for: server.id))
                    }
                }
            }
        }
    }
}

/// One of the user's own servers: the connected row's shape (icon, name, state, a switch
/// once connected) plus the Connect button a catalog card has, and a menu for editing,
/// disconnecting and deleting.
private struct MCPCustomRow: View {
    @Environment(AppModel.self) private var model
    let server: MCPCustomServer
    private let entry: MCPCatalogEntry
    let state: MCPConnectionState
    let connection: MCPConnection?

    @State private var showMenu = false
    @State private var isEditing = false

    init(server: MCPCustomServer, state: MCPConnectionState, connection: MCPConnection?) {
        self.server = server
        entry = server.catalogEntry()
        self.state = state
        self.connection = connection
    }


    private var toolCount: Int {
        if case .connected(let count) = state { return count }
        return connection?.tools.count ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            MCPIcon(entry: entry, size: 22)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: server.name)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                statusLine
            }
            Spacer(minLength: 12)
            action
            menuButton
        }
        .padding(.leading, 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .connected:
            Text(verbatim: String(format: Chrome.localized("%lld tools · %@"), toolCount, connection?.serverVersion ?? entry.vendor))
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
        case .failed(let message):
            Text(verbatim: message)
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.danger)
                .lineLimit(3)
        default:
            Text(verbatim: server.summary)
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .notConnected:
            Button("Connect") { begin() }
                .chromePillButton()
        case .connecting:
            HStack(spacing: 6) {
                WorkingSpinner(cellSize: 3)
                Text("Connecting")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize()
            }
        case .connected:
            SettingsSwitch(isOn: Binding(
                get: { connection?.isEnabled ?? true },
                set: { model.mcp.setEnabled($0, for: entry) }
            ))
        case .needsSetup(let guide):
            Button("Finish setup") { MCPSetupPanel.shared.present(entry: entry, guide: guide, model: model) }
                .chromePillButton(.regular, prominent: true)
        case .failed:
            Button("Try again") { begin() }
                .chromePillButton()
        }
    }

    /// The card's connect, unchanged: no fields needed connects at once, otherwise the
    /// key panel takes the variable values.
    private func begin() {
        guard model.mcp.isConfigurationLoaded else { return }
        if !entry.needsInput {
            model.mcp.connect(entry)
        } else {
            MCPKeyPanel.shared.present(entry: entry, model: model)
        }
    }

    private var menuButton: some View {
        Button {
            showMenu.toggle()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.ui(.body))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: Chrome.localized("Server options")))
        .accessibilityLabel(Text(verbatim: Chrome.localized("Server options")))
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            PopoverMenu {
                PopoverItem("Edit", symbol: "pencil") {
                    showMenu = false
                    isEditing = true
                }
                PopoverItem("Disconnect", symbol: "xmark.circle", isEnabled: state.isConnected, isDestructive: true) {
                    model.mcp.disconnect(entry)
                }
                PopoverDivider()
                PopoverItem("Delete", symbol: "trash", isDestructive: true) {
                    model.mcp.deleteCustom(server)
                }
            }
        }
        // On the button, not the row: hung from the row it opened in the row's middle.
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            MCPCustomEditor(server: server)
                .presentedChrome()
        }
    }
}

/// The add/edit popover for a custom server: its name, kind, and how it runs, then the
/// *names* of the variables it needs — never their values. Values are typed on connect,
/// through the same key panel a catalog server's fields use (see `MCPKeyPanel`), or
/// edited here, where a locked one never leaves a secure field.
private struct MCPCustomEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil when adding; the server being edited otherwise.
    let server: MCPCustomServer?

    @State private var name: String
    @State private var kind: MCPCustomServer.Kind
    @State private var command: String
    @State private var argsText: String
    @State private var url: String
    @State private var variables: [VariableDraft]
    @State private var error: String?
    @State private var savedID: String?
    /// Focus lands on the name only when adding: in an edit it would read as a prompt
    /// to rename (the same call `HydraPairEditor` makes).
    @FocusState private var isNameFocused: Bool

    /// A variable row being typed. Its identity is a UUID, not the key: the key changes
    /// with every keystroke, which would throw the row out of the list mid-edit.
    private struct VariableDraft: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
        var isSecret = false

        init() {}
        init(_ variable: MCPCustomServer.Variable) {
            key = variable.key
            isSecret = variable.isSecret
        }
    }

    init(server: MCPCustomServer?) {
        self.server = server
        _name = State(initialValue: server?.name ?? "")
        _kind = State(initialValue: server?.kind ?? .stdio)
        _command = State(initialValue: server?.command ?? "")
        _argsText = State(initialValue: (server?.args ?? []).joined(separator: "\n"))
        _url = State(initialValue: server?.url ?? "")
        _variables = State(initialValue: (server?.variables ?? []).map(VariableDraft.init))
    }

    private static let width: CGFloat = 380
    private static let sectionSpacing: CGFloat = 12
    private static let outerPadding: CGFloat = 16
    private static let variableRowHeight: CGFloat = 34
    // Custom icons depend only on the empty asset, not the fields being edited.
    private static let iconEntry = MCPCustomServer(id: "", name: "", kind: .stdio).catalogEntry()
    private static let kindOptions: [(MCPCustomServer.Kind, String)] = [
        (.stdio, "stdio — a command on this Mac"), (.http, "http — a remote server")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    nameField
                    field("Kind") {
                        GlassPickerButton(
                            options: Self.kindOptions,
                            selection: $kind,
                            symbol: { $0 == .stdio ? "terminal" : "network" }
                        )
                    }
                    if kind == .stdio {
                        field("Command") {
                            editorField("npx", text: $command)
                        }
                        argsEditor
                        variablesSection(title: "Environment", addLabel: "Add environment variable")
                    } else {
                        field("URL") {
                            editorField("https://…", text: $url)
                        }
                        variablesSection(title: "Headers", addLabel: "Add header")
                    }
                }
            }
            footer
        }
        .padding(Self.outerPadding)
        // The height follows the form: the arguments editor and each variable row claim
        // their space, header and save stay put, and the form scrolls inside rather than
        // stretching the popover off the screen (the lesson of the pair editor).
        .frame(width: Self.width, height: height)
        .disabled(!model.mcp.isConfigurationLoaded)
        .onAppear {
            if server == nil {
                isNameFocused = true
            } else if let id = server?.id {
                // Editing starts from the stored values: the Keychain's for locked
                // variables, the connection's for the rest.
                for index in variables.indices {
                    let variable = variables[index]
                    if let stored = model.mcp.storedValue(server: id, field: variable.key, secret: variable.isSecret) {
                        variables[index].value = stored
                    }
                }
            }
        }
    }

    /// A bounded height responsive to the transport and the variable rows: roughly 450
    /// points for an empty stdio form, 320 for an empty http one, each row adding its
    /// field, and 560 the most the popover ever takes.
    private var height: CGFloat {
        let base: CGFloat = kind == .stdio ? 450 : 320
        return min(560, base + CGFloat(variables.count) * Self.variableRowHeight)
    }

    /// Error and save live below the scroll view: they never scroll out of reach, and
    /// the fields above them never sit in a tall empty panel.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Text(verbatim: error)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button(Chrome.localized(server == nil ? "Add server" : "Save")) { save() }
                    .chromePillButton(.regular, prominent: true)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            MCPIcon(entry: Self.iconEntry, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: server?.name ?? Chrome.localized("New server"))
                    .font(.ui(size: 14, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: String(format: Chrome.localized("Custom · %@"), kind == .stdio ? "stdio" : "http"))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
    }

    private var nameField: some View {
        field("Name") {
            TextField("My server", text: $name)
                .textFieldStyle(.plain)
                .focused($isNameFocused)
                .focusEffectDisabled()
                .font(.ui(.title3, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .mcpFieldSurface()
        }
    }

    /// A labeled editor row, the key panel's field shape: small caps-ish label over the control.
    private func field<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: Chrome.localized(label))
                .font(.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
            control()
        }
    }

    private func editorField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.ui(.callout, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .mcpFieldSurface()
    }

    /// The secret value's field, dressed like `editorField`.
    private func secureEditorField(_ prompt: String, text: Binding<String>) -> some View {
        SecureField(prompt, text: text)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.ui(.callout, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .mcpFieldSurface()
    }

    private var argsEditor: some View {
        field("Arguments") {
            // The editor carries an inset of its own, so it needs less padding than the
            // single-line fields to put its text on the same edge.
            TextEditor(text: $argsText)
                .font(.ui(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(height: 66)
                .mcpFieldSurface()
            Text("One argument per line; empty lines are dropped.")
                .font(.ui(size: 10.5))
                .foregroundStyle(Chrome.secondaryText)
        }
    }

    private func variablesSection(title: String, addLabel: String) -> some View {
        field(title) {
            ForEach(variables) { variable in
                let binding = variableBinding(for: variable)
                HStack(spacing: 6) {
                    editorField("Variable name", text: binding.key)
                    if variable.isSecret {
                        secureEditorField("value", text: binding.value)
                    } else {
                        editorField("value", text: binding.value)
                    }
                    Button {
                        binding.wrappedValue.isSecret.toggle()
                    } label: {
                        Image(systemName: variable.isSecret ? "lock.fill" : "lock.open")
                            .font(.ui(.callout, weight: .medium))
                            .foregroundStyle(variable.isSecret ? Chrome.accent : Chrome.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: Chrome.localized(variable.isSecret ? "Kept in the Keychain" : "Stored in mcp.json; click to keep it in the Keychain instead")))
                    .accessibilityLabel(Text(verbatim: Chrome.localized(variable.isSecret ? "Kept in the Keychain" : "Stored in mcp.json; click to keep it in the Keychain instead")))
                    Button {
                        let id = variable.id
                        variables.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.ui(.callout, weight: .medium))
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: Chrome.localized("Remove this variable")))
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Remove this variable")))
                }
            }
            Button {
                variables.append(VariableDraft())
            } label: {
                Label { Text(verbatim: Chrome.localized(addLabel)) } icon: { Image(systemName: "plus") }
                    .font(.ui(.callout, weight: .medium))
                    .foregroundStyle(Chrome.accent)
            }
            .buttonStyle(.plain)
            Text("Locked values are kept in the Keychain.")
                .font(.ui(size: 10.5))
                .foregroundStyle(Chrome.secondaryText)
        }
    }

    private func variableBinding(for variable: VariableDraft) -> Binding<VariableDraft> {
        let id = variable.id
        return Binding(
            get: { variables.first(where: { $0.id == id }) ?? variable },
            set: { newVariable in
                guard let index = variables.firstIndex(where: { $0.id == id }) else { return }
                variables[index] = newVariable
            }
        )
    }

    /// The draft as a server for saving. Rows whose key was
    /// never filled are left out rather than failing validation on an empty key, and the
    /// variable list survives a kind switch: keys typed as env vars read fine as headers.
    private var draft: MCPCustomServer {
        let kept = variables
            .map { MCPCustomServer.Variable(key: $0.key.trimmingCharacters(in: .whitespaces), isSecret: $0.isSecret) }
            .filter { !$0.key.isEmpty }
        var draft = MCPCustomServer(id: server?.id ?? savedID ?? MCPCustomServer.makeID(name), name: name, kind: kind)
        draft.command = command.trimmed
        // One argument per line: an argument with spaces survives this way, and nothing
        // trims it, so a leading dash or an embedded quote reaches the server as typed.
        draft.args = argsText
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        draft.url = url.trimmed
        switch kind {
        case .stdio: draft.env = kept
        case .http: draft.headers = kept
        }
        return draft
    }

    private func save() {
        guard model.mcp.isConfigurationLoaded else {
            error = Chrome.localized("MCP configuration could not be loaded. Repair the file and retry in Settings before making changes.")
            return
        }
        let draft = draft
        let wasConnected = server.map { model.mcp.state(for: $0.id).isConnected } ?? false
        if let failure = model.mcp.saveCustom(draft, replacing: server?.id ?? savedID) {
            error = failure.message
            return
        }
        savedID = draft.id
        // The values go where `connect` would put them, so connecting later is only the
        // probe: plain ones to mcp.json, locked ones to the Keychain. Keys trim and
        // empty-key rows drop exactly as `draft` keeps them, and a variable that changed
        // lock keeps its stored value (see `saveCustomValues`).
        let keptValues = variables
            .map { (key: $0.key.trimmingCharacters(in: .whitespaces), value: $0.value, isSecret: $0.isSecret) }
            .filter { !$0.key.isEmpty }
        guard model.mcp.saveCustomValues(keptValues, for: draft.id, replacingFieldsOf: server?.catalogEntry()) else {
            error = Chrome.localized("The Keychain could not save a value. Keep this editor open and try again.")
            return
        }
        // An edit that changed a connected server's command, address or variables takes
        // effect on the next probe; `saveCustom` dropped it from the providers meanwhile.
        if wasConnected, let entry = model.mcp.entry(for: draft.id) {
            model.mcp.refresh(entry)
        }
        dismiss()
    }
}

/// The inset surface every field in the custom-server editor sits on: the fill, radius
/// and edge padding of `HydraPairEditor`'s name field, so the two popovers read alike.
private extension View {
    func mcpFieldSurface() -> some View {
        background(Chrome.overlay(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// The small `i` in a card's corner: hovering it opens the server's details, and so does a
/// click. The popover stays while the pointer is on it, so its docs link can be reached.
private struct MCPInfoButton: View {
    let entry: MCPCatalogEntry

    var body: some View {
        MCPHoverInfoButton(label: String(format: Chrome.localized("About %@"), entry.name)) {
            MCPInfoPopover(entry: entry)
        }
    }
}

/// An `i` that opens `content` in a popover on hover or click, and keeps it open while
/// the pointer is on either the button or the popover.
private struct MCPHoverInfoButton<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    @State private var isPresented = false
    @State private var isOverButton = false
    @State private var isOverPopover = false
    @State private var settle: Task<Void, Never>?

    var body: some View {
        Button {
            settle?.cancel()
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.secondaryText.opacity(isOverButton || isPresented ? 1 : 0.55))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(Text(verbatim: Chrome.localized(label)))
        .onHover { over in
            if isOverButton != over { isOverButton = over }
            reconsider()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content
                .onHover { over in
                    if isOverPopover != over { isOverPopover = over }
                    reconsider()
                }
                .presentedChrome()
        }
    }

    /// Opens a beat after the pointer arrives, closes a beat after it has left both the
    /// button and the popover: the gap between the two is crossed without it closing.
    private func reconsider() {
        settle?.cancel()
        let wanted = isOverButton || isOverPopover
        guard wanted != isPresented else { return }
        settle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(wanted ? 220 : 320))
            guard !Task.isCancelled, (isOverButton || isOverPopover) == wanted else { return }
            isPresented = wanted
        }
    }
}

/// A server's details: what it is, how it connects, what it needs, the tools it brings,
/// and where its docs are.
private struct MCPInfoPopover: View {
    let entry: MCPCatalogEntry
    @Environment(AppModel.self) private var model

    private static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                MCPIcon(entry: entry, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.name)
                        .font(.ui(size: 14, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                    Text(verbatim: "\(entry.vendor) · \(Chrome.localized(entry.category.title))")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            Text(verbatim: Chrome.localized(entry.summary))
                .font(.ui(.callout))
                .foregroundStyle(Chrome.primaryText.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                detail("Connects", connection)
                detail("Needs", needs)
            }
            if !entry.sampleTools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tools")
                        .font(.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                    FlowChips(entry.sampleTools)
                }
            }
            if let optional = entry.fields.first(where: { !$0.isRequired }) {
                Button(String(format: Chrome.localized("Change the %@…"), Chrome.localizedLowercased(optional.label))) {
                    MCPKeyPanel.shared.present(entry: entry, model: model)
                }
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.accent)
                .buttonStyle(.plain)
            }
            if let url = URL(string: entry.docsURL) {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text("Read the docs")
                        Image(systemName: "arrow.up.right")
                            .font(.ui(.caption2, weight: .bold))
                    }
                    .font(.ui(.callout, weight: .medium))
                    .foregroundStyle(Chrome.accent)
                }
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: Chrome.localized(label))
                .font(.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 58, alignment: .leading)
            Text(verbatim: value)
                .font(.ui(size: 11.5))
                .foregroundStyle(Chrome.primaryText.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connection: String {
        switch entry.transport {
        case .stdio(let command, let args):
            let package = args.first { !$0.hasPrefix("-") } ?? command
            return String(format: Chrome.localized("Runs on this Mac through %@ (%@)."), command, package)
        case .http(let url, _):
            return String(format: Chrome.localized("Remote server at %@."), Self.host(of: url))
        case .oauth(let url):
            return String(format: Chrome.localized("Remote server at %@. You sign in once in your browser."), Self.host(of: entry.fill(url, values: [:])))
        }
    }

    private var needs: String {
        let required = entry.fields.filter(\.isRequired).map { Chrome.localized($0.label) }
        let optional = entry.fields.filter { !$0.isRequired }.map { Chrome.localizedLowercased($0.label) }
        if required.isEmpty && optional.isEmpty {
            return Chrome.localized(entry.isOAuth ? "Only your sign-in." : "Nothing — press Connect.")
        }
        var parts = required
        if !optional.isEmpty { parts.append(String(format: Chrome.localized("optional: %@"), optional.joined(separator: Chrome.localized(", ")))) }
        return parts.joined(separator: Chrome.localized("; ")) + Chrome.localized(".")
    }

    private static func host(of url: String) -> String {
        URL(string: url)?.host() ?? url
    }
}

/// Monospaced chips wrapping onto as many lines as they need.
private struct FlowChips: View {
    let items: [String]

    init(_ items: [String]) { self.items = items }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(verbatim: item)
                    .font(.ui(size: 10.5, design: .monospaced))
                    .foregroundStyle(Chrome.primaryText.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Chrome.overlay(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

/// Rows of subviews, each as wide as it needs, wrapping at the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct MCPIcon: View {
    let entry: MCPCatalogEntry
    var size: CGFloat = 20

    var body: some View {
        image
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(entry.asset.isEmpty || entry.isMonochrome ? Chrome.primaryText : entry.color)
            .frame(width: size, height: size)
    }

    /// A custom server has no asset of its own (`asset == ""`): a symbol stands in for it.
    private var image: Image {
        entry.asset.isEmpty ? Image(systemName: "server.rack") : Image(entry.asset)
    }
}
