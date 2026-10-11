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
        guard source.contains(where: { $0 == "*" || $0 == "_" || $0 == "~" || $0 == "`" }) else { return source }
        let chars = Array(source)
        // The display suffix belongs before whitespace, where emphasis can close.
        var end = chars.count
        while end > 0, chars[end - 1].isWhitespace { end -= 1 }
        var partial: (marker: Character, missing: Int)?
        var partialTicks = 0
        var stack: [(marker: Character, length: Int, contentStart: Int)] = []
        var code: (ticks: Int, contentStart: Int)?
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", code == nil {
                index += 2
                continue
            }
            if char == "`" {
                let run = Self.run(of: char, in: chars, at: index)
                if let open = code {
                    if open.ticks == run {
                        code = nil
                    } else if run < open.ticks, index + run == end {
                        partialTicks = run
                    }
                } else {
                    code = (run, index + run)
                }
                index += run
                continue
            }
            guard code == nil, char == "*" || char == "_" || char == "~" else {
                index += 1
                continue
            }
            var run = Self.run(of: char, in: chars, at: index)
            let before: Character? = index > 0 ? chars[index - 1] : nil
            let after: Character? = index + run < chars.count ? chars[index + run] : nil
            if char == "~", run < 2, stack.last?.marker != char {
                index += run
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
               index + Self.run(of: char, in: chars, at: index) == end,
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
                    stack.append((char, length, index + Self.run(of: char, in: chars, at: index)))
                    run -= length
                }
            }
            index += Self.run(of: char, in: chars, at: index)
        }

        // Closers go before any trailing whitespace: a closer after a space closes nothing.
        func hasContent(from start: Int) -> Bool {
            start < end && chars[start..<end].contains { !$0.isWhitespace }
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
            var slashStart = end
            while slashStart > 0, chars[slashStart - 1] == "\\" { slashStart -= 1 }
            // A dangling escape must not swallow the first synthetic closer.
            if (end - slashStart) % 2 == 1 { closers = "\\" + closers }
        }
        return String(chars[..<end]) + closers + String(chars[end...])
    }

    private static func run(of char: Character, in chars: [Character], at index: Int) -> Int {
        var length = 0
        while index + length < chars.count, chars[index + length] == char { length += 1 }
        return length
    }
}
