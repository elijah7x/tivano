// Ported from Zeron (https://github.com/zeronsh/zeron, MIT), crates/orb and crates/ui/src/orb,
// itself extracted from Bezel (clearloop, MIT), a port of gpui-thinking-orbs (MIT), a port of
// Jakub Antalik's thinking-orbs (MIT). See THIRD_PARTY_NOTICES.md.
//
// Density profiles, the multiplier machinery that scales them (engine/profiles.rs) and the
// twelve states × four sizes presets (presets.rs).

import Foundation

/// Hard ceilings for count-like knobs. Preset values sit well below these; they only bite
/// mistaken power-user inputs.
enum OrbLimits {
    static let maxLatticeRings: Float = 128.0
    static let maxLonDensity: Float = 256.0
    static let maxOrbitN: Float = 64.0
    static let maxGhostN: Float = 512.0
    static let maxParticles: Float = 16.0
    static let maxNodeN: Float = 128.0
    static let maxSignals: Float = 64.0
    static let maxStrandN: Float = 256.0
    static let maxLanes: Float = 32.0
    static let maxSegs: Float = 512.0
    static let maxMoveCount: Float = 64.0
    static let maxIconD: Float = 8.0
    /// Max dots the Morph painter emits after `iconD` is applied.
    static let maxMorphDots: Int = 512
    /// Logical size accepted by the sanitizing draw entry point.
    static let minSize: Float = 1.0
    static let maxSize: Float = 1024.0
}

/// Free-form numeric knobs for the mode painters (mirrors upstream `ModeOpts`).
struct OrbModeOpts: Sendable, Equatable {
    // lattice
    var latRings: Float? = nil
    var lonDensity: Float? = nil
    var rings: Float? = nil
    var rBase: Float? = nil
    var rDepth: Float? = nil
    var rBoost: Float? = nil
    var rActive: Float? = nil
    var inkFar: Float? = nil
    var inkSpan: Float? = nil
    var rsPow: Float? = nil
    var rMin: Float? = nil
    var moveCount: Float? = nil
    var scanMul: Float? = nil
    var dimBase: Float? = nil
    // orbits
    var orbitN: Float? = nil
    var ghostN: Float? = nil
    var ghostR: Float? = nil
    var ghostA: Float? = nil
    var particles: Float? = nil
    var partR: Float? = nil
    var partRDepth: Float? = nil
    // web
    var nodeN: Float? = nil
    var thr: Float? = nil
    var signals: Float? = nil
    var nodeR: Float? = nil
    var nodeRDepth: Float? = nil
    var lineW: Float? = nil
    // braid
    var strandN: Float? = nil
    var turns: Float? = nil
    // ribbon / ring
    var lanes: Float? = nil
    var segs: Float? = nil
    var faceOn: Float? = nil
    var spin: Float? = nil
    var bandMul: Float? = nil
    var wobMul: Float? = nil
    // morph
    var rDot: Float? = nil
    var iconD: Float? = nil
    var spread: Float? = nil
    var rSizeMul: Float? = nil
}

enum OrbProfiles {
    /// Clamp a free-form option into a finite range, or leave it nil.
    private static func clampOpt(_ v: Float?, _ lo: Float, _ hi: Float) -> Float? {
        guard let x = v, x.isFinite else { return nil }
        return OrbMath.clamp(x, lo, hi)
    }

    /// A safe copy of `opts` with every count-like / radius-like knob finite and within the
    /// hard ceilings.
    static func sanitize(_ o: OrbModeOpts) -> OrbModeOpts {
        typealias L = OrbLimits
        var s = OrbModeOpts()
        s.latRings = clampOpt(o.latRings, 1.0, L.maxLatticeRings)
        s.lonDensity = clampOpt(o.lonDensity, 1.0, L.maxLonDensity)
        s.rings = clampOpt(o.rings, 1.0, L.maxLatticeRings)
        s.rBase = clampOpt(o.rBase, 0.0, 64.0)
        s.rDepth = clampOpt(o.rDepth, 0.0, 64.0)
        s.rBoost = clampOpt(o.rBoost, 0.0, 64.0)
        s.rActive = clampOpt(o.rActive, 0.0, 64.0)
        s.inkFar = clampOpt(o.inkFar, 0.0, 1.0)
        s.inkSpan = clampOpt(o.inkSpan, 0.0, 2.0)
        s.rsPow = clampOpt(o.rsPow, 0.05, 4.0)
        s.rMin = clampOpt(o.rMin, 0.0, 32.0)
        s.moveCount = clampOpt(o.moveCount, 0.0, L.maxMoveCount)
        s.scanMul = clampOpt(o.scanMul, 0.0, 16.0)
        s.dimBase = clampOpt(o.dimBase, 0.0, 1.0)
        s.orbitN = clampOpt(o.orbitN, 0.0, L.maxOrbitN)
        s.ghostN = clampOpt(o.ghostN, 0.0, L.maxGhostN)
        s.ghostR = clampOpt(o.ghostR, 0.0, 64.0)
        s.ghostA = clampOpt(o.ghostA, 0.0, 1.0)
        s.particles = clampOpt(o.particles, 0.0, L.maxParticles)
        s.partR = clampOpt(o.partR, 0.0, 64.0)
        s.partRDepth = clampOpt(o.partRDepth, 0.0, 64.0)
        s.nodeN = clampOpt(o.nodeN, 0.0, L.maxNodeN)
        s.thr = clampOpt(o.thr, 0.0, 4.0)
        s.signals = clampOpt(o.signals, 0.0, L.maxSignals)
        s.nodeR = clampOpt(o.nodeR, 0.0, 64.0)
        s.nodeRDepth = clampOpt(o.nodeRDepth, 0.0, 64.0)
        s.lineW = clampOpt(o.lineW, 0.0, 32.0)
        s.strandN = clampOpt(o.strandN, 0.0, L.maxStrandN)
        s.turns = clampOpt(o.turns, 0.0, 32.0)
        s.lanes = clampOpt(o.lanes, 1.0, L.maxLanes)
        s.segs = clampOpt(o.segs, 1.0, L.maxSegs)
        s.faceOn = clampOpt(o.faceOn, 0.0, 1.0)
        s.spin = clampOpt(o.spin, -16.0, 16.0)
        s.bandMul = clampOpt(o.bandMul, 0.05, 8.0)
        s.wobMul = clampOpt(o.wobMul, 0.0, 8.0)
        s.rDot = clampOpt(o.rDot, 0.0, 1.0)
        s.iconD = clampOpt(o.iconD, 0.02, L.maxIconD)
        s.spread = clampOpt(o.spread, 0.05, 4.0)
        s.rSizeMul = clampOpt(o.rSizeMul, 0.0, 64.0)
        return s
    }

    /// Clamp the logical paint size.
    static func sanitizeSize(_ size: Float) -> Float {
        size.isFinite ? OrbMath.clamp(size, OrbLimits.minSize, OrbLimits.maxSize) : 64.0
    }

    /// Interpret a count-like option as a count. Missing / non-finite use `fallback`; the
    /// result is always in `lo...hi`.
    @inline(__always)
    static func count(_ v: Float?, _ fallback: Float, _ lo: Int, _ hi: Int) -> Int {
        var x: Float = fallback
        if let v, v.isFinite { x = v }
        let clamped: Float = OrbMath.clamp(x.rounded(), Float(lo), Float(hi))
        return OrbMath.toCount(clamped)
    }

    /// Scale total dot density. 2-D lattices (rings × dots-per-ring) take √scale each side
    /// so the TOTAL scales by `scale`. Flat lists scale linearly.
    static func scaleCounts(_ opts: OrbModeOpts, _ scale: Float) -> OrbModeOpts {
        typealias L = OrbLimits
        var out = opts
        let scale: Float = (scale.isFinite && scale > 0.0) ? scale : 1.0
        let rt: Float = scale.squareRoot()

        // Upstream COUNT_PAIRS: latRings × lonDensity first (owns lonDensity), then
        // rings × lonDensity only if latRings was absent.
        if let va = out.latRings, let vb = out.lonDensity {
            out.latRings = OrbMath.clamp((va * rt).rounded(), 2.0, L.maxLatticeRings)
            out.lonDensity = OrbMath.clamp((vb * rt).rounded(), 2.0, L.maxLonDensity)
        } else if let va = out.rings, let vb = out.lonDensity {
            out.rings = OrbMath.clamp((va * rt).rounded(), 2.0, L.maxLatticeRings)
            out.lonDensity = OrbMath.clamp((vb * rt).rounded(), 2.0, L.maxLonDensity)
        }
        // lanes × segs pair
        if let va = out.lanes, let vb = out.segs {
            out.lanes = OrbMath.clamp((va * rt).rounded(), 2.0, L.maxLanes)
            out.segs = OrbMath.clamp((vb * rt).rounded(), 2.0, L.maxSegs)
        }

        // Linear count keys (0 means opt-out, do not resurrect).
        func scaleKey(_ v: Float?, _ hi: Float) -> Float? {
            guard let v else { return nil }
            if v == 0.0 { return 0.0 }
            guard v.isFinite else { return nil }
            return OrbMath.clamp((v * scale).rounded(), 1.0, hi)
        }
        out.orbitN = scaleKey(out.orbitN, L.maxOrbitN)
        out.ghostN = scaleKey(out.ghostN, L.maxGhostN)
        out.nodeN = scaleKey(out.nodeN, L.maxNodeN)
        out.strandN = scaleKey(out.strandN, L.maxStrandN)
        out.signals = scaleKey(out.signals, L.maxSignals)

        if let v = out.iconD {
            out.iconD = v.isFinite ? OrbMath.clamp(v * scale, 0.02, L.maxIconD) : nil
        }
        return out
    }

    /// Scale every key that sets a dot's rendered radius.
    static func scaleRadii(_ opts: OrbModeOpts, _ scale: Float) -> OrbModeOpts {
        var out = opts
        let scale: Float = scale.isFinite ? scale : 1.0
        func mul(_ v: Float?) -> Float? {
            guard let x = v, x.isFinite else { return nil }
            return x * scale
        }
        out.rBase = mul(out.rBase)
        out.rDepth = mul(out.rDepth)
        out.rActive = mul(out.rActive)
        out.rDot = mul(out.rDot)
        out.ghostR = mul(out.ghostR)
        out.partR = mul(out.partR)
        out.partRDepth = mul(out.partRDepth)
        out.nodeR = mul(out.nodeR)
        out.nodeRDepth = mul(out.nodeRDepth)
        out.rSizeMul = (out.rSizeMul ?? 1.0) * scale
        return out
    }

    /// Base (fine) profiles per mode, before preset multipliers.
    static func base(_ mode: OrbModeKey) -> OrbModeOpts {
        var o = OrbModeOpts()
        switch mode {
        case .globe:
            o.latRings = 17.0
            o.lonDensity = 44.0
            o.rBase = 0.6
            o.rDepth = 1.7
            o.rBoost = 1.0
            o.inkFar = 0.62
            o.inkSpan = 0.54
            o.rsPow = 0.6
            o.rMin = 0.3
        case .orbits:
            o.orbitN = 12.0
            o.ghostN = 40.0
            o.ghostR = 0.9
            o.ghostA = 0.5
            o.particles = 3.0
            o.partR = 1.2
            o.partRDepth = 1.6
            o.rsPow = 0.6
            o.rMin = 0.3
        case .rubik:
            o.latRings = 15.0
            o.lonDensity = 40.0
            o.moveCount = 14.0
            o.rBase = 0.6
            o.rDepth = 1.7
            o.rActive = 0.3
            o.inkFar = 0.62
            o.inkSpan = 0.54
            o.rsPow = 0.6
            o.rMin = 0.3
        case .wave:
            o.rings = 15.0
            o.lonDensity = 40.0
            o.rBase = 0.6
            o.rDepth = 1.7
            o.rsPow = 0.6
            o.rMin = 0.3
        case .web:
            o.nodeN = 30.0
            o.thr = 0.72
            o.signals = 5.0
            o.nodeR = 1.4
            o.nodeRDepth = 1.8
            o.lineW = 0.8
            o.rsPow = 0.6
            o.rMin = 0.3
        case .braid:
            o.strandN = 52.0
            o.turns = 3.0
            o.ghostN = 150.0
            o.rBase = 1.2
            o.rDepth = 1.8
            o.rsPow = 0.6
            o.rMin = 0.3
        case .ribbon:
            o.lanes = 5.0
            o.segs = 88.0
            o.ghostN = 150.0
            o.rBase = 1.1
            o.rDepth = 1.7
            o.rsPow = 0.6
            o.rMin = 0.3
        case .ring:
            o.lanes = 5.0
            o.segs = 88.0
            o.ghostN = 0.0
            o.faceOn = 1.0
            o.rBase = 1.1
            o.rDepth = 1.7
            o.rsPow = 0.6
            o.rMin = 0.3
        case .morph:
            o.rDot = 0.021
            o.iconD = 1.0
            o.rMin = 0.25
        case .focus:
            o.lanes = 6.0
            o.segs = 12.0
            o.particles = 5.0
            o.rBase = 0.9
            o.rDepth = 1.25
            o.rsPow = 0.6
            o.rMin = 0.3
        case .gyroscope:
            o.lanes = 3.0
            o.segs = 28.0
            o.rBase = 0.8
            o.rDepth = 1.5
            o.rsPow = 0.6
            o.rMin = 0.3
        case .echo:
            o.lanes = 4.0
            o.segs = 18.0
            o.particles = 3.0
            o.rBase = 0.85
            o.rDepth = 1.05
            o.rsPow = 0.6
            o.rMin = 0.3
        }
        return o
    }
}

// MARK: - Presets

/// Fully resolved draw options for a (state, size) pair.
struct OrbResolved: Sendable, Equatable {
    var mode: OrbModeKey
    var speed: Float
    var opts: OrbModeOpts

    /// Resolve a (state, size) pair to its mode + fully scaled draw options.
    init(state: OrbState, size: OrbSize) {
        let mode = OrbModeKey(state: state)
        let preset = OrbPreset.preset(mode, size)
        var opts = OrbProfiles.base(mode)
        if abs(preset.count - 1.0) > Float.ulpOfOne {
            opts = OrbProfiles.scaleCounts(opts, preset.count)
        }
        if abs(preset.size - 1.0) > Float.ulpOfOne {
            opts = OrbProfiles.scaleRadii(opts, preset.size)
        }
        if let v = preset.scanMul { opts.scanMul = v }
        if let v = preset.dimBase { opts.dimBase = v }
        if let v = preset.spin { opts.spin = v }
        if let v = preset.bandMul { opts.bandMul = v }
        if let v = preset.wobMul { opts.wobMul = v }
        if let v = preset.spread { opts.spread = v }
        self.mode = mode
        self.speed = preset.speed
        self.opts = opts
    }
}

private struct OrbPreset {
    var speed: Float
    var count: Float
    var size: Float
    // Extra knobs merged after scaling.
    var scanMul: Float? = nil
    var dimBase: Float? = nil
    var spin: Float? = nil
    var bandMul: Float? = nil
    var wobMul: Float? = nil
    var spread: Float? = nil

    static func preset(_ mode: OrbModeKey, _ size: OrbSize) -> OrbPreset {
        // The large designs preserve each avatar preset's character while adding detail
        // gradually; `scaleCounts` understands each painter's topology, so this is
        // deliberately not a naive coordinate scale.
        switch size {
        case .large, .hero:
            var preset = OrbPreset.preset(mode, .avatar)
            let count: Float = size == .large ? 1.15 : 1.30
            let radius: Float = size == .large ? 1.05 : 1.10
            let speed: Float = size == .large ? 0.95 : 0.90
            preset.count *= count
            preset.size *= radius
            preset.speed *= speed
            return preset
        case .avatar, .inline:
            break
        }
        let avatar = size == .avatar
        switch mode {
        case .orbits:
            return avatar
                ? OrbPreset(speed: 1.885, count: 1.0, size: 1.0)
                : OrbPreset(speed: 3.9, count: 0.238, size: 2.4)
        case .globe:
            return avatar
                ? OrbPreset(speed: 2.015, count: 0.42, size: 1.15, scanMul: 4.08, dimBase: 0.45)
                : OrbPreset(speed: 2.665, count: 0.105, size: 1.75, scanMul: 4.335, dimBase: 0.45)
        case .rubik:
            return avatar
                ? OrbPreset(speed: 1.82, count: 0.35, size: 1.05)
                : OrbPreset(speed: 1.95, count: 0.088, size: 1.9)
        case .wave:
            return avatar
                ? OrbPreset(speed: 3.15, count: 0.341, size: 1.0)
                : OrbPreset(speed: 3.35, count: 0.105, size: 1.6)
        case .web:
            return avatar
                ? OrbPreset(speed: 3.315, count: 1.35, size: 0.95)
                : OrbPreset(speed: 6.63, count: 0.25, size: 1.52)
        case .braid:
            return avatar
                ? OrbPreset(speed: 1.625, count: 0.5, size: 1.0)
                : OrbPreset(speed: 2.75, count: 0.1125, size: 1.36)
        case .ribbon:
            return avatar
                ? OrbPreset(speed: 1.95, count: 0.25, size: 0.85, spin: 0.0, bandMul: 2.9, wobMul: 1.0)
                : OrbPreset(speed: 2.5, count: 0.051, size: 1.073, spin: 0.0, bandMul: 3.6, wobMul: 1.0)
        case .ring:
            return avatar
                ? OrbPreset(speed: 1.55, count: 0.25, size: 0.956, spin: 0.0, bandMul: 2.8, wobMul: 0.368)
                : OrbPreset(speed: 2.1, count: 0.028, size: 1.622, spin: 0.0, bandMul: 3.2, wobMul: 0.565)
        case .morph:
            return avatar
                ? OrbPreset(speed: 2.405, count: 0.702, size: 0.395, spread: 1.45)
                : OrbPreset(speed: 2.08, count: 0.53, size: 1.011, spread: 1.45)
        case .focus:
            return avatar
                ? OrbPreset(speed: 1.72, count: 1.0, size: 1.0, spread: 1.0)
                : OrbPreset(speed: 2.2, count: 0.22, size: 1.45, spread: 1.0)
        case .gyroscope:
            return avatar
                ? OrbPreset(speed: 1.48, count: 1.0, size: 1.0, spread: 1.0)
                : OrbPreset(speed: 2.05, count: 0.25, size: 1.55, spread: 1.0)
        case .echo:
            return avatar
                ? OrbPreset(speed: 1.85, count: 1.0, size: 1.0, spread: 1.0)
                : OrbPreset(speed: 2.45, count: 0.25, size: 1.55, spread: 1.0)
        }
    }
}
