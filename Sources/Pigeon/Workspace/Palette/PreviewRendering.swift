import AppKit
import HighlightSwift
import MarkdownUI
import SwiftUI

/// Syntax highlighting for the file browser's preview pane, backed by
/// HighlightSwift (highlight.js in an actor-isolated JSContext). Output
/// carries colors only — HighlightSwift strips font attributes, so the
/// terminal font applied by the caller always wins.
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
    @MainActor
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
        let currentColors = await colors
        return await attributedString(
            for: text, language: language, colors: currentColors)
    }

    static func attributedString(
        for text: String, language: String?, colors: HighlightColors
    ) async -> NSAttributedString? {
        if text.isEmpty { return NSAttributedString(string: "") }
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

/// MarkdownUI's syntax-highlighter protocol is synchronous, while
/// HighlightSwift is async. Cache blocks progressively: the first render
/// returns plain text immediately, then publishes the highlighted result
/// when the actor finishes. Never block the main actor waiting for async
/// work — doing so deadlocks as soon as the async path needs main-actor
/// state and freezes the entire app.
@MainActor
final class MarkdownHighlightStore: ObservableObject {
    private struct Key: Hashable {
        let code: String
        let language: String?
        let dark: Bool
    }

    private var cached: [Key: NSAttributedString] = [:]
    private var pending: Set<Key> = []

    func text(for code: String, language: String?) -> Text {
        let dark = NSApp.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]) == .darkAqua
        let key = Key(code: code, language: language, dark: dark)
        if let value = cached[key] { return Self.text(from: value) }

        if !code.isEmpty, pending.insert(key).inserted {
            let colors: HighlightColors = dark ? .dark(.github) : .light(.github)
            Task { [weak self] in
                let highlighted = await SyntaxHighlighter.attributedString(
                    for: code, language: language, colors: colors)
                    ?? NSAttributedString(string: code)
                guard let self else { return }
                self.pending.remove(key)
                self.cached[key] = highlighted
                self.objectWillChange.send()
            }
        }

        return Text(code)
    }

    private static func text(from attributed: NSAttributedString) -> Text {
        var segments: [Text] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full) { attrs, range, _ in
            let body = attributed.attributedSubstring(from: range).string
            var segment = Text(body)
            if let color = attrs[.foregroundColor] as? NSColor {
                segment = segment.foregroundColor(Color(nsColor: color))
            }
            segments.append(segment)
        }
        guard var result = segments.popLast() else { return Text(attributed.string) }
        while let next = segments.popLast() {
            result = next + result
        }
        return result
    }
}

@MainActor
struct MarkdownCodeHighlighter: @preconcurrency CodeSyntaxHighlighter {
    let store: MarkdownHighlightStore

    func highlightCode(_ code: String, language: String?) -> Text {
        store.text(for: code, language: language)
    }
}
