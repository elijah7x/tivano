import Foundation
import Synchronization

/// Core records normalization during edits and decoding; App drains and presents it.
enum PermissionLowering {
    struct Lowering: Sendable, Equatable {
        var provider: ProviderKind
        var from: RuntimeMode
        var to: RuntimeMode
    }

    private static let pending = Mutex<[Lowering]>([])

    static func note(provider: ProviderKind, from: RuntimeMode, to: RuntimeMode) {
        let lowering = Lowering(provider: provider, from: from, to: to)
        pending.withLock { noted in
            if !noted.contains(lowering) { noted.append(lowering) }
        }
    }

    static func drain() -> [Lowering] {
        pending.withLock { noted in
            defer { noted.removeAll() }
            return noted
        }
    }
}
