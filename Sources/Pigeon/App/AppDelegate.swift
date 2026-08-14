import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When exec'd directly (driver/testing) instead of via
        // LaunchServices, the process comes up as a background app and
        // never shows a window; force regular activation.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppSettings.shared.applyAppearance()
        AgentServer.shared.start()
        DriverServer.shared.startIfConfigured()
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
