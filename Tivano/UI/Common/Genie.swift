import AppKit
import SwiftUI

/// Archived rows fly into the window's bottom-left corner with a genie effect.
///
/// The row is rendered once into a flat image, and that image is what flies: a small GPU
/// distortion over one layer for about half a second, with nothing left running afterwards.
@MainActor
@Observable
final class GenieAnimator {
    static let shared = GenieAnimator()
    nonisolated static let coordinateSpace = "tivano-window"
    nonisolated static let duration: Double = 0.58

    struct Flight: Identifiable {
        let id = UUID()
        let image: NSImage
        let frame: CGRect
        /// Where the flight lands, in the layer's coordinates; nil flies to the archive corner.
        var target: CGPoint?
        /// Played backwards: the ghost comes out of the target and settles into `frame`.
        var isArrival = false
    }

    private(set) var flights: [Flight] = []

    /// Flies a ghost of a row from `frame`. The ghost draws exactly what `ghost`
    /// returns, so pass the row as it looks — background included — and the row
    /// hands over to it without a visible change. Arriving, the ghost flies the other
    /// way: out of `target` and into `frame`. Returns false when nothing flies (reduced
    /// motion, or nothing to draw), so the caller can show the real thing instead.
    @discardableResult
    func launch<Ghost: View>(frame: CGRect, colorScheme: ColorScheme, target: CGPoint? = nil, arriving: Bool = false, @ViewBuilder ghost: () -> Ghost) -> Bool {
        guard frame.width > 1, frame.height > 1,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        let renderer = ImageRenderer(content: GenieGhost(size: frame.size, content: ghost())
            .environment(\.colorScheme, colorScheme))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return false }
        flights.append(Flight(image: image, frame: frame, target: target, isArrival: arriving))
        return true
    }

    func finish(_ id: UUID) {
        flights.removeAll { $0.id == id }
    }
}

/// The flat stand-in a row becomes for its flight. It adds no fill of its own:
/// the ghost already carries the row's background, so a transparent row stays
/// transparent instead of flashing opaque when archiving starts.
private struct GenieGhost<Content: View>: View {
    let size: CGSize
    let content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The window-wide layer the flights draw in. It never takes clicks.
struct GenieLayer: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(GenieAnimator.shared.flights) { flight in
                    GenieFlightView(flight: flight, canvas: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GenieFlightView: View {
    let flight: GenieAnimator.Flight
    let canvas: CGSize

    @State private var hasStarted = false

    var body: some View {
        let target = flight.target ?? CGPoint(x: 24, y: canvas.height - 12)
        let frame = flight.frame
        // An arrival is the same flight run backwards: all the way in at the start, and
        // out of the funnel into place by the end.
        let (start, end) = flight.isArrival ? (1.0, 0.0) : (0.0, 1.0)
        // How far a destination pixel can reach for its source: the shader maps the
        // funnel's pixels back into the row's frame, so the row's size plus its distance
        // to the neck bounds it. The offscreen pass the effect rasterizes is padded by
        // this on every side; the whole canvas padded it by the whole window.
        let reach = CGSize(
            width: abs(target.x - frame.midX) + frame.width,
            height: abs(target.y - frame.midY) + frame.height
        )
        Image(nsImage: flight.image)
            .resizable()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .keyframeAnimator(initialValue: start, trigger: hasStarted) { content, progress in
                content
                    .distortionEffect(
                        ShaderLibrary.genie(
                            .float(progress),
                            .float4(frame.minX, frame.minY, frame.width, frame.height),
                            .float2(target.x, target.y)
                        ),
                        maxSampleOffset: reach
                    )
                    .opacity(progress > 0.9 ? max(0, (1 - progress) / 0.1) : 1)
            } keyframes: { _ in
                CubicKeyframe(end, duration: GenieAnimator.duration)
            }
            .onAppear { hasStarted = true }
            .task {
                // Removed just before the keyframes finish, so the flight never springs back.
                try? await Task.sleep(for: .seconds(GenieAnimator.duration - 0.03))
                GenieAnimator.shared.finish(flight.id)
            }
    }
}
