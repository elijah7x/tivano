import AppKit
import SwiftUI

/// A merge note's body read into fields, so the popover can draw the card instead of
/// the bare text. The files line carries the numbers; every other line is a status
/// remark worth one quiet row, and the up-to-date line becomes a check rather than text.
struct HydraMergeNote {
    let link: MergeRequestLink
    let files: Int
    let additions: Int
    let deletions: Int
    let target: String
    let branch: String
    let notes: [String]
    let heads: [Head]

    struct Head: Hashable, Identifiable {
        let name: String
        let index: Int
        let task: String
        let files: [String]
        var id: String { "\(index)-\(name)" }
    }

    static func parse(_ body: String, link: MergeRequestLink) -> HydraMergeNote? {
        var match: (files: Int, additions: Int, deletions: Int, target: String, branch: String)?
        var notes: [String] = []
        var heads: [Head] = []
        var inHeads = false
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmed
            guard !line.isEmpty else {
                inHeads = false
                continue
            }
            if line == "Heads" {
                inHeads = true
                continue
            }
            if inHeads {
                if line.hasPrefix("- ") {
                    // Groups 4 and 5 sit in the `no files` alternation, so both are
                    // `Substring?` on a head that landed nothing.
                    if let found = line.wholeMatch(of: #/- (.+?) \((\d+)\): (.*?) — (?:no files|(\d+) files?: (.*))/#) {
                        let filesText = found.output.5 ?? ""
                        heads.append(Head(
                            name: String(found.output.1),
                            index: Int(found.output.2) ?? 0,
                            task: String(found.output.3),
                            files: found.output.4 != nil && !filesText.isEmpty
                                ? filesText.components(separatedBy: ", ") : []
                        ))
                    }
                    continue
                }
                inHeads = false
            }
            // The files line, which makes a body a merge note at all; without it the caller
            // keeps the generic popover. Matched whole: the line is already trimmed.
            if let found = line.wholeMatch(of: #/(\d+) files? \(\+(\d+) −(\d+)\) landed on `([^`]+)` from `([^`]+)`\./#), match == nil {
                guard let files = Int(found.output.1), let additions = Int(found.output.2),
                      let deletions = Int(found.output.3) else { continue }
                match = (files, additions, deletions, String(found.output.4), String(found.output.5))
                continue
            }
            // The checkout line goes without saying once the merge is in; it is not a note.
            if line.hasSuffix("is up to date.") { continue }
            notes.append(line.replacingOccurrences(of: "`", with: ""))
        }
        guard let match else { return nil }
        return HydraMergeNote(
            link: link, files: match.files, additions: match.additions, deletions: match.deletions,
            target: match.target, branch: match.branch, notes: notes, heads: heads
        )
    }
}

/// A merge note as a small card: what landed and where, in numbers first, then the
/// checkout's own standing. Sized to its content, so no empty box hangs off the pill.
struct HydraMergePopover: View {
    let note: HydraMergeNote

    /// The forge's mark beside the title, loaded on appear so the header reads as the
    /// merge request's home rather than a bare label.
    @State private var favicon: NSImage?
    /// The link was just copied: the button says so for a beat.
    @State private var didCopyLink = false
    @State private var hoveredHead: HydraMergeNote.Head?

    /// GitLab calls it a merge request; the other forges call it a pull request.
    private var openTitle: String {
        switch note.link.forge {
        case .gitlab: Chrome.localized("Open merge request")
        case .github, .gitea: Chrome.localized("Open pull request")
        }
    }

    var body: some View {
        let host = note.link.url.host ?? ""
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Group {
                    if let favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.ui(size: 18))
                            .foregroundStyle(Chrome.accent)
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Merged")
                        .font(.ui(.title3, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                    Text(verbatim: String(format: Chrome.localized("%@ on %@"), note.link.label, host))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.ui(size: 20))
                    .foregroundStyle(Chrome.success)
            }
            HStack(spacing: 8) {
                stat(value: "\(note.files)", label: note.files == 1 ? "file" : "files")
                stat(value: "+\(note.additions)", label: "added", tint: Chrome.success)
                stat(value: "−\(note.deletions)", label: "removed", tint: Chrome.danger)
            }
            // The branch chip spans whatever the arrow and the target leave, so the row
            // runs the card's full width and the name only shortens once it truly cannot fit.
            if !note.heads.isEmpty {
                HStack(spacing: 6) {
                    // Eight faces at most: the card's fixed width cannot hold a dozen of
                    // them, and the row spilled out of the popover when a big team came
                    // back. The count beside the faces still names every head that landed.
                    ForEach(Array(note.heads.prefix(8))) { head in
                        HydraGlyph(persona: HydraRoster.persona(at: head.index), size: 26)
                            .help(Text(verbatim: "\(head.name): \(head.task)"))
                            .onHover { inside in
                                if inside { hoveredHead = head } else if hoveredHead == head { hoveredHead = nil }
                            }
                            // Each glyph carries its own popover, so the card hangs from the
                            // face under the cursor; one popover on the row hung from the
                            // row's middle, between the faces and the count.
                            .popover(isPresented: Binding(
                                get: { hoveredHead == head },
                                set: { shown in if !shown, hoveredHead == head { hoveredHead = nil } }
                            ), arrowEdge: .bottom) {
                                headCard(head)
                            }
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: note.heads.count == 1 ? Chrome.localized("1 head landed") : String(format: Chrome.localized("%d heads landed"), note.heads.count))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            HStack(spacing: 6) {
                chip(note.branch, fills: true)
                    .help(note.branch)
                Image(systemName: "arrow.right")
                    .font(.ui(.caption2, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                chip(note.target)
                    .fixedSize()
            }
            ForEach(Array(note.notes.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                    Text(verbatim: entry)
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                // Answers in place like a popover row: the words say the link is copied, a
                // checkmark comes for the beat, then the button is itself again.
                Button {
                    guard !didCopyLink else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.link.url.absoluteString, forType: .string)
                    withAnimation(.snappy(duration: 0.22)) { didCopyLink = true }
                    Task { [copied = $didCopyLink] in
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.snappy(duration: 0.22)) { copied.wrappedValue = false }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if didCopyLink {
                            Image(systemName: "checkmark")
                                .font(.ui(.subheadline, weight: .semibold))
                                .foregroundStyle(Chrome.success)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                        Text(verbatim: didCopyLink ? Chrome.localized("Copied") : Chrome.localized("Copy link"))
                            .contentTransition(.numericText())
                    }
                }
                .buttonStyle(.glass)
                Button {
                    NSWorkspace.shared.open(note.link.url)
                } label: {
                    Label(openTitle, systemImage: "arrow.up.right")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .accessibilityElement(children: .contain)
        .task {
            if let known = FaviconCache.cached(host: host) {
                favicon = known
            } else {
                favicon = await FaviconCache.image(for: host)
            }
        }
    }

    /// One number tile: the count large, what it counts small beneath it.
    private func headCard(_ head: HydraMergeNote.Head) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: head.name)
                .font(.ui(.body, weight: .semibold))
            Text(verbatim: head.task)
                .font(.ui(.callout))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if head.files.isEmpty {
                Text("No files of its own in this merge")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            } else {
                ForEach(head.files, id: \.self) { path in
                    Text(verbatim: path)
                        .font(.ui(.subheadline, design: .monospaced))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func stat(value: String, label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.ui(.title2, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint ?? Chrome.primaryText)
            Text(verbatim: Chrome.localized(label))
                .font(.ui(.footnote, weight: .medium))
                .foregroundStyle(Chrome.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.08)))
    }

    /// A branch name as a capsule, since branch names read as names rather than prose.
    /// A filling chip stretches its capsule across the width it is given.
    private func chip(_ name: String, fills: Bool = false) -> some View {
        Text(verbatim: name)
            .font(.ui(.subheadline, design: .monospaced))
            .foregroundStyle(Chrome.primaryText.opacity(0.9))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
            .background(Capsule(style: .continuous).fill(Chrome.overlay(0.1)))
    }
}
