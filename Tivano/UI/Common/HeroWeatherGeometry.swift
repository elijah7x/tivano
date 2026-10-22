import CoreGraphics
import Foundation

@MainActor
enum HeroWeatherGeometry {
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
                // Bad path data should draw nothing rather than take the app down.
                assertionFailure("Unsupported hero path command: \(command)")
                return result
            }
        }
        return result
    }

    static let head = path("M197.927 34.991 C198.016 41.454 192.562 47.142 185.865 47.041 C179.645 46.943 173.846 41.362 174.096 34.940 C174.116 28.487 179.477 23.021 186.094 23.147 C192.498 22.869 198.158 28.637 198.006 34.946 Z")
    private static func projectHead(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat,
                                    yaw: CGFloat, pitch: CGFloat) -> CGPoint {
        let turnedX = x * cos(yaw) + z * sin(yaw)
        let turnedZ = -x * sin(yaw) + z * cos(yaw)
        return CGPoint(x: 186 + 11.8 * turnedX,
                       y: 35.05 + 11.8 * (y * cos(pitch) + turnedZ * sin(pitch)))
    }

    private static func crescent(yaw: CGFloat, pitch: CGFloat) -> CGPath {
        let result = CGMutablePath()
        // Fixed sample topology keeps the highlight gap intact during path interpolation.
        let spans: [(CGFloat, CGFloat, CGFloat)] = [(0.08, 1.31, 0.9), (1.37, 1.52, 0.18)]
        for (start, end, width) in spans {
            let points = (0...70).map { i in
                let angle = start + (end - start) * CGFloat(i) / 70
                return projectHead(0.88 * cos(angle), 0.88 * sin(angle), sqrt(1 - 0.88 * 0.88),
                                   yaw: yaw, pitch: pitch)
            }
            var outer: [CGPoint] = [], inner: [CGPoint] = []
            for i in points.indices {
                let a = points[max(0, i - 1)], b = points[min(70, i + 1)]
                let dx = b.x - a.x, dy = b.y - a.y
                let length = max(hypot(dx, dy), 0.0001)
                let halfWidth = width * pow(max(0, sin(.pi * CGFloat(i) / 70)), 0.55) / 2
                outer.append(CGPoint(x: points[i].x - dy / length * halfWidth,
                                     y: points[i].y + dx / length * halfWidth))
                inner.append(CGPoint(x: points[i].x + dy / length * halfWidth,
                                     y: points[i].y - dx / length * halfWidth))
            }
            result.move(to: outer[0])
            for point in outer.dropFirst() { result.addLine(to: point) }
            for point in inner.reversed() { result.addLine(to: point) }
            result.closeSubpath()
        }
        return result
    }

    private static func closedEyes(yaw: CGFloat, pitch: CGFloat) -> CGPath {
        let result = CGMutablePath()
        let centers: [CGFloat] = [-0.38, 0.38]
        for center in centers {
            for i in 0...20 {
                let t = CGFloat(i) / 20
                let x = center + (t - 0.5) * 0.30
                let y = 0.08 + 0.065 * sin(.pi * t)
                let point = projectHead(x, y, sqrt(max(0, 1 - x * x - y * y)), yaw: yaw, pitch: pitch)
                if i == 0 { result.move(to: point) } else { result.addLine(to: point) }
            }
        }
        return result
    }

    static let headCrescent = crescent(yaw: 0, pitch: 0)
    static let eyes = closedEyes(yaw: 0, pitch: 0)
    private static let runningTurn: [CGFloat] = [0.8, 1, 0.8, 0.6]
    static let runningHeadCrescent = runningTurn.map { crescent(yaw: 0.28 * $0, pitch: 0.10 * $0) }
    static let runningEyes = runningTurn.map { closedEyes(yaw: 0.28 * $0, pitch: 0.10 * $0) }
    static let runningRing = runningTurn.map { _ in ring }
    static let failedHeadCrescent = crescent(yaw: -0.10, pitch: 0.27)
    static let failedEyes = closedEyes(yaw: -0.10, pitch: 0.27)
    static let neckGather = path("M181.9 46.7Q186 48.05 190.1 46.7L190 48.4Q186 49.8 182 48.5Z")
    static let neckCrease = path("M182.4 47.25Q186 48.5 189.6 47.25")
    static let ring = CGPath(ellipseIn: CGRect(x: 184.5, y: 20, width: 3, height: 3), transform: nil)
    static let tie = path("M182 47.1C184.2 48 187.8 48 190 47.1 M182 48.5Q186 50 190 48.4 M190 48C193 44 197 46 193 49L190 48Q195 52 193 57L190 50 M190 49L188 57")
    static let string = path("M186 10.777778V21")
    static let pleats: CGPath = {
        let result = CGMutablePath()
        for i in 0..<32 {
            let end = 163 + Double(i) * 1.59
            let start = 182.3 + Double(i) * 0.24
            result.addPath(path("M\(start) 51.5 C\(start + (end - start) * 0.22) 61 \(end + (186 - end) * 0.16) 77 \(end) \(84 + sin(Double(i) * 0.55) * 2.6)"))
        }
        return result
    }()
    static let sun: CGPath = {
        let result = CGMutablePath()
        for radius in [8.0, 9.6, 11.2, 12.8, 14.4] {
            result.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        }
        return result
    }()
    static let cloud = path("M7 20C-2 20 -2 9 6 8C5 1 14 -2 19 3C24 -3 34 0 35 7C45 5 48 20 38 20Z")
    static let cloudHatch = path("M6 11H12 M16 11H36 M4 13H18 M21 13H40 M4 15H27 M30 15H41 M6 17H21 M24 17H40 M9 19H35")
    static let cloudTail = [
        CGPath(ellipseIn: CGRect(x: 46, y: 20, width: 2, height: 2), transform: nil),
        CGPath(ellipseIn: CGRect(x: 49.4, y: 23.4, width: 1.2, height: 1.2), transform: nil),
    ]
    static let tagThread = path("M0 0V17")
    static let tagOutline = path("M-3 38H-16Q-20 38 -20 34V26Q-20 22 -16 21L-6 17H6L16 21Q20 22 20 26V34Q20 38 16 38H3 M17 25l2 -1 M17 28l2 -1 M17 31l2 -1 M16 34l2 -1")
    static let tagHole = CGPath(ellipseIn: CGRect(x: -0.85, y: 19.65, width: 1.7, height: 1.7), transform: nil)
    static let wind = (0..<9).map { i in
        path("M\(105 + i % 3 * 25) \(48 + Double(i) * 3.6)c13 -2 21 2 35 0 m4 0h9")
    }
    static let rain = (0..<22).map { i in
        let length = Double(6 + i % 4 * 2)
        return path("M\(118 + Double(i) * 6.4) \(36 + (i * 13) % 34)l-\(length * 0.35) \(length * 0.94)")
    }
    static let rays: CGPath = {
        let result = CGMutablePath()
        for i in 0..<64 {
            result.addPath(path("M0 -17v-\(i % 4 == 0 ? 7 : 3)"), transform: CGAffineTransform(rotationAngle: CGFloat(i) * .pi / 32))
        }
        return result
    }()

    // A circumscribed ellipse covers the swept rectangle, including stroke, hover
    // lift and the pressed scale. It stays fixed while individual weather strokes move.
    static let weatherExclusion: CGRect = {
        let body = cloth[0]
        let paths = [head, body.idle, body.done, body.failed] + body.running
        var swept = CGRect.null
        for degrees in stride(from: -12.0, through: 6.0, by: 0.5) {
            let angle = CGFloat(degrees) * .pi / 180
            for path in paths {
                let rect = path.boundingBoxOfPath
                for x in [rect.minX, rect.maxX] {
                    for y in [rect.minY, rect.maxY] {
                        let px = (x - 186) * 0.84
                        let py = (y - 10.777778) * 0.84
                        let point = CGPoint(x: px * cos(angle) - py * sin(angle),
                                            y: px * sin(angle) + py * cos(angle))
                        swept = swept.union(CGRect(origin: point, size: .zero))
                    }
                }
            }
        }
        swept = swept.insetBy(dx: -4, dy: -4)
        let extra = (sqrt(CGFloat(2)) - 1) / 2
        return swept.insetBy(dx: -swept.width * extra, dy: -swept.height * extra)
    }()

    struct ClothPath {
        let name: String
        let idle: CGPath
        let running: [CGPath]
        let done: CGPath
        let failed: CGPath
    }

    // v5-hatch.html paths, mapped back before the view's 0.84 doll scale.
    static let cloth: [ClothPath] = [
        ClothPath(name: "body",
            idle: path("M182 47 C179 51 175.5 57.5 171.5 64 C166.5 71 161 78 158 81.5 C159.5 85.5 163.5 88 167.5 88 C170 88 171.5 85.5 173.5 85.5 C176 85.5 178 90.5 182.5 90.5 C186.5 90.5 188.5 87.5 190.5 87.5 C193.5 87.5 196 90 200 89.5 C204.5 89 204 84.5 207 84.5 C209.5 84.5 214.5 86.5 217.5 83 C218.5 82 219 80 218 79 C212 72.5 204 65.5 199 59.5 C194 54 192.5 49.5 190 47 C187.5 47.6 184.5 47.6 182 47 Z"),
            running: [
                path("M181.964 46.977 C179 51 176 57.5 172 64 C168 71.5 163 78.5 160.5 82.5 C162.5 86.5 166.5 89 170.5 89 C173 89 174.5 86.5 176.5 86.5 C179 86.5 182 91.5 186.5 91.5 C190.5 91 192 87 194.5 87 C198 86.5 201.5 88 206 87 C210.5 86 209 82 212 82 C215 81.5 221 82.5 223.5 79.5 C224 79 224 77 223 76 C214.5 71 205.5 65 199.5 59.5 C194.5 54 192.5 49.5 190.085 46.938 C187.597 47.6 184.46 47.6 181.918 47.078 Z"),
                path("M181.964 46.977 C179 51 176 57.5 172.5 64 C168.5 71 164 78 161.5 81 C163.5 85.5 167.5 88 172 88.5 C174.5 88.5 175.5 86 177.5 86.5 C180 86.5 183.5 92.5 188.5 92.5 C192.5 92.5 193.5 88.5 196 88.5 C200 88 203.5 90 208.5 88.5 C213 87 211 83 214 82.5 C217.5 81.5 224 82.5 226 79 C226.5 78 226 76 225 75.5 C216 71 206 65 199.5 59.5 C194.5 54 192.5 49.5 190.085 46.938 C187.597 47.6 184.46 47.6 181.918 47.078 Z"),
                path("M181.964 46.977 C179 51 176 57.5 172 64 C168 70.5 163 77 160.5 80.5 C162.5 84.5 166.5 86.5 170.5 86.5 C173 87 174.5 84.5 176.5 84.5 C179 85 182 90 186.5 91 C190.5 91 192 87.5 194.5 87.5 C198 87.5 201.5 90 206 89.5 C210.5 88.5 209 84.5 212 84 C215 83.5 221 85 223.5 81.5 C224 80.5 224 78.5 223 77.5 C214.5 72 205.5 65.5 199.5 59.5 C194.5 54 192.5 49.5 190.085 46.938 C187.597 47.6 184.46 47.6 181.918 47.078 Z"),
                path("M181.964 46.977 C179 51 176 57.5 171.5 64 C167 71 162 78 159 81.5 C161 85.5 165 87.5 169 87.5 C171.5 87 173 84.5 175 84.5 C177.5 84.5 180 89.5 184.5 89.5 C188.5 89.5 190 86 192.5 86 C195.5 86 198.5 88 203 88 C207.5 87.5 206.5 83.5 209.5 83.5 C212.5 83.5 217.5 85.5 220.5 82 C221.5 81.5 221.5 79.5 220.5 78.5 C213.5 72 205 65 199 59.5 C194.5 54 192.5 49.5 190.085 46.938 C187.597 47.6 184.46 47.6 181.918 47.078 Z"),
            ],
            done: path("M182 47 C179 51 175.5 57.5 171.5 64 C167 70.5 162 77 159.5 80.5 C161.5 84 165 86 169.5 86 C172 86 173 84 175 84 C177.5 84 180.5 89 185 89 C189 88.5 190 85 192.5 85 C195.5 84.5 198.5 86 202.5 85.5 C206.5 84.5 205.5 81 208.5 80.5 C211 80 216 81 219 78 C220 77.5 220 75.5 219 75 C212.5 70.5 204.5 64.5 199 59 C194.5 54 192.5 49.5 190 47 C187.5 47.6 184.5 47.6 182 47 Z"),
            failed: path("M182 47 C179 51 176.5 58 173.5 64.5 C171 72.5 168.5 80.5 167 84.5 C169 89 172 90.5 174.5 90.5 C176.5 90.5 177 89 178.5 89 C180 89.5 181.5 90.5 184.5 90.5 C187 90.5 188 90.5 189.5 90.5 C191 90.5 192.5 90.5 195 90.5 C198 90.5 198 88 200 88 C202 88 204.5 90.5 207.5 86 C208.5 85.5 209.5 82.5 209 81.5 C206.5 74 201.5 66 197.5 60 C194 54 192.5 49.5 190 47 C187.5 47.6 184.5 47.6 182 47 Z")),
        ClothPath(name: "fold1",
            idle: path("M183 49 C181.5 58 175 74.5 173.5 85.5"),
            running: [
                path("M183 49 C181.5 58 177 75 176.5 86.5"),
                path("M183 49 C181.5 58 177.5 75 178 86.5"),
                path("M183 49 C181.5 58 177 74.5 176.5 84.5"),
                path("M183 49 C181.5 58 176 74 175 84.5"),
            ],
            done: path("M183 49 C181.5 58 176 74 175.5 84"),
            failed: path("M183 49 C182 58 178 76.5 178.5 88.8")),
        ClothPath(name: "fold2",
            idle: path("M185.5 49 C186 61.5 189.5 78.5 190.5 87.5"),
            running: [
                path("M185.557 48.94 C186.5 61.5 192 78 194.5 87"),
                path("M185.557 48.94 C186.5 61.5 193 79 196 88.5"),
                path("M185.557 48.94 C186.5 61.5 192 78.5 194.5 87.5"),
                path("M185.557 48.94 C186 61.5 191 77.5 192.5 86"),
            ],
            done: path("M185.5 49 C186 61 191 77 192.5 85"),
            failed: path("M185.5 49 C186 62 189 81 189.5 90.5")),
        ClothPath(name: "fold3",
            idle: path("M188 49 C191 60 203 75.5 207 84.5"),
            running: [
                path("M188.118 48.945 C191.5 60 206 74 212 81.5"),
                path("M188.118 48.945 C192 60 207 74.5 214.5 82.3"),
                path("M188.118 48.945 C191.5 60 206 75 212 84"),
                path("M188.118 48.945 C191.5 60 204.5 74.5 209.5 83.5"),
            ],
            done: path("M188 49 C191.5 60 204 73.5 208.5 80.5"),
            failed: path("M188 49 C190.5 60.5 199 77.5 200.5 88")),
        ClothPath(name: "hatch1",
            idle: path("M188 76 L191 73 M190 75 L193 72.5 M192.5 74.5 L195 72 M194 74 L197 71"),
            running: [
                path("M190 76 L193 73 M192 75 L195 72 M194.5 74.5 L197 71.5 M196.5 73.5 L198.5 70.5"),
                path("M191 76.5 L194 73.5 M193 75.5 L196 72.5 M195.5 75 L197.5 72 M197 74 L199.5 71"),
                path("M190 76 L193 73 M192 75.5 L195 72.5 M194.5 75 L197 72 M196.5 74 L198.5 71"),
                path("M189 75 L192 72.5 M191 74.5 L194 72 M193.5 74 L196 71.5 M195.5 73.5 L198 71"),
            ],
            done: path("M189 75 L192 72 M191 74 L194 71.5 M193 73.5 L195.5 70.5 M195 72.5 L197.5 70"),
            failed: path("M188 78 L190 75 M189.5 77 L192 74 M191 76.5 L193.5 73.5 M192.5 75.5 L195 72.5")),
        ClothPath(name: "hatch2",
            idle: path("M201.5 79 L204 76.5 M203.5 78.5 L206 76 M205.5 77.5 L208 75 M207.5 77 L210 74.5"),
            running: [
                path("M205 77.5 L207 75 M207 76.5 L209 74 M209 76 L211 73.5 M211 75 L213 72.5"),
                path("M206 78 L208.5 75.5 M208.5 77 L210.5 74.5 M210 76.5 L212.5 74 M212.5 75.5 L214.5 72.5"),
                path("M205 79 L207 76 M207 78 L209 75.5 M209 77.5 L211 74.5 M211 76.5 L213 74"),
                path("M203 78 L205.5 75.5 M205 77.5 L207.5 75 M207 77 L209.5 74.5 M209 76 L211.5 74"),
            ],
            done: path("M202.5 76.5 L205 74 M204.5 75.5 L207 73.5 M206.5 75 L208.5 73 M208.5 74.5 L211 72"),
            failed: path("M197.5 81.5 L199.5 78.5 M199 80.5 L201 78 M200.5 80 L202.5 77 M202 79 L204.5 76")),
        ClothPath(name: "hatch3",
            idle: path("M207.5 83.5 L209 81.5 M209.5 82.5 L211 81 M211 82 L213 80.5"),
            running: [
                path("M212.5 80.5 L214 79 M214 80 L216 78.5 M216 79 L217.5 77.5"),
                path("M214.5 81.5 L216 79.5 M216.5 80 L218 78.5 M218.5 79 L219.5 77.5"),
                path("M212.5 83 L214 81 M214 82 L216 80 M216 81 L217.5 79.5"),
                path("M210 82.5 L211.5 81 M211.5 81.5 L213.5 80 M213.5 81 L215.5 79.5"),
            ],
            done: path("M209 79.5 L210.5 78 M210.5 78.5 L212.5 77 M212.5 78 L214 76.5"),
            failed: path("M201 87 L202 84.5 M202 85.5 L204 84 M203.5 85 L205 83")),
    ]
}
