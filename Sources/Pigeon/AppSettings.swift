import AppKit
import Combine
import SwiftUI

/// User preferences, persisted in UserDefaults. Terminal colors and fonts
/// stay in the ghostty config file; this covers Pigeon's own chrome.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum LabelStyle: String, CaseIterable, Identifiable {
        case folderName
        case fullPath
        var id: String { rawValue }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark
        var id: String { rawValue }
    }

    /// How tab labels render the working directory.
    @Published var labelStyle: LabelStyle {
        didSet { defaults.set(labelStyle.rawValue, forKey: "labelStyle") }
    }

    /// OpenMoji category new tabs draw random icons from; nil = all.
    @Published var iconCategory: String? {
        didSet { defaults.set(iconCategory, forKey: "iconCategory") }
    }

    /// Window appearance override.
    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    /// Accent color hex (e.g. "#4C8DFF"); nil = neutral, derived from the
    /// terminal foreground color.
    @Published var accentHex: String? {
        didSet { defaults.set(accentHex, forKey: "accentHex") }
    }

    var accentColor: Color? {
        accentHex.flatMap { Color(hex: $0) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        labelStyle = LabelStyle(rawValue: defaults.string(forKey: "labelStyle") ?? "") ?? .folderName
        iconCategory = defaults.string(forKey: "iconCategory")
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        accentHex = defaults.string(forKey: "accentHex")
    }

    /// Push the appearance override to AppKit. Ghostty configs that use
    /// light/dark theme variants follow this too.
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    /// "#RRGGBB" (leading # optional).
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}
