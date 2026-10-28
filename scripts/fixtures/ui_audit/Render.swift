// Standalone NSHostingView fixtures; no AppModel, stored library or provider.
// The full-product Recorder needs an AppModel/ScreenCaptureKit session. These
// isolated views instead use AppKit's view bitmap API, without capturing a desktop:
// https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:)
@MainActor enum AuditRender {
    static func host<V: View>(_ view: V, size: CGSize, dark: Bool) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Tivano isolated UI audit"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosted = NSHostingView(rootView: AnyView(view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(dark ? .dark : .light)
            .tint(Chrome.accent)))
        window.contentView = hosted
        window.center()
        window.makeKeyAndOrderFront(nil)
        return (window, hosted)
    }

    static func capture(_ name: String, view: NSView, output: URL) async throws {
        // Let SwiftUI's .task and observation updates run. A PNG is an artifact,
        // not proof of the expected rendered state; the lead must inspect it.
        try await Task.sleep(for: .seconds(1))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try Audit.require(view.bitmapImageRepForCachingDisplay(in: view.bounds), "capture bitmap: \(name)")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try Audit.require(bitmap.representation(using: .png, properties: [:]), "PNG encoding: \(name)")
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }

    static func dismiss(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    static func run(data: URL, output: URL) async throws {
        let corrupt = data.appendingPathComponent("broken-preview.png")
        try Data("temporary fixture: deliberately not an image".utf8).write(to: corrupt)
        var rows: [[String: String]] = []
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            ThemeManager.current = dark ? .breezeDark : .breezeLight
            let (previewWindow, previewHost) = host(ToolImagePreview(path: corrupt.path).padding(12),
                                                     size: CGSize(width: 504, height: 340), dark: dark)
            let previewName = "preview-failure-\(theme)"
            try await capture(previewName, view: previewHost, output: output)
            rows.append(["file": previewName + ".png", "expect": "Preview unavailable and Retry; no permanent spinner"])
            dismiss(previewWindow)

            let request = Audit.request(), runtime = ThreadRuntime()
            runtime.auditRequests([request])
            let draft = runtime.questionDraft(for: request)
            draft.selections["format"] = ["Detailed report"]
            draft.selections["detail"] = ["Performance", "Interaction"]
            draft.written["detail"] = "Keep the scroll position and unfinished answers."
            draft.page = 1
            let (firstWindow, firstHost) = host(QuestionSheet(request: request, runtime: runtime),
                                               size: CGSize(width: 460, height: 480), dark: dark)
            let firstName = "question-before-close-\(theme)"
            try await capture(firstName, view: firstHost, output: output)
            rows.append(["file": firstName + ".png", "expect": "Second page; Performance and Interaction selected; free text retained"])
            dismiss(firstWindow)

            let (reopenedWindow, reopenedHost) = host(QuestionSheet(request: request, runtime: runtime),
                                                     size: CGSize(width: 460, height: 480), dark: dark)
            let reopenedName = "question-reopened-\(theme)"
            try await capture(reopenedName, view: reopenedHost, output: output)
            rows.append(["file": reopenedName + ".png", "expect": "Same page, selected choices and free text as before close"])
            runtime.auditRequests([])
            let retiredName = "question-retired-\(theme)"
            try await capture(retiredName, view: reopenedHost, output: output)
            rows.append(["file": retiredName + ".png", "expect": "Old sheet disabled; page reset and draft cleared (fixture has no closePopover handler)"])
            dismiss(reopenedWindow)
        }
        let manifest: [String: Any] = [
            "visualReview": "pending-lead-inspection",
            "captures": rows,
            "scope": "Production ToolImagePreview and QuestionSheet in standalone NSHostingView; production Chrome, theme and type scale",
            "excluded": ["popover positioning and dismissal", "application window chrome", "user mouse/keyboard delivery",
                         "provider request lifecycle", "video playback", "zh-Hans catalog integration"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("render-index.json"), options: .atomic)
        print("Captured \(rows.count) isolated view PNGs; visual review remains pending.")
    }
}
