import AppKit
import Highlightr
import MarkdownUI
import SwiftUI

/// Syntax highlighting for the file browser's preview pane, backed by
/// Highlightr (highlight.js). One shared instance: the JS context is
/// expensive to boot, and highlights are fast enough to serialize.
@MainActor
enum SyntaxHighlighter {
    private static let shared: Highlightr? = {
        guard let highlightr = Highlightr() else { return nil }
        highlightr.setTheme(to: "pojoaque")
        return highlightr
    }()

    /// highlight.js language for a file, best-effort by extension.
    static func language(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "m", "mm": return "objectivec"
        case "h", "c": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "js", "mjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "ini"
        case "xml", "plist", "xib", "storyboard", "html", "htm": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "sh", "bash", "zsh": return "bash"
        case "sql": return "sql"
        case "md", "markdown": return "markdown"
        case "java": return "java"
        case "kt": return "kotlin"
        case "zig": return "zig"
        default: return nil
        }
    }

    /// Highlight whole text as one attributed string. Highlightr calls
    /// must stay on main (JavaScriptCore hop); highlights are fast and
    /// the preview is one file at a time, so that's fine.
    static func attributedString(for text: String, language: String) -> NSAttributedString? {
        shared?.highlight(text, as: language, fastRender: true)
    }

    /// Highlight per line (lazily rendered rows keep huge files smooth).
    /// highlight.js state (strings/comments) can span lines, so per-line
    /// highlighting is approximate — acceptable for a preview pane.
    static func attributedLines(for text: String, fileURL: URL) -> [NSAttributedString]? {
        guard let language = language(for: fileURL) else { return nil }
        return text.components(separatedBy: "\n").map {
            attributedString(for: $0, language: language) ?? NSAttributedString(string: $0)
        }
    }
}

/// Bridges Highlightr into MarkdownUI's code-block highlighter: each
/// colored run becomes a Text segment, concatenated into one Text.
@MainActor
struct HighlightrCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        let ns = (language.flatMap {
                    SyntaxHighlighter.attributedString(for: code, language: $0)
                })
            ?? SyntaxHighlighter.attributedString(for: code, language: "plaintext")
            ?? NSAttributedString(string: code)

        var segments: [Text] = []
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let body = ns.attributedSubstring(from: range).string
            var segment = Text(body)
            if let color = attrs[.foregroundColor] as? NSColor {
                segment = segment.foregroundColor(Color(nsColor: color))
            }
            segments.append(segment)
        }
        guard var result = segments.popLast() else { return Text(code) }
        while let next = segments.popLast() {
            result = next + result
        }
        return result
    }
}
