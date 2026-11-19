#!/usr/bin/env python3
"""Offline check for FileMentions core, FileMentionText attachment/offset logic, and headless NSTextView behavior."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    ROOT / 'Tivano/Core/Support/FileMentions.swift',
    ROOT / 'Tivano/App/Views/Composer/FileMentionText.swift',
)

SWIFT_HARNESS = r'''
@MainActor
final class HeadlessTextView: NSTextView {
    let storedUndoManager = UndoManager()
    override var undoManager: UndoManager? { storedUndoManager }
}

@main
@MainActor
enum FileMentionChecks {
    static var count = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if !condition() {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        count += 1
        print("PASS \(label)")
    }

    static func attachments(in text: NSAttributedString) -> [FileMentionAttachment] {
        var found: [FileMentionAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, attrRange, _ in
            guard let attachment = value as? FileMentionAttachment else { return }
            for _ in 0..<attrRange.length {
                found.append(attachment)
            }
        }
        return found
    }

    static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared

        let knownPaths: [String: Bool] = [
            "Docs/a.md": false,
            "Docs/b.md": false,
            "Docs/产品/欢迎.md": false,
            "Docs/营销/欢迎.md": false,
            "a/x/README.md": false,
            "b/x/README.md": false,
            "README.md": false,
            "Tivano/App/": true,
            "Tivano/App/Main.swift": false,
        ]
        let resolve: (String) -> Bool? = { knownPaths[$0] }
        let acceptAll: (String) -> Bool? = { _ in false }

        // 1. tokens
        do {
            let text = "帮我看下 @Docs/a.md 里"
            let found = FileMentions.tokens(in: text, resolve: resolve)
            let expectedRange = (text as NSString).range(of: "@Docs/a.md")
            check(
                found.count == 1 && found[0].range == expectedRange && found[0].path == "Docs/a.md",
                "tokens: CJK sentence UTF-16 range"
            )

            let email = "mail a@b.c"
            check(FileMentions.tokens(in: email, resolve: acceptAll).isEmpty, "tokens: email not after whitespace")

            let unresolved = "check @missing.md and @Docs/a.md"
            let resolvedOnly = FileMentions.tokens(in: unresolved, resolve: resolve)
            check(
                resolvedOnly.count == 1 && resolvedOnly[0].path == "Docs/a.md",
                "tokens: unresolved path excluded"
            )

            check(
                FileMentions.tokens(in: "@", resolve: acceptAll).isEmpty
                    && FileMentions.tokens(in: "hi @ there", resolve: acceptAll).isEmpty
                    && FileMentions.tokens(in: "@ ", resolve: acceptAll).isEmpty,
                "tokens: bare @ excluded"
            )

            let atStart = "@Docs/a.md hello"
            let startTokens = FileMentions.tokens(in: atStart, resolve: resolve)
            check(
                startTokens.count == 1
                    && startTokens[0].range == NSRange(location: 0, length: 10)
                    && startTokens[0].path == "Docs/a.md",
                "tokens: token at index 0"
            )

            let afterNewline = "line1\n@Docs/a.md\t@Docs/b.md"
            let newlineTokens = FileMentions.tokens(in: afterNewline, resolve: resolve)
            let rangeA = (afterNewline as NSString).range(of: "@Docs/a.md")
            let rangeB = (afterNewline as NSString).range(of: "@Docs/b.md")
            check(
                newlineTokens.count == 2
                    && newlineTokens[0].range == rangeA && newlineTokens[0].path == "Docs/a.md"
                    && newlineTokens[1].range == rangeB && newlineTokens[1].path == "Docs/b.md",
                "tokens: after newline and tab"
            )

            let spaced: (String) -> Bool? = { ["Docs/My", "Docs/My Notes.md"].contains($0) ? false : nil }
            let spacedText = "看 @Docs/My Notes.md 里"
            let spacedTokens = FileMentions.tokens(in: spacedText, resolve: spaced)
            check(
                spacedTokens.count == 1 && spacedTokens[0].path == "Docs/My Notes.md"
                    && spacedTokens[0].range == (spacedText as NSString).range(of: "@Docs/My Notes.md"),
                "tokens: a path with a space wins over its shorter prefix"
            )
            check(
                FileMentions.tokens(in: "看 @Docs/My 里", resolve: spaced).map(\.path) == ["Docs/My"],
                "tokens: the shorter path stands when the longer one is absent"
            )
            let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("file-mention-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: (tmp as NSString).appendingPathComponent("~notes.md"), contents: Data())
            let rooted = FileMentionText.resolver(root: tmp)!
            check(rooted("~notes.md") == false && rooted("/etc/hosts") == nil && rooted("../x") == nil
                    && FileMentionText.resolver(root: "") == nil,
                  "resolver: literal tilde names resolve, absolute and .. paths never do")
            try? FileManager.default.removeItem(atPath: tmp)
        }

        // 2. labels
        do {
            let unique = FileMentions.labels(for: ["Docs/a.md", "Tivano/App/", "Docs/a.md"])
            check(
                unique["Docs/a.md"] == FileMentionLabel(name: "a.md", detail: nil)
                    && unique["Tivano/App/"] == FileMentionLabel(name: "App", detail: nil),
                "labels: unique names and duplicate paths get detail nil"
            )

            let cjkDup = FileMentions.labels(for: ["Docs/产品/欢迎.md", "Docs/营销/欢迎.md"])
            check(
                cjkDup["Docs/产品/欢迎.md"] == FileMentionLabel(name: "欢迎.md", detail: "产品")
                    && cjkDup["Docs/营销/欢迎.md"] == FileMentionLabel(name: "欢迎.md", detail: "营销"),
                "labels: single-level parent disambiguation"
            )

            let deepDup = FileMentions.labels(for: ["a/x/README.md", "b/x/README.md"])
            check(
                deepDup["a/x/README.md"] == FileMentionLabel(name: "README.md", detail: "a/x")
                    && deepDup["b/x/README.md"] == FileMentionLabel(name: "README.md", detail: "b/x"),
                "labels: multi-level parent disambiguation"
            )

            let rootAndNested = FileMentions.labels(for: ["README.md", "a/x/README.md"])
            check(
                rootAndNested["README.md"] == FileMentionLabel(name: "README.md", detail: nil)
                    && rootAndNested["a/x/README.md"] == FileMentionLabel(name: "README.md", detail: "x"),
                "labels: parentless path keeps detail nil when distinct"
            )
        }

        let font14 = NSFont.systemFont(ofSize: 14)
        let accent = NSColor.controlAccentColor
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font14,
            .foregroundColor: NSColor.labelColor,
        ]

        // 3. attributed / serialized round trip
        do {
            let samples = [
                "普通文本无引用",
                "帮我看下 @Docs/a.md 里",
                "🚀 看下 @Docs/a.md 和 👩🏽‍💻 结尾",
                "@Docs/a.md 重复 @Docs/a.md 与 @Docs/产品/欢迎.md 和 @Docs/营销/欢迎.md",
                "目录 @Tivano/App/ 和代码 @Tivano/App/Main.swift",
                "非引用字符 \u{FFFC} 保留，再加 @Docs/a.md",
            ]
            for (idx, sample) in samples.enumerated() {
                let attributed = FileMentionText.attributed(
                    from: sample,
                    attributes: baseAttrs,
                    font: font14,
                    accent: accent,
                    resolve: resolve
                )
                let roundTripped = FileMentionText.serialized(attributed)
                check(roundTripped == sample, "round trip sample \(idx)")
            }

            let dirAttr = FileMentionText.attributed(
                from: "dir @Tivano/App/ end",
                attributes: baseAttrs,
                font: font14,
                accent: accent,
                resolve: resolve
            )
            let dirAttachments = attachments(in: dirAttr)
            let tip = dirAttr.attribute(.toolTip, at: 4, effectiveRange: nil) as? String
            check(
                dirAttachments.count == 1
                    && dirAttachments[0].isDirectory
                    && dirAttachments[0].label == FileMentionLabel(name: "App", detail: nil)
                    && tip == "Tivano/App/",
                "attributed sets directory flag, label and tooltip"
            )

            let slice = FileMentionText.serialized(dirAttr, range: NSRange(location: 4, length: 1))
            check(slice == "@Tivano/App/", "serialized respects explicit range")

            check(
                FileMentionText.plainAttributesKeysToStrip.contains(.attachment)
                    && FileMentionText.plainAttributesKeysToStrip.contains(.toolTip),
                "plainAttributesKeysToStrip includes attachment and toolTip"
            )
        }

        // 4. offset mapping
        do {
            let plain = "🚀 帮看 @Docs/a.md 和 @Tivano/App/ 结束"
            let attr = FileMentionText.attributed(
                from: plain,
                attributes: baseAttrs,
                font: font14,
                accent: accent,
                resolve: resolve
            )
            let tokens = FileMentions.tokens(in: plain, resolve: resolve)
            let modelLength = (plain as NSString).length

            var exteriorOK = true
            var interiorOK = true
            var endsOK = true

            for m in 0...modelLength {
                let insideToken = tokens.first { $0.range.location < m && m < NSMaxRange($0.range) }
                if let token = insideToken {
                    let afterAttachmentView = FileMentionText.viewOffset(NSMaxRange(token.range), in: attr)
                    let beforeAttachmentView = FileMentionText.viewOffset(token.range.location, in: attr)
                    let mapped = FileMentionText.viewOffset(m, in: attr)
                    if mapped != afterAttachmentView || afterAttachmentView != beforeAttachmentView + 1 {
                        interiorOK = false
                    }
                } else {
                    let view = FileMentionText.viewOffset(m, in: attr)
                    let back = FileMentionText.modelOffset(view, in: attr)
                    if back != m {
                        exteriorOK = false
                    }
                }

                let expectedEnd = tokens.contains { NSMaxRange($0.range) == m }
                if FileMentionText.mentionEnds(atModelOffset: m, in: attr) != expectedEnd {
                    endsOK = false
                }
            }

            check(exteriorOK, "offset mapping: exterior modelOffset(viewOffset(m)) == m")
            check(interiorOK, "offset mapping: interior offsets map after attachment")
            check(endsOK, "offset mapping: mentionEnds exact at mention ends")

            var rangesOK = true
            for token in tokens {
                let vRange = FileMentionText.viewRange(token.range, in: attr)
                let mRange = FileMentionText.modelRange(vRange, in: attr)
                if vRange.length != 1 || mRange != token.range {
                    rangesOK = false
                }
            }
            let fullModel = NSRange(location: 0, length: modelLength)
            let fullView = FileMentionText.viewRange(fullModel, in: attr)
            if fullView != NSRange(location: 0, length: attr.length)
                || FileMentionText.modelRange(fullView, in: attr) != fullModel {
                rangesOK = false
            }
            let spanModel = NSRange(
                location: tokens[0].range.location,
                length: NSMaxRange(tokens[1].range) - tokens[0].range.location
            )
            if FileMentionText.modelRange(FileMentionText.viewRange(spanModel, in: attr), in: attr) != spanModel {
                rangesOK = false
            }
            check(rangesOK, "offset mapping: modelRange/viewRange consistent")
        }

        // 5. headless NSTextView
        do {
            let textView = HeadlessTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.font = font14

            guard let storage = textView.textStorage else {
                check(false, "headless NSTextView has textStorage")
                return
            }

            let initialPlain = "看看 @Docs/a.md 和 @Doc"
            storage.setAttributedString(FileMentionText.attributed(
                from: initialPlain,
                attributes: baseAttrs,
                font: font14,
                accent: accent,
                resolve: resolve
            ))
            check(FileMentionText.serialized(storage) == initialPlain, "headless NSTextView initial serialized")

            let replaceRange = NSRange(location: storage.length - 4, length: 4)
            let chipAttr = FileMentionText.attributed(
                from: "@Docs/b.md",
                attributes: baseAttrs,
                font: font14,
                accent: accent,
                resolve: resolve
            )
            let accepted = textView.shouldChangeText(in: replaceRange, replacementString: chipAttr.string)
            check(accepted, "headless NSTextView shouldChangeText accepts replacement")
            storage.replaceCharacters(in: replaceRange, with: chipAttr)
            textView.didChangeText()
            textView.breakUndoCoalescing()
            if textView.storedUndoManager.groupingLevel > 0 {
                textView.storedUndoManager.endUndoGrouping()
            }

            let afterInsert = "看看 @Docs/a.md 和 @Docs/b.md"
            check(FileMentionText.serialized(storage) == afterInsert, "headless NSTextView chip replacement serialized")

            check(textView.storedUndoManager.canUndo, "headless NSTextView canUndo after replacement")
            textView.storedUndoManager.undo()
            check(FileMentionText.serialized(storage) == initialPlain, "headless NSTextView undo restores previous text")

            check(textView.storedUndoManager.canRedo, "headless NSTextView canRedo after undo")
            textView.storedUndoManager.redo()
            check(FileMentionText.serialized(storage) == afterInsert, "headless NSTextView redo reapplies chip")

            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            // No run loop here, so the event grouping AppKit relies on is opened by hand.
            textView.storedUndoManager.beginUndoGrouping()
            textView.deleteBackward(nil)
            textView.storedUndoManager.endUndoGrouping()
            let afterDelete = "看看 @Docs/a.md 和 "
            check(FileMentionText.serialized(storage) == afterDelete, "headless NSTextView deleteBackward removes whole chip")
            textView.storedUndoManager.undo()
            check(FileMentionText.serialized(storage) == afterInsert, "headless NSTextView undo of delete restores the chip")
            textView.storedUndoManager.redo()
            check(FileMentionText.serialized(storage) == afterDelete, "headless NSTextView redo of delete removes it again")

            textView.font = NSFont.systemFont(ofSize: 18)
            check(FileMentionText.serialized(storage) == afterDelete, "headless NSTextView setting font preserves attachments")
        }

        // 6. relabel
        do {
            let textView = HeadlessTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.font = font14
            guard let storage = textView.textStorage else {
                check(false, "relabel textStorage available")
                return
            }

            storage.setAttributedString(FileMentionText.attributed(
                from: "@Docs/产品/欢迎.md ",
                attributes: baseAttrs,
                font: font14,
                accent: accent,
                resolve: resolve
            ))
            let beforeInsert = attachments(in: storage)
            check(
                beforeInsert.count == 1 && beforeInsert[0].label == FileMentionLabel(name: "欢迎.md", detail: nil),
                "relabel: single chip starts without detail"
            )

            let secondChip = FileMentionText.attributed(
                from: "@Docs/营销/欢迎.md",
                attributes: baseAttrs,
                font: font14,
                accent: accent,
                resolve: resolve
            )
            storage.append(secondChip)
            FileMentionText.relabel(storage, font: font14, accent: accent)

            let afterSecond = attachments(in: storage)
            check(
                afterSecond.count == 2
                    && afterSecond[0].label == FileMentionLabel(name: "欢迎.md", detail: "产品")
                    && afterSecond[1].label == FileMentionLabel(name: "欢迎.md", detail: "营销")
                    && !textView.storedUndoManager.canUndo,
                "relabel: colliding chips get details without touching undo"
            )

            storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
            FileMentionText.relabel(storage, font: font14, accent: accent)
            let afterDelete = attachments(in: storage)
            check(
                afterDelete.count == 1
                    && afterDelete[0].label == FileMentionLabel(name: "欢迎.md", detail: nil),
                "relabel: deleting duplicate returns remaining chip to detail nil"
            )
        }

        // 7. cell sizes
        do {
            let expectedHeight = ceil(font14.ascender - font14.descender) + 2
            let attachment = FileMentionAttachment(
                path: "Docs/产品/欢迎.md",
                isDirectory: false,
                label: FileMentionLabel(name: "欢迎.md", detail: nil),
                font: font14,
                accent: accent
            )
            guard let cell = attachment.attachmentCell else {
                check(false, "cell sizes: attachment has attachmentCell")
                return
            }
            let sizePlain = cell.cellSize()
            let baseline = cell.cellBaselineOffset()
            check(
                sizePlain.width > 0
                    && sizePlain.height == expectedHeight
                    && baseline.y == font14.descender - 1,
                "cell sizes: 14pt height, positive width, baseline offset"
            )

            attachment.label = FileMentionLabel(name: "欢迎.md", detail: "产品")
            let sizeDetailed = cell.cellSize()
            check(
                sizeDetailed.width > sizePlain.width && sizeDetailed.height == expectedHeight,
                "cell sizes: detail makes chip wider"
            )
        }

        print("\(count) file mention checks passed.")
    }
}
'''


def fail(message: str) -> None:
    print(f'FAIL: {message}', file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    parts = []
    for source in SOURCES:
        if not source.is_file():
            fail(f'missing source file: {source.relative_to(ROOT)}')
        parts.append(source.read_text(encoding='utf-8'))
    parts.append(SWIFT_HARNESS)
    combined = '\n\n'.join(parts) + '\n'

    with tempfile.TemporaryDirectory(prefix='tivano-file-mentions-') as temp:
        directory = Path(temp)
        source_file = directory / 'checks.swift'
        binary = directory / 'checks'
        source_file.write_text(combined, encoding='utf-8')

        try:
            build = subprocess.run(
                [
                    'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    str(source_file), '-o', str(binary),
                ],
                capture_output=True,
                text=True,
                timeout=120,
            )
        except (OSError, subprocess.SubprocessError) as error:
            fail(f'failed to invoke swiftc: {error}')
        if build.returncode != 0:
            detail = (build.stderr or build.stdout).strip()
            fail(f'failed to compile file mention checks (exit {build.returncode}):\n{detail}')

        try:
            run = subprocess.run(
                [str(binary)],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.SubprocessError) as error:
            fail(f'failed to execute compiled check binary: {error}')
        if run.stdout:
            print(run.stdout, end='')
        if run.returncode != 0:
            detail = (run.stderr or run.stdout).strip()
            fail(f'check binary failed (exit {run.returncode}):\n{detail}')


if __name__ == '__main__':
    main()
