import SwiftUI

struct GeneralSettingsTab: View {
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
