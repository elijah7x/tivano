// Ported from Zeron (https://github.com/zeronsh/zeron, MIT), crates/orb and crates/ui/src/orb,
// itself extracted from Bezel (clearloop, MIT), a port of gpui-thinking-orbs (MIT), a port of
// Jakub Antalik's thinking-orbs (MIT). See THIRD_PARTY_NOTICES.md.
//
// The thinking orb as a SwiftUI view (crates/ui/src/orb/orb.rs + paint.rs). The animator runs
// the geometry, clock, audio response and state crossfades; this view only paints the frames:
// lines first, then disks back to front, in monochrome ink on a transparent canvas.
//
// Redraws at 30 fps while on screen and not paused; hidden or paused, its clock stops so
// motion resumes where it left off. Reduce Motion shows the static representative frame.

import SwiftUI

struct ThinkingOrb: View {
    var state: OrbState
    var size: OrbSize
    /// Uniform magnification of the size preset's painted geometry.
    var scale: CGFloat = 1
    /// Normalized 0…1 peaks; they quicken the motion, never the geometry.
    var microphone: Float = 0
    var speaker: Float = 0
    /// State crossfade duration in seconds.
    var transition: TimeInterval = 0.3
    /// Freeze on the static representative frame (the system setting forces the same).
    var reducedMotion: Bool = false
    /// Freeze the accumulated animation time.
    var paused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var player = ThinkingOrbPlayer()
    @State private var isOnScreen = false

    /// Below this the paint path skips a primitive.
    nonisolated private static let minAlpha: Float = 0.02
    /// The orb is a status indicator: at 30 fps its slow motion reads the same as 60.
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    private var reduced: Bool { reducedMotion || systemReduceMotion || performanceMode }
    private var animating: Bool { isOnScreen && !paused && !reduced }

    private var magnification: CGFloat {
        scale.isFinite ? Swift.min(Swift.max(scale, 0.25), 8.0) : 1.0
    }

    var body: some View {
        let edge = CGFloat(size.pixels) * magnification
        let isAnimating = animating
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !isAnimating)) { timeline in
            orbCanvas(date: timeline.date, animating: isAnimating)
        }
        .frame(width: edge, height: edge)
        .accessibilityHidden(true)
        .onAppear { isOnScreen = true }
        .onDisappear {
            isOnScreen = false
            player.hide()
        }
        .onChange(of: paused) { _, nowPaused in
            if nowPaused { player.stop() }
        }
        .onChange(of: reduced) { _, nowReduced in
            if nowReduced { player.hide() }
        }
    }

    private func orbCanvas(date: Date, animating: Bool) -> some View {
        let input = ThinkingOrbPlayer.Input(
            state: state,
            size: size,
            transition: transition,
            microphone: microphone,
            speaker: speaker,
            animating: animating,
            reduced: reduced
        )
        let dark = colorScheme == .dark
        let scale = Float(magnification)
        let player = player
        return Canvas { context, _ in
            // The timeline date only marks this render as a new frame; the animator keeps
            // its own monotonic clock.
            _ = date
            let (frame, rMin) = player.advance(input)
            Self.paint(frame, rMin: rMin, dark: dark, scale: scale, in: &context)
        }
    }

    /// Lines first, then dots back to front (the engine already emits them in that order).
    nonisolated private static func paint(
        _ frame: OrbFrame, rMin: Float, dark: Bool, scale: Float, in context: inout GraphicsContext
    ) {
        for line in frame.lines where line.a >= minAlpha {
            var path = Path()
            path.move(to: CGPoint(x: CGFloat(line.x1 * scale), y: CGFloat(line.y1 * scale)))
            path.addLine(to: CGPoint(x: CGFloat(line.x2 * scale), y: CGFloat(line.y2 * scale)))
            let style = StrokeStyle(lineWidth: CGFloat(line.w * scale), lineCap: .butt)
            context.stroke(path, with: .color(ink(line.white, line.a, dark)), style: style)
        }
        for dot in frame.dots where dot.a >= minAlpha {
            let r: Float = OrbMath.max(dot.r, rMin) * scale
            let x: Float = dot.x * scale - r
            let y: Float = dot.y * scale - r
            let diameter = CGFloat(r * 2.0)
            let rect = CGRect(x: CGFloat(x), y: CGFloat(y), width: diameter, height: diameter)
            context.fill(Path(ellipseIn: rect), with: .color(ink(dot.white, dot.a, dark)))
        }
    }

    /// Ink `white` on paper; dark appearances mirror it.
    nonisolated private static func ink(_ white: Float, _ alpha: Float, _ dark: Bool) -> Color {
        let w = Double(OrbMath.clamp(white, 0.0, 1.0))
        let a = Double(OrbMath.clamp(alpha, 0.0, 1.0))
        return Color(white: dark ? 1.0 - w : w, opacity: a)
    }
}

/// Owns one orb's animator and the frame on screen, across view updates.
final class ThinkingOrbPlayer {
    struct Input {
        var state: OrbState
        var size: OrbSize
        var transition: TimeInterval
        var microphone: Float
        var speaker: Float
        var animating: Bool
        var reduced: Bool
    }

    private var animator: OrbAnimator?
    /// The frame on screen now, so a state change fades from what the reader sees.
    private var frame = OrbFrame()
    private var hasAudio = false

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Apply the view's inputs, advance the clock to now and return the frame to paint.
    func advance(_ input: Input) -> (OrbFrame, Float) {
        let animator: OrbAnimator
        if let existing = self.animator {
            animator = existing
            animator.transitionDuration = Swift.max(input.transition, 0)
            animator.setSize(input.size)
            // A hidden, paused or reduced orb has a stopped clock, so it switches without a fade.
            animator.setState(input.state, visible: frame)
        } else {
            // Nothing is on screen yet, so there is no frame to fade from.
            animator = OrbAnimator(state: input.state, size: input.size, transition: Swift.max(input.transition, 0))
            self.animator = animator
        }
        let time = now
        if hasAudio || input.microphone != 0 || input.speaker != 0 {
            hasAudio = true
            animator.setAudioLevels(microphone: input.microphone, speaker: input.speaker, now: time)
        }
        animator.tick(now: time, animating: input.animating && !input.reduced, reduced: input.reduced)
        animator.draw(into: &frame)
        return (frame, animator.rMin)
    }

    /// Freeze the clock (paused).
    func stop() {
        animator?.stop(now: now)
    }

    /// Freeze the clock and drop any fade (hidden or reduced motion).
    func hide() {
        animator?.stop(now: now)
        animator?.cancelTransition()
    }
}
