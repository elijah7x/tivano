import SwiftUI

/// Upstream attribution, open-source credits, bundled licenses and the Keepsakes showcase.
struct CreditsSettingsPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keepsakeOverlayShown = false

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
        count: 2
    )

    private static let entries: [(name: String, role: String)] = [
        ("Zeron", "Voice, sounds and working indicators"),
        ("SwiftTerm", "Built-in terminal"),
        ("Thinking orbs", "Voice orb animation"),
        ("T3 Code", "Where Droppy Code began"),
        ("Synara", "Responsive chat architecture"),
        ("mugen-markdown", "Streaming text fade"),
        ("OpenAI Codex", "Voice protocol"),
        ("anti-slop", "Writing guidance"),
        ("MonoCode", "Usage reset flow"),
    ]

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
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                        ForEach(Self.entries, id: \.name) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: entry.name)
                                    .font(.ui(.subheadline, weight: .semibold))
                                    .foregroundStyle(Chrome.primaryText)
                                Text(verbatim: Chrome.localized(entry.role))
                                    .font(.ui(.caption))
                                    .foregroundStyle(Chrome.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text(verbatim: Chrome.localized("Marks: GitHub Octicons, oh-my-pi, Simple Icons and the Git Logo by Jason Long"))
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Chrome.contentHorizontalPadding)
                .padding(.vertical, 12)
            }
        }
    }
}

/// Upstream attribution plus the bundled license, third-party notices and trademark policy
/// read in a popover: every copy of the app carries the notices for what it builds on.
private struct UpstreamAttributionRow: View {
    @State private var isPresented = false

    private static let files: [(title: String, resource: String)] = [
        ("Tivano", "LICENSE"),
        ("Third-party notices", "THIRD_PARTY_NOTICES"),
        ("Trademarks", "TRADEMARK"),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where Tivano began")
                    .font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                Text(verbatim: "Droppy Code")
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: "Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                Text("Tivano is a fork of Droppy Code, under AGPL-3.0 with attribution terms.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("View") { isPresented = true }
                .chromePillButton()
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
        .padding(.horizontal, Chrome.contentHorizontalPadding)
        .padding(.vertical, 12)
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
