import Foundation

/// Which install this process is: the released app (dev.ahpx.pigeon) or
/// the development build (dev.ahpx.pigeon.dev, "Pigeon Dev"). The two are
/// separate apps to macOS — separate UserDefaults domains, separate
/// LaunchServices identities — so they run side by side without touching
/// each other's state. The one place bundle identity alone can't isolate
/// is the on-disk config directory, which this type derives.
///
/// The bundle ID is the single source of truth (set per build
/// configuration in project.yml); nothing here depends on #if DEBUG, so
/// a Release build always behaves as production no matter how it's run.
enum AppVariant {
    static let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

    /// This variant's config directory: ~/.config/pigeon for production,
    /// ~/.config/pigeon-dev for the dev build.
    static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(isDev ? ".config/pigeon-dev" : ".config/pigeon")
    }

    /// The production config directory, regardless of variant. A fresh
    /// dev environment seeds itself from here (kernel config,
    /// credentials) so it starts out looking like the app you actually
    /// use, then diverges freely.
    static var productionConfigDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pigeon")
    }

    /// User-facing path string for settings UI, e.g. "~/.config/pigeon-dev".
    static var configDirectoryDisplayPath: String {
        isDev ? "~/.config/pigeon-dev" : "~/.config/pigeon"
    }
}
