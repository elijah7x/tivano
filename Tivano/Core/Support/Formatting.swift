import Foundation

/// Thread-safe cache of POSIX `yyyy-MM-dd` formatters and Gregorian calendars keyed by time zone.
final class DayFormatterCache: @unchecked Sendable {
    static let shared = DayFormatterCache()
    private let lock = NSLock()
    private var entries: [TimeZone: (calendar: Calendar, formatter: DateFormatter)] = [:]

    func withFormatter<R>(for timeZone: TimeZone, _ body: (Calendar, DateFormatter) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        let entry: (calendar: Calendar, formatter: DateFormatter)
        if let existing = entries[timeZone] {
            entry = existing
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            entry = (calendar, formatter)
            entries[timeZone] = entry
        }
        return try body(entry.calendar, entry.formatter)
    }
}

/// Shared formatters and duration formatting helpers.
enum AppFormatting {
    /// Formats a whole-second duration with narrow units (up to two units, fractional part hidden).
    static func duration(seconds: Int, allowed: Set<Duration.UnitsFormatStyle.Unit>) -> String {
        Duration.seconds(seconds)
            .formatted(.units(allowed: allowed, width: .narrow, maximumUnitCount: 2, fractionalPart: .hide(rounded: .down)))
    }

    /// Shared full-style relative date formatter for MainActor callers.
    @MainActor static let relativeDateTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Shared file byte-count formatter for MainActor callers.
    @MainActor static let fileByteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
