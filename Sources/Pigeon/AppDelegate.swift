import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When exec'd directly (driver/testing) instead of via
        // LaunchServices, the process comes up as a background app and
        // never shows a window; force regular activation.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppSettings.shared.applyAppearance()
        DriverServer.shared.startIfConfigured()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Ghostty.App.shared.shutdown()
    }
}
