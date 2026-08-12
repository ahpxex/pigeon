import Foundation
import GhosttyKit

extension Ghostty {
    /// Pigeon's own terminal (kernel) configuration, fully isolated from
    /// Ghostty.app's. Same file format, different file.
    ///
    /// Isolation relies on a small patch we carry against libghostty
    /// (patches/ghostty-config-override.patch): when the
    /// GHOSTTY_CONFIG_OVERRIDE environment variable is set,
    /// ghostty_config_load_default_files loads exactly that file and
    /// nothing else. The earlier HOME/XDG env-swap approach was
    /// non-deterministic — Foundation caches NSSearchPath results, so
    /// whether the swap held depended on what AppKit had resolved first.
    enum ConfigStore {
        /// The file users edit.
        static var configFileURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/pigeon/config")
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

        /// Create the config file on first run.
        static func prepare() {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: configFileURL.path) else { return }

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

        /// Build a finalized ghostty config from Pigeon's file.
        /// Must be called on the main thread (mutates process env briefly).
        static func load() -> ghostty_config_t? {
            prepare()
            guard let config = ghostty_config_new() else { return nil }

            setenv("GHOSTTY_CONFIG_OVERRIDE", configFileURL.path, 1)
            ghostty_config_load_default_files(config)
            ghostty_config_load_recursive_files(config)
            unsetenv("GHOSTTY_CONFIG_OVERRIDE")

            ghostty_config_finalize(config)
            return config
        }
    }
}
