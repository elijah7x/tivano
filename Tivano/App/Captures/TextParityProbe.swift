#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum TextParityProbe {
    private static var deadline: DispatchSourceTimer?

    private final class ProbeWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class Measurement {
        var size = CGSize.zero
    }

    private struct Scene: View {
        let source: String
        let width: CGFloat
        let pointSize: CGFloat
        let dark: Bool
        let measurement: Measurement

        var body: some View {
            MarkdownView(text: source, isStreaming: true)
                .environment(\.markdownPointSize, pointSize)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self, of: \.size) { measurement.size = $0 }
                .padding(20)
                .frame(width: 920, height: 720, alignment: .topLeading)
                .background(dark ? Color.black : Color.white)
                .preferredColorScheme(dark ? .dark : .light)
        }
    }

    static func run(model: AppModel) async {
        guard CaptureRun.isEnabled, CommandLine.arguments.contains("--text-parity-probe"),
              let output = CaptureRun.outputDirectory else { return }
        await model.bootstrap()
        guard model.isLibraryLoaded else { NSApp.terminate(nil); return }
        let url = output.appendingPathComponent("text-parity.json")
        var report: [String: Any] = ["status": "running", "cases": [],
            "nativePlainProbe": CommandLine.arguments.contains("--native-plain-text-probe"),
            "scope": "actual MarkdownView and native paragraphs; static streaming baseline, no provider or production data"]
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
        }
        save()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(wallDeadline: .now() + 120)
        timer.setEventHandler {
            let data = try? JSONSerialization.data(withJSONObject: ["status": "timeout", "reason": "120 second own-process deadline"])
            try? data?.write(to: url, options: .atomic)
            _exit(124)
        }
        timer.resume(); deadline = timer
        let window = ProbeWindow(contentRect: NSRect(x: 120, y: 100, width: 920, height: 720),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Isolated paragraph parity"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))
        let fixtures = [
            String(repeating: "Plain selectable text keeps its wrapping, baseline and spacing. ", count: 10),
            "中文排版与标点，组合字符 e\u{301}，阿拉伯语 العربية，emoji 👨‍👩‍👧‍👦 👍🏽 🇨🇳 1️⃣。\n" + String(repeating: "中文与 English 混合换行，保留原来的字体与高度。", count: 5),
            "Plain **bold** *italic* ***bold italic*** `inline code` then normal text.\nSecond line with ~~literal markers~~ and escaped \\*stars\\*.",
            "- First item with enough prose to wrap onto another line without moving the marker.\n- **Bold** item and `code`.\n  - Nested 中文内容。\n\n1. Ordered item.\n2. Another item.",
            "> Quoted text with **weight**, *emphasis*, and mixed 中文 / العربية.\n> Another line that wraps without changing its leading inset.\n\nA paragraph after the quote.",
            "Combining A\u{301}\u{308}, Hangul 각, Indic क्‍षि, CRLF follows.\r\nFlags 🇦🇧🇨🇩 and a long word: " + String(repeating: "abcdefgh", count: 20),
        ]
        var cases: [[String: Any]] = []
        var lastHost: NSHostingView<Scene>?
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for size in [CGFloat(13), CGFloat(17)] {
                for width in [CGFloat(420), CGFloat(820)] {
                    for (fixture, source) in fixtures.enumerated() {
                        guard CommandLine.arguments.contains("--allow-locked-screen")
                                || (NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)) else {
                            report["status"] = "blocked"; report["reason"] = "probe lost foreground"; report["cases"] = cases
                            save(); NSApp.terminate(nil); return
                        }
                        let measurement = Measurement()
                        let host = NSHostingView(rootView: Scene(source: source, width: width, pointSize: size, dark: dark, measurement: measurement))
                        host.frame = NSRect(x: 0, y: 0, width: 920, height: 720)
                        window.contentView = host
                        try? await Task.sleep(for: .milliseconds(180))
                        host.layoutSubtreeIfNeeded()
                        let name = "case-\(cases.count).png"
                        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
                        if let bitmap { host.cacheDisplay(in: host.bounds, to: bitmap) }
                        let data = bitmap?.representation(using: .png, properties: [:])
                        try? data?.write(to: output.appendingPathComponent(name), options: .atomic)
                        let valid = data != nil && measurement.size.width == width
                            && measurement.size.height > 0 && measurement.size.height < 680
                        cases.append(["index": cases.count, "fixture": fixture, "dark": dark, "pointSize": size,
                                      "width": width, "measuredSize": [measurement.size.width, measurement.size.height],
                                      "image": name, "valid": valid, "scale": window.backingScaleFactor])
                        lastHost = host
                    }
                }
            }
        }
        func paragraphs(_ view: NSView) -> [LinkTextView] {
            (view as? LinkTextView).map { [$0] } ?? view.subviews.flatMap(paragraphs)
        }
        if let view = lastHost.flatMap({ paragraphs($0).first }), (view.string as NSString).length > 12 {
            let range = NSRange(location: 2, length: 6)
            window.makeFirstResponder(view)
            view.setSelectedRange(range)
            let expected = (view.string as NSString).substring(with: range)
            let original = NSAttributedString(attributedString: view.textStorage!)
            let appended = NSMutableAttributedString(attributedString: original)
            appended.append(NSAttributedString(string: " More fixture text.", attributes: original.attributes(at: 0, effectiveRange: nil)))
            view.render(appended)
            let selected = view.selectedRange()
            let pasteboard = NSPasteboard.withUniqueName()
            let types = view.writablePasteboardTypes
            let copied = view.writeSelection(to: pasteboard, types: types)
            report["copyPasteboardTypes"] = types.map(\.rawValue)
            report["nativeSelectionAcrossAppend"] = ["isSelectable": view.isSelectable,
                "rangePreserved": selected == range,
                "selectedTextPreserved": selected == range && (view.string as NSString).substring(with: selected) == expected,
                "firstResponderIsTextView": window.firstResponder === view,
                "writeSelectionReturned": copied,
                "privatePasteboardMatches": copied && types.contains { pasteboard.string(forType: $0) == expected }]
            pasteboard.releaseGlobally()
        }
        report["cases"] = cases
        report["status"] = cases.allSatisfy { $0["valid"] as? Bool == true } ? "completed" : "blocked"
        if CommandLine.arguments.contains("--hold-text-parity-probe") { report["UIInspectionHoldSeconds"] = 60 }
        save()
        if CommandLine.arguments.contains("--hold-text-parity-probe") {
            try? await Task.sleep(for: .seconds(60))
        }
        window.orderOut(nil)
        NSApp.terminate(nil)
    }
}
#endif
