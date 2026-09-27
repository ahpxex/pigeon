import Foundation

/// API-key store: a user-only JSON file at credentials.json in the
/// variant's config dir (~/.config/pigeon, or ~/.config/pigeon-dev for
/// the dev build) mapping provider ID → key.
///
/// Deliberately NOT the macOS Keychain: Keychain item ACLs are bound to
/// the app's code identity, and for an app built from source that means
/// authorization prompts whenever the identity shifts — unusable in a
/// rebuild-heavy dev loop, and confusing after every update. A 0600 file
/// is the same trust model used by gh/aws/claude CLI credentials; full-
/// disk encryption covers at rest.
///
/// Entries are keyed by a stable UUID string: an AgentProvider's id, or a
/// fixed constant for single-slot services (see SystemOneSettings).
enum CredentialsStore {
    static var url: URL {
        AppVariant.configDirectoryURL.appendingPathComponent("credentials.json")
    }

    /// A fresh dev environment starts from a copy of the production keys
    /// (built-in provider UUIDs are fixed constants, so the entries map
    /// cleanly). A copy, not a shared file: the two apps must never write
    /// into each other's store. Runs once, before the first read or write,
    /// whichever caller gets there first.
    private static let seeded: Void = seedFromProductionIfNeeded()

    private static func seedFromProductionIfNeeded() {
        let fm = FileManager.default
        guard AppVariant.isDev, !fm.fileExists(atPath: url.path) else { return }
        let production = AppVariant.productionConfigDirectoryURL
            .appendingPathComponent("credentials.json")
        guard let data = try? Data(contentsOf: production) else { return }
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(
            atPath: url.path, contents: data,
            attributes: [.posixPermissions: 0o600])
    }

    static func read(account: String) -> String? {
        load()[account]
    }

    static func write(account: String, value: String) {
        var all = load()
        all[account] = value
        save(all)
    }

    static func delete(account: String) {
        var all = load()
        guard all.removeValue(forKey: account) != nil else { return }
        save(all)
    }

    /// Re-key an entry to a new account, keeping the existing value at the
    /// destination if both exist. Used when a provider's ID is migrated to
    /// its stable form.
    static func move(from oldAccount: String, to newAccount: String) {
        guard oldAccount != newAccount else { return }
        var all = load()
        guard let value = all.removeValue(forKey: oldAccount) else { return }
        if all[newAccount] == nil { all[newAccount] = value }
        save(all)
    }

    private static func load() -> [String: String] {
        _ = seeded
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func save(_ all: [String: String]) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        // Write-then-rename so the file is never observable partially
        // written, and is 0600 from the moment it exists.
        let tmp = dir.appendingPathComponent(".credentials.json.tmp")
        guard fm.createFile(
            atPath: tmp.path, contents: data,
            attributes: [.posixPermissions: 0o600])
        else { return }
        _ = try? fm.replaceItemAt(url, withItemAt: tmp)
    }
}
