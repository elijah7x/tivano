import Foundation

/// The message as plain text for the clipboard: one walk over the app's own blocks,
/// no styling. Headings as their text, code blocks verbatim, links as `title (url)`,
/// the delegation block left out. Used by the row menu's Copy message (see
/// `AssistantMessageRow.messageActions`). The file keeps the name of the selectable text
/// view it used to hold, which left with the whole-reply drag mode; this enum is all that
/// stayed.
enum MessageText {
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var first = true
        for block in MarkdownParser.parse(markdown) {
            if !first { lines.append("") }
            first = false
            append(block, to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func append(_ block: MarkdownBlock, to lines: inout [String]) {
        switch block {
        case .heading(_, let text):
            lines.append(inline(text))
        case .paragraph(let text):
            lines.append(inline(text))
        case .code(let language, let code):
            guard language?.lowercased() != "hydra", !code.isEmpty else { return }
            lines.append(code)
        case .list(let ordered, let start, let items):
            for (index, item) in items.enumerated() {
                let marker: String
                if let checked = item.checked {
                    marker = checked ? "☑ " : "☐ "
                } else if ordered {
                    marker = "\(start + index).  "
                } else {
                    marker = "•  "
                }
                if !item.text.isEmpty { lines.append(marker + inline(item.text)) }
                for child in item.children { append(child, to: &lines) }
            }
        case .quote(let inner):
            for child in inner { append(child, to: &lines) }
        case .table(let header, let rows):
            lines.append(header.joined(separator: "  "))
            for row in rows { lines.append(row.joined(separator: "  ")) }
        case .image(let alt, let source):
            lines.append(alt.isEmpty ? source : alt)
        case .rule:
            break
        }
    }

    /// Links as `title (url)` when the title differs, the bare URL otherwise.
    private static func inline(_ source: String) -> String {
        var text = source.replacing(#/!\[([^\[\]]*)\]\(\S+?\)/#) { $0.output.1 }
        text = text.replacing(#/\[([^\[\]]+)\]\((\S+?)(?:\s+"[^"]*")?\)/#) { match in
            match.output.1 == match.output.2
                ? String(match.output.2)
                : "\(match.output.1) (\(match.output.2))"
        }
        text = text.replacing(#/<((?:https?|mailto):[^<>\s]+)>/#) { $0.output.1 }
        return text
    }
}
