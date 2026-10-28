import Foundation

/// Several chats share one checkout, and a working-tree diff cannot tell whose write it was.
@MainActor
enum CheckoutClaims {
    private struct Claim {
        var owner: UUID
        var date: Date
    }

    private static var claims: [String: [String: Claim]] = [:]
    // Stop an already queued provider callback from reclaiming work after its owner
    // was archived or deleted. Unarchiving explicitly permits future claims again.
    private static var inactiveOwners = Set<UUID>()

    private static func key(_ root: String) -> String {
        URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func claim(_ paths: some Sequence<String>, root: String, owner: UUID) {
        guard !inactiveOwners.contains(owner) else { return }
        let root = key(root)
        let now = Date.now
        for path in paths { claims[root, default: [:]][path] = Claim(owner: owner, date: now) }
    }

    static func deactivate(owner: UUID) {
        inactiveOwners.insert(owner)
        for root in Array(claims.keys) {
            claims[root] = claims[root]?.filter { $0.value.owner != owner }
            if claims[root]?.isEmpty == true { claims[root] = nil }
        }
    }

    static func activate(owner: UUID) {
        inactiveOwners.remove(owner)
    }

    /// Reconcile against the library before merging, including owners deleted while
    /// their runtime was absent. Age does not revoke a live task's ownership.
    static func retainOwners(_ owners: Set<UUID>, root: String) {
        let previous = Set((claims[key(root)] ?? [:]).values.map(\.owner))
        for owner in previous.subtracting(owners) { deactivate(owner: owner) }
        inactiveOwners.subtract(owners)
    }

    static func foreign(_ paths: some Sequence<String>, root: String, owner: UUID, since: Date) -> Set<String> {
        let latest = claims[key(root)] ?? [:]
        return Set(paths.filter { path in
            guard let claim = latest[path] else { return false }
            return claim.owner != owner && claim.date >= since
        })
    }

    static func othersActive(root: String, owner: UUID, since: Date) -> Bool {
        (claims[key(root)] ?? [:]).values.contains { $0.owner != owner && $0.date >= since }
    }
}
