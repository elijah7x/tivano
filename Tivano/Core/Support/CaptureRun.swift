import Foundation

/// A capture run: the app launched with `--website-captures <folder>`
/// to render development screenshots. The run keeps to its
/// own storage folder and defaults suite under that folder and never reads the Keychain,
/// so the store, the settings and the provider adapters ask here before touching the
/// real ones. `WebsiteCaptures` and `ProductCaptures` in the app layer drive the run.
enum CaptureRun {
    /// The folder the captures are written to, from the launch arguments; nil in a normal launch.
    nonisolated static let outputDirectory: URL? = {
        #if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--website-captures"),
           arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        return nil
    }()

    nonisolated static var isEnabled: Bool { outputDirectory != nil }

    /// The library and thread files the run reads, under the output folder.
    nonisolated static var storageRoot: URL? {
        outputDirectory?.appendingPathComponent("storage", isDirectory: true)
    }

    /// The defaults the run reads and writes instead of the app's own.
    nonisolated static var defaults: UserDefaults? {
        isEnabled ? UserDefaults(suiteName: suiteName) : nil
    }

    /// The defaults suite the run owns; a run starts by wiping it.
    nonisolated static let suiteName: String = {
        guard let directory = outputDirectory else { return "dev.tivano.Tivano.product-captures" }
        // An absolute preferences domain keeps its plist inside the capture folder,
        // rather than in the user's Library/Preferences. The path also isolates two
        // runs and stays stable when the same capture folder is resumed.
        return directory.standardizedFileURL.appendingPathComponent("settings").path
    }()
}
