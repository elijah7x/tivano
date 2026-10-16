// Ported from Zeron (https://github.com/zeronsh/zeron, MIT), crates/orb and crates/ui/src/orb,
// itself extracted from Bezel (clearloop, MIT), a port of gpui-thinking-orbs (MIT), a port of
// Jakub Antalik's thinking-orbs (MIT). See THIRD_PARTY_NOTICES.md.
//
// Backend-agnostic animation engine (engine/mod.rs plus every mode painter). One engine per
// orb: it owns the scratch the Rust kept in thread-locals (topology caches, Rubik move tables,
// the web's nodes and edges, the morph outline), so it is not shared across threads.

import Foundation

final class OrbEngine {
    let topology = OrbTopologyCache()

    // Rubik scratch, reused every frame so Solving is allocation-free in steady state.
    private var moves: [RubikMove] = []
    private var amounts: [Float] = []
    // Web scratch: (unit x, y, z, projected x, y, z) per node, and the accepted edges.
    private var nodes: [WebNode] = []
    private var edges: [(Int, Int)] = []
    // Morph scratch.
    private var morphPoints: [SIMD2<Float>] = Array(repeating: .zero, count: OrbMorph.samples)
    private var morphLengths: [Float] = Array(repeating: 0, count: OrbMorph.samples)

    init() {}

    /// Paint one frame for arbitrary options. `size` and every count-like field are
    /// sanitized (finite + hard ceilings) before geometry runs.
    func draw(mode: OrbModeKey, size: Float, t: Float, opts: OrbModeOpts, into out: inout OrbFrame) {
        let size = OrbProfiles.sanitizeSize(size)
        let opts = OrbProfiles.sanitize(opts)
        let t: Float = t.isFinite ? t : 0.0
        drawResolved(mode: mode, size: size, t: t, opts: opts, into: &out)
    }

    /// Fast path for already-sanitized, size-bounded presets (`OrbResolved`).
    func drawResolved(mode: OrbModeKey, size: Float, t: Float, opts: OrbModeOpts, into out: inout OrbFrame) {
        out.clear()
        switch mode {
        case .orbits: drawOrbits(size, t, opts, &out)
        case .globe: drawGlobe(size, t, opts, &out)
        case .rubik: drawRubik(size, t, opts, &out)
        case .wave: drawWave(size, t, opts, &out)
        case .web: drawWeb(size, t, opts, &out)
        case .braid: drawBraid(size, t, opts, &out)
        case .ribbon, .ring: drawRibbon(size, t, opts, &out)
        case .morph: drawMorph(size, t, opts, &out)
        case .focus: drawFocus(size, t, opts, &out)
        case .gyroscope: drawGyroscope(size, t, opts, &out)
        case .echo: drawEcho(size, t, opts, &out)
        }
        // Face-on modes emit z = 0 in painter order, so a sort cannot change their result.
        if mode != .focus && mode != .echo {
            OrbMath.sortDots(&out.dots)
        }
    }

    // MARK: - Orbits (working)

    /// Particles on tilted orbits.
    private func drawOrbits(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let cx: Float = size / 2.0
        let cy: Float = size / 2.0
        let r: Float = (size / 2.0) * 0.82
        let pt = OrbProj(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1.0)
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)

        let orbitN = OrbProfiles.count(o.orbitN, 12.0, 0, Int(OrbLimits.maxOrbitN))
        let ghostN = OrbProfiles.count(o.ghostN, 40.0, 0, Int(OrbLimits.maxGhostN))
        let particles = OrbProfiles.count(o.particles, 3.0, 0, Int(OrbLimits.maxParticles))

        out.dots.reserveCapacity(out.dots.count + orbitN * (ghostN + particles))
        let ghostR: Float = (o.ghostR ?? 0.9) * rs
        let ghostA: Float = o.ghostA ?? 0.5
        let partR: Float = o.partR ?? 1.2
        let partRDepth: Float = o.partRDepth ?? 1.6
        let circle = topology.unitCircle(ghostN)
        let twoPi: Float = 2.0 * Float.pi

        for orb in 0..<orbitN {
            let orbF = Float(orb)
            let h1: Float = OrbMath.hashD(orbF, 1.7)
            let h2: Float = OrbMath.hashD(orbF, 5.2)
            let h3: Float = OrbMath.hashD(orbF, 8.9)
            let ro: Float = r * (0.45 + 0.52 * h1)
            let th: Float = h1 * 2.0 * Float.pi
            let phi: Float = acos(2.0 * h2 - 1.0)
            // A stable plane basis: cross the normal with whichever world axis is least
            // parallel to it.
            let nx: Float = sin(phi) * cos(th)
            let ny: Float = cos(phi)
            let nz: Float = sin(phi) * sin(th)
            var ux: Float
            var uy: Float
            var uz: Float
            if abs(nz) < 0.9 {
                ux = -ny; uy = nx; uz = 0.0
            } else {
                ux = 0.0; uy = -nz; uz = ny
            }
            let ul2: Float = ux * ux + uy * uy + uz * uz
            let ul: Float = OrbMath.max(ul2.squareRoot(), 1e-6)
            ux /= ul
            uy /= ul
            uz /= ul
            let vx: Float = ny * uz - nz * uy
            let vy: Float = nz * ux - nx * uz
            let vz: Float = nx * uy - ny * ux
            let sign: Float = h3 > 0.5 ? 1.0 : -1.0
            let speed: Float = (0.25 + 0.55 * h3) * sign
            let invRo: Float = 1.0 / ro

            // Ghost topology is invariant; reuse the unit-circle samples.
            for p in circle {
                let ca: Float = p.x
                let sa: Float = p.y
                let wx: Float = (ux * ca + vx * sa) * ro
                let wy: Float = (uy * ca + vy * sa) * ro
                let wz: Float = (uz * ca + vz * sa) * ro
                let (px, py, z) = pt.project(wx, wy, wz)
                let depth: Float = (z * invRo + 1.0) / 2.0
                let alpha: Float = ghostA * (0.4 + 0.6 * depth)
                out.dots.append(OrbDot(x: px, y: py, z: z, r: ghostR, white: 0.72, a: alpha))
            }
            // The particles doing the work.
            for m in 0..<particles {
                let phase: Float = (Float(m) / Float(particles)) * twoPi
                let a: Float = t * speed + phase + h2 * 6.0
                let ca: Float = cos(a)
                let sa: Float = sin(a)
                let wx: Float = (ux * ca + vx * sa) * ro
                let wy: Float = (uy * ca + vy * sa) * ro
                let wz: Float = (uz * ca + vz * sa) * ro
                let (px, py, z) = pt.project(wx, wy, wz)
                let depth: Float = (z * invRo + 1.0) / 2.0
                let radius: Float = (partR + partRDepth * depth) * rs
                let white: Float = 0.3 - 0.22 * depth
                out.dots.append(OrbDot(x: px, y: py, z: z, r: radius, white: white))
            }
        }
    }

    // MARK: - Lattice: globe (searching), rubik (solving), wave (listening)

    /// Lat/long field, a scan meridian sweeps.
    private func drawGlobe(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let spin: Float = 0.5
        let cx: Float = size / 2.0
        let cy: Float = size / 2.0
        let radius: Float = (size / 2.0) * 0.82
        let tilt: Float = 0.4 + 0.06 * sin(t * 0.35)
        let pt = OrbProj(yaw: t * spin, tilt: tilt, cx: cx, cy: cy, scale: radius)
        let scanRate: Float = spin + (1.7 - spin) * (o.scanMul ?? 1.0)
        let scan: Float = t * scanRate
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)
        let dimBase: Float = o.dimBase ?? 1.0

        let latRings = OrbProfiles.count(o.latRings, 17.0, 1, Int(OrbLimits.maxLatticeRings))
        let lonDensity: Float = OrbMath.clamp(o.lonDensity ?? 44.0, 1.0, OrbLimits.maxLonDensity)
        let rBase: Float = o.rBase ?? 0.6
        let rDepth: Float = o.rDepth ?? 1.7
        let rBoost: Float = o.rBoost ?? 1.0
        let inkFar: Float = o.inkFar ?? 0.62
        let inkSpan: Float = o.inkSpan ?? 0.54
        let invLat: Float = 1.0 / Float(latRings)

        for li in 0...latRings {
            let lat: Float = -Float.pi / 2.0 + (Float(li) * invLat) * Float.pi
            let cosLat: Float = cos(lat)
            let sinLat: Float = sin(lat)
            let lonCount = Swift.max(OrbMath.toCount((abs(cosLat) * lonDensity).rounded()), 1)
            let lonStep: Float = 2.0 * Float.pi / Float(lonCount)
            let circle = topology.unitCircle(lonCount)
            for (lj, p) in circle.enumerated() {
                let lon: Float = Float(lj) * lonStep
                let (px, py, z) = pt.project(cosLat * p.x, sinLat, cosLat * p.y)
                let depth: Float = (z + 1.0) / 2.0
                let d: Float = OrbMath.angleDelta(lon + t * spin, scan)
                let boost: Float = exp(-(d * d) / 0.18) * OrbMath.max(z, 0.0)
                let radius: Float = (rBase + rDepth * depth + rBoost * boost) * rs
                let white: Float = inkFar - inkSpan * depth
                let alpha: Float = dimBase + (1.0 - dimBase) * OrbMath.min(boost, 1.0)
                out.dots.append(OrbDot(x: px, y: py, z: z, r: radius, white: white, a: alpha))
            }
        }
    }

    /// Bands twist in quarter turns, scramble → solve.
    private func drawRubik(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let cx: Float = size / 2.0
        let cy: Float = size / 2.0
        let r: Float = (size / 2.0) * 0.82
        // Keep the lattice almost still so each quarter turn reads as the action.
        let tilt: Float = 0.35 + 0.035 * sin(t * 0.45)
        let pt = OrbProj(yaw: t * 0.12, tilt: tilt, cx: cx, cy: cy, scale: r)
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)
        let moveCount = OrbProfiles.count(o.moveCount, 14.0, 0, Int(OrbLimits.maxMoveCount))

        if moves.count != moveCount {
            OrbRubik.makeMoves(moveCount, into: &moves)
        }
        let (active, emphasis) = OrbRubik.solveCycle(t, moveCount, 0.58, 1.35, &amounts)

        let latRings = OrbProfiles.count(o.latRings, 15.0, 1, Int(OrbLimits.maxLatticeRings))
        let lonDensity: Float = OrbMath.clamp(o.lonDensity ?? 40.0, 1.0, OrbLimits.maxLonDensity)
        let rBase: Float = o.rBase ?? 0.6
        let rDepth: Float = o.rDepth ?? 1.7
        let rActive: Float = o.rActive ?? 0.3
        let inkFar: Float = o.inkFar ?? 0.62
        let inkSpan: Float = o.inkSpan ?? 0.54
        let invLat: Float = 1.0 / Float(latRings)

        for li in 0...latRings {
            let lat: Float = -Float.pi / 2.0 + (Float(li) * invLat) * Float.pi
            let cosLat: Float = cos(lat)
            let sinLat: Float = sin(lat)
            let lonCount = Swift.max(OrbMath.toCount((abs(cosLat) * lonDensity).rounded()), 1)
            let circle = topology.unitCircle(lonCount)
            for p in circle {
                let (x, y, z, inActive) = OrbRubik.applyMoves(
                    cosLat * p.x, sinLat, cosLat * p.y, moves, amounts, active
                )
                let (px, py, zr) = pt.project(x, y, z)
                let depth: Float = (zr + 1.0) / 2.0
                let activeMix: Float = inActive ? emphasis : 0.0
                let radius: Float = (rBase + rDepth * depth + rActive * 2.1 * activeMix) * rs
                let white: Float = inkFar - inkSpan * depth - 0.24 * activeMix
                let alpha: Float = 0.58 + 0.14 * depth + 0.28 * activeMix
                out.dots.append(OrbDot(x: px, y: py, z: zr, r: radius, white: white, a: alpha))
            }
        }
    }

    /// A waveform rolls through the rings.
    private func drawWave(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let cx: Float = size / 2.0
        let cy: Float = size / 2.0
        let r: Float = (size / 2.0) * 0.874
        let pt = OrbProj(yaw: t * 0.18, tilt: 0.38, cx: cx, cy: cy, scale: 1.0)
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)

        let rings = OrbProfiles.count(o.rings, 15.0, 1, Int(OrbLimits.maxLatticeRings))
        let lonDensity: Float = OrbMath.clamp(o.lonDensity ?? 40.0, 1.0, OrbLimits.maxLonDensity)
        let rBase: Float = o.rBase ?? 0.6
        let rDepth: Float = o.rDepth ?? 1.7
        let invRings: Float = 1.0 / Float(rings)
        let invR: Float = 1.0 / r

        for ri in 0...rings {
            let riF = Float(ri)
            let lat: Float = -Float.pi / 2.0 + (riF * invRings) * Float.pi
            let cosLat: Float = cos(lat)
            let sinLat: Float = sin(lat)
            let w1: Float = 0.62 * sin(t * 2.1 - riF * 0.52)
            let w2: Float = 0.38 * sin(t * 1.27 + riF * 0.83)
            let w: Float = w1 + w2
            let rr: Float = r * (0.88 + 0.105 * w)
            let lonCount = Swift.max(OrbMath.toCount((abs(cosLat) * lonDensity).rounded()), 1)
            let crest: Float = OrbMath.max(w, 0.0)
            let crestR: Float = 1.0 + 0.4 * crest
            let crestInk: Float = 0.1 * crest
            let circle = topology.unitCircle(lonCount)
            for p in circle {
                let wx: Float = cosLat * p.x * rr
                let wy: Float = sinLat * rr
                let wz: Float = cosLat * p.y * rr
                let (px, py, z) = pt.project(wx, wy, wz)
                let depth: Float = (z * invR + 1.0) / 2.0
                let radius: Float = (rBase + rDepth * depth) * crestR * rs
                let white: Float = 0.66 - 0.56 * depth - crestInk
                out.dots.append(OrbDot(x: px, y: py, z: z, r: radius, white: white))
            }
        }
    }

    // MARK: - Web (connecting)

    /// A constellation wires itself.
    private func drawWeb(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let cx: Float = size / 2.0
        let cy: Float = size / 2.0
        let r: Float = (size / 2.0) * 0.8 * (o.spread ?? 1.0)
        let pt = OrbProj(yaw: t * 0.12, tilt: 0.32, cx: cx, cy: cy, scale: r)
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)

        let nodeN = OrbProfiles.count(o.nodeN, 30.0, 0, Int(OrbLimits.maxNodeN))
        let thr: Float = o.thr ?? 0.72
        let nodeR: Float = o.nodeR ?? 1.4
        let nodeRDepth: Float = o.nodeRDepth ?? 1.8
        let lineW: Float = OrbMath.max((o.lineW ?? 0.8) * rs, 0.6)
        let invThr: Float = thr > 0.0 ? 1.0 / thr : 0.0
        let thr2: Float = thr * thr

        nodes.removeAll(keepingCapacity: true)
        edges.removeAll(keepingCapacity: true)
        nodes.reserveCapacity(nodeN)

        // Project once up front: the O(n²) edge scan then needs n projections, not 2n².
        let directions = topology.fibDirs(nodeN)
        for (i, d) in directions.enumerated() {
            let iF = Float(i)
            let nX: Float = OrbMath.vnoise(iF * 0.31 + 9.0, t * 0.24)
            let nY: Float = OrbMath.vnoise(iF * 0.53 + 27.0, t * 0.21)
            let nZ: Float = OrbMath.vnoise(iF * 0.77 + 55.0, t * 0.27)
            let x: Float = d.x + 0.3 * (nX - 0.5) * 2.0
            let y: Float = d.y + 0.3 * (nY - 0.5) * 2.0
            let z: Float = d.z + 0.3 * (nZ - 0.5) * 2.0
            let l: Float = (x * x + y * y + z * z).squareRoot()
            let invL: Float = l > 1e-6 ? 1.0 / l : 0.0
            let ux: Float = x * invL
            let uy: Float = y * invL
            let uz: Float = z * invL
            let (px, py, pz) = pt.project(ux, uy, uz)
            nodes.append(WebNode(ux: ux, uy: uy, uz: uz, px: px, py: py, pz: pz))
        }

        for i in 0..<nodeN {
            let a = nodes[i]
            for j in (i + 1)..<nodeN {
                let b = nodes[j]
                let dx: Float = a.ux - b.ux
                let dy: Float = a.uy - b.uy
                let dz: Float = a.uz - b.uz
                let d2: Float = dx * dx + dy * dy + dz * dz
                // Squared distances: most pairs are rejected, so skip their sqrt.
                if d2 >= thr2 { continue }
                let dist: Float = d2.squareRoot()
                let depth: Float = ((a.pz + b.pz) / 2.0 + 1.0) / 2.0
                let alpha: Float = (1.0 - dist * invThr) * (0.3 + 0.55 * depth)
                out.lines.append(OrbLine(x1: a.px, y1: a.py, x2: b.px, y2: b.py, white: 0.42, a: alpha, w: lineW))
                edges.append((i, j))
            }
        }

        for (i, n) in nodes.enumerated() {
            let depth: Float = (n.pz + 1.0) / 2.0
            let pulse: Float = 1.0 + 0.25 * sin(t * 1.4 + Float(i) * 2.7)
            let radius: Float = (nodeR + nodeRDepth * depth) * pulse * rs
            let white: Float = 0.55 - 0.45 * depth
            out.dots.append(OrbDot(x: n.px, y: n.py, z: n.pz, r: radius, white: white))
        }

        let signals = OrbProfiles.count(o.signals, 5.0, 0, Int(OrbLimits.maxSignals))
        for s in 0..<signals {
            if edges.isEmpty { break }
            let sF = Float(s)
            let journey: Float = t * 0.48 + sF * 3.73
            let cycle: Float = journey.rounded(.down)
            let edgeCount = Float(edges.count)
            let pick: Float = (OrbMath.hashD(cycle, sF * 4.7 + 1.3) * edgeCount).rounded(.down)
            let edgeIndex = OrbMath.toCount(OrbMath.min(pick, Float(edges.count - 1)))
            let (ia, ib) = edges[edgeIndex]
            let f: Float = OrbMath.frac(journey)
            let px: Float = OrbMath.lerp(nodes[ia].px, nodes[ib].px, f)
            let py: Float = OrbMath.lerp(nodes[ia].py, nodes[ib].py, f)
            let zr: Float = OrbMath.lerp(nodes[ia].pz, nodes[ib].pz, f)
            let depth: Float = (zr + 1.0) / 2.0
            let life: Float = OrbMath.max(sin(Float.pi * f), 0.0)
            let radius: Float = (nodeR * 1.5 + nodeRDepth * depth) * rs
            let alpha: Float = life * (0.5 + 0.5 * depth)
            out.dots.append(OrbDot(x: px, y: py, z: zr, r: radius, white: 0.05, a: alpha))
        }
    }

    // MARK: - Braid (weaving)

    /// Three strands plait around the sphere.
    private func drawBraid(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let cx: Float = size / 2.0
        let cy: Float = size / 2.0
        let r: Float = (size / 2.0) * 0.76
        let pt = OrbProj(yaw: t * 0.4, tilt: 0.3, cx: cx, cy: cy, scale: 1.0)
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)

        let ghostN = OrbProfiles.count(o.ghostN, 150.0, 0, Int(OrbLimits.maxGhostN))
        let strandN = OrbProfiles.count(o.strandN, 52.0, 0, Int(OrbLimits.maxStrandN))
        let invR: Float = 1.0 / r
        out.dots.reserveCapacity(out.dots.count + ghostN + strandN * 3)

        for d in topology.fibDirs(ghostN) {
            let (px, py, z) = pt.project(d.x * r, d.y * r, d.z * r)
            let depth: Float = (z * invR + 1.0) / 2.0
            let alpha: Float = 0.1 + 0.22 * depth
            out.dots.append(OrbDot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: alpha))
        }

        let turns: Float = o.turns ?? 3.0
        let rBase: Float = o.rBase ?? 1.2
        let rDepth: Float = o.rDepth ?? 1.8
        let invStrand: Float = 1.0 / Float(strandN)
        for s in 0..<3 {
            let phase: Float = (Float(s) / 3.0) * 2.0 * Float.pi
            for i in 0..<strandN {
                let fr: Float = OrbMath.frac(Float(i) * invStrand + t * 0.045)
                let u: Float = (fr * 2.0 - 1.0) * 0.96
                let surf: Float = OrbMath.max(1.0 - u * u, 0.0).squareRoot()
                let endFade: Float = OrbMath.clamp((0.96 - abs(u)) / 0.12, 0.0, 1.0)
                let a: Float = u * Float.pi * turns + phase
                let weaveArg: Float = u * Float.pi * turns * 2.0 + phase * 2.0 + t * 0.8
                let weave: Float = 1.0 + 0.075 * sin(weaveArg)
                let rr: Float = surf * r * weave
                let (px, py, zr) = pt.project(cos(a) * rr, u * r * weave, sin(a) * rr)
                let depth: Float = (zr * invR + 1.0) / 2.0
                let radius: Float = (rBase + rDepth * depth) * rs
                let white: Float = 0.55 - 0.45 * depth
                let alpha: Float = endFade * (0.45 + 0.55 * depth)
                out.dots.append(OrbDot(x: px, y: py, z: zr, r: radius, white: white, a: alpha))
            }
        }
    }

    // MARK: - Ribbon / ring (composing, breathing)

    /// Undulating sash, or a face-on breathing ring.
    private func drawRibbon(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let cx: Float = size / 2.0
        let cy: Float = size / 2.0
        let r: Float = (size / 2.0) * 0.78
        let spin: Float = o.spin ?? 1.0
        let camTilt: Float = 0.3
        let pt = OrbProj(yaw: t * 0.1 * spin, tilt: camTilt, cx: cx, cy: cy, scale: 1.0)
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)
        let faceOn = (o.faceOn ?? 0.0) != 0.0

        let ghostN = OrbProfiles.count(o.ghostN, 150.0, 0, Int(OrbLimits.maxGhostN))
        let invR: Float = 1.0 / r
        out.dots.reserveCapacity(out.dots.count + ghostN)
        for d in topology.fibDirs(ghostN) {
            let (px, py, z) = pt.project(d.x * r, d.y * r, d.z * r)
            let depth: Float = (z * invR + 1.0) / 2.0
            let alpha: Float = 0.1 + 0.22 * depth
            out.dots.append(OrbDot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: alpha))
        }

        let ya: Float = t * 0.24 * spin
        let ta: Float = faceOn ? -camTilt : 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux: Float = cos(ya)
        let uy: Float = 0.0
        let uz: Float = sin(ya)
        let sta: Float = sin(ta)
        let cta: Float = cos(ta)
        let vx: Float = -uz * sta
        let vy: Float = cta
        let vz: Float = ux * sta
        // Plane normal n = u × v.
        let nx: Float = uy * vz - uz * vy
        let ny: Float = uz * vx - ux * vz
        let nz: Float = ux * vy - uy * vx

        let wobMul: Float = o.wobMul ?? 1.0
        let wobAmp: Float = 0.23 * wobMul
        let baseR: Float = faceOn ? r / (1.0 + 0.85 * wobAmp) : r

        let baseLanes: Float = OrbMath.clamp(o.lanes ?? 5.0, 1.0, OrbLimits.maxLanes)
        let segs = OrbProfiles.count(o.segs, 88.0, 1, Int(OrbLimits.maxSegs))
        let lanesF: Float = OrbMath.clamp((baseLanes * (o.bandMul ?? 1.0)).rounded(), 1.0, OrbLimits.maxLanes)
        let lanes = OrbMath.toCount(lanesF)
        let rBase: Float = o.rBase ?? 1.1
        let rDepth: Float = o.rDepth ?? 1.7
        let segStep: Float = 2.0 * Float.pi / Float(segs)
        let half: Float = (Float(lanes) - 1.0) / 2.0
        let invHalf: Float = 1.0 / OrbMath.max(half, 1.0)
        out.dots.reserveCapacity(out.dots.count + lanes * segs)

        for w in 0..<lanes {
            let wF = Float(w)
            let centered: Float = wF - half
            let laneOff: Float = centered * 0.075
            let edge: Float = abs(centered) * invHalf
            let edgeR: Float = 1.0 - 0.25 * edge
            let edgeInk: Float = 0.18 * edge
            for k in 0..<segs {
                let a: Float = Float(k) * segStep
                let ca: Float = cos(a)
                let sa: Float = sin(a)
                let breath: Float = faceOn ? 0.72 + 0.28 * sin(t * 0.48) : 1.0
                let wob1: Float = 0.16 * sin(a * 3.0 - t * 1.7 + wF * 0.22)
                let wob2: Float = 0.07 * sin(a * 5.0 + t * 1.1)
                let wob: Float = (wob1 + wob2) * wobMul * breath
                let radial: Float = faceOn ? 1.0 + wob : 1.0
                let off: Float = faceOn ? laneOff : laneOff + wob
                let x: Float = ux * ca + vx * sa + nx * off
                let y: Float = uy * ca + vy * sa + ny * off
                let z: Float = uz * ca + vz * sa + nz * off
                let l: Float = (x * x + y * y + z * z).squareRoot()
                let invL: Float = l > 1e-6 ? 1.0 / l : 0.0
                let rr: Float = baseR * radial * invL
                let (px, py, zr) = pt.project(x * rr, y * rr, z * rr)
                let depth: Float = (zr * invR + 1.0) / 2.0
                let radius: Float = (rBase + rDepth * depth) * edgeR * rs
                let white: Float = 0.52 - 0.44 * depth + edgeInk
                let alpha: Float = 0.4 + 0.6 * depth
                out.dots.append(OrbDot(x: px, y: py, z: zr, r: radius, white: white, a: alpha))
            }
        }
    }

    // MARK: - Morph (shaping)

    /// Dotted outline cycling circle → triangle → square.
    private func drawMorph(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let cycle: [OrbMorph.Shape] = [.circle, .poly(OrbMorph.triangle), .poly(OrbMorph.square)]
        let kLen = cycle.count
        let segDur: Float = OrbMorph.seg
        let tc: Float = OrbMath.remEuclid(t, segDur * Float(kLen))
        let k = Swift.min(OrbMath.toCount((tc / segDur).rounded(.down)), kLen - 1)
        let local: Float = tc - Float(k) * segDur
        let m: Float = local > OrbMorph.hold ? OrbMorph.smoothE((local - OrbMorph.hold) / OrbMorph.morph) : 0.0
        let sprd: Float = o.spread ?? 1.0

        let pA = cycle[k]
        let pB = cycle[(k + 1) % kLen]
        let samples = OrbMorph.samples

        let invSamples: Float = 1.0 / Float(samples)
        for i in 0..<samples {
            let f: Float = Float(i) * invSamples
            let a = pA.at(f)
            let b = pB.at(f)
            let x: Float = (a.x + (b.x - a.x) * m) * sprd
            let y: Float = (a.y + (b.y - a.y) * m) * sprd
            morphPoints[i] = SIMD2<Float>(x, y)
        }
        var total: Float = 0.0
        for i in 0..<samples {
            let a = morphPoints[i]
            let b = morphPoints[(i + 1) % samples]
            let l: Float = hypot(b.x - a.x, b.y - a.y)
            morphLengths[i] = l
            total += l
        }

        let n = OrbMorph.morphN(o.iconD ?? 1.0)
        let re: Float = (o.rDot ?? 0.021) * 1.35 * sprd
        let pulse: Float = 1.0 + 0.018 * sin(t * 2.35)

        out.dots.reserveCapacity(out.dots.count + n)
        let c2: Float = size / 2.0
        let radius: Float = OrbMath.max(re * size, 0.35)
        var seg = 0
        var acc: Float = 0.0
        let invN: Float = 1.0 / Float(n)
        for k2 in 0..<n {
            let target: Float = Float(k2) * invN * total
            // Bounds check first: `seg` never leaves 0..<samples.
            while seg < samples - 1 && acc + morphLengths[seg] < target {
                acc += morphLengths[seg]
                seg += 1
            }
            let a = morphPoints[seg]
            let b = morphPoints[(seg + 1) % samples]
            let segLen: Float = morphLengths[seg]
            let f: Float = segLen > 0.0 ? OrbMath.min((target - acc) / segLen, 1.0) : 0.0
            let x: Float = (a.x + (b.x - a.x) * f) * pulse
            let y: Float = (a.y + (b.y - a.y) * f) * pulse
            out.dots.append(OrbDot(x: c2 + x * size, y: c2 + y * size, z: 0.0, r: radius, white: 0.1))
        }
    }

    // MARK: - Concepts: focus, gyroscope, echo

    /// Iris-like streams converge on a small, steady focal core.
    private func drawFocus(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let center: Float = size / 2.0
        let extent: Float = size * 0.38 * (o.spread ?? 1.0)
        let lanes = OrbProfiles.count(o.lanes, 6.0, 1, Int(OrbLimits.maxLanes))
        let segs = OrbProfiles.count(o.segs, 12.0, 1, Int(OrbLimits.maxSegs))
        let coreN = OrbProfiles.count(o.particles, 5.0, 1, Int(OrbLimits.maxParticles))
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)
        let rBase: Float = o.rBase ?? 0.9
        let rDepth: Float = o.rDepth ?? 1.25
        out.dots.reserveCapacity(out.dots.count + lanes * segs + coreN)

        // Close and reopen a six-blade aperture without collapsing the samples into a star:
        // only each blade's inner edge moves, so it stays readable in a frozen frame.
        let openness: Float = 0.5 + 0.5 * sin(t * 0.9)
        let inner: Float = 0.12 + 0.2 * openness
        let rotation: Float = t * 0.11
        let invSegs: Float = 1.0 / Float(segs)
        let curlBase: Float = 0.88 - 0.24 * openness
        for (lane, direction) in topology.unitCircle(lanes).enumerated() {
            for i in 0..<segs {
                let u: Float = (Float(i) + 0.5) * invSegs
                let radial: Float = inner + (1.0 - inner) * u
                let curl: Float = curlBase * pow(1.0 - u, 1.25)
                let twist: Float = rotation + curl
                let st: Float = sin(twist)
                let ct: Float = cos(twist)
                let dx: Float = direction.x * ct - direction.y * st
                let dy: Float = direction.x * st + direction.y * ct
                let innerWeight: Float = 1.0 - u
                let shimmer: Float = 0.96 + 0.05 * sin(t * 1.4 + Float(lane) * 0.8)
                let radius: Float = (rBase + rDepth * innerWeight) * shimmer * rs
                let white: Float = 0.12 + 0.52 * u
                let alpha: Float = 0.48 + 0.52 * sin(Float.pi * u)
                let x: Float = center + dx * extent * radial
                let y: Float = center + dy * extent * radial
                out.dots.append(OrbDot(x: x, y: y, z: 0.0, r: radius, white: white, a: alpha))
            }
        }

        // A tiny breathing nucleus makes the destination legible at inline size.
        let coreRadius: Float = size * (0.035 + 0.004 * sin(t * 1.5))
        let coreR: Float = (rBase + rDepth * 1.15) * rs
        for p in topology.unitCircle(coreN) {
            let x: Float = center + p.x * coreRadius
            let y: Float = center + p.y * coreRadius
            out.dots.append(OrbDot(x: x, y: y, z: 0.0, r: coreR, white: 0.08))
        }
    }

    /// Three inference loops carry thoughts in alternating directions.
    private func drawGyroscope(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let center: Float = size / 2.0
        let radius: Float = size * 0.385 * (o.spread ?? 1.0)
        let rings = Swift.min(OrbProfiles.count(o.lanes, 3.0, 1, Int(OrbLimits.maxLanes)), 6)
        let segs = OrbProfiles.count(o.segs, 24.0, 3, Int(OrbLimits.maxSegs))
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)
        let rBase: Float = o.rBase ?? 0.8
        let rDepth: Float = o.rDepth ?? 1.5
        let proj = OrbProj(yaw: t * 0.055, tilt: 0.18, cx: center, cy: center, scale: radius)
        out.dots.reserveCapacity(out.dots.count + rings * (segs + 2))

        let circle = topology.unitCircle(segs)
        let ringsF = Float(rings)
        for ring in 0..<rings {
            let ringF = Float(ring)
            let spread: Float = rings > 1 ? ringF / Float(rings - 1) - 0.5 : 0.0
            let tiltX: Float = spread * 1.55 + 0.12 * sin(t * 0.16 + ringF)
            let tiltY: Float = ringF * Float.pi / ringsF + 0.32
            let sx: Float = sin(tiltX)
            let cx: Float = cos(tiltX)
            let sy: Float = sin(tiltY)
            let cy: Float = cos(tiltY)
            let direction: Float = ring % 2 == 0 ? 1.0 : -1.0
            func orient(_ ca: Float, _ sa: Float) -> (Float, Float, Float) {
                let y1: Float = sa * cx
                let z1: Float = sa * sx
                let x: Float = ca * cy + z1 * sy
                let z: Float = -ca * sy + z1 * cy
                return (x, y1, z)
            }

            for p in circle {
                let (x, y, z) = orient(p.x, p.y)
                let (px, py, depthZ) = proj.project(x, y, z)
                let depth: Float = (depthZ + 1.0) * 0.5
                let r: Float = (rBase * 0.9 + rDepth * 0.5 * depth) * rs
                let white: Float = 0.62 - 0.34 * depth
                let alpha: Float = 0.34 + 0.4 * depth
                out.dots.append(OrbDot(x: px, y: py, z: depthZ, r: r, white: white, a: alpha))
            }

            // A leading thought and a softer echo make direction and velocity legible.
            let travelRate: Float = t * (0.72 + ringF * 0.08) * direction
            let travelPhase: Float = ringF * 2.0 * Float.pi / ringsF
            let travel: Float = travelRate + travelPhase
            let offsets: [Float] = [0.0, -0.22 * direction]
            for (trail, offset) in offsets.enumerated() {
                let angle: Float = travel + offset
                let sa: Float = sin(angle)
                let ca: Float = cos(angle)
                let (x, y, z) = orient(ca, sa)
                let (px, py, depthZ) = proj.project(x, y, z)
                let depth: Float = (depthZ + 1.0) * 0.5
                let strength: Float = trail == 0 ? 1.0 : 0.48
                let r: Float = (rBase + rDepth * depth + 1.65 * strength) * rs
                let white: Float = 0.44 - 0.42 * depth - 0.2 * strength
                let alpha: Float = (0.55 + 0.45 * depth) * strength
                out.dots.append(OrbDot(x: px, y: py, z: depthZ + 0.002, r: r, white: white, a: alpha))
            }
        }
    }

    /// Concentric echoes emerge from a stable core and dissolve at the boundary.
    private func drawEcho(_ size: Float, _ t: Float, _ o: OrbModeOpts, _ out: inout OrbFrame) {
        let center: Float = size / 2.0
        let extent: Float = size * 0.4 * (o.spread ?? 1.0)
        let rings = OrbProfiles.count(o.lanes, 4.0, 1, Int(OrbLimits.maxLanes))
        let segs = OrbProfiles.count(o.segs, 18.0, 3, Int(OrbLimits.maxSegs))
        let coreN = OrbProfiles.count(o.particles, 3.0, 1, Int(OrbLimits.maxParticles))
        let rs: Float = OrbMath.radiusScale(size, o.rsPow ?? 0.6)
        let rBase: Float = o.rBase ?? 0.85
        let rDepth: Float = o.rDepth ?? 1.05
        out.dots.reserveCapacity(out.dots.count + rings * segs + coreN)

        let circle = topology.unitCircle(segs)
        let ringsF = Float(rings)
        for ring in 0..<rings {
            let ringF = Float(ring)
            let phase: Float = OrbMath.frac(t * 0.14 + ringF / ringsF)
            let radius: Float = extent * (0.13 + 0.87 * phase)
            let life: Float = OrbMath.max(sin(Float.pi * phase), 0.0)
            let turn: Float = ringF * 0.37 - t * 0.1
            let st: Float = sin(turn)
            let ct: Float = cos(turn)
            let r: Float = (rBase + rDepth * (1.0 - phase)) * rs
            let white: Float = 0.18 + 0.52 * phase
            let alpha: Float = pow(life, 0.58)
            for p in circle {
                let x: Float = p.x * ct - p.y * st
                let y: Float = p.x * st + p.y * ct
                let dx: Float = center + x * radius
                let dy: Float = center + y * radius
                out.dots.append(OrbDot(x: dx, y: dy, z: 0.0, r: r, white: white, a: alpha))
            }
        }

        let coreRadius: Float = size * 0.025
        let coreR: Float = (rBase + rDepth * 1.4) * rs
        for p in topology.unitCircle(coreN) {
            let x: Float = center + p.x * coreRadius
            let y: Float = center + p.y * coreRadius
            out.dots.append(OrbDot(x: x, y: y, z: 0.0, r: coreR, white: 0.06))
        }
    }
}

// MARK: - Web scratch

private struct WebNode {
    var ux: Float
    var uy: Float
    var uz: Float
    var px: Float
    var py: Float
    var pz: Float
}

// MARK: - Rubik helpers

struct RubikMove: Sendable {
    var axis: UInt8
    var lo: Float
    var hi: Float
    var ang: Float
}

private enum OrbRubik {
    static func makeMoves(_ count: Int, into moves: inout [RubikMove]) {
        moves.removeAll(keepingCapacity: true)
        moves.reserveCapacity(count)
        for i in 0..<count {
            let iF = Float(i)
            let axisF: Float = OrbMath.min((OrbMath.hashD(iF, 2.3) * 3.0).rounded(.down), 2.0)
            let axis = UInt8(OrbMath.toCount(axisF))
            let band: Float = OrbMath.min((OrbMath.hashD(iF, 5.9) * 4.0).rounded(.down), 3.0)
            let lo: Float = -1.0 + 0.5 * band
            let dir: Float = OrbMath.hashD(iF, 7.7) < 0.5 ? 1.0 : -1.0
            let ang: Float = dir * Float.pi / 2.0
            moves.append(RubikMove(axis: axis, lo: lo, hi: lo + 0.5, ang: ang))
        }
    }

    /// Returns the active move (or -1) and its emphasis.
    static func solveCycle(
        _ time: Float, _ count: Int, _ slotDur: Float, _ rest: Float, _ amount: inout [Float]
    ) -> (Int, Float) {
        amount.removeAll(keepingCapacity: true)
        amount.append(contentsOf: repeatElement(0.0, count: count))
        var active = -1
        if count == 0 { return (active, 0.0) }
        let span: Float = 2.0 * Float(count) * slotDur
        let cyc: Float = span + rest
        let tc: Float = time.truncatingRemainder(dividingBy: cyc)
        if tc < span {
            // Rounding can let `tc / slotDur` reach `2 * count` even though the guard held,
            // so clamp the slot.
            let slot = Swift.min(OrbMath.toCount((tc / slotDur).rounded(.down)), 2 * count - 1)
            let raw: Float = (tc - Float(slot) * slotDur) / slotDur
            let p: Float = OrbMath.clamp(raw, 0.0, 1.0)
            let ep: Float = p * p * (3.0 - 2.0 * p)
            let emphasis: Float = OrbMath.max(sin(Float.pi * p), 0.0).squareRoot()
            if slot < count {
                for i in 0..<slot { amount[i] = 1.0 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<Swift.min(u, count) { amount[i] = 1.0 }
                if u < count {
                    amount[u] = 1.0 - ep
                }
                active = u
            }
            return (active, emphasis)
        }
        return (active, 0.0)
    }

    @inline(__always)
    static func applyMoves(
        _ px: Float, _ py: Float, _ pz: Float, _ moves: [RubikMove], _ amounts: [Float], _ active: Int
    ) -> (Float, Float, Float, Bool) {
        var x = px
        var y = py
        var z = pz
        var inActive = false
        for i in 0..<moves.count {
            let amt = amounts[i]
            if amt <= 0.0 { continue }
            let mv = moves[i]
            let coord: Float
            switch mv.axis {
            case 0: coord = x
            case 1: coord = y
            default: coord = z
            }
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == active { inActive = true }
            let a: Float = mv.ang * amt
            let ca: Float = cos(a)
            let sa: Float = sin(a)
            switch mv.axis {
            case 0:
                let y2: Float = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            case 1:
                let x2: Float = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            default:
                let x2: Float = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return (x, y, z, inActive)
    }
}

// MARK: - Morph helpers

/// Arc-length parameterisation of a closed polygon.
struct OrbPolyPath: Sendable {
    let verts: [SIMD2<Float>]
    let lengths: [Float]
    let total: Float

    init(_ verts: [SIMD2<Float>]) {
        var lengths: [Float] = []
        var total: Float = 0.0
        let v = verts.count
        for i in 0..<v {
            let a = verts[i]
            let b = verts[(i + 1) % v]
            let l: Float = hypot(b.x - a.x, b.y - a.y)
            lengths.append(l)
            total += l
        }
        self.verts = verts
        self.lengths = lengths
        self.total = total
    }

    func at(_ f: Float) -> SIMD2<Float> {
        let v = verts.count
        var target: Float = f * total
        var i = 0
        while i < v - 1 && target > lengths[i] {
            target -= lengths[i]
            i += 1
        }
        let a = verts[i]
        let b = verts[(i + 1) % v]
        let len: Float = lengths[i]
        let ff: Float = len > 0.0 ? OrbMath.min(target / len, 1.0) : 0.0
        return SIMD2<Float>(a.x + (b.x - a.x) * ff, a.y + (b.y - a.y) * ff)
    }
}

enum OrbMorph {
    /// Outline resolution used to re-parameterise the blended shape by arc length.
    static let samples = 160
    static let hold: Float = 1.4
    static let morph: Float = 0.9
    static let seg: Float = hold + morph

    static let triangle = OrbPolyPath([
        SIMD2<Float>(0.0, -0.26), SIMD2<Float>(0.24, 0.16), SIMD2<Float>(-0.24, 0.16),
    ])
    static let square = OrbPolyPath([
        SIMD2<Float>(0.0, -0.2), SIMD2<Float>(0.2, -0.2), SIMD2<Float>(0.2, 0.2), SIMD2<Float>(-0.2, 0.2),
    ])

    enum Shape {
        case circle
        case poly(OrbPolyPath)

        func at(_ f: Float) -> SIMD2<Float> {
            switch self {
            case .circle:
                let a: Float = -Float.pi / 2.0 + f * 2.0 * Float.pi
                return SIMD2<Float>(cos(a) * 0.24, sin(a) * 0.24)
            case .poly(let path):
                return path.at(f)
            }
        }
    }

    static func smoothE(_ x: Float) -> Float {
        x * x * (3.0 - 2.0 * x)
    }

    static func morphN(_ d: Float) -> Int {
        let n: Float = OrbMath.max((34.0 * d).rounded(), 6.0)
        let count = OrbMath.toCount(n)
        return Swift.min(Swift.max(count, 6), OrbLimits.maxMorphDots)
    }
}
