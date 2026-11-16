import Foundation

enum AppIconChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case liquidGlass
    case texture
    case create

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Match Theme"
        case .liquidGlass: "Liquid Glass"
        case .texture: "Texture"
        case .create: "Creation"
        }
    }

    func resolved(for style: ThemeStyle) -> ThemeStyle {
        switch self {
        case .automatic: style
        case .liquidGlass: .liquidGlass
        case .texture: .texture
        case .create: .create
        }
    }

    static func assetName(for style: ThemeStyle) -> String {
        switch style {
        case .liquidGlass: "AppIconChoiceLiquidGlass"
        case .texture: "AppIconChoiceTexture"
        case .create: "AppIconChoiceCreation"
        }
    }
}
