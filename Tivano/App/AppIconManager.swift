import AppKit
import Observation

@MainActor
@Observable
final class AppIconManager {
    private struct AppliedState: Hashable {
        let style: ThemeStyle
        let edition: AppEdition
    }

    static let shared = AppIconManager()

    private(set) var image: NSImage
    @ObservationIgnored private var lastApplied: AppliedState?
    @ObservationIgnored private var lastWrittenBundleState: AppliedState?
    @ObservationIgnored private var renderedCache: [AppliedState: NSImage] = [:]

    private init() {
        image = NSApp.applicationIconImage
    }

    @ObservationIgnored private var pendingApply: Task<Void, Never>?
    @ObservationIgnored private var pendingBundleWrite: Task<Void, Never>?

    /// A theme switch hands the icon over after the switch's own frame: setting the Dock
    /// icon redraws the full-size image into the Dock tile synchronously (~20 ms).
    func applyAfterThemeSwitch(choice: AppIconChoice, style: ThemeStyle) {
        pendingApply?.cancel()
        pendingApply = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            pendingApply = nil
            applyNow(choice: choice, style: style)
        }
    }

    func apply(choice: AppIconChoice, style: ThemeStyle) {
        pendingApply?.cancel()
        pendingApply = nil
        applyNow(choice: choice, style: style)
    }

    private func applyNow(choice: AppIconChoice, style: ThemeStyle) {
        let resolved = choice.resolved(for: style)
        let edition = AppInfo.edition
        let state = AppliedState(style: resolved, edition: edition)
        guard lastApplied != state else { return }
        lastApplied = state

        if let cached = renderedCache[state] {
            NSApp.applicationIconImage = cached
            image = cached
            scheduleBundleIconWrite(state: state, image: cached)
            return
        }

        guard resolved != .texture,
              let base = NSImage(named: AppIconChoice.assetName(for: resolved)) else {
            NSApp.applicationIconImage = nil
            image = NSApp.applicationIconImage
            scheduleBundleIconWrite(state: state, image: nil)
            return
        }

        let rendered: NSImage
        switch edition {
        case .preview:
            rendered = Self.badgedIcon(from: base, text: "PRE", color: NSColor(srgbRed: 0.16, green: 0.48, blue: 0.96, alpha: 1))
        case .dev:
            rendered = Self.badgedIcon(from: base, text: "DEV", color: NSColor(srgbRed: 0.97, green: 0.54, blue: 0.12, alpha: 1))
        case .release:
            rendered = base
        }
        renderedCache[state] = rendered
        NSApp.applicationIconImage = rendered
        image = rendered
        scheduleBundleIconWrite(state: state, image: rendered)
    }

    private func scheduleBundleIconWrite(state: AppliedState, image: NSImage?) {
        guard lastWrittenBundleState != state,
              let bundlePath = Self.installedBundlePath() else { return }

        let imageData: Data?
        if let image {
            guard let tiff = image.tiffRepresentation else { return }
            imageData = tiff
        } else {
            imageData = nil
        }

        lastWrittenBundleState = state
        let previousWrite = pendingBundleWrite
        previousWrite?.cancel()
        pendingBundleWrite = Task.detached(priority: .utility) {
            await previousWrite?.value
            guard !Task.isCancelled else { return }
            let icon: NSImage?
            if let imageData {
                guard let decoded = NSImage(data: imageData) else { return }
                icon = decoded
            } else {
                icon = nil
            }
            _ = NSWorkspace.shared.setIcon(icon, forFile: bundlePath, options: [])
        }
    }

    private static func installedBundlePath() -> String? {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard bundleURL.pathExtension == "app" else { return nil }
        let bundlePath = bundleURL.path
        let roots = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
        for root in roots {
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if bundlePath.hasPrefix(prefix) {
                return bundlePath
            }
        }
        return nil
    }

    private static func badgedIcon(from source: NSImage, text badgeText: String, color badgeColor: NSColor) -> NSImage {
        let pixels = 1024
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixels * 4,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return source
        }

        let canvas = CGFloat(pixels)
        let plateOrigin: CGFloat = 100
        let plateSide: CGFloat = 824

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(
            in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        let badge = NSRect(
            x: plateOrigin + plateSide * 0.58,
            y: plateOrigin + plateSide * 0.09,
            width: plateSide * 0.33,
            height: plateSide * 0.19
        )
        let radius = plateSide * 0.035
        badgeColor.setFill()
        NSBezierPath(roundedRect: badge, xRadius: radius, yRadius: radius).fill()
        let text = NSAttributedString(string: badgeText, attributes: [
            .font: NSFont.systemFont(ofSize: plateSide * 0.10, weight: .heavy),
            .foregroundColor: NSColor(srgbRed: 0.13, green: 0.16, blue: 0.13, alpha: 1),
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: NSSize(width: canvas, height: canvas))
        result.addRepresentation(bitmap)
        return result
    }
}
