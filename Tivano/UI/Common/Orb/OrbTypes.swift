// Ported from Zeron (https://github.com/zeronsh/zeron, MIT), crates/orb and crates/ui/src/orb,
// itself extracted from Bezel (clearloop, MIT), a port of gpui-thinking-orbs (MIT), a port of
// Jakub Antalik's thinking-orbs (MIT). See THIRD_PARTY_NOTICES.md.
//
// Public types shared by the animation engine and the SwiftUI view: twelve hand-tuned states,
// four size presets, the ink theme and the internal mode keys (one painter per key).

import Foundation

/// The twelve shipped states, each a hand-tuned animation.
enum OrbState: CaseIterable, Hashable, Sendable {
    /// Particles on tilted orbits.
    case working
    /// A scan meridian sweeps a dotted globe.
    case searching
    /// Bands scramble in quarter turns, then click back.
    case solving
    /// A waveform rolls through latitude rings.
    case listening
    /// A constellation wires itself, packets running the edges.
    case connecting
    /// Three strands plait around the sphere.
    case weaving
    /// An undulating multi-band sash.
    case composing
    /// A face-on ring slowly morphing.
    case breathing
    /// A dotted outline morphs circle → triangle → square.
    case shaping
    /// An iris of particles converges and relaxes around a focal point.
    case focusing
    /// Counter-rotating great circles form a reasoning gyroscope.
    case reasoning
    /// Concentric memory echoes travel out from a steady core.
    case recalling

    /// Human-readable status label (matches upstream aria defaults).
    var label: String {
        switch self {
        case .working: "Working…"
        case .searching: "Searching…"
        case .solving: "Solving…"
        case .listening: "Listening…"
        case .connecting: "Connecting…"
        case .weaving: "Weaving…"
        case .composing: "Composing…"
        case .breathing: "Thinking…"
        case .shaping: "Shaping…"
        case .focusing: "Focusing…"
        case .reasoning: "Reasoning…"
        case .recalling: "Recalling…"
        }
    }

    /// Stable snake_case name (matches the web package `state` prop).
    var id: String {
        switch self {
        case .working: "working"
        case .searching: "searching"
        case .solving: "solving"
        case .listening: "listening"
        case .connecting: "connecting"
        case .weaving: "weaving"
        case .composing: "composing"
        case .breathing: "breathing"
        case .shaping: "shaping"
        case .focusing: "focusing"
        case .reasoning: "reasoning"
        case .recalling: "recalling"
        }
    }
}

/// Rendered size in logical points: inline (20), avatar (64), large (96) and hero (128).
/// Larger sizes add detail gradually instead of merely stretching the 64 pt artwork.
enum OrbSize: CaseIterable, Hashable, Sendable {
    /// Inline-text scale (20 pt).
    case inline
    /// Chat-avatar scale (64 pt).
    case avatar
    /// Prominent status / card scale (96 pt).
    case large
    /// Hero / empty-state scale (128 pt).
    case hero

    /// Logical edge length of the orb.
    var pixels: Float {
        switch self {
        case .inline: 20.0
        case .avatar: 64.0
        case .large: 96.0
        case .hero: 128.0
        }
    }

    /// Stable lowercase name.
    var id: String {
        switch self {
        case .inline: "inline"
        case .avatar: "avatar"
        case .large: "large"
        case .hero: "hero"
        }
    }

    /// Compact playground label.
    var label: String {
        switch self {
        case .inline: "20 · inline"
        case .avatar: "64 · avatar"
        case .large: "96 · large"
        case .hero: "128 · hero"
        }
    }
}

/// Theme mode for monochrome ink on a transparent canvas.
enum OrbTheme: Hashable, Sendable {
    /// Resolve from the appearance.
    case auto
    /// Light ink for dark backgrounds.
    case dark
    /// Dark ink for light backgrounds.
    case light
}

/// Internal mode keys, one painter per key.
enum OrbModeKey: Hashable, Sendable {
    case orbits, globe, rubik, wave, web, braid, ribbon, ring, morph, focus, gyroscope, echo

    init(state: OrbState) {
        switch state {
        case .working: self = .orbits
        case .searching: self = .globe
        case .solving: self = .rubik
        case .listening: self = .wave
        case .connecting: self = .web
        case .weaving: self = .braid
        case .composing: self = .ribbon
        case .breathing: self = .ring
        case .shaping: self = .morph
        case .focusing: self = .focus
        case .reasoning: self = .gyroscope
        case .recalling: self = .echo
        }
    }
}
