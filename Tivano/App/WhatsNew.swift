import Foundation

/// Release notes read from the bundled CHANGELOG.md for versions installed since the previous run.
@MainActor
@Observable
final class WhatsNew {
    static let shared = WhatsNew()

    private enum Keys {
        static let installedVersion = "whatsNew_installedVersion"
        static let previousVersion = "whatsNew_previousVersion"
        static let seenVersion = "whatsNew_seenVersion"
        static let legacyUpdateCheckerLastChecked = "updateChecker_lastChecked"
        static let legacyUpdateCheckerRelease = "updateChecker_release"
    }

    struct Entry: Sendable {
        let versionText: String
        let version: AppVersion
        let body: String
    }

    let displayVersion: String
    private(set) var versionCount = 0
    private(set) var oldestIncludedVersion: String?
    private(set) var bulletsByCategory: [ReleaseNoteCategory: [String]] = [:]
    private(set) var seenVersion: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var hasContent: Bool {
        versionCount > 0 && ReleaseNoteCategory.allCases.contains { !bullets(for: $0).isEmpty }
    }

    var isUnread: Bool {
        hasContent && seenVersion != displayVersion
    }

    private init() {
        displayVersion = AppInfo.releaseVersion
        seenVersion = UserDefaults.standard.string(forKey: Keys.seenVersion)
    }

    func bullets(for category: ReleaseNoteCategory) -> [String] {
        bulletsByCategory[category] ?? []
    }

    func count(for category: ReleaseNoteCategory) -> Int {
        bullets(for: category).count
    }

    func markSeen() {
        UserDefaults.standard.set(displayVersion, forKey: Keys.seenVersion)
        seenVersion = displayVersion
    }

    /// Tracks version upgrades across launches. Existing users upgrading onto a build with this
    /// feature for the first time see the current version's notes; fresh installs start marked seen.
    static func recordLaunch() {
        let defaults = UserDefaults.standard
        let currentRaw = AppInfo.releaseVersion
        guard let current = AppVersion(currentRaw) else { return }

        if let installedRaw = defaults.string(forKey: Keys.installedVersion) {
            if let installed = AppVersion(installedRaw), installed < current {
                defaults.set(installedRaw, forKey: Keys.previousVersion)
            }
        } else {
            let isExistingUser = defaults.object(forKey: Keys.legacyUpdateCheckerLastChecked) != nil
                || defaults.object(forKey: Keys.legacyUpdateCheckerRelease) != nil
            if isExistingUser {
                defaults.removeObject(forKey: Keys.previousVersion)
            } else {
                defaults.set(currentRaw, forKey: Keys.seenVersion)
            }
        }
        defaults.set(currentRaw, forKey: Keys.installedVersion)
        shared.reload()
    }

    private func reload() {
        let defaults = UserDefaults.standard
        seenVersion = defaults.string(forKey: Keys.seenVersion)

        let displayVersion = self.displayVersion
        let previousRaw = defaults.string(forKey: Keys.previousVersion)
        loadTask?.cancel()
        // Read and scan CHANGELOG.md off the main thread so launch does not block on file I/O.
        loadTask = Task { [weak self] in
            let matched: [Entry] = await Task.detached(priority: .utility) {
                guard let current = AppVersion(displayVersion),
                      let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
                      let markdown = try? String(contentsOf: url, encoding: .utf8) else {
                    return []
                }
                let previous = previousRaw.flatMap(AppVersion.init)
                return Self.matchingEntries(
                    from: Self.parseChangelog(markdown),
                    current: current,
                    previous: previous
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            guard !matched.isEmpty else {
                self.clearEntries()
                return
            }

            let language = Bundle.main.preferredLocalizations.first ?? "en"
            var merged: [ReleaseNoteCategory: [String]] = [:]
            var seenBullets: [ReleaseNoteCategory: Set<String>] = [:]
            for entry in matched {
                let notes = UpdateReleaseNotesDigest.selectedNotes(entry.body, language: language)
                let digest = UpdateReleaseNotesDigest.parse(notes)
                for category in ReleaseNoteCategory.allCases {
                    guard let section = digest.section(for: category) else { continue }
                    for bullet in section.bullets {
                        if seenBullets[category, default: []].insert(bullet.lowercased()).inserted {
                            merged[category, default: []].append(bullet)
                        }
                    }
                }
            }

            self.versionCount = matched.count
            self.oldestIncludedVersion = matched.last?.versionText
            self.bulletsByCategory = merged
        }
    }

    private func clearEntries() {
        versionCount = 0
        oldestIncludedVersion = nil
        bulletsByCategory = [:]
    }

    /// Parses `## [version] - date` sections from CHANGELOG.md, skipping `[Unreleased]`.
    private nonisolated static func parseChangelog(_ markdown: String) -> [Entry] {
        var entries: [Entry] = []
        var currentHeader: (versionText: String, version: AppVersion)?
        var bodyLines: [String] = []

        func flushCurrent() {
            guard let header = currentHeader else { return }
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                entries.append(Entry(versionText: header.versionText, version: header.version, body: body))
            }
            currentHeader = nil
            bodyLines = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ["), let closeBracket = trimmed.dropFirst(4).firstIndex(of: "]") {
                flushCurrent()
                let versionText = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<closeBracket])
                    .trimmingCharacters(in: .whitespaces)
                if versionText.lowercased() != "unreleased", let version = AppVersion(versionText) {
                    currentHeader = (versionText, version)
                }
            } else if currentHeader != nil {
                bodyLines.append(line)
            }
        }
        flushCurrent()
        return entries
    }

    private nonisolated static func matchingEntries(from entries: [Entry], current: AppVersion, previous: AppVersion?) -> [Entry] {
        let includePrereleases = current.isPrerelease
        let eligible = entries
            .filter { entry in
                (includePrereleases || !entry.version.isPrerelease) && entry.version <= current
            }
            .sorted { $0.version > $1.version }

        if let previous {
            return eligible.filter { $0.version > previous }
        }
        // Without a previous run, show only the current version's own notes; an older section
        // would be mislabeled as this version's (local preview builds keep theirs in [Unreleased]).
        return eligible.first.map { $0.version == current ? [$0] : [] } ?? []
    }
}
