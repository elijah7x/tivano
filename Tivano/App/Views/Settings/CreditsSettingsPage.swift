import SwiftUI

/// Upstream attribution, open-source credits, bundled licenses and the Keepsakes showcase.
struct CreditsSettingsPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keepsakeOverlayShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
            credits
                .opacity(keepsakeOverlayShown ? 0 : 1)
                .allowsHitTesting(!keepsakeOverlayShown)
                .accessibilityHidden(keepsakeOverlayShown)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: keepsakeOverlayShown)

            ChromeSection(title: "Keepsakes") {
                KeepsakesSettingsPage()
            }
        }
        .onPreferenceChange(KeepsakeOverlayPreference.self) { keepsakeOverlayShown = $0 }
    }

    private var credits: some View {
        ChromeSection(title: "Credits") {
            ChromeCard {
                UpstreamAttributionRow()
                ChromeRowDivider()
                CreditDetailRow(
                    symbol: "waveform", title: "Zeron", meta: "Wing · MIT",
                    detail: "Working indicators, the voice system and its sounds, and the voice orb integration. The streaming text fade (from mugen-markdown) and the Codex voice protocol (from OpenAI Codex, Apache-2.0) also came through Zeron."
                )
                ChromeRowDivider()
                CreditDetailRow(
                    symbol: "apple.terminal", title: "SwiftTerm", meta: "Miguel de Icaza · MIT",
                    detail: "The built-in terminal."
                )
                ChromeRowDivider()
                CreditDetailRow(
                    symbol: "circle.hexagongrid", title: "Thinking orbs", meta: "Animation engine · MIT",
                    detail: "The voice orb animations: Bezel → gpui-thinking-orbs → Jakub Antalik's thinking-orbs."
                )
                VStack(alignment: .leading, spacing: 12) {
                    CreditGroup(
                        title: "Code",
                        items: "T3 Code (Droppy Code's origin) · mugen-markdown · OpenAI Codex · anti-slop (writing policy)"
                    )
                    CreditGroup(
                        title: "Assets",
                        items: "GitHub Octicons (Copilot mark) · oh-my-pi (omp mark) · Simple Icons and the Git Logo by Jason Long (service marks)"
                    )
                    CreditGroup(title: "References", items: "MonoCode (usage reset flow)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Chrome.contentHorizontalPadding)
                .padding(.vertical, 11)
                ChromeRowDivider()
                LicensesRow()
            }
        }
    }
}

/// The license, the third-party notices and the trademark policy, as shipped in the bundle,
/// read in a popover: every copy of the app carries the notices for what it builds on.
private struct LicensesRow: View {
    @State private var isPresented = false

    private static let files: [(title: String, resource: String)] = [
        ("Tivano", "LICENSE"),
        ("Third-party notices", "THIRD_PARTY_NOTICES"),
        ("Trademarks", "TRADEMARK"),
    ]

    var body: some View {
        ChromeRow(title: "Licenses", detail: "AGPL-3.0 with attribution terms, and the notices for what the app builds on.") {
            Button("Show") { isPresented = true }
                .chromeGlassButtonStyle()
                .controlSize(.small)
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Self.files, id: \.resource) { file in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: Chrome.localized(file.title))
                                        .font(.ui(.body, weight: .semibold))
                                    MarkdownView(text: Self.text(of: file.resource)).equatable()
                                        .environment(\.markdownPointSize, TypeScale.shared.content(12))
                                        .foregroundStyle(Chrome.secondaryText)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 480, height: 440)
                    .presentedChrome()
                }
        }
    }

    private static let texts: [String: String] = Dictionary(uniqueKeysWithValues: files.map { file in
        let url = Bundle.main.url(forResource: file.resource, withExtension: file.resource == "LICENSE" ? nil : "md")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? String(format: Chrome.localized("The %@ file is missing from this copy of the app."), file.resource)
        return (file.resource, unwrapped(text))
    })

    private static func unwrapped(_ text: String) -> String {
        func standsAlone(_ line: Substring) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.isEmpty || line.hasPrefix("  ") || line.hasPrefix("\t") { return true }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("|") || trimmed.hasPrefix("```") || trimmed.hasPrefix("Copyright") { return true }
            if trimmed.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "_" }) { return true }
            if let dot = trimmed.firstIndex(of: "."), dot > trimmed.startIndex, trimmed[..<dot].allSatisfy(\.isNumber) { return true }
            return false
        }
        func closes(_ line: Substring) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("|") || trimmed.hasPrefix("```")
                || trimmed.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "_" })
        }
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let last = out.last, !standsAlone(line), !closes(Substring(last)) {
                out[out.count - 1] = last + " " + line
            } else {
                out.append(String(line))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func text(of resource: String) -> String {
        texts[resource] ?? String(format: Chrome.localized("The %@ file is missing from this copy of the app."), resource)
    }
}

private struct UpstreamAttributionRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where Tivano began")
                .font(.ui(.caption))
                .foregroundStyle(Chrome.secondaryText)
            Text(verbatim: "Droppy Code")
                .font(.ui(.title2, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
            Text(verbatim: "Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
            Text("Tivano is a fork of Droppy Code, under AGPL-3.0 with attribution terms.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Chrome.contentHorizontalPadding)
        .padding(.vertical, 14)
    }
}

private struct CreditGroup: View {
    let title: String
    let items: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.caption))
            Text(verbatim: Chrome.localized(items))
                .font(.ui(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Chrome.secondaryText)
    }
}

private struct CreditDetailRow: View {
    let symbol: String
    let title: String
    let meta: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.ui(.body))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                (Text(verbatim: Chrome.localized(title))
                    .font(.ui(.body, weight: .semibold))
                    .foregroundColor(Chrome.primaryText)
                 + Text(verbatim: "  " + Chrome.localized(meta))
                    .font(.ui(.subheadline))
                    .foregroundColor(Chrome.secondaryText))
                Text(verbatim: Chrome.localized(detail))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Chrome.contentHorizontalPadding)
        .padding(.vertical, 11)
    }
}
