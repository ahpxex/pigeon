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
            AgentSettingsTab()
                .tabItem { Label("Agent", systemImage: "sparkles") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
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

    private let themeColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font family", selection: $kernel.fontFamily) {
                    Text("System default").tag("")
                    ForEach(KernelSettings.monospaceFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
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

            Section("Theme") {
                LazyVGrid(columns: themeColumns, spacing: 8) {
                    themeCard(nil)
                    ForEach(TerminalTheme.all) { theme in
                        themeCard(theme)
                    }
                }
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
        .onChange(of: kernel.themeID) { _ in kernel.scheduleApply() }
        .onChange(of: kernel.cursorStyle) { _ in kernel.scheduleApply() }
        .onChange(of: kernel.backgroundOpacity) { _ in kernel.scheduleApply() }
        .onAppear { kernel.loadFromConfig() }
    }

    /// Mini preview card: theme background with accent dots + name.
    @ViewBuilder
    private func themeCard(_ theme: TerminalTheme?) -> some View {
        let isSelected = kernel.themeID == theme?.id
        Button {
            kernel.themeID = theme?.id
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: theme?.background ?? "#808080") ?? .gray)
                    if let theme {
                        HStack(spacing: 3) {
                            ForEach([1, 2, 3, 4], id: \.self) { index in
                                Circle()
                                    .fill(Color(hex: "#" + theme.palette[index]) ?? .clear)
                                    .frame(width: 7, height: 7)
                            }
                        }
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 2 : 1))

                Text(theme?.name ?? "Config file")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Agent

private struct AgentSettingsTab: View {
    @ObservedObject private var agent = AgentSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Default provider", selection: $agent.defaultProviderID) {
                    ForEach(agent.providers) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
            }

            ForEach(agent.providers) { provider in
                ProviderSection(provider: provider)
            }

            Section {
                Button {
                    agent.addCustomProvider()
                } label: {
                    Label("Add Custom Provider", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSection: View {
    let provider: AgentProvider
    @ObservedObject private var agent = AgentSettings.shared

    @State private var apiKey: String = ""
    @State private var fetching = false
    @State private var fetchError: String? = nil

    var body: some View {
        Section(provider.isBuiltin ? provider.name : "Custom") {
            if !provider.isBuiltin {
                TextField("Name", text: binding(\.name))
                TextField("Base URL", text: binding(\.baseURL), prompt: Text("https://api.example.com/v1"))
                    .autocorrectionDisabled()
            }

            SecureField("API key", text: $apiKey, prompt: Text("Stored in Keychain"))
                .onSubmit { agent.setAPIKey(apiKey, for: provider) }
                .onChange(of: apiKey) { newValue in
                    agent.setAPIKey(newValue, for: provider)
                }

            HStack {
                if provider.models.isEmpty {
                    Text("No models — set the URL and key, then refresh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: binding(\.selectedModel)) {
                        ForEach(provider.models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                Spacer()

                Button {
                    refreshModels()
                } label: {
                    if fetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Fetch model list from the provider")
                .disabled(fetching)

                if !provider.isBuiltin {
                    Button(role: .destructive) {
                        agent.remove(provider)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove provider")
                }
            }

            if let fetchError {
                Text(fetchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { apiKey = agent.apiKey(for: provider) }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AgentProvider, T>) -> Binding<T> {
        Binding(
            get: {
                agent.providers.first { $0.id == provider.id }?[keyPath: keyPath]
                    ?? provider[keyPath: keyPath]
            },
            set: { newValue in
                guard var current = agent.providers.first(where: { $0.id == provider.id })
                else { return }
                current[keyPath: keyPath] = newValue
                agent.update(current)
            })
    }

    private func refreshModels() {
        fetching = true
        fetchError = nil
        Task { @MainActor in
            defer { fetching = false }
            guard var current = agent.providers.first(where: { $0.id == provider.id })
            else { return }
            do {
                let models = try await agent.fetchModels(for: current)
                current.models = models
                if !models.contains(current.selectedModel) {
                    current.selectedModel = models.first ?? ""
                }
                agent.update(current)
            } catch {
                fetchError = error.localizedDescription
            }
        }
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
