import Foundation

struct ClaudeSwapImportCandidate: Identifiable, Equatable, Sendable {
    var id: String
    var slot: String
    var email: String
    var accountID: String?
    var organizationID: String?
    var organizationName: String?
    var label: String?
}

enum ClaudeSwapImport {
    // Source: installed claude-swap 0.28.0, models.py, credentials.py and
    // migrations.py. The unversioned sequence.json format is shape-checked;
    // this does not claim compatibility with future storage migrations.
    private struct Index: Decodable {
        let sequence: [Int]
        let accounts: [String: Account]
    }

    private struct Account: Decodable {
        let email: String
        let uuid: String?
        let organizationUuid: String?
        let organizationName: String?
        let alias: String?
    }

    nonisolated static func candidates() throws -> [ClaudeSwapImportCandidate] {
        guard !CaptureRun.isEnabled else { return [] }
        guard let data = try ClaudeAccountCredentials.readFile(directory: root, name: "sequence.json") else { return [] }
        guard let index = try? JSONDecoder().decode(Index.self, from: data),
              Set(index.sequence).count == index.sequence.count,
              index.sequence.allSatisfy({ $0 > 0 && index.accounts[String($0)] != nil }) else {
            throw ClaudeCredentialError.invalidIndex
        }
        var result: [ClaudeSwapImportCandidate] = []
        for (slot, account) in index.accounts {
            guard let number = Int(slot), number > 0, String(number) == slot,
                  safeComponent(account.email), !account.email.isEmpty else {
                throw ClaudeCredentialError.invalidIndex
            }
            result.append(ClaudeSwapImportCandidate(
                id: "claude-swap:" + slot,
                slot: slot, email: account.email,
                accountID: nonempty(account.uuid),
                organizationID: nonempty(account.organizationUuid),
                organizationName: nonempty(account.organizationName), label: nonempty(account.alias)
            ))
        }
        let positions = Dictionary(uniqueKeysWithValues: index.sequence.enumerated().map { (String($0.element), $0.offset) })
        return result.sorted {
            let lhs = positions[$0.slot] ?? Int.max
            let rhs = positions[$1.slot] ?? Int.max
            return lhs == rhs ? $0.slot.localizedStandardCompare($1.slot) == .orderedAscending : lhs < rhs
        }
    }

    nonisolated static func credential(for candidate: ClaudeSwapImportCandidate) throws -> Data {
        try requireCurrent(candidate)
        let name = ".creds-\(candidate.slot)-\(candidate.email).enc"
        let encoded = try ClaudeAccountCredentials.readFile(directory: root + "/credentials", name: name)
        let data: Data
        if let encoded {
            guard !encoded.isEmpty, let text = String(data: encoded, encoding: .utf8),
                  let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  !decoded.isEmpty else { throw ClaudeCredentialError.invalidCredential }
            // A valid .enc is authoritative in 0.28.0. A corrupt present file
            // is rejected instead of importing a potentially stale fallback.
            data = try ClaudeAccountCredentials.validated(decoded)
        } else {
            let account = "account-\(candidate.slot)-\(candidate.email)"
            if let current = try ClaudeAccountCredentials.readKeychain(service: "claude-swap", account: account) {
                data = try ClaudeAccountCredentials.validated(current)
            } else if let legacy = try ClaudeAccountCredentials.readKeychain(service: "claude-code", account: account) {
                data = try ClaudeAccountCredentials.validated(legacy)
            } else {
                throw ClaudeCredentialError.missingCredential
            }
        }
        // A Keychain authorization dialog can outlive a slot edit. Never return
        // its credential under the identity selected before that edit.
        try requireCurrent(candidate)
        return try ClaudeAccountCredentials.sanitizedImport(data)
    }

    private nonisolated static func requireCurrent(_ candidate: ClaudeSwapImportCandidate) throws {
        guard try candidates().contains(candidate) else { throw ClaudeCredentialError.changedCandidate }
    }

    private nonisolated static var root: String {
        LoginEnvironment.homeDirectory + "/.claude-swap-backup"
    }

    private nonisolated static func safeComponent(_ value: String) -> Bool {
        value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private nonisolated static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
