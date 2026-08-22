import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var autoChecks = Updater.automaticallyChecks

    var body: some View {
        Form {
            Section("Sidebar") {
                Picker("Tab label", selection: $settings.labelStyle) {
                    Text("Folder name").tag(AppSettings.LabelStyle.folderName)
                    Text("Full path").tag(AppSettings.LabelStyle.fullPath)
                }
                .pickerStyle(.radioGroup)

                Toggle("Group tabs by folder", isOn: $settings.autoGroupByFolder)
                Text("cd into a folder and the tab joins (or creates) that folder's group; cd home leaves it. Manual grouping holds until the next directory change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("AI tab titles", isOn: $settings.aiTabTitles)
                Text("Names each tab once — after it has produced enough output — using the AI provider from the Agent tab. Right-click a tab and choose Summarize Title to refresh anytime; a manual rename always wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("New tab icons", selection: $settings.iconCategory) {
                    Text("All categories").tag(String?.none)
                    ForEach(TabIcon.categories) { category in
                        Text(category.name).tag(String?.some(category.name))
                    }
                }
            }

            if Updater.canCheckForUpdates {
                Section("Updates") {
                    HStack {
                        Button("Check for Updates…") {
                            Updater.checkForUpdates()
                        }
                        Spacer()
                    }
                    Toggle("Check automatically", isOn: $autoChecks)
                        .onChange(of: autoChecks) { value in
                            Updater.automaticallyChecks = value
                        }
                    Text("Updates install in place from the appcast feed — no App Store. The dev build doesn’t self-update; pull and rebuild it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
