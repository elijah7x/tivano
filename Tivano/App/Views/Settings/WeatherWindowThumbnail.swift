import SwiftUI

/// Miniature window preview inside `ChromeVisualPicker` for each `WeatherWindowMode`.
struct WeatherWindowThumbnail: View {
    let mode: WeatherWindowMode

    private enum Metrics {
        static let size = CGSize(width: 60, height: 38)
        static let windowRect = CGRect(x: 0.5, y: 0.5, width: 59, height: 37)
        static let windowCorner: CGFloat = 5
        static let sidebarX: CGFloat = 22.5
        static let baseOpacity: Double = 0.45

        static let dotCenters: [CGPoint] = [
            CGPoint(x: 4.5, y: 4.0),
            CGPoint(x: 7.5, y: 4.0),
            CGPoint(x: 10.5, y: 4.0),
        ]
        static let dotRadius: CGFloat = 0.8

        static let sidebarRows: [(y: CGFloat, endX: CGFloat)] = [
            (19.5, 16.5),
            (23.5, 13.5),
            (27.5, 18.5),
            (31.5, 14.5),
        ]

        static let contentLines: [(y: CGFloat, endX: CGFloat)] = [
            (13.5, 50.5),
            (18.5, 46.5),
            (23.5, 41.5),
        ]

        static let portholeRect = CGRect(x: 2.5, y: 6.5, width: 18, height: 9)
        static let portholeCorner: CGFloat = 2.5

        static let rainStrokes: [(start: CGPoint, end: CGPoint)] = [
            (CGPoint(x: 8.0, y: 7.5), CGPoint(x: 6.2, y: 12.3)),
            (CGPoint(x: 17.5, y: 11.5), CGPoint(x: 15.7, y: 16.3)),
            (CGPoint(x: 11.5, y: 22.0), CGPoint(x: 9.7, y: 26.8)),
            (CGPoint(x: 29.5, y: 6.5), CGPoint(x: 27.7, y: 11.3)),
            (CGPoint(x: 39.5, y: 10.5), CGPoint(x: 37.7, y: 15.3)),
            (CGPoint(x: 32.5, y: 25.5), CGPoint(x: 30.7, y: 30.3)),
            (CGPoint(x: 49.5, y: 21.5), CGPoint(x: 47.7, y: 26.3)),
        ]

        static let sunCenter = CGPoint(x: 53.5, y: 6.5)
        static let sunRadius: CGFloat = 2.5
        static let sunRays: [(start: CGPoint, end: CGPoint)] = [
            (CGPoint(x: 49.5, y: 6.5), CGPoint(x: 47.8, y: 6.5)),
            (CGPoint(x: 50.7, y: 9.3), CGPoint(x: 49.5, y: 10.5)),
            (CGPoint(x: 53.5, y: 10.5), CGPoint(x: 53.5, y: 12.2)),
        ]
    }

    var body: some View {
        Canvas { context, _ in
            if mode == .full {
                drawFullWeather(in: &context)
            }
            drawBaseWindow(in: &context)
            if mode == .porthole {
                drawPorthole(in: &context)
            }
        }
        .frame(width: Metrics.size.width, height: Metrics.size.height)
        .accessibilityHidden(true)
    }

    private func drawBaseWindow(in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.opacity = Metrics.baseOpacity

            let outline = Path(
                roundedRect: Metrics.windowRect,
                cornerRadius: Metrics.windowCorner,
                style: .continuous
            )
            layer.stroke(outline, with: .foreground, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

            var divider = Path()
            divider.move(to: CGPoint(x: Metrics.sidebarX, y: Metrics.windowRect.minY + 0.5))
            divider.addLine(to: CGPoint(x: Metrics.sidebarX, y: Metrics.windowRect.maxY - 0.5))
            layer.stroke(divider, with: .foreground, style: StrokeStyle(lineWidth: 0.75, lineCap: .round))

            for center in Metrics.dotCenters {
                let dotRect = CGRect(
                    x: center.x - Metrics.dotRadius,
                    y: center.y - Metrics.dotRadius,
                    width: Metrics.dotRadius * 2,
                    height: Metrics.dotRadius * 2
                )
                layer.fill(Path(ellipseIn: dotRect), with: .foreground)
            }

            var sidebarLines = Path()
            for row in Metrics.sidebarRows {
                sidebarLines.move(to: CGPoint(x: 3.5, y: row.y))
                sidebarLines.addLine(to: CGPoint(x: row.endX, y: row.y))
            }
            layer.stroke(sidebarLines, with: .foreground, style: StrokeStyle(lineWidth: 1, lineCap: .round))

            var contentLines = Path()
            for line in Metrics.contentLines {
                contentLines.move(to: CGPoint(x: 27.5, y: line.y))
                contentLines.addLine(to: CGPoint(x: line.endX, y: line.y))
            }
            layer.stroke(contentLines, with: .foreground, style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    private func drawPorthole(in context: inout GraphicsContext) {
        let strip = Path(
            roundedRect: Metrics.portholeRect,
            cornerRadius: Metrics.portholeCorner,
            style: .continuous
        )
        context.stroke(strip, with: .foreground, style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))

        var horizon = Path()
        horizon.move(to: CGPoint(x: 3.5, y: 13.5))
        horizon.addLine(to: CGPoint(x: 19.5, y: 13.5))
        context.stroke(horizon, with: .foreground, style: StrokeStyle(lineWidth: 0.75, lineCap: .round))

        var cloud = Path()
        cloud.move(to: CGPoint(x: 4.8, y: 10.8))
        cloud.addQuadCurve(to: CGPoint(x: 8.0, y: 9.5), control: CGPoint(x: 5.4, y: 8.7))
        cloud.addQuadCurve(to: CGPoint(x: 11.2, y: 10.8), control: CGPoint(x: 10.3, y: 8.4))
        context.stroke(cloud, with: .foreground, style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))

        let headRect = CGRect(x: 14.5, y: 7.7, width: 2.6, height: 2.6)
        context.fill(Path(ellipseIn: headRect), with: .foreground)

        var skirt = Path()
        skirt.move(to: CGPoint(x: 15.8, y: 10.1))
        skirt.addLine(to: CGPoint(x: 17.5, y: 12.9))
        skirt.addLine(to: CGPoint(x: 14.1, y: 12.9))
        skirt.closeSubpath()
        context.fill(skirt, with: .foreground)
    }

    private func drawFullWeather(in context: inout GraphicsContext) {
        let clipShape = Path(
            roundedRect: Metrics.windowRect,
            cornerRadius: Metrics.windowCorner,
            style: .continuous
        )
        context.drawLayer { layer in
            layer.clip(to: clipShape)

            var sun = Path()
            sun.addArc(
                center: Metrics.sunCenter,
                radius: Metrics.sunRadius,
                startAngle: .degrees(10),
                endAngle: .degrees(230),
                clockwise: false
            )
            layer.stroke(sun, with: .foreground, style: StrokeStyle(lineWidth: 0.85, lineCap: .round))

            var rays = Path()
            for ray in Metrics.sunRays {
                rays.move(to: ray.start)
                rays.addLine(to: ray.end)
            }
            layer.stroke(rays, with: .foreground, style: StrokeStyle(lineWidth: 0.75, lineCap: .round))

            var rain = Path()
            for drop in Metrics.rainStrokes {
                rain.move(to: drop.start)
                rain.addLine(to: drop.end)
            }
            layer.stroke(rain, with: .foreground, style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
        }
    }
}
