import SwiftUI

/// Built-in terminal color themes (classic editor palettes). Selecting one
/// writes background/foreground/palette into the managed config block.
struct TerminalTheme: Identifiable {
    let id: String
    let name: String
    let background: String
    let foreground: String
    /// 16 ANSI palette entries, hex without leading #.
    let palette: [String]

    var isDark: Bool {
        guard let color = Color(hex: background) else { return true }
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let luma = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return luma < 0.5
    }

    static let all: [TerminalTheme] = [
        TerminalTheme(
            id: "one-dark", name: "One Dark",
            background: "#282C34", foreground: "#ABB2BF",
            palette: [
                "282c34", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "abb2bf",
                "5c6370", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "ffffff",
            ]),
        TerminalTheme(
            id: "github-light", name: "GitHub Light",
            background: "#FFFFFF", foreground: "#24292F",
            palette: [
                "24292e", "d73a49", "22863a", "b08800", "0366d6", "5a32a3", "0598bc", "6a737d",
                "959da5", "cb2431", "28a745", "dbab09", "005cc5", "5a32a3", "3192aa", "d1d5da",
            ]),
        TerminalTheme(
            id: "github-dark", name: "GitHub Dark",
            background: "#0D1117", foreground: "#C9D1D9",
            palette: [
                "484f58", "ff7b72", "3fb950", "d29922", "58a6ff", "bc8cff", "39c5cf", "b1bac4",
                "6e7681", "ffa198", "56d364", "e3b341", "79c0ff", "d2a8ff", "56d4dd", "f0f6fc",
            ]),
        TerminalTheme(
            id: "solarized-light", name: "Solarized Light",
            background: "#FDF6E3", foreground: "#657B83",
            palette: [
                "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3",
            ]),
        TerminalTheme(
            id: "solarized-dark", name: "Solarized Dark",
            background: "#002B36", foreground: "#839496",
            palette: [
                "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3",
            ]),
        TerminalTheme(
            id: "dracula", name: "Dracula",
            background: "#282A36", foreground: "#F8F8F2",
            palette: [
                "21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
                "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff",
            ]),
        TerminalTheme(
            id: "nord", name: "Nord",
            background: "#2E3440", foreground: "#D8DEE9",
            palette: [
                "3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
                "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4",
            ]),
        TerminalTheme(
            id: "tokyo-night", name: "Tokyo Night",
            background: "#1A1B26", foreground: "#C0CAF5",
            palette: [
                "15161e", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
                "414868", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "c0caf5",
            ]),
        TerminalTheme(
            id: "monokai", name: "Monokai",
            background: "#272822", foreground: "#F8F8F2",
            palette: [
                "272822", "f92672", "a6e22e", "f4bf75", "66d9ef", "ae81ff", "a1efe4", "f8f8f2",
                "75715e", "f92672", "a6e22e", "f4bf75", "66d9ef", "ae81ff", "a1efe4", "f9f8f5",
            ]),
    ]

    static func theme(id: String?) -> TerminalTheme? {
        all.first { $0.id == id }
    }
}
