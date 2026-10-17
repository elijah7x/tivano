import SwiftUI

struct ProviderSelectionSection: View {
    let settings: AppSettings
    @State private var isPresented = false

    var body: some View {
        ChromeSection(title: "Active providers") {
            ChromeCard {
                ChromeRow(
                    title: "Choose your providers",
                    detail: "Show only the providers you use in Settings and the model picker."
                ) {
                    Button("Choose providers") { isPresented = true }
                        .buttonStyle(.glass)
                        .popover(isPresented: $isPresented, arrowEdge: .top) {
                            ProviderSelectionCard(
                                isEnabled: { settings.isEnabled($0) },
                                setEnabled: { settings.setEnabled($0, for: $1) }
                            )
                            .presentedChrome()
                        }
                }
                ChromeRowDivider()
                ChromeRow(title: "Show remaining usage", detail: "Plan limits and balances in the provider cards below. The usage ring in a chat still shows them.") {
                    SettingsSwitch(isOn: Binding(
                        get: { settings.showsProviderUsage },
                        set: { settings.showsProviderUsage = $0 }
                    ))
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Show remaining usage")))
                }
            }
        }
    }
}

struct ProviderSelectionCard: View {
    let isEnabled: (ProviderKind) -> Bool
    let setEnabled: (Bool, ProviderKind) -> Void
    private static let columnCount = 3
    private static var columnWidth: CGFloat {
        ChromeVisualTileMetrics.regularWidth * 2 + ChromeVisualTileMetrics.spacing * 2
            + CGFloat(TypeScale.shared.ui - TypeScale.stockUI) * Chrome.rowHorizontalPadding
    }
    private static var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(columnWidth), spacing: ChromeVisualTileMetrics.spacing, alignment: .top),
            count: columnCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ChromeSection(title: "Active providers") {
                Text("Click a provider to show or hide it. Your settings are kept.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(ProviderGroup.allCases) { group in
                ChromeSection(title: group.title) {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: ChromeVisualTileMetrics.captionSpacing) {
                        ForEach(group.providers) { provider in
                            let enabled = isEnabled(provider)
                            ChromeVisualTile(
                                title: provider.displayName,
                                isSelected: enabled,
                                width: Self.columnWidth,
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
        }
        .padding(Chrome.contentHorizontalPadding)
        .frame(width: Self.columnWidth * CGFloat(Self.columnCount)
            + ChromeVisualTileMetrics.spacing * CGFloat(Self.columnCount - 1)
            + Chrome.contentHorizontalPadding * 2)
        .background { NoWindowDragArea() }
    }
}
