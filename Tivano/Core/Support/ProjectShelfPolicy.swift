import Foundation

enum ProjectShelfPolicy {
    struct Input: Equatable {
        var isShelved: Bool
        var addedAt: Date
        var lastActivity: Date?
        var shelfChangedAt: Date?
        var isBusy: Bool
        var holdsSelection: Bool
        var hasUnread: Bool
    }

    /// Zero disables automatic shelving.
    static let dayOptions = [0, 3, 7, 14]

    /// Shelves only idle projects that need no attention.
    static func shouldAutoShelve(_ input: Input, days: Int, now: Date) -> Bool {
        guard days > 0, !input.isShelved, !input.isBusy,
              !input.holdsSelection, !input.hasUnread else { return false }
        let reference = [input.addedAt, input.lastActivity, input.shelfChangedAt]
            .compactMap { $0 }.max() ?? input.addedAt
        guard reference <= now else { return false }
        return now.timeIntervalSince(reference) >= TimeInterval(days) * 86_400
    }
}
