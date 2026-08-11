import SwiftUI
import GhosttyKit

@main
struct PigeonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var ghostty = Ghostty.App.shared

    var body: some Scene {
        WindowGroup("Pigeon") {
            TerminalView()
                .environmentObject(ghostty)
        }
        .commands {
            // Terminal apps want cmd+key combos to reach the surface, not
            // default SwiftUI menu items like "New" that we don't support yet.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
