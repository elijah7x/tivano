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
