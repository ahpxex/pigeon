import Sparkle
import SwiftUI

/// App self-update via Sparkle: checks the appcast feed, downloads and
/// installs updates in place (no App Store). Production only — the dev
/// build shares the bundle's feed/public key but must not self-update
/// (it would get a prod-identity update), so every entry point no-ops
/// for the dev variant.
@MainActor
enum Updater {
    private static let controller: SPUStandardUpdaterController? = {
        guard AppVariant.isProduction else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)
    }()

    /// Show the update-check UI now (menu item / settings button).
    static func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    static var canCheckForUpdates: Bool { controller != nil }

    /// Whether Sparkle checks the feed automatically (settings toggle).
    static var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
