import AppKit
import Foundation
import os

/// Low-overhead runtime audit for blank-looking `NSTextView` instances in release builds.
/// Runs only when invoked at display-check points, retains no views, uses no timers, and
/// emits a persisted `.fault` log line only when an anomaly is detected (never logging text).
///
/// Inspect logs with:
/// `log show --predicate 'category == "TextDisplayAudit"' --last 1d`
@MainActor
enum TextDisplayAudit {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Tivano",
        category: "TextDisplayAudit"
    )

    private static let tolerance: CGFloat = 0.5
    private static let hiddenAlphaThreshold: CGFloat = 0.01
    private static let hiddenLayerOpacityThreshold: Float = 0.01
    private static let transparentTextAlphaThreshold: CGFloat = 0.05
    private static let maxInspectedCharacters = 512
    private static let maxLogsPerProcess = 40
    private static let maxRecordedKeys = 256

    private static var loggedCount = 0
    private static var recordedKeys: Set<AuditKey> = []

    private struct Issues: OptionSet, Hashable {
        let rawValue: UInt8

        static let containerWidth = Issues(rawValue: 1 << 0)
        static let heightMismatch = Issues(rawValue: 1 << 1)
        static let noGlyphsInView = Issues(rawValue: 1 << 2)
        static let outsideHost = Issues(rawValue: 1 << 3)
        static let ancestorHidden = Issues(rawValue: 1 << 4)
        static let transparentText = Issues(rawValue: 1 << 5)

        var labels: [String] {
            var result: [String] = []
            if contains(.containerWidth) { result.append("container_width") }
            if contains(.heightMismatch) { result.append("height_mismatch") }
            if contains(.noGlyphsInView) { result.append("no_glyphs_in_view") }
            if contains(.outsideHost) { result.append("outside_host") }
            if contains(.ancestorHidden) { result.append("ancestor_hidden") }
            if contains(.transparentText) { result.append("transparent_text") }
            return result
        }
    }

    private struct AuditKey: Hashable {
        let viewID: ObjectIdentifier
        let issues: Issues
    }

    /// `textFading` is true while the caller is dissolving new text in through temporary
    /// colours, so a paragraph that is legitimately still transparent is not reported.
    @discardableResult
    static func audit(_ view: NSTextView, reason: StaticString, textFading: Bool = false) -> Bool {
        // 1. Preconditions: skip views that are off-screen, hidden, zero-sized, empty, or unconfigured.
        guard let window = view.window,
              window.occlusionState.contains(.visible),
              !view.isHiddenOrHasHiddenAncestor else {
            return false
        }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return false
        }
        let visibleRect = view.visibleRect
        guard !visibleRect.isEmpty,
              let textStorage = view.textStorage, textStorage.length > 0,
              let layoutManager = view.layoutManager,
              let textContainer = view.textContainer else {
            return false
        }

        var issues: Issues = []

        // 2a. container_width: container width should match view bounds width within 0.5pt.
        let containerWidth = textContainer.containerSize.width
        if !(abs(containerWidth - bounds.width) <= tolerance) {
            issues.insert(.containerWidth)
        }

        // Convert visibleRect to text-container coordinates and lay out only the visible slice
        // (never calling full-container `ensureLayout(for:)`).
        let origin = view.textContainerOrigin
        let visibleInContainer = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        layoutManager.ensureLayout(forBoundingRect: visibleInContainer, in: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        // 2b. height_mismatch: compare full usedRect height when layout reached the end; when only
        // a top slice was laid out, still flag overflow, clamped container height, or unlaid text
        // remaining past a visible bottom edge.
        let usedHeight = ceil(usedRect.height)
        let layoutComplete = layoutManager.firstUnlaidCharacterIndex() >= textStorage.length
        if layoutComplete {
            if !(abs(usedHeight - bounds.height) <= tolerance) {
                issues.insert(.heightMismatch)
            }
        } else if !(usedHeight <= bounds.height + tolerance)
            || textContainer.containerSize.height < bounds.height - tolerance
            || (view.isFlipped
                && !layoutManager.allowsNonContiguousLayout
                && visibleRect.maxY >= bounds.maxY - tolerance) {
            issues.insert(.heightMismatch)
        }

        // 2c. no_glyphs_in_view: visible rect intersects usedRect yet yields zero glyphs.
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleInContainer, in: textContainer)
        if visibleGlyphRange.length == 0,
           !usedRect.isEmpty,
           usedRect.intersects(visibleInContainer) {
            issues.insert(.noGlyphsInView)
        }

        // 2d. outside_host: view.frame extends outside superview.bounds on any edge by > 0.5pt.
        let frame = view.frame
        let superview = view.superview
        if let hostBounds = superview?.bounds {
            let insideHost = frame.minX >= hostBounds.minX - tolerance
                && frame.maxX <= hostBounds.maxX + tolerance
                && frame.minY >= hostBounds.minY - tolerance
                && frame.maxY <= hostBounds.maxY + tolerance
            if !insideHost {
                issues.insert(.outsideHost)
            }
        }

        // 2e. ancestor_hidden: any ancestor from superview through window.contentView has near-zero
        // alpha or a hidden/transparent layer (`isHidden` is already excluded by preconditions).
        let contentView = window.contentView
        var ancestor = superview
        while let current = ancestor {
            let layerHidden = current.layer.map {
                $0.opacity < hiddenLayerOpacityThreshold || $0.isHidden
            } ?? false
            if current.alphaValue < hiddenAlphaThreshold || layerHidden {
                issues.insert(.ancestorHidden)
                break
            }
            if current === contentView { break }
            ancestor = current.superview
        }

        // 2f. transparent_text: the effective foreground alpha (temporary attribute overrides
        // storage attribute) of every inspected visible character is near zero. One opaque
        // character is enough to rule it out, so a fading tail never counts.
        var maxEffectiveAlpha: CGFloat?
        if !textFading, visibleGlyphRange.length > 0, visibleGlyphRange.location != NSNotFound {
            let fullCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
            let storageBounds = NSRange(location: 0, length: textStorage.length)
            var inspectRange = NSIntersectionRange(fullCharRange, storageBounds)
            if inspectRange.length > maxInspectedCharacters {
                inspectRange.length = maxInspectedCharacters
            }
            if inspectRange.length > 0 {
                let end = NSMaxRange(inspectRange)
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    var index = inspectRange.location
                    var lastColor: NSColor?
                    var lastAlpha: CGFloat?
                    while index < end {
                        let remaining = NSRange(location: index, length: end - index)
                        var tempRange = NSRange(location: index, length: 0)
                        let tempValue = layoutManager.temporaryAttribute(
                            .foregroundColor,
                            atCharacterIndex: index,
                            longestEffectiveRange: &tempRange,
                            in: remaining
                        )
                        let clampedTempEnd: Int
                        if tempRange.location != NSNotFound, tempRange.length > 0 {
                            let rawEnd = NSMaxRange(tempRange)
                            clampedTempEnd = rawEnd > index ? min(rawEnd, end) : index + 1
                        } else {
                            clampedTempEnd = index + 1
                        }

                        let effectiveColor: NSColor?
                        let nextIndex: Int
                        if let tempColor = tempValue as? NSColor {
                            effectiveColor = tempColor
                            nextIndex = clampedTempEnd
                        } else {
                            let storageLimit = NSRange(location: index, length: clampedTempEnd - index)
                            var storageRange = NSRange(location: index, length: 0)
                            let storageValue = textStorage.attribute(
                                .foregroundColor,
                                at: index,
                                longestEffectiveRange: &storageRange,
                                in: storageLimit
                            )
                            effectiveColor = storageValue as? NSColor
                            if storageRange.location != NSNotFound, storageRange.length > 0 {
                                let rawEnd = NSMaxRange(storageRange)
                                nextIndex = rawEnd > index ? min(rawEnd, clampedTempEnd) : index + 1
                            } else {
                                nextIndex = index + 1
                            }
                        }

                        if let color = effectiveColor {
                            let resolvedAlpha: CGFloat?
                            if color === lastColor {
                                resolvedAlpha = lastAlpha
                            } else {
                                resolvedAlpha = color.usingColorSpace(.sRGB)?.alphaComponent
                                lastColor = color
                                lastAlpha = resolvedAlpha
                            }
                            if let alpha = resolvedAlpha {
                                maxEffectiveAlpha = max(maxEffectiveAlpha ?? alpha, alpha)
                            }
                        }

                        index = nextIndex
                    }
                }
                if let alpha = maxEffectiveAlpha, alpha < transparentTextAlphaThreshold {
                    issues.insert(.transparentText)
                }
            }
        }

        guard !issues.isEmpty else { return false }

        // 4. Rate limiting: max 40 logs per process, deduplicated per (view, issue set) up to 256 keys.
        guard loggedCount < maxLogsPerProcess, recordedKeys.count < maxRecordedKeys else {
            return true
        }
        let viewID = ObjectIdentifier(view)
        let key = AuditKey(viewID: viewID, issues: issues)
        guard recordedKeys.insert(key).inserted else {
            return true
        }
        loggedCount += 1

        // 3. Persist one structured `.fault` line with public numeric/metadata fields only.
        let reasonText = String(describing: reason)
        let issueList = issues.labels.joined(separator: ",")
        let boundsText = "\(fmt(bounds.width))x\(fmt(bounds.height))"
        let frameText = "(\(fmt(frame.origin.x)),\(fmt(frame.origin.y)) \(fmt(frame.size.width))x\(fmt(frame.size.height)))"
        let hostBoundsText = superview.map { "\(fmt($0.bounds.width))x\(fmt($0.bounds.height))" } ?? "nil"
        let containerWidthText = fmt(containerWidth)
        let usedHeightText = fmt(usedRect.height)
        let visibleText = "\(fmt(visibleRect.width))x\(fmt(visibleRect.height))"
        let visibleGlyphCount = visibleGlyphRange.length
        let storageLength = textStorage.length
        let maxAlpha = maxEffectiveAlpha.map { Double($0) } ?? -1.0
        let isKeyWindow = window.isKeyWindow
        let isAppActive = NSApp?.isActive ?? false
        let viewClassName = String(describing: type(of: view))
        let viewHash = viewID.hashValue

        logger.fault("reason=\(reasonText, privacy: .public) issues=\(issueList, privacy: .public) bounds=\(boundsText, privacy: .public) frame=\(frameText, privacy: .public) superviewBounds=\(hostBoundsText, privacy: .public) containerW=\(containerWidthText, privacy: .public) usedH=\(usedHeightText, privacy: .public) visible=\(visibleText, privacy: .public) visibleGlyphs=\(visibleGlyphCount, privacy: .public) textLen=\(storageLength, privacy: .public) maxAlpha=\(maxAlpha, format: .fixed(precision: 3), privacy: .public) keyWindow=\(isKeyWindow, privacy: .public) appActive=\(isAppActive, privacy: .public) viewClass=\(viewClassName, privacy: .public) viewID=\(viewHash, privacy: .public)")

        return true
    }

    private static func fmt(_ value: CGFloat) -> String {
        if value.isNaN { return "nan" }
        if !value.isFinite { return value > 0 ? "inf" : "-inf" }
        if abs(value) >= 1e7 { return String(format: "%.2e", Double(value)) }
        return String(format: "%.1f", Double(value))
    }
}
