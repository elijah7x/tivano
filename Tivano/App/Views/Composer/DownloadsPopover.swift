import AppKit
import SwiftUI

/// One file in ~/Downloads.
struct RecentDownload: Identifiable, Hashable {
    var url: URL
    var name: String
    var size: String?
    var isImage: Bool

    var id: String { url.path }
}

/// The user's latest downloads with previews, loaded once per popover opening.
@MainActor
@Observable
final class RecentDownloads {
    nonisolated static let limit = 15
    nonisolated static let previewPointSize: CGFloat = 30

    private(set) var items: [RecentDownload] = []
    private(set) var thumbnails: [String: CGImage] = [:]
    private(set) var icons: [String: NSImage] = [:]
    private(set) var isLoaded = false

    var directory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
    ]

    func load() async {
        guard let directory else { return }
        let scan = Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isHiddenKey]
            let keySet = Set(keys)
            let found = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
            return found
                .compactMap { url -> (URL, Date, Int)? in
                    guard !Task.isCancelled,
                          let values = try? url.resourceValues(forKeys: keySet),
                          values.isDirectory == false else { return nil }
                    return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(RecentDownloads.limit)
                .map { ($0.0, $0.2) }
        }
        let urls = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled else { return }
        var items: [RecentDownload] = []
        var icons: [String: NSImage] = [:]
        items.reserveCapacity(urls.count)
        await withTaskGroup(of: (String, CGImage)?.self) { group in
            for (url, size) in urls {
                icons[url.path] = FileIcons.icon(for: url.path)
                let isImage = Self.imageExtensions.contains(url.pathExtension.lowercased())
                items.append(RecentDownload(
                    url: url,
                    name: url.lastPathComponent,
                    size: size > 0 ? Int64(size).formatted(.byteCount(style: .file)) : nil,
                    isImage: isImage
                ))
                if isImage {
                    group.addTask {
                        guard let thumbnail = await ThumbnailCache.shared.thumbnail(
                            for: url.path,
                            pointSize: Self.previewPointSize,
                            fillingSquare: true
                        ) else { return nil }
                        return (url.path, thumbnail.image)
                    }
                }
            }
            self.items = items
            self.icons = icons
            self.thumbnails = [:]
            isLoaded = true
            for await result in group {
                guard !Task.isCancelled, let (path, image) = result else { continue }
                self.thumbnails[path] = image
            }
        }
    }
}

/// The attach button's popover: the latest downloads with native icons and photo
/// previews, plus a way out to Finder.
struct DownloadsPopover: View {
    let pick: (URL) -> Void
    let chooseOther: () -> Void

    @State private var downloads = RecentDownloads()

    var body: some View {
        // A ScrollView in a popover collapses to a couple of rows on its own, so the
        // rows' own height is forced on it. The popover takes its size the moment it
        // opens and keeps it, so the height is set from the first frame: a full list's
        // worth while the folder is read (nearly every Downloads folder fills it), the
        // rows' own height once it is, and only an empty folder sizes itself.
        PopoverMenu(maxHeight: 700, idealHeight: height) {
            PopoverSectionHeader("Recent downloads")
            if !downloads.isLoaded {
                HStack {
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
            } else if downloads.items.isEmpty {
                PopoverNote("No downloads yet. Anything you download appears here.")
            } else {
                ForEach(downloads.items) { item in
                    DownloadRow(
                        item: item,
                        icon: downloads.icons[item.url.path],
                        thumbnail: downloads.thumbnails[item.url.path],
                        pick: { pick(item.url) }
                    )
                }
            }
            PopoverDivider()
            PopoverItem("Show in Finder", symbol: "folder") {
                if let directory = downloads.directory {
                    NSWorkspace.shared.open(directory)
                }
            }
            PopoverItem("Choose Files…", symbol: "doc.on.doc") {
                chooseOther()
            }
        }
        // Wide enough for long file names and their sizes: without a fixed width the
        // popover shrinks to PopoverMenu's minimum and truncates every row.
        .frame(width: 360, height: height)
        .task { await downloads.load() }
    }

    /// The rows' own height, so the popover is exactly as tall as it has downloads to
    /// show; a full list's worth before the folder is read. Nil only for an empty
    /// folder, whose note sizes itself.
    private var height: CGFloat? {
        guard downloads.isLoaded else { return Self.height(forRows: RecentDownloads.limit) }
        guard !downloads.items.isEmpty else { return nil }
        return Self.height(forRows: downloads.items.count)
    }

    private static func height(forRows count: Int) -> CGFloat {
        let rows = CGFloat(count) * DownloadRow.height
        // The section header, the divider and the two ways out below the rows.
        return min(700, rows + 106)
    }
}

private struct DownloadRow: View {
    /// One row's slot, so the popover can size itself to its rows.
    static let height: CGFloat = 38

    let item: RecentDownload
    let icon: NSImage?
    let thumbnail: CGImage?
    let pick: () -> Void

    @State private var isHovering = false
    @State private var previewFrame: CGRect = .zero
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            let picture: NSImage
            if let thumbnail {
                picture = NSImage(cgImage: thumbnail, size: NSSize(width: 28, height: 28))
            } else {
                picture = icon ?? FileIcons.icon(for: item.url.path)
            }
            AttachmentDrops.shared.arm(
                image: picture,
                fromScreen: previewFrame,
                radius: 6
            )
            dismiss()
            // Runs after the popover closes, matching PopoverItem behavior.
            Task { @MainActor in pick() }
        } label: {
            HStack(spacing: 10) {
                preview
                Text(verbatim: item.name)
                    .font(.ui(.body))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 16)
                if let size = item.size {
                    Text(verbatim: size)
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Chrome.primaryText)
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Chrome.overlay(0.1) : Color.clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                .background { ScreenFrameReader { updatePreviewFrame($0) } }
        } else {
            Image(nsImage: icon ?? FileIcons.icon(for: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                // The icon row flies too, so this branch reports its frame as well:
                // without it the flight would start from the screen's own corner.
                .background { ScreenFrameReader { updatePreviewFrame($0) } }
        }
    }

    private func updatePreviewFrame(_ frame: CGRect) {
        guard abs(previewFrame.origin.x - frame.origin.x) > 0.5
            || abs(previewFrame.origin.y - frame.origin.y) > 0.5
            || abs(previewFrame.width - frame.width) > 0.5
            || abs(previewFrame.height - frame.height) > 0.5 else { return }
        previewFrame = frame
    }
}
