import Foundation

/// Converts a cumulative token counter into per-event spend.
///
/// Providers report usage with different shapes: Claude hands over session
/// totals, Codex a thread total, ACP a session counter. All three only ever
/// grow within a session, so the spend behind one event is the positive
/// delta since the previous event. A drop (compaction, a fresh session on a
/// reused object) reseeds the baseline without recording: the growth after
/// it is new spend and gets counted from there. The first call may pass
/// `before`, the total the counter had before this session, which is not
/// new spend.
struct TokenSpendTracker {
    private var lastTotal = 0
    private var seeded = false

    mutating func spend(total: Int, before: Int = 0) -> Int {
        if !seeded { seeded = true; lastTotal = max(0, min(total, before)) }
        defer { lastTotal = max(0, total) }
        return max(0, total - lastTotal)
    }

    /// Sees a total without counting it, seeding the baseline for the deltas
    /// that follow. For a resumed session whose first reported total is the
    /// conversation's inherited history rather than spend: the baseline is
    /// unknown, so the observation is left uncounted instead of being charged
    /// or reported as zero.
    mutating func seedBaseline(total: Int) {
        guard !seeded else { return }
        seeded = true
        lastTotal = max(0, total)
    }
}
