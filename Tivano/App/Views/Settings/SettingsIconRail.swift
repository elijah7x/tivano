import AppKit
import SwiftUI

/// One selectable entry in a `SettingsIconRail`, rendered as an icon button in the
/// collapsed rail and a full `SidebarRow` in the hover-expanded overlay card.
struct SettingsIconRailRow: Identifiable {
    struct StatusDot {
        let color: Color
        let accessibilityLabel: String
    }

    let id: String
    let title: String
    let titleIsVerbatim: Bool
    let railHelp: String?
    let statusDot: StatusDot?
    let accessoryWidth: CGFloat
    let isSelected: Bool
    let action: @MainActor () -> Void
    let icon: AnyView
    let accessory: AnyView

    @MainActor
    init<Icon: View, Accessory: View>(
        id: String,
        title: String,
        titleIsVerbatim: Bool = true,
        railHelp: String? = nil,
        statusDot: StatusDot? = nil,
        accessoryWidth: CGFloat = 0,
        isSelected: Bool,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.id = id
        self.title = title
        self.titleIsVerbatim = titleIsVerbatim
        self.railHelp = railHelp
        self.statusDot = statusDot
        self.accessoryWidth = accessoryWidth
        self.isSelected = isSelected
        self.action = action
        self.icon = AnyView(icon())
        self.accessory = AnyView(accessory())
    }

    @MainActor
    init<Icon: View>(
        id: String,
        title: String,
        titleIsVerbatim: Bool = true,
        railHelp: String? = nil,
        statusDot: StatusDot? = nil,
        isSelected: Bool,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.init(
            id: id,
            title: title,
            titleIsVerbatim: titleIsVerbatim,
            railHelp: railHelp,
            statusDot: statusDot,
            accessoryWidth: 0,
            isSelected: isSelected,
            action: action,
            icon: icon,
            accessory: { EmptyView() }
        )
    }
}

/// A group of rows in `SettingsIconRail`. Non-initial sections draw a divider in the
/// collapsed rail, and either a section title or a divider in the expanded card.
struct SettingsIconRailSection: Identifiable {
    let id: String
    var title: String? = nil
    let rows: [SettingsIconRailRow]
}

/// Compact icon rail for two-column Settings pages that floats out an expanded sidebar
/// card on hover. Lists up to `maxUnscrolledItems` entries at full content height without
/// a scroll view; larger lists bound the card to the rail's height and isolate scrolling.
struct SettingsIconRail: View {
    static let railButtonSize: CGFloat = Chrome.rowHeight
    static let railWidth: CGFloat = Chrome.listInset * 2 + railButtonSize
    static let railStatusDotSize: CGFloat = 5
    static let expandedWidth: CGFloat = 200
    static let maxUnscrolledItems = 10
    private static let collapseDelay: Duration = .milliseconds(120)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    let sections: [SettingsIconRailSection]
    var emptyTitle: String? = nil

    @State private var isHoveringRail = false
    @State private var isHoveringOverlay = false
    @State private var isExpanded = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var railHeight: CGFloat = 0
    @State private var scrollIsolator = SettingsIconRailScrollIsolator()

    init(sections: [SettingsIconRailSection], emptyTitle: String? = nil) {
        self.sections = sections
        self.emptyTitle = emptyTitle
    }

    init(rows: [SettingsIconRailRow], emptyTitle: String? = nil) {
        self.sections = [SettingsIconRailSection(id: "rows", rows: rows)]
        self.emptyTitle = emptyTitle
    }

    private var isHovering: Bool { isHoveringRail || isHoveringOverlay }

    private var visibleSections: [SettingsIconRailSection] {
        sections.filter { !$0.rows.isEmpty }
    }

    private var rowIDs: [String] {
        visibleSections.flatMap { $0.rows.map(\.id) }
    }

    private var itemCount: Int {
        let total = visibleSections.reduce(0) { $0 + $1.rows.count }
        if visibleSections.count > 1, visibleSections[0].rows.count == 1, visibleSections[0].title == nil {
            return total - 1
        }
        return total
    }

    private var scrolls: Bool {
        itemCount > Self.maxUnscrolledItems
    }

    var body: some View {
        railCard
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { railHeight = $0 }
            .background {
                SettingsIconRailProbe { view in
                    scrollIsolator.railView = view
                }
            }
            .onHover { hovering in
                isHoveringRail = hovering
                handleHoverChange()
            }
            .overlay(alignment: .topLeading) {
                if isExpanded {
                    expandedCard
                        .geometryGroup()
                        .onHover { hovering in
                            isHoveringOverlay = hovering
                            handleHoverChange()
                        }
                        .transition(overlayTransition)
                }
            }
            .animation(nil, value: rowIDs)
            .onChange(of: isHovering) { _, hovering in
                scrollIsolator.setMonitoring(hovering)
            }
            .onDisappear {
                scrollIsolator.setMonitoring(false)
                collapseTask?.cancel()
                collapseTask = nil
                isHoveringRail = false
                isHoveringOverlay = false
                isExpanded = false
            }
    }

    private var railCard: some View {
        ChromeCard {
            VStack(spacing: 0) {
                ForEach(Array(visibleSections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .accessibilityHidden(true)
                    }
                    ForEach(section.rows) { row in
                        SettingsIconRailButton(row: row)
                    }
                }
            }
            .padding(Chrome.listInset)
            .opacity(isExpanded ? 0 : 1)
            .accessibilityHidden(isExpanded)
        }
    }

    @ViewBuilder
    private var expandedCard: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
        if scrolls {
            ChromeCard {
                ScrollView(.vertical) {
                    expandedContent
                        .background {
                            SettingsIconRailProbe { view in
                                scrollIsolator.scrollProbeView = view
                            }
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(width: Self.expandedWidth, height: railHeight > 0 ? railHeight : nil)
            .background {
                SettingsIconRailProbe { view in
                    scrollIsolator.overlayView = view
                }
            }
            .floatingGlass(shape)
            .shadow(
                color: .black.opacity(performanceMode ? 0 : 0.28),
                radius: performanceMode ? 0 : 10,
                y: performanceMode ? 0 : 4
            )
        } else {
            ChromeCard {
                expandedContent
            }
            .frame(width: Self.expandedWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                SettingsIconRailProbe { view in
                    scrollIsolator.overlayView = view
                }
            }
            .floatingGlass(shape)
            .shadow(
                color: .black.opacity(performanceMode ? 0 : 0.28),
                radius: performanceMode ? 0 : 10,
                y: performanceMode ? 0 : 4
            )
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleSections.enumerated()), id: \.element.id) { index, section in
                if let title = section.title {
                    Text(verbatim: title)
                        .font(.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, Chrome.rowHorizontalPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                } else if index > 0 {
                    Divider()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
                ForEach(section.rows) { row in
                    SidebarRow(
                        title: row.title,
                        titleIsVerbatim: row.titleIsVerbatim,
                        isSelected: row.isSelected,
                        accessoryWidth: row.accessoryWidth,
                        action: { row.action() }
                    ) {
                        row.icon
                    } accessory: { _ in
                        row.accessory
                    }
                }
            }
            if let emptyTitle {
                Text(verbatim: emptyTitle)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, Chrome.rowHorizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
        }
        .padding(Chrome.listInset)
    }

    private var overlayTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .opacity
            .combined(with: .scale(scale: 0.97, anchor: .topLeading))
            .combined(with: .offset(x: -4))
    }

    private func handleHoverChange() {
        if isHovering {
            collapseTask?.cancel()
            collapseTask = nil
            if !isExpanded {
                withAnimation(Chrome.hover) { isExpanded = true }
            }
        } else if isExpanded {
            collapseTask?.cancel()
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: Self.collapseDelay)
                guard !Task.isCancelled, !isHovering else { return }
                withAnimation(Chrome.hover) { isExpanded = false }
            }
        }
    }
}

private struct SettingsIconRailButton: View {
    let row: SettingsIconRailRow

    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        let helpTitle = row.railHelp ?? (row.titleIsVerbatim ? row.title : Chrome.localized(row.title))
        Button(action: { row.action() }) {
            row.icon
                .frame(width: Chrome.iconSize, height: Chrome.iconSize)
                .frame(width: SettingsIconRail.railButtonSize, height: SettingsIconRail.railButtonSize)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: helpTitle))
        .accessibilityLabel(Text(verbatim: helpTitle))
        .accessibilityAddTraits(row.isSelected ? [.isSelected, .isButton] : .isButton)
        .background {
            shape
                .fill(fill)
                .animation(Chrome.hover, value: row.isSelected)
                .animation(Chrome.hover, value: isHovering)
        }
        .overlay(alignment: .bottomTrailing) {
            if let dot = row.statusDot {
                Circle()
                    .fill(dot.color)
                    .frame(width: SettingsIconRail.railStatusDotSize, height: SettingsIconRail.railStatusDotSize)
                    .padding((SettingsIconRail.railButtonSize - Chrome.iconSize) / 2)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text(verbatim: dot.accessibilityLabel))
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
    }

    private var fill: Color {
        if row.isSelected { return Chrome.overlay(0.12) }
        if isHovering { return Chrome.overlay(0.06) }
        return .clear
    }
}

private struct SettingsIconRailProbe: NSViewRepresentable {
    let onResolve: @MainActor (NSView?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onResolve = onResolve
        nsView.report()
    }

    final class ProbeView: NSView {
        var onResolve: @MainActor (NSView?) -> Void

        init(onResolve: @escaping @MainActor (NSView?) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            onResolve(window == nil ? nil : self)
        }
    }
}

@MainActor
private final class SettingsIconRailScrollIsolator {
    weak var railView: NSView?
    weak var overlayView: NSView?
    weak var scrollProbeView: NSView?
    private nonisolated(unsafe) var monitor: Any?
    private var hasActiveGesture = false

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func setMonitoring(_ active: Bool) {
        if active {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                // Local monitors run on the main thread; the event never leaves it.
                nonisolated(unsafe) let wheel = event
                let consumed = MainActor.assumeIsolated { self.handleScrollWheel(wheel) == nil }
                return consumed ? nil : event
            }
        } else {
            hasActiveGesture = false
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        let overlayScroll = activeScrollView(in: event.window)
        let activeWindow = railView?.window ?? overlayView?.window ?? overlayScroll?.window
        guard let activeWindow, event.window === activeWindow else { return event }
        guard isPointInSelector(event.locationInWindow, window: activeWindow, overlayScroll: overlayScroll) else {
            return event
        }
        guard let overlayScroll else {
            hasActiveGesture = false
            return nil
        }
        if shouldForwardWheel(event, to: overlayScroll) {
            overlayScroll.scrollWheel(with: event)
        }
        return nil
    }

    private func activeScrollView(in window: NSWindow?) -> NSScrollView? {
        guard let scroll = scrollProbeView?.enclosingScrollView,
              !scroll.isHiddenOrHasHiddenAncestor,
              scroll.bounds.width <= SettingsIconRail.expandedWidth + 4,
              let scrollWindow = scroll.window,
              window == nil || scrollWindow === window else { return nil }
        return scroll
    }

    private func isPointInSelector(_ point: NSPoint, window: NSWindow, overlayScroll: NSScrollView?) -> Bool {
        containsWindowPoint(point, in: railView, window: window)
            || containsWindowPoint(point, in: overlayView, window: window)
            || containsWindowPoint(point, in: overlayScroll, window: window)
    }

    private func containsWindowPoint(_ point: NSPoint, in view: NSView?, window: NSWindow) -> Bool {
        guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor, !view.bounds.isEmpty else {
            return false
        }
        return view.bounds.contains(view.convert(point, from: nil))
    }

    /// Prevent `NSScrollView.scrollWheel(with:)` from forwarding excess scroll up the responder
    /// chain into the Settings page's outer scroll view when at an edge or unscrollable.
    private func shouldForwardWheel(_ event: NSEvent, to scrollView: NSScrollView) -> Bool {
        guard let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView.bounds
        let doc = document.bounds
        guard doc.height > clip.height + 0.5 else {
            hasActiveGesture = false
            return false
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let wasActive = hasActiveGesture
            hasActiveGesture = false
            return wasActive
        }
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return false }
        let flipped = document.isFlipped
        let atTop = flipped ? (clip.minY <= doc.minY + 0.5) : (clip.maxY >= doc.maxY - 0.5)
        let atBottom = flipped ? (clip.maxY >= doc.maxY - 0.5) : (clip.minY <= doc.minY + 0.5)
        if (deltaY > 0 && atTop) || (deltaY < 0 && atBottom) {
            return false
        }
        if !event.phase.isEmpty {
            hasActiveGesture = true
        }
        return true
    }
}
