import SwiftUI

private enum WhatsNewSummary {
    @MainActor
    static func line(for whatsNew: WhatsNew) -> String {
        var parts: [String] = []
        if whatsNew.versionCount > 1 {
            parts.append(String(localized: "\(whatsNew.versionCount) versions"))
        }
        for category in ReleaseNoteCategory.allCases {
            let count = whatsNew.count(for: category)
            guard count > 0 else { continue }
            switch category {
            case .newFeatures:
                parts.append(String(localized: "\(count) new features"))
            case .bugFixes:
                parts.append(String(localized: "\(count) fixes"))
            case .refinements:
                parts.append(String(localized: "\(count) refinements"))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// One-time banner shown above Version information after an upgrade until the user views or dismisses it.
struct WhatsNewBanner: View {
    let whatsNew: WhatsNew
    let onView: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ChromeCard {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Chrome.overlay(0.08))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.ui(.body, weight: .medium))
                            .foregroundStyle(Chrome.accent)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: String(format: Chrome.localized("Updated to %@"), whatsNew.displayVersion))
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.primaryText)
                    let summary = WhatsNewSummary.line(for: whatsNew)
                    if !summary.isEmpty {
                        Text(verbatim: summary)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Button(Chrome.localized("View"), action: onView)
                        .chromeGlassButtonStyle()
                        .controlSize(.small)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.ui(.caption, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: Chrome.localized("Dismiss")))
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Dismiss")))
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, Chrome.rowControlTrailingPadding)
            .padding(.vertical, 11)
        }
    }
}

/// Expandable row in the Version information card showing grouped release notes for recent updates.
struct WhatsNewRow: View {
    let whatsNew: WhatsNew
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var toggleAnimation: Animation? {
        reduceMotion ? nil : Chrome.panelSlide
    }

    private var nonEmptyCategories: [ReleaseNoteCategory] {
        ReleaseNoteCategory.allCases.filter { whatsNew.count(for: $0) > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(toggleAnimation) {
                    isExpanded.toggle()
                }
            } label: {
                ChromeRow(
                    title: String(format: Chrome.localized("What's new in %@"), whatsNew.displayVersion),
                    detail: WhatsNewSummary.line(for: whatsNew),
                    localizesDetail: false,
                    localizesTitle: false
                ) {
                    Image(systemName: "chevron.right")
                        .font(.ui(.caption, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(toggleAnimation, value: isExpanded)
                        .frame(width: 20, height: 20)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: Chrome.localized(isExpanded ? "Expanded" : "Collapsed")))

            ChromeReveal(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(nonEmptyCategories) { category in
                        categorySection(category, bullets: whatsNew.bullets(for: category))
                    }
                    footerLine
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .clipped()
        }
    }

    private func categorySection(_ category: ReleaseNoteCategory, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(category.cardTint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(verbatim: Chrome.localized(category.sectionTitle))
                    .font(.ui(.callout, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Chrome.overlay(0.3))
                            .frame(width: 4, height: 4)
                            .offset(y: -3)
                            .accessibilityHidden(true)
                        Text(verbatim: bullet)
                            .font(.ui(.callout))
                            .foregroundStyle(Chrome.secondaryText)
                            .lineSpacing(3.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }

    private var footerLine: some View {
        HStack(spacing: 6) {
            if whatsNew.versionCount > 1, let oldest = whatsNew.oldestIncludedVersion {
                Text(verbatim: String(localized: "Includes \(whatsNew.versionCount) versions since \(oldest)"))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                Text(verbatim: "·")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .accessibilityHidden(true)
            }
            Link(destination: UpdateChecker.projectURL.appending(path: "releases")) {
                HStack(spacing: 3) {
                    Text(verbatim: Chrome.localized("All release notes"))
                    Image(systemName: "arrow.up.right")
                        .font(.ui(.caption2, weight: .semibold))
                }
                .font(.ui(.subheadline, weight: .medium))
                .foregroundStyle(Chrome.accent)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: Chrome.localized("Open the release on GitHub")))
        }
        .padding(.top, 2)
    }
}
