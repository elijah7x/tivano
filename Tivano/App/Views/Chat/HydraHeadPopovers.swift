import SwiftUI

/// A single-head popover's header: the head's glyph, its name with a status caption, and its task.
struct HydraPopoverHeader: View {
    let persona: HydraPersona
    var status: HydraHeadInfo.Status? = nil
    var caption: String? = nil
    var captionColor: Color = Chrome.secondaryText
    var title: String? = nil

    /// Sits at the header's trailing edge: a copy button, a link.
    var accessory: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HydraGlyph(persona: persona, size: 28, status: status)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HydraNameText(persona: persona, size: 14, weight: .semibold, color: Chrome.primaryText)
                    if let caption, !caption.isEmpty {
                        Text(verbatim: Chrome.localized(caption))
                            .font(.ui(.subheadline, weight: .medium))
                            .foregroundStyle(captionColor)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.primaryText.opacity(0.85))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let accessory {
                accessory
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A shade of its own, so the header reads as the panel's top and the report as its page.
        .background(Chrome.overlay(0.035))
    }
}

/// A finished head's report in the popover its pill opens: the header stays put, the report scrolls under it.
struct HydraHeadReportPopover: View {
    let head: HydraHeadInfo
    private let blocks: [MarkdownBlock]

    private static let width: CGFloat = 460

    @MainActor
    init(head: HydraHeadInfo) {
        self.head = head
        let summary = HydraReportFlagsRows.withoutTrailingFlags(head.summary?.trimmed ?? "")
        blocks = summary.isEmpty ? [] : MarkdownView.blocks(for: summary)
    }

    var body: some View {
        VStack(spacing: 0) {
            HydraPopoverHeader(
                persona: head.persona,
                status: head.status,
                caption: Self.caption(for: head),
                captionColor: Self.captionColor(for: head.status),
                title: head.task,
                accessory: blocks.isEmpty ? nil : AnyView(CopyButton(text: head.summary ?? ""))
            )
            Divider()
            // Every block, not a lazy stack: the body is laid out whole to size the panel
            // before it opens (see `PopoverScroll`), so a lazy stack only measured
            // differently once shown and the panel cut its header off.
            PopoverScroll(maxHeight: 460, width: Self.width) {
                VStack(alignment: .leading, spacing: 10) {
                    HydraReportFlagsRows(head: head)
                    if blocks.isEmpty {
                        Text("No report yet.")
                            .font(.ui(.callout))
                            .foregroundStyle(Chrome.secondaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                MarkdownBlockView(block: block)
                                    .equatable()
                            }
                        }
                        .font(.ui(.callout))
                        .environment(\.markdownPointSize, TypeScale.shared.content(12))
                        .environment(\.markdownDimmed, false)
                        .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
    }

    static func caption(for head: HydraHeadInfo) -> String {
        let base: String = switch head.status {
        case .completed: Chrome.localized("Finished")
        case .failed: Chrome.localized("Failed")
        case .stopped: Chrome.localized("Stopped")
        case .running: Chrome.localized("Working")
        }
        guard head.status != .running, let finishedAt = head.finishedAt else { return base }
        return "\(base) · \(duration(from: head.startedAt, to: finishedAt))"
    }

    static func captionColor(for status: HydraHeadInfo.Status) -> Color {
        switch status {
        case .failed: Chrome.danger
        case .stopped: Chrome.warning
        default: Chrome.secondaryText
        }
    }

    static func duration(from: Date, to: Date) -> String {
        RelativeTime.duration(to.timeIntervalSince(from))
    }
}

/// The lead's brief to a head in the popover its pill opens: the same header over the brief's markdown.
struct HydraBriefPopover: View {
    let persona: HydraPersona
    let task: String?
    let text: String
    private let blocks: [MarkdownBlock]

    private static let width: CGFloat = 520

    @MainActor
    init(persona: HydraPersona, task: String?, text: String) {
        self.persona = persona
        self.task = task
        self.text = text
        blocks = MarkdownView.blocks(for: text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HydraPopoverHeader(persona: persona, caption: "Brief", title: task, accessory: AnyView(CopyButton(text: text)))
            Divider()
            PopoverScroll(maxHeight: 460, width: Self.width) {
                Group {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block)
                                .equatable()
                        }
                    }
                    .font(.ui(.callout))
                    .environment(\.markdownPointSize, TypeScale.shared.content(12))
                    .environment(\.markdownDimmed, false)
                    .textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
    }
}
