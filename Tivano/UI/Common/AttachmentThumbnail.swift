import AppKit
import SwiftUI

/// Thumbnails refresh on mount, path changes and hidden-column restoration. They
/// intentionally keep that snapshot while mounted; only an open preview polls.
struct AttachmentFileTracker: ViewModifier {
    let path: String
    @Binding var snapshot: AttachmentFileSnapshot?
    var continuously = false
    @Environment(\.veilRenderScope) private var scope

    private struct Watch: Hashable {
        let path: String
        let visible: Bool
        let continuously: Bool
    }

    func body(content: Content) -> some View {
        let watch = Watch(path: path, visible: scope?.isVisible ?? true, continuously: continuously)
        content.task(id: watch) {
            guard watch.visible, !watch.path.isEmpty else { return }
            while !Task.isCancelled {
                let version = await AttachmentFileVersion.read(watch.path)
                guard !Task.isCancelled else { return }
                let next = AttachmentFileSnapshot(path: watch.path, version: version)
                if snapshot != next { snapshot = next }
                guard watch.continuously else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

struct AttachmentMediaLoad: Hashable {
    let path: String
    let snapshot: AttachmentFileSnapshot?
    var width: CGFloat = 0
    var height: CGFloat? = nil
    var retry = 0
}

/// The photos of a message, the composer's draft and an agent's reply: one strip per place,
/// each photo opening in the shared large preview.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    var medium = false

    /// One preview panel for the strip, so every photo opens in a single tap no matter
    /// how many are attached, and made on the first tap rather than with the row.
    @State private var preview = AttachmentPreviewSlot()

    var body: some View {
        // Weak/box captures only: hover responders and anchor views must not keep this
        // strip (and its panel) alive after it scrolls away.
        let slot = preview
        // A plain stack hugs the thumbnails, so a trailing-aligned row keeps the
        // photos over the bubble — and the anchor view fills just the photos.
        HStack(spacing: 6) {
            ForEach(medium ? Array(attachments.prefix(4)) : attachments) { attachment in
                AttachmentThumbnail(
                    attachment: attachment,
                    size: medium ? (attachments.count == 1 ? 240 : 112) : 56,
                    height: medium && attachments.count == 1 ? 180 : nil,
                    preview: preview
                )
                .help(attachment.name)
                .accessibilityLabel(Text(attachment.name))
            }
        }
        .background {
            AttachmentAnchorCapture { [weak slot] in slot?.setAnchor($0) }
        }
        .onDisappear { [weak slot] in slot?.close() }
    }
}

struct AttachmentThumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 56
    var height: CGFloat? = nil
    /// The panel the photo opens in: either a slot, which makes its panel on the first
    /// tap, or one the caller already holds. A strip that scrolls with the conversation
    /// wants the slot; the composer's own strips, which are made once, take either.
    private let slot: AttachmentPreviewSlot?
    private let panel: AttachmentPreviewCoordinator?

    @State private var image: CGImage?
    @State private var fileSnapshot: AttachmentFileSnapshot?
    /// The thumbnail's own NSView, handed to the panel on tap so the arrow
    /// lands on the tapped photo rather than the strip's middle. Mounted once the
    /// pointer has been on the photo: a tap always follows a hover, and a strip
    /// scrolling past should not be building views for a tap that never comes.
    @State private var ownAnchor = WeakView()
    @State private var needsAnchor = false
    /// Never mounts an anchor view of its own: for a strip that keeps every AppKit view
    /// out of SwiftUI's key-view-loop walk (see `WindowRectAnchor`). The panel then aims
    /// at the tap inside the strip's own anchor, which is where the pointer is anyway.
    private let anchorless: Bool

    init(attachment: Attachment, size: CGFloat = 56, height: CGFloat? = nil, preview: AttachmentPreviewSlot, anchorless: Bool = false) {
        self.init(attachment: attachment, size: size, height: height, slot: preview, panel: nil, anchorless: anchorless)
    }

    init(attachment: Attachment, size: CGFloat = 56, height: CGFloat? = nil, preview: AttachmentPreviewCoordinator) {
        self.init(attachment: attachment, size: size, height: height, slot: nil, panel: preview, anchorless: false)
    }

    private init(attachment: Attachment, size: CGFloat, height: CGFloat?, slot: AttachmentPreviewSlot?, panel: AttachmentPreviewCoordinator?, anchorless: Bool) {
        self.attachment = attachment
        self.size = size
        self.height = height
        self.slot = slot
        self.panel = panel
        self.anchorless = anchorless
    }

    /// Opens (or closes) the panel for this photo, making one only now if the caller
    /// handed over a slot.
    private func togglePanel() {
        if let slot {
            slot.panel.toggle(attachment, over: ownAnchor.value)
        } else {
            panel?.toggle(attachment, over: ownAnchor.value)
        }
    }

    var body: some View {
        // The anchor box alone: the hover responder and the anchor view must not keep
        // this row (and its attachment) alive after it scrolls away.
        let anchorBox = ownAnchor
        Button {
            togglePanel()
        } label: {
            if attachment.isImage {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                    if let image {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
                .frame(width: size, height: height ?? size)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
            } else if attachment.isVideo {
                AttachmentVideoThumbnail(attachment: attachment, size: size)
            } else {
                // A file fills its chip the way a photo does: the Finder icon at the
                // chip's full size on the same plate, so a text file, a PDF and a
                // folder all read at a glance. The name is the tooltip and the preview
                // panel; at 48pt it never fit under a 16pt icon anyway.
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                    Image(nsImage: FileIcons.icon(for: attachment.path))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(size * 0.08)
                }
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(Text(attachment.name))
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        // The .fill image is drawn wider than the cell before it is clipped;
        // pinning the hit shape to the cell keeps the neighbour's remove badge
        // reachable no matter how hit-testing treats the overflow.
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
        .onHover { [needed = $needsAnchor, anchorless] hovering in
            if hovering, !anchorless, !needed.wrappedValue { needed.wrappedValue = true }
        }
        .background {
            if needsAnchor, !anchorless {
                AttachmentAnchorCapture { [weak anchorBox] in anchorBox?.value = $0 }
            }
        }
        .modifier(AttachmentFileTracker(path: attachment.isImage ? attachment.path : "", snapshot: $fileSnapshot))
        .task(id: AttachmentMediaLoad(path: attachment.path, snapshot: fileSnapshot, width: size, height: height)) {
            guard !Task.isCancelled else { return }
            image = nil
            guard attachment.isImage, let version = fileSnapshot?.version, version.path == attachment.path else { return }
            guard await AttachmentFileVersion.read(attachment.path) == version, !Task.isCancelled else { return }
            if let known = ThumbnailMemory.image(for: version, pointSize: size, height: height) {
                if image !== known { image = known }
                return
            }
            // A rectangular tile keeps the photo's aspect, so its long side must run past the
            // tile for the .fill crop to land on enough pixels.
            let requested = height == nil ? size : max(size, height ?? size) * 1.5
            guard let thumbnail = await ThumbnailCache.shared.thumbnail(for: attachment.path, pointSize: requested, fillingSquare: height == nil, version: version),
                  !Task.isCancelled else { return }
            ThumbnailMemory.store(thumbnail.image, for: version, pointSize: size, height: height)
            withAnimation(.easeOut(duration: 0.15)) { image = thumbnail.image }
        }
    }
}
