import Foundation

enum DshAgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, ptc, minimal, creator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: AppText.localized("Standard")
        case .ptc: AppText.localized("PTC")
        case .minimal: AppText.localized("Minimal agent")
        case .creator: AppText.localized("Creator")
        }
    }

    var summary: String {
        switch self {
        case .standard: AppText.localized("Full toolset: files, shell, search and web.")
        case .ptc: AppText.localized("The model writes a TypeScript program per step and calls the tools from it.")
        case .minimal: AppText.localized("One persistent shell and nothing else.")
        case .creator: AppText.localized("Standard plus tools to inspect DeepSeek Harness and build its plugins and presets.")
        }
    }
}
