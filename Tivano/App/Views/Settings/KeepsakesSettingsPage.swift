import SwiftUI
import AppKit

struct KeepsakeOverlayPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue() || value
    }
}

private struct KeepsakeDismissRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var keepsakeDismissRequest: Int {
        get { self[KeepsakeDismissRequestKey.self] }
        set { self[KeepsakeDismissRequestKey.self] = newValue }
    }
}

enum KeepsakeOverlayStyle {
    static func veil(dark: Bool) -> Color {
        KeepsakeMetrics.color(dark ? 0x202923 : 0xeef2ed, 96.0 / 255)
    }

    static func tint(dark: Bool) -> Color {
        KeepsakeMetrics.color(dark ? 0x080e0b : 0x18251c, dark ? 101.0 / 255 : 0.145)
    }
}

private enum KeepsakeMetrics {
    static let cardHeight: CGFloat = 420
    static let radius: CGFloat = 16
    static let hanging = CGSize(width: 116, height: 143)
    static let cord = CGSize(width: 1, height: 33)
    static let thumbnail: CGFloat = 116
    static let top: CGFloat = 27
    // The hanging stack is only as tall as the thumbnail and is centered in the taller
    // hanging frame, so the thumbnail sits below the top offset by half the difference.
    static let lever = (hanging.height - thumbnail) / 2 + top + thumbnail / 2
    static let viewer: CGFloat = 380
    static let flight = 0.62
    static let veilIn = 0.5
    static let veilOut = 0.45
    static let metadataDelay = 0.15
    static let metadataIn = 0.3
    static let metadataOut = 0.2
    static let closeLead = 0.1
    static let openEnd = flight + metadataDelay + metadataIn
    static let revealStart = 1.0
    static let restlessness = 7.0
    static let swellCycle = 3.2
    static let closeEnd = closeLead + max(flight, veilOut)
    static let hang = UnitPoint(x: 0.44, y: 133.0 / 420)
    static let branch = UnitPoint(x: 0, y: 133.0 / 420)
    static func color(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: alpha)
    }
    static func gradient(dark: Bool) -> [Gradient.Stop] {
        dark ? [.init(color: color(0xc6d4bd, 5.0 / 255), location: 0),
                .init(color: color(0x758e75, 6.0 / 255), location: 0.6),
                .init(color: color(0xa1b899, 11.0 / 255), location: 1)]
        : [.init(color: color(0xfffef9, 64.0 / 255), location: 0),
           .init(color: color(0xe5eee5, 26.0 / 255), location: 0.6),
           .init(color: color(0xd7e3d3, 41.0 / 255), location: 1)]
    }
}

private enum KeepsakeMotion {
    static let ease = Curve(0.25, 0.1, 0.25, 1)
    static let easeInOut = Curve(0.42, 0, 0.58, 1)
    static let easeOut = Curve(0, 0, 0.58, 1)
    static let easeIn = Curve(0.42, 0, 1, 1)
    // A critically damped spring, scaled to land exactly on 1. Its speed rises and falls
    // smoothly and is nearly zero on arrival, so the flight never brakes in its last frames.
    static func settle(_ progress: Double) -> Double {
        let stiffness = 7.0
        func spring(_ t: Double) -> Double { 1 - (1 + stiffness * t) * exp(-stiffness * t) }
        return spring(min(1, max(0, progress))) / spring(1)
    }
    struct Curve {
        let x1: Double, y1: Double, x2: Double, y2: Double
        init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        }
        func value(_ progress: Double) -> Double {
            let x = min(1, max(0, progress))
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let t = (low + high) / 2
                if cubic(t, x1, x2) < x { low = t } else { high = t }
            }
            return cubic((low + high) / 2, y1, y2)
        }
        private func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        func animation(_ duration: Double) -> Animation {
            .timingCurve(x1, y1, x2, y2, duration: duration)
        }
    }
}

struct KeepsakesSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.keepsakeDismissRequest) private var dismissRequest
    @State private var decodedImages: [String: NSImage] = [:]
    @State private var visible = false
    @State private var windowVisible = true
    @State private var previousTick: Date?
    @State private var ambientTime = 0.0
    // The branch sways only inside this window of ambient time, then rests so the page stops redrawing.
    @State private var motionStart = 0.0
    @State private var motionUntil = KeepsakeMetrics.restlessness
    @State private var lightingTime: Double?
    @State private var lightingID: String?
    @State private var releaseOnClose = false
    @State private var releaseTime: Double?
    @State private var noteTime: Double?
    @State private var expanded = false
    @State private var closing = false
    @State private var flightTime = 0.0
    @State private var hintTime = 0.0
    @State private var hintDismissed = false
    @State private var flipped = false
    @State private var dropHover = false
    @State private var detailFrame = CGRect.zero
    @State private var cardFrame = CGRect.zero
    @State private var flightFrame = CGRect.zero
    @FocusState private var focus: Control?
    private enum Control: Hashable { case thumbnail, badge, light, close }
    private typealias M = KeepsakeMetrics
    private typealias Motion = KeepsakeMotion

    private var keepsake: Keepsake? { model.keepsakes.first }
    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { M.color(dark ? 0xa2bbaa : 0x647e6e) }
    private var text: Color { M.color(dark ? 0xf0f0ee : 0x252727) }
    private var busy: Bool { lightingTime != nil || (expanded && flightTime < (reduceMotion ? 0 : (closing ? M.closeEnd : M.openEnd))) }
    private var restless: Bool { !reduceMotion && !model.settings.performanceMode && ambientTime < motionUntil }
    private var idleMotion: Bool { !expanded && restless }
    // The branch keeps swaying while the card flies, so the hand-off continues its motion.
    private var swaying: Bool { restless && (!expanded || closing || flightTime < M.openEnd) }
    private var motionEnvelope: Double {
        Motion.easeInOut.value(min((ambientTime - motionStart) / 1.0, (motionUntil - ambientTime) / 1.5))
    }
    private var hintEnd: Double { reduceMotion ? 3 : 3.8 }
    // The unlit view's drop swells on flightTime for a few cycles, then rests.
    private var pillBobbing: Bool {
        expanded && !closing && keepsake?.litAt == nil && lightingTime == nil
            && !reduceMotion && !model.settings.performanceMode && flightTime < M.swellCycle * 3
    }
    private var animating: Bool {
        idleMotion || lightingTime != nil || releaseTime != nil || noteTime != nil || pillBobbing
            || (expanded && (closing || busy || (!hintDismissed && hintTime < hintEnd)))
    }
    private var sway: Double {
        guard !reduceMotion, !model.settings.performanceMode else { return 0 }
        let phase = ambientTime.truncatingRemainder(dividingBy: 6)
        return (-3 + 6 * Motion.easeInOut.value(phase <= 3 ? phase / 3 : (6 - phase) / 3)) * motionEnvelope
    }

    var body: some View {
        TimelineView(.animation(paused: !visible || !windowVisible || !animating)) { timeline in
            VStack(alignment: .leading, spacing: 0) {
                Text("Keep the keepsakes from along the way.")
                    .font(.system(size: 12)).frame(height: 18)
                Text(verbatim: Chrome.localized(keepsake?.litAt == nil
                    ? "Open it to light it" : "Open one to read its story"))
                    .font(.system(size: 11)).frame(height: 16)
                    .opacity(0.75 * noteOpacity).padding(.top, 7)
                scene
                    .frame(height: M.cardHeight)
                    .background {
                        GeometryReader { geometry in
                            let angle = 145.0 * Double.pi / 180
                            let length = abs(geometry.size.width * sin(angle)) + abs(geometry.size.height * cos(angle))
                            LinearGradient(stops: M.gradient(dark: dark),
                                           startPoint: UnitPoint(x: 0.5 - sin(angle) * length / geometry.size.width / 2,
                                                                 y: 0.5 + cos(angle) * length / geometry.size.height / 2),
                                           endPoint: UnitPoint(x: 0.5 + sin(angle) * length / geometry.size.width / 2,
                                                               y: 0.5 - cos(angle) * length / geometry.size.height / 2))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: M.radius))
                    .overlay(RoundedRectangle(cornerRadius: M.radius)
                        .strokeBorder(.white.opacity(dark ? 18.0 / 255 : 144.0 / 255), lineWidth: 1))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("keepsake-page")) } action: { cardFrame = $0 }
                    .padding(.top, 20)
            }
            .foregroundStyle(text.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(1 - overlayProgress)
            .allowsHitTesting(!expanded)
            .accessibilityHidden(expanded)
            .background(KeepsakeDetailBounds(frame: $detailFrame, visible: $windowVisible))
            .overlay(alignment: .topLeading) {
                if expanded, let keepsake, let definition = KeepsakeCatalog.definition(keepsake.id) {
                    story(keepsake, definition)
                        .frame(width: detailFrame.width > 0 ? detailFrame.width : cardFrame.width,
                               height: detailFrame.height > 0 ? detailFrame.height : 481)
                        .offset(x: detailFrame.minX, y: detailFrame.minY)
                }
            }
            .coordinateSpace(name: "keepsake-page")
            .onChange(of: timeline.date) { _, date in tick(date) }
        }
        .preference(key: KeepsakeOverlayPreference.self, value: expanded && !closing)
        .task(id: keepsake?.id) {
            guard let keepsake, let definition = KeepsakeCatalog.definition(keepsake.id) else { return }
            for name in [definition.frontAsset, definition.backAsset, definition.unlitAsset] {
                await Task.yield()
                guard !Task.isCancelled else { return }
                // Decoding warms the named image's own cache; keeping the named image (not a
                // flattened copy) preserves its light and dark variants.
                guard decodedImages[name] == nil, let image = NSImage(named: name),
                      image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else { continue }
                decodedImages[name] = image
            }
        }
        .onChange(of: dismissRequest) { _, _ in close() }
        .onAppear { visible = true; previousTick = nil; stir(); model.markKeepsakesSeen() }
        .onDisappear { visible = false; previousTick = nil }
        .onChange(of: windowVisible) { _, _ in previousTick = nil }
        .onChange(of: animating) { _, _ in previousTick = nil }
        .onChange(of: keepsake?.id) { _, _ in
            expanded = false; lightingTime = nil; lightingID = nil; releaseTime = nil; noteTime = nil
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced && expanded { flightTime = closing ? M.closeEnd : M.openEnd }
        }
    }

    private var overlayProgress: Double {
        guard expanded else { return 0 }
        guard !reduceMotion else { return closing ? 0 : 1 }
        return closing
            ? 1 - Motion.easeInOut.value((flightTime - M.closeLead) / M.veilOut)
            : Motion.easeOut.value(flightTime / M.veilIn)
    }

    private var noteOpacity: Double {
        guard let noteTime else { return 1 }
        return min(1, noteTime / (reduceMotion ? 0.2 : 0.26))
    }

    private var scene: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Image("keepsake-backdrop").resizable().frame(width: size.width, height: size.height)
                ZStack(alignment: .topLeading) {
                    Image("keepsake-branch").resizable().frame(width: size.width, height: size.height)
                    if let releaseTime, !reduceMotion {
                        releasedLeaf(index: 0, time: releaseTime, size: size)
                        releasedLeaf(index: 1, time: releaseTime, size: size)
                    }
                }
                .rotationEffect(.degrees(sway * 0.35 / 3), anchor: M.branch)
                looseLeaf(index: 0, size: size)
                looseLeaf(index: 1, size: size)
                if let keepsake, let definition = KeepsakeCatalog.definition(keepsake.id) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(ink.opacity(0.48))
                            .frame(width: M.cord.width, height: M.cord.height).offset(x: 58)
                        Button { open()
                        } label: {
                            thumbnail(definition, lit: keepsake.litAt != nil)
                                .frame(width: M.thumbnail, height: M.thumbnail)
                        }
                        .buttonStyle(.plain).pointerStyle(.link).focused($focus, equals: .thumbnail)
                        .onHover { if $0 && !expanded { stir() } }
                        .accessibilityLabel(Text(verbatim: "\(Chrome.localized(definition.title)), \(earnedText(keepsake))"))
                        .accessibilityHint(Text(verbatim: Chrome.localized(keepsake.litAt == nil ? "Open it to light it" : "Open one to read its story")))
                        .opacity(expanded ? 0 : 1).offset(y: M.top)
                    }
                    .frame(width: M.hanging.width, height: M.hanging.height)
                    .rotationEffect(.degrees(sway), anchor: .top)
                    .offset(x: size.width * M.hang.x - 58, y: size.height * M.hang.y)
                }
            }
        }
    }

    private func thumbnail(_ definition: KeepsakeDefinition, lit: Bool) -> some View {
        asset(lit ? definition.frontAsset : definition.unlitAsset)
    }

    private func lightingFace(_ definition: KeepsakeDefinition) -> some View {
        let time = lightingTime ?? 0
        let progress = min(1, max(0, (time - (reduceMotion ? 0 : M.revealStart)) / (reduceMotion ? 1 : 1.9)))
        return ZStack {
            asset(definition.unlitAsset).opacity(1 - progress)
            asset(definition.frontAsset)
                .opacity(reduceMotion ? progress : 1)
                .mask {
                    if reduceMotion { Rectangle() }
                    else { revealMask(time: time - M.revealStart) }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: M.viewer * 0.07))
    }

    private func revealMask(time: Double) -> some View {
        let blobs: [(Double, Double, Double, Double, Double)] = [
            (0.5, 0.14, 0.62, 0, 1.4),
            (0.5, 0.323, 0.92, 0.06, 1.7),
            (0.40, 0.43, 0.82, 0.08, 1.6),
            (0.60, 0.46, 0.88, 0.14, 1.6),
            (0.47, 0.62, 0.88, 0.20, 1.5),
            (0.30, 0.81, 0.84, 0.27, 1.4),
            (0.67, 0.77, 0.86, 0.35, 1.4),
            (0.62, 0.20, 0.86, 0.30, 1.6),
        ]
        return ZStack {
            ForEach(blobs.indices, id: \.self) { index in
                let blob = blobs[index]
                let radius = M.viewer * blob.2 * Motion.easeOut.value((time - blob.3) / blob.4)
                RadialGradient(stops: [.init(color: .white, location: 0),
                                       .init(color: .white, location: 0.58),
                                       .init(color: .clear, location: 1)],
                               center: UnitPoint(x: blob.0, y: blob.1),
                               startRadius: 0, endRadius: max(0.001, radius))
                    .opacity(time > blob.3 ? 1 : 0)
            }
        }
    }

    // A drop of light hangs above the ribbon. Lighting it gathers the drop, lets it fall
    // along the ribbon onto the ring, and the reveal spreads from where it lands.
    private func lightButton(_ keepsake: Keepsake) -> some View {
        let time = lightingTime ?? 0
        let lighting = lightingTime != nil
        let phase = flightTime.truncatingRemainder(dividingBy: M.swellCycle) / M.swellCycle
        let swell = reduceMotion || lighting ? 0 : Motion.easeInOut.value(phase <= 0.5 ? phase * 2 : (1 - phase) * 2)
        let gather = Motion.easeInOut.value(time / 0.35)
        let fall = Motion.easeIn.value((time - 0.35) / (M.revealStart - 0.35))
        let splash = Motion.easeOut.value((time - M.revealStart + 0.05) / 0.7)
        // The ring sits 108 pt below the top of the 768 pt asset.
        let dropY: CGFloat = -14, ringY = M.viewer * 108 / 768
        let fill = lighting ? 0.3 + 0.4 * gather : (dropHover ? 0.5 : 0.16)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(ink.opacity(0.45)).frame(width: 1, height: 28)
                .position(x: M.viewer / 2, y: dropY - 24).opacity(1 - gather)
            Circle().fill(RadialGradient(colors: [ink.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: 18))
                .frame(width: 36, height: 36).position(x: M.viewer / 2, y: dropY - 2)
                .opacity(dropHover && !lighting ? 1 : 0)
            KeepsakeDropShape(tip: 1).fill(ink.opacity(fill))
                .overlay(KeepsakeDropShape(tip: 1).stroke(ink, lineWidth: 1))
                .frame(width: 12, height: 12)
                .scaleEffect(x: 1 + 0.06 * swell + 0.1 * gather - 0.15 * fall,
                             y: 1 + 0.1 * swell + 0.18 * gather + 0.1 * fall, anchor: .top)
                .position(x: M.viewer / 2, y: dropY + CGFloat(fall) * (ringY - dropY))
                .opacity(reduceMotion && lighting ? 0 : 1 - Motion.easeIn.value((fall - 0.8) / 0.2))
            Circle().strokeBorder(ink, lineWidth: 1).frame(width: 6, height: 6)
                .scaleEffect(1 + 8 * splash)
                .opacity(reduceMotion || splash <= 0 ? 0 : 0.9 * (1 - splash))
                .position(x: M.viewer / 2, y: ringY)
            Button {
                guard !busy, keepsake.litAt == nil else { return }
                lightingID = keepsake.id; lightingTime = 0; hintTime = 0
            } label: {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 16, height: 22)
                    Rectangle().fill(ink.opacity(0.45)).frame(width: 14, height: 1)
                    Text("Light it").font(.system(size: 11)).tracking(2).foregroundStyle(text.opacity(0.62))
                }
                .padding(8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerStyle(.link)
            .focused($focus, equals: .light).accessibilityLabel(Text("Light it"))
            .disabled(busy)
            .onHover { dropHover = $0 }
            .offset(x: M.viewer / 2 - 16, y: dropY - 19)
            .opacity(1 - gather)
        }
        .frame(width: M.viewer, height: M.viewer, alignment: .topLeading)
        .animation(reduceMotion ? nil : Motion.ease.animation(0.25), value: dropHover)
        .accessibilityHidden(lighting)
    }

    private func looseLeaf(index: Int, size: CGSize) -> some View {
        let duration = index == 0 ? 18.0 : 20.0
        let phase = (ambientTime + (index == 0 ? 3 : 12)).truncatingRemainder(dividingBy: duration) / duration
        let p = Motion.easeInOut.value(phase)
        return KeepsakeLeafShape(index: index)
            .fill(ink.opacity(0.14))
            .overlay(KeepsakeLeafShape(index: index).stroke(ink, lineWidth: 0.75))
            .opacity(0.35)
            .frame(width: 638, height: 420)
            .rotationEffect(.degrees(reduceMotion ? 0 : -12 + 46 * p),
                            anchor: UnitPoint(x: (index == 0 ? 412 : 544.5) / 638,
                                              y: (index == 0 ? 183 : 256) / 420))
            .offset(x: reduceMotion ? 0 : -9 + 28 * p,
                    y: reduceMotion ? 0 : -22 + 88 * p)
            .scaleEffect(x: size.width / 638, y: size.height / 420, anchor: .topLeading)
            .accessibilityHidden(true)
    }

    private func releasedLeaf(index: Int, time: Double, size: CGSize) -> some View {
        let t = time - Double(index) * 0.12
        let p = Motion.easeOut.value(t / 2.8)
        let alpha = t < 0 || t >= 2.8 ? 0 : (t / 2.8 < 0.7
            ? 0.5 - 0.2 * Motion.easeOut.value(t / 2.8 / 0.7)
            : 0.3 * (1 - Motion.easeOut.value((t / 2.8 - 0.7) / 0.3)))
        return KeepsakeLeafShape(index: index + 2)
            .fill(ink.opacity(0.14))
            .overlay(KeepsakeLeafShape(index: index + 2).stroke(ink, lineWidth: 0.75))
            .frame(width: 638, height: 420)
            .rotationEffect(.degrees(65 * p), anchor: UnitPoint(x: (index == 0 ? 233 : 391) / 638.0,
                                                                             y: (index == 0 ? 95 : 157) / 420.0))
            .offset(x: 65 * p, y: 110 * p)
            .scaleEffect(x: size.width / 638, y: size.height / 420, anchor: .topLeading)
            .opacity(alpha).accessibilityHidden(true)
    }

    private func story(_ keepsake: Keepsake, _ definition: KeepsakeDefinition) -> some View {
        let duration = reduceMotion ? 0 : M.flight
        let travelTime = closing ? max(0, flightTime - M.closeLead) : flightTime
        let p = duration == 0 ? 1 : min(1, travelTime / duration)
        let travel = closing ? 1 - Motion.settle(p) : Motion.settle(p)
        let veil = overlayProgress
        let angle = sway * Double.pi / 180
        // The thumbnail's center hangs `M.lever` below the cord's anchor and swings with it.
        let source = CGPoint(x: cardFrame.minX + cardFrame.width * M.hang.x - sin(angle) * M.lever,
                             y: cardFrame.minY + cardFrame.height * M.hang.y + cos(angle) * M.lever)
        let target = CGPoint(x: flightFrame.midX, y: flightFrame.midY)
        let metadata = reduceMotion ? (closing ? 0.0 : 1.0) : (closing
            ? 1 - Motion.ease.value(flightTime / M.metadataOut)
            : Motion.ease.value((flightTime - M.flight - M.metadataDelay) / M.metadataIn))
        let hint = reduceMotion ? (hintTime < 3 ? 1.0 : 0.0)
            : (hintTime <= 3 ? Motion.ease.value(hintTime / 0.8) : 1 - Motion.ease.value((hintTime - 3) / 0.8))
        return ZStack(alignment: .topTrailing) {
            ZStack {
                KeepsakeBackdrop()
                KeepsakeOverlayStyle.veil(dark: dark)
            }
            .opacity(veil)
            .contentShape(Rectangle()).onTapGesture { close() }
            .pointingHandCursor()
            VStack(spacing: 0) {
                Button {
                    guard !busy, keepsake.litAt != nil else { return }
                    withAnimation(reduceMotion ? nil : Motion.ease.animation(0.7)) { flipped.toggle() }
                    withAnimation(reduceMotion ? nil : Motion.ease.animation(0.8)) { hintDismissed = true }
                } label: {
                    ZStack {
                        if keepsake.litAt == nil {
                            if lightingTime != nil { lightingFace(definition) }
                            else { asset(definition.unlitAsset) }
                        } else {
                            KeepsakeFlipFace(front: image(definition.frontAsset), back: image(definition.backAsset), angle: flipped ? 180 : 0)
                        }
                    }
                    .frame(width: M.viewer, height: M.viewer)
                }
                .buttonStyle(.plain).pointingHandCursor().focused($focus, equals: .badge)
                .accessibilityLabel(Text(verbatim: Chrome.localized(definition.title)))
                .accessibilityHint(Text(verbatim: keepsake.litAt == nil ? "" : Chrome.localized("Tap to flip")))
                .overlay {
                    if keepsake.litAt == nil {
                        lightButton(keepsake).opacity(metadata)
                    }
                }
                .scaleEffect((M.thumbnail + (M.viewer - M.thumbnail) * travel) / M.viewer)
                .rotationEffect(.degrees(sway * (1 - travel)))
                .offset(x: (source.x - target.x) * (1 - travel), y: (source.y - target.y) * (1 - travel))
                // Measured outside the flight transforms, so the target is the card's resting layout frame.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("keepsake-page")) } action: { flightFrame = $0 }
                VStack(spacing: 0) {
                    Text(verbatim: Chrome.localized(definition.title)).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(text)
                    Text(verbatim: earnedText(keepsake)).font(.system(size: 12)).padding(.top, 8)
                    Text(verbatim: Chrome.localized(definition.detail))
                        .font(.system(size: 13)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                    Text("Tap to flip").font(.system(size: 12)).padding(.top, 20)
                        .opacity(keepsake.litAt == nil || lightingTime != nil || hintDismissed ? 0 : hint * (closing
                            ? (reduceMotion ? 0 : 1 - Motion.ease.value(flightTime / 0.8)) : 1))
                }
                .foregroundStyle(text.opacity(0.7)).multilineTextAlignment(.center)
                .padding(.top, 10).opacity(metadata)
            }
            .frame(width: M.viewer).frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: close) {
                Text(verbatim: "×").font(.system(size: 18)).foregroundStyle(text.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(dark ? 7.0 / 255 : 64.0 / 255), in: Circle())
                    .overlay(Circle().strokeBorder(dark ? .white.opacity(18.0 / 255) : M.color(0x252727, 18.0 / 255), lineWidth: 1))
            }
            .buttonStyle(.plain).pointingHandCursor().focused($focus, equals: .close).accessibilityLabel(Text("Close"))
            .padding(18).opacity(veil)
        }
        .accessibilityElement(children: .contain)
        .onExitCommand { close() }
        .onKeyPress(.tab) {
            let primary: Control = keepsake.litAt == nil ? .light : .badge
            focus = focus == primary ? .close : primary
            return .handled
        }
    }

    private func tick(_ date: Date) {
        guard visible, windowVisible, animating else { previousTick = nil; return }
        defer { previousTick = date }
        guard let previousTick else { return }
        let delta = max(0, date.timeIntervalSince(previousTick))
        if swaying { ambientTime += delta }
        if let time = lightingTime {
            let next = time + delta
            let revealEnd = reduceMotion ? 1.0 : M.revealStart + 1.9
            if next >= revealEnd, let id = lightingID {
                model.lightKeepsake(id)
                lightingID = nil; noteTime = 0; releaseOnClose = true
            }
            if !reduceMotion {
                if time < M.revealStart + 2.4 && next >= M.revealStart + 2.4 {
                    withAnimation(Motion.ease.animation(0.7)) { flipped = true }
                }
                if time < M.revealStart + 4.3 && next >= M.revealStart + 4.3 {
                    withAnimation(Motion.ease.animation(0.7)) { flipped = false }
                }
            }
            if next >= (reduceMotion ? 1 : M.revealStart + 5) {
                lightingTime = nil; hintTime = 0; focus = .badge
            } else { lightingTime = next }
        }
        if let time = releaseTime {
            let next = min(2.92, time + delta)
            releaseTime = next >= 2.92 ? nil : next
        }
        if let time = noteTime {
            let end = reduceMotion ? 0.2 : 0.26
            let next = min(end, time + delta)
            noteTime = next >= end ? nil : next
        }
        if expanded {
            flightTime += delta
            if closing && !busy { expanded = false; closing = false; focus = .thumbnail }
            else if !busy && keepsake?.litAt != nil { hintTime = min(hintEnd, hintTime + delta) }
        }
    }

    private func open() {
        #if DEBUG
        // Preview runs: Option-click unlights the keepsake so the light-up can be replayed.
        if KeepsakePreview.isRequested && NSEvent.modifierFlags.contains(.option) {
            model.prepareKeepsakePreview(); releaseOnClose = false; releaseTime = nil; noteTime = nil
        }
        #endif
        expanded = true; closing = false; flightTime = 0; hintTime = 0
        hintDismissed = false; flipped = false; focus = keepsake?.litAt == nil ? .light : .badge
    }
    // Starts another sway window, continuing from the current amplitude rather than jumping.
    private func stir() {
        let current = min(1, max(0, min(ambientTime - motionStart, (motionUntil - ambientTime) / 1.5)))
        motionStart = ambientTime - current
        motionUntil = ambientTime + M.restlessness - 1
    }
    private func close() {
        guard expanded, !busy, !closing else { return }
        closing = true; flightTime = 0
        if releaseOnClose {
            if !reduceMotion { releaseTime = 0 }
            releaseOnClose = false
        }
        withAnimation(reduceMotion ? nil : Motion.ease.animation(0.7)) { flipped = false }
    }
    private func earnedText(_ keepsake: Keepsake) -> String {
        String(format: Chrome.localized("Earned %@"), keepsake.earnedAt.formatted(date: .long, time: .omitted))
    }
    private func image(_ name: String) -> Image {
        if let decoded = decodedImages[name] { return Image(nsImage: decoded) }
        return Image(name)
    }
    private func asset(_ name: String) -> some View { image(name).resizable().interpolation(.high).scaledToFit() }
}

private struct KeepsakeDropShape: Shape {
    var tip: Double
    var animatableData: Double { get { tip } set { tip = newValue } }
    func path(in rect: CGRect) -> Path {
        if tip == 0 { return Capsule().path(in: rect) }
        let x = rect.midX, y = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        var path = Path()
        path.move(to: CGPoint(x: x, y: y - ry * (1 + tip * 0.65)))
        path.addCurve(to: CGPoint(x: x, y: y + ry),
                      control1: CGPoint(x: x + rx * (1.33 - tip * 0.35), y: y - ry * (1 - tip)),
                      control2: CGPoint(x: x + rx * 1.33, y: y + ry))
        path.addCurve(to: CGPoint(x: x, y: y - ry * (1 + tip * 0.65)),
                      control1: CGPoint(x: x - rx * 1.33, y: y + ry),
                      control2: CGPoint(x: x - rx * (1.33 - tip * 0.35), y: y - ry * (1 - tip)))
        path.closeSubpath()
        return path
    }
}

private struct KeepsakeFlipFace: View, Animatable {
    let front: Image
    let back: Image
    var angle: Double
    var animatableData: Double { get { angle } set { angle = newValue } }
    var body: some View {
        ZStack {
            front.resizable().scaledToFit().opacity(angle < 90 ? 1 : 0)
            back.resizable().scaledToFit()
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0), perspective: 0)
                .opacity(angle >= 90 ? 1 : 0)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: KeepsakeMetrics.viewer / 1100)
    }
}

// Exact SVG paths preserve the two different loose leaves and the detached attached leaves.
private struct KeepsakeLeafShape: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func move(_ x: CGFloat, _ y: CGFloat) { p.move(to: CGPoint(x: x, y: y)) }
        func quad(_ x: CGFloat, _ y: CGFloat, _ cx: CGFloat, _ cy: CGFloat) {
            p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
        }
        switch index {
        case 0:
            move(401, 188); quad(423, 179, 408, 172); quad(401, 188, 418, 193)
            move(402, 187); p.addLine(to: CGPoint(x: 419, y: 180))
        case 1:
            move(533, 256); quad(556, 257, 548, 244); quad(533, 256, 544, 265)
            move(535, 256); p.addLine(to: CGPoint(x: 552, y: 256))
        case 2:
            move(231, 104); quad(237, 85, 223, 90); quad(231, 104, 243, 98)
        default:
            move(380, 155); quad(402, 160, 394, 147); quad(380, 155, 389, 166)
        }
        return p
    }
}

struct KeepsakeBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// The page is inside SettingsView's padded ScrollView. Measure its viewport rather than the card.
private struct KeepsakeDetailBounds: NSViewRepresentable {
    @Binding var frame: CGRect
    @Binding var visible: Bool
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.report = { bounds, shown in
            if frame != bounds { frame = bounds }
            if visible != shown { visible = shown }
        }
        view.sample()
    }
    final class Probe: NSView {
        var report: ((CGRect, Bool) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.didChangeOcclusionStateNotification, NSWindow.didResizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.sample() }
                    })
                }
            }
            sample()
        }
        override func layout() { super.layout(); sample() }
        func sample() {
            guard let scroll = enclosingScrollView, let window else { return }
            let rect = convert(scroll.contentView.bounds, from: scroll.contentView)
            let bounds = CGRect(x: rect.minX, y: isFlipped ? rect.minY : self.bounds.height - rect.maxY,
                                width: rect.width, height: rect.height)
            let shown = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            DispatchQueue.main.async { [weak self] in self?.report?(bounds, shown) }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
