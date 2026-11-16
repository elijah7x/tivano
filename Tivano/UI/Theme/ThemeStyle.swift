import Foundation

enum ThemeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case liquidGlass
    case texture
    case create

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .texture: "Texture"
        case .create: "Creation"
        }
    }

    /// Liquid Glass needs macOS 26; older systems draw Texture.
    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var isAvailable: Bool {
        switch self {
        case .liquidGlass: Self.supportsLiquidGlass
        case .texture, .create: true
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var next: AppearanceMode {
        switch self {
        case .system: .light
        case .light: .dark
        case .dark: .system
        }
    }
}
