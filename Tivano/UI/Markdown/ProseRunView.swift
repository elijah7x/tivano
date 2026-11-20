import AppKit
import SwiftUI

struct ProseRunView: View, Equatable {
    let blocks: [MarkdownBlock]
    @Environment(\.markdownPointSize) private var pointSize
    @Environment(\.markdownDimmed) private var dimmed
    @Environment(\.hydraMentionPersonas) private var hydraMentionPersonas
    @Environment(\.hydraMentionTargets) private var hydraMentionTargets
    @Environment(\.markdownLinkBase) private var markdownLinkBase
    @Environment(\.openURL) private var openURL
    @State private var linkView = WeakView()
    @State private var showsHand = false
    @State private var hoveredHeadID: UUID?
    @State private var faviconRevision = 0

    nonisolated static func == (lhs: ProseRunView, rhs: ProseRunView) -> Bool {
        lhs.blocks == rhs.blocks
    }

    var body: some View {
        let resolvedSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        let scaled = (resolvedSize * 2).rounded() / 2
        let prepared = ProseRunRepresentable.prepare(
            blocks: blocks,
            pointSize: scaled,
            dimmed: dimmed,
            mentions: hydraMentionPersonas,
            targets: hydraMentionTargets
        )
        let linkBox = linkView
        let targets = hydraMentionTargets
        ProseRunRepresentable(
            blocks: blocks,
            pointSize: scaled,
            dimmed: dimmed,
            revision: faviconRevision,
            mentions: hydraMentionPersonas,
            targets: hydraMentionTargets,
            linkBase: markdownLinkBase,
            preparedAttributed: prepared.attributed,
            onOpenHead: { url in openURL(url) },
            onHost: { [weak linkBox] view in linkBox?.value = view }
        )
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LinkHoverModifier(linkView: linkBox, showsHand: $showsHand, hoveredHeadID: $hoveredHeadID, personas: hydraMentionPersonas, targets: targets))
            .task(id: prepared.needsAssetFetch ? prepared.linkKey : "") { [blocks, needsFetch = prepared.needsAssetFetch, revision = $faviconRevision] in
                guard needsFetch else { return }
                let sources = ProseRunRepresentable.inlineSources(blocks)
                await InlineText.fetchLinkAssets(sources: sources, streamingLast: false, revision: revision)
            }
    }
}

struct ProseRunRepresentable: NSViewRepresentable {
    struct PreparedProseRun {
        let attributed: NSAttributedString
        let linkKey: String
        let hosts: [String]
        let videos: [String]
        let needsAssetFetch: Bool
    }

    private struct CacheKey: Hashable {
        let blocks: [MarkdownBlock]
        let pointSize: CGFloat
        let dimmed: Bool
        let serif: Bool
        let uiScale: Int
        let contentScale: Int
        let codeScale: Int
        let mentions: [HydraPersona]
        let targetURLs: [String: URL]
        let assetGeneration: Int
    }

    @MainActor private static var preparedCache = RecentCache<CacheKey, PreparedProseRun>(
        limit: 1024,
        costLimit: 24 * 1024 * 1024,
        entryCostLimit: 2 * 1024 * 1024
    )

    @MainActor
    static func clearCache() {
        preparedCache = RecentCache<CacheKey, PreparedProseRun>(
            limit: 1024,
            costLimit: 24 * 1024 * 1024,
            entryCostLimit: 2 * 1024 * 1024
        )
    }

    #if DEBUG
    @MainActor static var debugZeroHeightMarker: String?
    @MainActor static var debugZeroHeightUntil = Date.distantPast
    #endif

    let blocks: [MarkdownBlock]
    var pointSize: CGFloat = TypeScale.shared.content(13)
    var codePointSize: CGFloat = TypeScale.shared.code(12)
    var serif: Bool = TypeScale.shared.serif
    var dimmed: Bool = false
    var revision: Int = 0
    var mentions: [HydraPersona] = []
    var targets: [String: HydraMentionTarget] = [:]
    var linkBase: String? = nil
    var preparedAttributed: NSAttributedString? = nil
    var onOpenHead: ((URL) -> Void)?
    var onHost: ((LinkTextView) -> Void)?

    func makeCoordinator() -> LinkParagraphView.Coordinator {
        LinkParagraphView.Coordinator()
    }

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView()
        let base = linkBase ?? context.environment.markdownLinkBase
        context.coordinator.linkBase = base
        view.delegate = context.coordinator
        view.passesProseThrough = false
        onHost?(view)
        view.linkBase = base
        view.mergeTarget = context.environment.mergeRequestTarget
        view.selectionOwner = context.environment.markdownSelectionOwner
        return view
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        _ = revision
        let coordinator = context.coordinator
        let mentionNames = mentions.map(\.name)
        let headLinks = targets.mapValues(\.url)
        if coordinator.lastBlocks != blocks || coordinator.lastPointSize != pointSize
            || coordinator.lastCodePointSize != codePointSize || coordinator.lastSerif != serif
            || coordinator.lastDimmed != dimmed || coordinator.lastRevision != revision
            || coordinator.lastMentions != mentionNames || coordinator.lastHeads != headLinks {
            coordinator.lastBlocks = blocks
            coordinator.lastPointSize = pointSize
            coordinator.lastCodePointSize = codePointSize
            coordinator.lastSerif = serif
            coordinator.lastDimmed = dimmed
            coordinator.lastRevision = revision
            coordinator.lastMentions = mentionNames
            coordinator.lastHeads = headLinks
            view.render(preparedAttributed ?? Self.attributed(blocks: blocks, pointSize: pointSize, dimmed: dimmed, mentions: mentions, targets: targets))
        }
        // Outside the render check: handlers and selection ownership must land even
        // on an update that drew nothing.
        let base = linkBase ?? context.environment.markdownLinkBase
        coordinator.linkBase = base
        view.linkBase = base
        view.onOpenHead = onOpenHead
        view.mergeTarget = context.environment.mergeRequestTarget
        view.selectionOwner = context.environment.markdownSelectionOwner
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkTextView, context: Context) -> CGSize? {
        #if DEBUG
        // Models SwiftUI receiving a zero height during the fold and not being asked again.
        if let marker = Self.debugZeroHeightMarker,
           Date.now < Self.debugZeroHeightUntil,
           nsView.textStorage?.string.contains(marker) == true {
            if let width = proposal.width, width > 0, width.isFinite { nsView.noteReportedHeight(0, forWidth: width) }
            return CGSize(width: proposal.width ?? 0, height: 0)
        }
        #endif
        guard let width = proposal.width else { return nil }
        guard width > 0 else { return .zero }
        guard width.isFinite else { return CGSize(width: width, height: nsView.cachedHeightHint) }
        let height = nsView.height(forWidth: width)
        // The text view checks this against its text later (see `LinkTextView` height heal).
        nsView.noteReportedHeight(height, forWidth: width)
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: LinkTextView, coordinator: LinkParagraphView.Coordinator) {
        view.delegate = nil
        view.onOpenHead = nil
        view.linkBase = nil
        view.mergeTarget = nil
        view.selectionOwner = nil
    }

    static func inlineSources(_ blocks: [MarkdownBlock]) -> [String] {
        var parts: [String] = []
        collect(blocks, into: &parts)
        return parts
    }

    private static func collect(_ blocks: [MarkdownBlock], into parts: inout [String]) {
        for block in blocks {
            switch block {
            case .paragraph(let text), .heading(_, let text):
                parts.append(text)
            case .list(_, _, let items):
                for item in items {
                    if !item.text.isEmpty { parts.append(item.text) }
                    collect(item.children, into: &parts)
                }
            case .quote(let inner):
                collect(inner, into: &parts)
            case .code, .table, .image, .rule:
                break
            }
        }
    }

    @MainActor
    static func prepare(blocks: [MarkdownBlock], pointSize: CGFloat, dimmed: Bool, mentions: [HydraPersona], targets: [String: HydraMentionTarget] = [:]) -> PreparedProseRun {
        RichLink.armMemoryPressure()
        let key = CacheKey(
            blocks: blocks,
            pointSize: pointSize,
            dimmed: dimmed,
            serif: TypeScale.shared.serif,
            uiScale: TypeScale.shared.ui,
            contentScale: TypeScale.shared.content,
            codeScale: TypeScale.shared.code,
            mentions: mentions,
            targetURLs: targets.mapValues(\.url),
            assetGeneration: RichLink.assetGeneration
        )
        if let hit = preparedCache.value(for: key) {
            if !hit.needsAssetFetch { return hit }
            let stillNeedsFetch = hit.hosts.contains(where: { FaviconCache.needsFetch(host: $0) })
                || hit.videos.contains(where: { LinkTitles.needsFetch(videoID: $0) })
            if stillNeedsFetch { return hit }
            let updated = PreparedProseRun(
                attributed: hit.attributed,
                linkKey: hit.linkKey,
                hosts: hit.hosts,
                videos: hit.videos,
                needsAssetFetch: false
            )
            preparedCache.insert(updated, for: key, cost: max(64, updated.attributed.length * 4))
            return updated
        }
        let sources = inlineSources(blocks)
        let plan = RichLink.linkAssetDetails(forEach: sources)
        let built = NSMutableAttributedString()
        for block in blocks {
            Self.append(block, depth: 0, indent: 0, dimmed: dimmed, afterSpacing: TypeScale.proseParagraphSpacing(pointSize), pointSize: pointSize, mentions: mentions, targets: targets, to: built)
        }
        let frozen = NSAttributedString(attributedString: built)
        let prepared = PreparedProseRun(
            attributed: frozen,
            linkKey: plan.key,
            hosts: plan.hosts,
            videos: plan.videos,
            needsAssetFetch: plan.needsFetch
        )
        preparedCache.insert(prepared, for: key, cost: max(64, frozen.length * 4))
        return prepared
    }

    @MainActor
    static func attributed(blocks: [MarkdownBlock], pointSize: CGFloat, dimmed: Bool, mentions: [HydraPersona], targets: [String: HydraMentionTarget] = [:]) -> NSAttributedString {
        prepare(blocks: blocks, pointSize: pointSize, dimmed: dimmed, mentions: mentions, targets: targets).attributed
    }

    @MainActor
    static func append(_ block: MarkdownBlock, depth: Int, indent: CGFloat, dimmed: Bool, afterSpacing: CGFloat, pointSize: CGFloat, mentions: [HydraPersona], targets: [String: HydraMentionTarget], to out: NSMutableAttributedString) {
        let base = ThemeTypeface.nsFont(size: pointSize)
        let color = dimmed ? LinkParagraphView.dimmedLabel : NSColor.labelColor
        // One text view holds the whole run, so the line spacing also falls between its
        // paragraphs; each gap gives it back to stay the SwiftUI blocks' own spacing.
        let lineSpacing = TypeScale.proseLineSpacing(pointSize)
        let codePointSize = TypeScale.shared.code(max(9, pointSize - CGFloat(TypeScale.shared.content - TypeScale.stockContent) - 1))
        switch block {
        case .paragraph(let text):
            separate(to: out, font: base, color: color)
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacing = max(0, afterSpacing - lineSpacing)
            style.lineSpacing = lineSpacing
            let line = LinkParagraphView.mutableAttributed(source: text, pointSize: pointSize, codePointSize: codePointSize, dimmed: dimmed, mentions: mentions, targets: targets, paragraphStyle: style)
            out.append(line)
        case .heading(let level, let text):
            let hasPrior = out.length > 0
            separate(to: out, font: base, color: color)
            let size = TypeScale.proseHeadingPointSize(pointSize, level: level)
            let headingLeading = TypeScale.proseHeadingLineSpacing(size)
            let contentDelta = CGFloat(TypeScale.shared.content - TypeScale.stockContent)
            let headingStockSize = size - contentDelta
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacingBefore = hasPrior ? TypeScale.proseHeadingTopExtra(pointSize, level: level) : 0
            style.paragraphSpacing = max(0, TypeScale.proseHeadingBottomSpacing(pointSize, level: level) - headingLeading)
            style.lineSpacing = headingLeading
            let line = LinkParagraphView.mutableAttributed(source: text, pointSize: size, codePointSize: TypeScale.shared.code(max(9, headingStockSize - 1)), dimmed: dimmed, mentions: mentions, targets: targets, paragraphStyle: style)
            let semibold = ThemeTypeface.nsFont(size: size, weight: .semibold)
            line.enumerateAttribute(.font, in: NSRange(location: 0, length: line.length), options: []) { value, range, _ in
                guard let font = value as? NSFont else { return }
                let traits = font.fontDescriptor.symbolicTraits
                if !traits.contains(.bold) && !traits.contains(.monoSpace) {
                    line.addAttribute(.font, value: semibold, range: range)
                }
            }
            out.append(line)
        case .list(let ordered, let start, let items):
            let metrics = TypeScale.proseListMetrics(pointSize: pointSize, ordered: ordered, start: start, count: items.count)
            let markerColor = dimmed ? LinkParagraphView.dimmedLabel : NSColor.secondaryLabelColor
            for (index, item) in items.enumerated() {
                separate(to: out, font: base, color: color)
                let isLastItem = (index == items.count - 1)
                let itemAfterSpacing = isLastItem ? afterSpacing : (!item.children.isEmpty && depth == 0 ? TypeScale.proseListGroupSpacing(pointSize) : TypeScale.proseListItemSpacing(pointSize, depth: depth))
                let marker: String
                let markerFont: NSFont
                if let checked = item.checked {
                    marker = checked ? "☑" : "☐"
                    markerFont = base
                } else if ordered {
                    marker = "\(start + index)."
                    markerFont = ThemeTypeface.monospacedDigitNSFont(size: pointSize, weight: .medium)
                } else {
                    marker = depth == 0 ? "•" : "◦"
                    markerFont = base
                }
                let markerWidth = ceil((marker as NSString).size(withAttributes: [.font: markerFont]).width)
                let slot = max(metrics.slotWidth, markerWidth)
                let step = slot + metrics.gap
                let firstIndent = (ordered && item.checked == nil)
                    ? (indent + max(0, slot - markerWidth))
                    : (indent + max(0, ((slot - markerWidth) * 0.5).rounded()))
                let bodyIndent = indent + step
                let line = NSMutableAttributedString(string: marker + "\t", attributes: [
                    .font: markerFont,
                    .foregroundColor: markerColor,
                ])
                if !item.text.isEmpty {
                    line.append(LinkParagraphView.mutableAttributed(source: item.text, pointSize: pointSize, codePointSize: codePointSize, dimmed: dimmed, mentions: mentions, targets: targets, paragraphStyle: nil))
                }
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = firstIndent
                style.headIndent = bodyIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: bodyIndent)]
                style.defaultTabInterval = max(28, step)
                style.lineSpacing = lineSpacing
                if item.children.isEmpty {
                    style.paragraphSpacing = max(0, itemAfterSpacing - lineSpacing)
                    line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                    out.append(line)
                } else {
                    let childGap = TypeScale.proseListChildSpacing(pointSize)
                    style.paragraphSpacing = max(0, childGap - lineSpacing)
                    line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                    out.append(line)
                    for (childIndex, child) in item.children.enumerated() {
                        let childAfter = (childIndex == item.children.count - 1) ? itemAfterSpacing : childGap
                        append(child, depth: depth + 1, indent: bodyIndent, dimmed: dimmed, afterSpacing: childAfter, pointSize: pointSize, mentions: mentions, targets: targets, to: out)
                    }
                }
            }
        case .quote(let inner):
            for (childIndex, child) in inner.enumerated() {
                let childAfter = (childIndex == inner.count - 1) ? afterSpacing : TypeScale.proseQuoteSpacing(pointSize)
                append(child, depth: depth, indent: indent + TypeScale.proseQuoteSpacing(pointSize), dimmed: true, afterSpacing: childAfter, pointSize: pointSize, mentions: mentions, targets: targets, to: out)
            }
        case .code, .table, .image, .rule:
            break
        }
    }

    @MainActor
    private static func separate(to out: NSMutableAttributedString, font: NSFont, color: NSColor) {
        guard out.length > 0 else { return }
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: font,
            .foregroundColor: color,
        ]))
    }
}

/// AppKit prose run used on the streaming path for plain paragraphs (and merged adjacent
/// plain paragraphs). Completed paragraphs and stabilized inline prefixes are formatted once;
/// each flush only parses the active tail and updates that range in `NSTextStorage`, while
/// `LinkTextVeil` drives the dissolve with layout-manager temporary attributes.
struct StreamingProseRunView: View, Equatable {
    let paragraphs: [String]
    let isStreamingTail: Bool
    var settled = false
    var generation = 0
    @Environment(\.markdownPointSize) private var pointSize
    @Environment(\.markdownDimmed) private var dimmed
    @Environment(\.hydraMentionPersonas) private var hydraMentionPersonas
    @Environment(\.hydraMentionTargets) private var hydraMentionTargets
    @Environment(\.markdownLinkBase) private var markdownLinkBase
    @Environment(\.openURL) private var openURL
    @State private var linkView = WeakView()
    @State private var showsHand = false
    @State private var hoveredHeadID: UUID?
    @State private var faviconRevision = 0

    nonisolated static func == (lhs: StreamingProseRunView, rhs: StreamingProseRunView) -> Bool {
        if lhs.settled, rhs.settled, !lhs.isStreamingTail, !rhs.isStreamingTail, lhs.generation == rhs.generation { return true }
        return lhs.isStreamingTail == rhs.isStreamingTail && lhs.paragraphs == rhs.paragraphs
    }

    var body: some View {
        let resolvedSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        let scaled = (resolvedSize * 2).rounded() / 2
        let codeSize = TypeScale.shared.code(max(9, scaled - CGFloat(TypeScale.shared.content - TypeScale.stockContent) - 1))
        let linkKey = RichLink.linkAssetPlan(forEach: paragraphs, streamingLast: isStreamingTail)
        let linkBox = linkView
        let targets = hydraMentionTargets
        StreamingProseRunRepresentable(
            paragraphs: paragraphs,
            isStreamingTail: isStreamingTail,
            pointSize: scaled,
            codePointSize: codeSize,
            dimmed: dimmed,
            revision: faviconRevision,
            mentions: hydraMentionPersonas,
            targets: hydraMentionTargets,
            linkBase: markdownLinkBase,
            onOpenHead: { url in openURL(url) },
            onHost: { [weak linkBox] view in linkBox?.value = view }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LinkHoverModifier(linkView: linkBox, showsHand: $showsHand, hoveredHeadID: $hoveredHeadID, personas: hydraMentionPersonas, targets: targets))
        .task(id: linkKey.needsFetch ? linkKey.key : "") { [paragraphs, isStreamingTail, needsFetch = linkKey.needsFetch, revision = $faviconRevision] in
            guard needsFetch else { return }
            await InlineText.fetchLinkAssets(sources: paragraphs, streamingLast: isStreamingTail, revision: revision)
        }
    }
}

struct StreamingProseRunRepresentable: NSViewRepresentable {
    let paragraphs: [String]
    let isStreamingTail: Bool
    var pointSize: CGFloat = TypeScale.shared.content(13)
    var codePointSize: CGFloat = TypeScale.shared.code(12)
    var serif: Bool = TypeScale.shared.serif
    var dimmed: Bool = false
    var revision: Int = 0
    var mentions: [HydraPersona] = []
    var targets: [String: HydraMentionTarget] = [:]
    var linkBase: String? = nil
    var onOpenHead: ((URL) -> Void)?
    var onHost: ((LinkTextView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView()
        let base = linkBase ?? context.environment.markdownLinkBase
        let selectable = context.environment.markdownBlockSelection
        context.coordinator.linkBase = base
        view.delegate = context.coordinator
        view.isSelectable = selectable
        view.passesProseThrough = !selectable
        onHost?(view)
        view.linkBase = base
        view.mergeTarget = context.environment.mergeRequestTarget
        view.selectionOwner = context.environment.markdownSelectionOwner
        return view
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        _ = revision
        let coordinator = context.coordinator
        let selectable = context.environment.markdownBlockSelection
        view.isSelectable = selectable
        view.passesProseThrough = !selectable
        let veiled = context.environment.markdownVeiled
        let scope = context.environment.veilRenderScope
        let mentionNames = mentions.map(\.name)
        let headLinks = targets.mapValues(\.url)
        var rendered = false
        if coordinator.lastParagraphs.count != paragraphs.count
            || coordinator.lastParagraphs.last != paragraphs.last
            || coordinator.lastParagraphs != paragraphs
            || coordinator.lastStreamingTail != isStreamingTail
            || coordinator.lastPointSize != pointSize || coordinator.lastCodePointSize != codePointSize
            || coordinator.lastSerif != serif
            || coordinator.lastDimmed != dimmed || coordinator.lastRevision != revision
            || coordinator.lastMentions != mentionNames || coordinator.lastHeads != headLinks {
            coordinator.lastParagraphs = paragraphs
            coordinator.lastStreamingTail = isStreamingTail
            coordinator.lastPointSize = pointSize
            coordinator.lastCodePointSize = codePointSize
            coordinator.lastSerif = serif
            coordinator.lastDimmed = dimmed
            coordinator.lastRevision = revision
            coordinator.lastMentions = mentionNames
            coordinator.lastHeads = headLinks
            var renderedTail = false
            if let (offset, tail) = coordinator.buildStreamingTail(
                paragraphs: paragraphs,
                isStreamingTail: isStreamingTail,
                pointSize: pointSize,
                codePointSize: codePointSize,
                dimmed: dimmed,
                revision: revision,
                mentions: mentions,
                mentionNames: mentionNames,
                targets: targets,
                headLinks: headLinks,
                width: view.bounds.width
            ) {
                Self.preserveExistingAttachments(in: tail, from: view.textStorage, at: offset)
                renderedTail = view.replaceStreamingTail(from: offset, with: tail)
            }
            if !renderedTail {
                let built = coordinator.buildAttributed(
                    paragraphs: paragraphs,
                    isStreamingTail: isStreamingTail,
                    pointSize: pointSize,
                    codePointSize: codePointSize,
                    dimmed: dimmed,
                    revision: revision,
                    mentions: mentions,
                    mentionNames: mentionNames,
                    targets: targets,
                    headLinks: headLinks,
                    width: view.bounds.width
                )
                Self.preserveExistingAttachments(in: built, from: view.textStorage, after: coordinator.reusedPrefixLength)
                view.render(built)
            }
            rendered = true
        }
        if rendered || coordinator.lastVeiled != veiled || coordinator.lastRenderScope !== scope {
            coordinator.lastVeiled = veiled
            coordinator.lastRenderScope = scope
            view.streamVeil.update(view, active: veiled, scope: scope)
        }
        let base = linkBase ?? context.environment.markdownLinkBase
        coordinator.linkBase = base
        view.linkBase = base
        view.onOpenHead = onOpenHead
        view.mergeTarget = context.environment.mergeRequestTarget
        view.selectionOwner = context.environment.markdownSelectionOwner
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        guard width > 0 else { return .zero }
        guard width.isFinite else { return CGSize(width: width, height: nsView.cachedHeightHint) }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }

    static func dismantleNSView(_ view: LinkTextView, coordinator: Coordinator) {
        view.delegate = nil
        view.onOpenHead = nil
        view.linkBase = nil
        view.mergeTarget = nil
        view.selectionOwner = nil
        view.streamVeil.detach(view)
    }

    /// Reuses `NSTextAttachment` instances already sitting in `storage` across the newly
    /// rebuilt tail overlap so `NSAttributedString.isEqual(to:)` stays true and `render`
    /// hits `NSTextStorage.append` when a favicon or persona glyph sits in the active tail.
    @MainActor
    private static func preserveExistingAttachments(in built: NSMutableAttributedString, from storage: NSTextStorage?, after start: Int) {
        guard let storage else { return }
        let count = storage.length
        guard count > 0, built.length >= count, start < count,
              built.string.utf16.starts(with: storage.string.utf16) else { return }
        let overlap = NSRange(location: max(0, start), length: count - max(0, start))
        guard overlap.length > 0 else { return }
        storage.enumerateAttribute(.attachment, in: overlap, options: []) { value, range, _ in
            guard range.length == 1,
                  let existing = value as? NSTextAttachment,
                  let replacement = built.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                  existing !== replacement,
                  existing.image === replacement.image,
                  existing.bounds == replacement.bounds else { return }
            built.addAttribute(.attachment, value: existing, range: range)
        }
    }

    @MainActor
    private static func preserveExistingAttachments(in tail: NSMutableAttributedString, from storage: NSTextStorage?, at start: Int) {
        guard let storage, start >= 0, start < storage.length else { return }
        let oldTailLength = storage.length - start
        guard tail.length >= oldTailLength,
              tail.string.utf16.starts(with: storage.string.utf16.dropFirst(start)) else { return }
        let overlap = NSRange(location: start, length: oldTailLength)
        storage.enumerateAttribute(.attachment, in: overlap, options: []) { value, range, _ in
            let relative = NSRange(location: range.location - start, length: range.length)
            guard range.length == 1,
                  let existing = value as? NSTextAttachment,
                  let replacement = tail.attribute(.attachment, at: relative.location, effectiveRange: nil) as? NSTextAttachment,
                  existing !== replacement,
                  existing.image === replacement.image,
                  existing.bounds == replacement.bounds else { return }
            tail.addAttribute(.attachment, value: existing, range: relative)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var lastRenderScope: VeilRenderScope?
        var lastParagraphs: [String] = []
        var lastStreamingTail = false
        var lastPointSize: CGFloat = 0
        var lastCodePointSize: CGFloat = 0
        var lastSerif = false
        var lastDimmed = false
        var lastRevision = 0
        var lastVeiled = false
        var lastMentions: [String] = []
        var lastHeads: [String: URL] = [:]
        var linkBase: String?

        private var stylePointSize: CGFloat = 0
        private var styleCodePointSize: CGFloat = 0
        private var styleSerif = false
        private var styleDimmed = false
        private var styleRevision = 0
        private var styleMentions: [String] = []
        private var styleHeads: [String: URL] = [:]

        private var completedSources: [String] = []
        private var completedAttributed = NSMutableAttributedString()
        private var activeSource = ""
        private var stableUTF8Count = 0
        private var stableAttributed = NSMutableAttributedString()
        private var activeUTF16Offset: Int?
        private var renderedWidth: CGFloat?
        private var hasRendered = false
        private(set) var reusedPrefixLength = 0

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                MarkdownLinkOpener.open(url, base: linkBase)
                return true
            }
            if let string = link as? String, let url = URL(string: string) {
                MarkdownLinkOpener.open(url, base: linkBase)
                return true
            }
            return false
        }

        @MainActor
        func buildStreamingTail(
            paragraphs: [String],
            isStreamingTail: Bool,
            pointSize: CGFloat,
            codePointSize: CGFloat,
            dimmed: Bool,
            revision: Int,
            mentions: [HydraPersona],
            mentionNames: [String],
            targets: [String: HydraMentionTarget],
            headLinks: [String: URL],
            width: CGFloat
        ) -> (offset: Int, text: NSMutableAttributedString)? {
            guard hasRendered, renderedWidth == width,
                  stylePointSize == pointSize, styleCodePointSize == codePointSize,
                  styleSerif == TypeScale.shared.serif, styleDimmed == dimmed,
                  styleRevision == revision, styleMentions == mentionNames, styleHeads == headLinks,
                  paragraphs.count == completedSources.count + 1,
                  let last = paragraphs.last,
                  last.utf8.starts(with: activeSource.utf8),
                  completedSources.elementsEqual(paragraphs.prefix(completedSources.count)),
                  let offset = activeUTF16Offset else { return nil }
            let lineSpacing = TypeScale.proseLineSpacing(pointSize)
            let paragraphSpacing = max(0, TypeScale.proseParagraphSpacing(pointSize) - lineSpacing)
            let style = LinkParagraphView.sharedParagraphStyle(lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing)
            let out = NSMutableAttributedString(attributedString: stableAttributed)
            let tail = stableUTF8Count == 0 ? last : String(decoding: last.utf8.dropFirst(stableUTF8Count), as: UTF8.self)
            if !tail.isEmpty {
                out.append(Self.formatFixed(tail, pointSize: pointSize, codePointSize: codePointSize, dimmed: dimmed, streaming: isStreamingTail, mentions: mentions, targets: targets, style: style))
            }
            activeSource = last
            return (offset, out)
        }

        @MainActor
        func buildAttributed(
            paragraphs: [String],
            isStreamingTail: Bool,
            pointSize: CGFloat,
            codePointSize: CGFloat,
            dimmed: Bool,
            revision: Int,
            mentions: [HydraPersona],
            mentionNames: [String],
            targets: [String: HydraMentionTarget],
            headLinks: [String: URL],
            width: CGFloat
        ) -> NSMutableAttributedString {
            if stylePointSize != pointSize || styleCodePointSize != codePointSize
                || styleSerif != TypeScale.shared.serif
                || styleDimmed != dimmed || styleRevision != revision
                || styleMentions != mentionNames || styleHeads != headLinks {
                stylePointSize = pointSize
                styleCodePointSize = codePointSize
                styleSerif = TypeScale.shared.serif
                styleDimmed = dimmed
                styleRevision = revision
                styleMentions = mentionNames
                styleHeads = headLinks
                resetCaches()
            }
            guard let last = paragraphs.last else {
                resetCaches()
                reusedPrefixLength = 0
                return NSMutableAttributedString()
            }
            let lineSpacing = TypeScale.proseLineSpacing(pointSize)
            let paragraphSpacing = max(0, TypeScale.proseParagraphSpacing(pointSize) - lineSpacing)
            let style = LinkParagraphView.sharedParagraphStyle(lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing)
            let baseFont = ThemeTypeface.nsFont(size: pointSize)
            let textColor = dimmed ? LinkParagraphView.dimmedLabel : NSColor.labelColor
            let separatorAttributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: textColor,
                .paragraphStyle: style,
            ]

            let prior = paragraphs.dropLast()
            if !prior.starts(with: completedSources) {
                resetCaches()
            }
            if completedSources.count < prior.count {
                for index in completedSources.count..<prior.count {
                    let source = prior[index]
                    if completedAttributed.length > 0 {
                        let sepStart = max(0, completedAttributed.length - 1)
                        completedAttributed.append(NSAttributedString(string: "\n", attributes: separatorAttributes))
                        completedAttributed.fixAttributes(in: NSRange(location: sepStart, length: completedAttributed.length - sepStart))
                    }
                    if index == completedSources.count, !activeSource.isEmpty, stableUTF8Count > 0,
                       source.utf8.starts(with: activeSource.utf8.prefix(stableUTF8Count)) {
                        completedAttributed.append(stableAttributed)
                        let rest = String(decoding: source.utf8.dropFirst(stableUTF8Count), as: UTF8.self)
                        if !rest.isEmpty {
                            let piece = Self.formatFixed(rest, pointSize: pointSize, codePointSize: codePointSize, dimmed: dimmed, streaming: false, mentions: mentions, targets: targets, style: style)
                            completedAttributed.append(piece)
                        }
                        activeSource = ""
                        stableUTF8Count = 0
                        stableAttributed = NSMutableAttributedString()
                    } else {
                        let piece = Self.formatFixed(source, pointSize: pointSize, codePointSize: codePointSize, dimmed: dimmed, streaming: false, mentions: mentions, targets: targets, style: style)
                        completedAttributed.append(piece)
                        activeSource = ""
                        stableUTF8Count = 0
                        stableAttributed = NSMutableAttributedString()
                    }
                }
                completedSources = Array(prior)
            }

            if !last.utf8.starts(with: activeSource.utf8) {
                activeSource = ""
                stableUTF8Count = 0
                stableAttributed = NSMutableAttributedString()
            }
            activeSource = last
            // The growing paragraph is re-formatted whole on every flush: cutting it mid-way
            // splits inline syntax (CJK-adjacent emphasis, strikethrough, titled links) into halves
            // that never heal. Only completed paragraphs are frozen.

            let out = NSMutableAttributedString(attributedString: completedAttributed)
            if out.length > 0 {
                let sepStart = max(0, out.length - 1)
                out.append(NSAttributedString(string: "\n", attributes: separatorAttributes))
                out.fixAttributes(in: NSRange(location: sepStart, length: out.length - sepStart))
            }
            let activeOffset = out.length
            out.append(stableAttributed)
            reusedPrefixLength = out.length

            let tail = stableUTF8Count == 0 ? last : String(decoding: last.utf8.dropFirst(stableUTF8Count), as: UTF8.self)
            if !tail.isEmpty {
                let tailPiece = Self.formatFixed(tail, pointSize: pointSize, codePointSize: codePointSize, dimmed: dimmed, streaming: isStreamingTail, mentions: mentions, targets: targets, style: style)
                out.append(tailPiece)
            }
            activeUTF16Offset = activeOffset
            renderedWidth = width
            hasRendered = true
            return out
        }

        private func resetCaches() {
            completedSources = []
            completedAttributed = NSMutableAttributedString()
            activeSource = ""
            stableUTF8Count = 0
            stableAttributed = NSMutableAttributedString()
            activeUTF16Offset = nil
            renderedWidth = nil
            hasRendered = false
        }

        @MainActor
        private static func formatFixed(
            _ source: String,
            pointSize: CGFloat,
            codePointSize: CGFloat,
            dimmed: Bool,
            streaming: Bool,
            mentions: [HydraPersona],
            targets: [String: HydraMentionTarget],
            style: NSParagraphStyle
        ) -> NSMutableAttributedString {
            let piece = LinkParagraphView.mutableAttributed(
                source: source,
                pointSize: pointSize,
                codePointSize: codePointSize,
                dimmed: dimmed,
                streaming: streaming,
                mentions: mentions,
                targets: targets,
                paragraphStyle: style
            )
            if piece.length > 0 {
                piece.fixAttributes(in: NSRange(location: 0, length: piece.length))
            }
            return piece
        }
    }
}
