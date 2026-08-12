import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// GUI-managed subset of the kernel (ghostty) configuration.
///
/// Values are persisted as a marked block appended to
/// ~/.config/pigeon/config. The block sits at the end of the file, so its
/// values win over anything hand-written above it (ghostty semantics:
/// last value wins). Everything outside the block is left untouched for
/// hand editing.
@MainActor
final class KernelSettings: ObservableObject {
    static let shared = KernelSettings()

    enum CursorStyle: String, CaseIterable, Identifiable {
        case block
        case bar
        case underline
        case blockHollow = "block_hollow"
        var id: String { rawValue }

        var label: String {
            switch self {
            case .block: return "Block"
            case .bar: return "Bar"
            case .underline: return "Underline"
            case .blockHollow: return "Hollow Block"
            }
        }
    }

    /// Empty string = system default font.
    @Published var fontFamily: String = ""
    @Published var fontSize: Double = 13
    /// TerminalTheme id; nil = whatever the config file says.
    @Published var themeID: String? {
        didSet { UserDefaults.standard.set(themeID, forKey: "kernelThemeID") }
    }
    @Published var cursorStyle: CursorStyle = .block
    @Published var backgroundOpacity: Double = 1.0

    /// Monospace font families installed on this machine.
    static let monospaceFamilies: [String] = {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        var families: Set<String> = []
        for name in names {
            if let family = NSFont(name: name, size: 12)?.familyName,
               !family.hasPrefix(".") {
                families.insert(family)
            }
        }
        return families.sorted()
    }()

    private static let beginMarker = "# >>> pigeon-settings — managed by the Settings window; edits inside this block will be overwritten"
    private static let endMarker = "# <<< pigeon-settings"

    private var applyTask: Task<Void, Never>?

    private init() {
        themeID = UserDefaults.standard.string(forKey: "kernelThemeID")
        loadFromConfig()
    }

    /// Read current effective values from the loaded ghostty config.
    func loadFromConfig() {
        guard let config = Ghostty.App.shared.config else { return }

        var family: UnsafePointer<CChar>? = nil
        if key("font-family", into: &family, config: config), let family {
            fontFamily = String(cString: family)
        }

        var size: Float = 13
        if key("font-size", into: &size, config: config) {
            fontSize = Double(size)
        }

        var style: UnsafePointer<CChar>? = nil
        if key("cursor-style", into: &style, config: config), let style,
           let parsed = CursorStyle(rawValue: String(cString: style)) {
            cursorStyle = parsed
        }

        var opacity: Double = 1
        if key("background-opacity", into: &opacity, config: config) {
            backgroundOpacity = opacity
        }
    }

    private func key<T>(_ name: String, into value: inout T, config: ghostty_config_t) -> Bool {
        withUnsafeMutablePointer(to: &value) { ptr in
            ghostty_config_get(config, ptr, name, UInt(name.count))
        }
    }

    /// Debounced write + live reload (sliders fire continuously).
    func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self.apply()
        }
    }

    /// Rewrite the managed block and push the config to live surfaces.
    func apply() {
        var lines = ["", Self.beginMarker]
        if !fontFamily.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("font-family = \(fontFamily)")
        }
        lines.append("font-size = \(formatNumber(fontSize))")
        lines.append("cursor-style = \(cursorStyle.rawValue)")
        lines.append("background-opacity = \(formatNumber(backgroundOpacity))")
        if let theme = TerminalTheme.theme(id: themeID) {
            lines.append("background = \(theme.background)")
            lines.append("foreground = \(theme.foreground)")
            for (index, color) in theme.palette.enumerated() {
                lines.append("palette = \(index)=#\(color)")
            }
        }
        lines.append(Self.endMarker)

        let url = Ghostty.ConfigStore.configFileURL
        Ghostty.ConfigStore.prepare()
        var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        contents = Self.strippingManagedBlock(from: contents)
        contents += lines.joined(separator: "\n") + "\n"
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Ghostty.logger.error("failed to write config: \(error)")
            return
        }
        Ghostty.App.shared.reloadConfig()
    }

    static func strippingManagedBlock(from contents: String) -> String {
        var result: [String] = []
        var inBlock = false
        for line in contents.components(separatedBy: "\n") {
            if line == beginMarker { inBlock = true; continue }
            if line == endMarker { inBlock = false; continue }
            if !inBlock { result.append(line) }
        }
        // Trim trailing blank lines so repeated writes stay stable.
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n") + (result.isEmpty ? "" : "\n")
    }

    private func formatNumber(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}
