import AppKit
import HighlightSwift
import MarkdownUI
import SwiftUI

/// Syntax highlighting for the file browser's preview pane, backed by
/// HighlightSwift (highlight.js in an actor-isolated JSContext). Output
/// carries colors only — HighlightSwift strips font attributes, so the
/// terminal font applied by the caller always wins.
@MainActor
enum SyntaxHighlighter {
    private static let highlight = Highlight()

    static func language(for url: URL) -> String? {
        language(forExtension: url.pathExtension)
    }

    static func language(forExtension ext: String) -> String? {
        switch ext.lowercased() {
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

    /// GitHub theme matching the system appearance (the markdown preview
    /// uses the light gitHub theme on the light pane).
    private static var colors: HighlightColors {
        let dark = NSApp.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .dark(.github) : .light(.github)
    }

    /// Whole-text highlight as one attributed string. Call from any
    /// async context; runs off-main inside the HLJS actor.
    static func attributedString(
        for text: String, language: String?
    ) async -> NSAttributedString? {
        do {
            let attributed: AttributedString
            if let language {
                attributed = try await highlight.attributedText(
                    text, language: language, colors: colors)
            } else {
                attributed = try await highlight.attributedText(
                    text, colors: colors)
            }
            return try NSAttributedString(
                attributed, including: \.appKit)
        } catch {
            return nil
        }
    }

    /// Whole-text highlight split into per-line attributed strings
    /// (lazily rendered rows keep huge files smooth; splitting after
    /// highlighting keeps multi-line tokens — comments, strings —
    /// correctly colored, unlike per-line highlighting).
    static func attributedLines(
        for text: String, fileURL: URL
    ) async -> [NSAttributedString]? {
        guard language(for: fileURL) != nil else { return nil }
        guard let whole = await attributedString(
            for: text, language: language(for: fileURL))
        else { return nil }
        return splitLines(whole)
    }

    /// Split an attributed string on newlines, carrying each character's
    /// attributes into its line: attribute runs are split at \n manually
    /// and accumulated into the current line across runs.
    static func splitLines(_ source: NSAttributedString) -> [NSAttributedString] {
        var lines: [NSAttributedString] = []
        var current = NSMutableAttributedString()
        let full = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: full) { attrs, partRange, _ in
            let part = source.attributedSubstring(from: partRange).string as NSString
            var segmentStart = 0
            for i in 0..<part.length where part.character(at: i) == 0x0A {
                current.append(NSAttributedString(
                    string: part.substring(with: NSRange(location: segmentStart, length: i - segmentStart)),
                    attributes: attrs))
                lines.append(current)
                current = NSMutableAttributedString()
                segmentStart = i + 1
            }
            if segmentStart < part.length {
                current.append(NSAttributedString(
                    string: part.substring(from: segmentStart),
                    attributes: attrs))
            }
        }
        lines.append(current)
        return lines
    }
}

/// Bridges HighlightSwift into MarkdownUI's (synchronous) code-block
/// highlighter: blocks the calling thread on the HLJS actor. Markdown
/// code blocks are small, and the actor never executes on main, so the
/// brief block is safe.
@MainActor
struct MarkdownCodeHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        guard let ns = blockingHighlight(code, language: language) else {
            return Text(code)
        }
        var segments: [Text] = []
        let full = NSRange(location: 0, length: ns.length)
        ns.enumerateAttributes(in: full) { attrs, range, _ in
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

    private func blockingHighlight(
        _ code: String, language: String?
    ) -> NSAttributedString? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: NSAttributedString?
        Task.detached(priority: .userInitiated) {
            result = await SyntaxHighlighter.attributedString(
                for: code, language: language)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
