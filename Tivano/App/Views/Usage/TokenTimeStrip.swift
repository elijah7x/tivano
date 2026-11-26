import SwiftUI

struct TokenTimeStrip: View {
    @MainActor
    struct Data {
        struct Segment {
            let tool: String
            let count: Double
        }

        struct MonthMark {
            let index: Int
            let label: String
        }

        let days: [TokenUsageDay]
        let maximum: Double
        let bars: [[Segment]]
        let months: [MonthMark]
        let colors: [String: Color]

        init(days: [TokenUsageDay], toolOrder: [String]) {
            self.days = days
            maximum = Double(days.map(\.total).max() ?? 0)
            let extraTools = Set(days.flatMap { $0.byTool.keys }).subtracting(toolOrder).sorted()
            let order = toolOrder + extraTools
            bars = days.map { day in
                order.compactMap { tool in
                    guard let count = day.byTool[tool], count > 0 else { return nil }
                    return Segment(tool: tool, count: Double(count))
                }
            }
            var marks: [MonthMark] = []
            var previousMonth = ""
            for (index, day) in days.enumerated() {
                let month = String(day.day.prefix(7))
                if month != previousMonth {
                    marks.append(MonthMark(index: index, label: TokenUsageFormatting.month(day.day)))
                    previousMonth = month
                }
            }
            months = marks
            colors = Dictionary(order.map { ($0, TokenWatershedPalette.color(forTool: $0)) },
                                uniquingKeysWith: { first, _ in first })
        }
    }

    let data: Data
    @Binding var brush: ClosedRange<Int>

    @State private var drag: BrushDrag?
    private let chartHeight: CGFloat = 64

    private var days: [TokenUsageDay] { data.days }

    var body: some View {
        let captionFont: Font = Font.ui(.caption2)
        let totalHeight: CGFloat = chartHeight + Chrome.pageTitleSpacing
        GeometryReader { (geometry: GeometryProxy) in
            Canvas { (context: inout GraphicsContext, size: CGSize) in
                drawCanvas(in: &context, size: size, captionFont: captionFont)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { (value: DragGesture.Value) in updateDrag(value, width: geometry.size.width) }
                .onEnded { _ in drag = nil })
        }
        .frame(height: totalHeight)
        .background { NoWindowDragArea() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Date range"))
        .accessibilityValue(Text(verbatim: accessibleValue))
        .accessibilityHint(Text("Adjust to move the selected range by one day."))
        .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Extend start by one day")) { resizeStart(by: -1) }
        .accessibilityAction(named: Text("Shorten start by one day")) { resizeStart(by: 1) }
        .accessibilityAction(named: Text("Extend end by one day")) { resizeEnd(by: 1) }
        .accessibilityAction(named: Text("Shorten end by one day")) { resizeEnd(by: -1) }
        .focusable()
        .onMoveCommand { (direction: MoveCommandDirection) in
            if direction == .left { move(by: -1) }
            if direction == .right { move(by: 1) }
        }
    }

    private func drawCanvas(in context: inout GraphicsContext, size: CGSize, captionFont: Font) {
        guard !days.isEmpty, size.width > 0 else { return }
        let step: CGFloat = size.width / CGFloat(days.count)
        let range: ClosedRange<Int> = clampedBrush
        let baseline: CGFloat = chartHeight - Chrome.unitHeaderSpacing
        let maxBarHeight: CGFloat = baseline - Chrome.unitHeaderSpacing
        let barWidth: CGFloat = max(step * 0.65, 0.5)
        for (index, segments) in data.bars.enumerated() {
            var y: CGFloat = baseline
            let barX: CGFloat = CGFloat(index) * step
            let opacity: Double = range.contains(index) ? 0.55 : 0.15
            for segment in segments {
                let height: CGFloat = data.maximum > 0 ? CGFloat(segment.count / data.maximum) * maxBarHeight : 0
                y -= height
                let rect = CGRect(x: barX, y: y, width: barWidth, height: height)
                let color: Color = data.colors[segment.tool] ?? Chrome.accent
                context.fill(Path(rect), with: .color(color.opacity(opacity)))
            }
        }

        var ruler = Path()
        ruler.move(to: CGPoint(x: 0, y: chartHeight))
        ruler.addLine(to: CGPoint(x: size.width, y: chartHeight))
        context.stroke(ruler, with: .color(Chrome.overlay(0.12)), lineWidth: 0.5)

        var lastLabelEnd: CGFloat = -.infinity
        let tickBottom: CGFloat = chartHeight + 3
        let labelY: CGFloat = chartHeight + Chrome.unitHeaderSpacing
        for mark in data.months {
            let x: CGFloat = CGFloat(mark.index) * step
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: chartHeight))
            tick.addLine(to: CGPoint(x: x, y: tickBottom))
            context.stroke(tick, with: .color(Chrome.overlay(0.2)), lineWidth: 0.5)
            let labelText: Text = Text(verbatim: mark.label).font(captionFont).foregroundColor(Chrome.secondaryText)
            let label: GraphicsContext.ResolvedText = context.resolve(labelText)
            let width: CGFloat = label.measure(in: size).width
            let maxLeft: CGFloat = max(0, size.width - width)
            let left: CGFloat = min(max(0, x), maxLeft)
            guard left >= lastLabelEnd + Chrome.unitHeaderSpacing else { continue }
            context.draw(label, at: CGPoint(x: left, y: labelY), anchor: .topLeading)
            lastLabelEnd = left + width
        }

        let left: CGFloat = CGFloat(range.lowerBound) * step
        let right: CGFloat = CGFloat(range.upperBound + 1) * step
        let rect = CGRect(x: left, y: 0, width: right - left, height: chartHeight)
        context.fill(Path(rect), with: .color(Chrome.accent.opacity(0.06)))
        context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Chrome.secondaryText), lineWidth: 1)
        let handleHeight: CGFloat = chartHeight - Chrome.unitHeaderSpacing * 2
        let maxHandleX: CGFloat = max(0, size.width - 4)
        let edges: [CGFloat] = [left, right]
        for edge in edges {
            let handleX: CGFloat = min(max(0, edge - 2), maxHandleX)
            let handle = CGRect(x: handleX, y: Chrome.unitHeaderSpacing, width: 4, height: handleHeight)
            context.fill(Path(roundedRect: handle, cornerRadius: 2), with: .color(Chrome.secondaryText))
        }
    }

    private var clampedBrush: ClosedRange<Int> {
        let last = max(0, days.count - 1)
        let lower = min(max(0, brush.lowerBound), last)
        return lower...min(max(lower, brush.upperBound), last)
    }

    private var accessibleValue: String {
        guard !days.isEmpty else { return Chrome.localized("No token usage in this range") }
        let range = clampedBrush
        let total = days[range].reduce(Int64(0)) { $0 + $1.total }
        return String(format: Chrome.localized("%@ · %@ tokens"),
                      TokenUsageFormatting.span(from: days[range.lowerBound].day, to: days[range.upperBound].day),
                      TokenUsageFormatting.exact(total))
    }

    private func updateDrag(_ value: DragGesture.Value, width: CGFloat) {
        guard !days.isEmpty, width > 0 else { return }
        let step = width / CGFloat(days.count)
        if drag == nil {
            let range = clampedBrush
            let left = CGFloat(range.lowerBound) * step
            let right = CGFloat(range.upperBound + 1) * step
            let x = value.startLocation.x
            let hitWidth = min(Chrome.rowHorizontalPadding, (right - left) / 3)
            let part: BrushDrag.Part
            if abs(x - left) <= hitWidth { part = .start }
            else if abs(x - right) <= hitWidth { part = .end }
            else if x >= left, x <= right { part = .body }
            else {
                let index = min(max(0, Int(x / step)), days.count - 1)
                let lower = min(max(0, index - range.count / 2), days.count - range.count)
                brush = lower...(lower + range.count - 1)
                part = .body
            }
            drag = BrushDrag(range: clampedBrush, part: part)
        }
        guard let drag else { return }
        let delta = Int((value.translation.width / step).rounded())
        switch drag.part {
        case .start:
            brush = min(max(0, drag.range.lowerBound + delta), drag.range.upperBound)...drag.range.upperBound
        case .end:
            brush = drag.range.lowerBound...max(drag.range.lowerBound, min(days.count - 1, drag.range.upperBound + delta))
        case .body:
            let lower = min(max(0, drag.range.lowerBound + delta), days.count - drag.range.count)
            brush = lower...(lower + drag.range.count - 1)
        }
    }

    private func move(by delta: Int) {
        guard !days.isEmpty else { return }
        let range = clampedBrush
        let lower = min(max(0, range.lowerBound + delta), days.count - range.count)
        brush = lower...(lower + range.count - 1)
    }

    private func resizeStart(by delta: Int) {
        guard !days.isEmpty else { return }
        let range = clampedBrush
        brush = min(max(0, range.lowerBound + delta), range.upperBound)...range.upperBound
    }

    private func resizeEnd(by delta: Int) {
        guard !days.isEmpty else { return }
        let range = clampedBrush
        brush = range.lowerBound...max(range.lowerBound, min(days.count - 1, range.upperBound + delta))
    }

    private struct BrushDrag {
        enum Part { case start, end, body }
        let range: ClosedRange<Int>
        let part: Part
    }
}

@MainActor
enum TokenUsageFormatting {
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let spanFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.locale = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateTemplate = "MMMdyyyy"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    private static let compactOneDecimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let compactTwoDecimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let costFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let exactCostFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    static func span(from: String, to: String) -> String {
        guard let first = parser.date(from: from), let last = parser.date(from: to) else { return "\(from) – \(to)" }
        return spanFormatter.string(from: first, to: last)
    }

    static func month(_ day: String) -> String {
        guard let date = parser.date(from: day) else { return day }
        return monthFormatter.string(from: date)
    }

    static func exact(_ value: Int64) -> String {
        value.formatted(.number)
    }

    static func compact(_ value: Int64) -> String {
        let scale: Double
        let template: String
        if value >= 1_000_000_000 { scale = 1_000_000_000; template = "%@B" }
        else if value >= 1_000_000 { scale = 1_000_000; template = "%@M" }
        else if value >= 1_000 { scale = 1_000; template = "%@K" }
        else { return exact(value) }
        let number = scale == 1_000_000_000 ? compactTwoDecimalFormatter : compactOneDecimalFormatter
        let text = number.string(from: NSNumber(value: Double(value) / scale)) ?? exact(value)
        return String(format: Chrome.localized(template), text)
    }

    static func cost(_ value: Decimal, exact: Bool = false) -> String {
        let formatter = exact ? exactCostFormatter : costFormatter
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }
}
