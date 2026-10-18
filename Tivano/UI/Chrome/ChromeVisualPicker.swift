import SwiftUI

// A row control of two or three tiles, each a single symbol standing for what the option
// does, the way macOS Appearance offers Light / Dark / Auto; the chosen tile wears an accent
// ring and takes the accent on its symbol. The symbol is the caller's: every picker hands in
// one `Image`, and the option's name sits under its tile so the symbol never has to be guessed.

/// The tile's measures: every tile is the same size, so a picker of two options and a picker
/// of three line up with each other and with the rows around them.
enum ChromeVisualTileMetrics {
    static let height: CGFloat = 48
    static let regularWidth: CGFloat = 76
    static let denseWidth: CGFloat = 76
    static let cornerRadius: CGFloat = 6
    static let ringInset: CGFloat = 3
    static let ringWidth: CGFloat = 2
    static let spacing: CGFloat = 12
    static let captionSpacing: CGFloat = 6
}

/// The row control: one tile per option, the chosen one ringed.
struct ChromeVisualPicker<Value: Hashable, Preview: View>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @ViewBuilder var preview: (Value) -> Preview

    init(options: [(value: Value, title: String)], selection: Binding<Value>, @ViewBuilder preview: @escaping (Value) -> Preview) {
        self.options = options
        self._selection = selection
        self.preview = preview
    }

    private var tileWidth: CGFloat {
        options.count >= 3 ? ChromeVisualTileMetrics.denseWidth : ChromeVisualTileMetrics.regularWidth
    }

    var body: some View {
        HStack(alignment: .top, spacing: ChromeVisualTileMetrics.spacing) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                ChromeVisualTile(title: option.title, isSelected: option.value == selection, width: tileWidth) {
                    guard selection != option.value else { return }
                    withAnimation(Chrome.hover) { selection = option.value }
                } content: {
                    preview(option.value)
                }
            }
        }
        .fixedSize()
        .background { NoWindowDragArea() }
    }
}

enum ChromeVisualTileLayout {
    case stacked
    case inline
}

/// One option, on a symbol stage or in a compact icon-and-name row.
struct ChromeVisualTile<Content: View>: View {
    let title: String
    let isSelected: Bool
    var width: CGFloat = ChromeVisualTileMetrics.regularWidth
    var layout: ChromeVisualTileLayout = .stacked
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            if layout == .inline {
                ChromeVisualTileFace(isSelected: isSelected, width: width, layout: layout, face: inlineLabel, caption: EmptyView())
            } else {
                ChromeVisualTileFace(isSelected: isSelected, width: width, layout: layout, face: stage, caption: caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Chrome.localized(title)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var inlineLabel: some View {
        HStack(spacing: Chrome.rowHorizontalPadding) {
            content()
                .foregroundStyle(isSelected ? Chrome.primaryText : Chrome.secondaryText)
                .frame(width: Chrome.iconSize)
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.callout))
                .foregroundStyle(isSelected ? Chrome.primaryText : Chrome.secondaryText)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Image(systemName: "checkmark.seal.fill")
                .font(.ui(.body, weight: .medium))
                .foregroundStyle(Chrome.accent)
                .frame(width: Chrome.iconSize)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    /// The option's name under its tile: the symbol alone does not say what the choice is.
    private var caption: some View {
        Text(verbatim: Chrome.localized(title))
            .font(.ui(.subheadline))
            .foregroundStyle(isSelected ? Chrome.primaryText : Chrome.secondaryText)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(width: width)
    }

    private var stage: some View {
        content()
            .font(.ui(.title2, weight: .medium))
            .foregroundStyle(isSelected ? Chrome.accent : Chrome.secondaryText)
            .frame(width: width, height: ChromeVisualTileMetrics.height)
    }
}

private struct ChromeVisualTileFace<Face: View, Caption: View>: View {
    let isSelected: Bool
    let width: CGFloat
    let layout: ChromeVisualTileLayout
    let face: Face
    let caption: Caption
    @State private var isHovering = false

    var body: some View {
        Group {
            if layout == .inline {
                face
                    .opacity(isSelected || isHovering ? 1 : 0.7)
                    .padding(.horizontal, Chrome.rowHorizontalPadding)
                    .frame(width: width, height: Chrome.rowHeight + ChromeVisualTileMetrics.captionSpacing * 2)
                    .background(
                        RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
                            .fill(Chrome.overlay(isHovering ? 0.06 : 0))
                    )
                    .contentShape(.rect)
            } else {
                VStack(spacing: ChromeVisualTileMetrics.captionSpacing) {
                    face
                        .background(
                            RoundedRectangle(cornerRadius: ChromeVisualTileMetrics.cornerRadius, style: .continuous)
                                .fill(Chrome.overlay(isHovering || isSelected ? 0.10 : 0.06))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: ChromeVisualTileMetrics.cornerRadius, style: .continuous))
                        .padding(ChromeVisualTileMetrics.ringInset)
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: ChromeVisualTileMetrics.cornerRadius + ChromeVisualTileMetrics.ringInset,
                                style: .continuous
                            )
                            .strokeBorder(isSelected ? Chrome.accent : Color.clear, lineWidth: ChromeVisualTileMetrics.ringWidth)
                        )
                        .contentShape(Rectangle())
                    caption
                }
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }
}
