import AppKit
import SwiftUI

/// Interface, Content and Code base sizes. A stock setting is today's type;
/// any other setting adds the same point offset to every size in that category.
///
/// Isolated to the main actor, which is where SwiftUI bodies and the AppKit
/// attributed-string builders run. The read stays synchronous under Swift 6,
/// and Observation re-renders a body that read a size.
@MainActor @Observable
final class TypeScale {
    static let shared = TypeScale()

    static let stockUI = 13
    static let defaultUI = 14
    static let stockContent = 13 // Rendering baseline; keep existing sizes and range anchored here.
    static let defaultContent = 15
    static let stockCode = 12
    static let defaultCode = 13

    /// One point under the stock size through five over it.
    static let uiRange = (stockUI - 1)...(stockUI + 5)
    static let contentRange = (stockContent - 1)...(stockContent + 5)
    static let codeRange = (stockCode - 1)...(stockCode + 5)

    var ui = defaultUI
    var content = defaultContent
    var code = defaultCode
    /// Mirrors the theme's `serif`, so every body that sized text through `Font.ui` or
    /// `Font.chat` re-renders in the new face when the theme changes.
    var serif = false
    /// Mirrors the theme's `handDrawnIcons` for the same reason: icons resolved through
    /// `CreationIcons` re-render when the theme changes.
    var handDrawnIcons = false

    private init() {}

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The macOS point size of a text style at the Large content size.
    static func stockPointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    func ui(_ stock: CGFloat) -> CGFloat { stock + CGFloat(ui - Self.stockUI) }
    func content(_ stock: CGFloat) -> CGFloat { stock + CGFloat(content - Self.stockContent) }
    func code(_ stock: CGFloat) -> CGFloat { stock + CGFloat(code - Self.stockCode) }

    struct ProseListMetrics: Equatable, Sendable {
        let slotWidth: CGFloat
        let gap: CGFloat
        var step: CGFloat { slotWidth + gap }
    }

    /// The extra room between the lines of chat prose: four tenths of its size, to the
    /// half point. The SwiftUI and AppKit paragraphs both add it between lines only, so a
    /// paragraph reads the same whichever of them draws it.
    nonisolated static func proseLineSpacing(_ pointSize: CGFloat) -> CGFloat { (pointSize * 0.8).rounded() / 2 }

    /// The gap between the blocks of chat prose (paragraphs, headings, lists, code), in
    /// both the SwiftUI blocks and the AppKit prose runs.
    nonisolated static func proseParagraphSpacing(_ pointSize: CGFloat) -> CGFloat { (pointSize * 1.3).rounded() }
    static var proseParagraphSpacing: CGFloat { proseParagraphSpacing(shared.content(13)) }

    nonisolated static func proseHeadingPointSize(_ bodyPointSize: CGFloat, level: Int) -> CGFloat {
        switch level {
        case 1: (bodyPointSize * 1.32).rounded()
        case 2: (bodyPointSize * 1.18).rounded()
        case 3: (bodyPointSize * 1.08).rounded()
        default: bodyPointSize
        }
    }

    nonisolated static func proseHeadingLineSpacing(_ headingPointSize: CGFloat) -> CGFloat {
        (headingPointSize * 0.5).rounded() / 2
    }

    nonisolated static func proseHeadingTopExtra(_ bodyPointSize: CGFloat, level: Int) -> CGFloat {
        switch level {
        case 1: (bodyPointSize * 0.55).rounded()
        case 2: (bodyPointSize * 0.45).rounded()
        default: (bodyPointSize * 0.25).rounded()
        }
    }

    nonisolated static func proseHeadingBottomSpacing(_ bodyPointSize: CGFloat, level: Int) -> CGFloat {
        level <= 2 ? (bodyPointSize * 0.75).rounded() : (bodyPointSize * 0.6).rounded()
    }

    nonisolated static func proseListItemSpacing(_ pointSize: CGFloat, depth: Int) -> CGFloat {
        depth == 0 ? (pointSize * 0.65).rounded() : (pointSize * 0.52).rounded()
    }

    nonisolated static func proseListChildSpacing(_ pointSize: CGFloat) -> CGFloat {
        (pointSize * 0.52).rounded()
    }

    nonisolated static func proseListGroupSpacing(_ pointSize: CGFloat) -> CGFloat {
        (pointSize * 0.8).rounded()
    }

    nonisolated static func proseListMetrics(pointSize: CGFloat, ordered: Bool, start: Int, count: Int) -> ProseListMetrics {
        let maxNumber = max(start, start + max(0, count - 1))
        let digits = ordered ? max(1, String(maxNumber).count) : 1
        let baseSlot = (pointSize * 1.15).rounded()
        let extraSlot = CGFloat(max(0, digits - 1)) * (pointSize * 0.65).rounded()
        let gap = (pointSize * 0.52).rounded()
        return ProseListMetrics(slotWidth: baseSlot + extraSlot, gap: gap)
    }

    nonisolated static func proseBulletDiameter(_ pointSize: CGFloat, hollow: Bool) -> CGFloat {
        let solid = (pointSize * 0.72).rounded() / 2
        return hollow ? solid + 0.5 : solid
    }

    nonisolated static func proseQuoteSpacing(_ pointSize: CGFloat) -> CGFloat {
        (pointSize * 0.75).rounded()
    }

    nonisolated static func codeLineSpacing(_ codePointSize: CGFloat) -> CGFloat {
        (codePointSize * 0.45).rounded() / 2
    }
}

extension Font {
    /// Interface text. At the stock Interface size this matches `Font.system` for the style.
    /// `Font` itself is nonisolated, so the factories are marked to match `TypeScale`.
    @MainActor static func ui(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        typeScaled(size: TypeScale.shared.ui(TypeScale.stockPointSize(style)), style: style, weight: weight, design: design)
    }

    @MainActor static func ui(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        themed(size: TypeScale.shared.ui(size), weight: weight, design: design)
    }

    /// Headline stays semibold unless the caller passes a weight, matching `Font.system`.
    @MainActor static func typeScaled(size: CGFloat, style: Font.TextStyle, weight: Font.Weight?, design: Font.Design) -> Font {
        let resolved = weight ?? (style == .headline ? Font.Weight.semibold : nil)
        if design == .default, TypeScale.shared.serif {
            return ThemeTypeface.font(size: size, weight: ThemeTypeface.weight(resolved ?? .regular))
        }
        let font = Font.system(size: size, design: design)
        return resolved.map { font.weight($0) } ?? font
    }

    /// `Font.system`, or the theme's serif face for the default design.
    @MainActor static func themed(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        if design == .default, TypeScale.shared.serif {
            return ThemeTypeface.font(size: size, weight: ThemeTypeface.weight(weight))
        }
        return .system(size: size, weight: weight, design: design)
    }
}

/// The serif face of a serif theme: New York for Latin text and digits, Songti SC for
/// Chinese (the serif design alone falls back to PingFang for CJK). Both ship with macOS,
/// so nothing is bundled. Code keeps SF Mono.
@MainActor
enum ThemeTypeface {
    private struct Key: Hashable { let size: CGFloat; let weight: CGFloat }
    private static var cache: [Key: NSFont] = [:]

    /// The interface or prose font for a size and weight: the serif face when the theme
    /// asks for one, the system face otherwise.
    static func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard TypeScale.shared.serif else { return .systemFont(ofSize: size, weight: weight) }
        return serif(size: size, weight: weight)
    }

    static func monospacedDigitNSFont(size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        guard TypeScale.shared.serif else { return .monospacedDigitSystemFont(ofSize: size, weight: weight) }
        let base = serif(size: size, weight: weight)
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func serif(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = Key(size: size, weight: weight.rawValue)
        if let font = cache[key] { return font }
        // Semibold reads heavy in a serif; a step lighter keeps headings quiet.
        let tuned: NSFont.Weight = weight == .semibold ? .medium : weight
        let base = NSFont.systemFont(ofSize: size, weight: tuned).fontDescriptor
        let songti = NSFontDescriptor(fontAttributes: [
            .family: "Songti SC",
            .traits: [NSFontDescriptor.TraitKey.weight: tuned.rawValue],
        ])
        let descriptor = (base.withDesign(.serif) ?? base).addingAttributes([.cascadeList: [songti]])
        let font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        cache[key] = font
        return font
    }

    static func font(size: CGFloat, weight: NSFont.Weight) -> Font {
        Font(serif(size: size, weight: weight) as CTFont)
    }

    static func weight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
