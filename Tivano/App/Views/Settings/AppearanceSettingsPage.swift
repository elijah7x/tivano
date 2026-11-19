import AppKit
import SwiftUI

/// Language, theme style, appearance mode, accent palette, wallpaper, weather window and font sizes.
struct AppearanceSettingsPage: View {
    @Environment(AppModel.self) private var model

    private static let languageOptions = AppLanguage.allCases.map { ($0, $0.title) }
    private static let themeStyleOptions: [(ThemeStyle, String)] = [
        (.liquidGlass, ThemeStyle.liquidGlass.title),
        (.texture, ThemeStyle.texture.title),
        (.create, ThemeStyle.create.title),
    ]
    private static let appIconOptions: [(AppIconChoice, String)] = [
        (.automatic, AppIconChoice.automatic.title),
        (.liquidGlass, AppIconChoice.liquidGlass.title),
        (.texture, AppIconChoice.texture.title),
        (.create, AppIconChoice.create.title),
    ]
    private static var weatherWindowOptions: [(WeatherWindowMode, String)] {
        if ThemeStyle.supportsLiquidGlass {
            [
                (.porthole, "Porthole"),
                (.full, "Full window"),
                (.off, "Off"),
            ]
        } else {
            [
                (.porthole, "Porthole"),
                (.off, "Off"),
            ]
        }
    }

    private static func weatherWindowDetail(style: ThemeStyle, mode: WeatherWindowMode) -> String {
        if style == .create {
            return "Available in the Liquid Glass and Texture themes."
        }
        switch mode {
        case .porthole:
            return "A small window above the thread list: wind when waiting on you, sunlight when a turn finishes, rain when one fails."
        case .full:
            return style == .texture
                ? "Full window is available in the Liquid Glass theme."
                : "Shows subtle wind when waiting on you, sunlight when a turn finishes, and rain when one fails."
        case .off:
            return "No weather."
        }
    }

    var body: some View {
        @Bindable var settings = model.settings
        let isCreation = settings.themeStyle == .create

        ChromeSection(title: "Language") {
            ChromeCard {
                ChromeRow(title: "App language", detail: "Changes apply after the app restarts.") {
                    GlassPickerButton(options: Self.languageOptions, selection: $settings.appLanguage)
                }
            }
        }

        ChromeSection(title: "Theme and style") {
            ChromeCard {
                ChromeRow(
                    title: "Theme",
                    detail: isCreation
                        ? "Light · Solid · Serif"
                        : (ChromeMaterial.supportsLiquidGlass ? nil : "Liquid Glass needs macOS 26 or later.")
                ) {
                    ChromeVisualPicker(
                        options: Self.themeStyleOptions,
                        selection: Binding(
                            get: { settings.themeStyle },
                            set: { style in
                                guard style.isAvailable else { return }
                                settings.themeStyle = style
                            }
                        )
                    ) { style in
                        ThemeStyleThumbnail(style: style, isSelected: settings.themeStyle == style)
                    }
                }
                ChromeRowDivider()
                ChromeRow(
                    title: "App icon",
                    detail: "Match Theme switches the Dock icon with the theme."
                ) {
                    ChromeVisualPicker(
                        options: Self.appIconOptions,
                        selection: $settings.appIconChoice
                    ) { choice in
                        AppIconChoiceThumbnail(
                            choice: choice,
                            style: settings.themeStyle,
                            isSelected: settings.appIconChoice == choice
                        )
                    }
                }
                ChromeRowDivider()
                ChromeRow(
                    title: "Transparency",
                    detail: isCreation
                        ? "Left lets the desktop through a little; right deepens the page tone."
                        : "How much shows through the window"
                ) {
                    BackdropOpacitySlider(value: $settings.backdropOpacity, stock: AppSettings.defaultBackdropOpacity(for: settings.themeStyle))
                }
                ChromeRowDivider()
                ChromeRow(
                    title: "Appearance & accent",
                    detail: isCreation
                        ? "Creation starts on Coral Red each time and stays light."
                        : "Colors controls and highlighted text."
                ) {
                    HStack(spacing: 8) {
                        AppearanceSplitCircleButton(mode: isCreation ? .constant(.light) : $settings.appearanceMode)
                            .disabled(isCreation)
                            .opacity(isCreation ? 0.5 : 1)
                        ThemePickerButton(selection: $settings.theme)
                    }
                }
            }
            WallpaperCard()
                .disabled(isCreation)
                .opacity(isCreation ? 0.5 : 1)
        }

        let effectiveWeatherMode: WeatherWindowMode = !ThemeStyle.supportsLiquidGlass && settings.weatherWindowMode == .full
            ? .off
            : settings.weatherWindowMode

        ChromeSection(title: "Weather window") {
            ChromeCard {
                ChromeRow(
                    title: "Weather window",
                    detail: Self.weatherWindowDetail(style: settings.themeStyle, mode: effectiveWeatherMode)
                ) {
                    ChromeVisualPicker(
                        options: Self.weatherWindowOptions,
                        selection: Binding(
                            get: { effectiveWeatherMode },
                            set: { settings.weatherWindowMode = $0 }
                        )
                    ) { mode in
                        WeatherWindowThumbnail(mode: mode)
                    }
                }
                .disabled(isCreation)
                .opacity(isCreation ? 0.5 : 1)
            }
        }

        FontSizeSection()
    }
}

/// Cycles system / light / dark appearance beside the accent picker.
private struct AppearanceSplitCircleButton: View {
    @Binding var mode: AppearanceMode

    @State private var isHovering = false

    private var leftHalf: Color {
        switch mode {
        case .system, .light: Color(hex: "FFFFFF")
        case .dark: Color(hex: "1E1E20")
        }
    }

    private var rightHalf: Color {
        switch mode {
        case .system, .dark: Color(hex: "1E1E20")
        case .light: Color(hex: "FFFFFF")
        }
    }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                mode = mode.next
            }
        } label: {
            HStack(spacing: 0) {
                leftHalf
                rightHalf
            }
            .frame(width: 16, height: 16)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
            .opacity(isHovering ? 1 : 0.92)
            .frame(width: Chrome.capsuleContentHeight, height: Chrome.capsuleContentHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: Chrome.localized(mode.title)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(mode.title)))
    }
}

/// Miniature window preview inside `ChromeVisualPicker` for each `ThemeStyle`.
private struct ThemeStyleThumbnail: View {
    let style: ThemeStyle
    let isSelected: Bool

    private static let creationCanvas = Color(hex: "FEFEFD")
    private static let creationSidebar = Color(hex: "F8F8F6")
    private static let creationHairline = Color(hex: "EAE8E4")
    private static let creationAccent = Color(hex: "B5654A")
    private static let creationSecondaryBar = SolidSurfaces.creation.ink.opacity(0.18)

    var body: some View {
        let stroke = isSelected ? Chrome.accent.opacity(0.65) : Chrome.primaryText.opacity(0.18)
        ZStack {
            switch style {
            case .liquidGlass:
                Group {
                    LinearGradient(
                        colors: [
                            Chrome.accent.opacity(0.24),
                            Chrome.primaryText.opacity(0.05),
                            Chrome.accent.opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    glassShell(trayOpacity: 0.22, cardOpacity: 0.14, stroke: stroke)
                }
                .opacity(style.isAvailable ? 1 : 0.45)
            case .texture:
                Chrome.primaryText.opacity(0.10)
                glassShell(trayOpacity: 0.16, cardOpacity: 0.22, stroke: stroke)
            case .create:
                Self.creationCanvas
                miniatureShell(
                    trayFill: Self.creationSidebar,
                    trayStroke: Self.creationHairline,
                    trayStrokeWidth: 0.75,
                    dotFill: Self.creationAccent.opacity(0.55),
                    primaryBarFill: Self.creationAccent,
                    secondaryBarFill: Self.creationSecondaryBar,
                    firstCardFill: Self.creationSidebar,
                    secondCardFill: Self.creationSidebar,
                    cardStroke: Self.creationHairline
                )
                RoundedRectangle(cornerRadius: ChromeVisualTileMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Self.creationHairline, lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(Text(verbatim: Chrome.localized(style.title)))
    }

    private func glassShell(trayOpacity: Double, cardOpacity: Double, stroke: Color) -> some View {
        miniatureShell(
            trayFill: Chrome.primaryText.opacity(trayOpacity),
            trayStroke: stroke.opacity(0.55),
            trayStrokeWidth: 0.5,
            dotFill: stroke,
            primaryBarFill: stroke.opacity(0.65),
            secondaryBarFill: stroke.opacity(0.4),
            firstCardFill: Chrome.primaryText.opacity(cardOpacity),
            secondCardFill: Chrome.primaryText.opacity(cardOpacity * 0.8),
            cardStroke: nil
        )
    }

    private func miniatureShell(
        trayFill: Color,
        trayStroke: Color,
        trayStrokeWidth: CGFloat,
        dotFill: Color,
        primaryBarFill: Color,
        secondaryBarFill: Color,
        firstCardFill: Color,
        secondCardFill: Color,
        cardStroke: Color?
    ) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(dotFill)
                            .frame(width: 2.5, height: 2.5)
                    }
                }
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(primaryBarFill)
                    .frame(width: 14, height: 2)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(secondaryBarFill)
                    .frame(width: 11, height: 2)
                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(width: 22, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(trayFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(trayStroke, lineWidth: trayStrokeWidth)
            )

            VStack(alignment: .leading, spacing: 4) {
                miniatureCard(fill: firstCardFill, stroke: cardStroke, height: 11)
                miniatureCard(fill: secondCardFill, stroke: cardStroke, height: 8)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(6)
    }

    private func miniatureCard(fill: Color, stroke: Color?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(height: height)
            .overlay {
                if let stroke {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 0.75)
                }
            }
    }
}

/// Miniature app icon preview inside `ChromeVisualPicker` for each `AppIconChoice`.
private struct AppIconChoiceThumbnail: View {
    let choice: AppIconChoice
    let style: ThemeStyle
    let isSelected: Bool

    var body: some View {
        let iconSize = ChromeVisualTileMetrics.height * 0.85
        ZStack {
            Image(nsImage: NSImage(named: AppIconChoice.assetName(for: choice.resolved(for: style))) ?? NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if choice == .automatic {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Chrome.accent : Chrome.secondaryText)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Chrome.glassTint))
                    .overlay(Circle().strokeBorder(Chrome.overlay(0.18), lineWidth: 0.5))
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .help(Text(verbatim: Chrome.localized(choice.title)))
    }
}

/// Font sizes use the same section and card spacing as the other settings.
private struct FontSizeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ChromeSection(
            title: "Font sizes",
            trailing: AnyView(
                Button("Reset font sizes") { settings.resetFontSizes() }
                    .font(.ui(.body))
                    .chromeGlassButtonStyle()
                    .controlSize(.small)
                    .disabled(settings.isDefault)
            )
        ) {
            ChromeCard {
                ChromeRow(title: "Interface font size", detail: "Adjust Tivano's base font size") {
                    FontSizeButtons(value: $settings.uiFontSize, range: TypeScale.uiRange)
                }
                ChromeRowDivider()
                ChromeRow(title: "Content font size", detail: "Adjust the base font size of conversations") {
                    FontSizeButtons(value: $settings.contentFontSize, range: TypeScale.contentRange)
                }
                ChromeRowDivider()
                ChromeRow(title: "Code font size", detail: "Adjust the base font size of code in chat and diff views") {
                    FontSizeButtons(value: $settings.codeFontSize, range: TypeScale.codeRange)
                }
            }
        }
    }
}

private struct FontSizeButtons: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            ChromeIconButton(symbol: "minus", isEnabled: value > range.lowerBound, help: "Decrease Font Size") {
                value = TypeScale.clamp(value - 1, to: range)
            }

            Text(verbatim: "\(value) pt")
                .font(Font.ui(size: 12).monospacedDigit())
                .frame(width: 56)
                .help(Text(verbatim: "\(range.lowerBound)–\(range.upperBound)"))

            ChromeIconButton(symbol: "plus", isEnabled: value < range.upperBound, help: "Increase Font Size") {
                value = TypeScale.clamp(value + 1, to: range)
            }
        }
    }
}

/// Clear glass on the left, a solid base on the right, the stock look in the middle,
/// with a reset that shows only once the slider has left the stock look.
private struct BackdropOpacitySlider: View {
    @Binding var value: Double
    let stock: Double

    private var isOffStock: Bool { abs(value - stock) >= 0.005 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .help(Text(verbatim: Chrome.localized("Transparent")))
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
                .frame(width: 140)
            Image(systemName: "circle.fill")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .help(Text(verbatim: Chrome.localized("Solid")))
        }
        .overlay(alignment: .leading) {
            if isOffStock {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { value = stock }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.ui(.subheadline, weight: .medium))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: Chrome.localized("Back to the stock look")))
                .offset(x: -28)
                .transition(.opacity.combined(with: .offset(x: 6)))
            }
        }
        .animation(.snappy(duration: 0.2), value: isOffStock)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Window transparency"))
    }
}

/// The accent family menu: System Accent and Avocado on top, then the rest in
/// case order, each with a dynamic swatch of its accent.
private struct ThemePickerButton: View {
    @Binding var selection: AppTheme

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                selection.swatch
                    .frame(width: 14, height: 14)
                Text(verbatim: Chrome.localized(selection.displayName))
                    .font(.ui(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                ForEach(AppTheme.allCases) { item($0) }
            }
        }
    }

    private func item(_ theme: AppTheme) -> some View {
        PopoverItem(theme.displayName, leading: AnyView(theme.swatch), isChecked: theme == selection, localizesTitle: true) {
            selection = theme
        }
    }
}
