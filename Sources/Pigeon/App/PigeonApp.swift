import SwiftUI
import GhosttyKit

@main
struct PigeonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var ghostty = Ghostty.App.shared

    var body: some Scene {
        WindowGroup("Pigeon", id: "main") {
            TerminalView()
                .environmentObject(ghostty)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            PigeonCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

private struct PigeonCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)

            // Fallback for when no surface has focus; with a focused
            // surface cmd+T is consumed by ghostty's own keybinding
            // and arrives via GHOSTTY_ACTION_NEW_TAB instead.
            Button("New Tab") {
                NotificationCenter.default.post(name: .pigeonNewTab, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") {
                Task { @MainActor in
                    guard let tab = TabManager.forKeyWindow?.selectedTab else { return }
                    tab.search.open(surfaceView: tab.surfaceView)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.15)) {
                        TabManager.forKeyWindow?.workspace.toggleSidebar()
                    }
                }
            }
            .keyboardShortcut("b", modifiers: .command)
        }
    }
}
