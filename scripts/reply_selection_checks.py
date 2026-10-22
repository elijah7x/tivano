#!/usr/bin/env python3
"""Exercise reply capture/actions using hidden AppKit views, without launching Tivano.

Production selection and quote logic is extracted below. Renderer identity and
unrelated menu dependencies are stubs. SwiftUI selection uses real Text views;
full Tivano menu gestures still need UI acceptance.
"""
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
import SwiftUI
class LinkTextView: NSTextView { var selectionOwner: UUID? }
struct Attachment: Equatable {}
@MainActor final class ThreadRuntime { var draft = ComposerDraft() }
@MainActor func copyActions(text: String, selection: SelectionCopy) -> [RowAction] { [] }
@MainActor func copyMessageText(_ text: String) { fatalError("Copy is outside this harness") }
'''
for path, marker in (
    ("Tivano/App/Views/Chat/MessagePopoverMenu.swift", "@MainActor\nfinal class SelectionCopy"),
    ("Tivano/App/Views/Chat/MessagePopoverMenu.swift", "fileprivate final class RightClickCatcherView"),
    ("Tivano/UI/Chrome/Popovers.swift", "struct RowAction:"),
    ("Tivano/App/Runtime/ThreadRuntime.swift", "struct ReplyQuote:"),
    ("Tivano/App/Runtime/ThreadRuntime.swift", "struct DraftCommand:"),
    ("Tivano/App/Runtime/ThreadRuntime.swift", "struct ComposerDraft:"),
):
    swift += "\n" + declaration(path, marker)
swift += "\n@MainActor enum MenuHarness {\n"
swift += declaration("Tivano/App/Views/Chat/TimelineRows.swift", "    static func messageActions(")
swift += "\n}\n"
swift += r'''
@main @MainActor enum Checks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        count += 1
        print("PASS \(label)")
    }
    static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let areaA = RightClickCatcherView { _, _ in }
        areaA.frame = NSRect(x: 0, y: 200, width: 500, height: 150)
        let areaB = RightClickCatcherView { _, _ in }
        areaB.frame = NSRect(x: 0, y: 0, width: 500, height: 150)
        root.addSubview(areaA)
        root.addSubview(areaB)
        let ownerA = UUID(), ownerB = UUID()
        let native = LinkTextView(frame: areaA.frame)
        native.isEditable = false
        native.isSelectable = true
        native.selectionOwner = ownerA
        root.addSubview(native)
        let full = "第一段 **dev** 👩🏽‍💻\n\n第二段：本次集成 worktree。"
        let fragment = "次集成 worktree"
        native.string = full
        native.setSelectedRange((full as NSString).range(of: fragment))
        check(window.makeFirstResponder(native), "hidden native responder")
        let clipboardVersion = NSPasteboard.general.changeCount
        let snapshot = SelectionCopy()
        snapshot.capture(in: areaA, owner: ownerA)
        check(snapshot.text == fragment, "second paragraph uses UTF-16 selection")
        let runtime = ThreadRuntime()
        let actions = MenuHarness.messageActions(text: full, code: nil, runtime: runtime, selection: snapshot)
        let add = actions.first { $0.title == "Add to reply" }!
        native.string = "message replaced while menu is open"
        native.setSelectedRange(NSRange(location: 0, length: 0))
        add.action()
        check(runtime.draft.quotes.map(\.text) == [fragment], "menu action keeps original selection after render update")
        check(runtime.draft.quotes[0].excerpt == fragment, "composer chip uses selected excerpt")
        add.action()
        check(runtime.draft.quotes.count == 1, "same fragment deduplicates")
        native.string = full
        let other = "👩🏽‍💻"
        native.setSelectedRange((full as NSString).range(of: other))
        let second = SelectionCopy()
        second.capture(in: areaA, owner: ownerA)
        MenuHarness.messageActions(text: full, code: nil, runtime: runtime, selection: second).last!.action()
        check(runtime.draft.quotes.map(\.text) == [fragment, other], "different fragment of same message is retained")
        runtime.draft.text = "请解释"
        check(runtime.draft.outgoingText == "> \(fragment)\n\n> \(other)\n\n请解释", "outgoing payload contains only quoted selections")
        native.setSelectedRange(NSRange(location: 0, length: 0))
        let empty = SelectionCopy()
        empty.capture(in: areaA, owner: ownerA)
        let fallback = ThreadRuntime()
        MenuHarness.messageActions(text: full, code: nil, runtime: fallback, selection: empty).last!.action()
        check(fallback.draft.quotes.map(\.text) == [full], "no selection quotes full message")
        native.setSelectedRange((full as NSString).range(of: fragment))
        let wrongOwner = SelectionCopy()
        wrongOwner.capture(in: areaB, owner: ownerB)
        check(wrongOwner.text == nil, "another message cannot borrow native selection")
        native.isEditable = true
        let editor = SelectionCopy()
        editor.capture(in: areaA, owner: ownerA)
        check(editor.text == nil, "composer or field editor selection is excluded")
        native.isEditable = false
        native.setSelectedRange(NSRange(location: 0, length: (full as NSString).length))
        let all = SelectionCopy()
        all.capture(in: areaA, owner: ownerA)
        check(all.text == full, "select all preserves paragraph breaks")
        check(NSPasteboard.general.changeCount == clipboardVersion, "capture and Add leave clipboard untouched")
        weak var weakRuntime: ThreadRuntime?
        var retainedAction: RowAction?
        do {
            let transient = ThreadRuntime()
            weakRuntime = transient
            retainedAction = MenuHarness.messageActions(text: full, code: nil, runtime: transient, selection: all).last
        }
        check(weakRuntime == nil, "menu callback does not retain runtime")
        retainedAction?.action()

        native.removeFromSuperview()
        let selectedText = "第二段：本次集成 worktree 👩🏽‍💻"
        let host = NSHostingView(rootView:
            VStack(spacing: 30) {
                Text("第一段，不应被引用").textSelection(.enabled)
                Text(selectedText).textSelection(.enabled)
            }.frame(width: 450, height: 250))
        host.frame = root.bounds
        root.addSubview(host)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        func textViews(_ view: NSView) -> [NSView] {
            (view.accessibilityRole() == .staticText && view.responds(to: #selector(NSText.copy(_:))) ? [view] : [])
                + view.subviews.flatMap(textViews)
        }
        let texts = textViews(host)
        check(texts.count == 2, "real SwiftUI selectable Text responders found")
        let textA = texts[0], textB = texts[1]
        areaA.frame = root.convert(textA.bounds, from: textA).insetBy(dx: -10, dy: -10)
        areaB.frame = root.convert(textB.bounds, from: textB).insetBy(dx: -10, dy: -10)
        check(window.makeFirstResponder(textB), "real SwiftUI text becomes responder")
        textB.setAccessibilitySelectedTextRange((selectedText as NSString).range(of: fragment))
        let swiftUI = SelectionCopy()
        swiftUI.capture(in: areaB, owner: ownerB)
        check(swiftUI.text == fragment, "real SwiftUI partial selection is captured")
        let swiftRuntime = ThreadRuntime()
        let swiftAction = MenuHarness.messageActions(text: "第一段\n\n" + selectedText, code: nil,
                                                    runtime: swiftRuntime, selection: swiftUI).last!
        textB.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 0))
        swiftAction.action()
        check(swiftRuntime.draft.outgoingText == "> \(fragment)\n\n", "SwiftUI quote remains selected text after focus change")
        let swiftEmpty = SelectionCopy()
        swiftEmpty.capture(in: areaB, owner: ownerB)
        check(swiftEmpty.text == nil, "SwiftUI empty selection falls back")
        textB.setAccessibilitySelectedTextRange((selectedText as NSString).range(of: fragment))
        let crossMessage = SelectionCopy()
        crossMessage.capture(in: areaA, owner: ownerA)
        check(crossMessage.text == nil, "real SwiftUI selection cannot cross messages")
        let overlap = RightClickCatcherView { _, _ in }
        overlap.frame = areaB.frame
        root.addSubview(overlap)
        let ambiguous = SelectionCopy()
        ambiguous.capture(in: areaB, owner: ownerB)
        check(ambiguous.text == nil, "overlapping message owners are rejected")
        overlap.removeFromSuperview()
        let multibyte = "👩🏽‍💻"
        textB.setAccessibilitySelectedTextRange((selectedText as NSString).range(of: multibyte))
        let emoji = SelectionCopy()
        emoji.capture(in: areaB, owner: ownerB)
        check(emoji.text == multibyte, "SwiftUI composed emoji selection uses UTF-16")
        check(NSPasteboard.general.changeCount == clipboardVersion, "SwiftUI capture leaves clipboard untouched")
        check(!window.isVisible, "checks never present a window")
        print("\(count) reply selection checks passed; full app menu gestures and Copy remain separate acceptance.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="tivano-reply-selection-") as directory:
    source = Path(directory) / "checks.swift"
    binary = Path(directory) / "checks"
    source.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
