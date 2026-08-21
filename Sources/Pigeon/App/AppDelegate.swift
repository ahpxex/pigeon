import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When exec'd directly (driver/testing) instead of via
        // LaunchServices, the process comes up as a background app and
        // never shows a window; force regular activation.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppSettings.shared.applyAppearance()
        AgentServer.shared.start()
        TabTitleSummarizer.shared.start()
        DriverServer.shared.startIfConfigured()

        // Report appearance changes to libghostty (color-scheme OSC
        // queries) and let the theme auto-switch rewrite its palette.
        // Fires for both OS appearance flips and the in-app override.
        appearanceObserver = NSApp.observe(
            \.effectiveAppearance, options: [.new, .initial]
        ) { _, change in
            guard let appearance = change.newValue else { return }
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            Task { @MainActor in
                if let app = Ghostty.App.shared.app {
                    ghostty_app_set_color_scheme(
                        app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
                }
                KernelSettings.shared.systemAppearanceChanged()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The kernel knows whether any surface still runs a process
        // (confirm-close-surface config folded in). Window-close paths
        // confirm on their own and release their surfaces first, so this
        // only fires for cmd+Q / menu quit with live processes.
        guard Ghostty.App.shared.needsConfirmQuit else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Pigeon?"
        alert.informativeText =
            "A terminal still has a running process. Quitting will kill it."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
            ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Ghostty.App.shared.shutdown()
    }
}
