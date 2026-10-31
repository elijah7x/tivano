import Foundation

/// Masks credentials in text bound for a third party. Mirrors mask() in
/// scripts/hydra_decisions_replay.py so live and replayed payloads match; change both together.
enum SecretMask {
    // ICU's \z matches Python's \Z: the absolute end, including after a final newline.
    private static let privateKey = try! NSRegularExpression(
        pattern: #"-----BEGIN [^-]*KEY-----.*?(?:-----END [^-]*KEY-----|\z)"#,
        options: .dotMatchesLineSeparators
    )
    private static let token = try! NSRegularExpression(
        pattern: #"\b(?:(?:sk-(?:ant-)?|ghp_|github_pat_|xox[abp]-|AKIA)[A-Za-z0-9_./+=-]+|AIza[0-9A-Za-z_-]{35})"#
    )
    private static let zai = try! NSRegularExpression(
        pattern: #"\b[0-9a-f]{32}\.[A-Za-z0-9]{16}\b"#
    )
    private static let bearer = try! NSRegularExpression(
        pattern: #"\bBearer\s+[^\s"',;}]+"#,
        options: .caseInsensitive
    )

    static func masked(_ text: String) -> String {
        [privateKey, token, zai, bearer].reduce(text) { value, expression in
            expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: "[masked]"
            )
        }
    }

    static func masked(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(masked(text))
        case .array(let values):
            return .array(values.map { masked($0) })
        case .object(let values):
            var result: [String: JSONValue] = [:]
            for (key, value) in values {
                result[masked(key)] = masked(value)
            }
            return .object(result)
        default:
            return value
        }
    }
}
