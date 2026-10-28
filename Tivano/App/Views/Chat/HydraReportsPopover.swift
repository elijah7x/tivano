import SwiftUI

/// A heads' report batch read as a digest: the intro, then one entry per head with
/// its outcome, its files and its report. The lead's closing instructions ride in
/// the last head's body and are dropped, since they are for the lead, not the user.
struct HydraReportDigest {
    let intro: String?
    let heads: [Head]

    struct Head: Identifiable {
        let id: String
        let name: String
        let task: String
        let outcome: Outcome
        let effort: String?
        let landing: Landing
        let flags: HydraReportNotes
        let reportFormatMissing: Bool
        let body: String
    }

    enum Outcome {
        case done, failed, stopped
    }

    enum Landing {
        case landed([LandedFile])
        case notLanded([LandedFile], error: String?)
        case nothing
        case unfinished(copyPath: String?)
        case none
    }

    struct LandedFile: Identifiable {
        let path: String
        let additions: Int
        let deletions: Int
        let hasConflicts: Bool
        var id: String { path }
    }

    /// The report off the lead's `reportMessage`: everything before the first head
    /// header is the intro, each head header starts a head, other `## ` headings
    /// stay in the report, and trailing `(...)` groups on the header are the
    /// outcome or the effort rather than the task.
    static func parse(_ text: String) -> HydraReportDigest {
        let lines = text.components(separatedBy: "\n")
        var introLines: [String] = []
        var sections: [(header: String, lines: [String])] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## "), Self.isHeadHeader(String(trimmed.dropFirst(3))) {
                sections.append((String(trimmed.dropFirst(3)), []))
            } else if sections.isEmpty {
                introLines.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        let intro = introLines.joined(separator: "\n").trimmed
        var heads: [Head] = []
        for (index, section) in sections.enumerated() {
            let (name, task, outcome, effort) = parseHeader(section.header)
            var rest = section.lines
            while let first = rest.first, first.trimmed.isEmpty {
                rest.removeFirst()
            }
            var flags = HydraReportNotes()
            var reportFormatMissing = false
            let hasFlagsBlock = rest.first?.trimmed == "Flags:"
            if hasFlagsBlock {
                rest.removeFirst()
                let hasLanding = rest.contains(where: Self.landingPrefix)
                var currentLabel: String?
                while let first = rest.first {
                    let line = first.trimmed
                    if Self.landingPrefix(line) { break }
                    if line.isEmpty || line.lowercased() == "none" {
                        rest.removeFirst()
                        continue
                    }
                    if line == "Report format not followed." {
                        reportFormatMissing = true
                    } else if let label = HydraReportNotes.labels.first(where: { line.hasPrefix($0 + ":") }) {
                        currentLabel = label
                        let value = String(line.dropFirst(label.count + 1)).trimmed
                        let flag = value.isEmpty || value.lowercased() == "none" ? nil : value
                        switch label {
                        case "Deviations": flags.deviations = flag
                        case "Unfinished": flags.unfinished = flag
                        default: flags.uncertain = flag
                        }
                    } else if hasLanding, let label = currentLabel {
                        switch label {
                        case "Deviations": flags.deviations = [flags.deviations, line].compactMap { $0 }.joined(separator: "\n")
                        case "Unfinished": flags.unfinished = [flags.unfinished, line].compactMap { $0 }.joined(separator: "\n")
                        default: flags.uncertain = [flags.uncertain, line].compactMap { $0 }.joined(separator: "\n")
                        }
                    } else { break }
                    rest.removeFirst()
                }
            }
            var landing = Landing.none
            if let first = rest.first, Self.landingPrefix(first) {
                landing = parseLanding(first.trimmed)
                rest.removeFirst()
            }
            var body = rest.joined(separator: "\n").trimmed
            if index == sections.count - 1 { body = withoutLeadInstructions(body) }
            heads.append(Head(id: name, name: name, task: task, outcome: outcome, effort: effort, landing: landing, flags: flags, reportFormatMissing: reportFormatMissing, body: hasFlagsBlock ? HydraReportFlagsRows.withoutTrailingFlags(body) : body))
        }
        return HydraReportDigest(intro: intro.isEmpty ? nil : intro, heads: heads)
    }

    /// A `## ` line starts a head only when the text before its first colon is a
    /// roster name; anything else (a head's own markdown headings) stays in the body.
    private static func isHeadHeader(_ header: String) -> Bool {
        guard let colon = header.firstIndex(of: ":") else { return false }
        let name = String(header[..<colon]).trimmingCharacters(in: .whitespaces)
        return HydraRoster.index(named: name) != nil
    }

    /// The name off the colon, then trailing `(...)` groups stripped from the task:
    /// `failed` or `stopped...` is the outcome, anything else the effort.
    private static func parseHeader(_ header: String) -> (name: String, task: String, outcome: Outcome, effort: String?) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let name: String
        var rest: String
        if let colon = trimmed.firstIndex(of: ":") {
            name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else {
            name = trimmed
            rest = ""
        }
        var outcome = Outcome.done
        var efforts: [String] = []
        let metaEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max", "ultra", "minimal", "fast", "default"]
        while rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
            let group = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            let lower = group.lowercased()
            let isMeta = lower == "failed" || lower.hasPrefix("stopped")
                || group.rangeOfCharacter(from: .decimalDigits) != nil
                || metaEfforts.contains(lower)
            guard isMeta else { break }
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            if lower == "failed" {
                outcome = .failed
            } else if lower.hasPrefix("stopped") {
                outcome = .stopped
            } else if !group.isEmpty {
                efforts.insert(group.replacingOccurrences(of: ", ", with: " · "), at: 0)
            }
        }
        return (name, rest, outcome, efforts.isEmpty ? nil : efforts.joined(separator: " · "))
    }

    private static func landingPrefix(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("Landed in your checkout:")
            || trimmed.hasPrefix("Did not land")
            || trimmed.hasPrefix("Changed nothing.")
            || trimmed.hasPrefix("Nothing landed")
    }

    /// The landing line off its prefix: the files part is comma-separated
    /// `path (+A −D)` items, before any `, and N more` or build-output tail.
    private static func parseLanding(_ line: String) -> Landing {
        if line.hasPrefix("Changed nothing.") { return .nothing }
        if line.hasPrefix("Nothing landed") {
            if let range = line.range(of: "in its copy at ") {
                var path = String(line[range.upperBound...]).trimmed
                if path.hasSuffix(".") { path = String(path.dropLast()) }
                return .unfinished(copyPath: path.isEmpty ? nil : path)
            }
            return .unfinished(copyPath: nil)
        }
        if line.hasPrefix("Landed in your checkout:") {
            return .landed(parseFiles(String(line.dropFirst("Landed in your checkout:".count))))
        }
        if line.hasPrefix("Did not land") {
            var rest = String(line.dropFirst("Did not land".count))
            var error: String?
            if rest.hasPrefix(" ("), let close = rest.firstIndex(of: ")") {
                error = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close]).trimmingCharacters(in: .whitespaces)
                rest = String(rest[rest.index(after: close)...])
            }
            if rest.hasPrefix(":") { rest = String(rest.dropFirst()) }
            return .notLanded(parseFiles(rest), error: error.flatMap { $0.isEmpty ? nil : $0 })
        }
        return .none
    }

    private static func parseFiles(_ raw: String) -> [LandedFile] {
        var text = raw.trimmed
        if text.hasSuffix(".") { text = String(text.dropLast()) }
        // The tails the lead appends after the files, longest first.
        for suffix in [#"; \d+ build-output files? (was|were) left out$"#, #", and \d+ more$"#] {
            if let range = text.range(of: suffix, options: .regularExpression) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.components(separatedBy: ", ").compactMap { item in
            matchFile(item.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func matchFile(_ item: String) -> LandedFile? {
        // The minus the lead writes is U+2212; a hyphen still matches for safety.
        guard let match = item.wholeMatch(of: #/(\S+) \(\+(\d+) [−\-](\d+)\)( with conflicts)?/#),
              let additions = Int(match.output.2), let deletions = Int(match.output.3) else { return nil }
        return LandedFile(
            path: String(match.output.1),
            additions: additions,
            deletions: deletions,
            hasConflicts: match.output.4 != nil
        )
    }

    /// The closing paragraph the lead appends for itself is not the heads' report;
    /// it leaves with the last head's final paragraph when it reads like instructions.
    private static let leadPrefixes = [
        "The changes listed above", "The heads worked in your checkout", "A file listed with conflicts",
        "Do not check any of this", "Do not wait for", "A head that failed", "A head the user stopped",
        "The user queued", "The user sent",
    ]

    private static func withoutLeadInstructions(_ body: String) -> String {
        guard let range = body.range(of: "\n\n", options: .backwards) else { return body }
        let tail = String(body[range.upperBound...]).trimmed
        guard leadPrefixes.contains(where: { tail.hasPrefix($0) }) else { return body }
        return String(body[..<range.lowerBound]).trimmed
    }
}

/// The digest of a heads' report batch in the popover its pill opens, laid out like a
/// native popover: a header that stays put, then one plain card per head with its
/// outcome, its files and its report, scrolling under it. Everything the first layout
/// shows is ready before it: the digest, and one head's report (which reads whole) as
/// blocks the pill warmed or a cold tap parses now; with several heads the reports
/// start collapsed and warm in the background. `PopoverScroll` lays the cards out once
/// at the popover's width, so it opens at its final size instead of growing. With one
/// head the header carries the head and its task, and the card is just its files and report.
struct HydraReportsPopover: View {
    let title: String
    let text: String
    let personas: [HydraPersona]
    private let digest: HydraReportDigest
    private var single: HydraReportDigest.Head? { digest.heads.count == 1 ? digest.heads.first : nil }

    @State private var expanded: Set<String>
    @State private var blocks: [String: [MarkdownBlock]]

    /// The popover's width; the cards are measured at it.
    private static let width: CGFloat = 460

    @MainActor
    init(title: String, text: String, personas: [HydraPersona]) {
        self.title = title
        self.text = text
        self.personas = personas
        let parsed = HydraReportDigest.parse(text)
        digest = parsed
        // One head's report reads whole; several start collapsed to their files.
        if parsed.heads.count == 1, let head = parsed.heads.first {
            _expanded = State(initialValue: [head.name])
            _blocks = State(initialValue: [head.name: MarkdownView.blocks(for: head.body)])
        } else {
            _expanded = State(initialValue: [])
            _blocks = State(initialValue: [:])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            let collapsible = digest.heads.count > 1
            PopoverScroll(maxHeight: 520, width: Self.width) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(digest.heads.enumerated()), id: \.element.id) { index, head in
                        headCard(head, index: index, collapsible: collapsible)
                    }
                }
                .padding(collapsible ? 10 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
        .task(id: text) {
            // The reports not on screen yet parse off the main thread, so opening a card
            // finds its blocks ready.
            let missing = digest.heads.filter { blocks[$0.name] == nil }
            guard !missing.isEmpty else { return }
            try? await MarkdownView.warm(missing.map(\.body))
            guard !Task.isCancelled else { return }
            var warmed = blocks
            for head in missing {
                warmed[head.name] = MarkdownView.blocks(for: head.body)
            }
            blocks = warmed
        }
    }

    // MARK: Header

    /// Who reported, and the one sentence saying who is still at work, if anyone is.
    /// With one head the header carries the head itself: its name, outcome, files and task.
    @ViewBuilder
    private var header: some View {
        if let head = single {
            singleHeader(head)
        } else {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: -6) {
                    ForEach(Array(personas.prefix(9)), id: \.self) { persona in
                        HydraGlyph(persona: persona, size: 22)
                    }
                    if personas.count > 9 {
                        // Faces past a handful overrun the header: the rest are counted
                        // here, and the totals line beside names the full number.
                        Text(verbatim: "+\(personas.count - 9)")
                            .font(.ui(.subheadline, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule(style: .continuous).fill(Chrome.overlay(0.1)))
                            .padding(.leading, 10)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.cleanedTitle(title, names: personas.map(\.name)))
                        .foregroundColor(Chrome.primaryText)
                        .font(.ui(.body, weight: .semibold))
                        .lineLimit(2)
                    Text(Self.totalsLine(for: digest))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .monospacedDigit()
                    if let intro = digest.intro, let sentence = Self.stillAtWorkSentence(in: intro) {
                        Text(sentence)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .lineLimit(2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func singleHeader(_ head: HydraReportDigest.Head) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HydraGlyph(persona: persona(for: head), size: 24, status: Self.status(head.outcome))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(head.name)
                        .font(.ui(.body, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                    Text(Self.outcomeCaption(for: head))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Self.outcomeColor(for: head.outcome))
                        .monospacedDigit()
                    if let files = Self.filesLine(for: head) {
                        Text("· " + files)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                let task = Self.withoutNamePrefix(Self.cleanedTitle(head.task, names: [head.name]), name: head.name)
                Text(task.isEmpty ? Self.cleanedTitle(title, names: [head.name]) : task)
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let intro = digest.intro, let sentence = Self.stillAtWorkSentence(in: intro) {
                    Text(sentence)
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private static func outcomeCaption(for head: HydraReportDigest.Head) -> String {
        let base: String
        switch head.outcome {
        case .done: base = Chrome.localized("Finished")
        case .failed: base = Chrome.localized("Failed")
        case .stopped: base = Chrome.localized("Stopped")
        }
        guard let effort = head.effort, !effort.isEmpty else { return base }
        return base + " · " + effort
    }

    private static func outcomeColor(for outcome: HydraReportDigest.Outcome) -> Color {
        switch outcome {
        case .failed: return Chrome.danger
        case .stopped: return Chrome.warning
        case .done: return Chrome.secondaryText
        }
    }

    private static func filesLine(for head: HydraReportDigest.Head) -> String? {
        let files: [HydraReportDigest.LandedFile]
        switch head.landing {
        case .landed(let f): files = f
        case .notLanded(let f, _): files = f
        default: return nil
        }
        guard !files.isEmpty else { return nil }
        let f = files.count
        let a = files.reduce(0) { $0 + $1.additions }
        let d = files.reduce(0) { $0 + $1.deletions }
        return (f == 1 ? Chrome.localized("1 file") : String(format: Chrome.localized("%d files"), f)) + " · +\(a) −\(d)"
    }

    /// The title with a head's name said once: a lead that writes "Juno: Juno: streaming
    /// path" has the repeated `Name: ` (or `Name `) prefix dropped until one name is left.
    static func cleanedTitle(_ title: String, names: [String]) -> String {
        var cleaned = title
        for name in names where !name.isEmpty {
            let prefixes = ["\(name): ", "\(name) "]
            func namePrefix(of string: String) -> String? {
                prefixes.first { string.hasPrefix($0) }
            }
            while let prefix = namePrefix(of: cleaned), namePrefix(of: String(cleaned.dropFirst(prefix.count))) != nil {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
        }
        return cleaned
    }

    /// The string without one leading `Name: `, for a line that sits under the name already.
    private static func withoutNamePrefix(_ string: String, name: String) -> String {
        let prefix = "\(name): "
        guard !name.isEmpty, string.hasPrefix(prefix) else { return string }
        return String(string.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// '<N> heads · <F> files · +<A> −<D>', dropping the files part when no files.
    private static func totalsLine(for digest: HydraReportDigest) -> String {
        let n = digest.heads.count
        var files: [HydraReportDigest.LandedFile] = []
        for head in digest.heads {
            switch head.landing {
            case .landed(let f): files.append(contentsOf: f)
            case .notLanded(let f, _): files.append(contentsOf: f)
            default: break
            }
        }
        var line = n == 1 ? Chrome.localized("1 head") : String(format: Chrome.localized("%d heads"), n)
        guard !files.isEmpty else { return line }
        let f = files.count
        let a = files.reduce(0) { $0 + $1.additions }
        let d = files.reduce(0) { $0 + $1.deletions }
        line += " · " + (f == 1 ? Chrome.localized("1 file") : String(format: Chrome.localized("%d files"), f)) + " · +\(a) −\(d)"
        return line
    }

    /// The sentence holding 'still at work', from its start to the intro's end.
    private static func stillAtWorkSentence(in intro: String) -> String? {
        guard let match = intro.range(of: "still at work") else { return nil }
        let start: String.Index
        if let stop = intro[..<match.lowerBound].lastIndex(of: ".") {
            start = intro.index(after: stop)
        } else {
            start = intro.startIndex
        }
        let sentence = String(intro[start...]).trimmed
        return sentence.isEmpty ? nil : sentence
    }

    // MARK: Cards

    private func persona(for head: HydraReportDigest.Head) -> HydraPersona {
        if let match = personas.first(where: { $0.name == head.name }) { return match }
        if let persona = HydraRoster.persona(named: head.name) { return persona }
        return HydraRoster.persona(at: 0)
    }

    private static func status(_ outcome: HydraReportDigest.Outcome) -> HydraHeadInfo.Status {
        switch outcome {
        case .done: return .completed
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }

    /// One head: its name over its outcome, its task, its files, then its report. With
    /// several heads the name row is the toggle that opens and closes the report.
    private func headCard(_ head: HydraReportDigest.Head, index: Int, collapsible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if collapsible {
                if hasReport(head) {
                    // No animation, like the diff inspector's file cards: the popover takes
                    // its height from the content, and an animated toggle feeds it a new
                    // height every frame, which AppKit animates again on top.
                    Button {
                        if expanded.contains(head.name) {
                            expanded.remove(head.name)
                        } else {
                            expanded.insert(head.name)
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 6) {
                            nameRow(head)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.ui(.footnote, weight: .semibold))
                                .foregroundStyle(Chrome.secondaryText)
                                .rotationEffect(.degrees(expanded.contains(head.name) ? 90 : 0))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    nameRow(head)
                }
            }
            if collapsible {
                // The name is on the row above, so the task drops any lead of its own.
                let task = Self.withoutNamePrefix(Self.cleanedTitle(head.task, names: [head.name]), name: head.name)
                if !task.isEmpty {
                    Text(task)
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HydraReportFlagsRows(notes: head.flags, formatMissing: head.reportFormatMissing)
            landingRows(head.landing)
            if !collapsible || expanded.contains(head.name) {
                reportBody(head)
            }
        }
        .padding(12)
        .background {
            if collapsible {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.overlay(0.05))
            }
        }
    }

    /// The head's name and, beside it, its outcome as a seal or caption plus its effort.
    private func nameRow(_ head: HydraReportDigest.Head) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HydraGlyph(persona: persona(for: head), size: 20, status: Self.status(head.outcome))
            Text(head.name)
                .font(.ui(.body, weight: .semibold))
                .foregroundStyle(persona(for: head).color)
            switch head.outcome {
            case .done:
                EmptyView()
            case .failed:
                Text("Failed")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.danger)
            case .stopped:
                Text("Stopped")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.warning)
            }
            Spacer(minLength: 8)
            if let effort = head.effort, !effort.isEmpty {
                Text(effort)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private func hasReport(_ head: HydraReportDigest.Head) -> Bool {
        !(head.body.isEmpty || head.body == "No report.")
    }

    /// Where the head's work went: its files as monospaced rows, or one line saying otherwise.
    @ViewBuilder
    private func landingRows(_ landing: HydraReportDigest.Landing) -> some View {
        switch landing {
        case .landed(let files):
            fileRows(files)
        case .notLanded(let files, let error):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: error.map { String(format: Chrome.localized("Did not land: %@"), $0) } ?? Chrome.localized("Did not land"))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.warning)
                    .fixedSize(horizontal: false, vertical: true)
                fileRows(files)
            }
        case .nothing:
            Text("Changed nothing.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
        case .unfinished(let copyPath):
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing landed")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.warning)
                if let copyPath {
                    Text(copyPath)
                        .font(.ui(.subheadline, design: .monospaced))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .none:
            EmptyView()
        }
    }

    /// Each file on a row of its own: the path, trimmed in the middle when long, and
    /// its additions and deletions at the end. A file still carrying conflict markers
    /// says so in amber.
    @ViewBuilder
    private func fileRows(_ files: [HydraReportDigest.LandedFile]) -> some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        filePathText(file)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            Text("+\(file.additions)").foregroundStyle(Chrome.success)
                            Text("−\(file.deletions)").foregroundStyle(Chrome.danger)
                        }
                        .monospacedDigit()
                        .layoutPriority(1)
                    }
                    .font(.ui(.subheadline, design: .monospaced))
                    .help(file.hasConflicts ? String(format: Chrome.localized("%@ (with conflicts)"), file.path) : file.path)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.overlay(0.05)))
        }
    }

    private func filePathText(_ file: HydraReportDigest.LandedFile) -> Text {
        let path = file.path
        let slash = path.lastIndex(of: "/")
        let directory = slash.map { String(path[...$0]) } ?? ""
        let filename = slash.map { String(path[path.index(after: $0)...]) } ?? path
        let head = Text(directory).foregroundStyle(Chrome.secondaryText)
        let tail = Text(filename).foregroundStyle(file.hasConflicts ? Chrome.warning : Chrome.primaryText)
        return Text("\(head)\(tail)")
    }

    /// The head's own report at the popover's reading size; a missing report says so.
    @ViewBuilder
    private func reportBody(_ head: HydraReportDigest.Head) -> some View {
        if !hasReport(head) {
            Text("No report.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
        } else if let headBlocks = blocks[head.name] {
            // Eager: a lazy stack reports an estimated height until its rows exist, and
            // the popover would resize a second time once they do.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(headBlocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
                        .equatable()
                }
            }
            .padding(.top, 2)
            .font(.ui(.callout))
            .environment(\.markdownPointSize, TypeScale.shared.content(12))
            .environment(\.markdownDimmed, false)
            .textSelection(.enabled)
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 8)
        }
    }
}

struct HydraReportFlagsRows: View {
    let notes: HydraReportNotes?
    var formatMissing = false

    init(notes: HydraReportNotes?, formatMissing: Bool = false) {
        self.notes = notes
        self.formatMissing = formatMissing
    }

    init(head: HydraHeadInfo) {
        notes = head.reportNotes
        formatMissing = head.jobID != nil && head.isFinished && head.reportNotes == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if formatMissing {
                Text("Report format not followed.")
                    .foregroundStyle(Chrome.warning)
            }
            if let value = notes?.unfinished { flag("Unfinished: %@", value: value) }
            if let value = notes?.deviations { flag("Deviations: %@", value: value) }
            if let value = notes?.uncertain { flag("Uncertain: %@", value: value) }
        }
        .font(.ui(.subheadline))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func flag(_ key: String, value: String) -> some View {
        Text(verbatim: String(format: Chrome.localized(key), value))
            .foregroundStyle(Chrome.warning)
    }

    static func withoutTrailingFlags(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.trimmed.hasPrefix("Deviations:") }),
              HydraReportNotes.parse(lines[start...].joined(separator: "\n")) != nil else { return text }
        return lines[..<start].joined(separator: "\n").trimmed
    }
}
