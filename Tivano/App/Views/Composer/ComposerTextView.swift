import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ComposerKey {
    case up
    case down
    case tab
    /// Right arrow in an empty composer: accepts a shown prediction.
    case right
    case escape
    case submit
    /// Command-Return: steer the running turn (queue as a follow-up).
    case steer
    /// Delete with the caret at the very start and nothing selected: the chips before the text take it.
    case deleteAtStart
}

/// Lets SwiftUI reach into the text view for focus and in-place replacements.
@MainActor
final class ComposerController {
    fileprivate weak var textView: ComposerNSTextView?
    private var suggestionPopover: NSPopover?
    private var suggestionHost: NSHostingController<AnyView>?
    private var suggestionOpensAbove = true
    /// The slash/@ refresh in flight for the latest keystroke; the next keystroke cancels it.
    /// The search for the caret's word, for the suggestions popover. One at a time: the
    /// next keystroke cancels it, and so does losing focus (see the composer's `onBlur`),
    /// so an answer for a word that is gone never shows.
    var suggestionRefresh: Task<Void, Never>?

    var cursorLocation: Int {
        textView?.modelCursorLocation ?? 0
    }

    var hasFocus: Bool {
        guard let textView else { return false }
        return NSApp.isActive && textView.window?.isKeyWindow == true && textView.window?.firstResponder === textView
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func mentionEnds(atModelOffset offset: Int) -> Bool {
        guard let textView, textView.mentionResolver != nil else { return false }
        return FileMentionText.mentionEnds(atModelOffset: offset, in: textView.attributedString())
    }

    func replaceCharacters(in modelRange: NSRange, with replacement: String) {
        guard let textView, let storage = textView.textStorage else { return }
        guard let resolver = textView.mentionResolver else {
            guard NSMaxRange(modelRange) <= storage.length else { return }
            guard textView.shouldChangeText(in: modelRange, replacementString: replacement) else { return }
            storage.replaceCharacters(in: modelRange, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: modelRange.location + (replacement as NSString).length, length: 0))
            return
        }
        // A suggestion range from before the last keystroke may run past the text now.
        guard NSMaxRange(modelRange) <= (textView.modelText as NSString).length else { return }
        let viewRange = FileMentionText.viewRange(modelRange, in: storage)
        guard NSMaxRange(viewRange) <= storage.length else { return }
        let attributedReplacement = FileMentionText.attributed(
            from: replacement,
            attributes: textView.plainTypingAttributes,
            font: textView.activeFont,
            accent: Chrome.accentNSColor,
            resolve: resolver
        )
        guard textView.shouldChangeText(in: viewRange, replacementString: attributedReplacement.string) else { return }
        if attributedReplacement.string.utf16.contains(0xFFFC) {
            textView.mentionsNeedRelabel = true
        }
        storage.replaceCharacters(in: viewRange, with: attributedReplacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: viewRange.location + attributedReplacement.length, length: 0))
        textView.stripMentionTypingAttributes()
    }

    /// Shows the slash/@ suggestions directly above the active token (or below if
    /// screen clearance above is too small). A SwiftUI `.popover` anchors to the
    /// whole composer bubble, so it lands centered (or flipped to the side) instead
    /// of where the user is typing.
    func showSuggestions<Content: View>(
        itemCount: Int,
        tokenModelOffset: Int,
        onSize: (NSSize) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        let popover: NSPopover
        if let existing = suggestionPopover {
            popover = existing
        } else {
            popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = true
            suggestionPopover = popover
        }
        guard let textView = textView, let window = textView.window else { return }

        let desiredHeight = min(440, 44 + CGFloat(max(itemCount, 1)) * TypeScale.shared.ui(26))
        let anchorRect = suggestionAnchorRect(atModelOffset: tokenModelOffset, in: textView)
        let spaceAbove: CGFloat?
        let spaceBelow: CGFloat?
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            let screenAnchor = window.convertToScreen(textView.convert(anchorRect, to: nil))
            spaceAbove = visibleFrame.maxY - screenAnchor.maxY - 12
            spaceBelow = screenAnchor.minY - visibleFrame.minY - 12
        } else {
            spaceAbove = nil
            spaceBelow = nil
        }

        let placement = FileMentions.suggestionPlacement(
            desiredHeight: desiredHeight,
            containerWidth: textView.bounds.width,
            spaceAbove: spaceAbove,
            spaceBelow: spaceBelow
        )
        let opensAbove: Bool
        var size = NSSize(width: placement.size.width, height: placement.size.height)
        if popover.isShown {
            opensAbove = suggestionOpensAbove
            if let lockedSpace = opensAbove ? spaceAbove : spaceBelow {
                size.height = min(desiredHeight, max(70, floor(lockedSpace)))
            } else {
                size.height = desiredHeight
            }
        } else {
            opensAbove = placement.opensAbove
            suggestionOpensAbove = opensAbove
        }

        onSize(size)
        // Height grows with the rows up to the cap and scrolls past it. The host never
        // publishes its own size (see setFixedContent), so this is the only size the
        // panel is ever positioned against and it stays anchored while typing narrows
        // the list.
        if suggestionHost == nil {
            let host = NSHostingController(rootView: AnyView(content()))
            host.sizingOptions = []
            suggestionHost = host
            popover.contentViewController = host
        }
        if popover.contentSize != size {
            let wasAnimated = popover.animates
            popover.animates = false
            popover.contentSize = size
            popover.animates = wasAnimated
        }
        if !popover.isShown {
            let edge: NSRectEdge = opensAbove
                ? (textView.isFlipped ? .minY : .maxY)
                : (textView.isFlipped ? .maxY : .minY)
            popover.show(relativeTo: anchorRect, of: textView, preferredEdge: edge)
            // The popover must never steal typing focus.
            window.makeFirstResponder(textView)
        }
    }

    func hideSuggestions() {
        suggestionPopover?.performClose(nil)
        suggestionOpensAbove = true
    }

    func tearDownSuggestions() {
        suggestionRefresh?.cancel()
        suggestionRefresh = nil
        suggestionPopover?.close()
        suggestionPopover?.contentViewController = nil
        suggestionHost = nil
        suggestionPopover = nil
        suggestionOpensAbove = true
    }

    /// True when the current click landed inside the suggestions popover,
    /// so losing text focus to pick a row must not dismiss the list first.
    func isClickInsideSuggestions() -> Bool {
        guard let popover = suggestionPopover, popover.isShown,
              let window = suggestionHost?.view.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    private func suggestionAnchorRect(atModelOffset tokenModelOffset: Int, in textView: NSTextView) -> NSRect {
        let attributed = textView.attributedString()
        let viewOffset = FileMentionText.viewOffset(tokenModelOffset, in: attributed)
        let clamped = max(0, min(viewOffset, attributed.length))
        let range = NSRange(location: clamped, length: clamped < attributed.length ? 1 : 0)
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        if let window = textView.window, screenRect.width >= 0, screenRect.height > 0 {
            let windowRect = window.convertFromScreen(screenRect)
            let tokenRect = textView.convert(windowRect, from: nil)
            let visible = textView.visibleRect
            let width = max(1, tokenRect.width)
            let height = max(18, tokenRect.height)
            let x: CGFloat
            let y: CGFloat
            if visible.width > 0, visible.height > 0 {
                x = min(max(tokenRect.minX, visible.minX), max(visible.minX, visible.maxX - width))
                y = min(max(tokenRect.minY, visible.minY), max(visible.minY, visible.maxY - height))
            } else {
                x = tokenRect.minX
                y = tokenRect.minY
            }
            return NSRect(x: x, y: y, width: width, height: height)
        }
        return caretRect(in: textView)
    }

    private func caretRect(in textView: NSTextView) -> NSRect {
        let selected = textView.selectedRange()
        let screenRect = textView.firstRect(forCharacterRange: selected, actualRange: nil)
        if let window = textView.window, screenRect.width >= 0, screenRect.height > 0 {
            let windowRect = window.convertFromScreen(screenRect)
            var rect = textView.convert(windowRect, from: nil)
            if rect.width < 1 { rect.size.width = 1 }
            if rect.height < 4 { rect.size.height = 18 }
            return rect
        }
        // Fallback: leading edge of the visible text.
        var rect = textView.visibleRect
        rect.origin.x += 4
        rect.size = NSSize(width: 1, height: 18)
        return rect
    }
}

final class ComposerNSTextView: NSTextView {
    private struct PlaceholderCacheKey: Equatable {
        let placeholder: String
        let placeholderHint: String
        let fontName: String
        let fontSize: CGFloat
        let width: CGFloat
        let appearanceName: NSAppearance.Name
    }

    private struct PlaceholderCache {
        let key: PlaceholderCacheKey
        let attributed: NSAttributedString
        let height: CGFloat
    }

    var placeholder = "" {
        didSet {
            invalidatePlaceholderCache()
            needsDisplay = true
        }
    }
    var placeholderHint = "" {
        didSet {
            invalidatePlaceholderCache()
            needsDisplay = true
        }
    }
    override var font: NSFont? {
        didSet { invalidatePlaceholderCache() }
    }
    var onAttach: (([AttachmentSource]) -> Void)?
    var onWidthChange: (() -> Void)?
    var onResign: (@MainActor () -> Void)?
    var mentionResolver: ((String) -> Bool?)?
    var mentionRoot: String?

    // MARK: - Handing the cursor back

    /// AppKit puts up the I-beam when the pointer enters this field. Everything around it is
    /// SwiftUI, which sets a cursor only when its own pointer style changes; the sidebar and
    /// the chat chrome claim the arrow all along, so nothing changes and nobody takes the
    /// I-beam down. Leaving the field therefore restores the arrow itself, unless something
    /// on the way out has already set another cursor (a link's hand).
    private var exitTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let exitTracking { removeTrackingArea(exitTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        exitTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if let exitTracking, event.trackingArea === exitTracking { return }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let exitTracking, event.trackingArea === exitTracking else {
            super.mouseExited(with: event)
            return
        }
        // After this event, so a cursor the destination sets in the same pass wins, and only
        // when the pointer did not move onto other text whose I-beam is its own.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, Self.showsIBeam,
                  !Self.isOverText(in: window) else { return }
            NSCursor.arrow.set()
        }
    }

    /// Whether the view under the pointer, or one of its nearest ancestors, is text that keeps
    /// its own I-beam: another field, a reply's text view.
    private static func isOverText(in window: NSWindow) -> Bool {
        guard let content = window.contentView, let superview = content.superview else { return false }
        let point = superview.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        var view = content.hitTest(point)
        var depth = 0
        while let current = view, depth < 4 {
            if current is NSTextView || current is NSTextField { return true }
            view = current.superview
            depth += 1
        }
        return false
    }

    /// Whether the cursor on screen is the I-beam, by identity or, for a copy, by its shape.
    private static var showsIBeam: Bool {
        if NSCursor.current === NSCursor.iBeam { return true }
        guard let shown = NSCursor.currentSystem else { return false }
        let iBeam = NSCursor.iBeam
        return shown.hotSpot == iBeam.hotSpot && shown.image.size == iBeam.image.size
    }

    private var placeholderCache: PlaceholderCache?
    private var lastMentionAttachmentCount = 0
    private var lastMentionFontName: String?
    private var lastMentionFontSize: CGFloat = 0
    private var lastMentionAccent: NSColor?
    fileprivate var mentionsNeedRelabel = false

    private func invalidatePlaceholderCache() {
        placeholderCache = nil
    }

    fileprivate var activeFont: NSFont {
        font ?? ThemeTypeface.nsFont(size: TypeScale.shared.content(14))
    }

    fileprivate var modelText: String {
        guard mentionResolver != nil else { return string }
        return FileMentionText.serialized(attributedString())
    }

    fileprivate var modelCursorLocation: Int {
        let viewOffset = selectedRange().location
        guard mentionResolver != nil else { return viewOffset }
        return FileMentionText.modelOffset(viewOffset, in: attributedString())
    }

    private static func attachmentCount(in storage: NSTextStorage) -> Int {
        var count = 0
        for codeUnit in storage.string.utf16 where codeUnit == 0xFFFC {
            count += 1
        }
        return count
    }

    fileprivate func syncMentionRelabelState(font: NSFont? = nil, accent: NSColor? = nil) {
        guard mentionResolver != nil, let storage = textStorage else {
            lastMentionAttachmentCount = 0
            mentionsNeedRelabel = false
            return
        }
        let currentFont = font ?? activeFont
        lastMentionAttachmentCount = Self.attachmentCount(in: storage)
        lastMentionFontName = currentFont.fontName
        lastMentionFontSize = currentFont.pointSize
        lastMentionAccent = accent ?? Chrome.accentNSColor
        mentionsNeedRelabel = false
    }

    fileprivate func relabelMentionsIfNeeded() {
        guard mentionResolver != nil, let storage = textStorage else { return }
        let count = Self.attachmentCount(in: storage)
        let currentFont = activeFont
        let currentAccent = Chrome.accentNSColor
        let countChanged = count != lastMentionAttachmentCount
        let styleChanged = lastMentionFontName != currentFont.fontName
            || lastMentionFontSize != currentFont.pointSize
            || lastMentionAccent != currentAccent
        let undoOrRedo = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        let needsRelabel = mentionsNeedRelabel || countChanged || styleChanged || (undoOrRedo && count > 0)
        lastMentionAttachmentCount = count
        mentionsNeedRelabel = false
        guard needsRelabel else { return }
        lastMentionFontName = currentFont.fontName
        lastMentionFontSize = currentFont.pointSize
        lastMentionAccent = currentAccent
        guard count > 0 else { return }
        FileMentionText.relabel(storage, font: currentFont, accent: currentAccent)
    }

    fileprivate func setModelText(_ text: String) {
        guard let resolver = mentionResolver, let storage = textStorage else {
            string = text
            syncMentionRelabelState()
            return
        }
        let baseFont = activeFont
        let accent = Chrome.accentNSColor
        let attributed = FileMentionText.attributed(
            from: text,
            attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor],
            font: baseFont,
            accent: accent,
            resolve: resolver
        )
        storage.beginEditing()
        storage.setAttributedString(attributed)
        storage.endEditing()
        syncMentionRelabelState(font: baseFont, accent: accent)
        stripMentionTypingAttributes()
        if string.isEmpty != placeholderShown { needsDisplay = true }
    }

    fileprivate func stripMentionTypingAttributes() {
        guard mentionResolver != nil else { return }
        var attrs = typingAttributes
        var changed = false
        for key in FileMentionText.plainAttributesKeysToStrip {
            if attrs.removeValue(forKey: key) != nil { changed = true }
        }
        if changed { typingAttributes = attrs }
    }

    fileprivate var plainTypingAttributes: [NSAttributedString.Key: Any] {
        var attrs = typingAttributes
        for key in FileMentionText.plainAttributesKeysToStrip {
            attrs.removeValue(forKey: key)
        }
        if attrs[.font] == nil { attrs[.font] = activeFont }
        if attrs[.foregroundColor] == nil { attrs[.foregroundColor] = NSColor.labelColor }
        return attrs
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            invalidatePlaceholderCache()
            onWidthChange?()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidatePlaceholderCache()
        if placeholderShown { needsDisplay = true }
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onResign?() }
        return ok
    }

    /// The image types a paste attaches, best first: a PNG is stored as it is, the rest
    /// are re-encoded off the main thread.
    private static let imageTypes: [UTType] = [.png, .tiff, .jpeg, .heic]
    private static let imagePasteboardTypes = imageTypes.map { NSPasteboard.PasteboardType($0.identifier) }

    /// Files, or image data with no text beside it, which paste as attachments instead of text.
    private var pasteboardHoldsAttachment: Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pasteboard.availableType(from: Self.imagePasteboardTypes) != nil && pasteboard.string(forType: .string) == nil
    }

    /// A plain-text view disables Paste when the clipboard has no text, so an image never reached `paste(_:)`.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), pasteboardHoldsAttachment { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, event.charactersIgnoringModifiers == "v", pasteboardHoldsAttachment {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        if mentionResolver != nil, range.length > 0 {
            let attributed = attributedString()
            if NSMaxRange(range) <= attributed.length {
                var hasMention = false
                attributed.enumerateAttribute(.attachment, in: range, options: []) { value, _, stop in
                    if value is FileMentionAttachment {
                        hasMention = true
                        stop.pointee = true
                    }
                }
                if hasMention {
                    pboard.declareTypes([.string], owner: nil)
                    pboard.setString(FileMentionText.serialized(attributed, range: range), forType: .string)
                    return true
                }
            }
        }
        return super.writeSelection(to: pboard, types: types)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onAttach?(urls.map(AttachmentSource.file))
            return
        }
        if pasteboard.string(forType: .string) == nil,
           let available = pasteboard.availableType(from: Self.imagePasteboardTypes),
           let type = UTType(available.rawValue),
           let data = pasteboard.data(forType: available) {
            onAttach?([.image(data, type)])
            return
        }
        if let resolver = mentionResolver,
           let pasted = pasteboard.string(forType: .string),
           !FileMentions.tokens(in: pasted, resolve: resolver).isEmpty,
           let storage = textStorage {
            let range = selectedRange()
            if NSMaxRange(range) <= storage.length {
                // A paste lands inside a word as part of it, as the draft's text reads on reload:
                // a non-space on either side is carried as a sentinel so no chip starts or ends there.
                let text = storage.string as NSString
                let isSpace: (unichar) -> Bool = { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 }
                let joinsBefore = range.location > 0 && !isSpace(text.character(at: range.location - 1))
                let joinsAfter = NSMaxRange(range) < text.length && !isSpace(text.character(at: NSMaxRange(range)))
                let wrapped = (joinsBefore ? "x" : "") + pasted + (joinsAfter ? "x" : "")
                let built = FileMentionText.attributed(
                    from: wrapped,
                    attributes: plainTypingAttributes,
                    font: activeFont,
                    accent: Chrome.accentNSColor,
                    resolve: resolver
                )
                let start = joinsBefore ? 1 : 0
                let attributed = built.attributedSubstring(from: NSRange(location: start, length: built.length - start - (joinsAfter ? 1 : 0)))
                if shouldChangeText(in: range, replacementString: attributed.string) {
                    if attributed.string.utf16.contains(0xFFFC) {
                        mentionsNeedRelabel = true
                    }
                    storage.replaceCharacters(in: range, with: attributed)
                    didChangeText()
                    setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
                    stripMentionTypingAttributes()
                }
                return
            }
        }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onAttach?(urls.map(AttachmentSource.file))
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Whether the last draw showed the placeholder: the view is redrawn whole only when
    /// the text becomes empty or stops being empty; other keystrokes redraw their lines.
    private var placeholderShown = false

    override func didChangeText() {
        super.didChangeText()
        if string.isEmpty != placeholderShown { needsDisplay = true }
    }

    private func placeholderAttributes(font placeholderFont: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        return [
            .font: placeholderFont,
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func resolvedPlaceholder(for rect: NSRect) -> PlaceholderCache {
        let placeholderFont = activeFont
        let key = PlaceholderCacheKey(
            placeholder: placeholder,
            placeholderHint: placeholderHint,
            fontName: placeholderFont.fontName,
            fontSize: placeholderFont.pointSize,
            width: rect.width,
            appearanceName: effectiveAppearance.name
        )
        if let cached = placeholderCache, cached.key == key {
            return cached
        }

        let attributes = placeholderAttributes(font: placeholderFont)
        let measureSize = NSSize(width: rect.width, height: .greatestFiniteMagnitude)
        func measureHeight(_ text: NSAttributedString) -> CGFloat {
            text.boundingRect(with: measureSize, options: [.usesLineFragmentOrigin]).height
        }

        let attributed: NSAttributedString
        let height: CGFloat
        if placeholderHint.isEmpty {
            attributed = NSAttributedString(string: placeholder, attributes: attributes)
            height = min(measureHeight(attributed), rect.height)
        } else {
            let hintFont = ThemeTypeface.nsFont(size: placeholderFont.pointSize * 0.85)
            let hint = placeholderHint as NSString
            let hintSize = hint.size(withAttributes: [.font: hintFont])
            let pillSize = NSSize(width: ceil(hintSize.width) + 14, height: ceil(hintSize.height) + 4)
            let attachment = NSTextAttachment()
            attachment.image = NSImage(size: pillSize, flipped: false) { rect in
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                hint.draw(at: NSPoint(x: 7, y: 2), withAttributes: [
                    .font: hintFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                return true
            }
            attachment.bounds = NSRect(
                x: 0, y: (placeholderFont.capHeight - pillSize.height) / 2,
                width: pillSize.width, height: pillSize.height
            )
            let pill = NSAttributedString(attachment: attachment)
            func composed(_ text: String) -> NSMutableAttributedString {
                let composed = NSMutableAttributedString(string: text + " ", attributes: attributes)
                composed.append(pill)
                return composed
            }
            // Truncating the drawn text would cut the pill off with it, so a prediction too
            // long for the box is shortened here until the pill still fits after it.
            let full = composed(placeholder)
            let fullHeight = measureHeight(full)
            if rect.width <= 0 || fullHeight <= rect.height + 0.5 {
                attributed = full
                height = min(fullHeight, rect.height)
            } else {
                let characters = Array(placeholder)
                var low = 0, high = characters.count
                while low < high {
                    let mid = (low + high + 1) / 2
                    if measureHeight(composed(String(characters[..<mid]) + "…")) <= rect.height + 0.5 {
                        low = mid
                    } else {
                        high = mid - 1
                    }
                }
                let truncated = composed(String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…")
                attributed = truncated
                height = min(measureHeight(truncated), rect.height)
            }
        }

        let entry = PlaceholderCache(key: key, attributed: attributed, height: height)
        placeholderCache = entry
        return entry
    }

    private var placeholderRect: NSRect {
        let placeholderFont = activeFont
        let padding = textContainer?.lineFragmentPadding ?? 0
        let width = min(textContainer?.size.width ?? bounds.width, bounds.width - textContainerInset.width * 2)
        return NSRect(
            x: textContainerInset.width + padding,
            y: textContainerInset.height,
            width: max(0, width - padding * 2),
            height: 3 * ceil(placeholderFont.ascender - placeholderFont.descender + placeholderFont.leading)
        )
    }

    func placeholderHeight() -> CGFloat {
        guard string.isEmpty, !placeholder.isEmpty else { return 0 }
        return resolvedPlaceholder(for: placeholderRect).height
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        placeholderShown = string.isEmpty && !placeholder.isEmpty
        guard placeholderShown else { return }
        let rect = placeholderRect
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        resolvedPlaceholder(for: rect).attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }

}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var placeholderHint: String = ""
    let controller: ComposerController
    var onKey: (ComposerKey) -> Bool
    var onAttach: ([AttachmentSource]) -> Void
    var onCursorChange: (Int) -> Void
    var onBlur: () -> Void = {}
    /// Whether the text takes typing focus as it appears. The chat's own box does; a
    /// floating panel's never does, so a head arriving or coming on stage while the user
    /// types in the chat leaves the caret where it is.
    var takesFocusOnAppear = true
    var pointSize: CGFloat = TypeScale.shared.content(14)
    var serif: Bool = TypeScale.shared.serif
    /// The thread's working directory: `@path` mentions resolving inside it show as chips.
    var mentionRoot: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = ComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = ThemeTypeface.nsFont(size: pointSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = Chrome.accentNSColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        // This field must never offer Write with Siri, writing-tools UI, inline
        // predictions, or Siri completion candidates: it has its own slash/@
        // popover. `.none` rather than `.limited`, which still offers the Writing
        // Tools panel and its Siri chip from the Edit and context menus. Scoped to
        // this view so every other system field is unaffected.
        textView.inlinePredictionType = .no
        textView.writingToolsBehavior = .none
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.placeholder = placeholder
        textView.placeholderHint = placeholderHint
        textView.mentionRoot = mentionRoot
        textView.mentionResolver = FileMentionText.resolver(root: mentionRoot)
        textView.setModelText(text)
        textView.onAttach = onAttach

        scrollView.documentView = textView
        controller.textView = textView
        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.onWidthChange = { [weak coordinator] in
            Task { @MainActor in coordinator?.updateHeight() }
        }
        textView.onResign = { [weak coordinator] in
            coordinator?.cancelPendingCursorChange()
            Task { @MainActor in coordinator?.parent.onBlur() }
        }
        Task { @MainActor in
            coordinator.updateHeight()
            guard takesFocusOnAppear else { return }
            for _ in 0..<10 {
                guard !Task.isCancelled, textView.window == nil else { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            // And never from another box the user is typing in, whichever one this is.
            if let window = textView.window, !(window.firstResponder is ComposerNSTextView) {
                window.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        textView.onAttach = onAttach
        // A thread moved to another project resolves its mentions there: the chips are rebuilt
        // from the same text, the caret kept at its place in it.
        if textView.mentionRoot != mentionRoot {
            let cursor = textView.modelCursorLocation
            textView.mentionRoot = mentionRoot
            textView.mentionResolver = FileMentionText.resolver(root: mentionRoot)
            if !textView.hasMarkedText(), let storage = textView.textStorage {
                textView.setModelText(text)
                let location = textView.mentionResolver == nil ? min(cursor, storage.length) : FileMentionText.viewOffset(min(cursor, (text as NSString).length), in: storage)
                textView.setSelectedRange(NSRange(location: location, length: 0))
                Task { @MainActor in context.coordinator.updateHeight() }
            }
        }
        let font = ThemeTypeface.nsFont(size: pointSize)
        if textView.font?.fontName != font.fontName || textView.font?.pointSize != pointSize {
            let selection = textView.selectedRanges
            textView.font = font
            if textView.mentionResolver != nil, let storage = textView.textStorage {
                let accent = Chrome.accentNSColor
                FileMentionText.relabel(storage, font: font, accent: accent)
                textView.syncMentionRelabelState(font: font, accent: accent)
            }
            textView.setSelectedRanges(selection, affinity: textView.selectionAffinity, stillSelecting: false)
            textView.needsDisplay = true
            Task { @MainActor in context.coordinator.updateHeight() }
        }
        if textView.placeholder != placeholder || textView.placeholderHint != placeholderHint {
            textView.placeholder = placeholder
            textView.placeholderHint = placeholderHint
            Task { @MainActor in context.coordinator.updateHeight() }
        }
        // The caret follows the theme's accent; a theme change never rebuilds the view.
        let caret = Chrome.accentNSColor
        if textView.insertionPointColor != caret {
            textView.insertionPointColor = caret
            if textView.mentionResolver != nil, let storage = textView.textStorage {
                let activeFont = textView.activeFont
                FileMentionText.relabel(storage, font: activeFont, accent: caret)
                textView.syncMentionRelabelState(font: activeFont, accent: caret)
                textView.needsDisplay = true
            }
        }
        if !textView.hasMarkedText(), textView.modelText != text {
            textView.setModelText(text)
            let end = textView.textStorage?.length ?? (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.stripMentionTypingAttributes()
            Task { @MainActor in context.coordinator.updateHeight() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        private var cursorNotifyPending = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func cancelPendingCursorChange() {
            cursorNotifyPending = false
        }

        private func scheduleCursorChange() {
            guard !cursorNotifyPending else { return }
            cursorNotifyPending = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.cursorNotifyPending, let textView = self.textView else { return }
                    self.cursorNotifyPending = false
                    self.parent.onCursorChange(textView.modelCursorLocation)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.modelText
            textView.relabelMentionsIfNeeded()
            updateHeight()
            scheduleCursorChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.stripMentionTypingAttributes()
            scheduleCursorChange()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if flags.contains(.command) {
                    return parent.onKey(.steer)
                }
                return parent.onKey(.submit)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.down)
            case #selector(NSResponder.moveRight(_:)):
                return textView.string.isEmpty ? parent.onKey(.right) : false
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.selectedRange() == NSRange(location: 0, length: 0) {
                    return parent.onKey(.deleteAtStart)
                }
                return false
            default:
                return false
            }
        }

        func updateHeight() {
            guard let textView, textView.bounds.width > 24 else { return }
            var contentHeight: CGFloat = 18
            if let layoutManager = textView.textLayoutManager {
                layoutManager.ensureLayout(for: layoutManager.documentRange)
                contentHeight = layoutManager.usageBoundsForTextContainer.height
            } else if let layoutManager = textView.layoutManager, let container = textView.textContainer {
                // ComposerNSTextView overrides draw(_:) for the placeholder, and AppKit
                // answers any draw override by falling back to TextKit 1. With no
                // textLayoutManager the height stayed at the one-line default, so the
                // pill never grew.
                layoutManager.ensureLayout(for: container)
                contentHeight = layoutManager.usedRect(for: container).height
            }
            contentHeight = max(contentHeight, textView.placeholderHeight())
            let total = ceil(max(TypeScale.shared.content(18), contentHeight) + textView.textContainerInset.height * 2)
            if abs(parent.height - total) > 0.5 { parent.height = total }
        }
    }
}
