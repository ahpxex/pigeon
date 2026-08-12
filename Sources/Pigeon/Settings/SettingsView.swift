import SwiftUI

/// The Settings scene shell: one toolbar tab per concern.
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
