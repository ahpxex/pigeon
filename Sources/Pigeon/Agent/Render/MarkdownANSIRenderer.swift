import Foundation

/// Streaming Markdown → ANSI renderer for agent output going into a pty.
///
/// Line-buffered: deltas accumulate until a full line is available, then
/// the whole line is rendered at once. Buffering by line is what makes
/// streaming safe — inline tokens (`**`, backticks, `[text](url)`) can be
/// split across arbitrary chunk boundaries, but never across lines. The
/// latency cost is one line, invisible for the short answers Pigeon's
/// agent produces.
///
/// Styling maps onto the terminal's own 16-color palette (never RGB), so
/// rendered output follows the active theme:
///   heading      bold (level 1 also underlined)
///   **bold**     SGR 1
///   *italic*     SGR 3
///   `code`       cyan, both inline and fenced blocks
///   ~~strike~~   SGR 9
///   [t](url)     OSC 8 hyperlink, underlined
///   - bullet     • (dimmed marker)
///   > quote      dimmed ▌ bar prefix
///   ---          dimmed ─ rule
/// Fence lines themselves (``` markers) are swallowed; their content keeps
/// its exact text (copy-safe), only colored.
final class MarkdownANSIRenderer {
    private var pending = ""
    private var inCodeFence = false
    /// Blank lines are held back and only emitted when real content
    /// follows: paragraph spacing inside the answer survives, but
    /// trailing blank lines vanish — so the shell prompt reconnects
    /// directly under the last line, like native command output.
    private var heldBlankLines = 0

    /// Consume a streamed delta; returns whatever became renderable
    /// (complete lines only — possibly empty).
    func feed(_ delta: String) -> String {
        pending += delta
        var out = ""
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending = String(pending[pending.index(after: newline)...])
            guard let rendered = render(line: line) else { continue }
            if rendered.allSatisfy({ $0 == " " || $0 == "\t" }) {
                heldBlankLines += 1
                continue
            }
            out += String(repeating: "\n", count: heldBlankLines)
            heldBlankLines = 0
            out += rendered + "\n"
        }
        return out
    }

    /// Render any buffered partial line. Call before interleaving other
    /// output (tool status lines) and once at end of stream. The result
    /// carries no trailing newline; held blank lines are dropped.
    func flush() -> String {
        heldBlankLines = 0
        guard !pending.isEmpty else { return "" }
        let line = pending
        pending = ""
        return render(line: line) ?? ""
    }

    // MARK: Block-level rendering

    private enum SGR {
        static let reset = "\u{1B}[0m"
        static let bold = "\u{1B}[1m"
        static let boldOff = "\u{1B}[22m"
        static let dim = "\u{1B}[2m"
        static let dimOff = "\u{1B}[22m"
        static let italic = "\u{1B}[3m"
        static let italicOff = "\u{1B}[23m"
        static let underline = "\u{1B}[4m"
        static let underlineOff = "\u{1B}[24m"
        static let strike = "\u{1B}[9m"
        static let strikeOff = "\u{1B}[29m"
        static let cyan = "\u{1B}[36m"
        static let fgOff = "\u{1B}[39m"
    }

    /// Renders one complete line; nil means the line is structural markup
    /// (a fence marker) and produces no output at all.
    private func render(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inCodeFence.toggle()
            return nil
        }
        if inCodeFence {
            return SGR.cyan + line + SGR.fgOff
        }

        // Horizontal rule: a line of only -, * or _ (3+).
        if trimmed.count >= 3,
           let mark = trimmed.first, "-*_".contains(mark),
           trimmed.allSatisfy({ $0 == mark }) {
            return SGR.dim + String(repeating: "─", count: 40) + SGR.dimOff
        }

        // Heading: bold, level 1 underlined too.
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" })
            let level = hashes.count
            if level <= 6 {
                let rest = trimmed.dropFirst(level)
                if rest.first == " " {
                    var content = renderInline(String(rest.dropFirst()))
                    // Nested bold would emit SGR 22 and kill the heading's
                    // bold early; re-assert instead of resetting.
                    content = content.replacingOccurrences(of: SGR.boldOff, with: SGR.bold)
                    let deco = level == 1 ? SGR.underline : ""
                    let decoOff = level == 1 ? SGR.underlineOff : ""
                    return SGR.bold + deco + content + decoOff + SGR.boldOff
                }
            }
        }

        // Blockquote: dimmed bar, content rendered normally.
        if trimmed.hasPrefix(">") {
            var content = trimmed.dropFirst()
            if content.first == " " { content = content.dropFirst() }
            return SGR.dim + "▌ " + SGR.dimOff + renderInline(String(content))
        }

        // Unordered list: -, * or + followed by a space → • bullet,
        // preserving indentation (nested lists).
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let afterIndent = line.dropFirst(indent.count)
        if let mark = afterIndent.first, "-*+".contains(mark),
           afterIndent.dropFirst().first == " " {
            let content = afterIndent.dropFirst(2)
            return indent + SGR.dim + "•" + SGR.dimOff + " " + renderInline(String(content))
        }

        // Ordered list: keep the number, just render the content.
        if let dot = afterIndent.firstIndex(where: { $0 == "." || $0 == ")" }),
           afterIndent[..<dot].count <= 3, !afterIndent[..<dot].isEmpty,
           afterIndent[..<dot].allSatisfy(\.isNumber),
           afterIndent[afterIndent.index(after: dot)...].first == " " {
            let content = afterIndent[afterIndent.index(dot, offsetBy: 2)...]
            let number = afterIndent[..<afterIndent.index(after: dot)]
            return indent + number + " " + renderInline(String(content))
        }

        return renderInline(line)
    }

    // MARK: Inline rendering

    /// Renders inline markdown spans within one line. Recursive for
    /// nesting (bold containing code, etc.). Deliberately conservative:
    /// a marker without a matching closer on the same line stays literal,
    /// and `_` inside words (snake_case) never triggers emphasis.
    private func renderInline(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0

        while i < chars.count {
            let c = chars[i]

            // Backslash escape of markdown metacharacters.
            if c == "\\", i + 1 < chars.count, "\\`*_~[".contains(chars[i + 1]) {
                out.append(chars[i + 1])
                i += 2
                continue
            }

            // Inline code: protects its content from all other parsing.
            if c == "`" {
                if let close = find(chars, "`", from: i + 1) {
                    out += SGR.cyan + String(chars[(i + 1)..<close]) + SGR.fgOff
                    i = close + 1
                    continue
                }
            }

            // Link: [text](url) → OSC 8 hyperlink.
            if c == "[" {
                if let closeBracket = find(chars, "]", from: i + 1),
                   closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
                   let closeParen = find(chars, ")", from: closeBracket + 2) {
                    let label = String(chars[(i + 1)..<closeBracket])
                    let url = String(chars[(closeBracket + 2)..<closeParen])
                    out += "\u{1B}]8;;\(url)\u{1B}\\"
                        + SGR.underline + renderInline(label) + SGR.underlineOff
                        + "\u{1B}]8;;\u{1B}\\"
                    i = closeParen + 1
                    continue
                }
            }

            // Emphasis: ** __ * _ and strikethrough ~~.
            if c == "*" || c == "_" || c == "~" {
                let double = i + 1 < chars.count && chars[i + 1] == c
                if c == "~" && !double {
                    out.append(c)
                    i += 1
                    continue
                }
                let marker = double ? String([c, c]) : String(c)
                if let close = findEmphasisClose(chars, marker: marker, from: i + double.intValue + 1),
                   emphasisAllowed(chars, open: i, close: close, marker: marker) {
                    let inner = renderInline(String(chars[(i + marker.count)..<close]))
                    switch marker {
                    case "**", "__": out += SGR.bold + inner + SGR.boldOff
                    case "~~": out += SGR.strike + inner + SGR.strikeOff
                    default: out += SGR.italic + inner + SGR.italicOff
                    }
                    i = close + marker.count
                    continue
                }
            }

            out.append(c)
            i += 1
        }
        return out
    }

    private func find(_ chars: [Character], _ target: Character, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    /// Closing position of an emphasis marker, skipping inline-code spans
    /// so `a *b `c*` d*` doesn't close inside code.
    private func findEmphasisClose(_ chars: [Character], marker: String, from: Int) -> Int? {
        let m = Array(marker)
        var i = from
        while i < chars.count {
            if chars[i] == "`" {
                guard let close = find(chars, "`", from: i + 1) else { break }
                i = close + 1
                continue
            }
            if chars[i] == m[0], i + m.count <= chars.count,
               Array(chars[i..<(i + m.count)]) == m {
                // For single markers, don't match the first half of a double.
                if m.count == 1, i + 1 < chars.count, chars[i + 1] == m[0] {
                    i += 2
                    continue
                }
                return i
            }
            i += 1
        }
        return nil
    }

    /// CommonMark-flavored sanity: content must not start/end with a
    /// space, and `_` must not sit inside a word (snake_case stays
    /// literal). `*` is allowed intra-word so globs like *.txt only match
    /// when a real closer exists.
    private func emphasisAllowed(
        _ chars: [Character], open: Int, close: Int, marker: String
    ) -> Bool {
        let contentStart = open + marker.count
        guard contentStart < close else { return false }
        if chars[contentStart].isWhitespace || chars[close - 1].isWhitespace { return false }
        if marker.first == "_" {
            let before = open > 0 ? chars[open - 1] : " "
            let afterIndex = close + marker.count
            let after = afterIndex < chars.count ? chars[afterIndex] : " "
            if before.isLetter || before.isNumber { return false }
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }
}

private extension Bool {
    var intValue: Int { self ? 1 : 0 }
}
