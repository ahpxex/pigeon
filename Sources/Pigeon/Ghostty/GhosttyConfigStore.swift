import Foundation
import GhosttyKit

extension Ghostty {
    /// Pigeon's own terminal (kernel) configuration, fully isolated from
    /// Ghostty.app's. Same file format, different file.
    ///
    /// libghostty has no "load this file" C API: ghostty_config_load_default_files
    /// hardcodes $XDG_CONFIG_HOME/ghostty/config plus (on macOS)
    /// ~/Library/Application Support/com.mitchellh.ghostty/config, both rooted
    /// in environment-derived paths. So we point HOME and XDG_CONFIG_HOME at a
    /// private root for the duration of the load, then restore them. Inside
    /// that root, .config/ghostty/config is a symlink to the user-facing file.
    enum ConfigStore {
        /// The file users edit.
        static var configFileURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/pigeon/config")
        }

        /// Private root that stands in for HOME while loading.
        static var privateHomeURL: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dev.ahpx.pigeon/config-home")
        }

        /// Ghostty.app's config (XDG first, then App Support), used once
        /// as a starting point.
        private static var ghosttyConfigURL: URL? {
            let fm = FileManager.default
            let candidates = [
                fm.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/ghostty/config"),
                fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.mitchellh.ghostty/config"),
            ]
            return candidates.first { fm.fileExists(atPath: $0.path) }
        }

        /// Create the config file (first run) and the private-home symlink.
        static func prepare() {
            let fm = FileManager.default

            if !fm.fileExists(atPath: configFileURL.path) {
                try? fm.createDirectory(
                    at: configFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                var contents = """
                # Pigeon terminal configuration.
                # Same format as Ghostty (https://ghostty.org/docs/config),
                # but this file belongs to Pigeon only — Ghostty.app never
                # reads it, and Pigeon never reads Ghostty's config.

                """
                if let source = ghosttyConfigURL,
                   let imported = try? String(contentsOf: source, encoding: .utf8) {
                    contents += """

                    # Imported from \(source.path) on first launch:
                    \(imported)
                    """
                }
                try? contents.write(to: configFileURL, atomically: true, encoding: .utf8)
            }

            // (Re)build the private home: .config/ghostty/config -> our file.
            let linkDir = privateHomeURL.appendingPathComponent(".config/ghostty")
            let link = linkDir.appendingPathComponent("config")
            try? fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != configFileURL.path {
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(
                    atPath: link.path, withDestinationPath: configFileURL.path)
            }
        }

        /// Build a finalized ghostty config from Pigeon's file.
        /// Must be called on the main thread (mutates process env briefly).
        static func load() -> ghostty_config_t? {
            prepare()
            guard let config = ghostty_config_new() else { return nil }

            let originalHome = getenv("HOME").map { String(cString: $0) }
            let originalXdg = getenv("XDG_CONFIG_HOME").map { String(cString: $0) }
            setenv("HOME", privateHomeURL.path, 1)
            setenv("XDG_CONFIG_HOME", privateHomeURL.appendingPathComponent(".config").path, 1)

            ghostty_config_load_default_files(config)
            ghostty_config_load_recursive_files(config)

            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
            if let originalXdg { setenv("XDG_CONFIG_HOME", originalXdg, 1) } else { unsetenv("XDG_CONFIG_HOME") }

            // Finalize outside the swap so ~ expansion and shell detection
            // see the real environment.
            ghostty_config_finalize(config)
            return config
        }
    }
}
