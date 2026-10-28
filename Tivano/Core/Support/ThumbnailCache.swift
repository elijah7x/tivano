import CoreGraphics
import Foundation
import ImageIO

nonisolated struct AttachmentFileVersion: Hashable, Sendable {
    let path: String
    let resolvedPath: String
    let size: UInt64
    let modified: Date
    let created: Date?
    let fileNumber: UInt64?
    let systemNumber: UInt64?

    @concurrent
    static func read(_ path: String) async -> Self? {
        guard !Task.isCancelled else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Self(path: path, resolvedPath: resolved, size: size.uint64Value, modified: modified,
                    created: attributes[.creationDate] as? Date,
                    fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                    systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value)
    }
}

nonisolated struct AttachmentFileSnapshot: Hashable, Sendable {
    let path: String
    let version: AttachmentFileVersion?
}

/// Downsampled image attachments, decoded off the main actor and kept for reuse, so scrolling past
/// a message with images never reads or decodes a file while drawing. The decodes run outside
/// the actor, so fifteen thumbnails for the downloads popover decode side by side instead of
/// one behind the other, and callers asking for the same thumbnail share one decode.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    struct Thumbnail: @unchecked Sendable {
        let image: CGImage
        let version: AttachmentFileVersion
    }

    private struct Key: Hashable {
        let version: AttachmentFileVersion
        let pixels: Int
        let fillingSquare: Bool
    }

    private var thumbnails = RecentCache<Key, Thumbnail>(limit: 120, costLimit: 32 * 1_024 * 1_024)
    private var inFlight: [Key: Task<Thumbnail?, Never>] = [:]

    func thumbnail(for path: String, pointSize: CGFloat, fillingSquare: Bool = false,
                   version expected: AttachmentFileVersion? = nil) async -> Thumbnail? {
        let pixels = max(1, Int((pointSize * 2).rounded(.up)))
        // Metadata is read off the main actor, including cache hits. A file removed or
        // replaced during decoding must never be published under its previous version.
        for _ in 0..<2 {
            guard !Task.isCancelled, let version = await AttachmentFileVersion.read(path),
                  expected == nil || expected == version else { return nil }
            let key = Key(version: version, pixels: pixels, fillingSquare: fillingSquare)
            if let cached = thumbnails.value(for: key) { return cached }
            let task: Task<Thumbnail?, Never>
            if let pending = inFlight[key] {
                task = pending
            } else {
                task = Task.detached(priority: .userInitiated) {
                    Self.decode(version, pixels: pixels, fillingSquare: fillingSquare)
                }
                inFlight[key] = task
            }
            let thumbnail = await task.value
            if inFlight[key] == task { inFlight[key] = nil }
            guard !Task.isCancelled else { return nil }
            guard await AttachmentFileVersion.read(path) == version else { continue }
            if let thumbnail {
                thumbnails.insert(thumbnail, for: key, cost: thumbnail.image.bytesPerRow * thumbnail.image.height)
            }
            return thumbnail
        }
        return nil
    }

    private nonisolated static func decode(_ version: AttachmentFileVersion, pixels: Int, fillingSquare: Bool) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: version.resolvedPath) as CFURL, nil) else { return nil }
        var pixels = pixels
        if fillingSquare,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Double,
           let height = properties[kCGImagePropertyPixelHeight] as? Double,
           min(width, height) > 0 {
            pixels = Int(min(2048, ceil(Double(pixels) * max(width, height) / min(width, height))))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Thumbnail(image: image, version: version)
    }
}

/// Main-actor access after the view has asynchronously resolved the file version.
@MainActor
enum ThumbnailMemory {
    private struct Key: Hashable {
        let version: AttachmentFileVersion
        let width: Int
        let height: Int?
    }

    private static var images = RecentCache<Key, CGImage>(limit: 120, costLimit: 16 * 1_024 * 1_024)

    private static func key(_ version: AttachmentFileVersion, pointSize: CGFloat, height: CGFloat?) -> Key {
        Key(version: version, width: Int((pointSize * 2).rounded(.up)),
            height: height.map { Int(($0 * 2).rounded(.up)) })
    }

    static func image(for version: AttachmentFileVersion, pointSize: CGFloat, height: CGFloat? = nil) -> CGImage? {
        images.value(for: key(version, pointSize: pointSize, height: height))
    }

    static func store(_ image: CGImage, for version: AttachmentFileVersion, pointSize: CGFloat, height: CGFloat? = nil) {
        images.insert(image, for: key(version, pointSize: pointSize, height: height), cost: image.bytesPerRow * image.height)
    }
}
