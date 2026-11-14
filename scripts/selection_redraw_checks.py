#!/usr/bin/env python3
"""Exercise LinkTextView selection redraws using hidden AppKit views, without launching Tivano."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(path: str, marker: str) -> str:
    source = (ROOT / path).read_text()
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


swift = r'''
import AppKit

@MainActor
class Base: NSTextView {
    static var rects: [NSRect] = []

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        Self.rects.append(rect)
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }
}

@MainActor
final class Probe: Base {
'''
for marker in (
    "    override func setNeedsDisplay(_ rect",
    "    override func setSelectedRanges(",
    "    override func resignFirstResponder()",
):
    swift += "\n" + declaration("Tivano/UI/Markdown/LinkParagraphView.swift", marker) + "\n"
swift += r'''
}

@main @MainActor enum Checks {
    static var count = 0

    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        count += 1
        print("PASS \(label)")
    }

    static func isAligned(_ value: CGFloat, scale: CGFloat) -> Bool {
        abs((value * scale).rounded() - value * scale) < 1e-4
    }

    // needsDisplay reads false in a window that is never presented, so assert on
    // the redraw requests the view actually made.
    static func coversBounds(_ view: NSView) -> Bool {
        Base.rects.contains { $0.isInfinite || $0.contains(view.bounds) }
    }

    static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        contentView.wantsLayer = true
        window.contentView = contentView

        let probe = Probe(frame: NSRect(x: 0, y: 0.25, width: 300, height: 120))
        probe.isEditable = false
        probe.isSelectable = true
        probe.drawsBackground = false
        probe.wantsLayer = true
        check(probe.layoutManager != nil, "TextKit 1 layoutManager active")
        contentView.addSubview(probe)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4.5
        let text = "第一行 Chinese and English mixed prose.\n第二行 Second line with 4.5pt spacing."
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
        probe.textStorage?.setAttributedString(attributed)
        if let container = probe.textContainer {
            probe.layoutManager?.ensureLayout(for: container)
        }
        probe.layoutSubtreeIfNeeded()

        let scale = window.backingScaleFactor
        check(scale >= 1.0, "window backingScaleFactor available")

        let inputRect = NSRect(x: 10, y: 20.25, width: 100, height: 22.5)
        Base.rects.removeAll()
        probe.setNeedsDisplay(inputRect, avoidAdditionalLayout: true)
        check(Base.rects.count == 1, "setNeedsDisplay forwards single rect")
        let recorded = Base.rects[0]
        let expected = probe.bounds.intersection(inputRect.insetBy(dx: -1, dy: -2))
        check(recorded.insetBy(dx: -1e-6, dy: -1e-6).contains(expected),
              "expanded rect covers inset intersection with bounds")
        let inWindow = probe.convert(recorded, to: nil)
        check(isAligned(inWindow.minX, scale: scale) && isAligned(inWindow.maxX, scale: scale)
              && isAligned(inWindow.minY, scale: scale) && isAligned(inWindow.maxY, scale: scale),
              "dirty rect edges are backing-pixel aligned")

        Base.rects.removeAll()
        probe.setNeedsDisplay(.zero, avoidAdditionalLayout: true)
        check(Base.rects == [.zero], "empty rect passes through unchanged")

        let outside = NSRect(x: 500, y: 500, width: 20, height: 20)
        Base.rects.removeAll()
        probe.setNeedsDisplay(outside, avoidAdditionalLayout: true)
        check(Base.rects == [outside], "non-intersecting rect passes through unchanged")

        probe.setSelectedRange(NSRange(location: 0, length: 5))
        probe.displayIfNeeded()
        probe.needsDisplay = false
        Base.rects.removeAll()
        probe.setSelectedRange(NSRange(location: 0, length: 0))
        check(coversBounds(probe), "clearing selection marks view for redraw")

        probe.setSelectedRange(NSRange(location: 0, length: 5))
        check(window.makeFirstResponder(probe), "probe becomes first responder")
        probe.displayIfNeeded()
        probe.needsDisplay = false
        Base.rects.removeAll()
        check(window.makeFirstResponder(nil), "window resigns probe as first responder")
        check(coversBounds(probe), "resigning first responder marks view for redraw")
        check(probe.selectedRange() == NSRange(location: 0, length: 5),
              "resigning first responder preserves selection")

        check(!window.isVisible, "checks never present a window")
        print("\(count) selection redraw checks passed.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="tivano-selection-redraw-") as directory:
    source = Path(directory) / "checks.swift"
    binary = Path(directory) / "checks"
    source.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
