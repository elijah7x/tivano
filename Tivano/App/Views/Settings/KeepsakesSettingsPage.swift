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
    static let thumbnail: CGFloat = 116
    static let viewer: CGFloat = 380
    static let flight = 0.62
    static let veilIn = 0.5
    static let veilOut = 0.45
    static let metadataDelay = 0.15
    static let metadataIn = 0.3
    static let metadataOut = 0.2
    static let closeLead = 0.1
    static let openEnd = flight + metadataDelay + metadataIn
    static let closeEnd = closeLead + max(flight, veilOut)

    static func color(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: alpha)
    }
}

private enum KeepsakeMotion {
    static let ease = Curve(0.25, 0.1, 0.25, 1)
    static let easeInOut = Curve(0.42, 0, 0.58, 1)
    static let easeOut = Curve(0, 0, 0.58, 1)

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
    @State private var expandedID: String?
    @State private var closing = false
    @State private var flightTime = 0.0
    @State private var hintTime = 0.0
    @State private var hintDismissed = false
    @State private var flipped = false
    @State private var detailFrame = CGRect.zero
    @State private var pageFrame = CGRect.zero
    @State private var thumbnailFrames: [String: CGRect] = [:]
    @State private var flightFrame = CGRect.zero
    @FocusState private var focus: Control?

    private enum Control: Hashable {
        case thumbnail(String)
        case badge
        case close
    }

    private typealias M = KeepsakeMetrics
    private typealias Motion = KeepsakeMotion

    private var expanded: Bool { expandedID != nil }
    private var expandedDefinition: KeepsakeDefinition? {
        expandedID.flatMap { KeepsakeCatalog.definition($0) }
    }
    private var isExpandedLit: Bool {
        expandedDefinition.flatMap { keepsake(for: $0.id) }?.litAt != nil
    }
    private var dark: Bool { colorScheme == .dark }
    private var text: Color { M.color(dark ? 0xf0f0ee : 0x252727) }
    private var busy: Bool {
        expanded && flightTime < (reduceMotion ? 0 : (closing ? M.closeEnd : M.openEnd))
    }
    private var hintEnd: Double { reduceMotion ? 3 : 3.8 }
    private var animating: Bool {
        expanded && (closing || busy || (isExpandedLit && !hintDismissed && hintTime < hintEnd))
    }

    var body: some View {
        TimelineView(.animation(paused: !visible || !windowVisible || !animating)) { timeline in
            VStack(alignment: .leading, spacing: Chrome.unitSpacing) {
                ForEach(KeepsakeCatalog.all, id: \.id) { definition in
                    card(for: definition, keepsake: keepsake(for: definition.id))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("keepsake-page")) } action: {
                pageFrame = $0
            }
            .opacity(1 - overlayProgress)
            .allowsHitTesting(!expanded)
            .accessibilityHidden(expanded)
            .background(KeepsakeDetailBounds(frame: $detailFrame, visible: $windowVisible))
            .overlay(alignment: .topLeading) {
                if let definition = expandedDefinition {
                    story(keepsake(for: definition.id), definition)
                        .frame(
                            width: detailFrame.width > 0 ? detailFrame.width : pageFrame.width,
                            height: detailFrame.height > 0 ? detailFrame.height : 481
                        )
                        .offset(x: detailFrame.minX, y: detailFrame.minY)
                }
            }
            .coordinateSpace(name: "keepsake-page")
            .onChange(of: timeline.date) { _, date in tick(date) }
        }
        .preference(key: KeepsakeOverlayPreference.self, value: expanded && !closing)
        .task {
            for definition in KeepsakeCatalog.all {
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
        }
        .onChange(of: dismissRequest) { _, _ in close() }
        .onAppear { visible = true; previousTick = nil; model.markKeepsakesSeen() }
        .onDisappear { visible = false; previousTick = nil }
        .onChange(of: windowVisible) { _, _ in previousTick = nil }
        .onChange(of: animating) { _, _ in previousTick = nil }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced && expanded {
                flightTime = closing ? M.closeEnd : M.openEnd
                if closing { finishClose() }
            }
        }
    }

    private func keepsake(for id: String) -> Keepsake? {
        model.keepsakes.first { $0.id == id }
    }

    private var overlayProgress: Double {
        guard expanded else { return 0 }
        guard !reduceMotion else { return closing ? 0 : 1 }
        return closing
            ? 1 - Motion.easeInOut.value((flightTime - M.closeLead) / M.veilOut)
            : Motion.easeOut.value(flightTime / M.veilIn)
    }

    private func card(for definition: KeepsakeDefinition, keepsake: Keepsake?) -> some View {
        let isLit = keepsake?.litAt != nil
        return ChromeCard {
            VStack(spacing: 12) {
                Button {
                    open(definition.id)
                } label: {
                    asset(isLit ? definition.frontAsset : definition.unlitAsset)
                        .frame(width: M.thumbnail, height: M.thumbnail)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .focused($focus, equals: .thumbnail(definition.id))
                .accessibilityLabel(Text(verbatim: thumbnailAccessibilityLabel(definition, keepsake: keepsake)))
                .accessibilityHint(Text(verbatim: Chrome.localized("Open one to read its story")))
                .opacity(expandedID == definition.id ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("keepsake-page")) } action: {
                    thumbnailFrames[definition.id] = $0
                }

                VStack(spacing: 4) {
                    Text(verbatim: Chrome.localized(definition.title))
                        .font(.ui(.body, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                    if let keepsake {
                        Text(verbatim: earnedText(keepsake))
                            .font(.ui(.caption))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                    Text(verbatim: Chrome.localized(captionKey(for: keepsake)))
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Chrome.contentHorizontalPadding)
            .padding(.vertical, 20)
        }
    }

    private func story(_ keepsake: Keepsake?, _ definition: KeepsakeDefinition) -> some View {
        let isLit = keepsake?.litAt != nil
        let duration = reduceMotion ? 0 : M.flight
        let travelTime = closing ? max(0, flightTime - M.closeLead) : flightTime
        let p = duration == 0 ? 1 : min(1, travelTime / duration)
        let travel = closing ? 1 - Motion.settle(p) : Motion.settle(p)
        let veil = overlayProgress
        let thumb = thumbnailFrames[definition.id] ?? .zero
        let source = CGPoint(x: thumb.midX, y: thumb.midY)
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
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .pointingHandCursor()

            VStack(spacing: 0) {
                Button {
                    guard !busy, isLit else { return }
                    withAnimation(reduceMotion ? nil : Motion.ease.animation(0.7)) { flipped.toggle() }
                    withAnimation(reduceMotion ? nil : Motion.ease.animation(0.8)) { hintDismissed = true }
                } label: {
                    ZStack {
                        if isLit {
                            KeepsakeFlipFace(
                                front: image(definition.frontAsset),
                                back: image(definition.backAsset),
                                angle: flipped ? 180 : 0
                            )
                        } else {
                            asset(definition.unlitAsset)
                        }
                    }
                    .frame(width: M.viewer, height: M.viewer)
                }
                .buttonStyle(.plain)
                .pointerStyle(isLit ? .link : nil)
                .focused($focus, equals: .badge)
                .accessibilityLabel(Text(verbatim: Chrome.localized(definition.title)))
                .accessibilityHint(Text(verbatim: isLit ? Chrome.localized("Tap to flip") : ""))
                .scaleEffect((M.thumbnail + (M.viewer - M.thumbnail) * travel) / M.viewer)
                .offset(x: (source.x - target.x) * (1 - travel), y: (source.y - target.y) * (1 - travel))
                // Measured outside the flight transforms, so the target is the card's resting layout frame.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("keepsake-page")) } action: { flightFrame = $0 }

                VStack(spacing: 0) {
                    Text(verbatim: Chrome.localized(definition.title))
                        .font(.ui(size: 15, weight: .medium))
                        .foregroundStyle(text)
                    if let keepsake {
                        Text(verbatim: earnedText(keepsake))
                            .font(.ui(size: 12))
                            .padding(.top, 8)
                    }
                    Text(verbatim: Chrome.localized(captionKey(for: keepsake)))
                        .font(.ui(size: 12))
                        .padding(.top, keepsake == nil ? 8 : 4)
                    Text(verbatim: Chrome.localized(definition.detail))
                        .font(.ui(size: 13))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                    if isLit {
                        Text("Tap to flip")
                            .font(.ui(size: 12))
                            .padding(.top, 20)
                            .opacity(hintDismissed ? 0 : hint * (closing
                                ? (reduceMotion ? 0 : 1 - Motion.ease.value(flightTime / 0.8)) : 1))
                    }
                }
                .foregroundStyle(text.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .opacity(metadata)
            }
            .frame(width: M.viewer)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: close) {
                Text(verbatim: "×")
                    .font(.system(size: 18))
                    .foregroundStyle(text.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(dark ? 7.0 / 255 : 64.0 / 255), in: Circle())
                    .overlay(Circle().strokeBorder(dark ? .white.opacity(18.0 / 255) : M.color(0x252727, 18.0 / 255), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .focused($focus, equals: .close)
            .accessibilityLabel(Text("Close"))
            .padding(18)
            .opacity(veil)
        }
        .accessibilityElement(children: .contain)
        .onExitCommand { close() }
        .onKeyPress(.tab) {
            focus = focus == .badge ? .close : .badge
            return .handled
        }
    }

    private func tick(_ date: Date) {
        guard visible, windowVisible, animating else { previousTick = nil; return }
        defer { previousTick = date }
        guard let previousTick else { return }
        let delta = max(0, date.timeIntervalSince(previousTick))
        if expanded {
            flightTime += delta
            if closing && !busy {
                finishClose()
            } else if !busy && isExpandedLit {
                hintTime = min(hintEnd, hintTime + delta)
            }
        }
    }

    private func open(_ id: String) {
        expandedID = id
        closing = false
        flightTime = 0
        hintTime = 0
        hintDismissed = false
        flipped = false
        focus = .badge
    }

    private func close() {
        guard expanded, !busy, !closing else { return }
        if reduceMotion {
            flipped = false
            finishClose()
            return
        }
        closing = true
        flightTime = 0
        withAnimation(Motion.ease.animation(0.7)) { flipped = false }
    }

    private func finishClose() {
        let closedID = expandedID
        expandedID = nil
        closing = false
        if let closedID {
            focus = .thumbnail(closedID)
        }
    }

    private func captionKey(for keepsake: Keepsake?) -> String {
        guard let keepsake else {
            return "Manuscript edition. Keepsakes are no longer given from 3.0."
        }
        return keepsake.litAt != nil
            ? "Lit before 3.0. Tap the card to flip it."
            : "Earned before 3.0. Keepsakes can no longer be lit from 3.0."
    }

    private func thumbnailAccessibilityLabel(_ definition: KeepsakeDefinition, keepsake: Keepsake?) -> String {
        let title = Chrome.localized(definition.title)
        guard let keepsake else { return title }
        return "\(title), \(earnedText(keepsake))"
    }

    private func earnedText(_ keepsake: Keepsake) -> String {
        String(format: Chrome.localized("Earned %@"), keepsake.earnedAt.formatted(date: .long, time: .omitted))
    }

    private func image(_ name: String) -> Image {
        if let decoded = decodedImages[name] { return Image(nsImage: decoded) }
        return Image(name)
    }

    private func asset(_ name: String) -> some View {
        image(name).resizable().interpolation(.high).scaledToFit()
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
            if let clipView = enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sample() }
                })
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
