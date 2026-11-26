import AppKit
import QuartzCore
import SwiftUI

enum PortholeLayout {
    static let height: CGFloat = 64
    static let cornerRadius: CGFloat = Chrome.trayCornerRadius
}

@MainActor
final class PortholeWeatherView: NSView {
    private typealias Geometry = PortholeWeatherGeometry

    private enum SkyPeriod: Equatable {
        case dawn   // 05:00 - 07:59
        case day    // 08:00 - 16:59
        case dusk   // 17:00 - 19:59
        case night  // 20:00 - 04:59

        static func resolve(for date: Date) -> Self {
            let hour = Calendar.current.component(.hour, from: date)
            switch hour {
            case 5..<8: return .dawn
            case 8..<17: return .day
            case 17..<20: return .dusk
            default: return .night
            }
        }
    }

    private enum WeatherKind: Equatable {
        case idle, awaiting, done, failed

        init(_ weather: HeroWeather) {
            switch weather {
            case .idle: self = .idle
            case .awaiting: self = .awaiting
            case .done: self = .done
            case .failed: self = .failed
            }
        }
    }

    // MARK: - Public API

    /// DEBUG/captures: pins the scene clock (time-of-day sky). nil = Date.now.
    var clockOverride: Date? {
        didSet {
            guard !isSuppressingPropertyObservers, clockOverride != oldValue else { return }
            handleClockOverrideChange()
        }
    }

    /// Material: true for Liquid Glass, false for Texture (same transparent engraving style with slightly warmer, ×1.15 ink).
    var isGlass: Bool = true {
        didSet {
            guard !isSuppressingPropertyObservers, isGlass != oldValue else { return }
            refreshAppearanceAndColors(crossfadeDuration: nil)
        }
    }

    func configure(weather: HeroWeather, animating: Bool, isGlass: Bool, clockOverride: Date?) {
        let clockChanged = self.clockOverride != clockOverride
        isSuppressingPropertyObservers = true
        self.clockOverride = clockOverride
        self.isGlass = isGlass
        isSuppressingPropertyObservers = false
        if clockChanged {
            updateSkyTimer()
        }
        apply(weather, animating: animating)
    }

    /// Shows `weather`. When `animating` is false every animation is removed and the scene holds a still frame of that state.
    func apply(_ weather: HeroWeather, animating: Bool) {
        let newPeriod = SkyPeriod.resolve(for: clockOverride ?? Date.now)
        let periodChanged = newPeriod != skyPeriod
        let glassChanged = appliedIsGlass != isGlass
        let animationsIntact = hasActiveLoopAnimations
        if isCurrentlyAnimating && !animationsIntact {
            isCurrentlyAnimating = false
        }
        let wasAnimating = animationsIntact
        let canAnimateNow = window != nil && bounds.width > 0 && bounds.height > 0
        let animationStateSatisfied = animating ? (!canAnimateNow || animationsIntact) : !isCurrentlyAnimating

        if isConfigured,
           self.weather == weather,
           self.requestedAnimating == animating,
           !periodChanged,
           !glassChanged,
           animationStateSatisfied {
            updateSkyTimer()
            return
        }

        let wasConfigured = isConfigured
        let oldKind = WeatherKind(self.weather)
        let newKind = WeatherKind(weather)
        let oldIntensity = Self.intensityLevel(for: self.weather)
        let newIntensity = Self.intensityLevel(for: weather)
        let animatingToggled = wasConfigured && (self.requestedAnimating != animating || wasAnimating != animating)
        let onScreenAllowingFade = wasConfigured
            && canAnimateNow
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        self.weather = weather
        self.requestedAnimating = animating
        self.skyPeriod = newPeriod
        updateSkyTimer()

        if !animating {
            if wasAnimating, let phases = captureCloudPhases() {
                pausedCloudPhases = phases
            }
            let shouldFadePause = wasAnimating && onScreenAllowingFade
            stopAllAnimations()
            isConfigured = true
            refreshAppearanceAndColors(crossfadeDuration: nil)
            applyStaticPose()
            if shouldFadePause {
                addPauseResumeFade()
            }
            return
        }

        // Same animated scene & capped intensity: refresh material/appearance if needed without resetting loop phases.
        if wasConfigured,
           wasAnimating,
           oldKind == newKind,
           oldIntensity == newIntensity,
           !periodChanged {
            if glassChanged {
                refreshAppearanceAndColors(crossfadeDuration: nil)
            }
            return
        }

        let cloudPhases = captureCloudPhases()
        let shouldCrossfade = wasConfigured && wasAnimating && canAnimateNow
        let shouldFadeResume = !wasAnimating && animatingToggled && onScreenAllowingFade

        let oldTimeWashColors = shouldCrossfade ? (timeWashLayer.presentation()?.colors ?? timeWashLayer.colors) : nil
        let fadeTargets = crossfadeStateLayers
        let oldOpacities = shouldCrossfade ? fadeTargets.map { $0.presentation()?.opacity ?? $0.opacity } : []
        let oldHaloTransform = shouldCrossfade ? (moonlightGlow.presentation()?.transform ?? moonlightGlow.transform) : CATransform3DIdentity
        let wasHaloVisible = shouldCrossfade && ((moonlightGlow.presentation()?.opacity ?? moonlightGlow.opacity) > 0.01)
        let oldDollRotation = shouldCrossfade ? Self.presentationRotationZ(of: dollSwingA) : 0
        let oldDollSwingBPos = shouldCrossfade ? (dollSwingB.presentation()?.position ?? dollSwingB.position) : .zero
        let failedDimChanged = shouldCrossfade && ((oldKind == .failed) != (newKind == .failed))
        let oldDollAccentSnapshots: [(layer: CAShapeLayer, stroke: CGColor?, fill: CGColor?)] = failedDimChanged
            ? [headOutlineLayer, ringLayer, neckGatherLayer, neckCreaseLayer, tieLayer, pleatsLayer].map { part in
                let p = part.presentation() ?? part
                return (part, p.strokeColor, p.fillColor)
            }
            : []

        stopAllAnimations()
        isConfigured = true

        let now = CACurrentMediaTime()
        if loopEpoch == 0 || !wasAnimating {
            loopEpoch = now
        }

        refreshAppearanceAndColors(crossfadeDuration: nil)
        applyStaticPose()
        if wasHaloVisible && moonlightGlow.opacity == 0 {
            withoutActions {
                moonlightGlow.transform = oldHaloTransform
            }
        }
        installAnimations(cloudPhases: cloudPhases)

        if shouldCrossfade {
            let duration: CFTimeInterval = 0.6
            if let oldTimeWashColors, let newTimeWashColors = timeWashLayer.colors {
                addCrossfade(to: timeWashLayer, keyPath: "colors", from: oldTimeWashColors, to: newTimeWashColors, duration: duration)
            }
            for (target, oldOpacity) in zip(fadeTargets, oldOpacities) where abs(oldOpacity - target.opacity) > 0.01 {
                addCrossfade(to: target, keyPath: "opacity", from: oldOpacity, to: target.opacity, duration: duration)
            }
            if oldKind != newKind {
                let elapsed = max(0, now - loopEpoch)
                let newDollRotation = Self.baseDollSwingARotation(for: newKind, elapsed: elapsed)
                let deltaRotation = oldDollRotation - newDollRotation
                if abs(deltaRotation) > 0.0005 {
                    addAdditiveTransition(
                        to: dollSwingA,
                        keyPath: "transform.rotation.z",
                        key: "crossfade-rotation",
                        fromDelta: deltaRotation,
                        duration: duration
                    )
                }

                let newDollSwingBY = Self.baseDollSwingBY(for: newKind, elapsed: elapsed)
                let deltaY = Double(oldDollSwingBPos.y) - newDollSwingBY
                if abs(deltaY) > 0.005 {
                    addAdditiveTransition(
                        to: dollSwingB,
                        keyPath: "position.y",
                        key: "crossfade-positionY",
                        fromDelta: deltaY,
                        duration: duration
                    )
                }
                let deltaX = Double(oldDollSwingBPos.x)
                if abs(deltaX) > 0.005 {
                    addAdditiveTransition(
                        to: dollSwingB,
                        keyPath: "position.x",
                        key: "crossfade-positionX",
                        fromDelta: deltaX,
                        duration: duration
                    )
                }

                let stateFadeTargets: [CALayer] = [
                    dollFabricGroup,
                    dollStringLayer,
                    pleatClipLayer,
                    headCrescentLayer,
                    eyesLayer,
                    telegraphWireLayer,
                    birdsGroup
                ]
                for target in stateFadeTargets {
                    let transition = CATransition()
                    transition.type = .fade
                    transition.duration = duration
                    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    transition.isRemovedOnCompletion = true
                    target.add(transition, forKey: "stateFade")
                }

                for snapshot in oldDollAccentSnapshots {
                    if let oldStroke = snapshot.stroke, let newStroke = snapshot.layer.strokeColor {
                        addCrossfade(to: snapshot.layer, keyPath: "strokeColor", from: oldStroke, to: newStroke, duration: duration)
                    }
                    if let oldFill = snapshot.fill, let newFill = snapshot.layer.fillColor {
                        addCrossfade(to: snapshot.layer, keyPath: "fillColor", from: oldFill, to: newFill, duration: duration)
                    }
                }
            }
        } else if shouldFadeResume {
            addPauseResumeFade()
        }
    }

    // MARK: - Stored State

    fileprivate var currentWeather: HeroWeather { weather }

    private var weather: HeroWeather = .idle
    private var requestedAnimating = false
    private var isCurrentlyAnimating = false
    private var isConfigured = false
    private var isSuppressingPropertyObservers = false
    private var appliedIsGlass: Bool?
    private var skyPeriod: SkyPeriod = .day
    private var skyTimer: Timer?
    private var isObservingSystemTime = false
    private var loopEpoch: CFTimeInterval = 0
    private var pausedCloudPhases: (far: Double, near: Double)?
    private var backingScale: CGFloat = 0
    private var lastLayoutSize: CGSize?

    // MARK: - Layer Tree (Built Once)

    private let scene = CALayer()
    private let sceneMaskContainer = CALayer()
    private let horizontalMaskLayer = CAGradientLayer()
    private let verticalMaskLayer = CAGradientLayer()

    // Faint feathered atmospheric washes (never full-rect fills)
    private let timeWashLayer = CAGradientLayer()
    private let breezeWashLayer = CAGradientLayer()
    private let rainWashLayer = CAGradientLayer()

    // Night sky line art & full-moon glow (.done at night)
    private let celestialNightGroup = CALayer()
    private let moonlightGlow = CAGradientLayer()
    private let starsGroup = CALayer()
    private var starLayers: [CAShapeLayer] = []
    private let moonLayer = CAShapeLayer()
    private let fullMoonLayer = CAShapeLayer()
    private let fullMoonMarksLayer = CAShapeLayer()

    // Sunlight (.done): warm radial glow + engraved sun + fine warm ray strokes
    private let sunGroup = CALayer()
    private let sunGlowLayer = CAGradientLayer()
    private let sunDiscLayer = CAShapeLayer()
    private let sunTicksLayer = CAShapeLayer()
    private var sunRayContainers: [CALayer] = []
    private var sunRayStrokeLayers: [CAShapeLayer] = []
    private var sunRayFadeMasks: [CAGradientLayer] = []

    // Drifting line-art clouds
    private let cloudFarLayer = CAShapeLayer()
    private let cloudNearGroup = CALayer()
    private let cloudNearBodyLayer = CAShapeLayer()
    private let cloudNearCreaseLayer = CAShapeLayer()

    // Far hills hairline ridge + sparse diagonal hatching (occluded behind foreground cottage)
    private let farHillsGroup = CALayer()
    private let farHillsOcclusionMask = CAShapeLayer()
    private let farHillsHatchGroup = CALayer()
    private let farHillsClipLayer = CAShapeLayer()
    private let farHillsHatchLayer = CAShapeLayer()
    private let farHillsStrokeLayer = CAShapeLayer()

    // Far parallax rain plane (.failed)
    private let rainFarGroup = CALayer()
    private var rainFarLayers: [CAShapeLayer] = []

    // Breeze (.awaiting): fine wind streaks + botanical line-art leaves
    private let breezeGroup = CALayer()
    private var windStreakLayers: [CAShapeLayer] = []
    private var windLeafLayers: [CAShapeLayer] = []

    // Horizon ruler, roofline, chimney smoke, night window dot, poles, wires & perched birds
    private let horizonGroup = CALayer()
    private let horizonLayer = CAShapeLayer()
    private let horizonTicksLayer = CAShapeLayer()
    private let horizonTicksMaskLayer = CAGradientLayer()
    private let smokeGroup = CALayer()
    private var smokeLayers: [CAShapeLayer] = []
    private let rooftopLayer = CAShapeLayer()
    private let rooftopDetailLayer = CAShapeLayer()
    private let litWindowContainer = CALayer()
    private let litWindowFlickerLayer = CALayer()
    private let litWindowGlowLayer = CAGradientLayer()
    private let litWindowLayer = CAShapeLayer()
    private let telegraphPoleLayer = CAShapeLayer()
    private let telegraphWireLayer = CAShapeLayer()
    private let birdsGroup = CALayer()
    private let birdLeftLayer = CAShapeLayer()
    private let birdRightLayer = CAShapeLayer()

    // Near rain plane, sliding droplets & horizon ripples (.failed)
    private let rainNearGroup = CALayer()
    private var rainNearLayers: [CAShapeLayer] = []
    private let dropletsGroup = CALayer()
    private var dropletLayers: [CAShapeLayer] = []
    private let ripplesGroup = CALayer()
    private var rippleLayers: [CAShapeLayer] = []

    // Hanging weather doll (Teru-teru-bozu)
    private let dollRoot = CALayer()
    private let dollSwingA = CALayer()
    private let dollSwingB = CALayer()
    private let dollLift = CALayer()
    private let dollStringLayer = CAShapeLayer()
    private let dollFabricGroup = CALayer()
    private var clothLayers: [CAShapeLayer] = []
    private let pleatGroup = CALayer()
    private let pleatsLayer = CAShapeLayer()
    private let pleatClipLayer = CAShapeLayer()
    private let pleatFadeLayer = CAGradientLayer()
    private let headOutlineLayer = CAShapeLayer()
    private let headCrescentLayer = CAShapeLayer()
    private let headClipLayer = CAShapeLayer()
    private let eyesLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let neckGatherLayer = CAShapeLayer()
    private let neckCreaseLayer = CAShapeLayer()
    private let tieLayer = CAShapeLayer()

    private var crossfadeStateLayers: [CALayer] {
        [
            timeWashLayer,
            breezeWashLayer,
            rainWashLayer,
            moonlightGlow,
            starsGroup,
            moonLayer,
            fullMoonLayer,
            fullMoonMarksLayer,
            sunGroup,
            breezeGroup,
            rainFarGroup,
            rainNearGroup,
            dropletsGroup,
            ripplesGroup,
            litWindowContainer,
            smokeGroup,
            birdsGroup
        ]
    }

    // MARK: - View Lifecycle & Non-Interactivity

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: PortholeLayout.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)

        if let root = layer {
            root.isGeometryFlipped = true
            root.backgroundColor = nil
            root.masksToBounds = true
            root.cornerRadius = PortholeLayout.cornerRadius
            root.cornerCurve = .continuous
            root.addSublayer(scene)
        }

        skyPeriod = SkyPeriod.resolve(for: Date.now)
        buildLayerTree()
        updateScale()
        layoutSceneIfNeeded()
        refreshAppearanceAndColors(crossfadeDuration: nil)
        applyStaticPose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        skyTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSceneIfNeeded()
    }

    override func layout() {
        super.layout()
        layoutSceneIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if isCurrentlyAnimating, let phases = captureCloudPhases() {
                pausedCloudPhases = phases
            }
            stopSkyTimer()
            stopSystemTimeObservers()
            stopAllAnimations()
            applyStaticPose()
        } else {
            updateScale()
            startSystemTimeObservers()
            updateSkyTimer()
            layoutSceneIfNeeded()

            let updatedPeriod = SkyPeriod.resolve(for: clockOverride ?? Date.now)
            let periodChanged = updatedPeriod != skyPeriod
            if periodChanged {
                skyPeriod = updatedPeriod
                refreshAppearanceAndColors(crossfadeDuration: nil)
            }

            let animationsIntact = hasActiveLoopAnimations
            if isCurrentlyAnimating && !animationsIntact {
                isCurrentlyAnimating = false
            }

            if requestedAnimating {
                if !animationsIntact || periodChanged {
                    let cloudPhases = captureCloudPhases()
                    stopAllAnimations()
                    loopEpoch = CACurrentMediaTime()
                    applyStaticPose()
                    installAnimations(cloudPhases: cloudPhases)
                }
            } else {
                if isCurrentlyAnimating {
                    stopAllAnimations()
                }
                if periodChanged {
                    applyStaticPose()
                }
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for wash in [timeWashLayer, breezeWashLayer, rainWashLayer, sunGlowLayer] {
            wash.removeAllAnimations()
        }
        moonlightGlow.removeAnimation(forKey: "fade-colors")
        refreshAppearanceAndColors(crossfadeDuration: nil)
    }

    // MARK: - Build Layer Tree Once

    private static func gradientLocations(_ values: [Double]) -> [NSNumber] {
        values.map { (value: Double) -> NSNumber in NSNumber(value: value) }
    }

    private func buildLayerTree() {
        withoutActions {
            buildMaskAndSkyLayers()
            buildLandscapeAndWeatherLayers()
            buildDollLayers()
        }
    }

    private func buildMaskAndSkyLayers() {
        let groups: [CALayer] = [
            scene, celestialNightGroup, starsGroup, sunGroup, cloudNearGroup,
            farHillsGroup, farHillsHatchGroup, rainFarGroup, breezeGroup,
            horizonGroup, smokeGroup, litWindowContainer, litWindowFlickerLayer, birdsGroup,
            rainNearGroup, dropletsGroup, ripplesGroup,
            dollRoot, dollSwingA, dollSwingB, dollLift, dollFabricGroup, pleatGroup
        ]
        for group: CALayer in groups {
            group.allowsGroupOpacity = false
        }

        // 0. Scene soft edge-feather mask (rounded rect + ~18% horizontal fade × ~10pt vertical fade)
        sceneMaskContainer.cornerRadius = PortholeLayout.cornerRadius
        sceneMaskContainer.cornerCurve = .continuous
        sceneMaskContainer.masksToBounds = true

        let edgeFadeAlphas: [CGFloat] = [0.0, 0.26, 0.78, 1.0, 1.0, 0.78, 0.26, 0.0]
        let edgeFadeStops: [CGColor] = edgeFadeAlphas.map { (alpha: CGFloat) -> CGColor in
            srgb(0x000000, alpha)
        }
        horizontalMaskLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        horizontalMaskLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        horizontalMaskLayer.colors = edgeFadeStops
        horizontalMaskLayer.locations = Self.gradientLocations([0.0, 0.06, 0.13, 0.18, 0.82, 0.87, 0.94, 1.0])

        verticalMaskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        verticalMaskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        verticalMaskLayer.colors = edgeFadeStops
        verticalMaskLayer.locations = Self.gradientLocations([0.0, 0.05, 0.11, 0.16, 0.84, 0.89, 0.95, 1.0])

        horizontalMaskLayer.mask = verticalMaskLayer
        sceneMaskContainer.addSublayer(horizontalMaskLayer)
        scene.mask = sceneMaskContainer

        // 1. Faint feathered radial atmospheric washes (fading to 0 well inside the mask)
        let washes: [CAGradientLayer] = [timeWashLayer, breezeWashLayer, rainWashLayer]
        let washLocations: [NSNumber] = Self.gradientLocations([0.0, 0.46, 0.86, 1.0])
        for wash: CAGradientLayer in washes {
            wash.type = .radial
            wash.startPoint = CGPoint(x: 0.5, y: 0.5)
            wash.endPoint = CGPoint(x: 1.0, y: 1.0)
            wash.locations = washLocations
            scene.addSublayer(wash)
        }

        // 2. Night sky: cool radial moonlight halo, twinkling star crosses, crescent moon & full moon
        scene.addSublayer(celestialNightGroup)
        moonlightGlow.type = .radial
        moonlightGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        moonlightGlow.endPoint = CGPoint(x: 1.0, y: 1.0)
        moonlightGlow.locations = Self.gradientLocations([0.0, 0.38, 0.82, 1.0])
        celestialNightGroup.addSublayer(moonlightGlow)

        celestialNightGroup.addSublayer(starsGroup)
        starLayers = Geometry.stars.map { spec -> CAShapeLayer in
            let star = CAShapeLayer()
            star.path = Geometry.starCrossPath(radius: spec.radius, isMajor: spec.isMajor)
            star.fillColor = nil
            star.lineWidth = 0.32
            star.lineCap = .round
            starsGroup.addSublayer(star)
            return star
        }
        moonLayer.path = Geometry.crescentMoon
        moonLayer.lineWidth = 0.36
        moonLayer.lineCap = .round
        moonLayer.lineJoin = .round
        celestialNightGroup.addSublayer(moonLayer)

        fullMoonLayer.path = Geometry.fullMoon
        fullMoonLayer.lineWidth = 0.36
        fullMoonLayer.lineCap = .round
        fullMoonLayer.lineJoin = .round
        celestialNightGroup.addSublayer(fullMoonLayer)

        fullMoonMarksLayer.path = Geometry.fullMoonMarks
        fullMoonMarksLayer.fillColor = nil
        fullMoonMarksLayer.lineWidth = 0.28
        fullMoonMarksLayer.lineCap = .round
        fullMoonMarksLayer.lineJoin = .round
        celestialNightGroup.addSublayer(fullMoonMarksLayer)

        // 3. Sunlight (.done): feathered warm glow + engraved sun disc/ticks + sweeping fine ray strokes
        scene.addSublayer(sunGroup)
        sunGlowLayer.type = .radial
        sunGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        sunGlowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        sunGlowLayer.locations = Self.gradientLocations([0.0, 0.42, 0.84, 1.0])
        sunGroup.addSublayer(sunGlowLayer)

        sunDiscLayer.path = Geometry.sunDisc
        sunDiscLayer.lineWidth = 0.34
        sunDiscLayer.lineCap = .round
        sunGroup.addSublayer(sunDiscLayer)

        sunTicksLayer.path = Geometry.sunCoronaTicks
        sunTicksLayer.fillColor = nil
        sunTicksLayer.lineWidth = 0.30
        sunTicksLayer.lineCap = .round
        sunGroup.addSublayer(sunTicksLayer)

        let rayFadeColors: [CGColor] = [
            srgb(0x000000, 0.0),
            srgb(0x000000, 0.95),
            srgb(0x000000, 0.52),
            srgb(0x000000, 0.0)
        ]
        let rayFadeLocations: [NSNumber] = Self.gradientLocations([0.04, 0.18, 0.62, 1.0])
        for _ in Geometry.sunRays {
            let container = CALayer()
            container.bounds = CGRect(x: 0, y: 0, width: 160, height: 48)
            container.anchorPoint = CGPoint(x: 0.0, y: 0.5)

            let rayLayer = CAShapeLayer()
            rayLayer.frame = container.bounds
            rayLayer.fillColor = nil
            rayLayer.lineWidth = 0.34
            rayLayer.lineCap = .round

            let fadeMask = CAGradientLayer()
            fadeMask.frame = container.bounds
            fadeMask.startPoint = CGPoint(x: 0.0, y: 0.5)
            fadeMask.endPoint = CGPoint(x: 1.0, y: 0.5)
            fadeMask.colors = rayFadeColors
            fadeMask.locations = rayFadeLocations
            rayLayer.mask = fadeMask

            container.addSublayer(rayLayer)
            sunGroup.addSublayer(container)
            sunRayContainers.append(container)
            sunRayStrokeLayers.append(rayLayer)
            sunRayFadeMasks.append(fadeMask)
        }
    }

    private func buildLandscapeAndWeatherLayers() {
        // 4. Far cloud & hatched far hills
        cloudFarLayer.path = Geometry.cloudFar
        cloudFarLayer.lineWidth = 0.32
        cloudFarLayer.lineCap = .round
        cloudFarLayer.lineJoin = .round
        scene.addSublayer(cloudFarLayer)

        farHillsOcclusionMask.fillRule = .evenOdd
        farHillsOcclusionMask.fillColor = NSColor.black.cgColor
        farHillsGroup.mask = farHillsOcclusionMask

        farHillsClipLayer.fillColor = NSColor.black.cgColor
        farHillsHatchGroup.mask = farHillsClipLayer

        farHillsHatchLayer.fillColor = nil
        farHillsHatchLayer.lineWidth = 0.30
        farHillsHatchLayer.lineCap = .round
        farHillsHatchGroup.addSublayer(farHillsHatchLayer)
        farHillsGroup.addSublayer(farHillsHatchGroup)

        farHillsStrokeLayer.fillColor = nil
        farHillsStrokeLayer.lineWidth = 0.35
        farHillsStrokeLayer.lineCap = .round
        farHillsStrokeLayer.lineJoin = .round
        farHillsGroup.addSublayer(farHillsStrokeLayer)
        scene.addSublayer(farHillsGroup)

        // 5. Far parallax rain plane (.failed)
        scene.addSublayer(rainFarGroup)
        rainFarLayers = (0..<5).map { (_: Int) -> CAShapeLayer in
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineWidth = 0.30
            layer.lineCap = .round
            rainFarGroup.addSublayer(layer)
            return layer
        }

        // 6. Near drifting line-art cloud
        cloudNearBodyLayer.path = Geometry.cloudNear
        cloudNearBodyLayer.lineWidth = 0.36
        cloudNearBodyLayer.lineCap = .round
        cloudNearBodyLayer.lineJoin = .round
        cloudNearGroup.addSublayer(cloudNearBodyLayer)

        cloudNearCreaseLayer.path = Geometry.cloudNearCrease
        cloudNearCreaseLayer.fillColor = nil
        cloudNearCreaseLayer.lineWidth = 0.30
        cloudNearCreaseLayer.lineCap = .round
        cloudNearGroup.addSublayer(cloudNearCreaseLayer)
        scene.addSublayer(cloudNearGroup)

        // 7. Breeze (.awaiting): fine horizontal wind streaks + line-art leaves
        scene.addSublayer(breezeGroup)
        windStreakLayers = Geometry.windStreaks.map { spec -> CAShapeLayer in
            let streak = CAShapeLayer()
            streak.path = spec.path
            streak.fillColor = nil
            streak.lineWidth = 0.34
            streak.lineCap = .round
            breezeGroup.addSublayer(streak)
            return streak
        }
        windLeafLayers = Geometry.windLeaves.map { spec -> CAShapeLayer in
            let leaf = CAShapeLayer()
            let scaleY: CGFloat = spec.scale * 0.78
            var scaleTransform = CGAffineTransform(scaleX: spec.scale, y: scaleY)
            let basePath: CGPath = spec.isSamara ? Geometry.samaraBody : Geometry.leafBody
            leaf.path = basePath.copy(using: &scaleTransform) ?? basePath
            leaf.lineWidth = 0.34
            leaf.lineCap = .round
            leaf.lineJoin = .round
            breezeGroup.addSublayer(leaf)
            return leaf
        }

        // 8. Horizon tick ruler, chimney smoke curls, roofline, lit window dot, poles, wires & perched birds
        horizonLayer.fillColor = nil
        horizonLayer.lineWidth = 0.32
        horizonLayer.lineCap = .round
        horizonGroup.addSublayer(horizonLayer)

        horizonTicksLayer.fillColor = nil
        horizonTicksLayer.lineWidth = 0.30
        horizonTicksLayer.lineCap = .round
        horizonTicksMaskLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        horizonTicksMaskLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        let horizonTickColors: [CGColor] = [
            srgb(0x000000, 0.10),
            srgb(0x000000, 1.0),
            srgb(0x000000, 1.0),
            srgb(0x000000, 0.10)
        ]
        horizonTicksMaskLayer.colors = horizonTickColors
        horizonTicksLayer.mask = horizonTicksMaskLayer
        horizonGroup.addSublayer(horizonTicksLayer)
        scene.addSublayer(horizonGroup)

        scene.addSublayer(smokeGroup)
        smokeLayers = Geometry.smokeCurls.map { spec -> CAShapeLayer in
            let curl = CAShapeLayer()
            curl.path = spec.path
            curl.fillColor = nil
            curl.lineWidth = 0.32
            curl.lineCap = .round
            smokeGroup.addSublayer(curl)
            return curl
        }

        rooftopDetailLayer.fillColor = nil
        rooftopDetailLayer.lineWidth = 0.30
        rooftopDetailLayer.lineCap = .round
        rooftopDetailLayer.lineJoin = .round
        scene.addSublayer(rooftopDetailLayer)

        rooftopLayer.fillColor = nil
        rooftopLayer.lineWidth = 0.42
        rooftopLayer.lineCap = .round
        rooftopLayer.lineJoin = .round
        scene.addSublayer(rooftopLayer)

        scene.addSublayer(litWindowContainer)
        litWindowContainer.addSublayer(litWindowFlickerLayer)
        litWindowGlowLayer.type = .radial
        litWindowGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        litWindowGlowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        litWindowFlickerLayer.addSublayer(litWindowGlowLayer)
        litWindowLayer.strokeColor = nil
        litWindowFlickerLayer.addSublayer(litWindowLayer)

        telegraphPoleLayer.fillColor = nil
        telegraphPoleLayer.lineWidth = 0.40
        telegraphPoleLayer.lineCap = .round
        scene.addSublayer(telegraphPoleLayer)

        telegraphWireLayer.fillColor = nil
        telegraphWireLayer.lineWidth = 0.32
        telegraphWireLayer.lineCap = .round
        scene.addSublayer(telegraphWireLayer)

        birdLeftLayer.path = Geometry.birdPath(facingRight: true)
        birdRightLayer.path = Geometry.birdPath(facingRight: false)
        let birds: [CAShapeLayer] = [birdLeftLayer, birdRightLayer]
        for bird: CAShapeLayer in birds {
            bird.lineWidth = 0.35
            bird.lineCap = .round
            bird.lineJoin = .round
            birdsGroup.addSublayer(bird)
        }
        scene.addSublayer(birdsGroup)

        // 9. Near parallax rain plane, sliding droplets & horizon ripples (.failed)
        scene.addSublayer(rainNearGroup)
        rainNearLayers = (0..<5).map { (_: Int) -> CAShapeLayer in
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineWidth = 0.36
            layer.lineCap = .round
            rainNearGroup.addSublayer(layer)
            return layer
        }

        scene.addSublayer(dropletsGroup)
        dropletLayers = Geometry.droplets.map { spec -> CAShapeLayer in
            let drop = CAShapeLayer()
            drop.path = Geometry.dropletPath(rx: spec.radiusX, ry: spec.radiusY)
            drop.lineWidth = 0.35
            drop.lineCap = .round
            drop.lineJoin = .round
            dropletsGroup.addSublayer(drop)
            return drop
        }

        scene.addSublayer(ripplesGroup)
        rippleLayers = Geometry.sillRipples.map { spec -> CAShapeLayer in
            let ripple = CAShapeLayer()
            let ellipseRect = CGRect(x: -spec.rx, y: -spec.ry, width: spec.rx * 2, height: spec.ry * 2)
            ripple.path = CGPath(ellipseIn: ellipseRect, transform: nil)
            ripple.fillColor = nil
            ripple.lineWidth = 0.32
            ripplesGroup.addSublayer(ripple)
            return ripple
        }
    }

    private func buildDollLayers() {
        // 10. Hanging weather doll (Teru-teru-bozu focal object)
        scene.addSublayer(dollRoot)
        dollRoot.addSublayer(dollSwingA)
        dollSwingA.addSublayer(dollSwingB)
        dollSwingB.addSublayer(dollLift)

        dollLift.bounds = Geometry.dollBounds
        dollLift.anchorPoint = CGPoint(
            x: Geometry.dollPivot.x / Geometry.dollBounds.width,
            y: Geometry.dollPivot.y / Geometry.dollBounds.height
        )
        dollLift.position = .zero
        dollLift.transform = CATransform3DMakeScale(Geometry.dollScale, Geometry.dollScale, 1)

        let invScale: CGFloat = 1.0 / Geometry.dollScale
        dollStringLayer.frame = Geometry.dollBounds
        dollStringLayer.path = Geometry.string
        dollStringLayer.fillColor = nil
        dollStringLayer.lineWidth = 0.36 * invScale
        dollStringLayer.lineCap = .round
        dollLift.addSublayer(dollStringLayer)

        dollFabricGroup.frame = Geometry.dollBounds
        dollLift.addSublayer(dollFabricGroup)
        clothLayers = Geometry.cloth.map { item -> CAShapeLayer in
            let panel = CAShapeLayer()
            panel.frame = Geometry.dollBounds
            panel.path = item.idle
            panel.fillColor = nil
            let baseStroke: CGFloat = item.name == "body" ? 0.62 : 0.32
            panel.lineWidth = baseStroke * invScale
            panel.lineCap = .round
            panel.lineJoin = .round
            dollFabricGroup.addSublayer(panel)
            return panel
        }

        pleatGroup.frame = Geometry.dollBounds
        pleatsLayer.frame = Geometry.dollBounds
        pleatsLayer.path = Geometry.pleats
        pleatsLayer.fillColor = nil
        pleatsLayer.lineWidth = 0.30 * invScale
        pleatsLayer.lineCap = .round
        pleatGroup.addSublayer(pleatsLayer)
        dollFabricGroup.addSublayer(pleatGroup)

        pleatClipLayer.frame = Geometry.dollBounds
        pleatClipLayer.fillColor = NSColor.black.cgColor
        pleatClipLayer.path = Geometry.cloth[0].idle
        pleatGroup.mask = pleatClipLayer

        pleatFadeLayer.frame = CGRect(x: 150, y: 49, width: 80, height: 46)
        pleatFadeLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        pleatFadeLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        let pleatFadeColors: [CGColor] = [
            srgb(0x000000, 0.06),
            srgb(0x000000, 0.28),
            srgb(0x000000, 0.55)
        ]
        pleatFadeLayer.colors = pleatFadeColors
        pleatFadeLayer.locations = Self.gradientLocations([0.0, 0.36, 1.0])
        pleatsLayer.mask = pleatFadeLayer

        let headParts: [(CAShapeLayer, CGPath, CGFloat)] = [
            (headOutlineLayer, Geometry.head, 0.62),
            (headCrescentLayer, Geometry.headCrescent, 0.0),
            (eyesLayer, Geometry.eyes, 0.44),
            (ringLayer, Geometry.ring, 0.58),
            (neckGatherLayer, Geometry.neckGather, 0.0),
            (neckCreaseLayer, Geometry.neckCrease, 0.40),
            (tieLayer, Geometry.tie, 0.60)
        ]
        for (part, path, strokePt) in headParts {
            part.frame = Geometry.dollBounds
            part.path = path
            part.fillColor = nil
            part.lineWidth = strokePt * invScale
            part.lineCap = .round
            part.lineJoin = .round
            dollLift.addSublayer(part)
        }

        headClipLayer.frame = Geometry.dollBounds
        headClipLayer.path = Geometry.head
        headClipLayer.fillColor = NSColor.black.cgColor
        headCrescentLayer.mask = headClipLayer
    }

    // MARK: - Responsive Layout (Width ~200-320pt, Height 64pt)

    private func layoutSceneIfNeeded() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            lastLayoutSize = nil
            stopAllAnimations()
            return
        }
        guard lastLayoutSize != size else { return }
        let previousWidth = lastLayoutSize?.width
        let capturedCloudPhases = previousWidth != nil ? captureCloudPhases(referenceWidth: previousWidth) : pausedCloudPhases
        let w = size.width
        let h = size.height

        withoutActions {
            layer?.cornerRadius = PortholeLayout.cornerRadius
            scene.frame = bounds

            // Re-layout feathered rounded-rect mask (~18% width at left/right, ~10pt at top/bottom)
            sceneMaskContainer.frame = bounds
            sceneMaskContainer.cornerRadius = PortholeLayout.cornerRadius
            horizontalMaskLayer.frame = bounds
            verticalMaskLayer.frame = bounds
            let vf = Double(min(0.32, 10.0 / h))
            verticalMaskLayer.locations = [
                0.0,
                vf * 0.35,
                vf * 0.72,
                vf,
                1.0 - vf,
                1.0 - vf * 0.72,
                1.0 - vf * 0.35,
                1.0
            ].map { NSNumber(value: $0) }

            // Feathered atmospheric washes kept well inside the mask
            timeWashLayer.frame = CGRect(x: w * 0.12, y: 4.0, width: w * 0.76, height: max(8, h - 8.0))
            breezeWashLayer.frame = CGRect(x: w * 0.10, y: 5.0, width: w * 0.78, height: max(8, h - 10.0))
            rainWashLayer.frame = CGRect(x: w * 0.10, y: 4.0, width: w * 0.80, height: max(8, h - 8.0))

            celestialNightGroup.frame = bounds
            starsGroup.frame = bounds
            sunGroup.frame = bounds
            farHillsGroup.frame = bounds
            farHillsOcclusionMask.frame = bounds
            farHillsHatchGroup.frame = bounds
            farHillsClipLayer.frame = bounds
            rainFarGroup.frame = bounds
            breezeGroup.frame = bounds
            horizonGroup.frame = bounds
            horizonLayer.frame = bounds
            horizonTicksLayer.frame = bounds
            horizonTicksMaskLayer.frame = bounds
            smokeGroup.frame = bounds
            rooftopDetailLayer.frame = bounds
            rooftopLayer.frame = bounds
            litWindowContainer.frame = bounds
            litWindowFlickerLayer.frame = bounds
            litWindowLayer.frame = bounds
            telegraphPoleLayer.frame = bounds
            telegraphWireLayer.frame = bounds
            birdsGroup.frame = bounds
            rainNearGroup.frame = bounds
            dropletsGroup.frame = bounds
            ripplesGroup.frame = bounds
            dollRoot.frame = bounds

            // Night star crosses, crescent moon, and night-.done full moon + cool radial halo
            for (star, spec) in zip(starLayers, Geometry.stars) {
                star.position = CGPoint(x: (w * spec.xNorm).rounded(), y: spec.y)
            }
            let moonOrigin = CGPoint(x: (w * 0.35).rounded(), y: 15.0)
            moonLayer.position = moonOrigin
            fullMoonLayer.position = moonOrigin
            fullMoonMarksLayer.position = moonOrigin
            let moonGlowRX = min(w * 0.28, 72.0)
            let moonGlowRY: CGFloat = 28.0
            moonlightGlow.bounds = CGRect(x: 0, y: 0, width: moonGlowRX * 2, height: moonGlowRY * 2)
            moonlightGlow.position = moonOrigin

            // Done sun glow, engraved sun disc/ticks & fine warm ray stroke bundles
            let sunOrigin = Geometry.sunOrigin(width: w)
            sunDiscLayer.position = sunOrigin
            sunTicksLayer.position = sunOrigin
            let glowRX = min(w * 0.34, 86.0)
            let glowRY: CGFloat = 32.0
            sunGlowLayer.frame = CGRect(
                x: sunOrigin.x - glowRX,
                y: sunOrigin.y - glowRY,
                width: glowRX * 2,
                height: glowRY * 2
            )

            let diag = hypot(w, h)
            for (index, spec) in Geometry.sunRays.enumerated() {
                let rayLen = min(145, max(44, diag * spec.lengthFactor))
                let container = sunRayContainers[index]
                let rayLayer = sunRayStrokeLayers[index]
                let fadeMask = sunRayFadeMasks[index]
                let box = CGRect(x: 0, y: 0, width: rayLen, height: 48)
                container.bounds = box
                container.position = sunOrigin
                rayLayer.frame = box
                rayLayer.path = Geometry.sunRayBundlePath(length: rayLen, spread: spec.spread, midY: 24)
                fadeMask.frame = box
            }

            // Drifting line-art clouds
            cloudFarLayer.position = CGPoint(x: 0, y: 20.5)
            cloudNearGroup.position = CGPoint(x: 0, y: 12.0)

            // Horizon hairline & single merged ticks layer with gradient end-fade mask
            horizonLayer.path = Geometry.horizonLinePath(width: w)
            horizonTicksLayer.path = Geometry.horizonTicksPath(width: w)
            let tickSpan = max(0.0, Double(w - 36.0))
            let tickStart = min(0.45, 18.0 / Double(w))
            let tickFull = min(0.48, (18.0 + tickSpan * (9.0 / Double(max(1, Geometry.horizonTickCount - 1)))) / Double(w))
            horizonTicksMaskLayer.locations = [
                tickStart,
                tickFull,
                1.0 - tickFull,
                1.0 - tickStart
            ].map { NSNumber(value: $0) }

            // Far hills ridge + clipped sparse diagonal hatching (occluded behind foreground cottage)
            farHillsOcclusionMask.path = Geometry.rooftopOcclusionPath(width: w, height: h)
            farHillsClipLayer.path = Geometry.farHillsClipPath(width: w)
            farHillsHatchLayer.path = Geometry.farHillsHatchPath(width: w)
            farHillsStrokeLayer.path = Geometry.farHillsRidgePath(width: w)

            // Rooftop, chimney smoke curls & warm night attic window dot
            rooftopLayer.path = Geometry.rooftopStrokePath(width: w)
            rooftopDetailLayer.path = Geometry.rooftopDetailPath(width: w)

            let chimney = Geometry.chimneyTop(width: w)
            for curl in smokeLayers {
                curl.position = chimney
            }

            let winRect = Geometry.litWindowRect(width: w)
            litWindowLayer.path = CGPath(roundedRect: winRect, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil)
            let winGlowR: CGFloat = 5.5
            litWindowGlowLayer.frame = CGRect(
                x: winRect.midX - winGlowR,
                y: winRect.midY - winGlowR,
                width: winGlowR * 2,
                height: winGlowR * 2
            )

            // Telegraph poles, wires & two perched ink birds
            telegraphPoleLayer.path = Geometry.telegraphPolesPath(width: w)
            let wires = Geometry.telegraphWires(width: w)
            let isAwaiting = WeatherKind(weather) == .awaiting
            telegraphWireLayer.path = isAwaiting ? wires.breeze[0] : wires.idle

            let leftBirdPos = Geometry.upperWirePositions(width: w, t: Geometry.birdLeftT)
            let rightBirdPos = Geometry.upperWirePositions(width: w, t: Geometry.birdRightT)
            birdLeftLayer.position = isAwaiting ? leftBirdPos.breeze[0] : leftBirdPos.idle
            birdRightLayer.position = isAwaiting ? rightBirdPos.breeze[0] : rightBirdPos.idle

            // Rain planes, droplets & horizon ripples
            let farPaths = Geometry.rainPlanePaths(width: w, isNear: false)
            for (layer, path) in zip(rainFarLayers, farPaths) {
                layer.path = path
            }
            let nearPaths = Geometry.rainPlanePaths(width: w, isNear: true)
            for (layer, path) in zip(rainNearLayers, nearPaths) {
                layer.path = path
            }
            for (drop, spec) in zip(dropletLayers, Geometry.droplets) {
                drop.position = CGPoint(x: (w * spec.xNorm).rounded(), y: spec.startY)
            }
            for (ripple, spec) in zip(rippleLayers, Geometry.sillRipples) {
                ripple.position = CGPoint(x: (w * spec.xNorm).rounded(), y: Geometry.horizonY + spec.yOffset)
            }

            // Hanging doll anchor (kept inside unfeathered horizontal & vertical sweet spot)
            dollSwingA.position = CGPoint(x: (w * 0.70).rounded(), y: 5.5)
        }

        lastLayoutSize = size

        if requestedAnimating && window != nil {
            if hasActiveLoopAnimations {
                stopLoopAnimations()
            } else {
                stopAllAnimations()
            }
            if loopEpoch == 0 {
                loopEpoch = CACurrentMediaTime()
            }
            applyStaticPose()
            installAnimations(cloudPhases: capturedCloudPhases)
        } else {
            if let capturedCloudPhases, pausedCloudPhases != nil {
                pausedCloudPhases = capturedCloudPhases
            }
            applyStaticPose()
        }
    }

    // MARK: - Appearance, Single Resolved Ink & Feathered Atmospheric Washes

    private func refreshAppearanceAndColors(crossfadeDuration: CFTimeInterval?) {
        appliedIsGlass = isGlass
        let appearance = effectiveAppearance
        let match = appearance.bestMatch(from: [
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastAqua,
            .darkAqua,
            .aqua
        ])
        let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let isHighContrast = match == .accessibilityHighContrastDarkAqua || match == .accessibilityHighContrastAqua
        let kind = WeatherKind(weather)

        var resolvedLabel = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            resolvedLabel = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        var inkR: CGFloat = isDark ? 1.0 : 0.0
        var inkG: CGFloat = isDark ? 1.0 : 0.0
        var inkB: CGFloat = isDark ? 1.0 : 0.0
        if let srgbLabel = resolvedLabel.usingColorSpace(.sRGB) {
            inkR = srgbLabel.redComponent
            inkG = srgbLabel.greenComponent
            inkB = srgbLabel.blueComponent
        }

        // Texture mode shares the transparent engraving style with slightly warmer and ×1.15 stronger ink.
        if !isGlass {
            if isDark {
                inkR += (1.00 - inkR) * 0.16
                inkG += (0.94 - inkG) * 0.16
                inkB += (0.83 - inkB) * 0.16
            } else {
                inkR += (0.28 - inkR) * 0.22
                inkG += (0.20 - inkG) * 0.22
                inkB += (0.13 - inkB) * 0.22
            }
        }

        let inkScale: CGFloat = (isGlass ? 1.0 : 1.15) * (isHighContrast ? 1.35 : 1.0)
        func ink(_ alpha: CGFloat) -> CGColor {
            CGColor(
                srgbRed: inkR,
                green: inkG,
                blue: inkB,
                alpha: min(1.0, max(0.0, alpha * inkScale))
            )
        }

        let warmGold: (r: CGFloat, g: CGFloat, b: CGFloat) = isDark
            ? (0.95, 0.80, 0.48)
            : (0.76, 0.54, 0.20)
        func warmInk(_ alpha: CGFloat) -> CGColor {
            CGColor(
                srgbRed: inkR * 0.34 + warmGold.r * 0.66,
                green: inkG * 0.34 + warmGold.g * 0.66,
                blue: inkB * 0.34 + warmGold.b * 0.66,
                alpha: min(1.0, max(0.0, alpha * inkScale))
            )
        }

        withoutActions {
            // 1. Barely-there time-of-day wash (strictly <= 0.08 in both light and dark)
            switch skyPeriod {
            case .dawn:
                let hex: UInt32 = isDark ? 0xE09A74 : 0xF2B28C
                let peak: CGFloat = isDark ? 0.075 : 0.062
                timeWashLayer.colors = [srgb(hex, peak), srgb(hex, peak * 0.42), srgb(hex, 0.0), srgb(hex, 0.0)]
            case .day:
                let hex: UInt32 = isDark ? 0x6AA4D8 : 0x82BAE8
                let peak: CGFloat = isDark ? 0.070 : 0.055
                timeWashLayer.colors = [srgb(hex, peak), srgb(hex, peak * 0.42), srgb(hex, 0.0), srgb(hex, 0.0)]
            case .dusk:
                let centerHex: UInt32 = isDark ? 0xDC9470 : 0xE29B76
                let outerHex: UInt32 = isDark ? 0x9676AE : 0xA482BA
                let peak: CGFloat = isDark ? 0.078 : 0.065
                timeWashLayer.colors = [
                    srgb(centerHex, peak),
                    srgb(outerHex, peak * 0.52),
                    srgb(outerHex, 0.0),
                    srgb(outerHex, 0.0)
                ]
            case .night:
                let hex: UInt32 = isDark ? 0x3A5E98 : 0x3B5B92
                let peak: CGFloat = isDark ? 0.078 : 0.065
                timeWashLayer.colors = [srgb(hex, peak), srgb(hex, peak * 0.44), srgb(hex, 0.0), srgb(hex, 0.0)]
            }

            // 2. Event washes (strictly <= 0.10 in light and <= 0.14 in dark)
            let breezeHex: UInt32 = isDark ? 0x6EC2BC : 0x49949A
            let breezePeak: CGFloat = isDark ? 0.115 : 0.085
            breezeWashLayer.colors = [
                srgb(breezeHex, breezePeak),
                srgb(breezeHex, breezePeak * 0.44),
                srgb(breezeHex, 0.0),
                srgb(breezeHex, 0.0)
            ]

            let intensityBoost = 1.0 + 0.06 * CGFloat(max(0, Self.intensityLevel(for: weather) - 1))
            let sunHex: UInt32 = isDark ? 0xF7CA74 : 0xE8AD44
            let sunPeak = min(isDark ? 0.135 : 0.095, (isDark ? 0.118 : 0.082) * intensityBoost)
            sunGlowLayer.colors = [
                srgb(sunHex, sunPeak),
                srgb(sunHex, sunPeak * 0.44),
                srgb(sunHex, 0.0),
                srgb(sunHex, 0.0)
            ]

            let moonCoreHex: UInt32 = isDark ? 0xE4EEFF : 0x789ECE
            let moonOuterHex: UInt32 = isDark ? 0xB8D2F6 : 0x648AC0
            let moonPeak = min(isDark ? 0.135 : 0.095, (isDark ? 0.120 : 0.084) * intensityBoost)
            moonlightGlow.colors = [
                srgb(moonCoreHex, moonPeak),
                srgb(moonOuterHex, moonPeak * 0.46),
                srgb(moonOuterHex, 0.0),
                srgb(moonOuterHex, 0.0)
            ]

            let rainHex: UInt32 = isDark ? 0x627F9E : 0x4A6078
            let rainPeak: CGFloat = isDark ? 0.125 : 0.088
            rainWashLayer.colors = [
                srgb(rainHex, rainPeak),
                srgb(rainHex, rainPeak * 0.45),
                srgb(rainHex, 0.0),
                srgb(rainHex, 0.0)
            ]

            // 3. Landscape, horizon ticks, clouds & celestial line art (ink at low alphas, fill <= 0.06)
            horizonLayer.strokeColor = ink(0.28)
            horizonTicksLayer.strokeColor = ink(0.34)

            farHillsStrokeLayer.strokeColor = ink(0.25)
            farHillsHatchLayer.strokeColor = ink(0.16)

            rooftopLayer.strokeColor = ink(0.40)
            rooftopDetailLayer.strokeColor = ink(0.20)
            for curl in smokeLayers {
                curl.strokeColor = ink(0.28)
            }

            telegraphPoleLayer.strokeColor = ink(0.34)
            telegraphWireLayer.strokeColor = ink(0.25)
            for bird in [birdLeftLayer, birdRightLayer] {
                bird.strokeColor = ink(0.44)
                bird.fillColor = ink(0.045)
            }

            cloudFarLayer.strokeColor = ink(0.22)
            cloudFarLayer.fillColor = ink(0.025)
            cloudNearBodyLayer.strokeColor = ink(0.35)
            cloudNearBodyLayer.fillColor = ink(0.04)
            cloudNearCreaseLayer.strokeColor = ink(0.22)

            for star in starLayers {
                star.strokeColor = ink(0.44)
            }
            moonLayer.strokeColor = ink(0.46)
            moonLayer.fillColor = ink(0.04)
            fullMoonLayer.strokeColor = ink(isDark ? 0.52 : 0.48)
            fullMoonLayer.fillColor = srgb(isDark ? 0xECF3FF : 0xDCE8FA, isDark ? 0.15 : 0.16)
            fullMoonMarksLayer.strokeColor = ink(0.16)

            // Lit night window dot (the single warm saturated pinpoint at night)
            litWindowLayer.fillColor = srgb(0xFFC266, isDark ? 0.88 : 0.82)
            let winHaloPeak: CGFloat = isDark ? 0.14 : 0.10
            litWindowGlowLayer.colors = [
                srgb(0xFFB84D, winHaloPeak),
                srgb(0xFFB84D, winHaloPeak * 0.35),
                srgb(0xFFB84D, 0.0)
            ]

            // 4. Event ink strokes (.awaiting wind/leaves, .done warm sun & rays, .failed rain/droplets/ripples)
            for streak in windStreakLayers {
                streak.strokeColor = ink(0.38)
            }
            for leaf in windLeafLayers {
                leaf.strokeColor = ink(0.42)
                leaf.fillColor = ink(0.045)
            }

            sunDiscLayer.strokeColor = warmInk(0.44)
            sunDiscLayer.fillColor = warmInk(0.035)
            sunTicksLayer.strokeColor = warmInk(0.35)
            for (rayLayer, spec) in zip(sunRayStrokeLayers, Geometry.sunRays) {
                rayLayer.strokeColor = warmInk(0.36 * spec.weight * min(1.12, intensityBoost))
            }

            for layer in rainFarLayers {
                layer.strokeColor = ink(0.25)
            }
            for layer in rainNearLayers {
                layer.strokeColor = ink(0.38)
            }
            for drop in dropletLayers {
                drop.strokeColor = ink(0.40)
                drop.fillColor = ink(0.045)
            }
            for ripple in rippleLayers {
                ripple.strokeColor = ink(0.36)
            }

            // 5. Hanging weather doll (fold 0.86 failed dim directly into stroke/fill alphas to avoid group-opacity offscreen pass)
            let dollDim: CGFloat = kind == .failed ? 0.86 : 1.0
            let paperHex: UInt32 = isGlass ? 0xFFFFFF : (isDark ? 0xF7F2E8 : 0xFCF9F2)
            let paperAlpha: CGFloat = (isDark ? 0.18 : 0.55) * dollDim
            let paperFill = srgb(paperHex, paperAlpha)

            let dollInk = ink((isDark ? 0.68 : 0.56) * dollDim)
            let hatchInk = ink((isDark ? 0.54 : 0.44) * dollDim)
            let foldInk = ink((isDark ? 0.36 : 0.28) * dollDim)

            for (index, panel) in clothLayers.enumerated() {
                let name = Geometry.cloth[index].name
                panel.fillColor = name == "body" ? paperFill : nil
                if name == "body" {
                    panel.strokeColor = dollInk
                    panel.opacity = 1.0
                } else if name.hasPrefix("hatch") {
                    panel.strokeColor = hatchInk
                    panel.opacity = 0.68
                } else {
                    panel.strokeColor = foldInk
                    panel.opacity = 0.52
                }
            }
            pleatsLayer.strokeColor = ink((isDark ? 0.88 : 0.74) * dollDim)
            headOutlineLayer.fillColor = paperFill
            headOutlineLayer.strokeColor = dollInk
            headCrescentLayer.fillColor = ink((isDark ? 0.26 : 0.22) * dollDim)
            neckGatherLayer.fillColor = ink((isDark ? 0.06 : 0.045) * dollDim)
            neckCreaseLayer.strokeColor = ink((isDark ? 0.32 : 0.24) * dollDim)
            eyesLayer.strokeColor = ink((isDark ? 0.76 : 0.64) * dollDim)
            ringLayer.strokeColor = dollInk
            tieLayer.strokeColor = dollInk
            dollStringLayer.strokeColor = hatchInk
        }

        if let duration = crossfadeDuration, duration > 0 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = duration
            fade.isRemovedOnCompletion = true
            scene.add(fade, forKey: "appearanceFade")
        }
    }

    // MARK: - Representative Still Pose (Exact Match to t = loopEpoch)

    private func applyStaticPose() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let w: CGFloat = bounds.width
        let kind = WeatherKind(weather)
        let intensity: Int = Self.intensityLevel(for: weather)
        let isNight: Bool = skyPeriod == .night
        let isNightDone: Bool = isNight && kind == .done

        withoutActions {
            applyStaticSkyAndLandscapePose(width: w, kind: kind, isNight: isNight, isNightDone: isNightDone)
            applyStaticWeatherEffectsPose(width: w, kind: kind, intensity: intensity, isNight: isNight)
            applyStaticDollPose(kind: kind)
        }
    }

    private func applyStaticSkyAndLandscapePose(width w: CGFloat, kind: WeatherKind, isNight: Bool, isNightDone: Bool) {
        // Atmospheric washes & night layers
        timeWashLayer.opacity = kind == .idle ? 1.0 : 0.35
        breezeWashLayer.opacity = kind == .awaiting ? 1.0 : 0.0
        rainWashLayer.opacity = kind == .failed ? 1.0 : 0.0

        celestialNightGroup.opacity = 1.0
        starsGroup.opacity = isNight ? (kind == .failed ? 0.26 : 1.0) : 0.0
        let starBoost: Double = isNightDone ? 1.15 : 1.0
        let baseStarValues: [Double] = [0.22, 0.94, 0.22]
        let starValues: [Double] = baseStarValues.map { (value: Double) -> Double in min(1.0, value * starBoost) }
        for (star, spec) in zip(starLayers, Geometry.stars) {
            let starAlpha: Double = Self.sampleLoop(
                values: starValues,
                duration: spec.duration,
                delay: spec.delay,
                eased: true
            )
            star.opacity = Float(starAlpha)
        }
        moonLayer.opacity = (isNight && !isNightDone) ? (kind == .failed ? 0.26 : 1.0) : 0.0
        fullMoonLayer.opacity = isNightDone ? 1.0 : 0.0
        fullMoonMarksLayer.opacity = isNightDone ? 1.0 : 0.0
        moonlightGlow.opacity = isNightDone ? 1.0 : 0.0
        let haloScale: Double = Self.sampleLoop(
            values: Self.moonlightHaloScales,
            duration: Self.moonlightHaloDuration,
            delay: Self.moonlightHaloDelay,
            eased: true
        )
        let haloScaleCG: CGFloat = CGFloat(haloScale)
        moonlightGlow.transform = CATransform3DMakeScale(haloScaleCG, haloScaleCG, 1)
        litWindowContainer.opacity = isNight ? 0.92 : 0.0
        let windowFlicker: Double = Self.sampleKeyframes(
            values: Self.litWindowFlickerValues,
            keyTimes: Self.litWindowFlickerKeyTimes,
            timings: nil,
            duration: 46.0,
            delay: 6.0
        )
        litWindowFlickerLayer.opacity = Float(windowFlicker)

        // Clouds resting parallax positions (exact t = loopEpoch phases unless preserving paused cloud positions)
        let phases: (far: Double, near: Double) = pausedCloudPhases ?? (Self.cloudFarDefaultPhase, Self.cloudNearDefaultPhase)
        let farX: CGFloat = Self.cloudX(forPhase: phases.far, width: w, margin: Self.cloudFarMargin)
        let nearX: CGFloat = Self.cloudX(forPhase: phases.near, width: w, margin: Self.cloudNearMargin)
        cloudFarLayer.transform = CATransform3DMakeTranslation(farX, 0, 0)
        cloudNearGroup.transform = CATransform3DMakeTranslation(nearX, 0, 0)

        // Chimney smoke curls & perched birds at t = loopEpoch
        smokeGroup.opacity = kind == .failed ? 0.38 : 1.0
        let smokeAlphas: [Double] = [0.0, 0.82, 0.50, 0.0]
        for (curl, spec) in zip(smokeLayers, Geometry.smokeCurls) {
            let dx: Double = Double(kind == .awaiting ? spec.breezeDriftX : spec.driftX)
            let dy: Double = Double(kind == .awaiting ? spec.riseY * 0.72 : spec.riseY)
            let dur: CFTimeInterval = kind == .awaiting ? spec.duration * 0.55 : spec.duration
            let txValues: [Double] = [0.0, dx * 0.42, dx]
            let tyValues: [Double] = [0.0, dy * 0.52, dy]
            let tx: Double = Self.sampleLoop(values: txValues, duration: dur, delay: spec.delay, eased: false)
            let ty: Double = Self.sampleLoop(values: tyValues, duration: dur, delay: spec.delay, eased: false)
            let alpha: Double = Self.sampleLoop(values: smokeAlphas, duration: dur, delay: spec.delay, eased: false)
            curl.transform = CATransform3DMakeTranslation(CGFloat(tx), CGFloat(ty), 0)
            curl.opacity = Float(alpha)
        }

        let wires = Geometry.telegraphWires(width: w)
        telegraphWireLayer.path = kind == .awaiting ? wires.breeze[0] : wires.idle

        birdsGroup.opacity = kind == .failed ? 0.62 : 1.0
        let leftBirdPos = Geometry.upperWirePositions(width: w, t: Geometry.birdLeftT)
        let rightBirdPos = Geometry.upperWirePositions(width: w, t: Geometry.birdRightT)
        birdLeftLayer.position = kind == .awaiting ? leftBirdPos.breeze[0] : leftBirdPos.idle
        birdRightLayer.position = kind == .awaiting ? rightBirdPos.breeze[0] : rightBirdPos.idle
        birdLeftLayer.transform = CATransform3DIdentity
        birdRightLayer.transform = CATransform3DIdentity
    }

    private func applyStaticWeatherEffectsPose(width w: CGFloat, kind: WeatherKind, intensity: Int, isNight: Bool) {
        // Event group visibility
        breezeGroup.opacity = kind == .awaiting ? 1.0 : 0.0
        sunGroup.opacity = (!isNight && kind == .done) ? 1.0 : 0.0
        rainFarGroup.opacity = kind == .failed ? 1.0 : 0.0
        rainNearGroup.opacity = kind == .failed ? 1.0 : 0.0
        dropletsGroup.opacity = kind == .failed ? 1.0 : 0.0
        ripplesGroup.opacity = kind == .failed ? 1.0 : 0.0

        // Sun & sweeping ray strokes at t = loopEpoch
        sunTicksLayer.transform = CATransform3DIdentity
        let rayAlphaValues: [Double] = [0.72, 1.0, 0.72]
        for (container, spec) in zip(sunRayContainers, Geometry.sunRays) {
            let a0: Double = Double(spec.baseAngle - spec.sweepDelta)
            let a1: Double = Double(spec.baseAngle + spec.sweepDelta)
            let angleValues: [Double] = [a0, a1, a0]
            let angle: Double = Self.sampleLoop(values: angleValues, duration: spec.duration, delay: spec.delay, eased: true)
            let rayAlpha: Double = Self.sampleLoop(values: rayAlphaValues, duration: spec.duration * 0.72, delay: spec.delay, eased: true)
            container.transform = CATransform3DMakeRotation(CGFloat(angle), 0, 0, 1)
            container.opacity = Float(rayAlpha)
        }

        // Breeze streaks & leaves at t = loopEpoch
        let activeStreakCount: Int = min(windStreakLayers.count, 4 + max(0, intensity - 1))
        let endX: Double = Double(w + 24.0)
        for (index, (streak, spec)) in zip(windStreakLayers, Geometry.windStreaks).enumerated() {
            let startX: Double = Double(-64.0 + w * spec.startOffsetNorm * 0.25)
            let xValues: [Double] = [startX, endX]
            let x: Double = Self.sampleLoop(values: xValues, duration: spec.duration, delay: spec.delay, eased: false)
            let alpha: Double
            if index < activeStreakCount {
                let peak: Double = Double(spec.peakOpacity)
                let streakAlphaValues: [Double] = [0.0, peak, Double(spec.peakOpacity * 0.85), 0.0]
                alpha = Self.sampleLoop(
                    values: streakAlphaValues,
                    duration: spec.duration,
                    delay: spec.delay,
                    eased: false
                )
            } else {
                alpha = 0.0
            }
            streak.opacity = Float(alpha)
            streak.position = CGPoint(x: x, y: spec.y)
            streak.transform = CATransform3DIdentity
        }
        let leafRotValues: [Double] = [-0.45, 0.32, -0.20, 0.40, -0.45]
        let leafAlphaValues: [Double] = [0.0, 0.90, 0.90, 0.0]
        for (leaf, spec) in zip(windLeafLayers, Geometry.windLeaves) {
            let progress: Double = Self.normalizedPhase(delay: spec.delay, duration: spec.duration)
            leaf.position = Geometry.windLeafPosition(width: w, spec: spec, progress: CGFloat(progress))
            let rot: Double = Self.sampleLoop(
                values: leafRotValues,
                duration: spec.duration * 0.65,
                delay: spec.delay,
                eased: true
            )
            let leafAlpha: Double = Self.sampleLoop(
                values: leafAlphaValues,
                duration: spec.duration,
                delay: spec.delay,
                eased: false
            )
            leaf.transform = CATransform3DMakeRotation(CGFloat(rot), 0, 0, 1)
            leaf.opacity = Float(leafAlpha)
        }

        // Rain planes, droplets & horizon ripples at t = loopEpoch
        let activeRainPlanes: Int = min(5, 3 + max(0, intensity - 1))
        let planeLimit: Int = intensity >= 2 ? 5 : activeRainPlanes
        for index: Int in 0..<5 {
            let planeAlpha: Float = index < activeRainPlanes ? 1.0 : (intensity >= 2 ? 0.45 : 0.0)
            rainFarLayers[index].opacity = planeAlpha
            rainNearLayers[index].opacity = planeAlpha
            if index < planeLimit {
                let indexD: Double = Double(index)
                let farDur: Double = 0.92 + indexD * 0.08
                let uFar: CGFloat = CGFloat(Self.normalizedPhase(delay: indexD * 0.19, duration: farDur))
                rainFarLayers[index].transform = CATransform3DMakeTranslation(
                    Geometry.rainCycleDriftX * uFar,
                    Geometry.rainCycleHeight * uFar,
                    0
                )
                let nearDur: Double = 0.58 + indexD * 0.06
                let uNear: CGFloat = CGFloat(Self.normalizedPhase(delay: indexD * 0.13, duration: nearDur))
                rainNearLayers[index].transform = CATransform3DMakeTranslation(
                    Geometry.rainCycleDriftX * uNear,
                    Geometry.rainCycleHeight * uNear,
                    0
                )
            } else {
                rainFarLayers[index].transform = CATransform3DIdentity
                rainNearLayers[index].transform = CATransform3DIdentity
            }
        }
        let dropKeyTimes: [Double] = [0.0, 0.34, 1.0]
        let dropAlphaValues: [Double] = [0.0, 0.85, 0.85, 0.0]
        let dropAlphaKeyTimes: [Double] = [0.0, 0.16, 0.84, 1.0]
        for (drop, spec) in zip(dropletLayers, Geometry.droplets) {
            let slideValues: [Double] = [0.0, 1.2, Double(spec.slideDistance)]
            let slideY: Double = Self.sampleKeyframes(
                values: slideValues,
                keyTimes: dropKeyTimes,
                timings: [.easeOut, .easeIn],
                duration: spec.duration,
                delay: spec.delay
            )
            let beadAlpha: Double = Self.sampleKeyframes(
                values: dropAlphaValues,
                keyTimes: dropAlphaKeyTimes,
                timings: nil,
                duration: spec.duration,
                delay: spec.delay
            )
            drop.opacity = Float(beadAlpha)
            drop.transform = CATransform3DMakeTranslation(0, CGFloat(slideY), 0)
        }
        let rippleScaleValues: [Double] = [0.22, 1.15, 1.15]
        let rippleScaleKeyTimes: [Double] = [0.0, 0.68, 1.0]
        let rippleAlphaValues: [Double] = [0.0, 0.86, 0.0, 0.0]
        let rippleAlphaKeyTimes: [Double] = [0.0, 0.14, 0.68, 1.0]
        for (ripple, spec) in zip(rippleLayers, Geometry.sillRipples) {
            let scale: Double = Self.sampleKeyframes(
                values: rippleScaleValues,
                keyTimes: rippleScaleKeyTimes,
                timings: [.easeOut, .linear],
                duration: spec.duration,
                delay: spec.delay
            )
            let rippleAlpha: Double = Self.sampleKeyframes(
                values: rippleAlphaValues,
                keyTimes: rippleAlphaKeyTimes,
                timings: nil,
                duration: spec.duration,
                delay: spec.delay
            )
            ripple.opacity = Float(rippleAlpha)
            let scaleCG: CGFloat = CGFloat(scale)
            ripple.transform = CATransform3DMakeScale(scaleCG, scaleCG, 1)
        }
    }

    private func applyStaticDollPose(kind: WeatherKind) {
        // Hanging weather doll pose & expression at t = loopEpoch (frame 0)
        dollRoot.opacity = 1.0
        let swingARad: CGFloat = CGFloat(Self.baseDollSwingARotation(for: kind, elapsed: 0))
        let swingBRad: CGFloat = switch kind {
        case .idle:     0.5 * .pi / 180
        case .awaiting: 0.0
        case .done:     0.7 * .pi / 180
        case .failed:   0.0
        }
        dollSwingA.transform = CATransform3DMakeRotation(swingARad, 0, 0, 1)
        dollSwingB.transform = CATransform3DMakeRotation(swingBRad, 0, 0, 1)

        let liftOffsetY: CGFloat = CGFloat(Self.baseDollSwingBY(for: kind, elapsed: 0))
        dollSwingB.position = CGPoint(x: 0, y: liftOffsetY)
        dollLift.transform = CATransform3DMakeScale(Geometry.dollScale, Geometry.dollScale, 1)

        dollStringLayer.path = kind == .awaiting ? Geometry.breezeStrings[0] : Geometry.string
        headCrescentLayer.path = switch kind {
        case .idle:     Geometry.headCrescent
        case .awaiting: Geometry.breezeHeadCrescent[0]
        case .done:     Geometry.doneHeadCrescent
        case .failed:   Geometry.failedHeadCrescent
        }
        eyesLayer.path = switch kind {
        case .idle:     Geometry.eyes
        case .awaiting: Geometry.breezeEyes[0]
        case .done:     Geometry.doneEyes
        case .failed:   Geometry.failedEyes
        }
        ringLayer.path = kind == .awaiting ? Geometry.breezeRing[0] : Geometry.ring

        for (index, panel) in clothLayers.enumerated() {
            let item = Geometry.cloth[index]
            panel.path = switch kind {
            case .idle:     item.idle
            case .awaiting: item.breeze[0]
            case .done:     item.done
            case .failed:   item.failed
            }
        }
        pleatClipLayer.path = clothLayers.first?.path
    }

    // MARK: - Core Animation Loops (Zero Per-Frame Main-Thread Work)

    private func installAnimations(cloudPhases: (far: Double, near: Double)? = nil) {
        guard requestedAnimating, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        isCurrentlyAnimating = true
        pausedCloudPhases = nil

        let w = bounds.width
        let kind = WeatherKind(weather)
        let intensity = Self.intensityLevel(for: weather)
        let isNight = skyPeriod == .night
        let now = CACurrentMediaTime()

        // 1. Drifting line-art clouds (phase-continuous across pause/resume, resize & duration changes)
        let farDuration: CFTimeInterval = kind == .awaiting ? 22.0 : 86.0
        let nearDuration: CFTimeInterval = kind == .awaiting ? 15.0 : 64.0
        let resolvedFarPhase = cloudPhases?.far
            ?? Self.cloudPhase(
                forX: cloudFarLayer.transform.m41,
                width: w,
                margin: Self.cloudFarMargin
            )
        let resolvedNearPhase = cloudPhases?.near
            ?? Self.cloudPhase(
                forX: cloudNearGroup.transform.m41,
                width: w,
                margin: Self.cloudNearMargin
            )
        addCloudLoop(
            to: cloudFarLayer,
            width: w,
            margin: Self.cloudFarMargin,
            duration: farDuration,
            phase: resolvedFarPhase,
            now: now,
            lowRate: kind != .awaiting
        )
        addCloudLoop(
            to: cloudNearGroup,
            width: w,
            margin: Self.cloudNearMargin,
            duration: nearDuration,
            phase: resolvedNearPhase,
            now: now,
            lowRate: kind != .awaiting
        )

        // 2. Chimney smoke curls drifting up slowly (long CA loop)
        withoutActions {
            for curl in smokeLayers {
                curl.transform = CATransform3DIdentity
            }
        }
        for (curl, spec) in zip(smokeLayers, Geometry.smokeCurls) {
            let dx = Double(kind == .awaiting ? spec.breezeDriftX : spec.driftX)
            let dy = Double(kind == .awaiting ? spec.riseY * 0.72 : spec.riseY)
            let dur = kind == .awaiting ? spec.duration * 0.55 : spec.duration
            addKeyframeLoop(
                to: curl,
                keyPath: "transform.translation.x",
                values: [0.0, dx * 0.42, dx],
                duration: dur,
                delay: spec.delay,
                eased: false,
                lowRate: true
            )
            addKeyframeLoop(
                to: curl,
                keyPath: "transform.translation.y",
                values: [0.0, dy * 0.52, dy],
                duration: dur,
                delay: spec.delay,
                eased: false,
                lowRate: true
            )
            addKeyframeLoop(
                to: curl,
                keyPath: "opacity",
                values: [0.0, 0.82, 0.50, 0.0],
                duration: dur,
                delay: spec.delay,
                eased: false,
                lowRate: true
            )
        }

        // 3. Perched birds: occasional small hop on calm wire, or riding wire sway in breeze
        if kind == .idle || kind == .done {
            installPerchedBirdLoops()
        }

        // 4. Night star crosses slow staggered twinkle & child window flicker layer (normalized 0...1)
        if isNight {
            let starBoost = kind == .done ? 1.15 : 1.0
            let starValues = [0.22, 0.94, 0.22].map { min(1.0, $0 * starBoost) }
            for (star, spec) in zip(starLayers, Geometry.stars) {
                addKeyframeLoop(
                    to: star,
                    keyPath: "opacity",
                    values: starValues,
                    duration: spec.duration,
                    delay: spec.delay,
                    eased: true,
                    lowRate: true
                )
            }
            let litAnim = CAKeyframeAnimation(keyPath: "opacity")
            litAnim.values = Self.litWindowFlickerValues
            litAnim.keyTimes = Self.litWindowFlickerKeyTimes.map { NSNumber(value: $0) }
            litAnim.duration = 46.0
            litAnim.repeatCount = .infinity
            litAnim.isRemovedOnCompletion = false
            litAnim.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 24, preferred: 15)
            litAnim.beginTime = litWindowFlickerLayer.convertTime(loopEpoch, from: nil) - 6.0
            litWindowFlickerLayer.add(litAnim, forKey: "opacity")
        }

        // 5. Doll pendulum sway & state-specific motion
        switch kind {
        case .idle:
            addKeyframeLoop(
                to: dollSwingA,
                keyPath: "transform.rotation.z",
                values: [-2.2, 2.2, -2.2].map { $0 * .pi / 180.0 },
                duration: 5.0,
                eased: true,
                lowRate: true
            )
            addKeyframeLoop(
                to: dollSwingB,
                keyPath: "transform.rotation.z",
                values: [0.5, -0.5, 0.5].map { $0 * .pi / 180.0 },
                duration: 6.4,
                eased: true,
                lowRate: true
            )

        case .awaiting:
            // Wider downwind swing, string tug, fluttering cloth, swaying wire & wind-riding birds
            addKeyframeLoop(
                to: dollSwingA,
                keyPath: "transform.rotation.z",
                values: [-4.0, -11.5, -5.5, -10.0, -4.0].map { $0 * .pi / 180.0 },
                duration: 3.2,
                eased: true
            )
            addKeyframeLoop(
                to: dollSwingB,
                keyPath: "transform.rotation.z",
                values: [0.0, -1.8, 0.8, -1.2, 0.0].map { $0 * .pi / 180.0 },
                duration: 2.3,
                eased: true
            )
            addKeyframeLoop(
                to: dollSwingB,
                keyPath: "position.y",
                values: [0.2, 1.5, 0.5, 1.2, 0.2],
                duration: 3.2,
                eased: true
            )
            addKeyframeLoop(
                to: dollStringLayer,
                keyPath: "path",
                values: Geometry.breezeStrings + [Geometry.breezeStrings[0]],
                duration: 3.2,
                eased: true,
                lowRate: true
            )
            for (index, panel) in clothLayers.enumerated() {
                let frames = Geometry.cloth[index].breeze
                addKeyframeLoop(
                    to: panel,
                    keyPath: "path",
                    values: frames + [frames[0]],
                    duration: 3.2,
                    eased: true,
                    lowRate: true
                )
            }
            let bodyFrames = Geometry.cloth[0].breeze
            addKeyframeLoop(
                to: pleatClipLayer,
                keyPath: "path",
                values: bodyFrames + [bodyFrames[0]],
                duration: 3.2,
                eased: true,
                lowRate: true
            )
            addKeyframeLoop(
                to: headCrescentLayer,
                keyPath: "path",
                values: Geometry.breezeHeadCrescent + [Geometry.breezeHeadCrescent[0]],
                duration: 3.2,
                eased: true,
                lowRate: true
            )
            addKeyframeLoop(
                to: eyesLayer,
                keyPath: "path",
                values: Geometry.breezeEyes + [Geometry.breezeEyes[0]],
                duration: 3.2,
                eased: true,
                lowRate: true
            )

            let wires = Geometry.telegraphWires(width: w)
            addKeyframeLoop(
                to: telegraphWireLayer,
                keyPath: "path",
                values: wires.breeze + [wires.breeze[0]],
                duration: 2.9,
                eased: true,
                lowRate: true
            )

            let leftPts = Geometry.upperWirePositions(width: w, t: Geometry.birdLeftT).breeze
            let rightPts = Geometry.upperWirePositions(width: w, t: Geometry.birdRightT).breeze
            addKeyframeLoop(
                to: birdLeftLayer,
                keyPath: "position.x",
                values: (leftPts + [leftPts[0]]).map { Double($0.x) },
                duration: 2.9,
                eased: true,
                lowRate: true
            )
            addKeyframeLoop(
                to: birdLeftLayer,
                keyPath: "position.y",
                values: (leftPts + [leftPts[0]]).map { Double($0.y) },
                duration: 2.9,
                eased: true,
                lowRate: true
            )
            addKeyframeLoop(
                to: birdRightLayer,
                keyPath: "position.x",
                values: (rightPts + [rightPts[0]]).map { Double($0.x) },
                duration: 2.9,
                eased: true,
                lowRate: true
            )
            addKeyframeLoop(
                to: birdRightLayer,
                keyPath: "position.y",
                values: (rightPts + [rightPts[0]]).map { Double($0.y) },
                duration: 2.9,
                eased: true,
                lowRate: true
            )

            let activeStreakCount = min(windStreakLayers.count, 4 + max(0, intensity - 1))
            for index in 0..<activeStreakCount {
                let streak = windStreakLayers[index]
                let spec = Geometry.windStreaks[index]
                let startX = Double(-64.0 + w * spec.startOffsetNorm * 0.25)
                let endX = Double(w + 24.0)
                withoutActions {
                    streak.position = CGPoint(x: 0, y: spec.y)
                }
                addKeyframeLoop(
                    to: streak,
                    keyPath: "position.x",
                    values: [startX, endX],
                    duration: spec.duration,
                    delay: spec.delay,
                    eased: false
                )
                addKeyframeLoop(
                    to: streak,
                    keyPath: "opacity",
                    values: [0.0, Double(spec.peakOpacity), Double(spec.peakOpacity * 0.85), 0.0],
                    duration: spec.duration,
                    delay: spec.delay,
                    eased: false
                )
            }

            for (leaf, spec) in zip(windLeafLayers, Geometry.windLeaves) {
                let flight = CAKeyframeAnimation(keyPath: "position")
                flight.path = Geometry.windLeafRoutePath(width: w, spec: spec)
                flight.duration = spec.duration
                flight.repeatCount = .infinity
                flight.isRemovedOnCompletion = false
                flight.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
                flight.beginTime = leaf.convertTime(loopEpoch, from: nil) - spec.delay
                leaf.add(flight, forKey: "position")

                addKeyframeLoop(
                    to: leaf,
                    keyPath: "transform.rotation.z",
                    values: [-0.45, 0.32, -0.20, 0.40, -0.45],
                    duration: spec.duration * 0.65,
                    delay: spec.delay,
                    eased: true
                )
                addKeyframeLoop(
                    to: leaf,
                    keyPath: "opacity",
                    values: [0.0, 0.90, 0.90, 0.0],
                    duration: spec.duration,
                    delay: spec.delay,
                    eased: false
                )
            }

        case .done:
            // Cheerful gentle doll sway + daytime corona/sunbeam loops or nighttime halo breathing
            addKeyframeLoop(
                to: dollSwingA,
                keyPath: "transform.rotation.z",
                values: [-3.0, 2.6, -3.0].map { $0 * .pi / 180.0 },
                duration: 4.4,
                eased: true,
                lowRate: true
            )
            addKeyframeLoop(
                to: dollSwingB,
                keyPath: "transform.rotation.z",
                values: [0.7, -0.7, 0.7].map { $0 * .pi / 180.0 },
                duration: 5.6,
                eased: true,
                lowRate: true
            )
            addKeyframeLoop(
                to: dollSwingB,
                keyPath: "position.y",
                values: [0.0, -0.8, 0.0],
                duration: 4.4,
                eased: true,
                lowRate: true
            )

            if isNight {
                addKeyframeLoop(
                    to: moonlightGlow,
                    keyPath: "transform.scale",
                    values: Self.moonlightHaloScales,
                    duration: Self.moonlightHaloDuration,
                    delay: Self.moonlightHaloDelay,
                    eased: true,
                    lowRate: true
                )
            } else {
                addKeyframeLoop(
                    to: sunTicksLayer,
                    keyPath: "transform.rotation.z",
                    values: [0.0, Double.pi * 2.0],
                    duration: 60.0,
                    eased: false,
                    lowRate: true
                )

                for (container, spec) in zip(sunRayContainers, Geometry.sunRays) {
                    let a0 = Double(spec.baseAngle - spec.sweepDelta)
                    let a1 = Double(spec.baseAngle + spec.sweepDelta)
                    addKeyframeLoop(
                        to: container,
                        keyPath: "transform.rotation.z",
                        values: [a0, a1, a0],
                        duration: spec.duration,
                        delay: spec.delay,
                        eased: true,
                        lowRate: true
                    )
                    addKeyframeLoop(
                        to: container,
                        keyPath: "opacity",
                        values: [0.72, 1.0, 0.72],
                        duration: spec.duration * 0.72,
                        delay: spec.delay,
                        eased: true,
                        lowRate: true
                    )
                }
            }

        case .failed:
            // Dampened heavy droop sway + 2-plane parallax slanted rain + sliding droplets + horizon ripples
            addKeyframeLoop(
                to: dollSwingA,
                keyPath: "transform.rotation.z",
                values: [4.1, 6.0, 4.1].map { $0 * .pi / 180.0 },
                duration: 5.8,
                eased: true,
                lowRate: true
            )

            let cycleDX = Double(Geometry.rainCycleDriftX)
            let cycleDY = Double(Geometry.rainCycleHeight)
            let activeRainPlanes = min(5, 3 + max(0, intensity - 1))
            let planeLimit = intensity >= 2 ? 5 : activeRainPlanes

            for index in 0..<planeLimit {
                let farLayer = rainFarLayers[index]
                let farDuration = 0.92 + Double(index) * 0.08
                addRainTranslationLoop(
                    to: farLayer,
                    dx: cycleDX,
                    dy: cycleDY,
                    duration: farDuration,
                    delay: Double(index) * 0.19
                )

                let nearLayer = rainNearLayers[index]
                let nearDuration = 0.58 + Double(index) * 0.06
                addRainTranslationLoop(
                    to: nearLayer,
                    dx: cycleDX,
                    dy: cycleDY,
                    duration: nearDuration,
                    delay: Double(index) * 0.13
                )
            }

            withoutActions {
                for drop in dropletLayers {
                    drop.transform = CATransform3DIdentity
                }
            }
            for (drop, spec) in zip(dropletLayers, Geometry.droplets) {
                let slide = CAKeyframeAnimation(keyPath: "transform.translation.y")
                slide.values = [0.0, 1.2, Double(spec.slideDistance)]
                slide.keyTimes = [0.0, 0.34, 1.0]
                slide.timingFunctions = [
                    CAMediaTimingFunction(name: .easeOut),
                    CAMediaTimingFunction(name: .easeIn)
                ]
                slide.duration = spec.duration
                slide.repeatCount = .infinity
                slide.isRemovedOnCompletion = false
                slide.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
                slide.beginTime = drop.convertTime(loopEpoch, from: nil) - spec.delay
                drop.add(slide, forKey: "slideY")

                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0.0, 0.85, 0.85, 0.0]
                fade.keyTimes = [0.0, 0.16, 0.84, 1.0]
                fade.duration = spec.duration
                fade.repeatCount = .infinity
                fade.isRemovedOnCompletion = false
                fade.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
                fade.beginTime = drop.convertTime(loopEpoch, from: nil) - spec.delay
                drop.add(fade, forKey: "beadFade")
            }

            withoutActions {
                for ripple in rippleLayers {
                    ripple.transform = CATransform3DIdentity
                }
            }
            for (ripple, spec) in zip(rippleLayers, Geometry.sillRipples) {
                let expand = CAKeyframeAnimation(keyPath: "transform.scale")
                expand.values = [0.22, 1.15, 1.15]
                expand.keyTimes = [0.0, 0.68, 1.0]
                expand.timingFunctions = [
                    CAMediaTimingFunction(name: .easeOut),
                    CAMediaTimingFunction(name: .linear)
                ]
                expand.duration = spec.duration
                expand.repeatCount = .infinity
                expand.isRemovedOnCompletion = false
                expand.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
                expand.beginTime = ripple.convertTime(loopEpoch, from: nil) - spec.delay
                ripple.add(expand, forKey: "expand")

                let rippleFade = CAKeyframeAnimation(keyPath: "opacity")
                rippleFade.values = [0.0, 0.86, 0.0, 0.0]
                rippleFade.keyTimes = [0.0, 0.14, 0.68, 1.0]
                rippleFade.duration = spec.duration
                rippleFade.repeatCount = .infinity
                rippleFade.isRemovedOnCompletion = false
                rippleFade.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
                rippleFade.beginTime = ripple.convertTime(loopEpoch, from: nil) - spec.delay
                ripple.add(rippleFade, forKey: "rippleFade")
            }
        }
    }

    private func installPerchedBirdLoops() {
        let lowRange = CAFrameRateRange(minimum: 12, maximum: 24, preferred: 18)

        // Left bird: subtle occasional head/tail tilt
        let bob = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        bob.values = [0.0, 0.0, 0.09, 0.0, -0.05, 0.0, 0.0]
        bob.keyTimes = [0.0, 0.38, 0.42, 0.47, 0.51, 0.55, 1.0]
        bob.duration = 9.8
        bob.repeatCount = .infinity
        bob.isRemovedOnCompletion = false
        bob.preferredFrameRateRange = lowRange
        bob.beginTime = birdLeftLayer.convertTime(loopEpoch, from: nil) - 1.5
        birdLeftLayer.add(bob, forKey: "birdBob")

        // Right bird: small occasional two-step hop along the wire (12.6s loop)
        let hopTimes: [NSNumber] = [0.0, 0.72, 0.755, 0.79, 0.85, 0.885, 0.92, 1.0]
        let hopDuration: CFTimeInterval = 12.6
        let hopStart = birdRightLayer.convertTime(loopEpoch, from: nil) - 3.2

        let hopX = CAKeyframeAnimation(keyPath: "transform.translation.x")
        hopX.values = [0.0, 0.0, 1.2, 2.3, 2.3, 1.1, 0.0, 0.0]
        hopX.keyTimes = hopTimes
        hopX.duration = hopDuration
        hopX.repeatCount = .infinity
        hopX.isRemovedOnCompletion = false
        hopX.preferredFrameRateRange = lowRange
        hopX.beginTime = hopStart
        birdRightLayer.add(hopX, forKey: "hopX")

        let hopY = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hopY.values = [0.0, 0.0, -2.2, 0.12, 0.12, -1.9, 0.0, 0.0]
        hopY.keyTimes = hopTimes
        hopY.duration = hopDuration
        hopY.repeatCount = .infinity
        hopY.isRemovedOnCompletion = false
        hopY.preferredFrameRateRange = lowRange
        hopY.beginTime = hopStart
        birdRightLayer.add(hopY, forKey: "hopY")

        let hopTilt = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        hopTilt.values = [0.0, 0.0, -0.14, 0.04, 0.04, 0.12, 0.0, 0.0]
        hopTilt.keyTimes = hopTimes
        hopTilt.duration = hopDuration
        hopTilt.repeatCount = .infinity
        hopTilt.isRemovedOnCompletion = false
        hopTilt.preferredFrameRateRange = lowRange
        hopTilt.beginTime = hopStart
        birdRightLayer.add(hopTilt, forKey: "hopTilt")
    }

    private func addCloudLoop(
        to target: CALayer,
        width w: CGFloat,
        margin: CGFloat,
        duration: CFTimeInterval,
        phase: Double,
        now: CFTimeInterval,
        lowRate: Bool
    ) {
        withoutActions {
            target.transform = CATransform3DIdentity
        }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [Double(-margin), Double(w + margin)]
        anim.keyTimes = [0.0, 1.0]
        anim.timingFunctions = [CAMediaTimingFunction(name: .linear)]
        anim.duration = duration
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        anim.preferredFrameRateRange = lowRate
            ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 20)
            : CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        anim.beginTime = target.convertTime(now, from: nil) - phase * duration
        target.add(anim, forKey: "transform.translation.x")
    }

    private func addKeyframeLoop(
        to target: CALayer,
        keyPath: String,
        values: [Any],
        duration: CFTimeInterval,
        delay: CFTimeInterval = 0,
        eased: Bool,
        lowRate: Bool = false
    ) {
        guard values.count >= 2 else { return }
        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.values = values
        anim.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(values.count - 1)) }
        anim.timingFunctions = (1..<values.count).map { _ in
            CAMediaTimingFunction(name: eased ? .easeInEaseOut : .linear)
        }
        anim.duration = duration
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        anim.preferredFrameRateRange = lowRate
            ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 20)
            : CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        anim.beginTime = target.convertTime(loopEpoch, from: nil) - delay
        target.add(anim, forKey: keyPath)
    }

    private func addRainTranslationLoop(
        to target: CALayer,
        dx: Double,
        dy: Double,
        duration: CFTimeInterval,
        delay: CFTimeInterval
    ) {
        withoutActions {
            target.transform = CATransform3DIdentity
        }
        let from = NSValue(caTransform3D: CATransform3DIdentity)
        let to = NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0))
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        anim.beginTime = target.convertTime(loopEpoch, from: nil) - delay
        target.add(anim, forKey: "rainFall")
    }

    private func addCrossfade(
        to target: CALayer,
        keyPath: String,
        from: Any,
        to: Any,
        duration: CFTimeInterval
    ) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.isRemovedOnCompletion = true
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(anim, forKey: "fade-\(keyPath)")
    }

    private func addAdditiveTransition(
        to target: CALayer,
        keyPath: String,
        key: String,
        fromDelta: Double,
        duration: CFTimeInterval
    ) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.isAdditive = true
        anim.fromValue = fromDelta
        anim.toValue = 0.0
        anim.duration = duration
        anim.isRemovedOnCompletion = true
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(anim, forKey: key)
    }

    private func addPauseResumeFade() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.isRemovedOnCompletion = true
        scene.add(fade, forKey: "pauseResumeFade")
    }

    private var hasActiveLoopAnimations: Bool {
        guard isCurrentlyAnimating else { return false }
        return cloudFarLayer.animation(forKey: "transform.translation.x") != nil
            && dollSwingA.animation(forKey: "transform.rotation.z") != nil
    }

    private static let preservedCrossfadeKeys: Set<String> = [
        "fade-colors",
        "fade-opacity",
        "fade-strokeColor",
        "fade-fillColor",
        "stateFade",
        "crossfade-rotation",
        "crossfade-positionY",
        "crossfade-positionX",
        "pauseResumeFade",
        "appearanceFade"
    ]

    private func stopAllAnimations() {
        isCurrentlyAnimating = false
        if let root = layer {
            removeAnimationsRecursively(from: root, preservingCrossfades: false)
        }
    }

    private func stopLoopAnimations() {
        isCurrentlyAnimating = false
        if let root = layer {
            removeAnimationsRecursively(from: root, preservingCrossfades: true)
        }
    }

    private func removeAnimationsRecursively(from target: CALayer, preservingCrossfades: Bool) {
        if preservingCrossfades {
            if let keys = target.animationKeys() {
                for key in keys where !Self.preservedCrossfadeKeys.contains(key) {
                    target.removeAnimation(forKey: key)
                }
            }
        } else {
            target.removeAllAnimations()
        }
        if let mask = target.mask {
            removeAnimationsRecursively(from: mask, preservingCrossfades: preservingCrossfades)
        }
        if let sublayers = target.sublayers {
            for child in sublayers {
                removeAnimationsRecursively(from: child, preservingCrossfades: preservingCrossfades)
            }
        }
    }

    // MARK: - Cloud Phase Continuity & Exact Loop Sampling

    private static let cloudFarDefaultPhase: Double = 0.28
    private static let cloudNearDefaultPhase: Double = 0.56
    private static let cloudFarMargin: CGFloat = 48.0
    private static let cloudNearMargin: CGFloat = 60.0
    private static let moonlightHaloScales: [Double] = [0.92, 1.08, 0.92]
    private static let moonlightHaloDuration: CFTimeInterval = 5.2
    private static let moonlightHaloDelay: CFTimeInterval = 1.3
    private static let litWindowFlickerValues: [Double] = [0.9565, 1.0, 0.9130, 0.0, 0.0, 0.9565]
    private static let litWindowFlickerKeyTimes: [Double] = [0.0, 0.28, 0.54, 0.60, 0.92, 1.0]

    private func captureCloudPhases(referenceWidth: CGFloat? = nil) -> (far: Double, near: Double)? {
        let refW = referenceWidth ?? lastLayoutSize?.width ?? 0
        guard isConfigured, refW > 0 else {
            return pausedCloudPhases
        }
        if !isCurrentlyAnimating, let paused = pausedCloudPhases {
            return paused
        }
        let farAnimated = isCurrentlyAnimating || (cloudFarLayer.animationKeys()?.isEmpty == false)
        let nearAnimated = isCurrentlyAnimating || (cloudNearGroup.animationKeys()?.isEmpty == false)
        let farSource = farAnimated ? (cloudFarLayer.presentation() ?? cloudFarLayer) : cloudFarLayer
        let nearSource = nearAnimated ? (cloudNearGroup.presentation() ?? cloudNearGroup) : cloudNearGroup
        return (
            Self.cloudPhase(forX: farSource.transform.m41, width: refW, margin: Self.cloudFarMargin),
            Self.cloudPhase(forX: nearSource.transform.m41, width: refW, margin: Self.cloudNearMargin)
        )
    }

    private static func cloudPhase(forX x: CGFloat, width w: CGFloat, margin: CGFloat) -> Double {
        let span = Double(w + margin * 2)
        guard span > 0 else { return 0 }
        var phase = Double(x + margin) / span
        phase = phase.truncatingRemainder(dividingBy: 1.0)
        if phase < 0 { phase += 1.0 }
        return phase
    }

    private static func cloudX(forPhase phase: Double, width w: CGFloat, margin: CGFloat) -> CGFloat {
        -margin + (w + margin * 2) * CGFloat(phase)
    }

    private static func presentationRotationZ(of target: CALayer) -> Double {
        let source = target.presentation() ?? target
        if let angle = source.value(forKeyPath: "transform.rotation.z") as? Double {
            return angle
        }
        let t = source.transform
        return Double(atan2(t.m12, t.m11))
    }

    private static func baseDollSwingARotation(for kind: WeatherKind, elapsed: CFTimeInterval) -> Double {
        switch kind {
        case .idle:
            return sampleLoop(values: [-2.2, 2.2, -2.2].map { $0 * .pi / 180.0 }, duration: 5.0, delay: elapsed, eased: true)
        case .awaiting:
            return sampleLoop(values: [-4.0, -11.5, -5.5, -10.0, -4.0].map { $0 * .pi / 180.0 }, duration: 3.2, delay: elapsed, eased: true)
        case .done:
            return sampleLoop(values: [-3.0, 2.6, -3.0].map { $0 * .pi / 180.0 }, duration: 4.4, delay: elapsed, eased: true)
        case .failed:
            return sampleLoop(values: [4.1, 6.0, 4.1].map { $0 * .pi / 180.0 }, duration: 5.8, delay: elapsed, eased: true)
        }
    }

    private static func baseDollSwingBY(for kind: WeatherKind, elapsed: CFTimeInterval) -> Double {
        switch kind {
        case .idle:
            return 0.0
        case .awaiting:
            return sampleLoop(values: [0.2, 1.5, 0.5, 1.2, 0.2], duration: 3.2, delay: elapsed, eased: true)
        case .done:
            return sampleLoop(values: [0.0, -0.8, 0.0], duration: 4.4, delay: elapsed, eased: true)
        case .failed:
            return 1.2
        }
    }

    private enum SegmentTiming {
        case linear, easeIn, easeOut, easeInEaseOut

        func evaluate(_ x: Double) -> Double {
            switch self {
            case .linear:        return x
            case .easeIn:        return cubicBezierY(forX: x, c1x: 0.42, c1y: 0.0, c2x: 1.0,  c2y: 1.0)
            case .easeOut:       return cubicBezierY(forX: x, c1x: 0.0,  c1y: 0.0, c2x: 0.58, c2y: 1.0)
            case .easeInEaseOut: return cubicBezierY(forX: x, c1x: 0.42, c1y: 0.0, c2x: 0.58, c2y: 1.0)
            }
        }

        private func cubicBezierY(forX x: Double, c1x: Double, c1y: Double, c2x: Double, c2y: Double) -> Double {
            let clamped = min(1.0, max(0.0, x))
            var s = clamped
            for _ in 0..<5 {
                let u = 1.0 - s
                let bx = 3.0 * u * u * s * c1x + 3.0 * u * s * s * c2x + s * s * s - clamped
                let dbx = 3.0 * u * u * c1x + 6.0 * u * s * (c2x - c1x) + 3.0 * s * s * (1.0 - c2x)
                guard abs(dbx) > 1e-6 else { break }
                s = min(1.0, max(0.0, s - bx / dbx))
            }
            let u = 1.0 - s
            return 3.0 * u * u * s * c1y + 3.0 * u * s * s * c2y + s * s * s
        }
    }

    private static func normalizedPhase(delay: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        var u = (delay / duration).truncatingRemainder(dividingBy: 1.0)
        if u < 0 { u += 1.0 }
        return u
    }

    private static func sampleLoop(values: [Double], duration: Double, delay: Double, eased: Bool) -> Double {
        guard values.count >= 2 else { return values.first ?? 0 }
        let keyTimes = values.indices.map { Double($0) / Double(values.count - 1) }
        let timings = Array(repeating: eased ? SegmentTiming.easeInEaseOut : .linear, count: values.count - 1)
        return sampleKeyframes(values: values, keyTimes: keyTimes, timings: timings, duration: duration, delay: delay)
    }

    private static func sampleKeyframes(
        values: [Double],
        keyTimes: [Double],
        timings: [SegmentTiming]?,
        duration: Double,
        delay: Double
    ) -> Double {
        guard values.count >= 2, values.count == keyTimes.count else { return values.first ?? 0 }
        let u = normalizedPhase(delay: delay, duration: duration)
        for index in 1..<keyTimes.count where u <= keyTimes[index] {
            let t0 = keyTimes[index - 1]
            let t1 = keyTimes[index]
            let span = t1 - t0
            let raw = span > 1e-9 ? (u - t0) / span : 0
            let timing = (timings != nil && index - 1 < timings!.count) ? timings![index - 1] : .linear
            let f = timing.evaluate(raw)
            return values[index - 1] + (values[index] - values[index - 1]) * f
        }
        return values.last ?? 0
    }

    // MARK: - Coarse 10-Minute Sky Period Timer & System Time Observers

    private func updateSkyTimer() {
        guard window != nil, clockOverride == nil else {
            stopSkyTimer()
            return
        }
        guard skyTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reevaluateSkyPeriod()
            }
        }
        timer.tolerance = 60
        skyTimer = timer
    }

    private func stopSkyTimer() {
        skyTimer?.invalidate()
        skyTimer = nil
    }

    private func startSystemTimeObservers() {
        guard !isObservingSystemTime else { return }
        isObservingSystemTime = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemTimeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemTimeNotification),
            name: .NSSystemClockDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemTimeNotification),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
    }

    private func stopSystemTimeObservers() {
        guard isObservingSystemTime else { return }
        isObservingSystemTime = false
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .NSSystemClockDidChange,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
    }

    @objc nonisolated private func handleSystemTimeNotification(_ notification: Notification) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.reevaluateSkyPeriod()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.reevaluateSkyPeriod()
            }
        }
    }

    private func transitionSkyPeriod(to nextPeriod: SkyPeriod) {
        skyPeriod = nextPeriod
        if hasActiveLoopAnimations {
            let cloudPhases = captureCloudPhases()
            let oldWash = timeWashLayer.presentation()?.colors ?? timeWashLayer.colors
            let fadeTargets = crossfadeStateLayers
            let oldOpacities = fadeTargets.map { $0.presentation()?.opacity ?? $0.opacity }
            let oldHaloTransform = moonlightGlow.presentation()?.transform ?? moonlightGlow.transform
            let wasHaloVisible = (moonlightGlow.presentation()?.opacity ?? moonlightGlow.opacity) > 0.01
            stopAllAnimations()
            refreshAppearanceAndColors(crossfadeDuration: nil)
            applyStaticPose()
            if wasHaloVisible && moonlightGlow.opacity == 0 {
                withoutActions {
                    moonlightGlow.transform = oldHaloTransform
                }
            }
            installAnimations(cloudPhases: cloudPhases)
            if let oldWash, let newWash = timeWashLayer.colors {
                addCrossfade(to: timeWashLayer, keyPath: "colors", from: oldWash, to: newWash, duration: 0.6)
            }
            for (target, oldOpacity) in zip(fadeTargets, oldOpacities) where abs(oldOpacity - target.opacity) > 0.01 {
                addCrossfade(to: target, keyPath: "opacity", from: oldOpacity, to: target.opacity, duration: 0.6)
            }
        } else {
            if isCurrentlyAnimating {
                stopAllAnimations()
            }
            refreshAppearanceAndColors(crossfadeDuration: nil)
            applyStaticPose()
            if requestedAnimating, window != nil, bounds.width > 0, bounds.height > 0 {
                if loopEpoch == 0 { loopEpoch = CACurrentMediaTime() }
                installAnimations(cloudPhases: pausedCloudPhases)
            }
        }
    }

    private func reevaluateSkyPeriod() {
        let nextPeriod = SkyPeriod.resolve(for: clockOverride ?? Date.now)
        guard nextPeriod != skyPeriod else { return }
        transitionSkyPeriod(to: nextPeriod)
    }

    private func handleClockOverrideChange() {
        updateSkyTimer()
        reevaluateSkyPeriod()
    }

    // MARK: - Retina Scale & Helpers

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        guard backingScale != scale else { return }
        backingScale = scale
        if let root = layer {
            withoutActions {
                applyContentsScaleRecursively(scale, to: root)
            }
        }
    }

    private func applyContentsScaleRecursively(_ scale: CGFloat, to target: CALayer) {
        target.contentsScale = scale
        if let mask = target.mask {
            applyContentsScaleRecursively(scale, to: mask)
        }
        if let sublayers = target.sublayers {
            for child in sublayers {
                applyContentsScaleRecursively(scale, to: child)
            }
        }
    }

    private static func intensityLevel(for weather: HeroWeather) -> Int {
        switch weather {
        case .idle: 0
        case .awaiting(let n): min(max(n, 1), 3)
        case .done(let n): min(max(n, 1), 3)
        case .failed(let n): min(max(n, 1), 4)
        }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private func srgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

// MARK: - SwiftUI Representable

struct PortholeWeatherCard: NSViewRepresentable {
    let weather: HeroWeather
    let animating: Bool
    let isGlass: Bool
    /// DEBUG demo only: pins the time-of-day sky.
    var clockOverride: Date? = nil

    func makeNSView(context: Context) -> PortholeWeatherView {
        let view = PortholeWeatherView(frame: CGRect(x: 0, y: 0, width: 260, height: PortholeLayout.height))
        view.configure(weather: weather, animating: animating, isGlass: isGlass, clockOverride: clockOverride)
        return view
    }

    func updateNSView(_ nsView: PortholeWeatherView, context: Context) {
        nsView.configure(weather: weather, animating: animating, isGlass: isGlass, clockOverride: clockOverride)
    }

    static func dismantleNSView(_ nsView: PortholeWeatherView, coordinator: ()) {
        nsView.apply(nsView.currentWeather, animating: false)
    }
}
