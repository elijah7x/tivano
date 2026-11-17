import CoreGraphics
import Foundation

struct PortholeClothPath {
    let name: String
    let idle: CGPath
    let breeze: [CGPath]
    let done: CGPath
    let failed: CGPath
}

struct PortholeStarSpec {
    let xNorm: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let isMajor: Bool
    let duration: Double
    let delay: Double
    let staticOpacity: Float
}

struct PortholeSmokeSpec {
    let path: CGPath
    let driftX: CGFloat
    let breezeDriftX: CGFloat
    let riseY: CGFloat
    let duration: Double
    let delay: Double
    let staticOffset: CGPoint
    let staticOpacity: Float
}

struct PortholeSunRaySpec {
    let baseAngle: CGFloat
    let lengthFactor: CGFloat
    let spread: CGFloat
    let sweepDelta: CGFloat
    let duration: Double
    let delay: Double
    let weight: CGFloat
}

struct PortholeWindStreakSpec {
    let path: CGPath
    let y: CGFloat
    let startOffsetNorm: CGFloat
    let duration: Double
    let delay: Double
    let peakOpacity: Float
    let staticXNorm: CGFloat
}

struct PortholeWindLeafSpec {
    let isSamara: Bool
    let scale: CGFloat
    let startY: CGFloat
    let lift: CGFloat
    let duration: Double
    let delay: Double
    let staticXNorm: CGFloat
    let staticRotation: CGFloat
}

struct PortholeDropletSpec {
    let xNorm: CGFloat
    let startY: CGFloat
    let slideDistance: CGFloat
    let radiusX: CGFloat
    let radiusY: CGFloat
    let duration: Double
    let delay: Double
    let staticSlideFraction: CGFloat
}

struct PortholeRippleSpec {
    let xNorm: CGFloat
    let yOffset: CGFloat
    let rx: CGFloat
    let ry: CGFloat
    let duration: Double
    let delay: Double
    let staticScale: CGFloat
    let staticOpacity: Float
}

@MainActor
enum PortholeWeatherGeometry {
    // MARK: - Doll Scale & Coordinate Mapping

    /// Scales the restored doll artwork (~82pt native span) to fit cleanly inside a 64pt porthole.
    static let dollScale: CGFloat = 0.54
    static let dollBounds = CGRect(x: 0, y: 0, width: 268, height: 128)
    static let dollPivot = CGPoint(x: 186, y: 8.0)

    /// Hairline horizon baseline, kept inside the unfeathered band above the 10pt bottom fade.
    static let horizonY: CGFloat = 51.5
    static let horizonTickCount: Int = 57
    static let birdLeftT: CGFloat = 0.425
    static let birdRightT: CGFloat = 0.485

    // MARK: - SVG Path Parser

    static func path(_ data: String) -> CGPath {
        let scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        let result = CGMutablePath()
        var command = "M"
        var point = CGPoint.zero
        var start = CGPoint.zero
        func number() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
        while !scanner.isAtEnd {
            if let next = scanner.scanCharacters(from: .letters) { command = next }
            let relative = command == command.lowercased()
            let origin = relative ? point : .zero
            func pair() -> CGPoint { CGPoint(x: number() + origin.x, y: number() + origin.y) }
            switch command.uppercased() {
            case "M":
                point = pair(); start = point; result.move(to: point)
                command = relative ? "l" : "L"
            case "L": point = pair(); result.addLine(to: point)
            case "H": point.x = number() + origin.x; result.addLine(to: point)
            case "V": point.y = number() + origin.y; result.addLine(to: point)
            case "C":
                let a = pair(), b = pair(), end = pair()
                result.addCurve(to: end, control1: a, control2: b); point = end
            case "Q":
                let control = pair(), end = pair()
                result.addQuadCurve(to: end, control: control); point = end
            case "Z": result.closeSubpath(); point = start; command = "M"
            default:
                assertionFailure("Unsupported porthole path command: \(command)")
                return result
            }
        }
        return result
    }

    // MARK: - Restored Weather Doll (Teru-teru-bozu)

    static let head = path("M197.927 34.991 C198.016 41.454 192.562 47.142 185.865 47.041 C179.645 46.943 173.846 41.362 174.096 34.940 C174.116 28.487 179.477 23.021 186.094 23.147 C192.498 22.869 198.158 28.637 198.006 34.946 Z")

    private static func projectHead(
        _ x: CGFloat, _ y: CGFloat, _ z: CGFloat,
        yaw: CGFloat, pitch: CGFloat
    ) -> CGPoint {
        let turnedX = x * cos(yaw) + z * sin(yaw)
        let turnedZ = -x * sin(yaw) + z * cos(yaw)
        return CGPoint(
            x: 186 + 11.8 * turnedX,
            y: 35.05 + 11.8 * (y * cos(pitch) + turnedZ * sin(pitch))
        )
    }

    private static func crescent(yaw: CGFloat, pitch: CGFloat) -> CGPath {
        let result = CGMutablePath()
        // Fixed sample topology keeps the highlight gap intact during path interpolation.
        let spans: [(CGFloat, CGFloat, CGFloat)] = [(0.08, 1.31, 0.9), (1.37, 1.52, 0.18)]
        let steps = 18
        for (start, end, width) in spans {
            let points = (0...steps).map { i in
                let angle = start + (end - start) * CGFloat(i) / CGFloat(steps)
                return projectHead(
                    0.88 * cos(angle), 0.88 * sin(angle), sqrt(1 - 0.88 * 0.88),
                    yaw: yaw, pitch: pitch
                )
            }
            var outer: [CGPoint] = [], inner: [CGPoint] = []
            for i in points.indices {
                let a = points[max(0, i - 1)], b = points[min(steps, i + 1)]
                let dx = b.x - a.x, dy = b.y - a.y
                let length = max(hypot(dx, dy), 0.0001)
                let halfWidth = width * pow(max(0, sin(.pi * CGFloat(i) / CGFloat(steps))), 0.55) / 2
                outer.append(CGPoint(
                    x: points[i].x - dy / length * halfWidth,
                    y: points[i].y + dx / length * halfWidth
                ))
                inner.append(CGPoint(
                    x: points[i].x + dy / length * halfWidth,
                    y: points[i].y - dx / length * halfWidth
                ))
            }
            result.move(to: outer[0])
            for point in outer.dropFirst() { result.addLine(to: point) }
            for point in inner.reversed() { result.addLine(to: point) }
            result.closeSubpath()
        }
        return result
    }

    private static func eyeArcs(yaw: CGFloat, pitch: CGFloat, archOffset: CGFloat) -> CGPath {
        let result = CGMutablePath()
        let centers: [CGFloat] = [-0.38, 0.38]
        for center in centers {
            for i in 0...20 {
                let t = CGFloat(i) / 20
                let x = center + (t - 0.5) * 0.30
                let y = 0.08 + archOffset * sin(.pi * t)
                let point = projectHead(x, y, sqrt(max(0, 1 - x * x - y * y)), yaw: yaw, pitch: pitch)
                if i == 0 { result.move(to: point) } else { result.addLine(to: point) }
            }
        }
        return result
    }

    static let headCrescent = crescent(yaw: 0, pitch: 0)
    static let eyes = eyeArcs(yaw: 0, pitch: 0, archOffset: 0.065)

    private static let breezeTurn: [CGFloat] = [0.8, 1.0, 0.8, 0.6]
    static let breezeHeadCrescent = breezeTurn.map { crescent(yaw: 0.28 * $0, pitch: 0.10 * $0) }
    static let breezeEyes = breezeTurn.map { eyeArcs(yaw: 0.28 * $0, pitch: 0.10 * $0, archOffset: 0.055) }
    static let breezeRing = breezeTurn.map { _ in ring }

    /// Lifted head and smiling upward-curved eyes when warm sunlight breaks through.
    static let doneHeadCrescent = crescent(yaw: 0.08, pitch: -0.10)
    static let doneEyes = eyeArcs(yaw: 0.08, pitch: -0.10, archOffset: -0.095)

    /// Slightly downcast head and heavy-lidded eyes in fine rain.
    static let failedHeadCrescent = crescent(yaw: -0.10, pitch: 0.27)
    static let failedEyes = eyeArcs(yaw: -0.10, pitch: 0.27, archOffset: 0.075)

    static let neckGather = path("M181.9 46.7Q186 48.05 190.1 46.7L190 48.4Q186 49.8 182 48.5Z")
    static let neckCrease = path("M182.4 47.25Q186 48.5 189.6 47.25")
    static let ring = CGPath(ellipseIn: CGRect(x: 184.5, y: 20, width: 3, height: 3), transform: nil)
    static let tie = path("M182 47.1C184.2 48 187.8 48 190 47.1 M182 48.5Q186 50 190 48.4 M190 48C193 44 197 46 193 49L190 48Q195 52 193 57L190 50 M190 49L188 57")

    /// Quadratic string path so resting and wind-tugged states share identical curve topology.
    static let string = path("M186 8 Q186 14.5 186 21")
    static let breezeStrings: [CGPath] = [
        path("M186 8 Q184.6 14.6 186 21.4"),
        path("M186 8 Q183.9 14.8 186 21.9"),
        path("M186 8 Q184.5 14.6 186 21.5"),
        path("M186 8 Q185.1 14.5 186 21.2")
    ]

    static let pleats: CGPath = {
        let result = CGMutablePath()
        for i in 0..<32 {
            let end = 163 + Double(i) * 1.59
            let start = 182.3 + Double(i) * 0.24
            result.addPath(path("M\(start) 51.5 C\(start + (end - start) * 0.22) 61 \(end + (186 - end) * 0.16) 77 \(end) \(84 + sin(Double(i) * 0.55) * 2.6)"))
        }
        return result
    }()

    static let cloth: [PortholeClothPath] = [
        PortholeClothPath(
            name: "body",
            idle: path("M182 47 C179 51 175.5 57.5 171.5 64 C166.5 71 161 78 158 81.5 C159.5 85.5 163.5 88 167.5 88 C170 88 171.5 85.5 173.5 85.5 C176 85.5 178 90.5 182.5 90.5 C186.5 90.5 188.5 87.5 190.5 87.5 C193.5 87.5 196 90 200 89.5 C204.5 89 204 84.5 207 84.5 C209.5 84.5 214.5 86.5 217.5 83 C218.5 82 219 80 218 79 C212 72.5 204 65.5 199 59.5 C194 54 192.5 49.5 190 47 C187.5 47.6 184.5 47.6 182 47 Z"),
            breeze: [
                path("M181.964 46.977 C179 51 176 57.5 172 64 C168 71.5 163 78.5 160.5 82.5 C162.5 86.5 166.5 89 170.5 89 C173 89 174.5 86.5 176.5 86.5 C179 86.5 182 91.5 186.5 91.5 C190.5 91 192 87 194.5 87 C198 86.5 201.5 88 206 87 C210.5 86 209 82 212 82 C215 81.5 221 82.5 223.5 79.5 C224 79 224 77 223 76 C214.5 71 205.5 65 199.5 59.5 C194.5 54 192.5 49.5 190.085 46.938 C187.597 47.6 184.46 47.6 181.918 47.078 Z"),
                path("M181.964 46.977 C179 51 176 57.5 172.5 64 C168.5 71 164 78 161.5 81 C163.5 85.5 167.5 88 172 88.5 C174.5 88.5 175.5 86 177.5 86.5 C180 86.5 183.5 92.5 188.5 92.5 C192.5 92.5 193.5 88.5 196 88.5 C200 88 203.5 90 208.5 88.5 C213 87 211 83 214 82.5 C217.5 81.5 224 82.5 226 79 C226.5 78 226 76 225 75.5 C216 71 206 65 199.5 59.5 C194.5 54 192.5 49.5 190.085 46.938 C187.597 47.6 184.46 47.6 181.918 47.078 Z"),
                path("M181.964 46.977 C179 51 176 57.5 172 64 C168 70.5 163 77 160.5 80.5 C162.5 84.5 166.5 86.5 170.5 86.5 C173 87 174.5 84.5 176.5 84.5 C179 85 182 90 186.5 91 C190.5 91 192 87.5 194.5 87.5 C198 87.5 201.5 90 206 89.5 C210.5 88.5 209 84.5 212 84 C215 83.5 221 85 223.5 81.5 C224 80.5 224 78.5 223 77.5 C214.5 72 205.5 65.5 199.5 59.5 C194.5 54 192.5 49.5 190.085 46.938 C187.597 47.6 184.46 47.6 181.918 47.078 Z"),
                path("M181.964 46.977 C179 51 176 57.5 171.5 64 C167 71 162 78 159 81.5 C161 85.5 165 87.5 169 87.5 C171.5 87 173 84.5 175 84.5 C177.5 84.5 180 89.5 184.5 89.5 C188.5 89.5 190 86 192.5 86 C195.5 86 198.5 88 203 88 C207.5 87.5 206.5 83.5 209.5 83.5 C212.5 83.5 217.5 85.5 220.5 82 C221.5 81.5 221.5 79.5 220.5 78.5 C213.5 72 205 65 199 59.5 C194.5 54 192.5 49.5 190.085 46.938 C187.597 47.6 184.46 47.6 181.918 47.078 Z")
            ],
            done: path("M182 47 C179 51 175.5 57.5 171.5 64 C167 70.5 162 77 159.5 80.5 C161.5 84 165 86 169.5 86 C172 86 173 84 175 84 C177.5 84 180.5 89 185 89 C189 88.5 190 85 192.5 85 C195.5 84.5 198.5 86 202.5 85.5 C206.5 84.5 205.5 81 208.5 80.5 C211 80 216 81 219 78 C220 77.5 220 75.5 219 75 C212.5 70.5 204.5 64.5 199 59 C194.5 54 192.5 49.5 190 47 C187.5 47.6 184.5 47.6 182 47 Z"),
            failed: path("M182 47 C179 51 176.5 58 173.5 64.5 C171 72.5 168.5 80.5 167 84.5 C169 89 172 90.5 174.5 90.5 C176.5 90.5 177 89 178.5 89 C180 89.5 181.5 90.5 184.5 90.5 C187 90.5 188 90.5 189.5 90.5 C191 90.5 192.5 90.5 195 90.5 C198 90.5 198 88 200 88 C202 88 204.5 90.5 207.5 86 C208.5 85.5 209.5 82.5 209 81.5 C206.5 74 201.5 66 197.5 60 C194 54 192.5 49.5 190 47 C187.5 47.6 184.5 47.6 182 47 Z")
        ),
        PortholeClothPath(
            name: "fold1",
            idle: path("M183 49 C181.5 58 175 74.5 173.5 85.5"),
            breeze: [
                path("M183 49 C181.5 58 177 75 176.5 86.5"),
                path("M183 49 C181.5 58 177.5 75 178 86.5"),
                path("M183 49 C181.5 58 177 74.5 176.5 84.5"),
                path("M183 49 C181.5 58 176 74 175 84.5")
            ],
            done: path("M183 49 C181.5 58 176 74 175.5 84"),
            failed: path("M183 49 C182 58 178 76.5 178.5 88.8")
        ),
        PortholeClothPath(
            name: "fold2",
            idle: path("M185.5 49 C186 61.5 189.5 78.5 190.5 87.5"),
            breeze: [
                path("M185.557 48.94 C186.5 61.5 192 78 194.5 87"),
                path("M185.557 48.94 C186.5 61.5 193 79 196 88.5"),
                path("M185.557 48.94 C186.5 61.5 192 78.5 194.5 87.5"),
                path("M185.557 48.94 C186 61.5 191 77.5 192.5 86")
            ],
            done: path("M185.5 49 C186 61 191 77 192.5 85"),
            failed: path("M185.5 49 C186 62 189 81 189.5 90.5")
        ),
        PortholeClothPath(
            name: "fold3",
            idle: path("M188 49 C191 60 203 75.5 207 84.5"),
            breeze: [
                path("M188.118 48.945 C191.5 60 206 74 212 81.5"),
                path("M188.118 48.945 C192 60 207 74.5 214.5 82.3"),
                path("M188.118 48.945 C191.5 60 206 75 212 84"),
                path("M188.118 48.945 C191.5 60 204.5 74.5 209.5 83.5")
            ],
            done: path("M188 49 C191.5 60 204 73.5 208.5 80.5"),
            failed: path("M188 49 C190.5 60.5 199 77.5 200.5 88")
        ),
        PortholeClothPath(
            name: "hatch1",
            idle: path("M188 76 L191 73 M190 75 L193 72.5 M192.5 74.5 L195 72 M194 74 L197 71"),
            breeze: [
                path("M190 76 L193 73 M192 75 L195 72 M194.5 74.5 L197 71.5 M196.5 73.5 L198.5 70.5"),
                path("M191 76.5 L194 73.5 M193 75.5 L196 72.5 M195.5 75 L197.5 72 M197 74 L199.5 71"),
                path("M190 76 L193 73 M192 75.5 L195 72.5 M194.5 75 L197 72 M196.5 74 L198.5 71"),
                path("M189 75 L192 72.5 M191 74.5 L194 72 M193.5 74 L196 71.5 M195.5 73.5 L198 71")
            ],
            done: path("M189 75 L192 72 M191 74 L194 71.5 M193 73.5 L195.5 70.5 M195 72.5 L197.5 70"),
            failed: path("M188 78 L190 75 M189.5 77 L192 74 M191 76.5 L193.5 73.5 M192.5 75.5 L195 72.5")
        ),
        PortholeClothPath(
            name: "hatch2",
            idle: path("M201.5 79 L204 76.5 M203.5 78.5 L206 76 M205.5 77.5 L208 75 M207.5 77 L210 74.5"),
            breeze: [
                path("M205 77.5 L207 75 M207 76.5 L209 74 M209 76 L211 73.5 M211 75 L213 72.5"),
                path("M206 78 L208.5 75.5 M208.5 77 L210.5 74.5 M210 76.5 L212.5 74 M212.5 75.5 L214.5 72.5"),
                path("M205 79 L207 76 M207 78 L209 75.5 M209 77.5 L211 74.5 M211 76.5 L213 74"),
                path("M203 78 L205.5 75.5 M205 77.5 L207.5 75 M207 77 L209.5 74.5 M209 76 L211.5 74")
            ],
            done: path("M202.5 76.5 L205 74 M204.5 75.5 L207 73.5 M206.5 75 L208.5 73 M208.5 74.5 L211 72"),
            failed: path("M197.5 81.5 L199.5 78.5 M199 80.5 L201 78 M200.5 80 L202.5 77 M202 79 L204.5 76")
        ),
        PortholeClothPath(
            name: "hatch3",
            idle: path("M207.5 83.5 L209 81.5 M209.5 82.5 L211 81 M211 82 L213 80.5"),
            breeze: [
                path("M212.5 80.5 L214 79 M214 80 L216 78.5 M216 79 L217.5 77.5"),
                path("M214.5 81.5 L216 79.5 M216.5 80 L218 78.5 M218.5 79 L219.5 77.5"),
                path("M212.5 83 L214 81 M214 82 L216 80 M216 81 L217.5 79.5"),
                path("M210 82.5 L211.5 81 M211.5 81.5 L213.5 80 M213.5 81 L215.5 79.5")
            ],
            done: path("M209 79.5 L210.5 78 M210.5 78.5 L212.5 77 M212.5 78 L214 76.5"),
            failed: path("M201 87 L202 84.5 M202 85.5 L204 84 M203.5 85 L205 83")
        )
    ]

    // MARK: - Clouds & Celestial Line Art

    /// Near drifting cumulus (~42x15pt) and inner engraving hatch/crease lines.
    static let cloudNear = path("M6.5 15.5 C0.5 15.5 0.2 8.2 6.0 7.6 C5.4 2.4 12.6 0.2 16.8 3.8 C21.2 -0.6 29.8 1.2 31.2 6.8 C39.4 5.4 42.2 15.5 34.0 15.5 Z")
    static let cloudNearCrease = path("M7.5 10.6 H16.5 M20.5 10.6 H32.5 M5.5 12.8 Q14.5 11.8 22.0 12.9 M24.8 13.1 Q30.0 12.2 35.0 13.2")

    /// Smaller, flatter distant cloud (~34x10pt) for slower background parallax.
    static let cloudFar = path("M4.5 10.2 C0.2 10.2 0.4 5.6 5.0 5.2 C6.2 1.8 12.5 0.8 16.2 3.4 C20.4 0.8 27.2 2.2 28.4 5.8 C33.8 5.2 35.2 10.2 29.8 10.2 Z")

    static let crescentMoon: CGPath = {
        let r1: CGFloat = 5.0
        let dx: CGFloat = 2.15
        let dy: CGFloat = -1.30
        let r2: CGFloat = 4.30
        let d = hypot(dx, dy)
        let base = atan2(dy, dx)
        let alpha1 = acos(min(1, max(-1, (d * d + r1 * r1 - r2 * r2) / (2 * d * r1))))
        let alpha2 = acos(min(1, max(-1, (d * d + r2 * r2 - r1 * r1) / (2 * d * r2))))

        let start1 = base + alpha1
        let end1 = base + 2 * .pi - alpha1
        let start2 = base + .pi + alpha2
        let end2 = base + .pi - alpha2

        let result = CGMutablePath()
        let steps = 32
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let a = start1 + (end1 - start1) * t
            let pt = CGPoint(x: r1 * cos(a), y: r1 * sin(a))
            if i == 0 { result.move(to: pt) } else { result.addLine(to: pt) }
        }
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let a = start2 + (end2 - start2) * t
            let pt = CGPoint(x: dx + r2 * cos(a), y: dy + r2 * sin(a))
            result.addLine(to: pt)
        }
        result.closeSubpath()
        return result
    }()

    /// Fine ink cross-star (with tiny diagonal glints on major stars).
    static func starCrossPath(radius r: CGFloat, isMajor: Bool) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -r))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.move(to: CGPoint(x: -r, y: 0))
        p.addLine(to: CGPoint(x: r, y: 0))
        if isMajor {
            let d = r * 0.44
            p.move(to: CGPoint(x: -d, y: -d))
            p.addLine(to: CGPoint(x: d, y: d))
            p.move(to: CGPoint(x: -d, y: d))
            p.addLine(to: CGPoint(x: d, y: -d))
        }
        return p
    }

    static let stars: [PortholeStarSpec] = [
        PortholeStarSpec(xNorm: 0.17, y: 13.5, radius: 1.50, isMajor: false, duration: 4.8, delay: 0.3, staticOpacity: 0.72),
        PortholeStarSpec(xNorm: 0.28, y: 23.5, radius: 1.25, isMajor: false, duration: 5.7, delay: 1.4, staticOpacity: 0.50),
        PortholeStarSpec(xNorm: 0.44, y: 12.0, radius: 1.95, isMajor: true,  duration: 6.4, delay: 0.9, staticOpacity: 0.86),
        PortholeStarSpec(xNorm: 0.52, y: 22.0, radius: 1.30, isMajor: false, duration: 5.2, delay: 3.1, staticOpacity: 0.54),
        PortholeStarSpec(xNorm: 0.59, y: 13.2, radius: 1.85, isMajor: true,  duration: 6.8, delay: 1.9, staticOpacity: 0.84),
        PortholeStarSpec(xNorm: 0.64, y: 26.0, radius: 1.20, isMajor: false, duration: 4.9, delay: 0.7, staticOpacity: 0.46),
        PortholeStarSpec(xNorm: 0.80, y: 14.5, radius: 1.50, isMajor: false, duration: 5.5, delay: 2.6, staticOpacity: 0.68)
    ]

    // MARK: - Horizon Ruler, Hatched Far Hills, Roofline, Smoke, Poles & Perched Birds

    static func horizonLinePath(width w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 6, y: horizonY))
        p.addLine(to: CGPoint(x: max(6, w - 6), y: horizonY))
        return p
    }

    static func horizonTicksPath(width w: CGFloat) -> CGPath {
        let count = max(2, horizonTickCount)
        let span = max(0, w - 36)
        let p = CGMutablePath()
        for index in 0..<count {
            let x = 18 + CGFloat(index) * span / CGFloat(count - 1)
            let len: CGFloat = index % 5 == 0 ? 2.6 : 1.4
            p.move(to: CGPoint(x: x, y: horizonY))
            p.addLine(to: CGPoint(x: x, y: horizonY + len))
        }
        return p
    }

    private static func appendFarHillsRidge(to p: CGMutablePath, width w: CGFloat) {
        p.addCurve(
            to: CGPoint(x: w * 0.31, y: 39.6),
            control1: CGPoint(x: w * 0.12, y: 40.2),
            control2: CGPoint(x: w * 0.22, y: 39.2)
        )
        p.addCurve(
            to: CGPoint(x: w * 0.62, y: 45.4),
            control1: CGPoint(x: w * 0.42, y: 40.4),
            control2: CGPoint(x: w * 0.52, y: 46.2)
        )
        p.addCurve(
            to: CGPoint(x: w - 4, y: 43.2),
            control1: CGPoint(x: w * 0.74, y: 44.6),
            control2: CGPoint(x: w * 0.87, y: 39.8)
        )
    }

    static func farHillsRidgePath(width w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 4, y: 45.8))
        appendFarHillsRidge(to: p, width: w)
        return p
    }

    static func farHillsClipPath(width w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 4, y: horizonY))
        p.addLine(to: CGPoint(x: 4, y: 45.8))
        appendFarHillsRidge(to: p, width: w)
        p.addLine(to: CGPoint(x: w - 4, y: horizonY))
        p.closeSubpath()
        return p
    }

    /// Sparse ~48° diagonal engraving hatching clipped to the far hills silhouette.
    static func farHillsHatchPath(width w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let spacing: CGFloat = 5.8
        var x: CGFloat = -16
        while x <= w + 16 {
            p.move(to: CGPoint(x: x, y: horizonY + 1))
            p.addLine(to: CGPoint(x: x + 13.5, y: 37.5))
            x += spacing
        }
        return p
    }

    private static func appendLeftRoofline(to p: CGMutablePath, width w: CGFloat) {
        // Soft left garden canopy
        p.addQuadCurve(
            to: CGPoint(x: w * 0.145, y: 49.6),
            control: CGPoint(x: w * 0.095, y: 47.4)
        )
        // Pitched cottage gable + tiny chimney
        p.addLine(to: CGPoint(x: w * 0.168, y: 48.2))
        p.addLine(to: CGPoint(x: w * 0.218, y: 41.8))
        p.addLine(to: CGPoint(x: w * 0.246, y: 44.6))
        p.addLine(to: CGPoint(x: w * 0.246, y: 40.8))
        p.addLine(to: CGPoint(x: w * 0.262, y: 40.8))
        p.addLine(to: CGPoint(x: w * 0.262, y: 46.2))
        p.addLine(to: CGPoint(x: w * 0.276, y: 47.6))
        // Lower garden annex stepping into low central hedgerow
        p.addLine(to: CGPoint(x: w * 0.312, y: 47.6))
        p.addLine(to: CGPoint(x: w * 0.326, y: 50.8))
        p.addCurve(
            to: CGPoint(x: w * 0.52, y: horizonY),
            control1: CGPoint(x: w * 0.39, y: 49.4),
            control2: CGPoint(x: w * 0.46, y: 51.6)
        )
    }

    private static func appendRightRoofline(to p: CGMutablePath, width w: CGFloat) {
        p.addLine(to: CGPoint(x: w * 0.835, y: 49.0))
        p.addLine(to: CGPoint(x: w * 0.905, y: 49.0))
        p.addQuadCurve(
            to: CGPoint(x: w * 0.955, y: horizonY),
            control: CGPoint(x: w * 0.935, y: 49.4)
        )
    }

    static func rooftopStrokePath(width w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 4, y: horizonY))
        appendLeftRoofline(to: p, width: w)
        // Open pocket around 0.52w..0.81w leaves clean breathing room beneath birds and doll.
        p.move(to: CGPoint(x: w * 0.81, y: horizonY))
        appendRightRoofline(to: p, width: w)
        return p
    }

    static func rooftopDetailPath(width w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        // Cottage eave & vertical wall lines down to horizon
        p.move(to: CGPoint(x: w * 0.174, y: 48.1))
        p.addLine(to: CGPoint(x: w * 0.268, y: 48.1))
        p.move(to: CGPoint(x: w * 0.179, y: 48.1))
        p.addLine(to: CGPoint(x: w * 0.179, y: horizonY))
        p.move(to: CGPoint(x: w * 0.263, y: 47.8))
        p.addLine(to: CGPoint(x: w * 0.263, y: horizonY))
        // Subtle daytime attic window outline
        p.addRoundedRect(in: litWindowRect(width: w), cornerWidth: 0.45, cornerHeight: 0.45)
        return p
    }

    /// Even-odd mask path that keeps far-hill strokes and hatching strictly behind the foreground roofline.
    static func rooftopOcclusionPath(width w: CGFloat, height h: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addRect(CGRect(x: -4, y: -4, width: w + 8, height: h + 8))
        p.move(to: CGPoint(x: -2, y: horizonY))
        p.addLine(to: CGPoint(x: 4, y: horizonY))
        appendLeftRoofline(to: p, width: w)
        p.addLine(to: CGPoint(x: w * 0.81, y: horizonY))
        appendRightRoofline(to: p, width: w)
        p.addLine(to: CGPoint(x: w + 2, y: horizonY))
        p.addLine(to: CGPoint(x: w + 2, y: h + 4))
        p.addLine(to: CGPoint(x: -2, y: h + 4))
        p.closeSubpath()
        return p
    }

    static func chimneyTop(width w: CGFloat) -> CGPoint {
        CGPoint(x: (w * 0.254).rounded(), y: 40.0)
    }

    static let smokeCurls: [PortholeSmokeSpec] = [
        PortholeSmokeSpec(
            path: path("M0 0 C-1.5 -2.2 1.7 -4.3 0.3 -6.6"),
            driftX: 4.2, breezeDriftX: 13.0, riseY: -13.0,
            duration: 10.2, delay: 2.2,
            staticOffset: CGPoint(x: 0.9, y: -2.4), staticOpacity: 0.78
        ),
        PortholeSmokeSpec(
            path: path("M0 0 C1.4 -2.0 -1.6 -4.0 -0.2 -6.0"),
            driftX: 5.8, breezeDriftX: 16.5, riseY: -15.0,
            duration: 11.6, delay: 5.8,
            staticOffset: CGPoint(x: 2.6, y: -6.8), staticOpacity: 0.50
        ),
        PortholeSmokeSpec(
            path: path("M0 0 C-1.2 -1.8 1.3 -3.5 0.4 -5.2"),
            driftX: 7.4, breezeDriftX: 19.5, riseY: -16.8,
            duration: 12.8, delay: 9.6,
            staticOffset: CGPoint(x: 4.5, y: -11.0), staticOpacity: 0.26
        )
    ]

    static func litWindowRect(width w: CGFloat) -> CGRect {
        CGRect(x: (w * 0.218).rounded() - 1.2, y: 44.8, width: 2.4, height: 2.8)
    }

    static func telegraphPolesPath(width w: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let lx = (w * 0.145).rounded() + 0.5
        p.move(to: CGPoint(x: lx, y: horizonY))
        p.addLine(to: CGPoint(x: lx, y: 30.5))
        p.move(to: CGPoint(x: lx - 3.0, y: 32.2))
        p.addLine(to: CGPoint(x: lx + 3.0, y: 32.2))
        p.move(to: CGPoint(x: lx - 2.4, y: 35.0))
        p.addLine(to: CGPoint(x: lx + 2.4, y: 35.0))

        let rx = (w * 0.865).rounded() + 0.5
        p.move(to: CGPoint(x: rx, y: horizonY))
        p.addLine(to: CGPoint(x: rx, y: 35.5))
        p.move(to: CGPoint(x: rx - 2.2, y: 37.0))
        p.addLine(to: CGPoint(x: rx + 2.2, y: 37.0))
        p.move(to: CGPoint(x: rx - 1.8, y: 39.6))
        p.addLine(to: CGPoint(x: rx + 1.8, y: 39.6))
        return p
    }

    private static let idleWireParams: (sag1: CGFloat, sag2: CGFloat, driftX: CGFloat) = (5.4, 5.8, 0.0)
    private static let breezeWireParams: [(sag1: CGFloat, sag2: CGFloat, driftX: CGFloat)] = [
        (2.2, 2.8, 4.2),
        (4.0, 4.5, 1.8),
        (1.4, 2.0, 5.6),
        (3.2, 3.8, 3.0)
    ]

    private static func upperWireControlPoints(
        width w: CGFloat,
        sag1: CGFloat,
        driftX: CGFloat
    ) -> (p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint) {
        let lx = (w * 0.145).rounded() + 0.5
        let rx = (w * 0.865).rounded() + 0.5
        let span = rx - lx
        return (
            p0: CGPoint(x: lx + 2.2, y: 32.2),
            c1: CGPoint(x: lx + span * 0.34 + driftX, y: 34.0 + sag1),
            c2: CGPoint(x: lx + span * 0.68 + driftX, y: 35.8 + sag1),
            p3: CGPoint(x: rx - 1.6, y: 37.0)
        )
    }

    private static func cubicBezierPoint(
        _ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, t: CGFloat
    ) -> CGPoint {
        let u = 1.0 - t
        let uu = u * u
        let tt = t * t
        let w0 = uu * u
        let w1 = 3.0 * uu * t
        let w2 = 3.0 * u * tt
        let w3 = tt * t
        return CGPoint(
            x: w0 * p0.x + w1 * c1.x + w2 * c2.x + w3 * p3.x,
            y: w0 * p0.y + w1 * c1.y + w2 * c2.y + w3 * p3.y
        )
    }

    private static func catenaryPair(
        width w: CGFloat,
        sag1: CGFloat,
        sag2: CGFloat,
        driftX: CGFloat
    ) -> CGPath {
        let upper = upperWireControlPoints(width: w, sag1: sag1, driftX: driftX)
        let lx = (w * 0.145).rounded() + 0.5
        let rx = (w * 0.865).rounded() + 0.5
        let span = rx - lx
        let p = CGMutablePath()

        p.move(to: upper.p0)
        p.addCurve(to: upper.p3, control1: upper.c1, control2: upper.c2)

        p.move(to: CGPoint(x: lx + 1.8, y: 35.0))
        p.addCurve(
            to: CGPoint(x: rx - 1.4, y: 39.6),
            control1: CGPoint(x: lx + span * 0.34 + driftX * 0.85, y: 36.6 + sag2),
            control2: CGPoint(x: lx + span * 0.68 + driftX * 0.85, y: 38.2 + sag2)
        )
        return p
    }

    static func telegraphWires(width w: CGFloat) -> (idle: CGPath, breeze: [CGPath]) {
        let idle = catenaryPair(
            width: w,
            sag1: idleWireParams.sag1,
            sag2: idleWireParams.sag2,
            driftX: idleWireParams.driftX
        )
        let breeze = breezeWireParams.map { item in
            catenaryPair(width: w, sag1: item.sag1, sag2: item.sag2, driftX: item.driftX)
        }
        return (idle, breeze)
    }

    static func upperWirePositions(width w: CGFloat, t: CGFloat) -> (idle: CGPoint, breeze: [CGPoint]) {
        let idleCP = upperWireControlPoints(
            width: w,
            sag1: idleWireParams.sag1,
            driftX: idleWireParams.driftX
        )
        let idlePt = cubicBezierPoint(idleCP.p0, idleCP.c1, idleCP.c2, idleCP.p3, t: t)
        let breezePts = breezeWireParams.map { item in
            let cp = upperWireControlPoints(width: w, sag1: item.sag1, driftX: item.driftX)
            return cubicBezierPoint(cp.p0, cp.c1, cp.c2, cp.p3, t: t)
        }
        return (idlePt, breezePts)
    }

    /// Tiny perched songbird in line art, anchored at `(0, 0)` where its feet grip the wire.
    static func birdPath(facingRight: Bool) -> CGPath {
        let p = CGMutablePath()
        // Plump body + round head + flicked tail
        p.move(to: CGPoint(x: 1.15, y: -1.35))
        p.addCurve(
            to: CGPoint(x: 1.35, y: -2.85),
            control1: CGPoint(x: 1.55, y: -1.85),
            control2: CGPoint(x: 1.65, y: -2.45)
        )
        p.addQuadCurve(
            to: CGPoint(x: 0.35, y: -3.20),
            control: CGPoint(x: 0.95, y: -3.35)
        )
        p.addCurve(
            to: CGPoint(x: -1.35, y: -1.85),
            control1: CGPoint(x: -0.25, y: -2.95),
            control2: CGPoint(x: -0.85, y: -2.30)
        )
        p.addLine(to: CGPoint(x: -2.55, y: -2.55))
        p.addLine(to: CGPoint(x: -2.25, y: -1.95))
        p.addCurve(
            to: CGPoint(x: 1.15, y: -1.35),
            control1: CGPoint(x: -1.05, y: -1.05),
            control2: CGPoint(x: 0.45, y: -0.85)
        )
        p.closeSubpath()

        // Tiny beak, folded wing line & V-legs touching (0, 0)
        p.move(to: CGPoint(x: 1.42, y: -2.62))
        p.addLine(to: CGPoint(x: 2.02, y: -2.46))
        p.addLine(to: CGPoint(x: 1.38, y: -2.30))

        p.move(to: CGPoint(x: 0.35, y: -2.20))
        p.addQuadCurve(to: CGPoint(x: -1.00, y: -1.85), control: CGPoint(x: -0.35, y: -1.70))

        p.move(to: CGPoint(x: -0.35, y: 0.0))
        p.addLine(to: CGPoint(x: -0.15, y: -1.05))
        p.move(to: CGPoint(x: 0.42, y: 0.0))
        p.addLine(to: CGPoint(x: 0.18, y: -1.05))

        if facingRight { return p }
        var flip = CGAffineTransform(scaleX: -1, y: 1)
        return p.copy(using: &flip) ?? p
    }

    // MARK: - Event Weather Effects (Sunlight, Breeze, Fine Rain)

    static func sunOrigin(width w: CGFloat) -> CGPoint {
        CGPoint(x: (w * 0.41).rounded(), y: 14.5)
    }

    static let sunDisc: CGPath = {
        let p = CGMutablePath()
        for r: CGFloat in [3.8, 5.1, 6.4] {
            p.addEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        }
        return p
    }()

    static let sunCoronaTicks: CGPath = {
        let p = CGMutablePath()
        for i in 0..<32 {
            let len: CGFloat = i % 4 == 0 ? 3.0 : 1.4
            let tick = CGMutablePath()
            tick.move(to: CGPoint(x: 0, y: -8.0))
            tick.addLine(to: CGPoint(x: 0, y: -8.0 - len))
            p.addPath(tick, transform: CGAffineTransform(rotationAngle: CGFloat(i) * .pi / 16))
        }
        return p
    }()

    static let sunRays: [PortholeSunRaySpec] = [
        PortholeSunRaySpec(baseAngle: 0.42, lengthFactor: 0.46, spread: 0.11, sweepDelta: 0.045,  duration: 15.2, delay: 0.0, weight: 0.96),
        PortholeSunRaySpec(baseAngle: 0.96, lengthFactor: 0.36, spread: 0.12, sweepDelta: -0.052, duration: 17.8, delay: 1.9, weight: 1.00),
        PortholeSunRaySpec(baseAngle: 2.08, lengthFactor: 0.36, spread: 0.12, sweepDelta: 0.048,  duration: 16.4, delay: 3.7, weight: 0.90),
        PortholeSunRaySpec(baseAngle: 2.66, lengthFactor: 0.44, spread: 0.10, sweepDelta: -0.042, duration: 18.6, delay: 5.1, weight: 0.86)
    ]

    /// Bundle of fine diverging ray strokes radiating from outside the sun corona.
    static func sunRayBundlePath(length: CGFloat, spread: CGFloat, midY: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let rays: [(angle: CGFloat, startR: CGFloat, endFactor: CGFloat)] = [
            (-spread, 12.2, 0.86),
            (0.0,     11.4, 1.00),
            (spread,  12.6, 0.90)
        ]
        for ray in rays where length * ray.endFactor > ray.startR + 4 {
            let ca = cos(ray.angle)
            let sa = sin(ray.angle)
            let r1 = length * ray.endFactor
            p.move(to: CGPoint(x: ray.startR * ca, y: midY + ray.startR * sa))
            p.addLine(to: CGPoint(x: r1 * ca, y: midY + r1 * sa))
        }
        return p
    }

    static let windStreaks: [PortholeWindStreakSpec] = [
        PortholeWindStreakSpec(path: path("M0 0 C14 -2.2 28 2.0 44 -0.6 M49 -0.8 H58"), y: 13.5, startOffsetNorm: 0.05, duration: 2.7, delay: 0.95, peakOpacity: 0.82, staticXNorm: 0.18),
        PortholeWindStreakSpec(path: path("M0 0 C18 1.8 34 -2.4 54 -0.4"),               y: 20.0, startOffsetNorm: 0.28, duration: 3.1, delay: 0.55, peakOpacity: 0.90, staticXNorm: 0.42),
        PortholeWindStreakSpec(path: path("M0 0 C12 -1.6 25 1.6 38 0.0 M43 0.0 H50"),    y: 26.8, startOffsetNorm: 0.52, duration: 2.5, delay: 1.15, peakOpacity: 0.76, staticXNorm: 0.26),
        PortholeWindStreakSpec(path: path("M0 0 C20 -2.4 38 2.2 60 -0.8"),               y: 33.5, startOffsetNorm: 0.14, duration: 3.4, delay: 1.70, peakOpacity: 0.84, staticXNorm: 0.50),
        PortholeWindStreakSpec(path: path("M0 0 C15 1.6 30 -1.8 46 -0.2 M50 -0.2 H57"),  y: 40.5, startOffsetNorm: 0.40, duration: 2.9, delay: 2.25, peakOpacity: 0.70, staticXNorm: 0.16),
        PortholeWindStreakSpec(path: path("M0 0 C13 -1.5 26 1.5 40 -0.4"),               y: 46.2, startOffsetNorm: 0.66, duration: 3.2, delay: 0.85, peakOpacity: 0.62, staticXNorm: 0.58)
    ]

    static let leafBody: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -1.02, y: 0.18))
        p.addCurve(to: CGPoint(x: 1.06, y: -0.16), control1: CGPoint(x: -0.42, y: -0.44), control2: CGPoint(x: 0.46, y: -0.42))
        p.addCurve(to: CGPoint(x: -1.02, y: 0.18), control1: CGPoint(x: 0.52, y: 0.34), control2: CGPoint(x: -0.30, y: 0.52))
        p.closeSubpath()
        p.move(to: CGPoint(x: -0.84, y: 0.14))
        p.addQuadCurve(to: CGPoint(x: 0.82, y: -0.12), control: CGPoint(x: 0.02, y: -0.04))
        return p
    }()

    static let samaraBody: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -0.95, y: 0.04))
        p.addCurve(to: CGPoint(x: 1.08, y: -0.10), control1: CGPoint(x: -0.45, y: -0.34), control2: CGPoint(x: 0.52, y: -0.36))
        p.addCurve(to: CGPoint(x: -0.55, y: 0.20), control1: CGPoint(x: 0.92, y: 0.42), control2: CGPoint(x: 0.05, y: 0.56))
        p.addCurve(to: CGPoint(x: -0.95, y: 0.04), control1: CGPoint(x: -0.76, y: 0.25), control2: CGPoint(x: -0.90, y: 0.18))
        p.closeSubpath()
        p.move(to: CGPoint(x: -0.68, y: 0.06))
        p.addQuadCurve(to: CGPoint(x: 0.78, y: -0.06), control: CGPoint(x: 0.08, y: 0.06))
        return p
    }()

    static let windLeaves: [PortholeWindLeafSpec] = [
        PortholeWindLeafSpec(isSamara: false, scale: 3.4, startY: 22.0, lift: 7.0, duration: 4.2, delay: 1.65, staticXNorm: 0.38, staticRotation: -0.28),
        PortholeWindLeafSpec(isSamara: true,  scale: 3.1, startY: 35.5, lift: 5.5, duration: 4.9, delay: 2.85, staticXNorm: 0.59, staticRotation: 0.22)
    ]

    private static func windLeafControlPoints(
        width w: CGFloat,
        spec: PortholeWindLeafSpec
    ) -> (p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint) {
        (
            p0: CGPoint(x: -18, y: spec.startY + 2.0),
            c1: CGPoint(x: w * 0.34, y: spec.startY - spec.lift * 0.85),
            c2: CGPoint(x: w * 0.68, y: spec.startY + 2.5),
            p3: CGPoint(x: w + 22, y: spec.startY - spec.lift)
        )
    }

    static func windLeafRoutePath(width w: CGFloat, spec: PortholeWindLeafSpec) -> CGPath {
        let cp = windLeafControlPoints(width: w, spec: spec)
        let route = CGMutablePath()
        route.move(to: cp.p0)
        route.addCurve(to: cp.p3, control1: cp.c1, control2: cp.c2)
        return route
    }

    static func windLeafPosition(width w: CGFloat, spec: PortholeWindLeafSpec, progress: CGFloat) -> CGPoint {
        let cp = windLeafControlPoints(width: w, spec: spec)
        let clamped = min(1, max(0, progress))
        let samples = 24
        var pts: [CGPoint] = []
        pts.reserveCapacity(samples + 1)
        var cumLen: [CGFloat] = [0]
        cumLen.reserveCapacity(samples + 1)
        var total: CGFloat = 0
        for i in 0...samples {
            let pt = cubicBezierPoint(cp.p0, cp.c1, cp.c2, cp.p3, t: CGFloat(i) / CGFloat(samples))
            if let prev = pts.last {
                total += hypot(pt.x - prev.x, pt.y - prev.y)
                cumLen.append(total)
            }
            pts.append(pt)
        }
        guard total > 0.0001 else { return cp.p0 }
        let target = clamped * total
        for i in 1...samples where cumLen[i] >= target {
            let segLen = cumLen[i] - cumLen[i - 1]
            let f = segLen > 0.0001 ? (target - cumLen[i - 1]) / segLen : 0
            return CGPoint(
                x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
                y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * f
            )
        }
        return cp.p3
    }

    // Seamless diagonal rain cycle constants (9.8° slant matching WeatherCanvas)
    static let rainSlantRadians: CGFloat = 9.8 * .pi / 180.0
    static let rainCycleHeight: CGFloat = 68.0
    static var rainCycleDriftX: CGFloat { -tan(rainSlantRadians) * rainCycleHeight }

    private static func seeded(_ index: Int, _ salt: Double) -> CGFloat {
        let raw = sin(Double(index) * 127.1 + salt * 311.7) * 43_758.5453123
        return CGFloat(raw - floor(raw))
    }

    /// Builds 5 compound rain-streak planes that tile seamlessly along `(rainCycleDriftX, rainCycleHeight)`.
    static func rainPlanePaths(width w: CGFloat, isNear: Bool) -> [CGPath] {
        let planeCount = 5
        let streaksPerPlane = isNear ? 3 : 4
        let ux = -sin(rainSlantRadians)
        let uy = cos(rainSlantRadians)
        let cycleH = rainCycleHeight
        let cycleDX = rainCycleDriftX
        let spanW = max(180, w + 28)

        return (0..<planeCount).map { plane in
            let p = CGMutablePath()
            for s in 0..<streaksPerPlane {
                let seedIndex = (isNear ? 100 : 0) + plane * 11 + s * 3
                let lane = (CGFloat(s) + 0.18 + seeded(seedIndex, 1.7) * 0.64) / CGFloat(streaksPerPlane)
                let baseX = -8 + lane * spanW + (CGFloat(plane) - 2) * 4.5
                let baseY = seeded(seedIndex, 5.3) * cycleH
                let len: CGFloat = isNear
                    ? (12.5 + seeded(seedIndex, 8.9) * 6.0)
                    : (8.5 + seeded(seedIndex, 8.9) * 4.2)

                // The loop moves planes down one period; tiles -2...0 keep tails that straddle the top edge continuous across the wrap.
                for k in [-2, -1, 0] {
                    let kf = CGFloat(k)
                    let sx = baseX + kf * cycleDX
                    let sy = baseY + kf * cycleH
                    p.move(to: CGPoint(x: sx, y: sy))
                    p.addLine(to: CGPoint(x: sx + ux * len, y: sy + uy * len))
                }
            }
            return p
        }
    }

    static func dropletPath(rx: CGFloat, ry: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -ry * 1.25))
        p.addCurve(
            to: CGPoint(x: 0, y: ry),
            control1: CGPoint(x: rx * 1.15, y: -ry * 0.35),
            control2: CGPoint(x: rx * 1.05, y: ry * 0.85)
        )
        p.addCurve(
            to: CGPoint(x: 0, y: -ry * 1.25),
            control1: CGPoint(x: -rx * 1.05, y: ry * 0.85),
            control2: CGPoint(x: -rx * 1.15, y: -ry * 0.35)
        )
        p.closeSubpath()
        return p
    }

    static let droplets: [PortholeDropletSpec] = [
        PortholeDropletSpec(xNorm: 0.21, startY: 13.0, slideDistance: 29.0, radiusX: 0.92, radiusY: 1.40, duration: 4.8, delay: 1.3, staticSlideFraction: 0.28),
        PortholeDropletSpec(xNorm: 0.43, startY: 16.0, slideDistance: 28.0, radiusX: 1.05, radiusY: 1.58, duration: 5.5, delay: 1.9, staticSlideFraction: 0.56),
        PortholeDropletSpec(xNorm: 0.57, startY: 11.5, slideDistance: 32.0, radiusX: 0.88, radiusY: 1.32, duration: 4.4, delay: 3.1, staticSlideFraction: 0.42),
        PortholeDropletSpec(xNorm: 0.79, startY: 17.5, slideDistance: 26.0, radiusX: 1.00, radiusY: 1.50, duration: 5.2, delay: 0.9, staticSlideFraction: 0.68)
    ]

    static let sillRipples: [PortholeRippleSpec] = [
        PortholeRippleSpec(xNorm: 0.24, yOffset: 0.8, rx: 5.4, ry: 0.95, duration: 2.3, delay: 0.35, staticScale: 0.68, staticOpacity: 0.72),
        PortholeRippleSpec(xNorm: 0.44, yOffset: 1.4, rx: 6.8, ry: 1.10, duration: 2.7, delay: 0.80, staticScale: 0.92, staticOpacity: 0.48),
        PortholeRippleSpec(xNorm: 0.59, yOffset: 0.7, rx: 4.8, ry: 0.88, duration: 2.1, delay: 0.20, staticScale: 0.48, staticOpacity: 0.80),
        PortholeRippleSpec(xNorm: 0.78, yOffset: 1.2, rx: 6.0, ry: 1.02, duration: 2.5, delay: 0.55, staticScale: 0.80, staticOpacity: 0.56)
    ]
}
