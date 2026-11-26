import AppKit

private final class LockedCellMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var size: NSSize = .zero
    private var baselineOffset: NSPoint = .zero

    func readSize() -> NSSize {
        lock.lock()
        defer { lock.unlock() }
        return size
    }

    func readBaselineOffset() -> NSPoint {
        lock.lock()
        defer { lock.unlock() }
        return baselineOffset
    }

    func store(size: NSSize, baselineOffset: NSPoint) {
        lock.lock()
        self.size = size
        self.baselineOffset = baselineOffset
        lock.unlock()
    }
}

@MainActor
final class FileMentionCell: NSTextAttachmentCell {
    private static let cornerRadius: CGFloat = 5
    private static let leadingPadding: CGFloat = 5
    private static let iconGap: CGFloat = 4
    private static let trailingPadding: CGFloat = 6
    private static let fillAlpha: CGFloat = 0.16
    private static let strokeAlpha: CGFloat = 0.22
    private static let symbolScale: CGFloat = 0.85

    private struct DrawCacheKey: Equatable {
        let label: FileMentionLabel
        let fontName: String
        let fontSize: CGFloat
        let accent: NSColor
        let appearanceName: NSAppearance.Name
    }

    private let path: String
    private let isDirectory: Bool
    private var label: FileMentionLabel
    private var chipFont: NSFont
    private var accent: NSColor
    private var iconSize: NSSize = .zero
    private var textWidth: CGFloat = 0
    private var cachedDrawKey: DrawCacheKey?
    private var cachedSymbol: NSImage?
    private var cachedAttributedLabel: NSAttributedString?
    private weak var lastControlView: NSView?
    private nonisolated let metrics = LockedCellMetrics()

    init(path: String, isDirectory: Bool, label: FileMentionLabel, font: NSFont, accent: NSColor) {
        self.path = path
        self.isDirectory = isDirectory
        self.label = label
        self.chipFont = font
        self.accent = accent
        super.init(textCell: "")
        recalculateMetrics()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("FileMentionCell does not support NSCoding")
    }

    func update(label: FileMentionLabel, font: NSFont, accent: NSColor) {
        self.label = label
        self.chipFont = font
        self.accent = accent
        invalidateDrawCache()
        recalculateMetrics()
        controlView?.needsDisplay = true
        lastControlView?.needsDisplay = true
    }

    private func invalidateDrawCache() {
        cachedDrawKey = nil
        cachedSymbol = nil
        cachedAttributedLabel = nil
    }

    nonisolated override func cellSize() -> NSSize {
        metrics.readSize()
    }

    nonisolated override func cellBaselineOffset() -> NSPoint {
        metrics.readBaselineOffset()
    }

    override func wantsToTrackMouse() -> Bool {
        false
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        lastControlView = controlView
        if let appearance = controlView?.effectiveAppearance {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    self.drawChip(in: cellFrame, controlView: controlView)
                }
            }
        } else {
            drawChip(in: cellFrame, controlView: controlView)
        }
    }

    private var symbolName: String {
        if isDirectory { return "folder" }
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt": return "doc.text"
        default: return "doc"
        }
    }

    private func makeAttributedLabel() -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: label.name,
            attributes: [
                .font: chipFont,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if let detail = label.detail, !detail.isEmpty {
            text.append(NSAttributedString(
                string: " · " + detail,
                attributes: [
                    .font: chipFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        return text
    }

    private func recalculateMetrics() {
        let symbolPointSize = chipFont.pointSize * Self.symbolScale
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            iconSize = symbol.size
        } else {
            let fallback = ceil(symbolPointSize)
            iconSize = NSSize(width: fallback, height: fallback)
        }

        let measuredText = makeAttributedLabel().size()
        textWidth = ceil(measuredText.width)

        let width = ceil(
            Self.leadingPadding
                + iconSize.width
                + Self.iconGap
                + measuredText.width
                + Self.trailingPadding
        )
        let height = ceil(chipFont.ascender - chipFont.descender) + 2
        let baselineOffset = NSPoint(x: 0, y: chipFont.descender - 1)
        metrics.store(size: NSSize(width: width, height: height), baselineOffset: baselineOffset)
    }

    private func drawChip(in cellFrame: NSRect, controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let scale = controlView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        let strokeWidth = 1.0 / max(scale, 1.0)

        let fillPath = NSBezierPath(
            roundedRect: cellFrame,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        accent.withAlphaComponent(Self.fillAlpha).setFill()
        fillPath.fill()

        let strokeRect = cellFrame.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let strokeRadius = max(0, Self.cornerRadius - strokeWidth / 2)
        let strokePath = NSBezierPath(
            roundedRect: strokeRect,
            xRadius: strokeRadius,
            yRadius: strokeRadius
        )
        strokePath.lineWidth = strokeWidth
        accent.withAlphaComponent(Self.strokeAlpha).setStroke()
        strokePath.stroke()

        let appearanceName = controlView?.effectiveAppearance.name ?? NSAppearance.currentDrawing().name
        let drawKey = DrawCacheKey(
            label: label,
            fontName: chipFont.fontName,
            fontSize: chipFont.pointSize,
            accent: accent,
            appearanceName: appearanceName
        )
        if cachedDrawKey != drawKey {
            let symbolPointSize = chipFont.pointSize * Self.symbolScale
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
            cachedSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            cachedAttributedLabel = makeAttributedLabel()
            cachedDrawKey = drawKey
        }

        if let symbol = cachedSymbol {
            let iconRect = NSRect(
                x: cellFrame.minX + Self.leadingPadding,
                y: cellFrame.midY - iconSize.height / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            symbol.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )
        }

        let textX = cellFrame.minX + Self.leadingPadding + iconSize.width + Self.iconGap
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? controlView?.isFlipped ?? true
        let baselineY = isFlipped
            ? cellFrame.maxY + chipFont.descender - 1
            : cellFrame.minY - chipFont.descender + 1
        if let attributed = cachedAttributedLabel {
            attributed.draw(
                with: NSRect(x: textX, y: baselineY, width: textWidth + 2, height: 0),
                options: [],
                context: nil
            )
        }
    }
}

@MainActor
final class FileMentionAttachment: NSTextAttachment {
    nonisolated let path: String
    nonisolated let isDirectory: Bool

    var label: FileMentionLabel {
        didSet { syncCell() }
    }

    var font: NSFont {
        didSet { syncCell() }
    }

    var accent: NSColor {
        didSet { syncCell() }
    }

    private let mentionCell: FileMentionCell

    init(path: String, isDirectory: Bool, label: FileMentionLabel, font: NSFont, accent: NSColor) {
        self.path = path
        self.isDirectory = isDirectory
        self.label = label
        self.font = font
        self.accent = accent
        let cell = FileMentionCell(
            path: path,
            isDirectory: isDirectory,
            label: label,
            font: font,
            accent: accent
        )
        self.mentionCell = cell
        super.init(data: nil, ofType: nil)
        self.attachmentCell = cell
    }

    @available(*, unavailable)
    nonisolated required init?(coder: NSCoder) {
        fatalError("FileMentionAttachment does not support NSCoding")
    }

    private func syncCell() {
        mentionCell.update(label: label, font: font, accent: accent)
    }
}

@MainActor
enum FileMentionText {
    /// Resolves a mention's path inside `root`: nil when it is not a file or folder there,
    /// else whether it is a folder. Absolute paths and `..` never resolve; a leading `~`
    /// is a literal name (appendingPathComponent never expands it).
    static func resolver(root: String?) -> ((String) -> Bool?)? {
        guard let root, !root.isEmpty else { return nil }
        return { path in
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(path), isDirectory: &isDirectory) else { return nil }
            return isDirectory.boolValue
        }
    }

    private static let attachmentCharacter = "\u{FFFC}"

    static var plainAttributesKeysToStrip: [NSAttributedString.Key] {
        [.attachment, .toolTip]
    }

    static func serialized(_ text: NSAttributedString, range: NSRange? = nil) -> String {
        let totalLength = text.length
        let scanRange: NSRange
        if let range {
            let start = max(0, min(range.location, totalLength))
            let end = max(start, min(NSMaxRange(range), totalLength))
            scanRange = NSRange(location: start, length: end - start)
        } else {
            scanRange = NSRange(location: 0, length: totalLength)
        }
        guard scanRange.length > 0 else { return "" }

        let nsString = text.string as NSString
        var output = ""
        text.enumerateAttribute(.attachment, in: scanRange, options: []) { value, attrRange, _ in
            if let mention = value as? FileMentionAttachment {
                for _ in 0..<attrRange.length {
                    output += "@"
                    output += mention.path
                }
            } else {
                output += nsString.substring(with: attrRange)
            }
        }
        return output
    }

    static func modelOffset(_ viewOffset: Int, in text: NSAttributedString) -> Int {
        let clamped = max(0, min(viewOffset, text.length))
        guard clamped > 0 else { return 0 }

        var delta = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: clamped), options: []) { value, attrRange, _ in
            guard let mention = value as? FileMentionAttachment else { return }
            delta += attrRange.length * mention.path.utf16.count
        }
        return clamped + delta
    }

    static func viewOffset(_ modelOffset: Int, in text: NSAttributedString) -> Int {
        if modelOffset <= 0 { return 0 }

        var currentModel = 0
        var currentView = 0
        var resolved: Int?

        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, attrRange, stop in
            if let mention = value as? FileMentionAttachment {
                let tokenLength = 1 + mention.path.utf16.count
                for _ in 0..<attrRange.length {
                    let tokenStart = currentModel
                    let tokenEnd = currentModel + tokenLength
                    if modelOffset <= tokenStart {
                        resolved = currentView
                        stop.pointee = true
                        return
                    }
                    if modelOffset <= tokenEnd {
                        resolved = currentView + 1
                        stop.pointee = true
                        return
                    }
                    currentModel = tokenEnd
                    currentView += 1
                }
            } else {
                let nextModel = currentModel + attrRange.length
                if modelOffset <= nextModel {
                    resolved = currentView + (modelOffset - currentModel)
                    stop.pointee = true
                    return
                }
                currentModel = nextModel
                currentView += attrRange.length
            }
        }

        return resolved ?? text.length
    }

    static func modelRange(_ viewRange: NSRange, in text: NSAttributedString) -> NSRange {
        let start = modelOffset(viewRange.location, in: text)
        let end = modelOffset(NSMaxRange(viewRange), in: text)
        return NSRange(location: start, length: max(0, end - start))
    }

    static func viewRange(_ modelRange: NSRange, in text: NSAttributedString) -> NSRange {
        let start = viewOffset(modelRange.location, in: text)
        let end = viewOffset(NSMaxRange(modelRange), in: text)
        return NSRange(location: start, length: max(0, end - start))
    }

    static func mentionEnds(atModelOffset offset: Int, in text: NSAttributedString) -> Bool {
        if offset <= 0 { return false }

        var currentModel = 0
        var matched = false

        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, attrRange, stop in
            if let mention = value as? FileMentionAttachment {
                let tokenLength = 1 + mention.path.utf16.count
                for _ in 0..<attrRange.length {
                    currentModel += tokenLength
                    if currentModel == offset {
                        matched = true
                        stop.pointee = true
                        return
                    }
                    if currentModel > offset {
                        stop.pointee = true
                        return
                    }
                }
            } else {
                currentModel += attrRange.length
                if currentModel >= offset {
                    stop.pointee = true
                    return
                }
            }
        }

        return matched
    }

    static func attributed(
        from plain: String,
        attributes: [NSAttributedString.Key: Any],
        font: NSFont,
        accent: NSColor,
        resolve: (String) -> Bool?
    ) -> NSAttributedString {
        var resolvedCache: [String: Bool?] = [:]
        let tokens = FileMentions.tokens(in: plain) { path in
            if let cached = resolvedCache[path] {
                return cached
            }
            let result = resolve(path)
            resolvedCache[path] = result
            return result
        }

        if tokens.isEmpty {
            return NSAttributedString(string: plain, attributes: attributes)
        }

        let labels = FileMentions.labels(for: tokens.map(\.path))
        let result = NSMutableAttributedString()
        let nsPlain = plain as NSString
        let totalLength = nsPlain.length
        var cursor = 0

        for token in tokens {
            if token.range.location > cursor {
                let slice = nsPlain.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
                result.append(NSAttributedString(string: slice, attributes: attributes))
            }

            let label = labels[token.path] ?? FileMentionLabel(name: token.path, detail: nil)
            let isDirectory = (resolvedCache[token.path] ?? nil) ?? false
            let attachment = FileMentionAttachment(
                path: token.path,
                isDirectory: isDirectory,
                label: label,
                font: font,
                accent: accent
            )

            var chipAttributes = attributes
            chipAttributes[.attachment] = attachment
            chipAttributes[.toolTip] = token.path
            result.append(NSAttributedString(string: attachmentCharacter, attributes: chipAttributes))

            cursor = NSMaxRange(token.range)
        }

        if cursor < totalLength {
            let tail = nsPlain.substring(with: NSRange(location: cursor, length: totalLength - cursor))
            result.append(NSAttributedString(string: tail, attributes: attributes))
        }

        return result
    }

    static func relabel(_ storage: NSTextStorage, font: NSFont, accent: NSColor) {
        let totalLength = storage.length
        guard totalLength > 0 else { return }

        var entries: [(range: NSRange, attachment: FileMentionAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: totalLength), options: []) { value, attrRange, _ in
            guard let mention = value as? FileMentionAttachment else { return }
            entries.append((range: attrRange, attachment: mention))
        }

        guard !entries.isEmpty else { return }

        let labels = FileMentions.labels(for: entries.map(\.attachment.path))
        var updates: [(range: NSRange, attachment: FileMentionAttachment, label: FileMentionLabel)] = []

        for entry in entries {
            let newLabel = labels[entry.attachment.path] ?? FileMentionLabel(name: entry.attachment.path, detail: nil)
            if entry.attachment.label != newLabel
                || entry.attachment.font != font
                || entry.attachment.accent != accent {
                updates.append((range: entry.range, attachment: entry.attachment, label: newLabel))
            }
        }

        guard !updates.isEmpty else { return }

        storage.beginEditing()
        for update in updates {
            if update.attachment.label != update.label {
                update.attachment.label = update.label
            }
            if update.attachment.font != font {
                update.attachment.font = font
            }
            if update.attachment.accent != accent {
                update.attachment.accent = accent
            }
            storage.edited(.editedAttributes, range: update.range, changeInLength: 0)
        }
        storage.endEditing()
    }
}
