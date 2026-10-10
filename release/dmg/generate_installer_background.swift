#!/usr/bin/env swift
// Renders the Tivano installer (DMG) window background at 1x and 2x, plus a
// preview composite that mimics how Finder lays out the two icons on top of it.
//
// Usage: swift generate_installer_background.swift <output-directory> [path/to/AppIcon.icns]
//
// The geometry here is the single source of truth shared with the pre-baked
// .DS_Store (see release/dmg/README.md). If any of these constants change, the
// .DS_Store must be re-baked so Finder's icon positions match the artwork:
//   designed content size: 660x400 (WindowBounds 660x480, see README)
//   Tivano.app icon center: (165, 200)   Applications icon center: (495, 200)
//   icon size: 128
import AppKit

// Canvas + layout (points, top-left origin)
let canvasW: CGFloat = 660
let canvasH: CGFloat = 400
// The exported image carries extra bleed below the composition. Finder on
// macOS 27 always shows a tab bar and honors the user's global path bar, so
// the visible content height varies with their settings (about 384pt to
// 412pt for the 480pt WindowBounds); the bleed continues the same paper so no
// variant can expose an unpainted strip. Finder anchors backgrounds top-left.
let exportBleed: CGFloat = 80
let appIconCenter = CGPoint(x: 165, y: 200)
let applicationsIconCenter = CGPoint(x: 495, y: 200)
let iconSize: CGFloat = 128

// Brand tokens: the warm paper and sage of the icon and launch artwork.
func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let paperTop = srgb(0xFAF8F3)
let paperBottom = srgb(0xEFEBE1)
let sage = srgb(0x6E9A80)
let sageInk = srgb(0x5E7968)
let wordmarkInk = srgb(0x3E5C4A)
let textPrimary = srgb(0x2B3A31)
let wordmark = "Tivano"
let outputStem = "installer-background"

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: generate_installer_background.swift <output-directory> [path/to/AppIcon.icns]\n".utf8))
    exit(64)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func drawText(_ string: String, font: NSFont, color: NSColor, center: CGPoint, kern: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let size = attributed.size()
    attributed.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
}

// Paints only the blurred shadow of `shape`: the shape itself is drawn far
// off-canvas and its shadow offset back into place. Shadow geometry is in
// device pixels, so it is multiplied by the render scale.
func softShape(_ context: CGContext, scale: CGFloat, color: NSColor, blur: CGFloat, _ shape: CGPath) {
    let away: CGFloat = 4000
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: away * scale), blur: blur * scale, color: color.cgColor)
    context.translateBy(x: 0, y: away)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()
}

func leaf(center: CGPoint, length: CGFloat, width: CGFloat, angle: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle * .pi / 180)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: -length / 2, y: 0))
    path.addQuadCurve(to: CGPoint(x: length / 2, y: 0), control: CGPoint(x: 0, y: -width))
    path.addQuadCurve(to: CGPoint(x: -length / 2, y: 0), control: CGPoint(x: 0, y: width))
    return path.copy(using: &transform)!
}

// The hand-drawn arrow: a cubic swoop with a little deterministic wobble, so
// it reads as one pen stroke rather than a vector primitive.
func handStroke(from p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, to p3: CGPoint, wobble: CGFloat, phase: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 90
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y
        let jitter = wobble * (sin(t * 11 + phase) * 0.6 + sin(t * 23 + phase * 2) * 0.4) * sin(t * .pi)
        let point = CGPoint(x: x, y: y + jitter)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

var renderScale: CGFloat = 1

func drawBackground(into context: CGContext) {
    let fullH = canvasH + exportBleed
    let space = CGColorSpace(name: CGColorSpace.sRGB)

    // Warm paper, a touch brighter toward the top-left where the light comes from
    if let paper = CGGradient(colorsSpace: space, colors: [paperTop.cgColor, paperBottom.cgColor] as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(paper, start: CGPoint(x: 120, y: 0), end: CGPoint(x: 420, y: fullH), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // Dappled foliage shadow drifting in from the top-right corner, kept faint
    let foliage = srgb(0x7F8E78, 0.11)
    let leaves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (612, 18, 70, 22, -28), (570, 46, 58, 18, 12), (640, 82, 64, 20, 54),
        (596, 112, 46, 15, -6), (530, 14, 48, 15, 40), (648, 150, 52, 16, -40),
        (552, 84, 40, 13, 70), (624, 196, 38, 12, 18), (24, 330, 54, 17, -60), (52, 372, 44, 14, 20),
    ]
    for (x, y, l, w, a) in leaves {
        softShape(context, scale: renderScale, color: foliage, blur: 9, leaf(center: CGPoint(x: x, y: y), length: l, width: w, angle: a))
    }
    // Window light: two soft diagonal beams across the paper
    for (offset, alpha) in [(CGFloat(0), CGFloat(0.55)), (CGFloat(120), CGFloat(0.35))] {
        let beam = CGMutablePath()
        beam.addLines(between: [
            CGPoint(x: 300 + offset, y: -20), CGPoint(x: 360 + offset, y: -20),
            CGPoint(x: 120 + offset, y: fullH + 20), CGPoint(x: 60 + offset, y: fullH + 20),
        ])
        beam.closeSubpath()
        softShape(context, scale: renderScale, color: NSColor(white: 1, alpha: alpha), blur: 36, beam)
    }

    // Drafting marks borrowed from the icon's construction lines
    let hairline = sage.withAlphaComponent(0.22)
    context.setStrokeColor(hairline.cgColor)
    context.setLineWidth(0.75)
    context.setLineCap(.butt)
    // The shared baseline through both icons
    context.strokeLineSegments(between: [CGPoint(x: 28, y: appIconCenter.y), CGPoint(x: canvasW - 28, y: appIconCenter.y)])
    // The hanger line from the top edge, as on the icon
    context.strokeLineSegments(between: [CGPoint(x: canvasW / 2, y: 0), CGPoint(x: canvasW / 2, y: 30)])
    // Dashed dimension over the app icon's visible body, with its note
    context.saveGState()
    context.setLineDash(phase: 0, lengths: [3, 3])
    let dimY = appIconCenter.y - iconSize / 2 - 16
    context.strokeLineSegments(between: [
        CGPoint(x: appIconCenter.x - 52, y: dimY), CGPoint(x: appIconCenter.x + 52, y: dimY),
    ])
    context.restoreGState()
    context.strokeLineSegments(between: [
        CGPoint(x: appIconCenter.x - 52, y: dimY - 4), CGPoint(x: appIconCenter.x - 52, y: dimY + 4),
        CGPoint(x: appIconCenter.x + 52, y: dimY - 4), CGPoint(x: appIconCenter.x + 52, y: dimY + 4),
    ])
    let mono = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    drawText("Ø128", font: mono, color: sage.withAlphaComponent(0.55), center: CGPoint(x: appIconCenter.x + 72, y: dimY))
    // Registration crosses in the lower corners
    for corner in [CGPoint(x: 34, y: 362), CGPoint(x: canvasW - 34, y: 362)] {
        context.strokeLineSegments(between: [
            CGPoint(x: corner.x - 6, y: corner.y), CGPoint(x: corner.x + 6, y: corner.y),
            CGPoint(x: corner.x, y: corner.y - 6), CGPoint(x: corner.x, y: corner.y + 6),
        ])
    }
    drawText("macOS 26+  ·  Apple silicon", font: mono, color: sage.withAlphaComponent(0.55), center: CGPoint(x: canvasW / 2, y: 362), kern: 0.6)

    // Wordmark
    drawText(wordmark, font: .systemFont(ofSize: 28, weight: .semibold), color: wordmarkInk, center: CGPoint(x: canvasW / 2, y: 62), kern: -0.4)

    // The hand-drawn arrow, swooping over the gap toward Applications. Opaque
    // ink, so the head strokes can overlap the shaft without darkening.
    let start = CGPoint(x: 246, y: 176)
    let end = CGPoint(x: 418, y: 170)
    let shaft = handStroke(from: start, CGPoint(x: 284, y: 118), CGPoint(x: 372, y: 108), to: end, wobble: 1.1, phase: 0.7)
    context.setStrokeColor(sageInk.cgColor)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(2.4)
    context.addPath(shaft)
    context.strokePath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: end.x - 15, y: end.y - 6))
    head.addQuadCurve(to: end, control: CGPoint(x: end.x - 6, y: end.y - 2))
    head.addQuadCurve(to: CGPoint(x: end.x - 3, y: end.y - 16), control: CGPoint(x: end.x - 1, y: end.y - 7))
    context.setLineWidth(2.4)
    context.addPath(head)
    context.strokePath()

    // Handwritten note riding under the swoop
    let hand = NSFont(name: "Noteworthy-Bold", size: 15) ?? .systemFont(ofSize: 14, weight: .medium)
    context.saveGState()
    context.translateBy(x: canvasW / 2, y: 152)
    context.rotate(by: -3 * .pi / 180)
    drawText("drag me over", font: hand, color: sageInk, center: .zero)
    context.restoreGState()
}

func render(scale: CGFloat, height: CGFloat = canvasH, drawExtras: ((CGContext) -> Void)? = nil) -> NSBitmapImageRep {
    let pixelW = Int(canvasW * scale)
    let pixelH = Int(height * scale)
    guard let context = CGContext(
        data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create bitmap context") }
    // Flip to top-left origin so layout constants read naturally
    context.translateBy(x: 0, y: CGFloat(pixelH))
    context.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    renderScale = scale
    drawBackground(into: context)
    drawExtras?(context)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let cgImage = context.makeImage() else { fatalError("Could not snapshot bitmap context") }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: canvasW, height: height)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
    try data.write(to: url)
}

// 1x + 2x background layers (combined into a hidpi TIFF by the caller)
try writePNG(render(scale: 1, height: canvasH + exportBleed), to: outputDir.appendingPathComponent("\(outputStem).png"))
try writePNG(render(scale: 2, height: canvasH + exportBleed), to: outputDir.appendingPathComponent("\(outputStem)@2x.png"))

// Preview composite: what the mounted window should look like, with icons and
// Finder-style labels at the exact .DS_Store positions.
func drawIcon(_ image: NSImage?, center: CGPoint, label: String, in context: CGContext) {
    let rect = CGRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2, width: iconSize, height: iconSize)
    image?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    drawText(label, font: .systemFont(ofSize: 12), color: textPrimary, center: CGPoint(x: center.x, y: center.y + iconSize / 2 + 12))
}
// The preview's app icon: an optional third argument names an .icns, else the installed Tivano's.
let previewIconPath = CommandLine.arguments.dropFirst(2).first { $0.hasSuffix(".icns") }
let appIcon = previewIconPath.flatMap { NSImage(contentsOfFile: $0) }
    ?? NSImage(contentsOfFile: "/Applications/Tivano.app/Contents/Resources/AppIcon.icns")
    ?? NSWorkspace.shared.icon(forFile: "/Applications/Tivano.app")
let applicationsIcon = NSWorkspace.shared.icon(forFile: "/Applications")
let preview = render(scale: 2) { context in
    drawIcon(appIcon, center: appIconCenter, label: wordmark, in: context)
    drawIcon(applicationsIcon, center: applicationsIconCenter, label: "Applications", in: context)
}
try writePNG(preview, to: outputDir.appendingPathComponent("preview-mock.png"))
print("Rendered installer background + preview into \(outputDir.path)")
