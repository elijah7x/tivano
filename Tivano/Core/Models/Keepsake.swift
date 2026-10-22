import Foundation

struct Keepsake: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var earnedAt: Date
    var litAt: Date?
}

struct KeepsakeDefinition: Sendable {
    let id: String
    let title: String
    let detail: String
    let frontAsset: String
    let backAsset: String
    let unlitAsset: String
}

enum KeepsakeCatalog {
    static let all: [KeepsakeDefinition] = [
        KeepsakeDefinition(
            id: "early-supporter",
            title: "Early Supporter",
            detail: "Given to you, to walk with us and explore how we will work with agents in the future.",
            frontAsset: "keepsake-early-supporter-front",
            backAsset: "keepsake-early-supporter-back",
            unlitAsset: "keepsake-early-supporter-unlit"
        ),
    ]

    static func definition(_ id: String) -> KeepsakeDefinition? {
        all.first { $0.id == id }
    }

    /// Issuing is version-controlled, with no server: a later release stops issuing
    /// a keepsake by removing its id here. Already earned keepsakes remain stored.
    static let grantedByThisBuild: [String] = ["early-supporter"]
}
