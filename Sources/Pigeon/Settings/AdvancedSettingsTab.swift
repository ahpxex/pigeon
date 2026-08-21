import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsTab: View {
    var body: some View {
        Form {
            Section("Config file") {
                LabeledContent("Path") {
                    Text("\(AppVariant.configDirectoryDisplayPath)/config")
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
        // Extensionless file: route through the default plain-text editor.
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: editor,
                configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
