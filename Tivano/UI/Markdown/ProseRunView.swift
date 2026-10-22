import AppKit
import SwiftUI

struct ProseRunView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.markdownPointSize) private var pointSize
    @Environment(\.markdownDimmed) private var dimmed
    @Environment(\.hydraMentionPersonas) private var hydraMentionPersonas
    @Environment(\.hydraMentionTargets) private var hydraMentionTargets
    @Environment(\.openURL) private var openURL
    @State private var linkView = WeakView()
    @State private var showsHand = false
    @State private var hoveredHeadID: UUID?
    @State private var faviconRevision = 0

    var body: some View {
        let resolvedSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        let scaled = (resolvedSize * 2).rounded() / 2
        let sources = ProseRunRepresentable.joinedSources(blocks)
        let linkKey = RichLink.linkAssetKey(for: sources)
        let linkBox = linkView
        let targets = hydraMentionTargets
        ProseRunRepresentable(blocks: blocks, pointSize: scaled, dimmed: dimmed, revision: faviconRevision, mentions: hydraMentionPersonas, targets: hydraMentionTargets, onOpenHead: { url in openURL(url) }, onHost: { [weak linkBox] view in linkBox?.value = view })
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LinkHoverModifier(linkView: linkBox, showsHand: $showsHand, hoveredHeadID: $hoveredHeadID, personas: hydraMentionPersonas, targets: targets))
            .task(id: linkKey) { [sources, linkKey, revision = $faviconRevision] in
                if !linkKey.isEmpty {
                    await InlineText.fetchLinkAssets(source: sources, streaming: false, revision: revision)
                }
            }
    }
}

struct ProseRunRepresentable: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    var pointSize: CGFloat = TypeScale.shared.content(13)
    var codePointSize: CGFloat = TypeScale.shared.code(12)
    var dimmed: Bool = false
    var revision: Int = 0
    var mentions: [HydraPersona] = []
    var targets: [String: HydraMentionTarget] = [:]
    var onOpenHead: ((URL) -> Void)?
    var onHost: ((LinkTextView) -> Void)?

    func makeCoordinator() -> LinkParagraphView.Coordinator {
        LinkParagraphView.Coordinator()
    }

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView()
        view.delegate = context.coordinator
        view.passesProseThrough = false
        onHost?(view)
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
            || coordinator.lastCodePointSize != codePointSize
            || coordinator.lastDimmed != dimmed || coordinator.lastRevision != revision
            || coordinator.lastMentions != mentionNames || coordinator.lastHeads != headLinks {
            coordinator.lastBlocks = blocks
            coordinator.lastPointSize = pointSize
            coordinator.lastCodePointSize = codePointSize
            coordinator.lastDimmed = dimmed
            coordinator.lastRevision = revision
            coordinator.lastMentions = mentionNames
            coordinator.lastHeads = headLinks
            view.render(Self.attributed(blocks: blocks, pointSize: pointSize, dimmed: dimmed, mentions: mentions, targets: targets))
        }
        // Outside the render check: handlers and selection ownership must land even
        // on an update that drew nothing.
        view.onOpenHead = onOpenHead
        view.mergeTarget = context.environment.mergeRequestTarget
        view.selectionOwner = context.environment.markdownSelectionOwner
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }

    static func dismantleNSView(_ view: LinkTextView, coordinator: LinkParagraphView.Coordinator) {
        view.delegate = nil
        view.onOpenHead = nil
        view.mergeTarget = nil
        view.selectionOwner = nil
    }

    static func joinedSources(_ blocks: [MarkdownBlock]) -> String {
        var parts: [String] = []
        collect(blocks, into: &parts)
        return parts.joined(separator: "\n")
    }

    private static func collect(_ blocks: [MarkdownBlock], into parts: inout [String]) {
        for block in blocks {
            switch block {
            case .paragraph(let text), .heading(_, let text):
                parts.append(text)
            case .list(_, _, let items):
                for item in items {
                    parts.append(item.text)
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
    static func attributed(blocks: [MarkdownBlock], pointSize: CGFloat, dimmed: Bool, mentions: [HydraPersona], targets: [String: HydraMentionTarget] = [:]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for block in blocks {
            append(block, depth: 0, indent: 0, dimmed: dimmed, spacing: 12, pointSize: pointSize, mentions: mentions, targets: targets, to: out)
        }
        return out
    }

    @MainActor
    private static func append(_ block: MarkdownBlock, depth: Int, indent: CGFloat, dimmed: Bool, spacing: CGFloat, pointSize: CGFloat, mentions: [HydraPersona], targets: [String: HydraMentionTarget], to out: NSMutableAttributedString) {
        let base = NSFont.systemFont(ofSize: pointSize)
        let color = dimmed ? NSColor.labelColor.withAlphaComponent(0.7) : NSColor.labelColor
        switch block {
        case .paragraph(let text):
            separate(to: out, font: base, color: color)
            let line = NSMutableAttributedString(attributedString: LinkParagraphView.attributed(source: text, pointSize: pointSize, codePointSize: TypeScale.shared.code(max(9, pointSize - CGFloat(TypeScale.shared.content - TypeScale.stockContent) - 1)), dimmed: dimmed, mentions: mentions, targets: targets))
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacing = spacing
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
        case .heading(let level, let text):
            separate(to: out, font: base, color: color)
            let stockSize = pointSize - CGFloat(TypeScale.shared.content - TypeScale.stockContent)
            let headingStockSize: CGFloat
            switch level {
            case 1: headingStockSize = (stockSize * 1.35).rounded()
            case 2: headingStockSize = (stockSize * 1.2).rounded()
            case 3: headingStockSize = (stockSize * 1.08).rounded()
            default: headingStockSize = stockSize
            }
            let size = TypeScale.shared.content(headingStockSize)
            let line = NSMutableAttributedString(attributedString: LinkParagraphView.attributed(source: text, pointSize: size, codePointSize: TypeScale.shared.code(max(9, headingStockSize - 1)), dimmed: dimmed, mentions: mentions, targets: targets))
            let semibold = NSFont.systemFont(ofSize: size, weight: .semibold)
            line.enumerateAttribute(.font, in: NSRange(location: 0, length: line.length), options: []) { value, range, _ in
                guard let font = value as? NSFont else { return }
                let traits = font.fontDescriptor.symbolicTraits
                if !traits.contains(.bold) && !traits.contains(.monoSpace) {
                    line.addAttribute(.font, value: semibold, range: range)
                }
            }
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacingBefore = level <= 2 ? 6 : 2
            style.paragraphSpacing = 12
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
        case .list(let ordered, let start, let items):
            for (index, item) in items.enumerated() {
                separate(to: out, font: base, color: color)
                let marker: String
                if let checked = item.checked {
                    marker = checked ? "☑" : "☐"
                } else if ordered {
                    marker = "\(start + index)."
                } else {
                    marker = depth == 0 ? "•" : "◦"
                }
                let line = NSMutableAttributedString(string: marker + "\t", attributes: [
                    .font: base,
                    .foregroundColor: color,
                ])
                if !item.text.isEmpty {
                    line.append(LinkParagraphView.attributed(source: item.text, pointSize: pointSize, codePointSize: TypeScale.shared.code(max(9, pointSize - CGFloat(TypeScale.shared.content - TypeScale.stockContent) - 1)), dimmed: dimmed, mentions: mentions, targets: targets))
                }
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 18
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
                style.defaultTabInterval = 18
                style.paragraphSpacing = (depth == 0 && index == items.count - 1) ? 12 : 6
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                out.append(line)
                for child in item.children {
                    append(child, depth: depth + 1, indent: indent + 18, dimmed: dimmed, spacing: 6, pointSize: pointSize, mentions: mentions, targets: targets, to: out)
                }
            }
        case .quote(let inner):
            for child in inner {
                append(child, depth: depth, indent: indent + 14, dimmed: true, spacing: spacing, pointSize: pointSize, mentions: mentions, targets: targets, to: out)
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
