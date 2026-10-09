import Foundation
import CryptoKit

/// Stable across processes, unlike Swift's randomized Hasher. SHA256.hash(data:)
/// is verified in the installed macOS SDK's CryptoKit.swiftinterface.
enum SharedResourceLock {
    /// Beside the editions' libraries rather than in either one, so Release and Dev
    /// working on the same repository take the same lock.
    static func url(resource: String) -> URL {
        let hash = SHA256.hash(data: Data(resource.utf8)).map { String(format: "%02x", $0) }.joined()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(".tivano-resource-locks/\(hash).lock")
    }
}
