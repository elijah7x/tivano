import Foundation

/// A provider saying the account's usage limit is spent, and when it comes back.
enum UsageLimitSignal {
    /// Bounds provider input before Duration's integer conversion and clock arithmetic.
    static let maximumWait: TimeInterval = 365 * 86_400

    static func supportsWait(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds > 0 && seconds <= maximumWait
    }

    static func supportsResetTime(_ date: Date, now: Date = .now) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && now.timeIntervalSinceReferenceDate.isFinite
            && date >= .distantPast && date <= .distantFuture
            && now >= .distantPast && now <= .distantFuture
            && supportsWait(date.timeIntervalSince(now))
    }

    /// Whether an error message is the provider refusing to work until a usage limit resets:
    /// Claude's and Codex's wording, or the rate, spend, quota and credit phrasing that API
    /// providers return.
    static func matches(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("usage limit") || lower.contains("hit your limit") || lower.contains("usage_limit")
            || lower.contains("limit reached") || lower.contains("out of extra usage")
            || lower.contains("account's rate limit") || lower.contains("spend limit")
            || lower.contains("usage credits are required") || lower.contains("quota will reset")
            || lower.contains("exhausted your capacity") || lower.contains("resource_exhausted")
            || lower.contains("resource exhausted") || lower.contains("insufficient_quota")
            || lower.contains("out of credits")
    }

    private static let unixTimestampRegex = try! NSRegularExpression(pattern: #"\|\s*(\d{9,})"#)
    private static let resetClockRegex = try! NSRegularExpression(pattern: #"(?i)resets?(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#)
    private static let timeZoneRegex = try! NSRegularExpression(pattern: #"\(([A-Za-z_]+/[A-Za-z_]+)\)"#)
    private static let retryAfterMillisRegexes = [
        try! NSRegularExpression(pattern: #"(?i)retry-after-ms\s*[:=]\s*(\d+)"#),
        try! NSRegularExpression(pattern: #"(?i)provider requested\s+(\d+)\s*ms\s+wait"#),
    ]
    private static let relativeWaitRegexes = [
        try! NSRegularExpression(pattern: #"(?i)(?:try again|retry)\s+in\s+~?\s*"#),
        try! NSRegularExpression(pattern: #"(?i)resets?\s+(?:after|in)\s+"#),
    ]
    private static let durationTokenRegex = try! NSRegularExpression(
        pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(milliseconds?|ms|days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?![a-z])"#
    )
    private static let secondsPerUnit: [String: TimeInterval] = [
        "d": 86_400, "day": 86_400, "days": 86_400,
        "h": 3_600, "hr": 3_600, "hrs": 3_600, "hour": 3_600, "hours": 3_600,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "ms": 0.001, "millisecond": 0.001, "milliseconds": 0.001,
    ]

    private static func firstRange(
        of regex: NSRegularExpression,
        in string: String,
        from start: String.Index,
        options: NSRegularExpression.MatchingOptions = []
    ) -> Range<String.Index>? {
        let nsRange = NSRange(start..<string.endIndex, in: string)
        guard let hit = regex.firstMatch(in: string, options: options, range: nsRange) else { return nil }
        return Range(hit.range, in: string)
    }

    /// The reset time an error message carries, when it does: a Unix timestamp after a bar
    /// ("usage limit reached|1757865600"), a clock time such as "resets 3pm" or "resets at
    /// 3:30 pm", taken as the next such time from now, or a wait (see `waitTime`) counted
    /// from now.
    static func resetTime(in text: String, now: Date = .now) -> Date? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              now >= .distantPast, now <= .distantFuture else { return nil }
        if let match = firstRange(of: unixTimestampRegex, in: text, from: text.startIndex) {
            let digits = text[match].drop { !$0.isNumber }
            guard let raw = TimeInterval(digits), raw.isFinite, raw > 0 else { return nil }
            // Some providers write milliseconds.
            let seconds = raw > 1e11 ? raw / 1_000 : raw
            guard seconds.isFinite, seconds > 0 else { return nil }
            let date = Date(timeIntervalSince1970: seconds)
            return supportsResetTime(date, now: now) ? date : nil
        }
        if let match = firstRange(of: resetClockRegex, in: text, from: text.startIndex) {
            let clock = String(text[match])
            let numbers = clock.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            guard let hourText = numbers.first, var hour = Int(hourText) else { return nil }
            let minute = numbers.count > 1 ? Int(numbers[1]) ?? 0 : 0
            guard (1...12).contains(hour), (0...59).contains(minute) else { return nil }
            let isPM = clock.lowercased().hasSuffix("pm")
            if isPM, hour < 12 { hour += 12 }
            if !isPM, hour == 12 { hour = 0 }
            var calendar = Calendar.current
            if let zone = firstRange(of: timeZoneRegex, in: text, from: text.startIndex),
               let timeZone = TimeZone(identifier: text[zone].trimmingCharacters(in: CharacterSet(charactersIn: "()"))) {
                calendar.timeZone = timeZone
            }
            let components = DateComponents(hour: hour, minute: minute)
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
                .flatMap { supportsResetTime($0, now: now) ? $0 : nil }
        }
        return waitTime(in: text).flatMap {
            let date = now.addingTimeInterval($0)
            return supportsResetTime(date, now: now) ? date : nil
        }
    }

    /// The wait an error message names, the longest when it names several: "retry-after-ms=1800000"
    /// or a provider's request for a fixed millisecond wait, "Try again in ~158 min", "Please retry
    /// in 12s", "reset after 18h31m10s", "resets in 3 days". Every phrase is weighed on its own, so
    /// the longest wait is taken, rather than adding independent waits together.
    static func waitTime(in text: String) -> TimeInterval? {
        var waits: [TimeInterval] = []
        for regex in retryAfterMillisRegexes {
            var index = text.startIndex
            while let match = firstRange(of: regex, in: text, from: index) {
                guard let milliseconds = TimeInterval(String(text[match].filter(\.isNumber))),
                      milliseconds.isFinite, milliseconds > 0,
                      milliseconds <= maximumWait * 1_000 else { return nil }
                let seconds = milliseconds / 1_000
                guard supportsWait(seconds) else { return nil }
                waits.append(seconds)
                index = match.upperBound
            }
        }
        for regex in relativeWaitRegexes {
            var index = text.startIndex
            while let match = firstRange(of: regex, in: text, from: index) {
                guard let seconds = duration(in: text[match.upperBound...]) else { return nil }
                waits.append(seconds)
                index = match.upperBound
            }
        }
        return waits.max().flatMap { supportsWait($0) ? $0 : nil }
    }

    /// "18h31m10s", "2 hours 5 min", "3 days", "158 min", "12s", "5 ms": the units of one
    /// contiguous run add up. A bare number carries no unit and so no duration, and `ms` is
    /// milliseconds, not minutes plus seconds.
    private static func duration(in text: Substring) -> TimeInterval? {
        var total: TimeInterval = 0
        var found = false
        let lower = text.lowercased()
        var index = lower.startIndex
        while true {
            while index < lower.endIndex, lower[index].isWhitespace { index = lower.index(after: index) }
            guard let match = firstRange(of: durationTokenRegex, in: lower, from: index, options: [.anchored]),
                  match.lowerBound == index else { break }
            let piece = lower[match]
            let digits = piece.prefix { $0.isNumber || $0 == "." }
            let unit = piece.dropFirst(digits.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let amount = TimeInterval(digits), let scale = secondsPerUnit[unit],
                  amount.isFinite, amount >= 0, amount <= maximumWait / scale else { return nil }
            let seconds = amount * scale
            guard seconds.isFinite, (total + seconds).isFinite,
                  total + seconds <= maximumWait else { return nil }
            total += seconds
            found = true
            index = match.upperBound
        }
        return found && supportsWait(total) ? total : nil
    }

    /// "3:31 PM" today, "tomorrow at 9:00 AM" or "Thursday at 9:00 AM" further out.
    static func format(_ date: Date) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              date >= .distantPast, date <= .distantFuture else {
            return String(localized: "Unknown reset time")
        }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return String(format: String(localized: "tomorrow at %@"), time) }
        if let week = calendar.date(byAdding: .day, value: 6, to: .now), date < week {
            return String(format: String(localized: "%@ at %@"), date.formatted(.dateTime.weekday(.wide)), time)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
