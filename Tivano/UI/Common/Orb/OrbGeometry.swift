// Ported from Zeron (https://github.com/zeronsh/zeron, MIT), crates/orb and crates/ui/src/orb,
// itself extracted from Bezel (clearloop, MIT), a port of gpui-thinking-orbs (MIT), a port of
// Jakub Antalik's thinking-orbs (MIT). See THIRD_PARTY_NOTICES.md.
//
// Shared primitives for the dotted 3D thought-orbs (engine/core.rs): frame geometry, the
// spin + tilt projection, the hash / noise helpers and the topology caches.

import Foundation

/// A projected, depth-shaded disk.
struct OrbDot: Sendable, Equatable {
    var x: Float
    var y: Float
    var z: Float
    var r: Float
    /// Ink value: 0 = darkest ink on paper. Mirrored on dark appearances.
    var white: Float
    var a: Float

    init(x: Float, y: Float, z: Float, r: Float, white: Float, a: Float = 1.0) {
        self.x = x
        self.y = y
        self.z = z
        self.r = r
        self.white = white
        self.a = a
    }
}

/// A stroked edge between two projected points (the connecting web).
struct OrbLine: Sendable, Equatable {
    var x1: Float
    var y1: Float
    var x2: Float
    var y2: Float
    var white: Float
    var a: Float
    var w: Float
}

/// Frame geometry produced by a mode painter.
struct OrbFrame: Sendable, Equatable {
    var dots: [OrbDot] = []
    var lines: [OrbLine] = []

    init() {}

    /// Drop all geometry but keep the allocated capacity, so a steady-state animation loop
    /// reuses one pair of buffers forever.
    mutating func clear() {
        dots.removeAll(keepingCapacity: true)
        lines.removeAll(keepingCapacity: true)
    }
}

/// Spin + tilt + orthographic projection, precomputed once per frame.
struct OrbProj: Sendable {
    let st: Float
    let ct: Float
    let sy: Float
    let cyw: Float
    let cx: Float
    let cy: Float
    let scale: Float

    /// Shared spin + tilt + orthographic projection (`make_proj`).
    init(yaw: Float, tilt: Float, cx: Float, cy: Float, scale: Float) {
        st = sin(tilt)
        ct = cos(tilt)
        sy = sin(yaw)
        cyw = cos(yaw)
        self.cx = cx
        self.cy = cy
        self.scale = scale
    }

    @inline(__always)
    func project(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
        let x1: Float = x * cyw + z * sy
        let z1: Float = -x * sy + z * cyw
        let y1: Float = y * ct - z1 * st
        let z2: Float = y * st + z1 * ct
        let px: Float = cx + x1 * scale
        let py: Float = cy - y1 * scale
        return (px, py, z2)
    }
}

/// Numeric helpers with Rust `f32` semantics.
enum OrbMath {
    @inline(__always)
    static func lerp(_ a: Float, _ b: Float, _ f: Float) -> Float {
        a + (b - a) * f
    }

    @inline(__always)
    static func floor(_ x: Float) -> Float {
        x.rounded(.down)
    }

    @inline(__always)
    static func frac(_ x: Float) -> Float {
        x - x.rounded(.down)
    }

    /// Rust `f32::clamp`: NaN passes through.
    @inline(__always)
    static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        if x < lo { return lo }
        if x > hi { return hi }
        return x
    }

    @inline(__always)
    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        if x < lo { return lo }
        if x > hi { return hi }
        return x
    }

    /// Rust `f32::max`: if one side is NaN, the other wins.
    @inline(__always)
    static func max(_ a: Float, _ b: Float) -> Float {
        Float.maximum(a, b)
    }

    /// Rust `f32::min`: if one side is NaN, the other wins.
    @inline(__always)
    static func min(_ a: Float, _ b: Float) -> Float {
        Float.minimum(a, b)
    }

    /// Rust `f32 as usize`: truncates toward zero, saturates, NaN → 0.
    @inline(__always)
    static func toCount(_ x: Float) -> Int {
        if !(x > 0) { return 0 }
        if x >= 9.0e18 { return Int.max }
        return Int(x)
    }

    /// Rust `f32::rem_euclid`.
    @inline(__always)
    static func remEuclid(_ a: Float, _ b: Float) -> Float {
        let r: Float = a.truncatingRemainder(dividingBy: b)
        return r < 0 ? r + abs(b) : r
    }

    /// Deterministic hash in [0, 1): the canonical GLSL `fract(sin(dot(...)) * 43758.5453)`
    /// constants, kept verbatim so the generated dot layouts match upstream.
    @inline(__always)
    static func hashD(_ a: Float, _ b: Float) -> Float {
        let s: Float = a * 12.9898 + b * 78.233
        let h: Float = sin(s) * 43758.5453
        return h - h.rounded(.down)
    }

    /// Value noise on a 2D lattice: smooth, deterministic, cheap.
    static func vnoise(_ x: Float, _ y: Float) -> Float {
        let xi: Float = x.rounded(.down)
        let yi: Float = y.rounded(.down)
        var fx: Float = x - xi
        var fy: Float = y - yi
        fx = fx * fx * (3.0 - 2.0 * fx)
        fy = fy * fy * (3.0 - 2.0 * fy)
        let a: Float = hashD(xi, yi)
        let b: Float = hashD(xi + 1.0, yi)
        let c: Float = hashD(xi, yi + 1.0)
        let d: Float = hashD(xi + 1.0, yi + 1.0)
        let t1: Float = (b - a) * fx
        let t2: Float = (c - a) * fy
        let t3: Float = (a - b - c + d) * fx * fy
        return a + t1 + t2 + t3
    }

    /// Stable directions on a unit sphere (Fibonacci lattice).
    static func fibDir(_ i: Int, _ n: Int) -> SIMD3<Float> {
        let golden: Float = Float.pi * (3.0 - Float(5.0).squareRoot())
        let fi = Float(i)
        let y: Float = 1.0 - (2.0 * (fi + 0.5)) / Float(n)
        let rad: Float = (1.0 - y * y).squareRoot()
        let a: Float = fi * golden
        return SIMD3<Float>(rad * cos(a), y, rad * sin(a))
    }

    /// Shortest signed angular distance, wrapped to (-π, π].
    @inline(__always)
    static func angleDelta(_ a: Float, _ b: Float) -> Float {
        let d: Float = a - b
        return atan2(sin(d), cos(d))
    }

    /// Dot radii were tuned for a 300 pt frame; sub-linear scaling keeps small spinners
    /// legible. Lower pow = radii shrink less with size.
    @inline(__always)
    static func radiusScale(_ size: Float, _ p: Float) -> Float {
        pow(size / 300.0, p)
    }

    /// Z-sort far → near so nearer dots paint over farther ones.
    static func sortDots(_ dots: inout [OrbDot]) {
        dots.sort { $0.z < $1.z }
    }
}

/// Per-engine topology caches indexed by sample count (the Rust thread-locals). Public draw
/// inputs are capped before reaching these, so the sparse arrays stay small.
final class OrbTopologyCache {
    private var fibonacci: [[SIMD3<Float>]?] = []
    private var circles: [[SIMD2<Float>]?] = []

    /// The stable Fibonacci sphere for `n` points.
    func fibDirs(_ n: Int) -> [SIMD3<Float>] {
        if fibonacci.count <= n {
            fibonacci.append(contentsOf: repeatElement(nil, count: n + 1 - fibonacci.count))
        }
        if let cached = fibonacci[n] { return cached }
        var directions: [SIMD3<Float>] = []
        directions.reserveCapacity(n)
        for i in 0..<n {
            directions.append(OrbMath.fibDir(i, n))
        }
        fibonacci[n] = directions
        return directions
    }

    /// Evenly spaced `(cos θ, sin θ)` samples for a closed circle.
    func unitCircle(_ n: Int) -> [SIMD2<Float>] {
        if circles.count <= n {
            circles.append(contentsOf: repeatElement(nil, count: n + 1 - circles.count))
        }
        if let cached = circles[n] { return cached }
        let step: Float = 2.0 * Float.pi / Float(Swift.max(n, 1))
        var circle: [SIMD2<Float>] = []
        circle.reserveCapacity(n)
        for i in 0..<n {
            let a: Float = Float(i) * step
            circle.append(SIMD2<Float>(cos(a), sin(a)))
        }
        circles[n] = circle
        return circle
    }
}
