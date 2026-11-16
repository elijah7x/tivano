import AppKit
import SwiftUI

/// Every accent color Tivano offers: System Accent, Avocado (Tivano's own green
/// from the app icon), and ten named color accents across greens, blues, purple,
/// pinks, reds and yellow.
///
/// Each custom accent pairs a dark-appearance hex with a light-appearance hex,
/// resolved dynamically for the current appearance while keeping case raw values
/// stable for persisted settings. The app stays Liquid Glass throughout, with a
/// dynamic glass tint and system status hues; the Creation style swaps glass for
/// solid surfaces.
enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case breeze
    case everforest
    case matrix
    case nord
    case github
    case nightOwl
    case catppuccin
    case rosePine
    case monokai
    case claude
    case ayu

    /// The accent family Creation selects each time the style is entered.
    static let creationDefault: AppTheme = .claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System Accent"
        case .breeze: "Avocado"
        case .everforest: "Matcha Green"
        case .matrix: "Emerald Green"
        case .nord: "Glacier Blue"
        case .github: "Sea Blue"
        case .nightOwl: "Sky Blue"
        case .catppuccin: "Lavender Purple"
        case .rosePine: "Rose Pink"
        case .monokai: "Raspberry Red"
        case .claude: "Coral Red"
        case .ayu: "Honey Yellow"
        }
    }

    /// Dark and light hexes for the family's accent, or nil to keep the system control accent.
    private var accentHexes: (dark: String, light: String)? {
        switch self {
        case .system: nil
        // The app icon's own green (mean of its background, sampled from the 1024 px master),
        // used as-is on dark and light grounds alike.
        case .breeze: ("7BA58F", "7BA58F")
        case .everforest: ("A7C080", "8DA101")
        case .matrix: ("00E676", "00A152")
        case .nord: ("88C0D0", "5E81AC")
        case .github: ("4493F8", "0969DA")
        case .nightOwl: ("82AAFF", "4876D6")
        case .catppuccin: ("CBA6F7", "8839EF")
        case .rosePine: ("EB6F92", "B4637A")
        case .monokai: ("F92672", "D3175F")
        case .claude: ("CE7E64", "B5654A")
        case .ayu: ("E6B450", "C98A12")
        }
    }

    /// The picker's badge: a plain circle filled with the theme's dynamic accent
    /// (or the system control accent for System Accent), with a hairline rim.
    @ViewBuilder
    var swatch: some View {
        Circle()
            .fill(spec.accent ?? Color.accentColor)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
    }

    /// A color that reads `dark` in a dark appearance and `light` in a light one, picked
    /// each time it is drawn so a Mac that flips appearance recolors it without a rebuild.
    private static func dynamicColor(dark: String, light: String) -> Color {
        func srgb(_ hex: String) -> NSColor {
            let value = UInt64(hex, radix: 16) ?? 0
            return NSColor(
                srgbRed: Double((value >> 16) & 0xFF) / 255.0,
                green: Double((value >> 8) & 0xFF) / 255.0,
                blue: Double(value & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        let darkColor = srgb(dark)
        if dark == light { return Color(nsColor: darkColor) }
        let lightColor = srgb(light)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }))
    }

    private static let surfaceColor = dynamicColor(dark: "1E1E20", light: "FFFFFF")

    private static let cachedSpecs: [AppTheme: ThemeSpec] = {
        var specs: [AppTheme: ThemeSpec] = [:]
        specs.reserveCapacity(allCases.count)
        for theme in allCases {
            specs[theme] = ThemeSpec(
                accent: theme.accentHexes.map { dynamicColor(dark: $0.dark, light: $0.light) },
                surface: surfaceColor,
                success: .green,
                warning: .orange,
                danger: .red
            )
        }
        return specs
    }()

    private static let cachedCreationSpecs: [AppTheme: ThemeSpec] = {
        let surface = Color(hex: "FEFEFD")
        let success = Color(hex: "5C8A5B")
        let warning = Color(hex: "B5862F")
        let danger = Color(hex: "B4473A")
        var specs: [AppTheme: ThemeSpec] = [:]
        specs.reserveCapacity(allCases.count)
        for theme in allCases {
            specs[theme] = ThemeSpec(
                scheme: .light,
                accent: theme.spec.accent,
                surface: surface,
                success: success,
                warning: warning,
                danger: danger,
                solid: .creation,
                serif: true,
                handDrawnIcons: true
            )
        }
        return specs
    }()

    var spec: ThemeSpec {
        Self.cachedSpecs[self]!
    }

    var creationSpec: ThemeSpec {
        Self.cachedCreationSpecs[self]!
    }

    /// Maps current and legacy theme raw values onto the merged accent families.
    static func migrated(fromLegacy raw: String) -> AppTheme? {
        if let current = AppTheme(rawValue: raw) { return current }
        switch raw {
        case "breezeLight", "breezeDark": return .breeze
        case "light", "dark": return .system
        case "catppuccinMocha", "catppuccinLatte", "dracula", "codex": return .catppuccin
        case "tokyoNight", "kanagawa": return .nightOwl
        case "cursor": return .nord
        case "oneDark", "githubDark", "githubLight", "solarized", "solarizedDark", "solarizedLight": return .github
        case "claudeLight", "gruvbox", "gruvboxLight": return .claude
        case "creation": return .claude
        default: return nil
        }
    }

    /// Returns the fixed appearance a legacy theme value used to imply, or nil when it
    /// followed the system or is unknown.
    static func legacyScheme(ofRaw raw: String) -> ColorScheme? {
        switch raw {
        case "breezeLight", "light", "catppuccinLatte", "gruvboxLight", "solarizedLight", "githubLight", "claudeLight":
            return .light
        case "breeze", "system":
            return nil
        case "breezeDark", "dark", "catppuccinMocha", "dracula", "tokyoNight", "nord",
             "gruvbox", "oneDark", "everforest", "kanagawa", "rosePine",
             "solarizedDark", "githubDark", "ayu", "nightOwl", "monokai",
             "claude", "codex", "cursor", "matrix":
            return .dark
        default:
            return nil
        }
    }
}

/// The opaque grounds of a solid theme, from the window down to a hairline, and the inks
/// written on them. Only Creation has them; every other theme stays glass.
struct SolidSurfaces: Equatable, Sendable {
    /// The conversation's page.
    var canvas: Color
    var sidebar: Color
    /// The composer, popovers and floating panels: a shade brighter than the page.
    var elevated: Color
    /// Cards, code blocks and folded tool groups.
    var card: Color
    var userBubble: Color
    /// The selected sidebar row.
    var selection: Color
    var hairline: Color
    var hairlineStrong: Color
    var ink: Color
    var body: Color
    var muted: Color
    var faint: Color

    /// Near-white with only a trace of warmth, cleaner than Claude's page; never parchment.
    static let creation = SolidSurfaces(
        canvas: Color(hex: "FEFEFD"),
        sidebar: Color(hex: "F8F8F6"),
        elevated: Color(hex: "FFFFFF"),
        card: Color(hex: "F9F9F7"),
        userBubble: Color(hex: "F5F5F2"),
        selection: Color(hex: "EFEEEA"),
        hairline: Color(hex: "EAE8E4"),
        hairlineStrong: Color(hex: "D6D3CD"),
        ink: Color(hex: "24221E"),
        body: Color(hex: "36332E"),
        muted: Color(hex: "6E685F"),
        faint: Color(hex: "A49D93")
    )

    /// The soft lift of a floating solid surface, standing in for the glass's own depth.
    static let shadow = Color(red: 0.11, green: 0.10, blue: 0.09).opacity(0.05)

    private static let paperCanvas = Color(hex: "F1F0EC")
    private static let paperSidebar = Color(hex: "EAE8E3")

    /// Applies the 0…1 transparency slider around its 0.5 midpoint: down to 80% opacity on the
    /// clear side, and mixed toward a soft paper grey on the solid side.
    func adjusted(backdrop t: Double) -> SolidSurfaces {
        let clamped = min(max(t, 0), 1)
        if clamped == 0.5 { return self }
        var adjusted = self
        if clamped < 0.5 {
            let opacity = 0.80 + 0.20 * (clamped / 0.5)
            adjusted.canvas = canvas.opacity(opacity)
            adjusted.sidebar = sidebar.opacity(opacity)
        } else {
            let amount = (clamped - 0.5) / 0.5
            adjusted.canvas = canvas.mix(with: Self.paperCanvas, by: amount)
            adjusted.sidebar = sidebar.mix(with: Self.paperSidebar, by: amount)
        }
        return adjusted
    }
}

extension EnvironmentValues {
    /// The solid theme's surfaces, or nil for the glass themes. Set at every hosted root
    /// so a theme change re-renders the surfaces that read it.
    @Entry var solidSurfaces: SolidSurfaces? = nil
}

/// What an accent family or solid theme paints: an optional fixed color scheme, an optional
/// dynamic accent (nil keeps the system control accent), the glass tint, and status hues.
struct ThemeSpec: Sendable {
    var scheme: ColorScheme? = nil
    var accent: Color?
    var surface: Color
    var success: Color
    var warning: Color
    var danger: Color
    /// Opaque surfaces instead of Liquid Glass; nil for the glass themes.
    var solid: SolidSurfaces? = nil
    /// New York for Latin and Songti SC for Chinese in interface and chat text; code stays mono.
    var serif = false
    /// The hand-drawn template icons in place of SF Symbols where a drawing exists.
    var handDrawnIcons = false

    var isSolid: Bool { solid != nil }
}

/// The theme every static `Chrome` color reads. Mirrored from
/// `AppSettings.theme` and `AppSettings.themeStyle`, which are the source of truth; views
/// re-render through the settings they already observe, so the static read is always
/// fresh on the main thread.
enum ThemeManager {
    /// Posted after the theme changes, for layer-backed views whose colours are set once
    /// rather than resolved on every draw (the spinners' cells), so they follow the theme
    /// even when nothing re-renders them.
    static let didChange = Notification.Name("ThemeManager.didChange")

    nonisolated(unsafe) static var current: AppTheme = .breeze {
        didSet {
            spec = style == .create ? current.creationSpec : current.spec
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    nonisolated(unsafe) static var style: ThemeStyle = .liquidGlass {
        didSet {
            spec = style == .create ? current.creationSpec : current.spec
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// The current theme's colors, built once per theme or style change. `Chrome.accent` and
    /// friends are read in hundreds of view bodies per frame, and building a spec parses hex
    /// colors, so the parse happens here rather than on every read.
    nonisolated(unsafe) private(set) static var spec: ThemeSpec = AppTheme.breeze.spec
}

extension Color {
    /// `"CBA6F7"` or `"#CBA6F7"` in sRGB.
    init(hex: String) {
        var digits = hex.trimmed[...]
        if digits.hasPrefix("#") {
            digits = digits.dropFirst()
        } else if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
        }
        let value = UInt32(digits, radix: 16) ?? 0
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
