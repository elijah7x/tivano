import AppKit
import Foundation
import UserNotifications

/// A release version as GitHub tags it: `v1.2.3` or `1.2`. Anything with a prerelease suffix
/// (`-nightly.…`, `-beta.1`) is not a version the app offers, so it does not parse.
struct AppVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    let components: [Int]

    init?(_ raw: String) {
        var text = raw.trimmed
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        components = numbers
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// The tag without its leading v: the version as the release calls itself.
    static func text(ofTag tag: String) -> String {
        var text = tag.trimmed
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// A newer release on GitHub: what the About page describes and the installer downloads.
struct AvailableUpdate: Codable, Equatable, Sendable {
    var version: String
    var tag: String
    var downloadURL: URL
    var size: Int64?
    /// Present for static feeds; old cached/API results remain decodable without it.
    var sha256: String? = nil
    /// The release description, Markdown as written on GitHub.
    var notes: String
    var releasedAt: Date?
    /// The release page, for reading the notes in the browser.
    var pageURL: URL

    /// Only exact, checksummed assets can move between the two trusted origins.
    var fallbackDownloadURL: URL? {
        guard let sha256, sha256.count == 64,
              sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        let mirror = "https://elijah.ac.cn/tivano/releases/\(tag)/Tivano-\(version).dmg"
        let canonical = "https://github.com/elijah7x/tivano/releases/download/\(tag)/Tivano-\(version).dmg"
        if downloadURL.absoluteString == mirror { return URL(string: canonical) }
        if downloadURL.absoluteString == canonical { return URL(string: mirror) }
        return nil
    }
}

/// Checks the app's GitHub releases for a newer version and remembers what it found.
///
/// A check compares public static feeds concurrently within a bounded response window,
/// falling back to the releases API, and keeps the newest observed stable version with a disk
/// image, and compares it with the running build. The result is persisted, so the About page
/// shows a known update the moment it opens, and `updateAvailable` is recomputed from the
/// running version, so an update that was installed stops being one. Checks run on launch,
/// every six hours while the app runs, when it comes back to the front after a long
/// while, and whenever the About page opens or asks.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// The fork's repository on GitHub.
    static let projectURL = URL(string: "https://github.com/elijah7x/tivano")!
    private static let apiURL = URL(string: "https://api.github.com/repos/elijah7x/tivano/releases?per_page=20")!
    private static let feedURLs = [
        URL(string: "https://elijah.ac.cn/tivano/updates.json")!,
        URL(string: "https://elijah7x.github.io/tivano/updates.json")!,
        URL(string: "https://raw.githubusercontent.com/elijah7x/tivano/gh-pages/updates.json")!,
    ]

    /// How often the background check runs, and how stale a check may be before the app
    /// coming to the front runs another.
    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let launchDelay: TimeInterval = 8

    private enum Keys {
        static let update = "updateChecker_release"
        static let lastChecked = "updateChecker_lastChecked"
        static let notifiedVersion = "updateChecker_notifiedVersion"
    }

    let currentVersion = AppInfo.version

    private(set) var update: AvailableUpdate?
    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?
    /// Why the last check found nothing, for the About page after a manual check.
    private(set) var lastError: String?

    /// Only a version newer than the running one is an update; anything else the last check
    /// found is kept for the notes but reads as up to date.
    var updateAvailable: Bool {
        guard let update, let latest = AppVersion(update.version), let current = AppVersion(currentVersion) else { return false }
        return latest > current
    }

    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var previewVersion: String?
    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Tivano/\(AppInfo.version)", "Accept": "application/json"]
        return URLSession(configuration: configuration)
    }()

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.update),
           let saved = try? JSONDecoder().decode(AvailableUpdate.self, from: data) {
            update = saved
        }
        lastCheckedAt = defaults.object(forKey: Keys.lastChecked) as? Date
        #if DEBUG
        // `--preview-update 9.9.9` shows the update story without a newer release: the latest
        // real release is offered under that version. Pressing Update & restart then installs
        // that release for real, which only passes verification when its version is the one shown.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--preview-update"), index + 1 < arguments.count {
            previewVersion = arguments[index + 1]
        }
        #endif
    }

    // MARK: - Schedule

    /// The launch check, the six-hourly one after it, and a catch-up when the app comes to
    /// the front after a long sleep.
    func startBackgroundChecks() {
        guard backgroundTask == nil, !CaptureRun.isEnabled, !AppInfo.isDevelopment else { return }
        backgroundTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchDelay))
            while !Task.isCancelled {
                await self?.check(background: true)
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let stale = lastCheckedAt.map { Date.now.timeIntervalSince($0) > Self.checkInterval } ?? true
                if stale { await check(background: true) }
            }
        }
    }

    // MARK: - Checking

    /// Reads the releases and updates the state. Returns whether an update is available
    /// afterwards. A background check also posts the one notification a new version gets.
    @discardableResult
    func check(background: Bool = false) async -> Bool {
        guard !AppInfo.isDevelopment else { return false }
        guard !isChecking else { return updateAvailable }
        isChecking = true
        defer { isChecking = false }
        do {
            var found = try await fetchUpdate()
            if let previewVersion {
                found.version = previewVersion
            }
            if found.size == nil {
                found.size = await downloadSize(of: found.downloadURL)
            }
            try Task.checkCancellation()
            update = found
            lastError = nil
            lastCheckedAt = .now
            persist()
            if background, updateAvailable {
                notifyOnce(about: found)
            }
        } catch is CancellationError {
            return updateAvailable
        } catch {
            guard !Task.isCancelled else { return updateAvailable }
            lastError = (error as? UpdateError)?.errorDescription ?? Chrome.localized("Couldn't reach any update source.")
            lastCheckedAt = .now
            UserDefaults.standard.set(lastCheckedAt, forKey: Keys.lastChecked)
        }
        return updateAvailable
    }

    private func fetchUpdate() async throws -> AvailableUpdate {
        // A whole-resource deadline also bounds slow trickles, not only idle waits.
        // Verified in the SDK NSURLSession.h timeoutIntervalForResource contract.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Tivano/\(AppInfo.version)", "Accept": "application/json"]
        let feedSession = URLSession(configuration: configuration)
        defer { feedSession.invalidateAndCancel() }
        let candidates = await withTaskGroup(of: AvailableUpdate?.self, returning: [AvailableUpdate].self) { group in
            for url in Self.feedURLs {
                group.addTask {
                    do {
                        let (data, response) = try await feedSession.data(from: url)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                        return try await Self.updateFromFeed(data)
                    } catch {
                        return nil
                    }
                }
            }
            var results: [AvailableUpdate] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
        try Task.checkCancellation()
        // Arrival order breaks same-version ties; versions always outrank latency.
        let best = candidates.reduce(nil as AvailableUpdate?) { best, candidate in
            guard let best else { return candidate }
            return AppVersion(candidate.version)! > AppVersion(best.version)! ? candidate : best
        }
        if let found = best {
            let peers = candidates.filter { AppVersion($0.version) == AppVersion(found.version) }
            guard peers.allSatisfy({ $0.sha256 == found.sha256 && $0.size == found.size }) else {
                throw UpdateError.invalidFeed
            }
            let olderThanSaved = update.flatMap { AppVersion($0.version) }
                .map { $0 > AppVersion(found.version)! } ?? false
            if !olderThanSaved { return try Self.reconcile(found, with: update) }
        }
        let releases: [GitHubRelease]
        do {
            releases = try await fetchReleases()
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard let found = Self.newestRelease(in: releases) else { throw UpdateError.noRelease }
        return try Self.reconcile(found, with: update)
    }

    private static func reconcile(_ found: AvailableUpdate, with saved: AvailableUpdate?) throws -> AvailableUpdate {
        guard let saved, let old = AppVersion(saved.version), let new = AppVersion(found.version) else { return found }
        guard new >= old else { throw UpdateError.noRelease }
        if new == old, let knownDigest = saved.sha256 {
            if let digest = found.sha256 {
                guard digest == knownDigest, saved.size == nil || saved.size == found.size else {
                    throw UpdateError.invalidFeed
                }
            } else {
                // API fallback must not erase the integrity metadata of a known release.
                return saved
            }
        }
        return found
    }

    static func updateFromFeed(_ data: Data) throws -> AvailableUpdate {
        guard data.count <= 1_048_576 else { throw UpdateError.invalidFeed }
        let feed = try JSONDecoder().decode(StaticUpdateFeed.self, from: data)
        guard feed.schemaVersion == 1, let found = newestRelease(in: feed.releases),
              found.releasedAt != nil, let digest = found.sha256, digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              let size = found.size, size > 0 else { throw UpdateError.invalidFeed }
        let expected = "https://github.com/elijah7x/tivano/releases/download/\(found.tag)/Tivano-\(found.version).dmg"
        let mirror = "https://elijah.ac.cn/tivano/releases/\(found.tag)/Tivano-\(found.version).dmg"
        guard [expected, mirror].contains(found.downloadURL.absoluteString) else { throw UpdateError.invalidFeed }
        return found
    }

    private func fetchReleases() async throws -> [GitHubRelease] {
        try Task.checkCancellation()
        var token = GitHubCredentials.storedToken()
        if token == nil, !UserDefaults.standard.bool(forKey: "GitHubCLIDeclined") {
            await LoginEnvironment.load()
            token = await GitHubCredentials.cliToken()
        }
        try Task.checkCancellation()
        do {
            return try await fetchReleases(token: token)
        } catch UpdateError.unauthorized where token != nil {
            // An expired login must not prevent checking this public repository.
            return try await fetchReleases(token: nil)
        }
    }

    private func fetchReleases(token: String?) async throws -> [GitHubRelease] {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request, delegate: GitHubUpdateRequestDelegate())
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse(-1) }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateError.httpFailure(data: data, response: http, authenticated: token != nil)
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    /// The newest stable release that ships a disk image. Prereleases and drafts never
    /// count, whatever their date.
    static func newestRelease(in releases: [GitHubRelease]) -> AvailableUpdate? {
        var best: (AppVersion, AvailableUpdate)?
        for release in releases {
            guard !release.upcomingRelease, let version = AppVersion(release.tagName) else { continue }
            if let releasedAt = release.releasedAt, releasedAt > .now { continue }
            guard let asset = release.assets.first(where: { $0.isDiskImage }) else { continue }
            guard let downloadURL = URL(string: asset.browserDownloadURL) else { continue }
            let candidate = AvailableUpdate(
                version: AppVersion.text(ofTag: release.tagName),
                tag: release.tagName,
                downloadURL: downloadURL,
                size: asset.size,
                sha256: asset.sha256,
                notes: release.body ?? "",
                releasedAt: release.releasedAt,
                pageURL: projectURL.appending(path: "releases/tag/\(release.tagName)")
            )
            if let current = best, current.0 >= version { continue }
            best = (version, candidate)
        }
        return best?.1
    }

    /// The image's size from a HEAD request, for the About page. Nothing depends on it.
    private func downloadSize(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.expectedContentLength > 0 else { return nil }
        return http.expectedContentLength
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let update, let data = try? JSONEncoder().encode(update) {
            defaults.set(data, forKey: Keys.update)
        } else {
            defaults.removeObject(forKey: Keys.update)
        }
        defaults.set(lastCheckedAt, forKey: Keys.lastChecked)
    }

    // MARK: - Notification

    /// One banner per version, the first time a background check finds it. Tapping it opens
    /// Settings on About, where the update installs.
    private func notifyOnce(about update: AvailableUpdate) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Keys.notifiedVersion) != update.version else { return }
        defaults.set(update.version, forKey: Keys.notifiedVersion)
        let content = UNMutableNotificationContent()
        content.title = String(format: Chrome.localized("Tivano %@ is available"), update.version)
        content.body = Chrome.localized("Open Settings › About to update and restart.")
        content.userInfo = ["update": update.version]
        let request = UNNotificationRequest(identifier: "update-\(update.version)", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            try? await center.add(request)
        }
    }
}

/// Release metadata stays on the API host; a redirect must not carry a token to a download host.
private final class GitHubUpdateRequestDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme == "https", request.url?.host == "api.github.com",
              request.url?.port == nil || request.url?.port == 443 else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct StaticUpdateFeed: Decodable {
    var schemaVersion: Int
    var releases: [GitHubRelease]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case releases
    }
}

enum UpdateError: LocalizedError {
    case invalidFeed
    case noRelease
    case badResponse(Int)
    case unauthorized
    case rateLimited(until: Date?, authenticated: Bool)

    static func httpFailure(data: Data, response: HTTPURLResponse, authenticated: Bool) -> UpdateError {
        if response.statusCode == 401 { return .unauthorized }
        if response.statusCode == 403 || response.statusCode == 429 {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            if response.statusCode == 429 || remaining == "0" || retryAfter != nil
                || message?.localizedCaseInsensitiveContains("rate limit") == true {
                var until: Date?
                if let seconds = retryAfter.flatMap(TimeInterval.init) {
                    until = .now.addingTimeInterval(max(0, seconds))
                } else if remaining == "0",
                          let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
                    until = Date(timeIntervalSince1970: reset)
                }
                return .rateLimited(until: until, authenticated: authenticated)
            }
        }
        return .badResponse(response.statusCode)
    }

    var errorDescription: String? {
        switch self {
        case .invalidFeed: return Chrome.localized("The update information could not be read.")
        case .noRelease: return Chrome.localized("No release with a disk image was found.")
        case .badResponse(let status): return String(format: Chrome.localized("GitHub answered with HTTP %lld."), status)
        case .unauthorized: return Chrome.localized("Your GitHub sign-in expired. Connect again.")
        case .rateLimited(let until, let authenticated):
            if let until {
                let key = authenticated
                    ? "GitHub's request limit was reached. Try again after %@."
                    : "GitHub's anonymous request limit was reached. Try again after %@ or download Tivano from its releases page."
                return String(format: Chrome.localized(key), until.formatted(date: .omitted, time: .shortened))
            }
            return Chrome.localized(authenticated
                ? "GitHub's request limit was reached. Try again later."
                : "GitHub's anonymous request limit was reached. Try again later or download Tivano from its releases page.")
        }
    }
}

/// The parts of a GitHub release the checker reads.
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        var name: String
        var browserDownloadURL: String
        var size: Int64?
        var sha256: String? = nil

        var isDiskImage: Bool {
            name.lowercased().hasSuffix(".dmg") || browserDownloadURL.lowercased().hasSuffix(".dmg")
        }

        private enum CodingKeys: String, CodingKey {
            case name, size, sha256
            case browserDownloadURL = "browser_download_url"
        }
    }

    var tagName: String
    var name: String?
    var body: String?
    var releasedAt: Date?
    var upcomingRelease: Bool
    var assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
        case releasedAt = "published_at"
        case draft, prerelease
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        releasedAt = try container.decodeIfPresent(String.self, forKey: .releasedAt).flatMap(Self.parseDate)
        let isDraft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        let isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        upcomingRelease = isDraft || isPrerelease
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    /// GitHub writes `2026-09-13T18:28:42Z`; the fraction is optional.
    nonisolated static func parseDate(_ text: String) -> Date? {
        ISO8601.date(from: text)
    }
}
