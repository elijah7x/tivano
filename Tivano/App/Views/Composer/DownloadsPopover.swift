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

/// The attach button's popover: Finder first, then the latest downloads with native icons
/// and photo previews when enabled, and a switch for the recent downloads list.
struct DownloadsPopover: View {
    @Environment(AppModel.self) private var model
    let pick: (URL) -> Void
    let chooseOther: () -> Void

    @State private var downloads = RecentDownloads()

    var body: some View {
        @Bindable var settings = model.settings
        let showsRecents = settings.recentDownloadsPicker
        let idealHeight = height(showsRecents: showsRecents)
        PopoverMenu(maxHeight: 700, idealHeight: idealHeight, scrolls: idealHeight != nil) {
            PopoverItem("Choose files…", symbol: "paperclip") {
                chooseOther()
            }
            if showsRecents {
                PopoverDivider()
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
            }
            PopoverDivider()
            HStack(spacing: 8) {
                Text("Show recent downloads")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 12)
                SettingsSwitch(isOn: $settings.recentDownloadsPicker)
                    .accessibilityLabel(Text("Show recent downloads"))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
        }
        // Wide enough for long file names and their sizes when listing downloads.
        .frame(width: showsRecents ? 360 : 250, height: idealHeight)
        .task(id: showsRecents) {
            if showsRecents, !downloads.isLoaded {
                await downloads.load()
            }
        }
    }

    /// The rows' own height, so the popover is exactly as tall as it has downloads to
    /// show; a full list's worth before the folder is read. Nil when downloads are hidden
    /// or for an empty folder, which sizes itself.
    private func height(showsRecents: Bool) -> CGFloat? {
        guard showsRecents else { return nil }
        guard downloads.isLoaded else { return Self.height(forRows: RecentDownloads.limit) }
        guard !downloads.items.isEmpty else { return nil }
        return Self.height(forRows: downloads.items.count)
    }

    private static func height(forRows count: Int) -> CGFloat {
        let rows = CGFloat(count) * DownloadRow.height
        // Choose files…, section header, dividers, Show in Finder and the switch row.
        return min(700, rows + 150)
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
