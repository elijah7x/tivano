import AppKit
import SwiftUI

// The software update story on the About page, told the way the settings pages tell it: the
// sticky chrome carries the version and the one control (the seal while up to date, the blue
// Update & restart button while a release waits, the slider while it installs), and the page
// shows the release's notes as three tappable cards: New, Bugs, Refinements.

// MARK: - Release notes

/// The three sections a release's notes are written in.
enum ReleaseNoteCategory: CaseIterable, Identifiable {
    case newFeatures
    case bugFixes
    case refinements

    var id: Self { self }

    var assetName: String {
        switch self {
        case .newFeatures: "UpdateNewFeaturesIcon"
        case .bugFixes: "UpdateBugFixesIcon"
        case .refinements: "UpdateRefinementsIcon"
        }
    }

    /// Short, so three cards stay one row.
    var cardTitle: String {
        switch self {
        case .newFeatures: "New"
        case .bugFixes: "Bugs"
        case .refinements: "Refinements"
        }
    }

    var sectionTitle: String {
        switch self {
        case .newFeatures: "New features"
        case .bugFixes: "Bug fixes"
        case .refinements: "Refinements"
        }
    }

    func countSummary(_ count: Int) -> String {
        switch self {
        case .newFeatures: count == 1 ? Chrome.localized("1 addition") : String(format: Chrome.localized("%lld additions"), count)
        case .bugFixes: String(format: Chrome.localized("%lld fixed"), count)
        case .refinements: String(format: Chrome.localized("%lld improved"), count)
        }
    }

    /// Sampled from each card's own icon.
    var cardTint: Color {
        switch self {
        case .newFeatures: Color(red: 0.09, green: 0.44, blue: 0.85)
        case .bugFixes: Color(red: 0.90, green: 0.30, blue: 0.24)
        case .refinements: Color(red: 0.43, green: 0.23, blue: 0.72)
        }
    }
}

/// A release's notes read into the three sections. The notes are the release description on
/// GitHub: a `## New features`, `## Bug fixes`, `## Refinements` heading each, bullets under
/// them. A section that is missing or empty is simply absent; bullets under any other heading,
/// such as the release's Thanks to contributors, are left out of the cards; notes in any other
/// shape read as nothing, and the page shows them as they are instead.
struct UpdateReleaseNotesDigest: Equatable {
    struct Section: Equatable, Identifiable {
        let category: ReleaseNoteCategory
        let bullets: [String]
        /// A closing "… 12 extra …" line, kept apart because it is a count, not a change.
        let rollup: String?
        let rollupCount: Int

        var id: ReleaseNoteCategory { category }
        var changeCount: Int { bullets.count + rollupCount }
    }

    let sections: [Section]
    var isEmpty: Bool { sections.isEmpty }

    func section(for category: ReleaseNoteCategory) -> Section? {
        sections.first { $0.category == category }
    }

    /// Language headings may be promoted from ### to ## when publishing. Category
    /// headings stay inside their language section; Thanks is shared by both.
    @MainActor private static var lastSelection: (raw: String, language: String, notes: String)?

    @MainActor
    static func selectedNotes(_ raw: String?, language: String) -> String? {
        guard let raw else { return nil }
        if let lastSelection, lastSelection.raw == raw, lastSelection.language == language {
            return lastSelection.notes
        }
        let notes = selectNotes(raw, language: language)
        lastSelection = (raw, language, notes)
        return notes
    }

    private static func selectNotes(_ raw: String, language: String) -> String {
        var english: [String] = []
        var chinese: [String] = []
        var thanks: [String] = []
        var current: String?
        var hasLanguageSections = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let header: String?
            if trimmed.hasPrefix("### ") {
                header = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("## ") {
                header = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                header = nil
            }
            switch header {
            case "English", "简体中文":
                hasLanguageSections = true
                current = header
                continue
            case "Thanks" where hasLanguageSections:
                current = "Thanks"
            default:
                break
            }
            switch current {
            case "English": english.append(String(line))
            case "简体中文": chinese.append(String(line))
            case "Thanks": thanks.append(String(line))
            default: break
            }
        }
        guard hasLanguageSections else { return raw }
        let hasChineseContent = chinese.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && category(forHeader: trimmed) == nil
        }
        let selected = language.lowercased().hasPrefix("zh") && hasChineseContent ? chinese : english
        let body = selected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let sharedThanks = thanks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return [body, sharedThanks].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static let bulletMarkers: Set<Character> = ["-", "\u{2010}", "\u{2013}", "\u{2014}", "\u{2212}", "*", "•"]
    /// The last notes parsed: the About page asks on every evaluation for the one release
    /// it shows, and the parse runs three regular expressions per bullet.
    @MainActor private static var last: (raw: String, digest: UpdateReleaseNotesDigest)?

    @MainActor
    static func parse(_ raw: String?) -> UpdateReleaseNotesDigest {
        guard let raw, !raw.isEmpty else { return UpdateReleaseNotesDigest(sections: []) }
        if let last, last.raw == raw { return last.digest }
        let digest = parseNotes(raw)
        last = (raw, digest)
        return digest
    }

    private static func parseNotes(_ raw: String) -> UpdateReleaseNotesDigest {
        var collected: [ReleaseNoteCategory: [String]] = [:]
        var current: ReleaseNoteCategory?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" || trimmed.hasPrefix("<") { continue }
            if let bullet = bulletBody(of: trimmed) {
                guard let current else { continue }
                let clean = strippedInlineMarkdown(bullet)
                if !clean.isEmpty { collected[current, default: []].append(clean) }
                continue
            }
            if let category = category(forHeader: trimmed) {
                current = category
            } else if isHeader(trimmed) {
                // Any other heading, such as the release's Thanks to contributors, closes
                // the card before it so its bullets are left out rather than appended.
                current = nil
            }
        }
        let sections = ReleaseNoteCategory.allCases.compactMap { category -> Section? in
            guard var items = collected[category], !items.isEmpty else { return nil }
            var seen = Set<String>()
            items = items.filter { seen.insert($0.lowercased()).inserted }
            if let last = items.last, let count = rollupCount(in: last) {
                return Section(category: category, bullets: Array(items.dropLast()), rollup: last, rollupCount: count)
            }
            return Section(category: category, bullets: items, rollup: nil, rollupCount: 0)
        }
        return UpdateReleaseNotesDigest(sections: sections)
    }

    private static func bulletBody(of line: String) -> String? {
        guard let marker = line.first, bulletMarkers.contains(marker) else { return nil }
        let rest = line.dropFirst()
        guard let next = rest.first, next == " " || next == "\t" else { return nil }
        let body = rest.trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    /// True for any line shaped like a heading: one or more `#` followed by a space, or a
    /// bold-only line. Plain text lines are not headings, even with a trailing colon.
    private static func isHeader(_ line: String) -> Bool {
        if line.hasPrefix("#") {
            var rest = line
            while rest.hasPrefix("#") { rest.removeFirst() }
            return rest.isEmpty || rest.first == " " || rest.first == "\t"
        }
        if line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 { return true }
        return false
    }

    /// The three section names, bare or in Markdown heading or bold chrome.
    private static func category(forHeader line: String) -> ReleaseNoteCategory? {
        var text = line
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("**") { text.removeFirst(2) }
        if text.hasSuffix("**") { text.removeLast(2) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t:"))
        switch text.lowercased() {
        case "new features", "new", "新功能": return .newFeatures
        case "bug fixes", "fixes", "bugs", "问题修复": return .bugFixes
        case "refinements", "improvements", "优化改进": return .refinements
        default: return nil
        }
    }

    /// "Fixed 12 extra issues…" counts as 12.
    private static func rollupCount(in bullet: String) -> Int? {
        let words = bullet.split(separator: " ")
        guard let extraIndex = words.firstIndex(where: { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) == "extra" }),
              extraIndex > words.startIndex else { return nil }
        let digits = words[words.index(before: extraIndex)].filter(\.isNumber)
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// The three inline markdown shapes the release notes use, stripped to their text.
    /// Runs per bullet, cheap because `parse` memoizes on the raw notes string.
    private static func strippedInlineMarkdown(_ text: String) -> String {
        var output = text.replacing(#/\[([^\]]+)\]\([^)]*\)/#) { $0.output.1 }
        output = output.replacing(#/\*\*([^*]+)\*\*/#) { $0.output.1 }
        output = output.replacing(#/`([^`]+)`/#) { $0.output.1 }
        return output.trimmingCharacters(in: .whitespaces)
    }
}

/// The notes as three tappable cards: each its icon, its tint held very light, and the number
/// of changes it stands for. Tapping one opens that section's bullets in a popover.
struct UpdateReleaseSectionCards: View {
    let digest: UpdateReleaseNotesDigest
    let version: String

    @State private var presented: ReleaseNoteCategory?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(ReleaseNoteCategory.allCases) { category in
                card(for: category)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func card(for category: ReleaseNoteCategory) -> some View {
        let section = digest.section(for: category)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button {
            guard section != nil else { return }
            presented = presented == category ? nil : category
        } label: {
            VStack(spacing: 6) {
                Image(category.assetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text(verbatim: Chrome.localized(category.cardTitle))
                    .font(.ui(size: 12.5, weight: .medium))
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: section.map { category.countSummary($0.changeCount) } ?? Chrome.localized("Nothing here"))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // No border: the card is its tint.
            .background { shape.fill(category.cardTint.opacity(0.09)) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(section == nil)
        .opacity(section == nil ? 0.45 : 1)
        .help(Text(verbatim: section == nil ? Chrome.localized("Nothing here") : String(format: Chrome.localized("Every change in %@"), Chrome.localizedLowercased(category.sectionTitle))))
        .accessibilityLabel(Text(verbatim: Chrome.localized(category.sectionTitle)))
        .popover(isPresented: Binding(
            get: { presented == category },
            set: { if $0 { presented = category } else if presented == category { presented = nil } }
        ), arrowEdge: .top) {
            Group {
                if let section {
                    UpdateReleaseSectionPopover(section: section, version: version)
                }
            }
            .presentedChrome()
        }
    }
}

private struct UpdateReleaseSectionPopover: View {
    let section: UpdateReleaseNotesDigest.Section
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(section.category.assetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: Chrome.localized(section.category.sectionTitle))
                        .font(.ui(.body, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                    Text(verbatim: version)
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Spacer(minLength: 0)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(section.bullets.indices, id: \.self) { index in
                        Text(verbatim: section.bullets[index])
                            .font(.ui(.body))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let rollup = section.rollup {
                        Text(verbatim: rollup)
                            .font(.ui(.callout))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - Progress slider

/// Per-frame exponential chase of a target that only moves forward, so a download's uneven
/// reports become one continuous glide.
@MainActor
private final class FractionChase {
    private var displayed: Double
    private var lastTime: TimeInterval?

    init(initial: Double) {
        displayed = initial
    }

    func advance(to time: TimeInterval, target: Double, response: Double, minimumSpeed: Double) -> Double {
        defer { lastTime = time }
        guard let lastTime else {
            displayed = target
            return displayed
        }
        guard target >= displayed else {
            displayed = target
            return displayed
        }
        let dt = max(0, min(time - lastTime, 0.25))
        let remaining = target - displayed
        guard remaining > 0, dt > 0 else { return displayed }
        var step = remaining * (1 - exp(-dt / max(response, 0.01)))
        step = max(step, minimumSpeed * dt)
        displayed = min(displayed + step, target)
        // The glide is exponential and would close the last hundredth of a pixel for
        // seconds: within a ten-thousandth it is there, and the clock can stop.
        if target - displayed < 0.0001 { displayed = target }
        return displayed
    }
}

/// Hosts the slider and chases the raw target every display frame. The only view that
/// observes the hot value.
struct SmoothedUpdateProgressSlider: View {
    let target: UpdateInstallProgress.FractionTarget
    var response = 0.3
    var minimumSpeed = 0.0
    var trackHeight: CGFloat = 14
    var headDiameter: CGFloat = 20

    @State private var chase: FractionChase
    /// True once the head has reached the target: the frame clock stops until the target
    /// moves again, instead of running at the display's rate for the whole install.
    @State private var settled = false

    init(target: UpdateInstallProgress.FractionTarget, response: Double = 0.3, minimumSpeed: Double = 0, trackHeight: CGFloat = 14, headDiameter: CGFloat = 20) {
        self.target = target
        self.response = response
        self.minimumSpeed = minimumSpeed
        self.trackHeight = trackHeight
        self.headDiameter = headDiameter
        // Mounts caught up, so the post-relaunch sweep never opens with a chase from zero.
        _chase = State(initialValue: FractionChase(initial: target.value))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: settled || ScrollActivity.shared.isScrolling)) { timeline in
            let fraction = chase.advance(
                to: timeline.date.timeIntervalSinceReferenceDate,
                target: target.value,
                response: response,
                minimumSpeed: minimumSpeed
            )
            UpdateProgressSlider(fraction: fraction, trackHeight: trackHeight, headDiameter: headDiameter)
                .onChange(of: fraction == target.value, initial: true) { _, reached in
                    if reached != settled { settled = reached }
                }
        }
        .onChange(of: target.value) { _, _ in
            if settled { settled = false }
        }
    }
}

/// A pill track filling with the theme accent behind a soft white head, sparkles
/// twinkling in the filled part. Renders whatever fraction it is given.
struct UpdateProgressSlider: View {
    let fraction: Double
    var trackHeight: CGFloat = 14
    var headDiameter: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The theme accent, lifted toward white at the leading end and deepened at the head.
    private static var fill: [Color] {
        let accent = Chrome.accent
        return [accent.mix(with: .white, by: 0.35), accent, accent.mix(with: .black, by: 0.12)]
    }
    private static let sparkles = SparkleParticle.field(count: 14, seed: 0x5EED_D80B)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .circular)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07))
                    .frame(height: trackHeight)
                FillCanvas(
                    fraction: fraction,
                    trackHeight: trackHeight,
                    colors: Self.fill,
                    sparkles: reduceMotion ? [] : Self.sparkles
                )
                .frame(width: width, height: trackHeight)
                .allowsHitTesting(false)
                Circle()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: headDiameter * 0.64, height: headDiameter * 0.64)
                    .frame(width: headDiameter, height: headDiameter)
                    .position(x: Self.headX(for: fraction, width: width, trackHeight: trackHeight), y: headDiameter / 2)
            }
        }
        .frame(height: headDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Updating Tivano"))
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }

    /// The head travels between the two end-cap centres.
    fileprivate static func headX(for value: Double, width: CGFloat, trackHeight: CGFloat) -> CGFloat {
        trackHeight / 2 + (width - trackHeight) * CGFloat(min(max(value, 0), 1))
    }

    /// The fill fades in over the first few percent, as its cap clears the head.
    fileprivate static func fillOpacity(for fraction: Double) -> Double {
        let start = 0.012
        let end = 0.05
        guard fraction > start else { return 0 }
        guard fraction < end else { return 1 }
        let t = (fraction - start) / (end - start)
        return t * t * (3 - 2 * t)
    }
}

/// The accent fill and its sparkles in one canvas, revealed by a leading clip. The gradient is
/// anchored to the whole track and the sparkles sit still, so only the reveal grows.
private struct FillCanvas: View {
    let fraction: Double
    let trackHeight: CGFloat
    let colors: [Color]
    let sparkles: [SparkleParticle]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: sparkles.isEmpty || ScrollActivity.shared.isScrolling)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let opacity = UpdateProgressSlider.fillOpacity(for: fraction)
                guard opacity > 0, size.width > 0, size.height > 0 else { return }
                let headX = UpdateProgressSlider.headX(for: fraction, width: size.width, trackHeight: trackHeight)
                let reveal = Path(
                    roundedRect: CGRect(x: 0, y: 0, width: max(headX, trackHeight / 2), height: size.height),
                    cornerRadius: size.height / 2,
                    style: .circular
                )
                context.clip(to: reveal)
                context.opacity = opacity
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: colors),
                        startPoint: CGPoint(x: 0, y: size.height / 2),
                        endPoint: CGPoint(x: size.width, y: size.height / 2)
                    )
                )
                let verticalInset: CGFloat = 3
                let horizontalInset: CGFloat = 5
                let usableWidth = size.width - horizontalInset * 2
                let usableHeight = size.height - verticalInset * 2
                guard usableWidth > 0, usableHeight > 0 else { return }
                for particle in sparkles {
                    let twinkle = 0.5 + 0.5 * sin(time * particle.speed + particle.phase)
                    let sparkleOpacity = 0.08 + 0.72 * twinkle * twinkle
                    let drift = CGFloat(sin(time * particle.speed * 0.31 + particle.phase * 2.1)) * particle.drift
                    let rect = CGRect(
                        x: horizontalInset + CGFloat(particle.x) * usableWidth + drift - particle.size / 2,
                        y: verticalInset + CGFloat(particle.y) * usableHeight - particle.size / 2,
                        width: particle.size,
                        height: particle.size
                    )
                    context.fill(Circle().path(in: rect), with: .color(Color.white.opacity(min(1, sparkleOpacity))))
                }
            }
        }
    }
}

/// One sparkle: a fixed spot on the track, its own twinkle speed and phase, a little shimmer.
private struct SparkleParticle {
    let x: Double
    let y: Double
    let size: CGFloat
    let speed: Double
    let phase: Double
    let drift: CGFloat

    static func field(count: Int, seed: UInt64) -> [SparkleParticle] {
        var state = seed
        func next() -> Double {
            // SplitMix64: cheap, deterministic, well spread.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        return (0..<count).map { _ in
            SparkleParticle(
                x: next(),
                y: 0.12 + next() * 0.76,
                size: CGFloat(1.2 + next() * 1.6),
                speed: 0.9 + next() * 2.4,
                phase: next() * .pi * 2,
                drift: CGFloat(0.6 + next() * 1.4)
            )
        }
    }
}

/// The unread dot, on the Settings row and the About row while a release waits.
struct UpdateAvailableDot: View {
    var body: some View {
        Circle()
            .fill(Chrome.accent)
            .frame(width: 7, height: 7)
            .offset(x: 2.5, y: -2.5)
            .accessibilityLabel(Text("Update available"))
    }
}

// MARK: - Chrome

/// The About page's chrome: the installed version beside the app's icon, then the update
/// control: the seal while up to date, the blue Update & restart button while a release
/// waits, and the slider in the same capsule while it installs.
struct AboutUpdateChromeAccessory: View {
    var body: some View {
        HStack(spacing: 10) {
            AboutIdentityPill()
            AboutVersionPill()
        }
    }
}

private struct AboutIdentityPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(verbatim: "v\(AppInfo.version)")
                .font(.ui(.callout, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
                .lineLimit(1)
        }
        .padding(.leading, Chrome.capsuleHorizontalPadding - 4)
        .padding(.trailing, Chrome.capsuleHorizontalPadding)
        .frame(height: Chrome.capsuleContentHeight)
        .padding(.vertical, Chrome.capsuleVerticalPadding)
        .chromeGlassCapsule()
        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Tivano %@"), AppInfo.version)))
    }
}

/// The one control of the update story. The blue Update & restart button while a release
/// waits, the slider while it installs, and otherwise what the last check actually found:
/// the green seal, a warning when the check failed, or a plain note before the first one.
private struct AboutVersionPill: View {
    private let checker = UpdateChecker.shared
    private let progress = UpdateInstallProgress.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isReady: Bool {
        checker.updateAvailable && checker.update != nil && !progress.showsProgressUI
    }

    /// What the pill says when it is not the install button. The seal used to claim "Up to
    /// date" even when GitHub had never answered, or had answered with an error.
    private enum Standing {
        case upToDate
        case failed
        case unchecked

        var symbol: String {
            switch self {
            case .upToDate: "checkmark.seal.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .unchecked: "clock"
            }
        }

        var title: String {
            switch self {
            case .upToDate: "No update found"
            case .failed: "Check failed"
            case .unchecked: "Not checked yet"
            }
        }

        var tint: Color {
            switch self {
            case .upToDate: Chrome.success
            case .failed: Chrome.warning
            case .unchecked: Chrome.secondaryText
            }
        }
    }

    private var standing: Standing {
        if checker.lastError != nil { return .failed }
        if checker.lastCheckedAt == nil { return .unchecked }
        return .upToDate
    }

    var body: some View {
        Group {
            if progress.showsProgressUI {
                SmoothedUpdateProgressSlider(
                    target: progress.fractionTarget,
                    response: chaseResponse,
                    minimumSpeed: progress.phase == .celebrating ? 0.12 : 0
                )
                .frame(width: 104)
                .padding(.horizontal, Chrome.capsuleHorizontalPadding)
                .frame(height: Chrome.capsuleContentHeight)
                .padding(.vertical, Chrome.capsuleVerticalPadding)
                .fixedSize()
                .chromeGlassCapsule()
            } else {
                Button {
                    guard let update = checker.update, isReady else { return }
                    AppUpdater.shared.install(update)
                } label: {
                    HStack(spacing: 6) {
                        if isReady {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(Chrome.inlineIconFont)
                                .foregroundStyle(Chrome.blue)
                            Text("Update & restart")
                                .font(.ui(.callout, weight: .semibold))
                                .foregroundStyle(Chrome.blue)
                        } else {
                            Image(systemName: standing.symbol)
                                .font(Chrome.inlineIconFont)
                                .foregroundStyle(standing.tint)
                            Text(verbatim: Chrome.localized(standing.title))
                                .font(.ui(.callout, weight: .semibold))
                                .foregroundStyle(Chrome.primaryText)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Chrome.capsuleHorizontalPadding)
                    .frame(height: Chrome.capsuleContentHeight)
                    .padding(.vertical, Chrome.capsuleVerticalPadding)
                    .contentShape(Capsule(style: .continuous))
                    // A blue wash over the glass while the pill is the button; the seal stays plain.
                    .background {
                        if isReady {
                            Capsule(style: .continuous).fill(Chrome.blue.opacity(0.2))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isReady)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(isReady)
                .chromeGlassCapsule()
                // The seal is not a button, but it is still worth saying what it means
                // rather than showing an empty tooltip.
                .help(Text(verbatim: isReady
                    ? String(format: Chrome.localized("Installs Tivano %@ and relaunches"), checker.update?.version ?? "")
                    : standingHelp))
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .accessibilityAddTraits(isReady ? .isButton : [])
            }
        }
    }

    private var chaseResponse: Double {
        if reduceMotion { return 0.15 }
        return progress.phase == .celebrating ? 0.72 : 0.3
    }

    /// The seal is not a button, but it is still worth saying what it means.
    private var standingHelp: String {
        switch standing {
        case .upToDate: String(format: Chrome.localized("No newer version was found for Tivano %@."), AppInfo.version)
        case .failed: checker.lastError ?? Chrome.localized("The last update check failed.")
        case .unchecked: Chrome.localized("No update check has completed yet.")
        }
    }

    private var accessibilityLabel: String {
        isReady ? Chrome.localized("Update & restart") : String(format: Chrome.localized("Tivano %@, %@"), AppInfo.version, Chrome.localizedLowercased(standing.title))
    }
}

// MARK: - Page

/// What the About page shows of the update: the waiting release's notes as the three cards
/// (or as they were written, when they are not in that shape) with its size and date, and
/// the check row. Opening the page runs a check, and a launch that is the relaunch after an
/// install finishes the slider's story here.
struct AboutSoftwareUpdateSection: View {
    private let checker = UpdateChecker.shared
    private let progress = UpdateInstallProgress.shared
    @State private var celebration: Task<Void, Never>?
    // Refresh when the selected notes change, including edits to the same release.
    @State private var digest = UpdateReleaseNotesDigest(sections: [])
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notes = UpdateReleaseNotesDigest.selectedNotes(
            checker.update?.notes,
            language: Bundle.main.preferredLocalizations.first ?? "en"
        )
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            if progress.phase == .waitingForMerge {
                ChromeCard {
                    ChromeRow(title: "Waiting for Hydra merges to finish.") {
                        Button("Cancel") { AppUpdater.shared.cancelInstall() }
                            .buttonStyle(.glass)
                    }
                }
            }
            // The cards lead the page on their own, as on the About page; the version is
            // on the pill in the chrome and on the cards' popovers.
            if checker.updateAvailable, let update = checker.update {
                releaseBody(update, notes: notes ?? "")
            }
        }
        .task {
            if progress.consumePendingCelebration() {
                startCelebrationSweep()
            }
            await checker.check()
        }
        .onChange(of: notes, initial: true) {
            digest = UpdateReleaseNotesDigest.parse(notes)
        }
        .onDisappear {
            // Leaving mid-sweep lands the pill on Up to date at once; left celebrating, it
            // would host the frame-driven slider on every later visit and never settle.
            celebration?.cancel()
            celebration = nil
            progress.completeCelebration()
        }
    }

    @ViewBuilder
    private func releaseBody(_ update: AvailableUpdate, notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !digest.isEmpty {
                UpdateReleaseSectionCards(digest: digest, version: update.version)
            } else if !notes.isEmpty {
                ChromeCard {
                    ScrollView(.vertical) {
                        MarkdownView(text: notes).equatable()
                            .environment(\.markdownPointSize, TypeScale.shared.content(12.5))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 240)
                }
            }
            ChromeCard {
                ChromeRow(title: "Signed and notarized disk image", detail: releaseDetail(update)) {
                    Link(destination: update.pageURL) {
                        HStack(spacing: 4) {
                            Text("Release notes")
                            Image(systemName: "arrow.up.right")
                                .font(.ui(.footnote, weight: .semibold))
                        }
                        .font(.ui(.callout, weight: .medium))
                        .foregroundStyle(Chrome.accent)
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: Chrome.localized("Open the release on GitHub")))
                }
            }
        }
    }

    private func releaseDetail(_ update: AvailableUpdate) -> String {
        var parts: [String] = []
        if let date = update.releasedAt {
            parts.append(String(format: Chrome.localized("Released %@"), date.formatted(date: .long, time: .omitted)))
        }
        if let size = update.size {
            parts.append(ByteCountFormatStyle(style: .file).format(size))
        }
        parts.append(Chrome.localized("Update & restart installs it in place and relaunches."))
        return parts.joined(separator: " · ")
    }

    /// After the relaunch: the head sweeps from the handoff position to 100%, ticks the last
    /// milestone on the way, and the pill settles into Up to date.
    private func startCelebrationSweep() {
        celebration?.cancel()
        let reduceMotion = reduceMotion
        celebration = Task { @MainActor in
            let progress = UpdateInstallProgress.shared
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, progress.phase == .celebrating else { return }
            progress.finishCelebrationSweep()
            if reduceMotion {
                Haptics.perform(.alignment)
                try? await Task.sleep(for: .milliseconds(900))
            } else {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                Haptics.perform(.alignment)
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                Haptics.perform(.levelChange)
                try? await Task.sleep(for: .milliseconds(700))
            }
            guard !Task.isCancelled else { return }
            progress.completeCelebration()
        }
    }
}

/// The row on the app card that says when GitHub was last asked, and asks again.
struct AboutUpdateCheckRow: View {
    private let checker = UpdateChecker.shared

    var body: some View {
        ChromeRow(title: "Software update", detail: detail) {
            Button(Chrome.localized(checker.isChecking ? "Checking…" : "Check now")) {
                Task { await checker.check() }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(checker.isChecking)
        }
    }

    private var detail: String {
        if checker.isChecking { return Chrome.localized("Checking update sources…") }
        let checked = checker.lastCheckedAt.map { String(format: Chrome.localized("Checked %@."), $0.formatted(.relative(presentation: .named))) } ?? Chrome.localized("Not checked yet.")
        if let error = checker.lastError { return "\(error) \(checked)" }
        if checker.updateAvailable, let version = checker.update?.version {
            return String(format: Chrome.localized("Tivano %@ is ready to install. %@"), version, checked)
        }
        return String(format: Chrome.localized("Tivano checks GitHub for new versions a few times a day. %@"), checked)
    }
}
