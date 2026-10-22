import AppKit
import QuartzCore
import CoreText
import SwiftUI

private struct HeroWeatherContentVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var heroWeatherContentVisible: Bool {
        get { self[HeroWeatherContentVisibleKey.self] }
        set { self[HeroWeatherContentVisibleKey.self] = newValue }
    }
}

@MainActor
final class HeroWeatherView: NSView {
    var onActivate: (() -> Void)?
    /// SwiftUI can keep a zero-width/clipped or transparent sidebar mounted.
    var isContentVisible = true {
        didSet { if oldValue != isContentVisible { refreshMotion() } }
    }

    private typealias Geometry = HeroWeatherGeometry
    private let scene = CALayer()
    private let marks = CALayer()
    private let rightArt = CALayer()
    private let weatherArt = CALayer()
    private let weatherInk = CALayer()
    private let weatherMask = CAShapeLayer()
    private let dollMask = CAShapeLayer()
    private let tagGroup = CALayer()
    private let tagThread = CAShapeLayer()
    private let tagOutline = CAShapeLayer()
    private let tagHole = CAShapeLayer()
    private let rotA = CALayer()
    private let rotB = CALayer()
    private let lift = CALayer()
    private let fabric = CALayer()
    private let headOutline = CAShapeLayer()
    private var markLines: [CAShapeLayer] = []
    private var resolvedLabel = NSColor.black
    private let cloud = CALayer()
    private let cloudOutline = CAShapeLayer()
    private var cloudTail: [CAShapeLayer] = []
    private let sun = CALayer()
    private let rays = CAShapeLayer()
    private let sunOutline = CAShapeLayer()
    private let cloudHatch = CAShapeLayer()
    private let headCrescent = CAShapeLayer()
    private let neckGather = CAShapeLayer()
    private let neckCrease = CAShapeLayer()
    private let tie = CAShapeLayer()
    private let string = CAShapeLayer()
    private let rain = CALayer()
    private let wind = CALayer()
    private let hoverFill = CALayer()
    private let entry = CATextLayer()
    private let shortcut = CATextLayer()
    private let caption = CATextLayer()
    private let entryUnderline = CAShapeLayer()
    private var loopEpoch: CFTimeInterval = 0
    private let brackets = CAShapeLayer()
    private let hangingRule = CAShapeLayer()
    private var ticks: [CAShapeLayer] = []
    private let pleats = CAShapeLayer()
    private let pleatFade = CAGradientLayer()
    private let pleatGroup = CALayer()
    private let pleatClip = CAShapeLayer()
    private let eyes = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var clothLayers: [CAShapeLayer] = []
    private var rainDrops: [CAShapeLayer] = []
    private var streaks: [CAShapeLayer] = []
    private var labels: [CATextLayer] = []
    private var weather: HeroWeather = .idle
    private var configured = false
    private var hovered = false
    private var pressed = false
    private var settled = false
    private var motionAllowed = false
    private var settleTimer: Timer?
    private weak var observedWindow: NSWindow?
    private let defaults = CaptureRun.defaults ?? .standard
    private var clearerBackdrop = false
    private var tracking: NSTrackingArea?
    private var backingScale: CGFloat = 0
    private var lastLayoutSize: CGSize?
    private var appearanceName: NSAppearance.Name?
    private var appearanceClearerBackdrop: Bool?
    private var animatedLayers: [ObjectIdentifier: CALayer] = [:]

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 96) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.isGeometryFlipped = true
        layer?.addSublayer(scene)
        layer?.masksToBounds = true
        clearerBackdrop = defaults.bool(forKey: "clearerBackdrop")
        buildLayers()
        updateAppearance()
        updateScale()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Chrome.localized("New thread"))
        let center = NotificationCenter.default
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            center.addObserver(self, selector: #selector(environmentChanged), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: defaults)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        apply(.idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        settleTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    @discardableResult
    private func shape(_ path: CGPath, in parent: CALayer, fill: CGColor? = nil,
                       stroke: CGColor? = nil, width: CGFloat = 0.5) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = fill
        layer.strokeColor = stroke
        layer.lineWidth = width
        parent.addSublayer(layer)
        return layer
    }

    private func text(_ layer: CATextLayer, _ string: String, x: CGFloat, baseline: CGFloat,
                      size: CGFloat = 9, mono: Bool = true, in parent: CALayer) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size, weight: .medium)
        layer.font = font
        layer.fontSize = size
        layer.string = string
        layer.foregroundColor = color(0xfffef3)
        layer.frame = CGRect(x: x, y: baseline - font.ascender, width: 160, height: ceil(font.ascender - font.descender + 2))
        parent.addSublayer(layer)
        labels.append(layer)
    }

    private func buildLayers() {
        withoutActions {
            for group in [scene, marks, rightArt, rotA, rotB, lift, fabric, sun, cloud, rain, wind, weatherArt, weatherInk, tagGroup] {
                group.allowsGroupOpacity = false
            }
            scene.addSublayer(marks)
            marks.shouldRasterize = true
            for line in [brackets, hangingRule] {
                line.fillColor = nil
                line.lineWidth = 0.3
                marks.addSublayer(line)
            }
            ticks = (0..<57).map { i in
                let tick = CAShapeLayer()
                tick.fillColor = nil
                tick.lineWidth = 0.3
                tick.opacity = Float(min(1, Double(i + 1) / 9, Double(57 - i) / 9))
                marks.addSublayer(tick)
                return tick
            }
            markLines = [brackets, hangingRule] + ticks
            scene.addSublayer(rightArt)
            scene.insertSublayer(weatherArt, below: rightArt)
            weatherArt.addSublayer(weatherInk)
            weatherMask.fillColor = NSColor.black.cgColor
            weatherArt.mask = weatherMask
            dollMask.fillRule = .evenOdd
            dollMask.fillColor = NSColor.black.cgColor
            weatherInk.mask = dollMask
            weatherInk.addSublayer(wind)
            streaks = Geometry.wind.map { shape($0, in: wind) }
            weatherInk.addSublayer(rain)
            rainDrops = Geometry.rain.map { shape($0, in: rain) }
            weatherInk.addSublayer(sun)
            for (layer, path, width) in [(sunOutline, Geometry.sun, CGFloat(0.3)),
                                          (rays, Geometry.rays, CGFloat(0.3))] {
                layer.path = path
                layer.fillColor = nil
                layer.lineWidth = width
                layer.lineCap = .round
                layer.lineJoin = .round
                sun.addSublayer(layer)
            }
            weatherInk.addSublayer(cloud)
            cloudOutline.path = Geometry.cloud
            cloudHatch.path = Geometry.cloudHatch
            cloudTail = Geometry.cloudTail.map { shape($0, in: cloud, width: 0.35) }
            for layer in [cloudOutline, cloudHatch] + cloudTail {
                layer.fillColor = nil
                layer.lineWidth = 0.35
                layer.lineCap = .round
                layer.lineJoin = .round
            }
            cloud.addSublayer(cloudOutline)
            cloud.addSublayer(cloudHatch)
            rightArt.addSublayer(rotA)
            rotA.addSublayer(rotB)
            rotB.addSublayer(lift)
            // Old path coordinates stay intact; the inner group maps the string anchor to zero.
            lift.bounds = CGRect(x: 0, y: 0, width: 268, height: 128)
            lift.anchorPoint = CGPoint(x: 186.0 / 268, y: 10.777778 / 128)
            lift.position = .zero
            lift.addSublayer(fabric)
            string.path = Geometry.string
            string.fillColor = nil
            string.lineWidth = 0.3 / 0.84
            lift.insertSublayer(string, below: fabric)
            clothLayers = Geometry.cloth.map { geometry in
                let layer = shape(geometry.idle, in: fabric,
                                  width: (geometry.name == "body" ? 0.65 : 0.3) / 0.84)
                layer.lineCap = .round
                layer.lineJoin = .round
                return layer
            }
            pleats.path = Geometry.pleats
            pleats.fillColor = nil
            pleats.lineWidth = 0.3 / 0.84
            pleats.lineCap = .round
            pleatGroup.addSublayer(pleats)
            fabric.addSublayer(pleatGroup)
            pleatClip.fillColor = NSColor.black.cgColor
            pleatGroup.mask = pleatClip
            pleatFade.frame = CGRect(x: 150, y: 49, width: 80, height: 44)
            pleatFade.startPoint = CGPoint(x: 0.5, y: 0)
            pleatFade.endPoint = CGPoint(x: 0.5, y: 1)
            pleatFade.colors = [color(0x000000, 0.06), color(0x000000, 0.3), color(0x000000, 0.58)]
            pleatFade.locations = [0, 0.35, 1]
            pleats.mask = pleatFade
            for (layer, path, width) in [(headOutline, Geometry.head, CGFloat(0.65)),
                                          (headCrescent, Geometry.headCrescent, CGFloat(0)),
                                          (eyes, Geometry.eyes, CGFloat(0.38)),
                                          (ring, Geometry.ring, CGFloat(0.65)),
                                          (neckGather, Geometry.neckGather, CGFloat(0)),
                                          (neckCrease, Geometry.neckCrease, CGFloat(0.45)),
                                          (tie, Geometry.tie, CGFloat(0.65))] {
                layer.path = path
                layer.fillColor = nil
                layer.lineWidth = width / 0.84
                layer.lineCap = .round
                layer.lineJoin = .round
                lift.addSublayer(layer)
            }
            let headClip = CAShapeLayer()
            headClip.path = Geometry.head
            headClip.fillColor = NSColor.black.cgColor
            headCrescent.mask = headClip
            // The plate frame is square corner marks, so the wash's corners stay square to meet them.
            hoverFill.cornerRadius = 0
            hoverFill.opacity = 0
            scene.insertSublayer(hoverFill, at: 0)
            entryUnderline.path = Geometry.path("M0 0H72")
            entryUnderline.fillColor = nil
            entryUnderline.lineWidth = 0.5
            entryUnderline.strokeEnd = 0.48
            scene.addSublayer(entryUnderline)
            text(entry, "", x: 0, baseline: 0, size: 11, mono: false, in: scene)
            text(shortcut, ShortcutStore.label(for: .newThread) ?? "",
                 x: 0, baseline: 0, size: 9, mono: false, in: scene)
            shortcut.font = NSFont.systemFont(ofSize: 9, weight: .regular)
            shortcut.alignmentMode = .left
            shortcut.opacity = 0
            scene.addSublayer(tagGroup)
            tagGroup.bounds = CGRect(x: -24, y: 0, width: 48, height: 38)
            tagGroup.anchorPoint = CGPoint(x: 0.5, y: 0)
            for (line, path, width) in [(tagThread, Geometry.tagThread, CGFloat(0.3)),
                                       (tagOutline, Geometry.tagOutline, CGFloat(0.25)),
                                       (tagHole, Geometry.tagHole, CGFloat(0.25))] {
                line.path = path
                line.fillColor = nil
                line.lineWidth = width
                line.lineCap = .round
                line.lineJoin = .round
                tagGroup.addSublayer(line)
            }
            markLines += [tagThread, tagOutline, tagHole]
            text(caption, "Still", x: 0, baseline: 0, size: 8.5, mono: false, in: tagGroup)
            let serif = (NSFont(name: "Georgia-Italic", size: 8.5) ?? NSFont.systemFont(ofSize: 8.5)).fontDescriptor
            let italic = serif.withSymbolicTraits(.italic).addingAttributes([
                .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                                    NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector]]
            ])
            let captionFont = NSFont(descriptor: italic, size: 8.5) ?? NSFont.systemFont(ofSize: 8.5)
            caption.font = captionFont
            caption.alignmentMode = .center
            caption.frame = CGRect(x: -19, y: 31.5 - captionFont.ascender, width: 38,
                                   height: ceil(captionFont.ascender - captionFont.descender + 2))

        }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard lastLayoutSize != size else { return }
        withoutActions {
            scene.frame = bounds
            marks.frame = bounds
            let anchor = (bounds.width * 0.6).rounded()
            rotA.position = CGPoint(x: anchor, y: 15)
            brackets.path = Geometry.path("M17 18V7H28 M\(bounds.width - 28) 7H\(bounds.width - 17)V18 M17 81V92H28 M\(bounds.width - 28) 92H\(bounds.width - 17)V81")
            hangingRule.path = Geometry.path("M\(anchor - 37) 15H\(anchor + 66) M\(anchor - 31) 13v4 M\(anchor + 60) 13v4")
            for (index, tick) in ticks.enumerated() {
                let x = 38 + CGFloat(index) * max(0, bounds.width - 76) / 56
                let length = index % 5 == 0 ? 3.0 : 1.6
                tick.path = Geometry.path("M\(x) 7v\(length) M\(x) 92v-\(length)")
            }
            weatherArt.frame = bounds
            weatherInk.frame = bounds
            weatherMask.frame = bounds
            let weatherLeft = Chrome.listInset + Chrome.rowHorizontalPadding + 64
            weatherMask.path = Geometry.path("M29 47H\(weatherLeft)V18H\(anchor + 36)V88H29Z")
            dollMask.frame = bounds
            updateDollMask()
            sun.position = CGPoint(x: max(anchor - 62, weatherLeft + 24), y: 64)
            cloud.position = CGPoint(x: anchor - 62, y: 21)
            tagGroup.position = CGPoint(x: anchor + 66, y: 15)
            let left = Chrome.listInset + Chrome.rowHorizontalPadding
            hoverFill.frame = CGRect(x: 17, y: 7, width: max(0, bounds.width - 34), height: 85)
            let entryText = entry.string as? NSAttributedString
            let textWidth = ceil(entryText?.size().width ?? 0)
            entry.frame = CGRect(x: left, y: 23, width: textWidth + 1, height: 15)
            entryUnderline.position = CGPoint(x: left, y: 42)
            shortcut.frame = CGRect(x: max(left + 58, entry.frame.maxX + 12), y: 26,
                                    width: max(0, anchor - 37 - max(left + 58, entry.frame.maxX + 12)), height: 13)
            shortcut.truncationMode = .end
            for group in [wind, rain] { group.position = CGPoint(x: anchor - 180, y: 0) }

        }
        lastLayoutSize = size
    }

    func apply(_ weather: HeroWeather) {
        guard !configured || weather != self.weather else { return }
        // A count change inside one scene draws nothing new; rebuilding would
        // restart every loop at phase zero, so keep the animations running.
        if configured && Self.sameScene(self.weather, weather) {
            self.weather = weather
            return
        }
        let animate = configured && canAnimate
        let enteringAwaiting = !isAwaiting
        let leavingRunning = isRunning && !Self.running(weather)
        let rotations = animate && leavingRunning ? [rotA, rotB].map { $0.presentation()?.transform ?? $0.transform } : []
        let oldOpacities = animate ? stateLayers.map { $0.presentation()?.opacity ?? $0.opacity } : []
        self.weather = weather
        configured = true
        settled = false
        stopAnimations()
        setStaticFrame()
        appearanceName = nil
        updateAppearance()
        setAccessibilityValue(Chrome.localized(isRunning ? "Running" : isAwaiting ? "Waiting for you" : isDone ? "Done" : isFailed ? "Error" : "Idle"))
        if animate {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.4
            add(fade, to: caption, key: "state")
        }
        motionAllowed = canAnimate
        if animate {
            for (layer, opacity) in zip(stateLayers, oldOpacities) {
                basic(layer, key: "opacity", from: opacity, to: layer.opacity, duration: 0.4)
            }
            for layer in clothLayers {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.4
                add(fade, to: layer, key: "state")
            }
            if leavingRunning {
                for (layer, transform) in zip([rotA, rotB], rotations) {
                    basic(layer, key: "transform", from: NSValue(caTransform3D: transform),
                          to: NSValue(caTransform3D: layer.transform), duration: 0.8)
                }
            }
        }
        if motionAllowed { installAnimations(entering: enteringAwaiting) }
    }

    private static func running(_ state: HeroWeather) -> Bool {
        if case .running = state { return true }
        return false
    }

    /// Same weather ignoring the thread count, which no layer displays.
    private static func sameScene(_ a: HeroWeather, _ b: HeroWeather) -> Bool {
        switch (a, b) {
        case (.idle, .idle), (.failed, .failed), (.awaiting, .awaiting),
             (.running, .running), (.done, .done):
            true
        default:
            false
        }
    }
    private var isRunning: Bool { Self.running(weather) }
    private var isDone: Bool { if case .done = weather { return true }; return false }
    private var isFailed: Bool { if case .failed = weather { return true }; return false }
    private var isAwaiting: Bool { if case .awaiting = weather { return true }; return false }
    private var stateLayers: [CALayer] { [sun, cloud, rain, wind, marks] }

    private func setStaticFrame() {
        withoutActions {
            cloud.opacity = isAwaiting ? 1 : 0
            cloud.transform = CATransform3DIdentity
            sun.opacity = isDone ? 0.7 : 0
            rain.opacity = isFailed ? 1 : 0
            wind.opacity = isRunning ? 1 : 0
            marks.opacity = isAwaiting ? 0.7 : 1
            caption.string = isRunning ? "Breeze" : isAwaiting ? "Overcast" : isDone ? "Fair" : isFailed ? "Drizzle" : "Still"
            // Negative turns the hem downwind (to the right), the way the wind streaks travel.
            rotA.transform = CATransform3DMakeRotation((isRunning ? -7 : isFailed ? 6 : 0) * .pi / 180, 0, 0, 1)
            tagGroup.transform = CATransform3DMakeRotation((isRunning ? 3 : 0) * .pi / 180, 0, 0, 1)
            rotB.transform = CATransform3DIdentity
            lift.transform = dollTransform
            headCrescent.path = isRunning ? Geometry.runningHeadCrescent[0] : isFailed ? Geometry.failedHeadCrescent : Geometry.headCrescent
            eyes.path = isRunning ? Geometry.runningEyes[0] : isFailed ? Geometry.failedEyes : Geometry.eyes
            ring.path = isRunning ? Geometry.runningRing[0] : Geometry.ring
            scene.transform = CATransform3DMakeScale(pressed ? 0.98 : 1, pressed ? 0.98 : 1, 1)
            rays.transform = CATransform3DIdentity
            rays.opacity = 1
            for (index, panel) in clothLayers.enumerated() {
                let geometry = Geometry.cloth[index]
                panel.path = isDone ? geometry.done : isFailed ? geometry.failed : isRunning ? geometry.running[0] : geometry.idle
            }
            pleatClip.path = clothLayers.first?.path
            updateDollMask()
            for drop in rainDrops {
                drop.opacity = 1
                drop.transform = CATransform3DIdentity
            }
            for streak in streaks {
                streak.opacity = 0.8
                streak.transform = CATransform3DIdentity
            }
        }
    }

    /// Weather passes behind the translucent doll, so the doll's silhouette is cut out of it.
    /// A moving doll needs the whole swept area; a still one only its own outline, which
    /// leaves room for the sun, cloud and rain beside it.
    private func updateDollMask() {
        let anchor = (bounds.width * 0.6).rounded()
        let exclusion = CGMutablePath()
        exclusion.addRect(bounds)
        let body = Geometry.cloth[0]
        func placed(_ path: CGPath, degrees: CGFloat) -> CGPath {
            var transform = CGAffineTransform(translationX: anchor, y: 15)
                .rotated(by: degrees * .pi / 180)
                .scaledBy(x: 0.84, y: 0.84)
                .translatedBy(x: -186, y: -10.777778)
            return path.copy(using: &transform) ?? path
        }
        if isRunning {
            // Every pose the swaying doll passes through, so streaks never show through it.
            var swept: CGPath = CGMutablePath()
            for degrees in stride(from: -9.0, through: -5.0, by: 1.0) {
                for pose in [Geometry.head] + body.running {
                    swept = swept.union(placed(pose, degrees: degrees))
                }
            }
            exclusion.addPath(swept)
        } else {
            let pose = Geometry.head.union(isDone ? body.done : isFailed ? body.failed : body.idle)
            exclusion.addPath(placed(pose, degrees: isFailed ? 6 : 0))
        }
        dollMask.path = exclusion
    }

    private func add(_ animation: CAAnimation, to layer: CALayer, key: String) {
        animatedLayers[ObjectIdentifier(layer)] = layer
        layer.add(animation, forKey: key)
    }

    private func basic(_ layer: CALayer, key: String, from: Any, to: Any, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        add(animation, to: layer, key: key)
    }

    private func loop(_ layer: CALayer, key: String, values: [Any], duration: CFTimeInterval,
                      delay: CFTimeInterval = 0, eased: Bool = false) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(values.count - 1)) }
        animation.timingFunctions = (1..<values.count).map { _ in CAMediaTimingFunction(name: eased ? .easeInEaseOut : .linear) }
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        animation.beginTime = layer.convertTime(loopEpoch, from: nil) - delay
        add(animation, to: layer, key: key)
    }

    private func installAnimations(entering: Bool) {
        guard canAnimate else { return }
        loopEpoch = CACurrentMediaTime()
        if isAwaiting && entering {
            basic(cloud, key: "transform.translation.x", from: -24, to: 0, duration: 1.2)
            basic(cloud, key: "opacity", from: 0, to: 1, duration: 1.2)
        }
        if isRunning {
            loop(tagGroup, key: "transform.rotation.z", values: [-3, 3, -3].map { Double($0) * .pi / 180 }, duration: 3.4, eased: true)
            loop(rotA, key: "transform.rotation.z", values: [-6, -8, -6].map { Double($0) * .pi / 180 }, duration: 3.4, eased: true)
            loop(rotB, key: "transform.rotation.z", values: [0, 1, 0, -1, 0].map { Double($0) * .pi / 180 }, duration: 3.7, eased: true)
            for (index, panel) in clothLayers.enumerated() {
                let paths = Geometry.cloth[index].running
                loop(panel, key: "path", values: paths + [paths[0]], duration: 3.4, eased: true)
            }
            for (layer, paths) in [(headCrescent, Geometry.runningHeadCrescent), (eyes, Geometry.runningEyes), (ring, Geometry.runningRing)] {
                loop(layer, key: "path", values: paths + [paths[0]], duration: 3.4, eased: true)
            }
            let paths = Geometry.cloth[0].running
            loop(pleatClip, key: "path", values: paths + [paths[0]], duration: 3.4, eased: true)
            for (index, streak) in streaks.enumerated() {
                loop(streak, key: "transform.translation.x", values: [-22, 35], duration: 3.6, delay: Double(index) * 0.31)
                loop(streak, key: "opacity", values: [0, 0.8, 0.8, 0], duration: 3.6, delay: Double(index) * 0.31)
            }
        }
        guard (isDone || isFailed) && !settled else { return }
        if isDone {
            loop(rays, key: "transform.rotation.z", values: [0, Double.pi * 2], duration: 60)
        } else {
            for (index, drop) in rainDrops.enumerated() {
                let from = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -10, 0))
                let to = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 20, 0))
                loop(drop, key: "opacity", values: [0, 1, 1, 0], duration: 2.8, delay: Double(index) * 0.29)
                loop(drop, key: "transform", values: [from, to], duration: 2.8, delay: Double(index) * 0.29)
            }
        }
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginSettling() }
        }
    }

    @objc private func beginSettling() {
        settleTimer = nil
        guard isDone || isFailed else { return }
        guard canAnimate else { refreshMotion(); return }
        settled = true
        let target = isDone ? rays : rain
        basic(target, key: "opacity", from: target.presentation()?.opacity ?? target.opacity, to: 0, duration: 0.2)
        withoutActions { target.opacity = 0 }
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishSettling() }
        }
    }

    @objc private func finishSettling() {
        stopAnimations()
        setStaticFrame()
        let target = isDone ? rays : rain
        basic(target, key: "opacity", from: 0, to: target.opacity, duration: 0.2)
    }

    private func stopAnimations() {
        settleTimer?.invalidate()
        settleTimer = nil
        guard !animatedLayers.isEmpty else { return }
        for layer in animatedLayers.values { layer.removeAllAnimations() }
        animatedLayers.removeAll(keepingCapacity: true)
    }

    private var canAnimate: Bool {
        guard isContentVisible, !defaults.bool(forKey: "performanceMode"), let window, window.occlusionState.contains(.visible), !window.isMiniaturized,
              !NSApp.isHidden, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        return ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
    }

    // Thermal, power and defaults notifications can arrive on any thread; the view is
    // main-actor state, so every handler hops to the main actor before touching it.
    @objc nonisolated private func environmentChanged() {
        Task { @MainActor [weak self] in self?.refreshMotion() }
    }

    @objc nonisolated private func defaultsChanged() {
        Task { @MainActor [weak self] in self?.applyDefaults() }
    }

    private func applyDefaults() {
        let clearer = defaults.bool(forKey: "clearerBackdrop")
        refreshMotion()
        guard clearer != clearerBackdrop else { return }
        clearerBackdrop = clearer
        updateAppearance()
    }

    private func refreshMotion() {
        let allowed = canAnimate
        guard allowed != motionAllowed else { return }
        motionAllowed = allowed
        stopAnimations()
        setStaticFrame()
        if allowed { installAnimations(entering: false) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard observedWindow !== window else { return }
        let center = NotificationCenter.default
        if let observedWindow {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                center.removeObserver(self, name: name, object: observedWindow)
            }
        }
        observedWindow = window
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                center.addObserver(self, selector: #selector(environmentChanged), name: name, object: window)
            }
        }
        updateScale()
        refreshMotion()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshMotion()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshMotion()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func ink(_ alpha: CGFloat) -> CGColor {
        resolvedLabel.withAlphaComponent(min(1, alpha)).cgColor
    }

    private var dollTransform: CATransform3D {
        let scale: CGFloat = 0.84
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                 CATransform3DMakeTranslation(0, hovered ? -2 : 0, 0))
    }

    private func updateAppearance() {
        let appearance = effectiveAppearance
        guard appearanceName != appearance.name || appearanceClearerBackdrop != clearerBackdrop else { return }
        appearanceName = appearance.name
        appearanceClearerBackdrop = clearerBackdrop
        appearance.performAsCurrentDrawingAppearance {
            resolvedLabel = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let boost: CGFloat = clearerBackdrop ? 0.08 : 0
        let engraving = dark ? (clearerBackdrop ? UInt32(0xccd6d6) : UInt32(0xb8c4c6))
            : (clearerBackdrop ? UInt32(0x19252b) : UInt32(0x2c363b))
        withoutActions {
            for line in markLines { line.strokeColor = color(engraving, (hovered || pressed ? 0.64 : 0.48) + boost) }
            for line in streaks { line.strokeColor = color(engraving, 0.53 + boost); line.lineWidth = 0.3 }
            for line in rainDrops { line.strokeColor = color(engraving, 0.45 + boost); line.lineWidth = 0.35 }
            for label in labels { label.foregroundColor = ink(0.45) }
            let tagBoost: CGFloat = (hovered || pressed ? 0.16 : 0) + boost
            tagThread.strokeColor = color(engraving, (isFailed ? 0.46 : 0.40) + tagBoost)
            for line in [tagOutline, tagHole] {
                line.strokeColor = color(engraving, (isFailed ? (line === tagHole ? 0.46 : 0.36) : 0.30) + tagBoost)
            }
            caption.foregroundColor = color(engraving, (dark ? 0.50 : 0.45) + boost)
            let descriptor = NSFont.systemFont(ofSize: 11, weight: .regular).fontDescriptor.addingAttributes([
                .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                                    NSFontDescriptor.FeatureKey.selectorIdentifier: kLowerCaseSmallCapsSelector]]
            ])
            entry.string = NSAttributedString(string: Chrome.localized("New thread"), attributes: [
                .font: NSFont(descriptor: descriptor, size: 11) ?? NSFont.systemFont(ofSize: 11),
                .kern: 1,
                .foregroundColor: NSColor(srgbRed: dark ? 1 : 0, green: dark ? 1 : 0,
                                          blue: dark ? 1 : 0, alpha: dark ? 0.88 : 0.82)
            ])
            shortcut.foregroundColor = color(dark ? 0xffffff : 0x000000, dark ? 0.55 : 0.42)
            entryUnderline.strokeColor = color(engraving, 0.55)
            entry.opacity = 1
            hoverFill.backgroundColor = color(engraving, pressed ? 0.07 : dark ? 0.06 : 0.045)
            let dollInk = color(engraving, 0.64 + boost)
            let hatchInk = color(engraving, 0.53 + boost)
            let paper = color(0xffffff, 0.12)
            for (index, layer) in clothLayers.enumerated() {
                let name = Geometry.cloth[index].name
                layer.fillColor = name == "body" ? paper : nil
                layer.strokeColor = name == "body" ? dollInk : hatchInk
                layer.opacity = name.hasPrefix("hatch") ? 0.65 : name.hasPrefix("fold") ? 0 : 1
            }
            pleats.strokeColor = color(engraving)
            headOutline.fillColor = paper
            headOutline.strokeColor = dollInk
            headCrescent.fillColor = color(engraving, 0.46)
            headCrescent.strokeColor = nil
            neckGather.fillColor = color(engraving, 0.025)
            neckGather.strokeColor = nil
            neckCrease.strokeColor = color(engraving, 0.18)
            eyes.strokeColor = color(engraving, 0.66)
            ring.strokeColor = dollInk
            tie.strokeColor = dollInk
            string.strokeColor = hatchInk
            for line in [sunOutline, rays] { line.strokeColor = color(dark ? 0xd5b77e : 0xae8546) }
            for line in [cloudOutline, cloudHatch] + cloudTail { line.strokeColor = color(engraving, 0.60 + boost) }
        }
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard backingScale != scale else { return }
        backingScale = scale
        withoutActions {
            marks.rasterizationScale = scale
            for label in labels { label.contentsScale = scale }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointer(with: event)
        if settled && canAnimate {
            settled = false
            stopAnimations()
            setStaticFrame()
            installAnimations(entering: false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateHover()
    }

    override func mouseMoved(with event: NSEvent) { updatePointer(with: event) }

    private func isInteractive(at point: CGPoint) -> Bool {
        hoverFill.frame.contains(point)
    }

    private func updatePointer(with event: NSEvent) {
        let overPlate = isInteractive(at: convert(event.locationInWindow, from: nil))
        (overPlate ? NSCursor.pointingHand : NSCursor.arrow).set()
        guard hovered != overPlate else { return }
        hovered = overPlate
        updateHover()
    }

    func refreshShortcut() {
        withoutActions { shortcut.string = ShortcutStore.label(for: .newThread) ?? "" }
    }

    private func updateHover() {
        let oldFill = hoverFill.presentation()?.opacity ?? hoverFill.opacity
        let oldShortcut = shortcut.presentation()?.opacity ?? shortcut.opacity
        let oldUnderline = entryUnderline.presentation()?.strokeEnd ?? entryUnderline.strokeEnd
        let oldMarks = markLines.map { $0.presentation()?.strokeColor ?? $0.strokeColor }
        let oldLift = lift.presentation()?.transform ?? lift.transform
        appearanceName = nil
        updateAppearance()
        withoutActions {
            hoverFill.opacity = hovered || pressed ? 1 : 0
            shortcut.opacity = hovered || pressed ? 1 : 0
            entryUnderline.strokeEnd = hovered || pressed ? 1 : 0.48
            lift.transform = dollTransform
        }
        if canAnimate {
            basic(hoverFill, key: "opacity", from: oldFill, to: hoverFill.opacity, duration: 0.16)
            basic(shortcut, key: "opacity", from: oldShortcut, to: shortcut.opacity, duration: 0.16)
            basic(entryUnderline, key: "strokeEnd", from: oldUnderline, to: entryUnderline.strokeEnd, duration: 0.18)
            for (line, oldColor) in zip(markLines, oldMarks) {
                if let oldColor, let target = line.strokeColor {
                    basic(line, key: "strokeColor", from: oldColor, to: target, duration: 0.18)
                }
            }
            basic(lift, key: "transform", from: NSValue(caTransform3D: oldLift), to: NSValue(caTransform3D: lift.transform), duration: 0.18)
        }
    }

    override func cursorUpdate(with event: NSEvent) { updatePointer(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard isInteractive(at: convert(event.locationInWindow, from: nil)) else { return }
        pressed = true
        pressScale(0.98)
    }
    override func mouseUp(with event: NSEvent) {
        let activate = pressed && isInteractive(at: convert(event.locationInWindow, from: nil))
        pressed = false
        pressScale(1)
        if activate { onActivate?() }
    }

    private func pressScale(_ scale: CGFloat) {
        let oldScene = scene.presentation()?.transform ?? scene.transform
        updateHover()
        withoutActions { scene.transform = CATransform3DMakeScale(scale, scale, 1) }
        if canAnimate {
            basic(scene, key: "transform", from: NSValue(caTransform3D: oldScene),
                  to: NSValue(caTransform3D: scene.transform), duration: 0.15)
        }
    }

    override func accessibilityPerformPress() -> Bool { onActivate?(); return true }
}

struct HeroWeatherCard: NSViewRepresentable {
    @Environment(\.heroWeatherContentVisible) private var isContentVisible
    let weather: HeroWeather
    let onActivate: () -> Void

    func makeNSView(context: Context) -> HeroWeatherView {
        let view = HeroWeatherView(frame: CGRect(x: 0, y: 0, width: 268, height: 96))
        view.onActivate = onActivate
        view.isContentVisible = isContentVisible
        view.refreshShortcut()
        view.apply(weather)
        return view
    }

    func updateNSView(_ view: HeroWeatherView, context: Context) {
        view.onActivate = onActivate
        view.isContentVisible = isContentVisible
        view.refreshShortcut()
        view.apply(weather)
    }

    static func dismantleNSView(_ view: HeroWeatherView, coordinator: ()) {
        view.isContentVisible = false
        view.onActivate = nil
    }
}
