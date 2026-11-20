#!/usr/bin/env python3
"""Exercise LinkTextView height self-heal using hidden AppKit views, without launching Tivano."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LINK_PARAGRAPH = "Tivano/UI/Markdown/LinkParagraphView.swift"


def mask_comments_and_strings(source: str) -> str:
    pattern = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')
    return pattern.sub(lambda match: re.sub(r"[^\n]", " ", match.group(0)), source)


def unique_index(source: str, marker: str) -> int:
    start = source.find(marker)
    if start < 0:
        raise RuntimeError(f"{LINK_PARAGRAPH} missing marker: {marker!r}")
    if source.find(marker, start + len(marker)) >= 0:
        raise RuntimeError(f"{LINK_PARAGRAPH} marker is not unique: {marker!r}")
    return start


def declaration(source: str, masked: str, marker: str) -> str:
    start = unique_index(source, marker)
    opening = masked.find("{", start)
    if opening < 0:
        raise RuntimeError(f"{LINK_PARAGRAPH} missing opening brace after {marker!r}")
    depth = 0
    for pos in range(opening, len(masked)):
        ch = masked[pos]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start : pos + 1]
    raise RuntimeError(f"{LINK_PARAGRAPH} unbalanced braces for {marker!r}")


def extract_section(source: str, masked: str, class_marker: str, section_marker: str) -> str:
    class_decl = declaration(source, masked, class_marker)
    inner = class_decl[:-1]
    start = unique_index(inner, section_marker)
    next_mark = inner.find("// MARK:", start + len(section_marker))
    extracted = inner[start:next_mark] if next_mark >= 0 else inner[start:]
    for required in (
        "debugHeightHealDisabled",
        "resetHeal()",
        "scheduleHeightCheck(",
        "verifyHeight()",
    ):
        if required not in extracted:
            raise RuntimeError(f"{LINK_PARAGRAPH} Height heal section missing {required!r}")
    return extracted.rstrip()


link_paragraph_source = (ROOT / LINK_PARAGRAPH).read_text()
masked_source = mask_comments_and_strings(link_paragraph_source)

invalidate_decl = declaration(
    link_paragraph_source, masked_source, "    private func invalidateMeasuredText()"
)
if "resetHeal()" not in invalidate_decl:
    raise RuntimeError(f"{LINK_PARAGRAPH} invalidateMeasuredText() must call resetHeal()")
if "scheduleHeightCheck()" not in invalidate_decl:
    raise RuntimeError(f"{LINK_PARAGRAPH} invalidateMeasuredText() must schedule a height check after resetHeal()")

layout_decl = declaration(link_paragraph_source, masked_source, "    override func layout()")
if "resetHeal()" not in layout_decl:
    raise RuntimeError(f"{LINK_PARAGRAPH} layout() must call resetHeal() on width change")

height_heal_section = extract_section(
    link_paragraph_source,
    masked_source,
    "final class LinkTextView: NSTextView",
    "    // MARK: - Height heal",
)

extracted_methods = [
    declaration(link_paragraph_source, masked_source, marker)
    for marker in (
        "    func height(forWidth width: CGFloat) -> CGFloat",
        "    override func setFrameSize(_ newSize: NSSize)",
        "    override func viewWillMove(toWindow newWindow: NSWindow?)",
        "    override func viewDidMoveToWindow()",
        "    @objc private func windowDidChangeOcclusionState(_ notification: Notification)",
        "    override func viewDidUnhide()",
    )
]

swift = r'''
import AppKit
import os

@MainActor
class Base: NSTextView {
    var invalidationCount = 0
    var redrawRects: [NSRect] = []
    var markedNeedsDisplay = false
    var onInvalidate: (() -> Void)?

    func resetCounters() {
        invalidationCount = 0
        redrawRects.removeAll()
        markedNeedsDisplay = false
    }

    override func invalidateIntrinsicContentSize() {
        invalidationCount += 1
        super.invalidateIntrinsicContentSize()
        onInvalidate?()
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue {
                markedNeedsDisplay = true
                redrawRects.append(bounds)
            }
            super.needsDisplay = newValue
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        redrawRects.append(rect)
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }
}

@MainActor
final class Probe: Base {
    private let storage = NSTextStorage()
    var measuredHeights: [CGFloat: CGFloat] = [:]
    var measuredWidthOrder: [CGFloat] = []
    var lastMeasuredHeight: CGFloat = 0
    var intrinsicInvalidationQueued = false

    init() {
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = true
        isHorizontallyResizable = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
'''

for method in extracted_methods:
    swift += "\n" + method + "\n"
swift += "\n" + height_heal_section + "\n"

swift += r'''
}

@main @MainActor enum Checks {
    static var count = 0

    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        count += 1
        print("PASS \(label)")
    }

    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func makeWindow() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        contentView.wantsLayer = true
        window.contentView = contentView
        return (window, contentView)
    }

    static func sampleAttributedText() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4.5
        let text = [
            "First line of a finished assistant reply that must never collapse to zero height.",
            "Second line with enough prose to wrap cleanly inside a 300pt text container.",
            "Third line verifying multi-line layout height measurement and self-heal.",
            "Fourth line ensuring the expected height is substantially greater than zero.",
        ].joined(separator: "\n")
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    // needsDisplay reads false in a window that is never presented, so assert on
    // the redraw requests the view actually made.
    static func requestedRedrawCoveringBounds(_ probe: Probe) -> Bool {
        probe.markedNeedsDisplay || probe.redrawRects.contains { rect in
            rect.isInfinite || rect == probe.bounds || rect.contains(probe.bounds)
        }
    }

    static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared

        // (a) Probe with several lines of text framed at 300x0 heals after pumping run loop.
        do {
            let (window, content) = makeWindow()
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            probe.noteReportedHeight(0, forWidth: 300)
            content.addSubview(probe)
            probe.resetCounters()
            pump(0.05)
            let expected = probe.height(forWidth: 300)
            check(expected > 20, "(a) sample text measures multi-line height")
            check(probe.invalidationCount >= 1, "(a) zero-height probe invalidates intrinsic content size")
            check(requestedRedrawCoveringBounds(probe), "(a) zero-height probe requests redraw covering bounds")
            check(abs(probe.lastMeasuredHeight - expected) <= 0.5, "(a) lastMeasuredHeight matches laid-out height")
            check(!window.isVisible, "(a) window stays hidden")
            probe.removeFromSuperview()
        }

        // (b) Probe framed at exact height(forWidth: 300) gets no invalidation.
        do {
            let (window, content) = makeWindow()
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            let exactHeight = probe.height(forWidth: 300)
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: exactHeight)
            probe.noteReportedHeight(exactHeight, forWidth: 300)
            content.addSubview(probe)
            probe.resetCounters()
            pump(0.05)
            check(probe.invalidationCount == 0, "(b) exact-height probe gets no invalidation")
            check(!window.isVisible, "(b) window stays hidden")
            probe.removeFromSuperview()
        }

        // (c) Frame forced back to height 0 after each invalidation stops at most 1 + 3 attempts.
        do {
            let (window, content) = makeWindow()
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            probe.noteReportedHeight(0, forWidth: 300)
            content.addSubview(probe)
            probe.resetCounters()
            probe.onInvalidate = { [weak probe] in
                probe?.noteReportedHeight(0, forWidth: 300)
                probe?.setFrameSize(NSSize(width: 300, height: 0))
            }
            pump(5.0)
            let countAfterBackoff = probe.invalidationCount
            check(countAfterBackoff >= 1 && countAfterBackoff <= 4,
                  "(c) retries bounded to at most 1 + 3 attempts (got \(countAfterBackoff))")
            pump(0.5)
            check(probe.invalidationCount == countAfterBackoff,
                  "(c) no further invalidations after backoff stops")
            check(!window.isVisible, "(c) window stays hidden")
            probe.onInvalidate = nil
            probe.removeFromSuperview()
        }

        // (d) Hiding then unhiding superview with mismatched height triggers a new invalidation.
        do {
            let (window, content) = makeWindow()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            content.addSubview(container)
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            let exactHeight = probe.height(forWidth: 300)
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: exactHeight)
            container.addSubview(probe)
            pump(0.05)
            probe.resetCounters()

            container.isHidden = true
            probe.noteReportedHeight(0, forWidth: 300)
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            pump(0.05)
            check(probe.invalidationCount == 0, "(d) hidden superview suppresses invalidation")

            container.isHidden = false
            pump(0.05)
            check(probe.invalidationCount >= 1,
                  "(d) unhiding superview with mismatched height triggers a new invalidation")
            check(!window.isVisible, "(d) window stays hidden")
            probe.removeFromSuperview()
        }

        // (e) An empty probe never invalidates.
        do {
            let (window, content) = makeWindow()
            let probe = Probe()
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            probe.noteReportedHeight(0, forWidth: 300)
            content.addSubview(probe)
            probe.resetCounters()
            probe.scheduleHeightCheck()
            pump(0.05)
            check(probe.invalidationCount == 0, "(e) empty probe never invalidates")
            check(!window.isVisible, "(e) window stays hidden")
            probe.removeFromSuperview()
        }

        // (f) With intrinsicInvalidationQueued = true, no invalidation happens until cleared.
        do {
            let (window, content) = makeWindow()
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            probe.intrinsicInvalidationQueued = true
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            probe.noteReportedHeight(0, forWidth: 300)
            content.addSubview(probe)
            probe.resetCounters()
            pump(0.05)
            check(probe.invalidationCount == 0,
                  "(f) no invalidation while intrinsicInvalidationQueued is true")

            probe.intrinsicInvalidationQueued = false
            pump(0.05)
            check(probe.invalidationCount >= 1,
                  "(f) rescheduled check invalidates once intrinsicInvalidationQueued clears")
            check(!window.isVisible, "(f) window stays hidden")
            probe.removeFromSuperview()
        }

        // (g) Frame already fits the text (NSTextView sized itself) but SwiftUI was told 0.
        do {
            let (window, content) = makeWindow()
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            let exactHeight = probe.height(forWidth: 300)
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: exactHeight)
            content.addSubview(probe)
            pump(0.05)
            probe.resetCounters()
            probe.noteReportedHeight(0, forWidth: 300)
            probe.scheduleHeightCheck()
            pump(0.05)
            check(probe.invalidationCount >= 1, "(g) stale zero slot heals although bounds fit the text")
            probe.noteReportedHeight(exactHeight, forWidth: 300)
            let healed = probe.invalidationCount
            pump(0.5)
            check(probe.invalidationCount == healed, "(g) a matching report stops the heal")
            check(!window.isVisible, "(g) window stays hidden")
            probe.removeFromSuperview()
        }

        // (h) A stale report alone, with no frame change and no explicit check, heals.
        do {
            let (window, content) = makeWindow()
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            let exactHeight = probe.height(forWidth: 300)
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: exactHeight)
            content.addSubview(probe)
            pump(0.05)
            probe.resetCounters()
            probe.noteReportedHeight(0, forWidth: 300)
            pump(0.05)
            check(probe.invalidationCount >= 1, "(h) recording a stale report schedules its own heal")
            check(!window.isVisible, "(h) window stays hidden")
            probe.removeFromSuperview()
        }

        // (i) SwiftUI keeps getting 0 for 0.6 s after each request (a passing cause), then the
        // real height: immediate re-checks must not use up the attempts inside that moment.
        do {
            let (window, content) = makeWindow()
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            let exactHeight = probe.height(forWidth: 300)
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: exactHeight)
            content.addSubview(probe)
            pump(0.05)
            probe.resetCounters()
            let start = Date()
            var lastReport: CGFloat = -1
            probe.onInvalidate = { [weak probe] in
                guard let probe else { return }
                let report: CGFloat = Date().timeIntervalSince(start) < 0.6 ? 0 : exactHeight
                lastReport = report
                probe.noteReportedHeight(report, forWidth: 300)
            }
            probe.noteReportedHeight(0, forWidth: 300)
            pump(2.0)
            check(lastReport == exactHeight, "(i) heal outlasts a 0.6 s zero-height cause (last report \(lastReport))")
            check(probe.invalidationCount <= 3, "(i) attempts follow the backoff (got \(probe.invalidationCount))")
            probe.onInvalidate = nil
            check(!window.isVisible, "(i) window stays hidden")
            probe.removeFromSuperview()
        }

        // DEBUG disable flag suppresses heal for capture harnesses.
        do {
            let (window, content) = makeWindow()
            Probe.debugHeightHealDisabled = true
            defer { Probe.debugHeightHealDisabled = false }
            let probe = Probe()
            probe.textStorage?.setAttributedString(sampleAttributedText())
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            probe.noteReportedHeight(0, forWidth: 300)
            content.addSubview(probe)
            probe.resetCounters()
            pump(0.05)
            check(probe.invalidationCount == 0, "debugHeightHealDisabled suppresses height heal")
            check(!window.isVisible, "debugHeightHealDisabled window stays hidden")
            probe.removeFromSuperview()
        }

        print("\(count) text height heal checks passed.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="tivano-text-height-heal-") as directory:
    source = Path(directory) / "checks.swift"
    binary = Path(directory) / "checks"
    source.write_text(swift)
    subprocess.run(
        ["xcrun", "swiftc", "-DDEBUG", "-parse-as-library", str(source), "-o", str(binary)],
        check=True,
    )
    subprocess.run([str(binary)], check=True)
