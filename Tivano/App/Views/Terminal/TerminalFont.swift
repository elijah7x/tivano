import AppKit
import CoreText

/// The font the embedded terminal draws with: the running terminal's configured font,
/// so a Starship prompt's Nerd Font glyphs render instead of landing as empty boxes.
@MainActor
enum TerminalFont {
    /// The configured terminal font that carries the icons, or the closest thing to it.
    static func preferred(fallbackSize: CGFloat = 12) -> NSFont {
        let configured = configuredFonts()
        for font in configured where hasNerdGlyphs(font) {
            if let sibling = nerdSibling(of: font) { return sibling }
            if isTerminalFont(font) { return font }
        }
        if let first = configured.first {
            return nerdSibling(of: first) ?? firstInstalledNerdFont(size: first.pointSize)
                ?? (isTerminalFont(first) ? first : NSFont.monospacedSystemFont(ofSize: first.pointSize, weight: .regular))
        }
        return firstInstalledNerdFont(size: fallbackSize)
            ?? NSFont.monospacedSystemFont(ofSize: fallbackSize, weight: .regular)
    }

    /// Each terminal's configured font, the running terminals first so the one in front of
    /// the user is the one matched.
    private static func configuredFonts() -> [NSFont] {
        let readers: [(bundleID: String, font: () -> NSFont?)] = [
            ("com.mitchellh.ghostty", ghosttyFont),
            ("com.googlecode.iterm2", iTermFont),
            ("com.apple.Terminal", terminalFont),
        ]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return (readers.filter { running.contains($0.bundleID) } + readers.filter { !running.contains($0.bundleID) })
            .compactMap { $0.font() }
    }

    // MARK: - Terminals

    /// Ghostty's `font-family` and `font-size`, from its Application Support or XDG config.
    private static func ghosttyFont() -> NSFont? {
        for url in ghosttyConfigURLs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var name: String?
            var size: CGFloat = 12
            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { continue }
                let key = line[..<equal].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "font-family" where name == nil:
                    // A family list is allowed; the first name is the primary one.
                    let first = value.split(separator: ",").first.map(String.init) ?? value
                    name = first.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                case "font-size":
                    if let points = Double(value), points > 0 { size = CGFloat(points) }
                default:
                    break
                }
            }
            if let name, !name.isEmpty, let font = resolve(name, size: size) { return font }
        }
        return nil
    }

    private static var ghosttyConfigURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Application Support/com.mitchellh.ghostty/config", directoryHint: .notDirectory),
            home.appending(path: ".config/ghostty/config", directoryHint: .notDirectory),
        ]
    }

    /// The default profile's `Font`, an archived `NSFont`.
    private static func terminalFont() -> NSFont? {
        let defaults = UserDefaults(suiteName: "com.apple.Terminal")
        let profile = defaults?.string(forKey: "Default Window Settings") ?? "Basic"
        guard let settings = defaults?.dictionary(forKey: "Window Settings") as? [String: Any],
              let entry = settings[profile] as? [String: Any],
              let data = entry["Font"] as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data)
    }

    /// A profile's `Normal Font`, written as the font's PostScript name and its size.
    private static func iTermFont() -> NSFont? {
        guard let bookmarks = UserDefaults(suiteName: "com.googlecode.iterm2")?.array(forKey: "New Bookmarks") as? [[String: Any]] else {
            return nil
        }
        for bookmark in bookmarks {
            guard let entry = bookmark["Normal Font"] as? String else { continue }
            let parts = entry.split(separator: " ")
            guard let last = parts.last, let size = Double(last) else { continue }
            if let font = NSFont(name: parts.dropLast().joined(separator: " "), size: CGFloat(size)) { return font }
        }
        return nil
    }

    // MARK: - Glyphs

    /// The icons a Nerd Font prompt leans on: a powerline cap, two Font Awesome marks and
    /// a Material one from the supplementary plane.
    private static let nerdProbes: [UnicodeScalar] = [UInt32(0xE0B0), UInt32(0xE0B6), UInt32(0xF015), UInt32(0xF0035)].compactMap(UnicodeScalar.init)

    private static func hasNerdGlyphs(_ font: NSFont) -> Bool {
        let covered = font.coveredCharacterSet
        return nerdProbes.allSatisfy { covered.contains($0) }
    }

    // SwiftTerm 1.20.0, AppleTerminalView.computeFontDimensions, uses the named W
    // glyph's advance for every cell. Check ASCII against that same metric; icon
    // coverage or a font's fixed-pitch flag alone does not establish compatibility.
    private static func isTerminalFont(_ font: NSFont) -> Bool {
        guard !normalized(font.familyName ?? font.fontName).hasSuffix("nfp") else { return false }
        let reference = font.glyph(withName: "W")
        let width = font.advancement(forGlyph: reference).width
        guard reference != 0, width.isFinite, width > 0 else { return false }
        let tolerance = max(0.01, width * 0.001)
        return (32..<127).allSatisfy { code in
            var character = UniChar(code)
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { return false }
            let advance = font.advancement(forGlyph: NSGlyph(glyph)).width
            return advance.isFinite && abs(advance - width) <= tolerance
        }
    }

    /// Prefer the Mono sibling, whose patched icons fit a single terminal cell.
    private static func nerdSibling(of font: NSFont) -> NSFont? {
        guard let family = font.familyName else { return nil }
        var base = normalized(family)
        for suffix in ["nfm", "nfp", "nf"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
            break
        }
        for suffix in ["nfm", "nf"] {
            if let family = NSFontManager.shared.availableFontFamilies.first(where: { normalized($0) == base + suffix }),
               let candidate = NSFont(name: family, size: font.pointSize),
               isTerminalFont(candidate), hasNerdGlyphs(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func firstInstalledNerdFont(size: CGFloat) -> NSFont? {
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        for suffix in ["nfm", "nf"] {
            for family in families where normalized(family).hasSuffix(suffix) {
                if let font = NSFont(name: family, size: size), isTerminalFont(font), hasNerdGlyphs(font) {
                    return font
                }
            }
        }
        return nil
    }

    /// A font by the name a terminal config uses, tolerating the abbreviations terminals
    /// allow: "Geist Mono NF" is installed as "GeistMono Nerd Font".
    private static func resolve(_ name: String, size: CGFloat) -> NSFont? {
        if let font = NSFont(name: name, size: size) { return font }
        let target = normalized(name)
        guard let family = NSFontManager.shared.availableFontFamilies.first(where: { normalized($0) == target }) else {
            return nil
        }
        return NSFont(name: family, size: size)
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "nerdfontmono", with: "nfm")
            .replacingOccurrences(of: "nerdfontpropo", with: "nfp")
            .replacingOccurrences(of: "nerdfont", with: "nf")
    }
}
