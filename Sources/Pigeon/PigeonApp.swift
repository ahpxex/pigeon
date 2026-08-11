import SwiftUI
import GhosttyKit

@main
struct PigeonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var ghostty = Ghostty.App.shared

    var body: some Scene {
        Window("Pigeon", id: "main") {
            TerminalView()
                .environmentObject(ghostty)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Fallback for when no surface has focus; with a focused
                // surface cmd+T is consumed by ghostty's own keybinding
                // and arrives via GHOSTTY_ACTION_NEW_TAB instead.
                Button("New Tab") {
                    NotificationCenter.default.post(name: .pigeonNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
    }
}
