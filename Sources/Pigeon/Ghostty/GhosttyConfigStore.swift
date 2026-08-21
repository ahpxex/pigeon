import Foundation
import GhosttyKit

extension Ghostty {
    /// Pigeon's own terminal (kernel) configuration, fully isolated from
    /// Ghostty.app's. Same file format, different file.
    ///
    /// Isolation is a first-class kernel capability: our vendored patch
    /// (patches/ghostty-embedder-api.patch) adds a real C API,
    /// ghostty_config_load_file(config, path), so embedders own their
    /// config location. No default-path search, no environment tricks
    /// (an earlier HOME/XDG env swap broke non-deterministically because
    /// Foundation caches NSSearchPath results).
    enum ConfigStore {
        /// The file users edit. Per app variant: production reads
        /// ~/.config/pigeon/config, the dev build ~/.config/pigeon-dev/config.
        static var configFileURL: URL {
            AppVariant.configDirectoryURL.appendingPathComponent("config")
        }

        /// The best available starting point for a fresh config, tried in
        /// order: for the dev variant, production Pigeon's config first
        /// (so dev launches looking like the app in daily use); then
        /// Ghostty.app's config (XDG first, then App Support).
        private static var seedConfigURL: URL? {
            let fm = FileManager.default
            var candidates: [URL] = []
            if AppVariant.isDev {
                candidates.append(
                    AppVariant.productionConfigDirectoryURL
                        .appendingPathComponent("config"))
            }
            candidates += [
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
            if let source = seedConfigURL,
               let imported = try? String(contentsOf: source, encoding: .utf8) {
                contents += """

                # Imported from \(source.path) on first launch:
                \(imported)
                """
            }
            try? contents.write(to: configFileURL, atomically: true, encoding: .utf8)
        }

        /// Build a finalized ghostty config from Pigeon's file.
        static func load() -> ghostty_config_t? {
            prepare()
            guard let config = ghostty_config_new() else { return nil }
            ghostty_config_load_file(config, configFileURL.path)
            ghostty_config_load_recursive_files(config)
            ghostty_config_finalize(config)
            return config
        }
    }
}
