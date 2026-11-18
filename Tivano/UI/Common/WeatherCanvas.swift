import SwiftUI

struct WeatherCanvas: View {
    static let pulseDuration: TimeInterval = 7.3
    static let releaseDuration: TimeInterval = 0.95
    private static let fadeInDuration: TimeInterval = 1.05
    private static let holdEnd: TimeInterval = 5.55

    let kind: HeroWeather
    var pulseStart: Date? = nil
    var releaseStart: Date? = nil
    var holdsSteady: Bool = false
    var backdropOpacity: Double = 0.5
    var isPausedExternal: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var glassBoost: Double {
        1.0 + 0.40 * (1.0 - min(1.0, max(0.0, backdropOpacity / 0.55)))
    }

    private var isPaused: Bool {
        if isPausedExternal || kind == .idle { return true }
        if holdsSteady { return false }
        return !Self.isActive(at: Date.now, start: pulseStart, releaseStart: releaseStart)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { timeline in
            Canvas { context, size in
                let strength = holdsSteady ? (kind == .idle ? 0 : 1) : Self.strength(at: timeline.date, start: pulseStart, releaseStart: releaseStart)
                guard strength > 0, size.width > 0, size.height > 0 else { return }
                var ctx = context
                ctx.opacity = strength
                let time = timeline.date.timeIntervalSinceReferenceDate
                switch kind {
                case .idle:
                    break
                case .awaiting:
                    drawWind(in: ctx, size: size, time: time, entrance: strength)
                case .done:
                    drawSun(in: ctx, size: size, time: time, entrance: strength)
                case .failed:
                    drawRain(in: ctx, size: size, time: time, entrance: strength)
                }
            }
        }
        .clipped()
    }

    static func isActive(at date: Date, start: Date?, releaseStart: Date? = nil) -> Bool {
        guard let start else { return false }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed >= 0, elapsed < pulseDuration else { return false }
        if let releaseStart, date.timeIntervalSince(releaseStart) >= releaseDuration {
            return false
        }
        return true
    }

    static func strength(at date: Date, start: Date?, releaseStart: Date? = nil) -> Double {
        guard let start else { return 0 }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed > 0, elapsed < pulseDuration else { return 0 }

        let base: Double
        if elapsed < fadeInDuration {
            base = smoothStep(0, fadeInDuration, elapsed)
        } else if elapsed < holdEnd {
            base = 1.0
        } else {
            base = 1.0 - smoothStep(holdEnd, pulseDuration, elapsed)
        }

        if let releaseStart {
            return base * (1.0 - smoothStep(0, Self.releaseDuration, date.timeIntervalSince(releaseStart)))
        }
        return base
    }

    // MARK: - Static Deterministic Descriptors & Behind-Glass Optics

    private struct MistRibbon {
        let yNorm: Double
        let lift: Double
        let thickness: Double
        let ampPrimary: Double
        let ampSecondary: Double
        let speed: Double
        let phase: Double
        let focalWeight: Double
    }

    private struct Slipstream {
        let yNorm: Double
        let length: Double
        let maxWidth: Double
        let speed: Double
        let lift: Double
        let waveAmp: Double
        let offset: Double
        let phase: Double
        let readingSoftener: Double
    }

    private struct WindLeaf {
        let isSamara: Bool
        let startXNorm: Double
        let yNorm: Double
        let halfLength: Double
        let speed: Double
        let lift: Double
        let flutterAmp: Double
        let flutterFreq: Double
        let spinSpeed: Double
        let offset: Double
        let phase: Double
    }

    private struct WindBokeh {
        let startXNorm: Double
        let yNorm: Double
        let radius: Double
        let speed: Double
        let driftAmp: Double
        let shimmerSpeed: Double
        let offset: Double
        let phase: Double
    }

    private struct SunBeam {
        let baseAngle: Double
        let lengthRatio: Double
        let nearHalfWidth: Double
        let farSpread: Double
        let breathSpeed: Double
        let phase: Double
        let weight: Double
    }

    private struct SunHalo {
        let progress: Double
        let radius: Double
        let perpOffset: Double
        let fillOpacity: Double
        let isRose: Bool
        let phase: Double
    }

    private struct RainSheetBand {
        let laneOffset: Double
        let halfWidth: Double
        let speed: Double
        let slant: Double
        let verticalReach: Double
        let weight: Double
    }

    private struct RainThread {
        let isMid: Bool
        let laneNorm: Double
        let speed: Double
        let length: Double
        let slant: Double
        let offset: Double
    }

    private struct GroundRipple {
        let xNorm: Double
        let yInset: Double
        let maxRx: Double
        let rate: Double
        let phaseOffset: Double
        let splashLength: Double
    }

    private static func seeded(_ index: Int, _ salt: Double) -> Double {
        let raw = sin(Double(index) * 127.1 + salt * 311.7) * 43_758.5453123
        return raw - floor(raw)
    }

    private static func weightedX(_ index: Int, _ salt: Double, rightBias: Double = 0.74) -> Double {
        let gate = seeded(index, salt)
        let u = seeded(index, salt + 19.3)
        if gate < rightBias {
            return 0.24 + u * 0.74
        } else {
            return 0.02 + u * 0.22
        }
    }

    // Wind: 3 broad background mist ribbons in upper/mid pane (speed: 0.27...0.35)
    private static let mistRibbons: [MistRibbon] = [
        MistRibbon(yNorm: 0.11, lift: 44, thickness: 58, ampPrimary: 16, ampSecondary: 7, speed: 0.31, phase: 0.4, focalWeight: 1.00),
        MistRibbon(yNorm: 0.25, lift: 56, thickness: 72, ampPrimary: 20, ampSecondary: 8, speed: 0.27, phase: 2.1, focalWeight: 0.94),
        MistRibbon(yNorm: 0.41, lift: 48, thickness: 56, ampPrimary: 16, ampSecondary: 7, speed: 0.35, phase: 3.8, focalWeight: 0.78)
    ]

    // Wind: 9 slender, silky tapered S-curve wind streams (maxWidth: 3.2...6.8 pt; speed: 84...122 pt/s)
    private static let slipstreams: [Slipstream] = (0..<9).map { i in
        let yBands: [Double] = [0.08, 0.14, 0.20, 0.27, 0.34, 0.41, 0.48, 0.55, 0.62]
        let yNorm = yBands[i]
        let inReadingBand = yNorm >= 0.42
        let rawOffset = (Double(i) + 0.15 + seeded(i, 6) * 0.70) / 9.0
        return Slipstream(
            yNorm: yNorm,
            length: 240.0 + seeded(i, 1) * 170.0,
            maxWidth: 3.2 + seeded(i, 2) * 3.6,
            speed: 84.0 + seeded(i, 3) * 38.0,
            lift: 22.0 + seeded(i, 4) * 26.0,
            waveAmp: 8.5 + seeded(i, 5) * 10.0,
            offset: rawOffset - floor(rawOffset),
            phase: seeded(i, 7) * .pi * 2,
            readingSoftener: inReadingBand ? 0.52 : 1.0
        )
    }

    // Wind: 4 soft behind-glass botanical leaves (halfLength: 8.2...11.2; speed: 44...64 pt/s)
    private static let windLeaves: [WindLeaf] = (0..<4).map { i in
        let yBands: [Double] = [0.13, 0.25, 0.38, 0.54]
        let startXNorm = i == 0 ? 0.26 : (0.34 + seeded(i, 10) * 0.28)
        let rawOffset = (Double(i) + 0.15 + seeded(i, 17) * 0.70) / 4.0
        return WindLeaf(
            isSamara: i % 2 == 1,
            startXNorm: startXNorm,
            yNorm: yBands[i],
            halfLength: 8.2 + seeded(i, 11) * 3.0,
            speed: 44.0 + seeded(i, 12) * 20.0,
            lift: 22.0 + seeded(i, 13) * 24.0,
            flutterAmp: 8.0 + seeded(i, 14) * 8.0,
            flutterFreq: 0.58 + seeded(i, 15) * 0.26,
            spinSpeed: 1.05 + seeded(i, 16) * 0.37,
            offset: rawOffset - floor(rawOffset),
            phase: seeded(i, 18) * .pi * 2
        )
    }

    // Wind: 8 subtle soft air motes (radius: 2.0...4.2; speed: 54...80 pt/s)
    private static let windBokehs: [WindBokeh] = (0..<8).map { i in
        let yBands: [Double] = [0.10, 0.17, 0.25, 0.33, 0.42, 0.51, 0.61, 0.72]
        let startXNorm = 0.24 + seeded(i, 21) * 0.44
        let rawOffset = (Double(i) + 0.15 + seeded(i, 27) * 0.70) / 8.0
        return WindBokeh(
            startXNorm: startXNorm,
            yNorm: yBands[i],
            radius: 2.0 + seeded(i, 23) * 2.2,
            speed: 54.0 + seeded(i, 24) * 26.0,
            driftAmp: 6.0 + seeded(i, 25) * 9.0,
            shimmerSpeed: 0.48 + seeded(i, 26) * 0.34,
            offset: rawOffset - floor(rawOffset),
            phase: seeded(i, 28) * .pi * 2
        )
    }

    // Sun: 5 wide behind-glass sunBeams (lengthRatio: 0.46...0.72; breathSpeed: 0.22...0.32)
    private static let sunBeams: [SunBeam] = [
        SunBeam(baseAngle: 2.04, lengthRatio: 0.46, nearHalfWidth: 16, farSpread: 0.052, breathSpeed: 0.22, phase: 0.2, weight: 0.86),
        SunBeam(baseAngle: 2.20, lengthRatio: 0.58, nearHalfWidth: 20, farSpread: 0.062, breathSpeed: 0.28, phase: 1.4, weight: 0.96),
        SunBeam(baseAngle: 2.36, lengthRatio: 0.72, nearHalfWidth: 24, farSpread: 0.070, breathSpeed: 0.24, phase: 2.7, weight: 1.00),
        SunBeam(baseAngle: 2.52, lengthRatio: 0.64, nearHalfWidth: 19, farSpread: 0.060, breathSpeed: 0.32, phase: 4.0, weight: 0.90),
        SunBeam(baseAngle: 2.68, lengthRatio: 0.50, nearHalfWidth: 16, farSpread: 0.050, breathSpeed: 0.26, phase: 5.3, weight: 0.82)
    ]

    // Sun: 3 faint ringless bokeh halos (fillOpacity: 0.020...0.028)
    private static let sunHalos: [SunHalo] = [
        SunHalo(progress: 0.30, radius: 24, perpOffset: -4.0, fillOpacity: 0.028, isRose: false, phase: 0.5),
        SunHalo(progress: 0.56, radius: 38, perpOffset: 5.0, fillOpacity: 0.024, isRose: true, phase: 1.9),
        SunHalo(progress: 0.82, radius: 52, perpOffset: -3.5, fillOpacity: 0.020, isRose: false, phase: 3.4)
    ]

    // Rain: 3 broad slanted exterior rain-sheet mist bands (speed: 52...72 pt/s)
    private static let rainSheetBands: [RainSheetBand] = [
        RainSheetBand(laneOffset: 0.12, halfWidth: 96, speed: 52.0, slant: 9.4 * .pi / 180.0, verticalReach: 0.82, weight: 1.00),
        RainSheetBand(laneOffset: 0.47, halfWidth: 112, speed: 62.0, slant: 9.8 * .pi / 180.0, verticalReach: 0.88, weight: 0.92),
        RainSheetBand(laneOffset: 0.81, halfWidth: 88, speed: 72.0, slant: 10.2 * .pi / 180.0, verticalReach: 0.78, weight: 0.86)
    ]

    // Rain: 66 hairline-slender headless linear rain lines (42 far + 24 mid-behind-glass; slantDeg: 9.2...10.4)
    private static let rainThreads: [RainThread] = (0..<66).map { i in
        let isMid = i >= 42
        let planeIndex = isMid ? (i - 42) : i
        let planeCount = isMid ? 24 : 42
        let slantDeg = 9.2 + seeded(i, 41) * 1.2
        let rawOffset = (Double(planeIndex) + 0.15 + seeded(i, 46) * 0.70) / Double(planeCount)
        return RainThread(
            isMid: isMid,
            laneNorm: weightedX(i, 42, rightBias: 0.74),
            speed: isMid ? (415.0 + seeded(i, 43) * 80.0) : (320.0 + seeded(i, 43) * 75.0),
            length: isMid ? (46.0 + seeded(i, 44) * 24.0) : (34.0 + seeded(i, 44) * 20.0),
            slant: slantDeg * .pi / 180.0,
            offset: rawOffset - floor(rawOffset)
        )
    }

    private static let farRainThreads: [RainThread] = rainThreads.filter { !$0.isMid }
    private static let midRainThreads: [RainThread] = rainThreads.filter(\.isMid)

    // Rain: 14 perspective-foreshortened ground water-impact ripples across wet ground (xNorm: 0.25...0.96; yInset: 3.5...19.5 pt)
    private static let groundRipples: [GroundRipple] = (0..<14).map { i in
        let slot = (Double(i) + 0.15 + seeded(i, 61) * 0.70) / 14.0
        let yInset = 3.5 + seeded(i, 62) * 16.0
        let depthT = 1.0 - (yInset - 3.5) / 16.0
        let maxRx = 16.0 + (0.40 * depthT + 0.60 * seeded(i, 63)) * 18.0
        let rawPhase = Double(i) * 0.61803398875 + seeded(i, 65) * 0.18
        return GroundRipple(
            xNorm: 0.25 + slot * 0.71,
            yInset: yInset,
            maxRx: maxRx,
            rate: 0.44 + seeded(i, 64) * 0.22,
            phaseOffset: rawPhase - floor(rawPhase),
            splashLength: 4.2 + seeded(i, 66) * 3.4
        )
    }

    private static let splashAngles: [Double] = [-1.18, -1.57, -1.96]

    private static let unitLeafBody: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -1.02, y: 0.18))
        p.addCurve(
            to: CGPoint(x: 1.06, y: -0.16),
            control1: CGPoint(x: -0.42, y: -0.44),
            control2: CGPoint(x: 0.46, y: -0.42)
        )
        p.addCurve(
            to: CGPoint(x: -1.02, y: 0.18),
            control1: CGPoint(x: 0.52, y: 0.34),
            control2: CGPoint(x: -0.30, y: 0.52)
        )
        p.closeSubpath()
        return p
    }()

    private static let unitSamaraBody: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -0.95, y: 0.04))
        p.addCurve(
            to: CGPoint(x: 1.08, y: -0.10),
            control1: CGPoint(x: -0.45, y: -0.34),
            control2: CGPoint(x: 0.52, y: -0.36)
        )
        p.addCurve(
            to: CGPoint(x: -0.55, y: 0.20),
            control1: CGPoint(x: 0.92, y: 0.42),
            control2: CGPoint(x: 0.05, y: 0.56)
        )
        p.addCurve(
            to: CGPoint(x: -0.95, y: 0.04),
            control1: CGPoint(x: -0.76, y: 0.25),
            control2: CGPoint(x: -0.90, y: 0.18)
        )
        p.closeSubpath()
        return p
    }()

    private func fraction(_ value: Double) -> Double {
        value - floor(value)
    }

    private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    private static func smoothStep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1.0 : 0.0 }
        let t = min(1.0, max(0.0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    private func smoothStep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        Self.smoothStep(edge0, edge1, value)
    }

    /// Attenuates visual presence over the central/lower chat reading and composer zone (x: 0.26...0.78, y: 0.46...1.0).
    private func readingComposerWeight(xNorm: Double, yNorm: Double, minWeight: Double) -> Double {
        let xMask = smoothStep(0.19, 0.26, xNorm) * (1.0 - smoothStep(0.78, 0.85, xNorm))
        let yMask = smoothStep(0.39, 0.46, yNorm)
        return 1.0 - (1.0 - minWeight) * (xMask * yMask)
    }

    /// Subtle interior window-pane top sheen so the frosted glass optically sits in front of the exterior weather.
    private func drawGlassSurfaceVeil(in ctx: GraphicsContext, size: CGSize, isDark: Bool) {
        let w = Double(size.width)
        let veilHeight = Double(size.height) * 0.66
        let veilRect = Path(CGRect(x: 0, y: 0, width: w, height: veilHeight))
        let topAlpha = isDark ? 0.020 : 0.042
        ctx.fill(
            veilRect,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color.white.opacity(topAlpha), location: 0.0),
                    .init(color: Color.white.opacity(topAlpha * 0.38), location: 0.38),
                    .init(color: Color.white.opacity(topAlpha * 0.10), location: 0.72),
                    .init(color: .clear, location: 1.0)
                ]),
                startPoint: CGPoint(x: w * 0.5, y: 0),
                endPoint: CGPoint(x: w * 0.5, y: veilHeight)
            )
        )
    }

    // MARK: - 1. .awaiting -> Slender Behind-Glass Breeze

    private func drawWind(in ctx: GraphicsContext, size: CGSize, time: Double, entrance: Double) {
        let w = Double(size.width)
        let h = Double(size.height)
        let isDark = colorScheme == .dark
        let boost = glassBoost
        let settleLift = (1.0 - entrance) * 6.0

        // (a) Upper-right cool celadon ambient wash
        let washPeak = (isDark ? 0.060 : 0.072) * boost
        let breezeOrigin = CGPoint(x: w * 0.84, y: h * 0.12)
        let breezeRadius = max(w, h) * 0.62
        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: isDark ? rgb(0.46, 0.74, 0.72, washPeak) : rgb(0.28, 0.56, 0.60, washPeak), location: 0.0),
                    .init(color: isDark ? rgb(0.42, 0.68, 0.68, washPeak * 0.44) : rgb(0.32, 0.60, 0.64, washPeak * 0.44), location: 0.48),
                    .init(color: .clear, location: 1.0)
                ]),
                center: breezeOrigin,
                startRadius: 0,
                endRadius: breezeRadius
            )
        )

        // (b) 3 background mistRibbons in a single soft mist pass
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 24))
            let steps = 24
            let spanStart = -48.0
            let spanWidth = w + 96.0

            @inline(__always)
            func ribbonMetrics(_ s: Int, ribbon: MistRibbon, baseY: Double) -> (x: Double, centerY: Double, halfBand: Double) {
                let u = Double(s) / Double(steps)
                let x = spanStart + u * spanWidth
                let wave1 = sin(u * .pi * 2.1 - time * ribbon.speed + ribbon.phase) * ribbon.ampPrimary
                let wave2 = cos(u * .pi * 3.3 - time * ribbon.speed * 1.35 + ribbon.phase * 1.7) * ribbon.ampSecondary
                let centerY = baseY - u * ribbon.lift + wave1 + wave2
                let gust = 0.80 + 0.20 * sin(u * .pi * 2.4 - time * ribbon.speed * 1.3 + ribbon.phase)
                let halfBand = 0.5 * ribbon.thickness * (0.38 + 0.62 * sin(u * .pi)) * gust
                return (x, centerY, halfBand)
            }

            for ribbon in Self.mistRibbons {
                let baseY = ribbon.yNorm * h + settleLift
                var bandPath = Path()
                var corePath = Path()

                for s in 0...steps {
                    let m = ribbonMetrics(s, ribbon: ribbon, baseY: baseY)
                    let coreHalf = m.halfBand * 0.52
                    let outerPt = CGPoint(x: m.x, y: m.centerY - m.halfBand)
                    let corePt = CGPoint(x: m.x, y: m.centerY - coreHalf * 1.12)
                    if s == 0 {
                        bandPath.move(to: outerPt)
                        corePath.move(to: corePt)
                    } else {
                        bandPath.addLine(to: outerPt)
                        corePath.addLine(to: corePt)
                    }
                }
                for s in stride(from: steps, through: 0, by: -1) {
                    let m = ribbonMetrics(s, ribbon: ribbon, baseY: baseY)
                    let coreHalf = m.halfBand * 0.52
                    bandPath.addLine(to: CGPoint(x: m.x, y: m.centerY + m.halfBand))
                    corePath.addLine(to: CGPoint(x: m.x, y: m.centerY + coreHalf * 0.88))
                }
                bandPath.closeSubpath()
                corePath.closeSubpath()

                let fw = ribbon.focalWeight
                let basePeak = (isDark ? 0.085 : 0.105) * fw * boost
                let baseColor: (Double) -> Color = { alpha in
                    isDark ? rgb(0.64, 0.84, 0.82, alpha) : rgb(0.24, 0.48, 0.53, alpha)
                }

                layer.fill(
                    bandPath,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: baseColor(basePeak * 0.28), location: 0.0),
                            .init(color: baseColor(basePeak * 0.52), location: 0.28),
                            .init(color: baseColor(basePeak * 0.78), location: 0.50),
                            .init(color: baseColor(basePeak), location: 0.76),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: CGPoint(x: 0, y: baseY),
                        endPoint: CGPoint(x: w, y: baseY - ribbon.lift)
                    )
                )

                let whitePeak = (isDark ? 0.048 : 0.17) * fw * boost
                layer.fill(
                    corePath,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color.white.opacity(whitePeak * 0.24), location: 0.0),
                            .init(color: Color.white.opacity(whitePeak * 0.48), location: 0.30),
                            .init(color: Color.white.opacity(whitePeak), location: 0.72),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: CGPoint(x: 0, y: baseY),
                        endPoint: CGPoint(x: w, y: baseY - ribbon.lift)
                    )
                )
            }
        }

        // (c + d) Combined foreground breeze layer: 9 slipstreams + 8 air motes + 4 botanical leaves
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 2.0))
            let streamSteps = 32
            for stream in Self.slipstreams {
                let travel = w + stream.length * 1.9
                let startX = fraction(time * stream.speed / travel + stream.offset) * travel - stream.length * 0.95
                let endX = startX + stream.length
                guard endX > -24, startX < w + 24 else { continue }

                let baseY = stream.yNorm * h + sin(time * 0.36 + stream.phase) * 6.0 + settleLift * 0.6
                let midX = startX + stream.length * 0.5
                let midY = baseY - stream.lift * 0.5
                let leftRamp = min(1.0, max(0.0, (midX + 20.0) / max(1.0, w * 0.32)))
                let zoneSoftener = readingComposerWeight(
                    xNorm: midX / max(1.0, w),
                    yNorm: midY / max(1.0, h),
                    minWeight: 0.56
                )
                let spatialWeight = (0.38 + 0.62 * leftRamp) * min(stream.readingSoftener, zoneSoftener)
                let wavePhase = time * 0.58 + stream.phase

                @inline(__always)
                func streamMetrics(_ step: Int) -> (px: Double, py: Double, nx: Double, ny: Double, halfWidth: Double) {
                    let progress = Double(step) / Double(streamSteps)
                    let px = startX + progress * stream.length
                    let py = baseY - progress * stream.lift
                        + sin(progress * .pi * 1.85 + wavePhase) * stream.waveAmp
                        + cos(progress * .pi * 3.1 - wavePhase * 0.6) * (stream.waveAmp * 0.28)

                    let dx = stream.length
                    let dy = -stream.lift
                        + cos(progress * .pi * 1.85 + wavePhase) * (.pi * 1.85 * stream.waveAmp)
                        - sin(progress * .pi * 3.1 - wavePhase * 0.6) * (.pi * 3.1 * stream.waveAmp * 0.28)
                    let invLen = 1.0 / max(0.001, hypot(dx, dy))
                    let nx = -dy * invLen
                    let ny = dx * invLen
                    let halfWidth = 0.5 * stream.maxWidth * pow(sin(progress * .pi), 1.22)
                    return (px, py, nx, ny, halfWidth)
                }

                var poly = Path()
                var innerPoly = Path()

                for step in 0...streamSteps {
                    let m = streamMetrics(step)
                    let upperPt = CGPoint(x: m.px + m.nx * m.halfWidth, y: m.py + m.ny * m.halfWidth)
                    if step == 0 {
                        poly.move(to: upperPt)
                    } else {
                        poly.addLine(to: upperPt)
                    }
                    if !isDark {
                        let innerHalf = 0.45 * m.halfWidth
                        let innerUpperPt = CGPoint(x: m.px + m.nx * innerHalf, y: m.py + m.ny * innerHalf)
                        if step == 0 {
                            innerPoly.move(to: innerUpperPt)
                        } else {
                            innerPoly.addLine(to: innerUpperPt)
                        }
                    }
                }
                for step in stride(from: streamSteps, through: 0, by: -1) {
                    let m = streamMetrics(step)
                    poly.addLine(to: CGPoint(x: m.px - m.nx * m.halfWidth, y: m.py - m.ny * m.halfWidth))
                    if !isDark {
                        let innerHalf = 0.45 * m.halfWidth
                        innerPoly.addLine(to: CGPoint(x: m.px - m.nx * innerHalf, y: m.py - m.ny * innerHalf))
                    }
                }
                poly.closeSubpath()

                let tintColor = isDark
                    ? rgb(0.62, 0.86, 0.83, 0.15 * spatialWeight * boost)
                    : rgb(0.20, 0.45, 0.52, 0.13 * spatialWeight * boost)
                let coreColor = isDark
                    ? rgb(0.88, 0.98, 0.96, 0.26 * spatialWeight * boost)
                    : rgb(0.20, 0.45, 0.52, 0.22 * spatialWeight * boost)

                let gradStart = CGPoint(x: startX, y: baseY)
                let gradEnd = CGPoint(x: endX, y: baseY - stream.lift)

                layer.fill(
                    poly,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: tintColor, location: 0.24),
                            .init(color: coreColor, location: 0.54),
                            .init(color: tintColor, location: 0.82),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: gradStart,
                        endPoint: gradEnd
                    )
                )

                if !isDark {
                    innerPoly.closeSubpath()
                    let innerPeak = 0.30 * spatialWeight * boost
                    layer.fill(
                        innerPoly,
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: Color.white.opacity(innerPeak * 0.55), location: 0.24),
                                .init(color: Color.white.opacity(innerPeak), location: 0.54),
                                .init(color: Color.white.opacity(innerPeak * 0.55), location: 0.82),
                                .init(color: .clear, location: 1.0)
                            ]),
                            startPoint: gradStart,
                            endPoint: gradEnd
                        )
                    )
                }
            }

            for bokeh in Self.windBokehs {
                let startX = bokeh.startXNorm * w
                let span = (w + 42.0) - startX
                let u = fraction(time * bokeh.speed / max(140.0, span) + bokeh.offset)
                let x = startX + u * span
                let y = bokeh.yNorm * h - u * 24.0 + sin(time * 0.48 + bokeh.phase) * bokeh.driftAmp
                let edgeFade = min(1.0, min(u / 0.16, (1.0 - u) / 0.14))
                let shimmer = (0.64 + 0.36 * sin(time * bokeh.shimmerSpeed + bokeh.phase)) * edgeFade
                let zoneWeight = readingComposerWeight(
                    xNorm: x / max(1.0, w),
                    yNorm: y / max(1.0, h),
                    minWeight: 0.50
                )
                let weight = shimmer * zoneWeight
                guard weight > 0.02 else { continue }

                let r = bokeh.radius
                let center = CGPoint(x: x, y: y)
                let rect = CGRect(x: x - r, y: y - r, width: r * 2.0, height: r * 2.0)
                let peakAlpha = (isDark ? 0.16 : 0.22) * weight * boost
                let midColor = isDark
                    ? rgb(0.66, 0.86, 0.83, peakAlpha * 0.58)
                    : rgb(0.24, 0.50, 0.56, peakAlpha * 0.62)

                layer.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: isDark ? rgb(0.86, 0.97, 0.95, peakAlpha) : rgb(0.20, 0.46, 0.53, peakAlpha), location: 0.0),
                            .init(color: midColor, location: 0.56),
                            .init(color: .clear, location: 1.0)
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: r
                    )
                )
            }

            for leaf in Self.windLeaves {
                let startX = leaf.startXNorm * w
                let span = (w + 48.0) - startX
                let u = fraction(time * leaf.speed / max(160.0, span) + leaf.offset)
                let x = startX + u * span
                let waveY = sin(time * leaf.flutterFreq + leaf.phase) * leaf.flutterAmp
                    + sin(time * (leaf.flutterFreq * 1.7) + leaf.phase * 1.4) * 3.0
                let y = leaf.yNorm * h - u * leaf.lift + waveY + settleLift * 0.5

                let fadeIn = min(1.0, u / 0.16)
                let fadeOut = min(1.0, (1.0 - u) / 0.12)
                let zoneWeight = readingComposerWeight(
                    xNorm: x / max(1.0, w),
                    yNorm: y / max(1.0, h),
                    minWeight: 0.50
                )
                let envelope = max(0.0, min(fadeIn, fadeOut)) * zoneWeight
                guard envelope > 0.01 else { continue }

                let heading = -0.32
                    + sin(time * (leaf.spinSpeed * 0.52) + leaf.phase) * 0.54
                    + cos(u * .pi * 2.0 + leaf.phase) * 0.18
                let bank = cos(time * leaf.spinSpeed + leaf.phase)
                let minorScale = 0.28 + 0.72 * abs(bank)
                let bodyTransform = CGAffineTransform(translationX: x, y: y)
                    .rotated(by: heading)
                    .scaledBy(x: leaf.halfLength, y: leaf.halfLength * minorScale)

                let unitBody = leaf.isSamara ? Self.unitSamaraBody : Self.unitLeafBody
                let bodyPath = unitBody.applying(bodyTransform)
                let sageAlpha = (isDark ? 0.22 : 0.27) * envelope * boost
                let sageFill = isDark
                    ? rgb(0.54, 0.76, 0.65, sageAlpha)
                    : rgb(0.28, 0.52, 0.40, sageAlpha)

                layer.fill(bodyPath, with: .color(sageFill))
            }
        }

        drawGlassSurfaceVeil(in: ctx, size: size, isDark: isDark)
    }

    // MARK: - 2. .done -> Quiet Behind-Glass Sunlight

    private func drawSun(in ctx: GraphicsContext, size: CGSize, time: Double, entrance: Double) {
        let w = Double(size.width)
        let h = Double(size.height)
        let isDark = colorScheme == .dark
        let sunBoost = 1.0 + 0.24 * (glassBoost - 1.0)
        let ox = w * 0.90
        let oy = -h * 0.04 + (1.0 - entrance) * 10.0
        let origin = CGPoint(x: ox, y: oy)
        let endRadius = max(w, h) * 0.60
        let breath = 1.0 + 0.028 * sin(time * 0.28)
        let fullWindow = Path(CGRect(origin: .zero, size: size))

        // (a) Soft corner radial warmth scaled gently by sunBoost
        ctx.fill(
            fullWindow,
            with: .radialGradient(
                Gradient(stops: isDark ? [
                    .init(color: rgb(1.0, 0.83, 0.54, 0.095 * sunBoost), location: 0.0),
                    .init(color: rgb(0.98, 0.75, 0.42, 0.050 * sunBoost), location: 0.32),
                    .init(color: rgb(0.96, 0.68, 0.36, 0.022 * sunBoost), location: 0.62),
                    .init(color: .clear, location: 1.0)
                ] : [
                    .init(color: rgb(1.0, 0.76, 0.32, 0.105 * sunBoost), location: 0.0),
                    .init(color: rgb(1.0, 0.80, 0.40, 0.058 * sunBoost), location: 0.32),
                    .init(color: rgb(1.0, 0.85, 0.48, 0.024 * sunBoost), location: 0.62),
                    .init(color: .clear, location: 1.0)
                ]),
                center: origin,
                startRadius: 0,
                endRadius: endRadius * breath
            )
        )

        // Soft behind-glass source bloom drawn directly with widened radial falloff
        let bloomRadius = 235.0 * breath
        let bloomRect = CGRect(
            x: ox - bloomRadius,
            y: oy - bloomRadius,
            width: bloomRadius * 2.0,
            height: bloomRadius * 2.0
        )
        ctx.fill(
            Path(ellipseIn: bloomRect),
            with: .radialGradient(
                Gradient(stops: isDark ? [
                    .init(color: rgb(1.0, 0.95, 0.84, 0.16 * sunBoost), location: 0.0),
                    .init(color: rgb(1.0, 0.88, 0.64, 0.064 * sunBoost), location: 0.46),
                    .init(color: .clear, location: 1.0)
                ] : [
                    .init(color: rgb(1.0, 0.97, 0.88, 0.22 * sunBoost), location: 0.0),
                    .init(color: rgb(1.0, 0.91, 0.68, 0.088 * sunBoost), location: 0.46),
                    .init(color: .clear, location: 1.0)
                ]),
                center: origin,
                startRadius: 0,
                endRadius: bloomRadius
            )
        )

        // (b + c) 5 wide sunBeams and 3 faint ringless bokeh halos in one soft behind-glass pass
        let diag = hypot(w, h)
        let axisDX = w * 0.52 - ox
        let axisDY = h * 0.36 - oy
        let axisLen = max(1.0, hypot(axisDX, axisDY))
        let perpX = -axisDY / axisLen
        let perpY = axisDX / axisLen

        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 22))
            for beam in Self.sunBeams {
                let phase = beam.phase
                let angle = beam.baseAngle + sin(time * 0.22 + phase) * 0.016
                let pulse = 0.88 + 0.12 * sin(time * beam.breathSpeed + phase * 1.3)
                let length = beam.lengthRatio * diag * (0.95 + 0.05 * entrance)

                let ux = cos(angle)
                let uy = sin(angle)
                let nx = -uy
                let ny = ux

                let nearHalf = beam.nearHalfWidth
                let farHalf = nearHalf + sin(beam.farSpread) * length

                var wedge = Path()
                wedge.move(to: CGPoint(x: ox + nx * nearHalf, y: oy + ny * nearHalf))
                wedge.addLine(to: CGPoint(x: ox + ux * length + nx * farHalf, y: oy + uy * length + ny * farHalf))
                wedge.addLine(to: CGPoint(x: ox + ux * length - nx * farHalf, y: oy + uy * length - ny * farHalf))
                wedge.addLine(to: CGPoint(x: ox - nx * nearHalf, y: oy - ny * nearHalf))
                wedge.closeSubpath()

                let peak = (isDark ? 0.095 : 0.135) * beam.weight * pulse * sunBoost
                let originColor = isDark ? rgb(1.0, 0.94, 0.82, peak * 0.68) : rgb(1.0, 0.86, 0.48, peak * 0.72)
                let headColor = isDark ? rgb(1.0, 0.94, 0.82, peak) : rgb(0.99, 0.78, 0.30, peak)
                let midColor = isDark ? rgb(1.0, 0.85, 0.56, peak * 0.40) : rgb(0.99, 0.74, 0.24, peak * 0.46)
                let tailColor = isDark ? rgb(0.98, 0.76, 0.44, peak * 0.10) : rgb(0.98, 0.70, 0.22, peak * 0.12)

                layer.fill(
                    wedge,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: originColor, location: 0.0),
                            .init(color: headColor, location: 0.14),
                            .init(color: midColor, location: 0.44),
                            .init(color: tailColor, location: 0.74),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: origin,
                        endPoint: CGPoint(x: ox + ux * length, y: oy + uy * length)
                    )
                )
            }

            for halo in Self.sunHalos {
                let drift = sin(time * 0.22 + halo.phase) * 3.5
                let cx = ox + axisDX * halo.progress + perpX * (halo.perpOffset + drift)
                let cy = oy + axisDY * halo.progress + perpY * (halo.perpOffset + drift)
                let zoneWeight = readingComposerWeight(
                    xNorm: cx / max(1.0, w),
                    yNorm: cy / max(1.0, h),
                    minWeight: 0.35
                )
                let fillAlpha = halo.fillOpacity * zoneWeight * sunBoost
                let r = halo.radius
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2.0, height: r * 2.0)

                let tint: (Double) -> Color = { alpha in
                    if halo.isRose {
                        return isDark ? rgb(1.0, 0.82, 0.84, alpha) : rgb(0.94, 0.66, 0.70, alpha)
                    } else {
                        return isDark ? rgb(1.0, 0.90, 0.68, alpha) : rgb(0.98, 0.76, 0.34, alpha)
                    }
                }

                layer.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: tint(fillAlpha), location: 0.0),
                            .init(color: tint(fillAlpha * 0.70), location: 0.64),
                            .init(color: .clear, location: 1.0)
                        ]),
                        center: CGPoint(x: cx, y: cy),
                        startRadius: 0,
                        endRadius: r
                    )
                )
            }
        }

        drawGlassSurfaceVeil(in: ctx, size: size, isDark: isDark)
    }

    // MARK: - 3. .failed -> Slender Behind-Glass Rain & Wet Ground

    private func drawRain(in ctx: GraphicsContext, size: CGSize, time: Double, entrance: Double) {
        let w = Double(size.width)
        let h = Double(size.height)
        let isDark = colorScheme == .dark
        let boost = glassBoost
        let settleOffset = (1.0 - entrance) * 4.0

        // (a) Upper rainy-sky wash with smooth asymptotic fade
        let washHeight = h * 0.58
        let washPeak = (isDark ? 0.105 : 0.118) * boost
        let washRect = Path(CGRect(x: 0, y: 0, width: w, height: washHeight))
        ctx.fill(
            washRect,
            with: .linearGradient(
                Gradient(stops: isDark ? [
                    .init(color: rgb(0.38, 0.54, 0.72, washPeak), location: 0.0),
                    .init(color: rgb(0.36, 0.52, 0.70, washPeak * 0.40), location: 0.40),
                    .init(color: rgb(0.36, 0.52, 0.70, washPeak * 0.10), location: 0.74),
                    .init(color: .clear, location: 1.0)
                ] : [
                    .init(color: rgb(0.24, 0.39, 0.56, washPeak), location: 0.0),
                    .init(color: rgb(0.32, 0.48, 0.64, washPeak * 0.40), location: 0.40),
                    .init(color: rgb(0.32, 0.48, 0.64, washPeak * 0.10), location: 0.74),
                    .init(color: .clear, location: 1.0)
                ]),
                startPoint: CGPoint(x: w * 0.60, y: 0),
                endPoint: CGPoint(x: w * 0.60, y: washHeight)
            )
        )

        // (a-2 + c) Combined background rain-sheet mist bands + wet-ground mist reflection
        let groundPeak = (isDark ? 0.078 : 0.088) * boost
        let groundTint: (Double) -> Color = { alpha in
            isDark ? rgb(0.56, 0.74, 0.92, alpha) : rgb(0.22, 0.38, 0.56, alpha)
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 19))
            let sheetSpan = w + 360.0
            for sheet in Self.rainSheetBands {
                let drift = fraction(time * sheet.speed / sheetSpan + sheet.laneOffset)
                let topX = (w + 180.0) - drift * sheetSpan
                let topY = -36.0 + settleOffset
                let reachY = h * sheet.verticalReach
                let botX = topX - (reachY - topY) * tan(sheet.slant)
                let midX = 0.5 * (topX + botX)

                let edgeEnvelope = min(1.0, min(drift / 0.14, (1.0 - drift) / 0.14))
                let zoneWeight = readingComposerWeight(
                    xNorm: midX / max(1.0, w),
                    yNorm: 0.52,
                    minWeight: 0.38
                )
                let peakAlpha = (isDark ? 0.062 : 0.075) * sheet.weight * edgeEnvelope * zoneWeight * boost
                guard peakAlpha > 0.003 else { continue }

                let nx = cos(sheet.slant) * sheet.halfWidth
                let ny = sin(sheet.slant) * sheet.halfWidth

                var band = Path()
                band.move(to: CGPoint(x: topX - nx, y: topY - ny))
                band.addLine(to: CGPoint(x: topX + nx, y: topY + ny))
                band.addLine(to: CGPoint(x: botX + nx, y: reachY + ny))
                band.addLine(to: CGPoint(x: botX - nx, y: reachY - ny))
                band.closeSubpath()

                let sheetColor: (Double) -> Color = { alpha in
                    isDark ? rgb(0.58, 0.74, 0.90, alpha) : rgb(0.26, 0.42, 0.58, alpha)
                }

                layer.fill(
                    band,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: sheetColor(peakAlpha * 0.52), location: 0.0),
                            .init(color: sheetColor(peakAlpha), location: 0.24),
                            .init(color: sheetColor(peakAlpha * 0.46), location: 0.62),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: CGPoint(x: topX, y: topY),
                        endPoint: CGPoint(x: botX, y: reachY)
                    )
                )
            }

            let puddleRect = CGRect(x: w * 0.18, y: h * 0.88, width: w * 0.86, height: h * 0.22)
            layer.fill(
                Path(ellipseIn: puddleRect),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: groundTint(groundPeak * 0.34), location: 0.36),
                        .init(color: groundTint(groundPeak), location: 0.62),
                        .init(color: groundTint(groundPeak), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: w * 0.61, y: h * 0.88),
                    endPoint: CGPoint(x: w * 0.61, y: h * 1.02)
                )
            )
        }

        // (b) 66 hairline-slender headless linear rain lines across far and mid-behind-glass planes
        drawRainThreadPlane(
            in: ctx,
            size: size,
            time: time,
            isDark: isDark,
            threads: Self.farRainThreads,
            isMidPlane: false,
            lineWidth: 1.25,
            basePeakAlpha: (isDark ? 0.26 : 0.32) * (0.68 / 1.25) * boost
        )
        drawRainThreadPlane(
            in: ctx,
            size: size,
            time: time,
            isDark: isDark,
            threads: Self.midRainThreads,
            isMidPlane: true,
            lineWidth: 1.08,
            basePeakAlpha: (isDark ? 0.36 : 0.44) * (0.88 / 1.08) * boost
        )

        // (d) 14 perspective-foreshortened ground water-impact ripples & micro-splash mist ticks
        drawGroundRipples(in: ctx, size: size, time: time, isDark: isDark, boost: boost)

        drawGlassSurfaceVeil(in: ctx, size: size, isDark: isDark)
    }

    private func drawRainThreadPlane(
        in ctx: GraphicsContext,
        size: CGSize,
        time: Double,
        isDark: Bool,
        threads: [RainThread],
        isMidPlane: Bool,
        lineWidth: Double,
        basePeakAlpha: Double
    ) {
        guard basePeakAlpha > 0.004 else { return }
        let w = Double(size.width)
        let h = Double(size.height)
        let margin = 48.0
        let travelY = h + margin * 2.0
        let strokeStyle = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        let highlightStrokeStyle = StrokeStyle(lineWidth: 0.68, lineCap: .round)

        let threadColor: (Double) -> Color = { a in
            isDark ? rgb(0.72, 0.86, 0.98, a) : rgb(0.20, 0.36, 0.54, a)
        }
        let threadGradient = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: threadColor(basePeakAlpha * 0.42), location: 0.24),
            .init(color: threadColor(basePeakAlpha), location: 0.64),
            .init(color: threadColor(basePeakAlpha * 0.52), location: 0.90),
            .init(color: .clear, location: 1.0)
        ])
        let highlightPeak = basePeakAlpha * 0.62
        let highlightGradient: Gradient? = (isMidPlane && !isDark)
            ? Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Color.white.opacity(highlightPeak * 0.42), location: 0.24),
                .init(color: Color.white.opacity(highlightPeak), location: 0.64),
                .init(color: Color.white.opacity(highlightPeak * 0.52), location: 0.90),
                .init(color: .clear, location: 1.0)
            ])
            : nil

        for thread in threads {
            let tanSlant = tan(thread.slant)
            let driftSpan = tanSlant * travelY
            let spawnWidth = w + driftSpan + margin * 2.0
            let progress = fraction(time * thread.speed / travelY + thread.offset)
            let midY = progress * travelY - margin
            let midX = thread.laneNorm * spawnWidth - margin - (midY + margin) * tanSlant
            guard midX > -48, midX < w + 48, midY > -48, midY < h + 48 else { continue }

            let xNorm = midX / max(1.0, w)
            let yNorm = midY / max(1.0, h)

            // Soften across central prose + composer box (x: 0.25...0.78, y: 0.36...0.91 -> minWeight: 0.42),
            // while keeping open upper glass, outer right pane, and bottom ground impact crisp
            let proseX = smoothStep(0.19, 0.25, xNorm) * (1.0 - smoothStep(0.78, 0.84, xNorm))
            let proseY = smoothStep(0.29, 0.36, yNorm) * (1.0 - smoothStep(0.91, 0.96, yNorm))
            let proseFactor = 1.0 - (1.0 - 0.42) * (proseX * proseY)

            let alpha = basePeakAlpha * proseFactor
            guard alpha > 0.004 else { continue }

            let ux = -sin(thread.slant)
            let uy = cos(thread.slant)
            let halfLen = thread.length * 0.5
            let startPt = CGPoint(x: midX - ux * halfLen, y: midY - uy * halfLen)
            let endPt = CGPoint(x: midX + ux * halfLen, y: midY + uy * halfLen)

            var line = Path()
            line.move(to: startPt)
            line.addLine(to: endPt)

            var threadCtx = ctx
            threadCtx.opacity *= proseFactor
            threadCtx.stroke(
                line,
                with: .linearGradient(threadGradient, startPoint: startPt, endPoint: endPt),
                style: strokeStyle
            )

            if let highlightGradient {
                let highlightStart = CGPoint(x: startPt.x + 0.6, y: startPt.y)
                let highlightEnd = CGPoint(x: endPt.x + 0.6, y: endPt.y)
                var highlightLine = Path()
                highlightLine.move(to: highlightStart)
                highlightLine.addLine(to: highlightEnd)

                threadCtx.stroke(
                    highlightLine,
                    with: .linearGradient(highlightGradient, startPoint: highlightStart, endPoint: highlightEnd),
                    style: highlightStrokeStyle
                )
            }
        }
    }

    private func drawGroundRipples(
        in ctx: GraphicsContext,
        size: CGSize,
        time: Double,
        isDark: Bool,
        boost: Double
    ) {
        let w = Double(size.width)
        let h = Double(size.height)
        let primaryStyle = StrokeStyle(lineWidth: 0.92)
        let echoStyle = StrokeStyle(lineWidth: 0.72)
        let splashStyle = StrokeStyle(lineWidth: 0.82, lineCap: .round)

        let basePrimary = (isDark ? 0.34 : 0.38) * 0.66 * boost
        let ringColor: (Double) -> Color = { a in
            isDark ? rgb(0.82, 0.92, 1.0, a) : rgb(0.20, 0.37, 0.55, a)
        }
        // Fade left/right tips to clear so grazing-angle water rings read as delicate front/back specular arcs, never closed O-rings
        let arcGrad = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: ringColor(basePrimary * 0.72), location: 0.20),
            .init(color: ringColor(basePrimary), location: 0.50),
            .init(color: ringColor(basePrimary * 0.72), location: 0.80),
            .init(color: .clear, location: 1.0)
        ])
        let baseRim = basePrimary * 0.68
        let rimGrad: Gradient? = !isDark
            ? Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Color.white.opacity(baseRim * 0.70), location: 0.22),
                .init(color: Color.white.opacity(baseRim), location: 0.50),
                .init(color: Color.white.opacity(baseRim * 0.70), location: 0.78),
                .init(color: .clear, location: 1.0)
            ])
            : nil
        let baseEcho = basePrimary * 0.50
        let echoGrad = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: ringColor(baseEcho), location: 0.50),
            .init(color: .clear, location: 1.0)
        ])

        let baseTick = (isDark ? 0.38 : 0.42) * 0.66 * boost
        let glintGrad = Gradient(stops: [
            .init(color: isDark ? Color.white.opacity(baseTick * 0.72) : rgb(0.22, 0.40, 0.58, baseTick * 0.65), location: 0.0),
            .init(color: .clear, location: 1.0)
        ])
        let tickColor: (Double) -> Color = { a in
            isDark ? rgb(0.86, 0.94, 1.0, a) : rgb(0.20, 0.37, 0.55, a)
        }
        let tickGrad = Gradient(stops: [
            .init(color: tickColor(baseTick), location: 0.0),
            .init(color: tickColor(baseTick * 0.48), location: 0.54),
            .init(color: .clear, location: 1.0)
        ])

        for ripple in Self.groundRipples {
            let rawCycle = fraction(time * ripple.rate + ripple.phaseOffset)
            // Active for 56% of cycle so ~7-8 organic splashes bloom asynchronously instead of a static row
            guard rawCycle < 0.56 else { continue }
            let p = rawCycle / 0.56
            let cx = ripple.xNorm * w
            let cy = h - ripple.yInset

            let rx = ripple.maxRx * (0.08 + 0.92 * pow(p, 0.68))
            let ry = rx * 0.115
            let fade = smoothStep(0.0, 0.10, p) * pow(1.0 - p, 1.75)
            let primaryAlpha = basePrimary * fade

            if primaryAlpha > 0.004 {
                var ringCtx = ctx
                ringCtx.opacity *= fade

                let primaryRect = CGRect(x: cx - rx, y: cy - ry, width: rx * 2.0, height: ry * 2.0)
                let primaryPath = Path(ellipseIn: primaryRect)
                ringCtx.stroke(
                    primaryPath,
                    with: .linearGradient(arcGrad, startPoint: CGPoint(x: cx - rx, y: cy), endPoint: CGPoint(x: cx + rx, y: cy)),
                    style: primaryStyle
                )

                if let rimGrad {
                    let rimPath = Path(ellipseIn: primaryRect.offsetBy(dx: 0, dy: -0.4))
                    ringCtx.stroke(
                        rimPath,
                        with: .linearGradient(rimGrad, startPoint: CGPoint(x: cx - rx, y: cy), endPoint: CGPoint(x: cx + rx, y: cy)),
                        style: echoStyle
                    )
                }

                if p > 0.18 {
                    let echoRamp = smoothStep(0.18, 0.28, p)
                    let echoAlpha = primaryAlpha * 0.50 * echoRamp
                    if echoAlpha > 0.004 {
                        var echoCtx = ringCtx
                        echoCtx.opacity *= echoRamp
                        let echoRx = 0.50 * rx
                        let echoRy = echoRx * 0.115
                        let echoPath = Path(ellipseIn: CGRect(x: cx - echoRx, y: cy - echoRy, width: echoRx * 2.0, height: echoRy * 2.0))
                        echoCtx.stroke(
                            echoPath,
                            with: .linearGradient(echoGrad, startPoint: CGPoint(x: cx - echoRx, y: cy), endPoint: CGPoint(x: cx + echoRx, y: cy)),
                            style: echoStyle
                        )
                    }
                }
            }

            // Brief wet-surface impact glint + fine upward rebound spray at initial contact (p < 0.22)
            if p < 0.22 {
                let splashProgress = p / 0.22
                let splashEnvelope = sin(splashProgress * .pi)
                let tickAlpha = baseTick * splashEnvelope
                if tickAlpha > 0.004 {
                    var splashCtx = ctx
                    splashCtx.opacity *= splashEnvelope

                    let glintRx = 5.5 * (0.5 + 0.5 * splashProgress)
                    let glintRy = 1.15
                    let glintRect = CGRect(x: cx - glintRx, y: cy - glintRy, width: glintRx * 2.0, height: glintRy * 2.0)
                    splashCtx.fill(
                        Path(ellipseIn: glintRect),
                        with: .radialGradient(
                            glintGrad,
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: glintRx
                        )
                    )

                    let baseLift = splashProgress * 1.6
                    let activeLen = ripple.splashLength * (0.45 + 0.55 * sin(min(1.0, splashProgress * 1.35) * .pi * 0.5))

                    for (idx, theta) in Self.splashAngles.enumerated() {
                        let lenScale = idx == 1 ? 1.18 : 0.88
                        let dx = cos(theta)
                        let dy = sin(theta)
                        let startPt = CGPoint(x: cx + dx * baseLift, y: cy + dy * baseLift)
                        let endPt = CGPoint(x: cx + dx * (baseLift + activeLen * lenScale), y: cy + dy * (baseLift + activeLen * lenScale))

                        var tick = Path()
                        tick.move(to: startPt)
                        tick.addLine(to: endPt)

                        splashCtx.stroke(
                            tick,
                            with: .linearGradient(tickGrad, startPoint: startPt, endPoint: endPt),
                            style: splashStyle
                        )
                    }
                }
            }
        }
    }
}
