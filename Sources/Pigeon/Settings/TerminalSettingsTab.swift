import SwiftUI

/// Kernel (ghostty) options managed through the GUI: font, theme,
/// cursor, opacity. Writes go to KernelSettings' managed config block.
struct TerminalSettingsTab: View {
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
