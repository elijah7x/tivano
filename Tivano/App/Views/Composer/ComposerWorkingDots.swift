import AppKit
import QuartzCore
import SwiftUI

/// The composer's working animation: a field of accent-tinted dots along the pill's
/// bottom, pulsing in a wave that flows left to right and fades out upward.
///
/// One dot layer carries one repeating opacity keyframe; two replicator layers stamp it
/// across the columns and rows with a per-instance delay, which is what makes the wave
/// travel. Once on screen the render server plays it alone: no timer, no view update
/// and no drawing on the main thread, however long a turn runs.
struct ComposerWorkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatColumnVisibility) private var columnVisibility

    var body: some View {
#if DEBUG
        DotFieldLayerView.Representable(color: Chrome.accentNSColor, animated: !reduceMotion && columnVisibility.isShown && !ProbeKnobs.isOff("dots"))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
#else
        DotFieldLayerView.Representable(color: Chrome.accentNSColor, animated: !reduceMotion && columnVisibility.isShown)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
#endif
    }
}

/// The same field over a whole surface, once: one wave of dots in `tint` flows through it
/// from left to right and is gone, the way a head's panel marks its head finishing. With
/// reduced motion nothing is drawn.
struct DotFieldSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatColumnVisibility) private var columnVisibility
    let tint: NSColor

    var body: some View {
        if !reduceMotion {
            DotFieldLayerView.Representable(color: tint, animated: columnVisibility.isShown, sweeps: true)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

final class DotFieldLayerView: NSView {
    struct Representable: NSViewRepresentable {
        let color: NSColor
        let animated: Bool
        /// One pass over every row instead of the pill's endless wave along the bottom.
        var sweeps = false

        func makeNSView(context: Context) -> DotFieldLayerView {
            let view = DotFieldLayerView()
            view.sweeps = sweeps
            view.configure(color: color, animated: animated)
            return view
        }

        func updateNSView(_ view: DotFieldLayerView, context: Context) {
            view.configure(color: color, animated: animated)
        }
    }

    private let rows = CAReplicatorLayer()
    private let columns = CAReplicatorLayer()
    private let dot = CALayer()
    private let waveMask = CAGradientLayer()
    private var color: NSColor = .controlAccentColor
    private var animated = true
    private var laidOutSize: CGSize = .zero
    private weak var observedWindow: NSWindow?
    /// Set once, before the view is configured: a sweep fills every row of its surface
    /// with one wave that starts when the view appears and ends faded out.
    fileprivate var sweeps = false

    private static let dotSize: CGFloat = 2
    private static let pitch: CGFloat = 8
    /// The field never grows past this many rows however tall the pill gets, so a
    /// five-line draft does not multiply the layers the render server composites.
    private static let maxRows = 3
    private static let period: Double = 2.2
    private static let animationKey = "pulse"
    /// The sweep's single pulse: a wave that crosses a panel of 400 points in about a second.
    private static let sweepPeriod: Double = 0.8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        dot.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        dot.cornerRadius = Self.dotSize / 2
        dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        for replicator in [columns, rows] {
            replicator.actions = ["bounds": NSNull(), "position": NSNull(), "instanceCount": NSNull(), "instanceTransform": NSNull()]
        }
        waveMask.startPoint = CGPoint(x: 0, y: 0.5)
        waveMask.endPoint = CGPoint(x: 1, y: 0.5)
        waveMask.actions = ["locations": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        columns.addSublayer(dot)
        rows.addSublayer(columns)
        layer?.addSublayer(rows)

        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            center.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, animated: Bool) {
        let colorChanged = color != self.color
        let motionChanged = animated != self.animated
        self.color = color
        self.animated = animated
        if colorChanged { dot.backgroundColor = color.cgColor }
        if motionChanged { syncAnimation(force: true) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observedWindow !== window {
            let center = NotificationCenter.default
            let names = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification,
            ]
            if let observedWindow {
                for name in names {
                    center.removeObserver(self, name: name, object: observedWindow)
                }
            }
            observedWindow = window
            if let window {
                for name in names {
                    let selector = name == NSWindow.willCloseNotification
                        ? #selector(windowWillClose)
                        : #selector(visibilityChanged)
                    center.addObserver(self, selector: selector, name: name, object: window)
                }
            }
        }
        syncAnimation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        pauseAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncAnimation()
    }

    @objc private func visibilityChanged() {
        syncAnimation()
    }

    @objc private func windowWillClose() {
        pauseAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The system accent is dynamic; re-resolve it for the new appearance.
        dot.backgroundColor = color.cgColor
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != laidOutSize, size.width > 0, size.height > 0 else { return }
        laidOutSize = size
        let columnCount = Int(ceil(size.width / Self.pitch)) + 1
        let rowCount = sweeps
            ? max(1, Int(ceil(size.height / Self.pitch)))
            : min(Self.maxRows, max(1, Int(ceil(size.height / Self.pitch))))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rows.frame = bounds
        columns.frame = CGRect(x: 0, y: 0, width: size.width, height: Self.pitch)
        waveMask.frame = bounds
        // The base dot sits at the bottom-left; columns march right and rows stack upward,
        // each row a little fainter, so the field dissolves before it reaches the text.
        dot.position = CGPoint(x: Self.pitch / 2, y: Self.pitch / 2)
        columns.instanceCount = columnCount
        columns.instanceTransform = CATransform3DMakeTranslation(Self.pitch, 0, 0)
        columns.instanceDelay = 0
        rows.instanceCount = rowCount
        rows.instanceTransform = CATransform3DMakeTranslation(0, Self.pitch, 0)
        rows.instanceDelay = 0
        rows.instanceAlphaOffset = sweeps ? 0 : -Float(1) / Float(rowCount)
        CATransaction.commit()
        syncAnimation(force: true)
    }

    private var canAnimate: Bool {
        guard animated, superview != nil, bounds.width > 0, let window else { return false }
        return NSApp.isActive
            && !NSApp.isHidden
            && window.isVisible
            && window.occlusionState.contains(.visible)
            && !window.isMiniaturized
            && !isHiddenOrHasHiddenAncestor
    }

    private func pauseAnimation() {
        waveMask.removeAnimation(forKey: Self.animationKey)
        dot.opacity = sweeps ? 0 : 0.28
        rows.mask = nil
    }

    private func syncAnimation(force: Bool = false) {
        guard canAnimate else {
            pauseAnimation()
            return
        }
        if force || waveMask.animation(forKey: Self.animationKey) == nil {
            installAnimation()
        }
    }

    private func installAnimation() {
        waveMask.removeAnimation(forKey: Self.animationKey)
        guard canAnimate else {
            pauseAnimation()
            return
        }
        let baseAlpha: CGFloat = sweeps ? 0 : 0.12
        let peakAlpha: CGFloat = 0.82
        waveMask.colors = [
            NSColor.white.withAlphaComponent(baseAlpha).cgColor,
            NSColor.white.withAlphaComponent(baseAlpha).cgColor,
            NSColor.white.withAlphaComponent(peakAlpha).cgColor,
            NSColor.white.withAlphaComponent(baseAlpha).cgColor,
            NSColor.white.withAlphaComponent(baseAlpha).cgColor,
        ]
        rows.mask = waveMask
        dot.opacity = 1.0
        let band: Double = min(160, max(50, Double(bounds.width) * 0.35)) / Double(bounds.width)
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-band, -band, -band / 2, 0.0, 0.0].map { NSNumber(value: $0) }
        anim.toValue = [1.0, 1.0, 1.0 + band / 2, 1.0 + band, 1.0 + band].map { NSNumber(value: $0) }
        anim.duration = sweeps ? Self.sweepPeriod : Self.period
        anim.repeatCount = sweeps ? 1 : .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        if !sweeps {
            anim.beginTime = waveMask.convertTime(1, from: nil)
        }
        waveMask.add(anim, forKey: Self.animationKey)
    }
}
