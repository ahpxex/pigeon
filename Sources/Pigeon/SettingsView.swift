import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let accentPresets: [(name: String, hex: String)] = [
        ("Blue", "#4C8DFF"),
        ("Purple", "#A78BFA"),
        ("Pink", "#F472B6"),
        ("Red", "#F87171"),
        ("Orange", "#FB923C"),
        ("Green", "#34D399"),
        ("Teal", "#2DD4BF"),
    ]

    var body: some View {
        Form {
            Section("Sidebar") {
                Picker("Tab label", selection: $settings.labelStyle) {
                    Text("Folder name").tag(AppSettings.LabelStyle.folderName)
                    Text("Full path").tag(AppSettings.LabelStyle.fullPath)
                }
                .pickerStyle(.radioGroup)

                Picker("New tab icons", selection: $settings.iconCategory) {
                    Text("All categories").tag(String?.none)
                    ForEach(TabIcon.categories) { category in
                        Text(category.name).tag(String?.some(category.name))
                    }
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("System").tag(AppSettings.Appearance.system)
                    Text("Light").tag(AppSettings.Appearance.light)
                    Text("Dark").tag(AppSettings.Appearance.dark)
                }
                .pickerStyle(.segmented)

                LabeledContent("Accent color") {
                    HStack(spacing: 6) {
                        accentSwatch(name: "Auto", hex: nil)
                        ForEach(Self.accentPresets, id: \.hex) { preset in
                            accentSwatch(name: preset.name, hex: preset.hex)
                        }
                    }
                }
            }

            Section("Terminal") {
                LabeledContent("Config file") {
                    Text("~/.config/pigeon/config")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open Config File") {
                        openConfigFile()
                    }
                    Button("Reload Config") {
                        Ghostty.App.shared.reloadConfig()
                    }
                }
                Text("Colors, fonts, and keybindings use Ghostty's config format, but this file belongs to Pigeon — it is independent from Ghostty.app's configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }

    private func openConfigFile() {
        let url = Ghostty.ConfigStore.configFileURL
        Ghostty.ConfigStore.prepare()
        // Extensionless file: route through the default plain-text editor.
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: editor,
                configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @ViewBuilder
    private func accentSwatch(name: String, hex: String?) -> some View {
        let isSelected = settings.accentHex == hex
        Button {
            settings.accentHex = hex
        } label: {
            ZStack {
                if let hex, let color = Color(hex: hex) {
                    Circle().fill(color)
                } else {
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 1)
                        .background(Circle().fill(.quaternary))
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hex == nil ? Color.primary : Color.white)
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(name)
    }
}
