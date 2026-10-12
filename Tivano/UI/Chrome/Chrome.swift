import AppKit
import SwiftUI

/// Tokens and building blocks shared with the settings panel, so the pages read as one family.
enum Chrome {
    /// Catalog keys stay plain strings; unknown keys and user data are displayed unchanged.
    static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// A term set inside a sentence: lowercased only while it is still English, so a
    /// translation (and the "API" in it) keeps its own case.
    static func localizedLowercased(_ key: String) -> String {
        let text = localized(key)
        return text == key ? text.lowercased() : text
    }

    /// A one-`%@` template's text before and after the value, for a value that is a view of
    /// its own (a button, a styled name) rather than a string.
    static func localizedAround(_ template: String) -> (before: String, after: String) {
        let parts = localized(template).components(separatedBy: "%@")
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    // MARK: Window

    /// The detail sheet runs to the window's edge: inset, it drew a second, tighter corner
    /// inside the window's own, a clipped double border wherever the sidebar left it bare.
    static let sheetInset: CGFloat = 0
    /// The rounding of surfaces that sit on the sheet, like the terminal's top corners.
    static let sheetCornerRadius: CGFloat = 16

    static let trafficLightDiameter: CGFloat = 14
    static let trafficLightSpacing: CGFloat = 9
    static var trafficLightPitch: CGFloat { trafficLightDiameter + trafficLightSpacing }
    static let trafficLightLeading: CGFloat = 18
    static let trafficLightTop: CGFloat = 16
    static var trafficLightsWidth: CGFloat { trafficLightDiameter * 3 + trafficLightSpacing * 2 }
    static let trafficLightClearance: CGFloat = 10

    // MARK: Sticky chrome row

    /// One weight and size for every symbol that is a control on its own: chrome buttons,
    /// the composer's paperclip and send, the terminal strip. Symbols beside text step down
    /// a point so they sit level with the type; menu chevrons are small and bold.
    @MainActor static var iconFont: Font { .ui(.callout, weight: .semibold) }
    @MainActor static var inlineIconFont: Font { .ui(.subheadline, weight: .semibold) }
    static var chevronFont: Font { .system(size: 8, weight: .bold) }
    static let chromeHorizontalPadding: CGFloat = 14
    static let chromeTopPadding: CGFloat = 12
    static let capsuleContentHeight: CGFloat = 28
    static let capsuleVerticalPadding: CGFloat = 2
    static let capsuleHorizontalPadding: CGFloat = 12
    static let iconCapsuleInnerPadding: CGFloat = 3
    static let dividerHeight: CGFloat = 14
    static var capsuleHeight: CGFloat { capsuleContentHeight + capsuleVerticalPadding * 2 }
    static let contentBreathBelowChrome: CGFloat = 28
    static var contentTopInset: CGFloat { chromeTopPadding + capsuleHeight + contentBreathBelowChrome }
    static let veilHeight: CGFloat = 72
    static let titleStartOffset: CGFloat = 10
    static let titleEndOffset: CGFloat = 44
    static let progressQuantum: CGFloat = 0.04

    // MARK: Sidebar

    static let rowHeight: CGFloat = 28
    static let rowCornerRadius: CGFloat = 7
    static let rowHorizontalPadding: CGFloat = 8
    static let iconSize: CGFloat = 20
    static let symbolSize: CGFloat = 14
    static let groupGap: CGFloat = 10
    static let listInset: CGFloat = 10

    // MARK: Cards

    static let cardCornerRadius: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let sectionHeaderSpacing: CGFloat = 10
    static let contentHorizontalPadding: CGFloat = 16
    /// The gap between a row's trailing control and the card edge.
    static let rowControlTrailingPadding: CGFloat = 10
    /// The height a settings row's trailing button label is held to. A monospaced `> agy`
    /// copy button drew a taller capsule than the plain "Sign in" beside it, so the two
    /// read as two sizes; one clamped label height keeps the controls in a row even.
    @MainActor static var rowButtonLabelHeight: CGFloat { TypeScale.shared.ui(16) }

    // MARK: Color and motion

    static func overlay(_ opacity: Double) -> Color {
        primaryText.opacity(opacity)
    }

    // Dynamic system colors resolve at draw time, so one wrapped value serves every appearance.
    static let primaryText = Color(nsColor: .labelColor)
    /// Supporting copy: captions, metadata lines, row details. Primary at 70% clears the
    /// 4.5:1 floor on both grounds; `secondaryLabelColor`'s 50% alpha does not.
    static let secondaryText = primaryText.opacity(0.7)
    private static let systemAccent = Color(nsColor: .controlAccentColor)

    /// The theme's accent, or the system control accent for System/Light/Dark.
    /// The window root also applies it as the view tint, so prominent glass
    /// buttons, toggles and progress indicators follow the theme.
    static var accent: Color { ThemeManager.spec.accent ?? systemAccent }
    /// The same accent for AppKit: text view link attributes and layer colours.
    static var accentNSColor: NSColor { ThemeManager.spec.accent.map { NSColor($0) } ?? .controlAccentColor }

    /// Status hues: system green/orange/red for System/Light/Dark, the
    /// palette's own hues for every named theme.
    static var success: Color { ThemeManager.spec.success }
    static var warning: Color { ThemeManager.spec.warning }
    static var danger: Color { ThemeManager.spec.danger }

    /// The theme's glass tint, washed over capsules, sheets and the window.
    static var glassTint: Color { ThemeManager.spec.surface }

    static var hover: Animation { .easeOut(duration: 0.1) }

    static var panelSlide: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.32, dampingFraction: 0.9)
    }

    /// The motion of a settling row's glide and of the rows making room for it, so they
    /// land together.
    static let glideSpring = Spring(response: 0.6, dampingRatio: 0.86)

    /// The rows making room as a thread settles to the bottom of the sidebar or comes back
    /// up: the glide's own spring, so the ghost and the rows land together.
    static var settleFlight: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.2)
            : .spring(glideSpring)
    }

    static let gray = Color(red: 0.556, green: 0.557, blue: 0.576)
    static let blue = Color(red: 0.040, green: 0.478, blue: 1.000)
    static let orange = Color(red: 1.000, green: 0.584, blue: 0.000)
}

// MARK: - Surfaces

extension View {
    /// Capsule buttons stay Liquid Glass, washed with a tad of the theme. On a glass panel
    /// they draw flat instead (see `isOnGlassPanel`): glass on glass samples the same
    /// pixels twice, once for the panel and once for the button.
    func chromeGlassCapsule() -> some View {
        modifier(ChromeGlassSurface(shape: .capsule))
    }

    /// The capsule for a field rather than a button: the same glass, without the press
    /// response. A field is clicked to place the caret, and interactive glass answered
    /// the click with its press bounce at the same moment the field took focus, so the
    /// capsule flickered on every tap.
    func chromeGlassFieldCapsule() -> some View {
        modifier(ChromeGlassSurface(shape: .capsule, isInteractive: false))
    }

    func chromeGlassCircle() -> some View {
        modifier(ChromeGlassSurface(shape: .circle))
    }

    /// The inset content sheet the detail pane floats on.
    func detailSheet() -> some View {
        modifier(DetailSheetModifier())
    }

    /// The timeline's floating surfaces share a theme wash and a hairline. A tab's
    /// tucked-under foot omits its rim so it does not cross the composer's glass.
    func floatingGlass<S: InsettableShape>(
        _ shape: S,
        tint: Color? = nil,
        rim: Color? = nil,
        isInteractive: Bool = false,
        hiddenRimBottom: CGFloat = 0
    ) -> some View {
        modifier(FloatingGlassSurface(shape: shape, tint: tint, rim: rim, isInteractive: isInteractive, hiddenRimBottom: hiddenRimBottom))
    }

    func floatingGlassContainer() -> some View {
        modifier(FloatingGlassContainer())
    }
}

extension Chrome {
    static func floatingGlassWash(isDark: Bool) -> Color {
        glassTint.opacity(isDark ? 0.15 : 0.35)
    }

    static func floatingGlassRim(isDark: Bool) -> Color {
        isDark
            ? Color(hue: 210 / 360, saturation: 0.18, brightness: 0.82).opacity(0.09)
            : Color(hue: 210 / 360, saturation: 0.30, brightness: 0.38).opacity(0.10)
    }
}

private struct FloatingGlassContainer: ViewModifier {
    @AppStorage("floatingGlassStyle", store: CaptureRun.defaults ?? .standard) private var floatingGlassStyle = "local"

    func body(content: Content) -> some View {
        if floatingGlassStyle == "upstream" {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

private struct FloatingGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let rim: Color?
    let isInteractive: Bool
    let hiddenRimBottom: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let edge = shape
            .strokeBorder(rim ?? Chrome.floatingGlassRim(isDark: isDark), lineWidth: 1)
            .mask(alignment: .top) { Rectangle().padding(.bottom, hiddenRimBottom) }
        if reduceTransparency || performanceMode {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .clipShape(shape)
                .overlay { edge }
        } else {
            // An opaque base behind glass becomes its sample and hides the timeline.
            content
                .glassEffect(glass(isDark: isDark), in: shape)
                .overlay { edge }
        }
    }

    private func glass(isDark: Bool) -> Glass {
        let wash = tint ?? Chrome.floatingGlassWash(isDark: isDark)
        return isInteractive ? .regular.tint(wash).interactive() : .regular.tint(wash)
    }
}

/// A control's surface: interactive Liquid Glass, or, inside a glass panel, the panel's
/// flat control fill, a shade brighter under the pointer the way the glass would be.
private struct ChromeGlassSurface: ViewModifier {
    enum Kind { case capsule, circle }
    let shape: Kind
    /// Whether the glass answers a press; off for a field that takes the caret instead.
    var isInteractive = true
    @Environment(\.isOnGlassPanel) private var isOnGlassPanel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            surface(content, in: Capsule(style: .continuous))
        case .circle:
            surface(content, in: Circle())
        }
    }

    @ViewBuilder
    private func surface<S: InsettableShape>(_ content: Content, in shape: S) -> some View {
        if isOnGlassPanel || performanceMode {
            content
                .background(shape.fill(Chrome.panelControlFill(isDark: colorScheme == .dark, hovered: isHovered)))
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(performanceMode ? nil : Chrome.hover, value: isHovered)
        } else if isInteractive {
            content.glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)).interactive(), in: shape)
        } else {
            content.glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)), in: shape)
        }
    }
}

private struct DetailSheetModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        // Square: the window's own clip rounds the sheet's outer corners with everything
        // else, so the sheet never draws a corner of its own inside the window's. Flat
        // fills, so performance mode keeps them.
        content
            .background {
                Rectangle().fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.3))
                Rectangle().fill(Chrome.glassTint.opacity(colorScheme == .dark ? 0.22 : 0.16))
            }
    }
}

/// The window supplies the exterior curve and border; the backdrop follows its container.
struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @AppStorage("windowBackdropStyle", store: CaptureRun.defaults ?? .standard) private var windowBackdropStyle = "glass"
    /// The backdrop setting, 0 for bare glass and 1 for a solid base.
    let opacity: Double
    /// The user's wallpaper, painted edge to edge at the transparency setting's own opacity; nil for the stock glass.
    var wallpaper: NSImage? = nil

    /// The scrim over the glass for a backdrop setting: the stock scrim at the
    /// midpoint, none at 0, a solid base at 1, linear either side.
    static func scrim(for opacity: Double, isDark: Bool) -> Double {
        let stock = isDark ? 0.26 : 0.18
        let t = min(max(opacity, 0), 1)
        return t <= 0.5 ? stock * (t / 0.5) : stock + (1 - stock) * ((t - 0.5) / 0.5)
    }

    private var shape: ContainerRelativeShape {
        // SwiftUI supplies a container for sheets. An AppKit-hosted root falls back to
        // a rectangle, leaving the native window frame to clip its exterior corners.
        // https://developer.apple.com/documentation/swiftui/containerrelativeshape
        ContainerRelativeShape()
    }

    private var solidBackdrop: some View {
        shape.fill(colorScheme == .dark ? Color.black : Color.white)
            .overlay { shape.fill(Chrome.glassTint.opacity(0.12)) }
    }

    var body: some View {
        let isDark = colorScheme == .dark
        let isSolid = opacity >= 0.98
        if performanceMode || ((isSolid || reduceTransparency) && wallpaper == nil) {
            solidBackdrop
        } else {
            Group {
                if let wallpaper {
                    // The picture's opacity follows the transparency slider, with no scrim.
                    shape.fill(.clear)
                        .overlay {
                            Image(nsImage: wallpaper)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                                .opacity(opacity)
                        }
                        .clipShape(shape)
                        .overlay {
                            if !isSolid {
                                shape
                                    .fill(.clear)
                                    .glassEffect(in: shape)
                            }
                        }
                        .transition(.opacity)
                } else {
                    Group {
                        if windowBackdropStyle == "blur" {
                            BehindWindowBlur()
                                .clipShape(shape)
                        } else {
                            shape
                                .fill(.clear)
                                .glassEffect(in: shape)
                        }
                    }
                    .overlay {
                        shape
                            .fill(isDark ? Color.black : Color.white)
                            .opacity(Self.scrim(for: opacity, isDark: isDark))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: wallpaper != nil)
            .overlay {
                shape.fill(Chrome.glassTint.opacity(0.12))
            }
        }
    }

}

/// Samples behind the window and retains its active material when the window loses focus.
/// Exterior clipping belongs to the local container and native window frame.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// No pressed feedback, while retaining Button semantics for keyboard and accessibility.
struct ChromeQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Reveals its single child by height: fraction 1 gives the slot the child's natural
/// height, 0 collapses the slot to nothing while the child stays mounted, laid out
/// top-leading at full size so it never travels — the clip reveals it in place.
/// Animatable, so a panelSlide transaction slides the fraction, not the child.
struct ChromeRevealLayout: Layout {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: natural.height * min(max(fraction, 0), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

// MARK: - Chrome controls

struct ChromeCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, Chrome.iconCapsuleInnerPadding)
        .padding(.vertical, Chrome.capsuleVerticalPadding)
        .chromeGlassCapsule()
        // The capsule is a control wherever it sits: presses on it work the control and
        // never drag the window.
        .background { NoWindowDragArea() }
    }
}

struct ChromeDivider: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 0.5, style: .continuous)
            .fill(Chrome.primaryText.opacity(0.22))
            .frame(width: 1, height: Chrome.dividerHeight)
            .accessibilityHidden(true)
    }
}

struct ChromeIconLabel: View {
    let symbol: String
    var isEnabled = true
    var isActive = false
    var isHovering = false
    var prominent = false
    var secondary = false

    var body: some View {
        Image(systemName: symbol)
            .font(prominent ? .ui(.title3, weight: .semibold) : Chrome.iconFont)
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(foreground))
            .frame(width: prominent ? Chrome.capsuleHeight : Chrome.capsuleContentHeight, height: prominent ? Chrome.capsuleHeight : Chrome.capsuleContentHeight)
            .background {
                if isActive || (prominent && isHovering) {
                    Circle()
                        .fill(Chrome.overlay(isActive ? 0.12 : 0.08))
                        .shadow(color: Chrome.primaryText.opacity(prominent && isHovering ? 0.1 : 0), radius: Chrome.capsuleVerticalPadding * 2, y: Chrome.capsuleVerticalPadding)
                        .padding(1)
                }
            }
            .contentShape(.rect)
    }

    private var foreground: Color {
        guard isEnabled else { return Chrome.primaryText.opacity(0.32) }
        if isActive { return Chrome.primaryText }
        return Chrome.primaryText.opacity(isHovering ? 1 : 0.92)
    }
}

struct ChromeIconButton: View {
    let symbol: String
    var isEnabled = true
    var isActive = false
    var prominent = false
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ChromeIconLabel(symbol: symbol, isEnabled: isEnabled, isActive: isActive, isHovering: isHovering, prominent: prominent)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: Chrome.localized(help)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
        .background { NoWindowDragArea() }
    }
}

/// Lets a containing toolbar stay visible while one of its controls presents a menu.
// SwiftUI preferences propagate child state to the container:
// https://developer.apple.com/documentation/swiftui/preferences
struct ChromePresentationPreference: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        let next = nextValue()
        value = value || next
    }
}

struct ChromeMenuButton<Content: View>: View {
    let symbol: String
    var secondary = false
    let help: String
    @ViewBuilder var content: Content

    @State private var isHovering = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ChromeIconLabel(symbol: symbol, isActive: isPresented, isHovering: isHovering, secondary: secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: Chrome.localized(help)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu { content }
        }
        .preference(key: ChromePresentationPreference.self, value: isPresented)
        .background { NoWindowDragArea() }
    }
}

/// A round glass button the height of a chrome capsule.
struct ChromeCircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.iconFont)
                .foregroundStyle(Chrome.primaryText.opacity(isHovering ? 1 : 0.92))
                .frame(width: Chrome.capsuleHeight, height: Chrome.capsuleHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chromeGlassCircle()
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: Chrome.localized(help)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
        .background { NoWindowDragArea() }
    }
}

/// A text button shaped like a chrome capsule that opens a popover, such as the branch picker.
struct ChromeTextMenu<Content: View>: View {
    let symbol: String
    let title: String
    let help: String
    @ViewBuilder var content: Content

    @State private var isHovering = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(Chrome.inlineIconFont)
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(Chrome.chevronFont)
                    .foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: Chrome.localized(help)))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu { content }
        }
        .preference(key: ChromePresentationPreference.self, value: isPresented)
        .background { NoWindowDragArea() }
    }
}

/// A text button shaped like a chrome capsule, such as the archive page's delete all. A
/// destructive one reads as an ordinary chrome control at rest and turns red under the pointer.
struct ChromeTextButton: View {
    let symbol: String
    let title: String
    let help: String
    var isEnabled = true
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(Chrome.inlineIconFont)
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: Chrome.localized(help)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
        .background { NoWindowDragArea() }
    }

    private var foreground: Color {
        guard isEnabled else { return Chrome.primaryText.opacity(0.32) }
        if isDestructive { return Chrome.danger.opacity(isHovering ? 1 : 0.92) }
        return Chrome.primaryText.opacity(isHovering ? 1 : 0.92)
    }
}

// MARK: - Scroll morph

/// Scroll progress for the sticky chrome. Only the edge fade and the compact title observe it,
/// so scrolling never re-renders the page underneath.
@MainActor
@Observable
final class ChromeScrollModel {
    private(set) var progress: CGFloat = 0

    func update(travel: CGFloat) {
        let raw = (travel - Chrome.titleStartOffset) / (Chrome.titleEndOffset - Chrome.titleStartOffset)
        let clamped = min(max(raw, 0), 1)
        let quantized = (clamped / Chrome.progressQuantum).rounded() * Chrome.progressQuantum
        if quantized != progress { progress = quantized }
    }
}

/// Content scrolling under the chrome dissolves into the backdrop instead of being
/// covered: the top of the pane is masked away, so the window's own glass and picture
/// stay visible behind the title and capsules, with nothing painted over them. This was
/// a white or black scrim plus the theme's tint, which kept the title legible but turned
/// the top of a transparent window into an opaque band once the chat scrolled.
extension View {
    func chromeEdgeFade(_ model: ChromeScrollModel) -> some View {
        mask { ChromeEdgeFadeMask(model: model) }
    }
}

/// The mask alone observes the scroll progress, so scrolling never re-renders the page
/// it masks. At rest it is solid and costs nothing visible; it eases in with the title.
private struct ChromeEdgeFadeMask: View {
    let model: ChromeScrollModel

    var body: some View {
        let progress = Double(model.progress)
        VStack(spacing: 0) {
            ZStack {
                Self.fade
                Color.black.opacity(1 - progress)
            }
            .frame(height: Chrome.veilHeight)
            Color.black
        }
    }

    /// Gone by the middle of the chrome row, so nothing reads behind the title, then
    /// eased back to full by the line the page's content rests on.
    private static var fade: LinearGradient {
        let chromeMiddle = (Chrome.chromeTopPadding + Chrome.capsuleHeight / 2) / Chrome.veilHeight
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: chromeMiddle),
                .init(color: .black.opacity(0.45), location: 0.74),
                .init(color: .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The title that fades into the chrome row once the page's own title scrolls away.
struct ChromeCompactTitle: View {
    let title: String
    let model: ChromeScrollModel

    var body: some View {
        let progress = model.progress
        Text(verbatim: Chrome.localized(title))
            .font(.ui(.title3, weight: .semibold))
            .foregroundStyle(Chrome.primaryText)
            .lineLimit(1)
            .opacity(Double(progress))
            .offset(y: (1 - progress) * 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(progress < 0.5)
    }
}

// MARK: - Sidebar pieces

struct SidebarSymbol: View {
    let name: String
    var scale: CGFloat = 1

    init(_ name: String, scale: CGFloat = 1) {
        self.name = name
        self.scale = scale
    }

    var body: some View {
        Image(systemName: name)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: Chrome.symbolSize * scale, height: Chrome.symbolSize * scale)
            .symbolRenderingMode(.monochrome)
    }
}

/// A sidebar glyph on its own: a provider logo or an SF Symbol, with nothing drawn behind it.
struct SidebarIconBadge<Glyph: View>: View {
    @ViewBuilder var glyph: Glyph

    var body: some View {
        glyph
            .foregroundStyle(Chrome.primaryText.opacity(0.85))
            .frame(width: Chrome.iconSize, height: Chrome.iconSize)
    }
}

struct SidebarRow<Icon: View, Accessory: View>: View {
    let title: String
    let isSelected: Bool
    let isEmphasized: Bool
    let accessoryWidth: CGFloat
    let action: () -> Void
    let icon: Icon
    let accessory: (Bool) -> Accessory

    @State private var isHovering = false

    init(
        title: String,
        isSelected: Bool = false,
        isEmphasized: Bool = false,
        accessoryWidth: CGFloat = 0,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder accessory: @escaping (Bool) -> Accessory
    ) {
        self.title = title
        self.isSelected = isSelected
        self.isEmphasized = isEmphasized
        self.accessoryWidth = accessoryWidth
        self.action = action
        self.icon = icon()
        self.accessory = accessory
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                    .frame(width: Chrome.iconSize, alignment: .center)
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(.body, weight: isSelected || isEmphasized ? .medium : .regular))
                    .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 1 : 0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .padding(.leading, Chrome.rowHorizontalPadding)
            .padding(.trailing, Chrome.rowHorizontalPadding + accessoryWidth)
            .frame(height: Chrome.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { shape.fill(fill).animation(Chrome.hover, value: isSelected) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            accessory(isHovering)
                .padding(.trailing, 6)
        }
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Chrome.overlay(0.12) }
        if isHovering { return Chrome.overlay(0.06) }
        return .clear
    }
}

extension SidebarRow where Accessory == EmptyView {
    init(
        title: String,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.init(title: title, isSelected: isSelected, action: action, icon: icon) { _ in EmptyView() }
    }
}

struct RowAccessoryIcon: View {
    let symbol: String

    init(_ symbol: String) {
        self.symbol = symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .font(Chrome.inlineIconFont)
            .foregroundStyle(Chrome.secondaryText)
            .frame(width: 20, height: 20)
            .contentShape(.rect)
    }
}

struct SidebarSearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var onSubmit: () -> Void = {}
    /// Up and down walk the results, one step per press. Last, so a bare trailing closure
    /// still means `onSubmit`. Left out where there is no list under the field, and the
    /// arrows are then the field's own again.
    var onMove: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.secondaryText.opacity(0.85))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.ui(.body))
                .frame(maxWidth: .infinity)
                .onSubmit(onSubmit)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: TypeScale.shared.ui(30))
        .background {
            Capsule(style: .continuous).fill(Chrome.overlay(0.07))
        }
        .contentShape(Capsule(style: .continuous))
        // Escape empties the field, the way the chrome's search capsule does.
        .onExitCommand { text = "" }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard let onMove else { return .ignored }
        onMove(offset)
        return .handled
    }
}

/// A glass search capsule for a pane's chrome row. Fixed size so it sits aligned with the
/// other capsules instead of pushing them or clipping the sheet edge.
struct ChromeSearchField: View {
    static let width: CGFloat = 200

    @Binding var query: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.ui(.callout, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .accessibilityHidden(true)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                // The capsule is the field's edge; the focus ring flashed around the text
                // alone as the caret landed.
                .focusEffectDisabled()
                .font(.ui(size: 12.5))
                .foregroundStyle(Chrome.primaryText)
            Button {
                query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.8))
            }
            .buttonStyle(.plain)
            // Always laid out, so the field's text never shifts when the button comes;
            // invisible and out of the accessibility tree while there is nothing to clear.
            .opacity(query.isEmpty ? 0 : 1)
            .disabled(query.isEmpty)
            .accessibilityHidden(query.isEmpty)
            .accessibilityLabel(Text("Clear search"))
        }
        .padding(.horizontal, 10)
        .frame(width: Self.width, height: Chrome.capsuleContentHeight)
        .padding(.vertical, Chrome.capsuleVerticalPadding)
        .chromeGlassFieldCapsule()
        .fixedSize()
        .onExitCommand { query = "" }
        .background { NoWindowDragArea() }
    }
}

/// A glass capsule showing the current choice; clicking it opens the choices in a native popover.
struct GlassPickerButton<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var asset: (Value) -> String? = { _ in nil }
    /// An SF Symbol per value, shown before the title and on each row, for pickers whose
    /// values have no image asset.
    var symbol: (Value) -> String? = { _ in nil }
    var maxWidth: CGFloat? = nil

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        let title = options.first { $0.value == selection }?.title ?? ""
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                if let name = asset(selection) {
                    Image(name)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
                if let symbol = symbol(selection) {
                    Image(systemName: symbol)
                        .font(.ui(.callout, weight: .medium))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(Chrome.chevronFont)
                    .foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: maxWidth == nil, vertical: true)
        .chromeGlassCapsule()
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    PopoverItem(option.title, symbol: symbol(option.value), asset: asset(option.value), isChecked: option.value == selection) {
                        selection = option.value
                    }
                }
            }
        }
        .background { NoWindowDragArea() }
    }
}

/// A soft appearance: fades in with a short rise. Opacity and offset are plain layer
/// properties, so a view in its settled state costs nothing extra; a blur here would leave
/// every timeline row and markdown block with a filter of its own, an offscreen pass each.
struct SoftAppearModifier: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 4)
    }
}

extension AnyTransition {
    /// Arrives softly; leaves with a quick fade so removals never drag.
    static var softAppear: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SoftAppearModifier(isVisible: false), identity: SoftAppearModifier(isVisible: true))
                .animation(.softAppear),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }
}

extension Animation {
    /// The timing every soft appearance shares.
    static var softAppear: Animation { .smooth(duration: 0.32) }
}

/// A departing badge's face along its glide: `progress` runs from 0, in place, to 1, gone.
/// The face holds through the first half of the flight and fades over the second, the way
/// the sidebar's ghost slips out of the list's edge (see `RowGlideAnimator`); with Reduce
/// Motion on it fades where it stands.
private struct SettleGlideModifier: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = reduceMotion ? progress : Self.smoothstep(0.45, 0.92, progress)
        content
            .opacity(1 - fade)
            .offset(y: reduceMotion ? 0 : 22 * progress)
            .scaleEffect(reduceMotion ? 1 : 1 - 0.04 * progress, anchor: .top)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

extension AnyTransition {
    /// How a badge whose work is done leaves the timeline: the way a settled chat's row
    /// leaves the sidebar. It glides down a little on the glide spring and fades out on the
    /// way, gone before it would land. It arrives softly, like everything else.
    static var settleGlide: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SoftAppearModifier(isVisible: false), identity: SoftAppearModifier(isVisible: true))
                .animation(.softAppear),
            removal: .modifier(active: SettleGlideModifier(progress: 1), identity: SettleGlideModifier(progress: 0))
                .animation(.spring(Chrome.glideSpring))
        )
    }
}

// MARK: - Cards

struct ChromeCard<Content: View>: View {
    /// Use lazy only for cards that list a long, uniform, growing collection.
    /// Variable-height rows at the visible bottom edge can rebuild without end.
    var lazy = false
    @ViewBuilder var content: Content

    var body: some View {
        // The card uses a filled shape instead of a clip, avoiding a mask while scrolling.
        Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) { content }
            } else {
                VStack(alignment: .leading, spacing: 0) { content }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                .fill(Chrome.overlay(0.03))
        )
    }
}

struct ChromeSection<Content: View>: View {
    let title: String
    /// Sits right after the title: an info button, a count.
    var accessory: AnyView? = nil
    /// Sits at the header's far right: a control for the whole section, out of its cards.
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            HStack(spacing: 4) {
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                if let accessory { accessory }
                if let trailing {
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChromeRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                if let detail, !detail.isEmpty {
                    Text(verbatim: Chrome.localized(detail))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.leading, 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 11)
    }
}

struct ChromeRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}

// MARK: - Window drag

/// Lets a stretch of chrome move the window, the way the sidebar does in the app's settings.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

/// Marks a chrome control's hit area as never dragging the window.
///
/// The chrome row sits inside the title bar's reach (see `WindowChrome.titlebarHeight`), where
/// AppKit moves the window for any view that lets it. Native controls refuse on their own, but a
/// control SwiftUI renders itself — a drag track, say — lands on the shared hosting view, which
/// lets the window move: dragging such a control moved the window with it. This view sits
/// behind the control's content, so it wins the hit test for presses no narrower control claims and
/// refuses the window drag for them; the presses themselves travel on to SwiftUI, so gestures,
/// popovers and buttons work exactly as before. Empty chrome around the controls has no such view
/// behind it, and still drags the window like a title bar.
struct NoWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NoWindowDragView {
        NoWindowDragView(frame: .zero)
    }

    func updateNSView(_ nsView: NoWindowDragView, context: Context) {}
}

final class NoWindowDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press here works the control, never the window.
    override var mouseDownCanMoveWindow: Bool { false }

    // The view draws nothing and keeps nothing: it only takes the hit so the window does not
    // drag. Each press travels on to the superview, which routes it to the control under the
    // pointer the way a directly dispatched press would.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }

    override func mouseDragged(with event: NSEvent) { superview?.mouseDragged(with: event) }

    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }

    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    override func rightMouseUp(with event: NSEvent) { superview?.rightMouseUp(with: event) }
}
