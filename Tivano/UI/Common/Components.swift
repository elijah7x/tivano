import AppKit
import SwiftUI

struct ProviderIcon: View {
    let provider: ProviderKind
    var size: CGFloat = 14

    var body: some View {
        Image(provider.iconName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .scaleEffect(provider == .kimi ? 0.92 : 1)
    }
}

enum RelativeTime {
    /// Dates older than a week by their formatted day: every sidebar row past that age
    /// asked ICU again on each evaluation of the list.
    @MainActor private static var days = RecentCache<Date, String>(limit: 256)

    @MainActor
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return Chrome.localized("now")
        case ..<3_600: return String(format: Chrome.localized("%lldm"), Int(seconds / 60))
        case ..<86_400: return String(format: Chrome.localized("%lldh"), Int(seconds / 3_600))
        case ..<604_800: return String(format: Chrome.localized("%lldd"), Int(seconds / 86_400))
        default:
            if let day = days.value(for: date) { return day }
            let day = date.formatted(.dateTime.month(.abbreviated).day())
            days.insert(day, for: date)
            return day
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        Duration.seconds(max(0, Int(interval.rounded())))
            .formatted(.units(allowed: [.seconds, .minutes, .hours], width: .narrow, maximumUnitCount: 2, fractionalPart: .hide(rounded: .down)))
    }
}

struct DiffStatLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Chrome.success)
            Text("−\(deletions)").foregroundStyle(Chrome.danger)
        }
        .font(.ui(.caption).monospacedDigit())
    }
}

/// A compact, borderless control used inside glass surfaces, where nested glass would muddy the material.
struct ChipButtonStyle: ButtonStyle {
    var isActive = false
    /// A lone glyph: a round chip the size of the composer's other icon buttons, where
    /// the text chip's padding would stretch it into an oval.
    var isIcon = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, isActive: isActive, isIcon: isIcon)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let isActive: Bool
        let isIcon: Bool
        @State private var isHovering = false

        var body: some View {
            label
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background {
                    Capsule().fill(fill)
                }
                .contentShape(.capsule)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var fill: AnyShapeStyle {
            if isActive { return AnyShapeStyle(.tint.opacity(configuration.isPressed ? 0.26 : 0.16)) }
            if configuration.isPressed { return AnyShapeStyle(.primary.opacity(0.12)) }
            return AnyShapeStyle(.primary.opacity(isHovering ? 0.07 : 0))
        }

        @ViewBuilder private var label: some View {
            if isIcon {
                configuration.label
                    .frame(width: Chrome.capsuleContentHeight, height: Chrome.capsuleContentHeight)
            } else {
                configuration.label
                    .font(.ui(.callout))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            }
        }
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    static var chip: ChipButtonStyle { ChipButtonStyle() }

    static func chip(active: Bool) -> ChipButtonStyle {
        ChipButtonStyle(isActive: active)
    }

    static func iconChip(active: Bool) -> ChipButtonStyle {
        ChipButtonStyle(isActive: active, isIcon: true)
    }
}

enum Workspace {
    struct Editor: Identifiable {
        var id: String { bundleID }
        var name: String
        var bundleID: String
    }

    static let editors = [
        Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed"),
        Editor(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        Editor(name: "Terminal", bundleID: "com.apple.Terminal"),
        Editor(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        Editor(name: "iTerm", bundleID: "com.googlecode.iterm2"),
    ]

    /// Opens Terminal with the command already running, so an interactive CLI login gets a real shell.
    static func openTerminal(running command: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tivano-login", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One file per CLI: a second login opened while the first shell is still running
        // must not overwrite the script that shell is reading.
        let token = command.split(whereSeparator: \.isWhitespace).first.map { $0.filter(\.isLetter) } ?? ""
        let script = directory.appendingPathComponent(token.isEmpty ? "login.command" : "login-\(token).command")
        let contents = "#!/bin/zsh -l\n" + command + "\n"
        do {
            try contents.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    /// Looked up once per launch: the chat's controls build this list on every render, and each
    /// entry is a Launch Services query.
    static let installedEditors: [Editor] = editors.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
    }

    static func open(_ path: String, with editor: Editor) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Icons by bundle id. Each is a Launch Services lookup plus an icon read, and the "Open in"
    /// menu asks for every editor's whenever the chat's chrome is rebuilt.
    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor
    static func icon(for editor: Editor) -> NSImage? {
        if let cached = icons[editor.bundleID] { return cached }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: application.path)
        image.size = NSSize(width: 16, height: 16)
        icons[editor.bundleID] = image
        return image
    }

    /// Finder's icon, for the same menu.
    @MainActor static let finderIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
