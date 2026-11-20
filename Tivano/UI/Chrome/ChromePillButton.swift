import SwiftUI

/// The two sizes of a text button in a page or panel. Height and font are fixed here, never
/// left to the system glass metrics, the inherited window font or a control size, so a row's
/// buttons stand as tall as its pickers (`GlassPickerButton`) wherever they sit.
///
/// - `regular`: the default for every action, in a row, a card or section header, a card
///   body, an empty state, or a popover, sheet or panel footer.
/// - `compact`: only for an action inside a line that is itself secondary and set smaller
///   than a row title, such as an inline error or a nested usage sub-row.
///
/// The window's top chrome keeps its taller capsules (`ChromeTextButton`, `ChromeCapsule`).
enum ChromePillSize {
    case regular
    case compact

    var height: CGFloat {
        switch self {
        case .regular: Chrome.capsuleContentHeight
        case .compact: 24
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: Chrome.capsuleHorizontalPadding
        case .compact: 10
        }
    }

    @MainActor var font: Font {
        switch self {
        case .regular: .ui(size: 12.5, weight: .medium)
        case .compact: .ui(.callout, weight: .medium)
        }
    }
}

extension View {
    /// A text, label or icon button drawn as a chrome pill of one fixed size. `iconOnly`
    /// makes it a circle of the same height. A destructive role reads as an ordinary
    /// control at rest and turns red under the pointer, as `ChromeTextButton` does.
    func chromePillButton(_ size: ChromePillSize = .regular, prominent: Bool = false, iconOnly: Bool = false) -> some View {
        buttonStyle(ChromePillButtonStyle(size: size, prominent: prominent, iconOnly: iconOnly))
    }
}

struct ChromePillButtonStyle: ButtonStyle {
    var size: ChromePillSize = .regular
    var prominent = false
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, size: size, prominent: prominent, iconOnly: iconOnly)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let size: ChromePillSize
        let prominent: Bool
        let iconOnly: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let label = configuration.label
                .labelStyle(PillLabelStyle(iconOnly: iconOnly))
                .font(size.font)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(foreground)
                .padding(.horizontal, iconOnly ? 0 : size.horizontalPadding)
                .frame(width: iconOnly ? size.height : nil, height: size.height)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    guard isHovering != hovering else { return }
                    withAnimation(Chrome.hover) { isHovering = hovering }
                }

            Group {
                if prominent {
                    label.background {
                        Capsule(style: .continuous)
                            .fill(.tint)
                            .overlay {
                                Capsule(style: .continuous)
                                    .fill(pressOverlay)
                                    .animation(Chrome.hover, value: isHovering)
                                    .animation(Chrome.hover, value: configuration.isPressed)
                            }
                    }
                } else {
                    label.chromeGlassCapsule()
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .pointerStyle(.default)
            .background { NoWindowDragArea() }
        }

        private var foreground: Color {
            if prominent { return .white }
            let base = configuration.role == .destructive && isHovering && isEnabled ? Chrome.danger : Chrome.primaryText
            return base.opacity(isHovering || configuration.isPressed ? 1 : 0.92)
        }

        private var pressOverlay: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return .black.opacity(0.14) }
            if isHovering { return .white.opacity(0.10) }
            return .clear
        }
    }

    private struct PillLabelStyle: LabelStyle {
        let iconOnly: Bool

        func makeBody(configuration: Configuration) -> some View {
            if iconOnly {
                configuration.icon.font(Chrome.inlineIconFont)
            } else {
                HStack(spacing: 6) {
                    configuration.icon.font(Chrome.inlineIconFont)
                    configuration.title
                }
            }
        }
    }
}
