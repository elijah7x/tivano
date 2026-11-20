import AppKit
import SwiftUI

/// Creation's hand-drawn icons: template drawings in the asset catalog, named
/// `creation-<symbol>` with the symbol's dots as hyphens, that stand in for SF Symbols
/// (and for the app's own sidebar assets) while the theme asks for them. A symbol with no
/// drawing in the catalog keeps its SF Symbol, so the set can grow one icon at a time.
enum CreationIcons {
    /// The SF Symbols and app assets that have a drawing.
    private static let symbols: [String] = [
        "sidebar.left", "plus.bubble", "magnifyingglass", "folder", "archivebox", "gear", "gearshape",
        "list.bullet", "ellipsis", "pin", "pin.fill", "arrow.left", "bubble.left.and.text.bubble.right",
        "asset:today-ring", "asset:sidebar-folder", "asset:sidebar-shelf",
        "arrow.up", "stop.fill", "paperclip", "bolt", "bolt.fill", "sparkles", "text.quote", "xmark", "plus",
        "hand.raised", "pencil.line", "wand.and.sparkles", "checkmark.shield",
        "terminal", "plusminus", "arrow.triangle.branch", "arrow.triangle.pull", "play", "arrow.up.forward.app", "arrow.down",
        "chevron.right", "chevron.down", "chevron.left", "chevron.up",
        "pencil", "doc.on.doc", "doc", "doc.text", "globe", "wrench.and.screwdriver", "person.2", "trash",
        "checkmark", "checkmark.circle", "checkmark.circle.fill", "info.circle", "exclamationmark.triangle",
        "arrow.clockwise", "eye", "eye.slash",
        "slider.horizontal.3", "paintpalette", "cpu", "internaldrive", "tag",
    ]

    /// The catalog name of a symbol's drawing.
    static func assetName(for symbol: String) -> String {
        let base = symbol.hasPrefix("asset:") ? String(symbol.dropFirst(6)) : symbol
        return "creation-" + base.replacingOccurrences(of: ".", with: "-")
    }

    /// Symbols whose drawing is in the catalog, checked once.
    @MainActor private static let drawn: Set<String> = Set(symbols.filter { NSImage(named: assetName(for: $0)) != nil })

    /// The name to draw: `asset:creation-…` while the theme draws by hand and the symbol has
    /// a drawing, otherwise the symbol as given.
    @MainActor static func resolve(_ symbol: String) -> String {
        guard TypeScale.shared.handDrawnIcons, drawn.contains(symbol) else { return symbol }
        return "asset:" + assetName(for: symbol)
    }
}

extension Image {
    /// An SF Symbol, or the theme's hand-drawn stand-in for it. A drawing has its own
    /// intrinsic size rather than following the font, so use it where the glyph sits at
    /// about the body size, or make it resizable and frame it.
    @MainActor static func themed(_ symbol: String) -> Image {
        let name = CreationIcons.resolve(symbol)
        return name.hasPrefix("asset:") ? Image(String(name.dropFirst(6))) : Image(systemName: name)
    }
}
