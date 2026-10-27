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

    /// The extra room between the lines of chat prose: three tenths of its size, to the
    /// half point. The SwiftUI and AppKit paragraphs both add it between lines only, so a
    /// paragraph reads the same whichever of them draws it.
    nonisolated static func proseLineSpacing(_ pointSize: CGFloat) -> CGFloat { (pointSize * 0.6).rounded() / 2 }

    /// The gap between the blocks of chat prose (paragraphs, headings, lists, code), in
    /// both the SwiftUI blocks and the AppKit prose runs.
    nonisolated static let proseParagraphSpacing: CGFloat = 16
}

extension Font {
    /// Interface text. At the stock Interface size this matches `Font.system` for the style.
    /// `Font` itself is nonisolated, so the factories are marked to match `TypeScale`.
    @MainActor static func ui(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        typeScaled(size: TypeScale.shared.ui(TypeScale.stockPointSize(style)), style: style, weight: weight, design: design)
    }

    @MainActor static func ui(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: TypeScale.shared.ui(size), weight: weight, design: design)
    }

    /// Headline stays semibold unless the caller passes a weight, matching `Font.system`.
    @MainActor static func typeScaled(size: CGFloat, style: Font.TextStyle, weight: Font.Weight?, design: Font.Design) -> Font {
        let resolved = weight ?? (style == .headline ? Font.Weight.semibold : nil)
        let font = Font.system(size: size, design: design)
        return resolved.map { font.weight($0) } ?? font
    }
}
