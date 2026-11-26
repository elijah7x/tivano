import Foundation

/// Closes the inline markup a paragraph still streaming has opened but not yet closed, for
/// display only. Without it `**bold` shows its asterisks until the closing pair arrives,
/// then they vanish and the run restyles: the characters before the cursor change, the
/// line reflows and the veil dissolves the whole tail in again. With synthetic closers the
/// run is styled from its first word, and each flush only ever adds characters after the
/// ones already shown.
///
/// - Emphasis: `**`, `__`, `*`, `_` and `~~` are paired on a stack, innermost first, and
///   a half-streamed closer (`**a*`) is completed. An opener needs a word after it and no
///   letter or digit before it, so `2*3` and `snake_case` stay literal.
/// - Inline code: an open backtick run gets its matching run.
/// - An opener with nothing but whitespace after it is left alone until text follows.
///
/// Approximate on purpose: anything it misjudges mid-stream is set right by the next flush,
/// and once the reply finishes the paragraph is parsed as written, so a marker that truly
/// never closes settles honestly, once.
enum StreamMend {
    static func mended(_ source: String) -> String {
        guard source.utf8.contains(where: { $0 == 42 || $0 == 95 || $0 == 126 || $0 == 96 }) else { return source }
        // The display suffix belongs before whitespace, where emphasis can close.
        var end = source.endIndex
        while end > source.startIndex {
            let prev = source.index(before: end)
            guard source[prev].isWhitespace else { break }
            end = prev
        }
        var partial: (marker: Character, missing: Int)?
        var partialTicks = 0
        var stack: [(marker: Character, length: Int, contentStart: String.Index)] = []
        var code: (ticks: Int, contentStart: String.Index)?
        var index = source.startIndex
        while index < source.endIndex {
            let char = source[index]
            if char == "\\", code == nil {
                let next = source.index(after: index)
                index = next < source.endIndex ? source.index(after: next) : source.endIndex
                continue
            }
            if char == "`" {
                let (run, runEnd) = Self.run(of: char, in: source, at: index)
                if let open = code {
                    if open.ticks == run {
                        code = nil
                    } else if run < open.ticks, runEnd == end {
                        partialTicks = run
                    }
                } else {
                    code = (run, runEnd)
                }
                index = runEnd
                continue
            }
            guard code == nil, char == "*" || char == "_" || char == "~" else {
                index = source.index(after: index)
                continue
            }
            let (totalRun, runEnd) = Self.run(of: char, in: source, at: index)
            var run = totalRun
            let before: Character? = index > source.startIndex ? source[source.index(before: index)] : nil
            let after: Character? = runEnd < source.endIndex ? source[runEnd] : nil
            if char == "~", run < 2, stack.last?.marker != char {
                index = runEnd
                continue
            }
            if let before, !before.isWhitespace {
                while run > 0, let top = stack.last, top.marker == char, run >= top.length {
                    stack.removeLast()
                    run -= top.length
                }
            }
            // Only an unescaped terminal run can be a half-written closer. Account
            // for markers already consumed by an inner span (e.g. `***a**`).
            if run > 0, let top = stack.last, top.marker == char, run < top.length,
               runEnd == end,
               let before, !before.isWhitespace {
                partial = (char, top.length - run)
                stack.removeLast()
                run = 0
            }
            let opens = after.map { !$0.isWhitespace } ?? false
                && !(before.map { $0.isLetter || $0.isNumber } ?? false)
            if run > 0, opens {
                while run > 0 {
                    if char == "~", run < 2 { break }
                    let length = char == "~" ? 2 : min(run, 2)
                    stack.append((char, length, runEnd))
                    run -= length
                }
            }
            index = runEnd
        }

        // Closers go before any trailing whitespace: a closer after a space closes nothing.
        func hasContent(from start: String.Index) -> Bool {
            start < end && source[start..<end].contains { !$0.isWhitespace }
        }
        var closers = ""
        if let open = code {
            guard hasContent(from: open.contentStart) else { return source }
            closers += String(repeating: "`", count: open.ticks - partialTicks)
        }
        if let partial {
            closers += String(repeating: String(partial.marker), count: partial.missing)
        }
        for open in stack.reversed() where hasContent(from: open.contentStart) {
            closers += String(repeating: open.marker, count: open.length)
        }
        guard !closers.isEmpty else { return source }
        if code == nil {
            var slashCount = 0
            var cursor = end
            while cursor > source.startIndex {
                let prev = source.index(before: cursor)
                guard source[prev] == "\\" else { break }
                slashCount += 1
                cursor = prev
            }
            // A dangling escape must not swallow the first synthetic closer.
            if slashCount % 2 == 1 { closers = "\\" + closers }
        }
        var result = String()
        result.reserveCapacity(source.utf8.count + closers.utf8.count)
        result.append(contentsOf: source[..<end])
        result.append(closers)
        result.append(contentsOf: source[end...])
        return result
    }

    private static func run(of char: Character, in source: String, at index: String.Index) -> (length: Int, end: String.Index) {
        var length = 0
        var cursor = index
        while cursor < source.endIndex, source[cursor] == char {
            length += 1
            cursor = source.index(after: cursor)
        }
        return (length, cursor)
    }
}
