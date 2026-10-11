import Foundation

/// What the provider registry needs from the settings: which providers are switched on,
/// where their binaries and keys are, and the model each last ran. The app's settings
/// object conforms; the registry never sees the rest of it.
@MainActor
protocol ProviderSettings: AnyObject {
    func isEnabled(_ provider: ProviderKind) -> Bool
    func binaryPath(for provider: ProviderKind) -> String
    func lastModel(for provider: ProviderKind) -> String?
    func apiKey(for provider: ProviderKind) -> String
    /// Whether update checks stay on for this provider. The app defaults this to on and
    /// remembers a switch off. A conformer with no opinion of its own stays monitored.
    func monitorsUpdates(_ provider: ProviderKind) -> Bool
    /// Moves chosen models and their preferences from a variant's id to the row its
    /// variants were merged into (see `ModelFamilies.collapsed`), keeping its effort and speed.
    func adoptModelFamilies(_ families: [ModelOption], for provider: ProviderKind)
}

extension ProviderSettings {
    func monitorsUpdates(_ provider: ProviderKind) -> Bool { true }
}
