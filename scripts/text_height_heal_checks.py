#!/usr/bin/env python3
"""Verify LinkTextView, TextHeightMeasurer, and TextDisplayAudit text display invariants.

Runs static source checks (on comment/string-masked Swift) and a standalone AppKit harness
extracting the real production TextHeightMeasurer, LinkTextView layout/reconciliation logic,
and TextDisplayAudit implementation without launching Tivano.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LINK_PARAGRAPH = "Tivano/UI/Markdown/LinkParagraphView.swift"
PROSE_RUN = "Tivano/UI/Markdown/ProseRunView.swift"
TEXT_DISPLAY_AUDIT = "Tivano/UI/Markdown/TextDisplayAudit.swift"
STREAM_VEIL = "Tivano/UI/Markdown/StreamVeil.swift"


def mask_comments_and_strings(source: str) -> str:
    pattern = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')
    return pattern.sub(lambda match: re.sub(r"[^\n]", " ", match.group(0)), source)


def unique_index(source: str, marker: str, path: str = LINK_PARAGRAPH) -> int:
    start = source.find(marker)
    if start < 0:
        raise RuntimeError(f"{path} missing marker: {marker!r}")
    if source.find(marker, start + len(marker)) >= 0:
        raise RuntimeError(f"{path} marker is not unique: {marker!r}")
    return start


def declaration(source: str, masked: str, marker: str, path: str = LINK_PARAGRAPH) -> str:
    start = unique_index(source, marker, path)
    opening = masked.find("{", start)
    if opening < 0:
        raise RuntimeError(f"{path} missing opening brace after {marker!r}")
    depth = 0
    for pos in range(opening, len(masked)):
        ch = masked[pos]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start : pos + 1]
    raise RuntimeError(f"{path} unbalanced braces for {marker!r}")


def extract_section_to_class_end(
    class_source: str, section_marker: str, path: str = LINK_PARAGRAPH
) -> str:
    if not class_source.endswith("}"):
        raise RuntimeError(f"{path} extracted class declaration does not end with '}}'")
    inner = class_source[:-1]
    start = unique_index(inner, section_marker, path)
    extracted = inner[start:].rstrip()
    for required in (
        "debugHeightHealDisabled",
        "scheduleReconcile(",
        "scheduleRecheck()",
        "cancelPendingRecheck()",
        "reconcileDisplay(",
        "TextDisplayAudit.audit(",
    ):
        if required not in extracted:
            raise RuntimeError(
                f"{path} Display reconciliation section missing {required!r}"
            )
    return extracted


def strip_top_level_imports(source: str) -> str:
    return "\n".join(
        line for line in source.splitlines() if not line.startswith("import ")
    )


# --- Read sources ---

link_paragraph_source = (ROOT / LINK_PARAGRAPH).read_text()
masked_link_paragraph = mask_comments_and_strings(link_paragraph_source)

prose_run_source = (ROOT / PROSE_RUN).read_text()
masked_prose_run = mask_comments_and_strings(prose_run_source)

audit_source = (ROOT / TEXT_DISPLAY_AUDIT).read_text()
masked_audit = mask_comments_and_strings(audit_source)

stream_veil_source = (ROOT / STREAM_VEIL).read_text()
masked_stream_veil = mask_comments_and_strings(stream_veil_source)


# --- Extract primary declarations ---

measurer_decl = declaration(
    link_paragraph_source,
    masked_link_paragraph,
    "@MainActor\nfinal class TextHeightMeasurer",
    LINK_PARAGRAPH,
)

link_text_view_decl = declaration(
    link_paragraph_source,
    masked_link_paragraph,
    "final class LinkTextView: NSTextView",
    LINK_PARAGRAPH,
)
masked_link_text_view = mask_comments_and_strings(link_text_view_decl)

link_text_veil_decl = declaration(
    stream_veil_source,
    masked_stream_veil,
    "final class LinkTextVeil",
    STREAM_VEIL,
)
masked_link_text_veil = mask_comments_and_strings(link_text_veil_decl)


# --- A. Static checks (on comment/string-masked sources) ---

static_count = 0


def static_check(condition: bool, message: str) -> None:
    global static_count
    if not condition:
        raise RuntimeError(message)
    static_count += 1


for forbidden in (
    "widthTracksTextView = true",
    "isVerticallyResizable = true",
    "autoresizingMask",
    "paintedGeneration",
    "noteReportedHeight",
    "healAttempt",
):
    static_check(
        forbidden not in masked_link_text_view,
        f"{LINK_PARAGRAPH} LinkTextView must not contain {forbidden!r}",
    )

# The display container's width is set in exactly one place: setFrameSize.
set_container_decl = declaration(
    link_text_view_decl, masked_link_text_view, "    private func setContainerWidth(_ width: CGFloat)", LINK_PARAGRAPH
)
static_check(
    masked_link_text_view.count("containerSize =") == 1
    and mask_comments_and_strings(set_container_decl).count("containerSize =") == 1,
    f"{LINK_PARAGRAPH} LinkTextView must set containerSize only in setContainerWidth",
)
match_decl = declaration(
    link_text_view_decl, masked_link_text_view, "    private func matchContainerToBounds()", LINK_PARAGRAPH
)
will_draw_decl = declaration(
    link_text_view_decl, masked_link_text_view, "    override func viewWillDraw()", LINK_PARAGRAPH
)
set_frame_decl = declaration(
    link_text_view_decl, masked_link_text_view, "    override func setFrameSize(_ newSize: NSSize)", LINK_PARAGRAPH
)
hit_test_decl = declaration(
    link_text_view_decl, masked_link_text_view, "    override func hitTest(_ point: NSPoint) -> NSView?", LINK_PARAGRAPH
)
# Whatever width a measurement leaves, the shown width is restored before drawing,
# on every frame change, on every hit test and at the start of every reconcile.
for label, decl in (
    ("viewWillDraw()", will_draw_decl),
    ("setFrameSize(_:)", set_frame_decl),
    ("hitTest(_:)", hit_test_decl),
):
    static_check(
        "matchContainerToBounds()" in mask_comments_and_strings(decl),
        f"{LINK_PARAGRAPH} LinkTextView.{label} must call matchContainerToBounds()",
    )

async_after_count = masked_link_text_view.count("asyncAfter")
static_check(
    async_after_count == 1,
    f"{LINK_PARAGRAPH} LinkTextView must contain 'asyncAfter' exactly once (found {async_after_count})",
)

init_decl = declaration(
    link_text_view_decl, masked_link_text_view, "    init() {", LINK_PARAGRAPH
)
masked_init = mask_comments_and_strings(init_decl)
for required in (
    "isVerticallyResizable = false",
    "isHorizontallyResizable = false",
    "widthTracksTextView = false",
    "backgroundLayoutEnabled = false",
):
    static_check(
        required in masked_init,
        f"{LINK_PARAGRAPH} LinkTextView.init() missing {required!r}",
    )

height_decl = declaration(
    link_text_view_decl,
    masked_link_text_view,
    "    func height(forWidth width: CGFloat) -> CGFloat",
    LINK_PARAGRAPH,
)
masked_height = mask_comments_and_strings(height_decl)
static_check(
    "heightMeasurer.measure(" in masked_height,
    f"{LINK_PARAGRAPH} LinkTextView.height(forWidth:) must call heightMeasurer.measure(",
)

reconcile_trigger_markers = (
    "    private func invalidateMeasuredText()",
    "    override func setFrameSize(_ newSize: NSSize)",
    "    override func viewDidMoveToWindow()",
    "    override func viewDidUnhide()",
    "    @objc private func windowDidChangeOcclusionState(_ notification: Notification)",
)
reconcile_trigger_decls = {}
for marker in reconcile_trigger_markers:
    decl = declaration(link_text_view_decl, masked_link_text_view, marker, LINK_PARAGRAPH)
    masked_decl = mask_comments_and_strings(decl)
    static_check(
        "scheduleReconcile(" in masked_decl,
        f"{LINK_PARAGRAPH} {marker.strip()} must call scheduleReconcile(",
    )
    reconcile_trigger_decls[marker] = decl

static_check(
    "noteReportedHeight" not in masked_prose_run,
    f"{PROSE_RUN} must not contain 'noteReportedHeight'",
)

for forbidden in ("asyncAfter", "Timer", ".string"):
    static_check(
        forbidden not in masked_audit,
        f"{TEXT_DISPLAY_AUDIT} must not contain {forbidden!r}",
    )
for required in ("maxLogsPerProcess", ".fault("):
    static_check(
        required in masked_audit,
        f"{TEXT_DISPLAY_AUDIT} missing required {required!r}",
    )

static_check(
    "var isDissolving: Bool" in masked_link_text_veil,
    f"{STREAM_VEIL} LinkTextVeil missing 'var isDissolving: Bool'",
)

# Verify stored property declarations referenced by extracted LinkTextView methods.
REQUIRED_STORED_PROPERTIES = (
    "    private var lastMeasuredHeight: CGFloat = 0",
    "    private lazy var heightMeasurer = TextHeightMeasurer(storage: storage)",
    "    let streamVeil = LinkTextVeil()",
    "    private let storage = NSTextStorage()",
    "    private var measuredHeights: [CGFloat: CGFloat] = [:]",
    "    private var measuredWidthOrder: [CGFloat] = []",
    "    private var intrinsicInvalidationQueued = false",
)
for prop_decl in REQUIRED_STORED_PROPERTIES:
    unique_index(masked_link_text_view, prop_decl, LINK_PARAGRAPH)
    static_count += 1

print(f"PASS {static_count} static text display invariant checks")


# --- B. Extract remaining runtime harness pieces ---

queue_invalidation_decl = declaration(
    link_text_view_decl,
    masked_link_text_view,
    "    private func queueIntrinsicContentSizeInvalidation()",
    LINK_PARAGRAPH,
)
intrinsic_size_decl = declaration(
    link_text_view_decl,
    masked_link_text_view,
    "    override var intrinsicContentSize: NSSize",
    LINK_PARAGRAPH,
)
view_will_move_decl = declaration(
    link_text_view_decl,
    masked_link_text_view,
    "    override func viewWillMove(toWindow newWindow: NSWindow?)",
    LINK_PARAGRAPH,
)
reconciliation_section = extract_section_to_class_end(
    link_text_view_decl,
    "    // MARK: - Display reconciliation",
    LINK_PARAGRAPH,
)

extracted_methods = [
    init_decl,
    set_container_decl,
    match_decl,
    will_draw_decl,
    reconcile_trigger_decls["    private func invalidateMeasuredText()"],
    height_decl,
    queue_invalidation_decl,
    intrinsic_size_decl,
    reconcile_trigger_decls["    override func setFrameSize(_ newSize: NSSize)"],
    view_will_move_decl,
    reconcile_trigger_decls["    override func viewDidMoveToWindow()"],
    reconcile_trigger_decls[
        "    @objc private func windowDidChangeOcclusionState(_ notification: Notification)"
    ],
    reconcile_trigger_decls["    override func viewDidUnhide()"],
]

swift = r'''
import AppKit
import Foundation
import os

enum RichLink {
    static func armMemoryPressure() {}
}

@MainActor
final class LinkTextVeil {
    var isDissolving = false
}
'''

swift += "\n" + strip_top_level_imports(audit_source) + "\n"
swift += "\n" + measurer_decl + "\n"

swift += r'''
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
'''

for prop_decl in REQUIRED_STORED_PROPERTIES:
    swift += prop_decl + "\n"

swift += r'''
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setMeasuredText(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        invalidateMeasuredText()
    }

    func noteAppended() {
        invalidateMeasuredText()
    }
'''

for method in extracted_methods:
    swift += "\n" + method + "\n"
swift += "\n" + reconciliation_section + "\n"

swift += r'''
}

@main @MainActor enum Checks {
    static var count = 0

    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        count += 1
        print("PASS \(label)")
    }

    // Drain window-server events too: a bare run loop never delivers the occlusion
    // change that makes the audit window count as visible.
    static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    static func makeHiddenWindow() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
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
            "Third line verifying multi-line layout height measurement and reconciliation.",
            "Fourth line ensuring the expected height is substantially greater than zero.",
        ].joined(separator: "\n")
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    static func displayReferenceHeight(for text: NSAttributedString, width: CGFloat, in content: NSView) -> CGFloat {
        let reference = Probe()
        reference.textStorage?.setAttributedString(text)
        reference.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        content.addSubview(reference)
        defer { reference.removeFromSuperview() }
        guard let container = reference.textContainer, let layout = reference.layoutManager else {
            preconditionFailure("reference probe missing TextKit 1 stack")
        }
        precondition(
            abs(container.containerSize.width - width) <= 0.5,
            "reference display container width \(container.containerSize.width) did not track frame width \(width)"
        )
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        // 1. A measurement at another width never outlives the next draw, frame change or tick.
        do {
            let (window, content) = makeHiddenWindow()
            let probe = Probe()
            probe.setMeasuredText(sampleAttributedText())
            let exact = probe.height(forWidth: 300)
            check(exact > 20, "(1) sample text measures multi-line height")
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: exact)
            content.addSubview(probe)
            pump(0.05)

            let layout = probe.layoutManager!
            let container = probe.textContainer!
            layout.ensureLayout(for: container)
            let containerWidthBefore = container.containerSize.width
            let frameBefore = probe.frame
            let unlaidBefore = layout.firstUnlaidCharacterIndex()
            check(abs(containerWidthBefore - 300) <= 0.5, "(1) display container width tracks 300pt frame")
            check(unlaidBefore == probe.textStorage!.length, "(1) initial ensureLayout laid out full storage")

            let h150 = probe.height(forWidth: 150)
            let h600 = probe.height(forWidth: 600)
            let h301 = probe.height(forWidth: 301)
            check(h150 > h600 && h301 > 0, "(1) off-width probes return distinct valid heights")
            check(probe.frame == frameBefore, "(1) display frame unchanged after probes")
            probe.viewWillDraw()
            check(abs(container.containerSize.width - 300) <= 0.5, "(1) viewWillDraw restores the shown width")
            // An uncached width (150 is cached above, and a cache hit touches nothing).
            _ = probe.height(forWidth: 170)
            check(abs(container.containerSize.width - 170) <= 0.5, "(1) a probe may leave the measured width until the next tick")
            pump(0.05)
            check(abs(container.containerSize.width - 300) <= 0.5, "(1) the next tick restores the shown width")
            layout.ensureLayout(for: container)
            check(
                abs(ceil(layout.usedRect(for: container).height) - exact) <= 0.5,
                "(1) restored layout matches the frame height"
            )
            check(probe.frame == frameBefore, "(1) display frame unchanged after restore")
            _ = unlaidBefore
            check(!window.isVisible, "(1) window stays hidden")
            probe.removeFromSuperview()
        }

        // 2. Equivalence between offscreen TextHeightMeasurer path and a real display Probe.
        do {
            let (window, content) = makeHiddenWindow()
            let spacedStyle = NSMutableParagraphStyle()
            spacedStyle.lineSpacing = 6.0
            spacedStyle.paragraphSpacing = 8.0

            let cases: [(String, NSAttributedString)] = [
                (
                    "english",
                    NSAttributedString(
                        string: "The quick brown fox jumps over the lazy dog repeatedly across multiple lines.\nSecond paragraph with steady prose for line breaking verification.\nThird line to confirm multi-line height.",
                        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
                    )
                ),
                (
                    "cjk",
                    NSAttributedString(
                        string: "第一段中文排版测试，包含全角标点符号、长句自动换行，以及中英文 mixed 混排行为。\n第二段继续验证離屏测量器与实际显示视图在窄栏和宽栏下的高度完全一致。",
                        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
                    )
                ),
                (
                    "emoji",
                    NSAttributedString(
                        string: "Launch 🚀✨🎉 family 👨‍👩‍👧‍👦 developer 👩🏽‍💻 flag 🇯🇵 mixed with ordinary prose so lines wrap in narrow and wide columns.\nSecond line 🧪🔥💡 trailing text.",
                        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
                    )
                ),
                (
                    "long-word",
                    NSAttributedString(
                        string: "Prefix supercalifragilisticexpialidocious_abcdefghijklmnopqrstuvwxyz0123456789_unbreakable_token suffix and trailing prose words.",
                        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
                    )
                ),
                (
                    "line-spacing",
                    NSAttributedString(
                        string: "First paragraph with explicit lineSpacing and paragraphSpacing attributes that must carry across offscreen measurement.\nSecond paragraph continuing with enough words to wrap cleanly at every tested width.",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 13),
                            .foregroundColor: NSColor.labelColor,
                            .paragraphStyle: spacedStyle,
                        ]
                    )
                ),
            ]
            let widths: [CGFloat] = [120, 300, 517.5]

            for (label, text) in cases {
                // Keep measurerProbe at frame .zero so height(forWidth:) always exercises TextHeightMeasurer.
                let measurerProbe = Probe()
                measurerProbe.setMeasuredText(text)
                for width in widths {
                    let measured = measurerProbe.height(forWidth: width)
                    let display = displayReferenceHeight(for: text, width: width, in: content)
                    check(
                        measured > 0 && abs(measured - display) <= 0.5,
                        "(2) measurer matches display for \(label) at width \(width) (measured=\(measured) display=\(display))"
                    )
                }
            }
            check(!window.isVisible, "(2) window stays hidden")
        }

        // 3. Frame sovereignty: container width follows setFrameSize, and layout never resizes frame height.
        do {
            let (window, content) = makeHiddenWindow()
            let probe = Probe()
            probe.setMeasuredText(sampleAttributedText())
            let naturalHeight = probe.height(forWidth: 450)
            check(naturalHeight > 40, "(3) natural height at 450pt is multi-line (\(naturalHeight))")

            probe.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
            content.addSubview(probe)
            probe.setFrameSize(NSSize(width: 450, height: 24))
            check(
                abs(probe.textContainer!.containerSize.width - 450) <= 0.5,
                "(3) setFrameSize(450) syncs container width to 450"
            )
            probe.layoutManager!.ensureLayout(for: probe.textContainer!)
            check(
                abs(probe.frame.width - 450) <= 0.01 && abs(probe.frame.height - 24) <= 0.01,
                "(3) ensureLayout does not grow frame height (frame=\(probe.frame))"
            )

            let clippedHeight: CGFloat = 10
            check(clippedHeight < naturalHeight - 20, "(3) clipped height is strictly smaller than natural height")
            probe.setFrameSize(NSSize(width: 450, height: clippedHeight))
            probe.layoutManager!.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: probe.textStorage!.length),
                actualCharacterRange: nil
            )
            probe.layoutManager!.ensureLayout(for: probe.textContainer!)
            check(
                abs(probe.frame.width - 450) <= 0.01 && abs(probe.frame.height - clippedHeight) <= 0.01,
                "(3) relayout keeps clipped frame height unchanged (frame=\(probe.frame))"
            )

            // A width change only invalidates; layout waits for a draw or a measure, so
            // offscreen rows pay nothing while a pane is dragged.
            probe.layoutManager!.ensureLayout(for: probe.textContainer!)
            for width in stride(from: 440, through: 400, by: -1) {
                probe.setFrameSize(NSSize(width: CGFloat(width), height: clippedHeight))
            }
            check(
                abs(probe.textContainer!.containerSize.width - 400) <= 0.5
                    && probe.layoutManager!.firstUnlaidCharacterIndex() < probe.textStorage!.length,
                "(3) width changes leave layout lazy (unlaid=\(probe.layoutManager!.firstUnlaidCharacterIndex()))"
            )
            check(!window.isVisible, "(3) window stays hidden")
            probe.removeFromSuperview()
        }

        // 4. Text version reuse safety: two Probes with equal-length texts and different line counts.
        do {
            let (window, content) = makeHiddenWindow()
            let tallText = NSAttributedString(
                string: String(repeating: "a\n", count: 10),
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            )
            let flatText = NSAttributedString(
                string: String(repeating: "a ", count: 10),
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            )
            check(tallText.length == flatText.length, "(4) test strings have identical UTF-16 length (\(tallText.length))")

            let refTall = displayReferenceHeight(for: tallText, width: 200, in: content)
            let refFlat = displayReferenceHeight(for: flatText, width: 200, in: content)
            check(refTall > refFlat * 3, "(4) tall text (\(refTall)) is substantially taller than flat text (\(refFlat))")

            let probeA = Probe()
            let probeB = Probe()
            probeA.setMeasuredText(tallText)
            probeB.setMeasuredText(flatText)

            let hA1 = probeA.height(forWidth: 200)
            let hB1 = probeB.height(forWidth: 200)
            check(abs(hA1 - refTall) <= 0.5, "(4) probeA first measure at 200 matches tall height (\(hA1))")
            check(abs(hB1 - refFlat) <= 0.5, "(4) probeB first measure at 200 matches flat height (\(hB1))")

            // Alternate across 4 extra widths to evict width 200 from each Probe's 4-entry cache,
            // forcing repeated shared TextHeightMeasurer switches on equal-length storage.
            for width in [202.0, 204.0, 206.0, 208.0] as [CGFloat] {
                let hA = probeA.height(forWidth: width)
                let hB = probeB.height(forWidth: width)
                check(
                    abs(hA - refTall) <= 0.5 && abs(hB - refFlat) <= 0.5,
                    "(4) alternating probes at width \(width) stay isolated (A=\(hA) B=\(hB))"
                )
            }

            let hB2 = probeB.height(forWidth: 200)
            let hA2 = probeA.height(forWidth: 200)
            check(abs(hB2 - refFlat) <= 0.5, "(4) probeB post-eviction measure at 200 matches flat height (\(hB2))")
            check(abs(hA2 - refTall) <= 0.5, "(4) probeA post-eviction measure at 200 matches tall height (\(hA2))")

            // The measuring layout shares the storage, so a streamed append reaches it.
            let tail = NSAttributedString(
                string: "\nappended line one\nappended line two\nappended line three",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            )
            let grown = NSMutableAttributedString(attributedString: probeB.textStorage!)
            grown.append(tail)
            probeB.textStorage?.append(tail)
            probeB.noteAppended()
            let hB3 = probeB.height(forWidth: 200)
            let refGrown = displayReferenceHeight(for: grown, width: 200, in: content)
            check(hB3 > 16 && abs(hB3 - refGrown) <= 0.5, "(4) off-width measure follows an append (\(hB3) vs \(refGrown))")
            check(!window.isVisible, "(4) window stays hidden")
        }

        // 5. Zero-height reconciliation invalidates and stops after the single 0.5s recheck.
        do {
            let (window, content) = makeHiddenWindow()
            let probe = Probe()
            probe.setMeasuredText(sampleAttributedText())
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            // Drain setMeasuredText's detached async invalidation before mounting into window.
            pump(0.05)
            probe.resetCounters()
            probe.onInvalidate = { [weak probe] in
                probe?.setFrameSize(NSSize(width: 300, height: 0))
            }
            content.addSubview(probe)
            pump(0.05)
            check(probe.invalidationCount >= 1, "(5) zero-height probe triggers invalidation after mount")

            // Mount (1) + first reconcile (1) + rechecks at 0.5 s and 2.5 s (2).
            pump(3.0)
            let countAfterRechecks = probe.invalidationCount
            check(
                countAfterRechecks >= 1 && countAfterRechecks <= 4,
                "(5) persistent zero-height retries bounded to <= 4 (got \(countAfterRechecks))"
            )
            pump(1.5)
            check(
                probe.invalidationCount == countAfterRechecks,
                "(5) no further invalidations after the rechecks finish"
            )
            check(!window.isVisible, "(5) window stays hidden")
            probe.onInvalidate = nil
            probe.removeFromSuperview()
        }

        // 6. Exact-height probe produces no invalidation.
        do {
            let (window, content) = makeHiddenWindow()
            let probe = Probe()
            probe.setMeasuredText(sampleAttributedText())
            let exact = probe.height(forWidth: 300)
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: exact)
            pump(0.05)
            // addSubview itself invalidates once (backing properties); count only what follows.
            content.addSubview(probe)
            probe.resetCounters()
            pump(0.6)
            check(probe.invalidationCount == 0, "(6) exact-height probe gets no invalidation over 0.6s")
            check(!window.isVisible, "(6) window stays hidden")
            probe.removeFromSuperview()
        }

        // 7. Hidden ancestor suppresses reconciliation until unhidden.
        do {
            let (window, content) = makeHiddenWindow()
            let parent = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            parent.isHidden = true
            content.addSubview(parent)

            let probe = Probe()
            probe.setMeasuredText(sampleAttributedText())
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            pump(0.05)
            // addSubview itself invalidates once (backing properties); count only what follows.
            parent.addSubview(probe)
            probe.resetCounters()
            pump(0.6)
            check(probe.invalidationCount == 0, "(7) hidden ancestor suppresses zero-height invalidation")

            parent.isHidden = false
            pump(0.05)
            check(probe.invalidationCount >= 1, "(7) unhiding ancestor triggers zero-height invalidation")
            check(!window.isVisible, "(7) window stays hidden")
            probe.removeFromSuperview()
        }

        // 8. DEBUG flag debugHeightHealDisabled suppresses height reconciliation.
        do {
            let (window, content) = makeHiddenWindow()
            Probe.debugHeightHealDisabled = true
            defer { Probe.debugHeightHealDisabled = false }

            let probe = Probe()
            probe.setMeasuredText(sampleAttributedText())
            probe.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
            pump(0.05)
            // addSubview itself invalidates once (backing properties); count only what follows.
            content.addSubview(probe)
            probe.resetCounters()
            pump(0.6)
            check(probe.invalidationCount == 0, "(8) debugHeightHealDisabled suppresses height reconciliation")
            check(!window.isVisible, "(8) window stays hidden")
            probe.removeFromSuperview()
        }

        // 9. TextDisplayAudit checks in a small visible borderless window.
        do {
            let visibleFrame = NSScreen.main?.visibleFrame
                ?? NSScreen.screens.first?.visibleFrame
                ?? NSRect(x: 100, y: 100, width: 800, height: 600)
            let auditWindow = NSWindow(
                contentRect: NSRect(
                    x: visibleFrame.minX + 40,
                    y: visibleFrame.minY + 40,
                    width: 200,
                    height: 200
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            auditWindow.isReleasedWhenClosed = false
            auditWindow.level = .floating
            let auditContent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            auditContent.wantsLayer = true
            auditWindow.contentView = auditContent
            auditWindow.orderFrontRegardless()
            defer {
                auditWindow.orderOut(nil)
                auditWindow.close()
            }

            let deadline = Date().addingTimeInterval(2.0)
            while !auditWindow.occlusionState.contains(.visible), Date() < deadline {
                pump(0.05)
            }
            check(
                auditWindow.occlusionState.contains(.visible),
                "(9) audit window reached visible occlusionState (requires an active GUI session; timed out after 2s)"
            )

            func mountAuditProbe(text: NSAttributedString) -> Probe {
                let probe = Probe()
                probe.setMeasuredText(text)
                let exact = probe.height(forWidth: 180)
                precondition(exact > 0 && exact <= 160, "audit sample height \(exact) must fit inside 200x200 window")
                probe.frame = NSRect(x: 10, y: 10, width: 180, height: exact)
                auditContent.addSubview(probe)
                auditContent.layoutSubtreeIfNeeded()
                probe.layoutManager?.ensureLayout(for: probe.textContainer!)
                precondition(!probe.visibleRect.isEmpty, "mounted audit probe must have non-empty visibleRect")
                return probe
            }

            let opaqueColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
            let clearColor = NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
            let shortBody = "Audit visibility check line one.\nAudit visibility check line two."

            // (9a) Normal opaque text -> audit returns false.
            do {
                let normalText = NSAttributedString(
                    string: shortBody,
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: opaqueColor]
                )
                let probe = mountAuditProbe(text: normalText)
                defer { probe.removeFromSuperview() }
                check(!TextDisplayAudit.audit(probe, reason: "audit_normal"), "(9a) normal text audit returns false")
            }

            // (9b) Storage foreground alpha 0 everywhere -> audit returns true.
            do {
                let transparentText = NSAttributedString(
                    string: shortBody,
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: clearColor]
                )
                let probe = mountAuditProbe(text: transparentText)
                defer { probe.removeFromSuperview() }
                check(
                    TextDisplayAudit.audit(probe, reason: "audit_storage_alpha0"),
                    "(9b) all-transparent storage foreground returns true"
                )
            }

            // (9c) Only trailing characters have temporary alpha 0, rest opaque -> audit returns false.
            do {
                let normalText = NSAttributedString(
                    string: shortBody,
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: opaqueColor]
                )
                let probe = mountAuditProbe(text: normalText)
                defer { probe.removeFromSuperview() }
                let length = probe.textStorage!.length
                let tailLength = min(8, max(1, length / 4))
                let tailRange = NSRange(location: length - tailLength, length: tailLength)
                probe.layoutManager!.addTemporaryAttribute(
                    .foregroundColor,
                    value: clearColor,
                    forCharacterRange: tailRange
                )
                check(
                    !TextDisplayAudit.audit(probe, reason: "audit_partial_temp_alpha0"),
                    "(9c) trailing temporary alpha 0 with opaque prefix returns false"
                )
            }

            // (9d) All characters temporary alpha 0 with textFading: true -> audit returns false.
            do {
                let normalText = NSAttributedString(
                    string: shortBody,
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: opaqueColor]
                )
                let probe = mountAuditProbe(text: normalText)
                defer { probe.removeFromSuperview() }
                let fullRange = NSRange(location: 0, length: probe.textStorage!.length)
                probe.layoutManager!.addTemporaryAttribute(
                    .foregroundColor,
                    value: clearColor,
                    forCharacterRange: fullRange
                )
                check(
                    !TextDisplayAudit.audit(probe, reason: "audit_full_temp_fading", textFading: true),
                    "(9d) full temporary alpha 0 with textFading=true returns false"
                )
                check(
                    TextDisplayAudit.audit(probe, reason: "audit_full_temp_settled", textFading: false),
                    "(9d) full temporary alpha 0 with textFading=false returns true"
                )
            }

            // (9e) Container width diverges from bounds width -> audit returns true.
            do {
                let normalText = NSAttributedString(
                    string: shortBody,
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: opaqueColor]
                )
                // LinkTextView pulls its container back to its width in setFrameSize, so the
                // mismatch is staged on a plain NSTextView (the audit takes any NSTextView).
                let plain = NSTextView(frame: NSRect(x: 10, y: 10, width: 180, height: 40))
                plain.isVerticallyResizable = false
                plain.textContainerInset = NSSize.zero
                plain.textContainer!.lineFragmentPadding = 0
                plain.textContainer!.widthTracksTextView = false
                plain.textStorage!.setAttributedString(normalText)
                auditContent.addSubview(plain)
                defer { plain.removeFromSuperview() }
                plain.textContainer!.containerSize = NSSize(width: 90, height: CGFloat.greatestFiniteMagnitude)
                check(
                    abs(plain.textContainer!.containerSize.width - 90) <= 0.5 && !plain.visibleRect.isEmpty,
                    "(9e) staged container width mismatch holds"
                )
                check(
                    TextDisplayAudit.audit(plain, reason: "audit_container_width"),
                    "(9e) mismatched container width returns true"
                )
            }
        }

        print("\(count) text display invariant checks passed.")
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
