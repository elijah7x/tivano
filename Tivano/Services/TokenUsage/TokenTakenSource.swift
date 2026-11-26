import AppKit
import Foundation

enum TokenTakenStatus: Equatable, Sendable {
    case notInstalled
    case installed(version: String?)
}

enum TokenUsageFetchError: Error, Equatable, Sendable {
    case cliMissing
    case noData
    case unsupportedSchema
    case timedOut
    case failed(status: Int32, message: String)
    case schemaChanged(missing: [String])
    case cancelled
    case other(String)
}

enum TokenTakenSource {
    static let bundleIdentifier = "io.github.elijah7x.TokenTaken"
    static let sourceID = "token-taken"
    static let downloadURL = URL(string: "https://elijah.ac.cn/tt")!
    static let projectURL = URL(string: "https://github.com/elijah7x/token-taken")!

    private static let decoder = JSONDecoder()
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func appURL() -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    @concurrent
    static func detect() async -> TokenTakenStatus {
        detectSync()
    }

    private static func detectSync() -> TokenTakenStatus {
        guard let url = appURL() else { return .notInstalled }
        let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return .installed(version: version)
    }

    @concurrent
    static func fetch(
        lastDays: Int,
        timeZone: TimeZone,
        scope: TokenUsageScope
    ) async throws -> TokenUsageSnapshot {
        try checkCancellation()
        guard lastDays > 0 else { throw TokenUsageFetchError.other("lastDays") }
        let (since, until) = try DayFormatterCache.shared.withFormatter(for: timeZone) { calendar, formatter in
            let today = calendar.startOfDay(for: Date())
            guard let start = calendar.date(byAdding: .day, value: -(lastDays - 1), to: today) else {
                throw TokenUsageFetchError.other("lastDays")
            }
            return (formatter.string(from: start), formatter.string(from: today))
        }

        guard let appURL = appURL() else {
            throw TokenUsageFetchError.other("not installed")
        }
        let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let cliURL = appURL.appendingPathComponent("Contents/Helpers/token-taken")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cliURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw TokenUsageFetchError.cliMissing
        }

        let arguments = [
            "export",
            "--format", "json",
            "--schema", "1",
            "--since", since,
            "--until", until,
            "--tz", timeZone.identifier,
        ]
        let result: ShellResult
        do {
            result = try await Shell.run(cliURL, arguments, timeout: 30)
        } catch is CancellationError {
            throw TokenUsageFetchError.cancelled
        } catch {
            if Task.isCancelled { throw TokenUsageFetchError.cancelled }
            throw TokenUsageFetchError.other(error.localizedDescription)
        }
        try checkCancellation()
        if result.timedOut { throw TokenUsageFetchError.timedOut }

        let stderrMessage = result.errorOutput.trimmed
        if result.status != 0 {
            if result.status == 3 {
                throw TokenUsageFetchError.noData
            }
            if result.status == 2, stderrMessage.localizedCaseInsensitiveContains("schema") {
                throw TokenUsageFetchError.unsupportedSchema
            }
            throw TokenUsageFetchError.failed(status: result.status, message: stderrMessage)
        }

        let decoded = try decode(result.stdout, scope: scope)
        try checkCancellation()
        var total: Int64 = 0
        for row in decoded.rows {
            let sum = total.addingReportingOverflow(row.totalTokens)
            guard !sum.overflow else {
                throw TokenUsageFetchError.schemaChanged(missing: ["data.rows.total"])
            }
            total = sum.partialValue
        }

        var warnings = decoded.warnings
        let hasPricedRow = decoded.rows.contains { $0.costUSD != nil }
        let hasUnpricedRow = decoded.rows.contains { $0.costUSD == nil }
        if hasPricedRow && hasUnpricedRow && !warnings.contains("Some models are unpriced") {
            warnings.append("Some models are unpriced")
        }

        return TokenUsageSnapshot(
            schemaVersion: TokenUsageSnapshot.currentSchemaVersion,
            source: TokenUsageSourceInfo(
                id: sourceID,
                displayName: "Token Taken",
                version: version,
                fetchedFrom: cliURL.path
            ),
            fetchedAt: Date(),
            from: since,
            to: until,
            timeZone: timeZone.identifier,
            scope: scope,
            rows: decoded.rows,
            warnings: warnings
        )
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw TokenUsageFetchError.cancelled }
    }

    private static func decode(
        _ data: Data,
        scope: TokenUsageScope
    ) throws -> (rows: [TokenUsageRow], warnings: [String]) {
        guard let value = try? decoder.decode(Value.self, from: data),
              let root = value.object else {
            throw TokenUsageFetchError.schemaChanged(missing: ["$"])
        }

        var missing: Set<String> = []
        if case .integer(let schemaVersion) = root["schemaVersion"] {
            guard schemaVersion == 1 else {
                throw TokenUsageFetchError.unsupportedSchema
            }
        } else {
            missing.insert("schemaVersion")
        }

        let dataObject = root["data"]?.object
        if dataObject == nil { missing.insert("data") }
        let rawRows = dataObject?["rows"]?.array
        if dataObject != nil && rawRows == nil { missing.insert("data.rows") }

        var warnings: [String] = []
        if let rawWarnings = root["warnings"]?.array {
            for (index, warningValue) in rawWarnings.enumerated() {
                let path = "warnings[\(index)]"
                guard let warningObject = warningValue.object else {
                    missing.insert(path)
                    continue
                }
                if let message = requiredString(warningObject["message"], path: "\(path).message", missing: &missing) {
                    warnings.append(message)
                }
            }
        } else {
            missing.insert("warnings")
        }

        var rows: [TokenUsageRow] = []
        var positions: [RowKey: Int] = [:]
        for (index, rowValue) in (rawRows ?? []).enumerated() {
            let path = "data.rows[\(index)]"
            guard let rowObject = rowValue.object else {
                missing.insert(path)
                continue
            }
            let day = requiredString(rowObject["day"], path: "\(path).day", missing: &missing)
            let deviceID = requiredString(rowObject["deviceID"], path: "\(path).deviceID", missing: &missing)
            let tool = requiredString(rowObject["sourceID"], path: "\(path).sourceID", missing: &missing)
            let model = requiredString(rowObject["modelID"], path: "\(path).modelID", missing: &missing)
            let input = count(rowObject["input"], path: "\(path).input", missing: &missing)
            let cached = count(rowObject["cacheRead"], path: "\(path).cacheRead", missing: &missing)
            let cacheWrite = count(rowObject["cacheWrite"], path: "\(path).cacheWrite", missing: &missing)
            let output = count(rowObject["output"], path: "\(path).output", missing: &missing)
            let reasoning = count(rowObject["reasoning"], path: "\(path).reasoning", missing: &missing)
            let total = count(rowObject["total"], path: "\(path).total", missing: &missing)
            let costUSD = optionalCost(rowObject["estimatedUSD"], path: "\(path).estimatedUSD", missing: &missing)

            guard let day, let deviceID, let tool, let model,
                  let input, let cached, let cacheWrite, let output, let reasoning, let total,
                  total > 0 else {
                continue
            }
            if scope == .personal, deviceID.hasPrefix("account-") {
                continue
            }

            let row = TokenUsageRow(
                day: day,
                tool: tool,
                model: model,
                inputTokens: input,
                cachedInputTokens: cached,
                cacheWriteTokens: cacheWrite,
                outputTokens: output,
                reasoningTokens: reasoning,
                totalTokens: total,
                costUSD: costUSD
            )
            let key = RowKey(day: day, tool: tool, model: model)
            if let existingIndex = positions[key] {
                merge(row, into: &rows[existingIndex], path: path, missing: &missing)
            } else {
                positions[key] = rows.count
                rows.append(row)
            }
        }

        guard missing.isEmpty else {
            throw TokenUsageFetchError.schemaChanged(missing: missing.sorted())
        }
        return (rows, warnings)
    }

    private static func requiredString(_ value: Value?, path: String, missing: inout Set<String>) -> String? {
        guard let string = value?.string, !string.isEmpty else {
            missing.insert(path)
            return nil
        }
        return string
    }

    private static func count(_ value: Value?, path: String, missing: inout Set<String>) -> Int64? {
        guard case .integer(let number) = value, number >= 0 else {
            missing.insert(path)
            return nil
        }
        return number
    }

    private static func optionalCost(_ value: Value?, path: String, missing: inout Set<String>) -> Decimal? {
        guard let value else { return nil }
        if case .null = value { return nil }
        let decimal: Decimal?
        switch value {
        case .integer(let number): decimal = Decimal(number)
        case .decimal(let number): decimal = number
        case .string(let string):
            let trimmed = trimmedJSONWhitespace(string)
            if isPlainJSONNumber(trimmed) {
                decimal = Decimal(string: String(trimmed), locale: posixLocale)
            } else {
                decimal = try? decoder.decode(Decimal.self, from: Data(string.utf8))
            }
        default:
            decimal = nil
        }
        guard let decimal, !decimal.isNaN, decimal >= 0 else {
            missing.insert(path)
            return nil
        }
        return decimal
    }

    private static func trimmedJSONWhitespace(_ string: String) -> Substring {
        let utf8 = string.utf8
        let isJSONSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        var start = utf8.startIndex
        var end = utf8.endIndex
        while start < end, isJSONSpace(utf8[start]) {
            start = utf8.index(after: start)
        }
        while end > start {
            let before = utf8.index(before: end)
            guard isJSONSpace(utf8[before]) else { break }
            end = before
        }
        return string[start..<end]
    }

    private static func isPlainJSONNumber(_ string: Substring) -> Bool {
        var bytes = string.utf8.makeIterator()
        guard var current = bytes.next() else { return false }
        if current == UInt8(ascii: "-") {
            guard let next = bytes.next() else { return false }
            current = next
        }
        if current == UInt8(ascii: "0") {
            guard let next = bytes.next() else { return true }
            current = next
        } else if current >= UInt8(ascii: "1") && current <= UInt8(ascii: "9") {
            while true {
                guard let next = bytes.next() else { return true }
                if next >= UInt8(ascii: "0") && next <= UInt8(ascii: "9") { continue }
                current = next
                break
            }
        } else {
            return false
        }
        guard current == UInt8(ascii: ".") else { return false }
        guard let firstFraction = bytes.next(),
              firstFraction >= UInt8(ascii: "0") && firstFraction <= UInt8(ascii: "9") else {
            return false
        }
        while let next = bytes.next() {
            guard next >= UInt8(ascii: "0") && next <= UInt8(ascii: "9") else { return false }
        }
        return true
    }


    private static func merge(_ row: TokenUsageRow, into existing: inout TokenUsageRow, path: String, missing: inout Set<String>) {
        let counts: [(String, WritableKeyPath<TokenUsageRow, Int64>)] = [
            ("input", \.inputTokens),
            ("cacheRead", \.cachedInputTokens),
            ("cacheWrite", \.cacheWriteTokens),
            ("output", \.outputTokens),
            ("reasoning", \.reasoningTokens),
            ("total", \.totalTokens),
        ]
        for (field, keyPath) in counts {
            let sum = existing[keyPath: keyPath].addingReportingOverflow(row[keyPath: keyPath])
            if sum.overflow {
                missing.insert("\(path).\(field)")
            } else {
                existing[keyPath: keyPath] = sum.partialValue
            }
        }
        if let first = existing.costUSD, let second = row.costUSD {
            let sum = first + second
            if sum.isNaN { missing.insert("\(path).estimatedUSD") }
            existing.costUSD = sum
        } else {
            existing.costUSD = nil
        }
    }

    private struct RowKey: Hashable {
        let day: String
        let tool: String
        let model: String
    }

    // Decode the shape before validating fields so one response reports every missing path.
    private enum Value: Decodable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case integer(Int64)
        case decimal(Decimal)
        case boolean(Bool)
        case null
        case invalidNumber

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
            else if let value = try? container.decode(Int64.self) { self = .integer(value) }
            else if let value = try? container.decode(Decimal.self) { self = .decimal(value) }
            else if let value = try? container.decode([String: Value].self) { self = .object(value) }
            else if let value = try? container.decode([Value].self) { self = .array(value) }
            else { self = .invalidNumber }
        }

        var object: [String: Value]? {
            if case .object(let value) = self { return value }
            return nil
        }

        var array: [Value]? {
            if case .array(let value) = self { return value }
            return nil
        }

        var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }
    }
}
