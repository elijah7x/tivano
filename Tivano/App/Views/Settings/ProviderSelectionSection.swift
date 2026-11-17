import SwiftUI

struct ProviderSelectionSection: View {
    let settings: AppSettings
    @State private var isExpanded = false
    @State private var cardWidth: CGFloat = 0

    var body: some View {
        ChromeSection(title: "Active providers") {
            ChromeCard {
                ChromeRow(
                    title: "Choose your providers",
                    detail: "Show only the providers you use in Settings and the model picker."
                ) {
                    Button {
                        withAnimation(Chrome.hover) { isExpanded.toggle() }
                    } label: {
                        Text(verbatim: Chrome.localized(isExpanded ? "Done" : "Choose providers"))
                    }
                    .chromeGlassButtonStyle()
                    .accessibilityValue(Text(verbatim: Chrome.localized(isExpanded ? "Expanded" : "Collapsed")))
                }
                ChromeReveal(isExpanded: isExpanded) {
                    ProviderSelectionGrid(
                        availableWidth: max(0, cardWidth - Chrome.rowHorizontalPadding * 2),
                        isEnabled: { settings.isEnabled($0) },
                        setEnabled: { settings.setEnabled($0, for: $1) }
                    )
                }
                .clipped()
                ChromeRowDivider()
                ChromeRow(title: "Show remaining usage", detail: "Plan limits and balances in the provider cards below. The usage ring in a chat still shows them.") {
                    SettingsSwitch(isOn: Binding(
                        get: { settings.showsProviderUsage },
                        set: { settings.showsProviderUsage = $0 }
                    ))
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Show remaining usage")))
                }
                ChromeRowDivider()
                ChromeRow(
                    title: "Check for updates",
                    detail: "Check installed CLIs for updates every six hours. Installation starts only when you choose Update."
                ) {
                    SettingsSwitch(isOn: Binding(
                        get: { settings.checksCLIUpdates },
                        set: { settings.checksCLIUpdates = $0 }
                    ))
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Check for updates")))
                }
                ChromeRowDivider()
                ChromeRow(
                    title: "Show executable paths",
                    detail: "Show each CLI's executable path and a field to override it."
                ) {
                    SettingsSwitch(isOn: Binding(
                        get: { settings.showsProviderBinaryPaths },
                        set: { settings.showsProviderBinaryPaths = $0 }
                    ))
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Show executable paths")))
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                cardWidth = width
            }
        }
    }
}

private struct ProviderSelectionGrid: View {
    let availableWidth: CGFloat
    let isEnabled: (ProviderKind) -> Bool
    let setEnabled: (Bool, ProviderKind) -> Void

    private static var minimumColumnWidth: CGFloat {
        ChromeVisualTileMetrics.regularWidth * 2 + ChromeVisualTileMetrics.spacing * 2
            + CGFloat(TypeScale.shared.ui - TypeScale.stockUI) * Chrome.rowHorizontalPadding
    }

    /// `ChromeVisualTile` takes a fixed `CGFloat` width, so match `GridItem(.adaptive)`'s column width.
    private static func resolvedTileWidth(availableWidth: CGFloat, minimum: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return minimum }
        let spacing = ChromeVisualTileMetrics.spacing
        let count = max(1, Int((availableWidth + spacing) / (minimum + spacing)))
        return ((availableWidth - spacing * CGFloat(count - 1)) / CGFloat(count)).rounded(.down)
    }

    var body: some View {
        let minimum = Self.minimumColumnWidth
        let tileWidth = Self.resolvedTileWidth(availableWidth: availableWidth, minimum: minimum)
        let columns = [
            GridItem(.adaptive(minimum: minimum), spacing: ChromeVisualTileMetrics.spacing, alignment: .leading),
        ]
        VStack(alignment: .leading, spacing: 0) {
            ChromeRowDivider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Click a provider to show or hide it. Your settings are kept.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Chrome.rowHorizontalPadding)
                ForEach(ProviderGroup.allCases) { group in
                    Text(verbatim: Chrome.localized(group.title))
                        .font(.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, Chrome.rowHorizontalPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: ChromeVisualTileMetrics.captionSpacing) {
                        ForEach(group.providers) { provider in
                            let enabled = isEnabled(provider)
                            ChromeVisualTile(
                                title: provider.displayName,
                                isSelected: enabled,
                                width: tileWidth,
                                layout: .inline
                            ) {
                                withAnimation(Chrome.hover) { setEnabled(!enabled, provider) }
                            } content: {
                                ProviderIcon(provider: provider, size: Chrome.iconSize)
                            }
                            .accessibilityValue(Text(verbatim: Chrome.localized(enabled ? "Active" : "Hidden")))
                        }
                    }
                }
            }
            // Tiles and headers each add `rowHorizontalPadding` (8 pt), landing text and icons at 16 pt with `ChromeRow`.
            .padding(.horizontal, Chrome.rowHorizontalPadding)
            .padding(.vertical, 11)
        }
    }
}
