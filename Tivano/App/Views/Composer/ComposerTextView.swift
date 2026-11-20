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
        storage.replaceCharacters(in: viewRange, with: attributedReplacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: viewRange.location + attributedReplacement.length, length: 0))
        textView.stripMentionTypingAttributes()
    }

    /// Shows the slash/@ suggestions directly above the caret. A SwiftUI
    /// `.popover` anchors to the whole composer bubble, so it lands centered
    /// (or flipped to the side) instead of where the user is typing.
    func showSuggestions(_ content: AnyView, itemCount: Int) {
        let popover: NSPopover
        if let existing = suggestionPopover {
            popover = existing
        } else {
            popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = true
            suggestionPopover = popover
        }
        guard let textView = textView, textView.window != nil else { return }
        // Fixed width matching the old menu; height fits the rows so the
        // ScrollView inside never needs to scroll for the capped item count.
        // The host never publishes its own size (see setFixedContent), so this
        // is the only size the panel is ever positioned against and it stays
        // on the caret while the list changes under typing.
        let size = NSSize(width: 340, height: min(340, 44 + CGFloat(max(itemCount, 1)) * TypeScale.shared.ui(26)))
        let sized = AnyView(content.frame(width: size.width, height: size.height).presentedChrome())
        if let host = suggestionHost {
            host.rootView = sized
        } else {
            let host = NSHostingController(rootView: sized)
            host.sizingOptions = []
            suggestionHost = host
            popover.contentViewController = host
        }
        popover.contentSize = size
        popover.show(relativeTo: caretRect(in: textView), of: textView, preferredEdge: .maxY)
        // The popover must never steal typing focus.
        textView.window?.makeFirstResponder(textView)
    }

    func hideSuggestions() {
        suggestionPopover?.performClose(nil)
    }

    func tearDownSuggestions() {
        suggestionRefresh?.cancel()
        suggestionRefresh = nil
        suggestionPopover?.close()
        suggestionPopover?.contentViewController = nil
        suggestionHost = nil
        suggestionPopover = nil
    }

    /// True when the current click landed inside the suggestions popover,
    /// so losing text focus to pick a row must not dismiss the list first.
    func isClickInsideSuggestions() -> Bool {
        guard let popover = suggestionPopover, popover.isShown,
              let window = suggestionHost?.view.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
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
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var placeholderHint = "" { didSet { needsDisplay = true } }
    var onAttach: (([AttachmentSource]) -> Void)?
    var onWidthChange: (() -> Void)?
    var onResign: (@MainActor () -> Void)?
    var mentionResolver: ((String) -> Bool?)?
    var mentionRoot: String?

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

    fileprivate func setModelText(_ text: String) {
        guard let resolver = mentionResolver, let storage = textStorage else {
            string = text
            return
        }
        let baseFont = activeFont
        let attributed = FileMentionText.attributed(
            from: text,
            attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor],
            font: baseFont,
            accent: Chrome.accentNSColor,
            resolve: resolver
        )
        storage.beginEditing()
        storage.setAttributedString(attributed)
        storage.endEditing()
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
        if widthChanged { onWidthChange?() }
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

    private var placeholderAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        return [
            .font: font ?? ThemeTypeface.nsFont(size: TypeScale.shared.content(14)),
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private var attributedPlaceholder: NSAttributedString {
        let attributes = placeholderAttributes
        guard !placeholderHint.isEmpty else { return NSAttributedString(string: placeholder, attributes: attributes) }
        let placeholderFont = font ?? ThemeTypeface.nsFont(size: TypeScale.shared.content(14))
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
        let rect = placeholderRect
        func fits(_ text: NSAttributedString) -> Bool {
            text.boundingRect(with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin]).height <= rect.height + 0.5
        }
        let full = composed(placeholder)
        guard rect.width > 0, !fits(full) else { return full }
        let characters = Array(placeholder)
        var low = 0, high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(composed(String(characters[..<mid]) + "…")) { low = mid } else { high = mid - 1 }
        }
        return composed(String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…")
    }

    private var placeholderRect: NSRect {
        let placeholderFont = font ?? ThemeTypeface.nsFont(size: TypeScale.shared.content(14))
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
        let rect = placeholderRect
        let measured = attributedPlaceholder.boundingRect(
            with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        return min(measured.height, rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        placeholderShown = string.isEmpty && !placeholder.isEmpty
        guard placeholderShown else { return }
        let rect = placeholderRect
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        attributedPlaceholder.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
                FileMentionText.relabel(storage, font: font, accent: Chrome.accentNSColor)
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
                FileMentionText.relabel(storage, font: textView.activeFont, accent: caret)
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
            if textView.mentionResolver != nil,
               let storage = textView.textStorage,
               storage.string.utf16.contains(0xFFFC) {
                FileMentionText.relabel(storage, font: textView.activeFont, accent: Chrome.accentNSColor)
            }
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
