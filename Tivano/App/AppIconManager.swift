import AppKit
import Observation

@MainActor
@Observable
final class AppIconManager {
    private struct AppliedState: Equatable {
        let style: ThemeStyle
        let edition: AppEdition
    }

    static let shared = AppIconManager()

    private(set) var image: NSImage
    @ObservationIgnored private var lastApplied: AppliedState?

    private init() {
        image = NSApp.applicationIconImage
    }

    func apply(choice: AppIconChoice, style: ThemeStyle) {
        let resolved = choice.resolved(for: style)
        let edition = AppInfo.edition
        let state = AppliedState(style: resolved, edition: edition)
        guard lastApplied != state else { return }
        lastApplied = state

        guard resolved != .texture,
              let base = NSImage(named: AppIconChoice.assetName(for: resolved)) else {
            NSApp.applicationIconImage = nil
            image = NSApp.applicationIconImage
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
        NSApp.applicationIconImage = rendered
        image = rendered
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
