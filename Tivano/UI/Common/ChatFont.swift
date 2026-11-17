import SwiftUI

extension Font {
    /// Conversation text at the Content size. Stock Content keeps the macOS point
    /// size for the style, so the stock setting leaves today's type alone.
    @MainActor static func chat(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        typeScaled(size: TypeScale.shared.content(TypeScale.stockPointSize(style)), style: style, weight: weight, design: design)
    }

    @MainActor static func chat(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        themed(size: TypeScale.shared.content(size), weight: weight, design: design)
    }

    /// Code at the Code size. Design defaults to monospaced. The stock base is 12:
    /// a callout stays 12, and `code(size:)` shifts a raw stock size (the diff's 11.5) by the same amount.
    @MainActor static func code(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .monospaced) -> Font {
        typeScaled(size: TypeScale.shared.code(TypeScale.stockPointSize(style)), style: style, weight: weight, design: design)
    }

    @MainActor static func code(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .monospaced) -> Font {
        .system(size: TypeScale.shared.code(size), weight: weight, design: design)
    }
}
