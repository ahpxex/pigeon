import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            TerminalSettingsTab()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

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
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
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
            Section {
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
            } footer: {
                Text("Terminal colors live in the Terminal tab; accent affects Pigeon's own chrome (tab selection, highlights).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Terminal (kernel settings, GUI-managed)

private struct TerminalSettingsTab: View {
    @ObservedObject private var kernel = KernelSettings.shared

    var body: some View {
        Form {
            Section("Font") {
                TextField("Font family", text: $kernel.fontFamily, prompt: Text("System default"))
                    .onSubmit { kernel.scheduleApply() }
                HStack {
                    Slider(value: $kernel.fontSize, in: 8...32, step: 1) {
                        Text("Font size")
                    }
                    Text("\(Int(kernel.fontSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("Colors") {
                ColorPicker("Background", selection: $kernel.backgroundColor, supportsOpacity: false)
                ColorPicker("Foreground", selection: $kernel.foregroundColor, supportsOpacity: false)
                HStack {
                    Slider(value: $kernel.backgroundOpacity, in: 0.5...1.0) {
                        Text("Background opacity")
                    }
                    Text(String(format: "%.0f%%", kernel.backgroundOpacity * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("Cursor") {
                Picker("Cursor style", selection: $kernel.cursorStyle) {
                    ForEach(KernelSettings.CursorStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: kernel.fontFamily) { _ in kernel.scheduleApply() }
        .onChange(of: kernel.fontSize) { _ in kernel.scheduleApply() }
        .onChange(of: kernel.backgroundColor) { _ in kernel.scheduleApply() }
        .onChange(of: kernel.foregroundColor) { _ in kernel.scheduleApply() }
        .onChange(of: kernel.cursorStyle) { _ in kernel.scheduleApply() }
        .onChange(of: kernel.backgroundOpacity) { _ in kernel.scheduleApply() }
        .onAppear { kernel.loadFromConfig() }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    var body: some View {
        Form {
            Section("Config file") {
                LabeledContent("Path") {
                    Text("~/.config/pigeon/config")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open Config File") { openConfigFile() }
                    Button("Reload Config") { Ghostty.App.shared.reloadConfig() }
                }
                Text("Ghostty config format. Options set in the Terminal tab are written to a managed block at the end of this file and win over hand-written values; everything else is yours to edit. Independent from Ghostty.app's configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func openConfigFile() {
        let url = Ghostty.ConfigStore.configFileURL
        Ghostty.ConfigStore.prepare()
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: editor,
                configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
