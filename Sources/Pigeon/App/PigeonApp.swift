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
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Updater.checkForUpdates()
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(!Updater.canCheckForUpdates)
        }
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
        CommandGroup(after: .textEditing) {
            // cmd+K and cmd+` both open the command palette. With a
            // focused terminal surface, cmd+` never reaches the menu
            // (ghostty doesn't bind it, AppKit gives it to the view),
            // so the surface layer also posts the notification directly.
            Button("Command Palette") {
                NotificationCenter.default.post(name: .pigeonOpenPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            // cmd+J skips the palette and opens the file browser at the
            // selected tab's working directory directly.
            Button("Browse Files") {
                Task { @MainActor in
                    guard let tab = TabManager.forKeyWindow?.selectedTab else { return }
                    let url = tab.surfaceView.pwd.map(URL.init(fileURLWithPath:))
                        ?? FileManager.default.homeDirectoryForCurrentUser
                    NotificationCenter.default.post(
                        name: .pigeonOpenFileBrowser, object: nil,
                        userInfo: ["url": url])
                }
            }
            .keyboardShortcut("j", modifiers: .command)

            // cmd+shift+G opens the Git workspace for the selected tab's
            // repository.
            Button("Git") {
                NotificationCenter.default.post(name: .pigeonOpenGit, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            // cmd+L opens the agent message history for the selected tab.
            Button("Message History") {
                NotificationCenter.default.post(name: .pigeonOpenMessageHistory, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
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
