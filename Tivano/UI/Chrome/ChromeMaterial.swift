import AppKit
import SwiftUI

/// Liquid Glass on macOS 26 and later; a Texture surface (translucent material, tint wash and
/// a top-lit rim) on older systems. Every branch here is on the OS version only, which never
/// changes while the app runs, so wrapped content keeps one identity across theme switches.
/// Theme-driven looks (Creation's solid surfaces) stay with the callers, which pass `.identity`.
enum ChromeMaterial {
    static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    fileprivate static let darkRimGradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.18), location: 0),
            .init(color: .white.opacity(0.08), location: 0.5),
            .init(color: .white.opacity(0.03), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    fileprivate static let lightRimGradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.50), location: 0),
            .init(color: .white.opacity(0.20), location: 0.5),
            .init(color: .white.opacity(0.06), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    fileprivate static let prominentRimGradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.32), location: 0),
            .init(color: .white.opacity(0.06), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    fileprivate static func rimGradient(isDark: Bool) -> LinearGradient {
        isDark ? darkRimGradient : lightRimGradient
    }
}

/// A version-independent description of a `Glass` value.
struct ChromeGlass: Equatable, Sendable {
    var tint: Color?
    var isInteractive: Bool
    /// No surface at all, like `Glass.identity`.
    var isIdentity: Bool

    init(tint: Color? = nil, isInteractive: Bool = false, isIdentity: Bool = false) {
        self.tint = tint
        self.isInteractive = isInteractive
        self.isIdentity = isIdentity
    }

    static let regular = ChromeGlass()
    static let identity = ChromeGlass(isIdentity: true)

    func tint(_ color: Color?) -> ChromeGlass {
        ChromeGlass(tint: color, isInteractive: isInteractive, isIdentity: isIdentity)
    }

    func interactive(_ isEnabled: Bool = true) -> ChromeGlass {
        ChromeGlass(tint: tint, isInteractive: isEnabled, isIdentity: isIdentity)
    }

    @available(macOS 26.0, *)
    var glass: Glass {
        if isIdentity { return .identity }
        var resolved: Glass = .regular
        if let tint {
            resolved = resolved.tint(tint)
        }
        if isInteractive {
            resolved = resolved.interactive()
        }
        return resolved
    }
}

extension View {
    /// `glassEffect(_:in:)` on macOS 26; a Texture surface before it.
    func chromeGlassEffect<S: Shape>(_ glass: ChromeGlass = .regular, in shape: S) -> some View {
        modifier(ChromeGlassEffectModifier(glass: glass, shape: shape))
    }

    /// `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` on macOS 26; a Texture capsule before it.
    func chromeGlassButtonStyle(prominent: Bool = false) -> some View {
        modifier(ChromeGlassButtonStyleModifier(isProminent: prominent))
    }
}

/// `GlassEffectContainer` on macOS 26; the bare content before it.
struct ChromeGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private struct ChromeGlassEffectModifier<S: Shape>: ViewModifier {
    let glass: ChromeGlass
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass.glass, in: shape)
        } else {
            content.modifier(TextureGlassSurfaceModifier(glass: glass, shape: shape))
        }
    }
}

private struct ChromeGlassButtonStyleModifier: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            content.buttonStyle(TextureGlassButtonStyle(isProminent: isProminent))
        }
    }
}

/// The pre-macOS 26 stand-in for a glass surface. `.identity` draws nothing, and the
/// wrapped content stays on one path whether or not the surface is drawn.
private struct TextureGlassSurfaceModifier<S: Shape>: ViewModifier {
    let glass: ChromeGlass
    let shape: S
    var isPressed = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let isDrawn = !glass.isIdentity
        content
            .background {
                if isDrawn {
                    ZStack {
                        if reduceTransparency {
                            shape.fill(Color(nsColor: .controlBackgroundColor))
                        } else {
                            shape
                                .fill(Material.ultraThin)
                                .shadow(
                                    color: .black.opacity(isDark ? 0.20 : 0.07),
                                    radius: 3,
                                    x: 0,
                                    y: 1
                                )
                        }
                        shape.fill(glass.tint ?? Chrome.glassTint.opacity(isDark ? 0.24 : 0.30))
                        if glass.isInteractive {
                            shape
                                .fill(interactionOverlay(isDark: isDark))
                                .animation(Chrome.hover, value: isHovered)
                                .animation(Chrome.hover, value: isPressed)
                        }
                    }
                }
            }
            .overlay {
                if isDrawn {
                    shape
                        .stroke(ChromeMaterial.rimGradient(isDark: isDark), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                guard glass.isInteractive, isHovered != hovering else { return }
                isHovered = hovering
            }
    }

    private func interactionOverlay(isDark: Bool) -> Color {
        guard isEnabled else { return .clear }
        if isPressed {
            return .black.opacity(isDark ? 0.16 : 0.09)
        }
        if isHovered {
            return .white.opacity(isDark ? 0.07 : 0.16)
        }
        return .clear
    }
}

private struct TextureGlassButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, isProminent: isProminent)
    }

    private struct ButtonBody: View {
        let configuration: Configuration
        let isProminent: Bool

        @Environment(\.controlSize) private var controlSize
        /// A font set on the button wins, as it does for the Liquid Glass button styles.
        @Environment(\.font) private var environmentFont
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @State private var isHovered = false

        var body: some View {
            let capsule = Capsule(style: .continuous)
            let padded = configuration.label
                .font(environmentFont ?? defaultFont)
                .foregroundStyle(labelColor)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(minHeight: minHeight)

            Group {
                if isProminent {
                    padded
                        .background {
                            ZStack {
                                capsule
                                    .fill(.tint)
                                    .shadow(
                                        color: .black.opacity(reduceTransparency ? 0 : (colorScheme == .dark ? 0.24 : 0.10)),
                                        radius: 3,
                                        x: 0,
                                        y: 1
                                    )
                                capsule
                                    .fill(prominentOverlay)
                                    .animation(Chrome.hover, value: isHovered)
                                    .animation(Chrome.hover, value: configuration.isPressed)
                            }
                        }
                        .overlay {
                            capsule
                                .strokeBorder(ChromeMaterial.prominentRimGradient, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .contentShape(capsule)
                        .onHover { hovering in
                            guard isHovered != hovering else { return }
                            isHovered = hovering
                        }
                } else {
                    padded
                        .modifier(
                            TextureGlassSurfaceModifier(
                                glass: .regular.interactive(),
                                shape: capsule,
                                isPressed: configuration.isPressed
                            )
                        )
                        .contentShape(capsule)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
        }

        private var labelColor: Color {
            if isProminent {
                return .white
            }
            return configuration.role == .destructive ? Chrome.danger : Chrome.primaryText
        }

        private var prominentOverlay: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed {
                return .black.opacity(0.14)
            }
            if isHovered {
                return .white.opacity(0.10)
            }
            return .clear
        }

        private var minHeight: CGFloat {
            switch controlSize {
            case .mini: 20
            case .small: 24
            case .regular: 28
            case .large: 34
            case .extraLarge: 40
            @unknown default: 28
            }
        }

        private var horizontalPadding: CGFloat {
            switch controlSize {
            case .mini: 8
            case .small: 10
            case .regular: 12
            case .large: 16
            case .extraLarge: 20
            @unknown default: 12
            }
        }

        private var verticalPadding: CGFloat {
            switch controlSize {
            case .mini: 2
            case .small: 3
            case .regular: 4
            case .large: 6
            case .extraLarge: 8
            @unknown default: 4
            }
        }

        private var defaultFont: Font {
            switch controlSize {
            case .mini: .ui(.caption, weight: .medium)
            case .small: .ui(.callout, weight: .medium)
            case .regular: .ui(.body, weight: .medium)
            case .large: .ui(.body, weight: .medium)
            case .extraLarge: .ui(.title3, weight: .medium)
            @unknown default: .ui(.body, weight: .medium)
            }
        }
    }
}
