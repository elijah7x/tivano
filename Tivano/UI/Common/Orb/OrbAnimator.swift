// Ported from Zeron (https://github.com/zeronsh/zeron, MIT), crates/orb and crates/ui/src/orb,
// itself extracted from Bezel (clearloop, MIT), a port of gpui-thinking-orbs (MIT), a port of
// Jakub Antalik's thinking-orbs (MIT). See THIRD_PARTY_NOTICES.md.
//
// Renderer-agnostic orb playback (animator.rs, motion.rs): the continuous clock, audio-driven
// speed and state crossfades. Hosts decide when to tick and paint the frames. Times are
// monotonic seconds (e.g. `ProcessInfo.processInfo.systemUptime`).

import Foundation

/// Reduced motion freezes every orb on this representative frame.
let orbReducedMotionT: Float = 0.6

// MARK: - Clock

/// Continuous animation time. Hidden and paused time never accumulates.
struct OrbAnimationClock: Sendable {
    private(set) var seconds: Double = 0
    private(set) var activeSeconds: Double = 0
    private var last: TimeInterval?
    private var rate: Double = 0
    private var running = false

    mutating func advance(now: TimeInterval, rate: Double, running: Bool) {
        if let last, self.running {
            let dt: Double = Swift.max(now - last, 0)
            seconds += dt * self.rate
            activeSeconds += dt
        }
        self.last = now
        self.rate = rate
        self.running = running
    }

    mutating func stop(now: TimeInterval) {
        advance(now: now, rate: rate, running: false)
    }

    var isRunning: Bool { running }
}

// MARK: - Audio

/// One bounded envelope: fast attack (80 ms), slow release (300 ms).
private struct OrbEnvelope: Sendable {
    var origin: Float = 0
    var target: Float = 0
    var changed: TimeInterval

    init(now: TimeInterval) {
        changed = now
    }

    func value(_ now: TimeInterval) -> Float {
        let tau: Float = target > origin ? 0.080 : 0.300
        let dt = Float(Swift.max(now - changed, 0))
        return target + (origin - target) * exp(-dt / tau)
    }

    mutating func set(_ peak: Float, now: TimeInterval) -> Bool {
        // Ignore quiet background noise; compress peaks without exceeding 1.
        let peak: Float = peak.isFinite ? OrbMath.clamp(peak, 0.0, 1.0) : 0.0
        let x: Float = OrbMath.max((peak - 0.015) / 0.985, 0.0)
        let target: Float = 1.2 * x / (x + 0.2)
        if self.target == target { return false }
        origin = value(now)
        self.target = target
        changed = now
        return true
    }
}

/// Independent microphone and speaker envelopes that quicken the motion.
struct OrbAudioResponse: Sendable {
    private var microphone: OrbEnvelope
    private var speaker: OrbEnvelope

    init(now: TimeInterval) {
        microphone = OrbEnvelope(now: now)
        speaker = OrbEnvelope(now: now)
    }

    mutating func set(microphone: Float, speaker: Float, now: TimeInterval) -> Bool {
        let micChanged = self.microphone.set(microphone, now: now)
        let speakerChanged = self.speaker.set(speaker, now: now)
        return micChanged || speakerChanged
    }

    func speed(_ now: TimeInterval) -> Double {
        let mic: Float = microphone.value(now)
        let spk: Float = speaker.value(now)
        // A bounded, continuous combination, even when both sides overlap.
        let combined: Float = OrbMath.clamp(1.0 - (1.0 - mic) * (1.0 - spk), 0.0, 1.0)
        return 1.0 + Double(combined) * 0.3
    }
}

// MARK: - Crossfade

/// Blend two frames by opacity with a smoothstep weight.
func orbCrossfade(from: OrbFrame, to: OrbFrame, progress: Float, into out: inout OrbFrame) {
    out.clear()
    let p: Float = OrbMath.clamp(progress, 0.0, 1.0)
    let weight: Float = p * p * (3.0 - 2.0 * p)
    let layers: [(OrbFrame, Float)] = [(from, 1.0 - weight), (to, weight)]
    for (frame, opacity) in layers {
        for var dot in frame.dots {
            dot.a *= opacity
            if dot.a >= 0.005 { out.dots.append(dot) }
        }
        for var line in frame.lines {
            line.a *= opacity
            if line.a >= 0.005 { out.lines.append(line) }
        }
    }
}

// MARK: - Animator

/// One orb's animation state. The engine takes continuous, unbounded time (its modes mix
/// incommensurate frequencies, so there is no seamless wrap point) and this owns that clock.
final class OrbAnimator {
    private final class StateTransition {
        var from: OrbFrame
        /// Animate the outgoing form, unless it was itself mid-fade.
        let source: OrbResolved?
        let started: Double

        init(from: OrbFrame, source: OrbResolved?, started: Double) {
            self.from = from
            self.source = source
            self.started = started
        }
    }

    private(set) var state: OrbState
    private(set) var size: OrbSize
    /// Multiplier on top of the preset's baked speed.
    private(set) var speed: Float = 1.0
    /// Crossfade duration for state changes, in seconds (0 = no fade).
    var transitionDuration: TimeInterval
    private var clock = OrbAnimationClock()
    private var audio: OrbAudioResponse?
    private var transition: StateTransition?
    private var resolved: OrbResolved
    private var targetFrame = OrbFrame()
    private var t: Float = 0
    private let engine = OrbEngine()

    /// `transition` crossfades state geometry without restarting the clock.
    init(state: OrbState, size: OrbSize, transition: TimeInterval = 0) {
        self.state = state
        self.size = size
        self.transitionDuration = transition
        self.resolved = OrbResolved(state: state, size: size)
    }

    /// Logical edge length of the preset's artwork.
    var pixels: Float { size.pixels }

    /// Smallest painted dot radius for the current preset.
    var rMin: Float { resolved.opts.rMin ?? 0.3 }

    var isRunning: Bool { clock.isRunning }

    var isTransitioning: Bool { transition != nil }

    /// Change state. `visible` is the frame on screen now: an interrupted fade continues from
    /// its visible composite instead of jumping back.
    @discardableResult
    func setState(_ state: OrbState, visible: OrbFrame) -> Bool {
        if self.state == state { return false }
        let canFade = transitionDuration > 0
            && clock.isRunning
            && (!visible.dots.isEmpty || !visible.lines.isEmpty)
        if canFade {
            let source: OrbResolved? = transition == nil ? resolved : nil
            transition = StateTransition(from: visible, source: source, started: clock.activeSeconds)
        } else {
            transition = nil
        }
        self.state = state
        resolved = OrbResolved(state: state, size: size)
        return true
    }

    @discardableResult
    func setSize(_ size: OrbSize) -> Bool {
        if self.size == size { return false }
        self.size = size
        resolved = OrbResolved(state: state, size: size)
        return true
    }

    @discardableResult
    func setSpeed(_ speed: Float) -> Bool {
        let speed: Float = speed.isFinite ? OrbMath.clamp(speed, 0.0, 100.0) : 1.0
        let changed = self.speed != speed
        self.speed = speed
        return changed
    }

    /// Audio affects only visual motion, with independent microphone and speaker envelopes.
    @discardableResult
    func setAudioLevels(microphone: Float, speaker: Float, now: TimeInterval) -> Bool {
        var response = audio ?? OrbAudioResponse(now: now)
        let changed = response.set(microphone: microphone, speaker: speaker, now: now)
        audio = response
        return changed
    }

    /// Freeze accumulated time (paused, hidden or reduced motion).
    func stop(now: TimeInterval) {
        clock.stop(now: now)
    }

    func cancelTransition() {
        transition = nil
    }

    /// Advance the clock to `now`. Time only accumulates while `animating`.
    func tick(now: TimeInterval, animating: Bool, reduced: Bool) {
        let audioSpeed: Double = audio?.speed(now) ?? 1.0
        let rate: Double = Double(resolved.speed) * Double(speed) * audioSpeed
        clock.advance(now: now, rate: rate, running: animating)
        t = reduced ? orbReducedMotionT : Float(clock.seconds)
        if reduced {
            transition = nil
        }
    }

    /// Geometry at the last tick, in the preset's logical points.
    func draw(into out: inout OrbFrame) {
        var progress: Float = 1.0
        if let transition, transitionDuration > 0 {
            let elapsed: Double = clock.activeSeconds - transition.started
            progress = Float(elapsed / transitionDuration)
        }
        if progress >= 1.0 {
            transition = nil
        }
        let size = self.size.pixels
        guard let transition else {
            // The allocation-free path outside a fade.
            engine.drawResolved(mode: resolved.mode, size: size, t: t, opts: resolved.opts, into: &out)
            return
        }
        engine.drawResolved(mode: resolved.mode, size: size, t: t, opts: resolved.opts, into: &targetFrame)
        if let source = transition.source {
            engine.drawResolved(mode: source.mode, size: size, t: t, opts: source.opts, into: &transition.from)
        }
        orbCrossfade(from: transition.from, to: targetFrame, progress: progress, into: &out)
    }
}
