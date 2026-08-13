import Foundation
import Combine

/// An AI provider configuration. API keys are NOT stored here — they live
/// in ~/.config/pigeon/credentials.json, one entry per provider.
struct AgentProvider: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    /// Enumerated model list backing the model Select. Seeded for
    /// built-ins; refreshable from the provider's /models endpoint.
    var models: [String]
    var selectedModel: String
    var isBuiltin: Bool
}

@MainActor
final class AgentSettings: ObservableObject {
    static let shared = AgentSettings()

    @Published var providers: [AgentProvider] {
        didSet { persist() }
    }

    @Published var defaultProviderID: UUID? {
        didSet {
            UserDefaults.standard.set(defaultProviderID?.uuidString, forKey: "agentDefaultProvider")
        }
    }

    private let defaults = UserDefaults.standard

    /// Built-in provider IDs are fixed constants: the credentials entry for a
    /// provider is keyed by this ID, so it must be identical across
    /// launches — a random UUID here would orphan every stored API key on
    /// restart.
    private static let builtins: [AgentProvider] = [
        AgentProvider(
            id: UUID(uuidString: "6A1F26F1-0001-4B69-9E30-2D2B9A6E0001")!,
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            models: ["claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"],
            selectedModel: "claude-sonnet-5",
            isBuiltin: true),
        AgentProvider(
            id: UUID(uuidString: "6A1F26F1-0002-4B69-9E30-2D2B9A6E0002")!,
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-5.1", "gpt-5.1-mini", "gpt-4.1", "o4-mini"],
            selectedModel: "gpt-5.1",
            isBuiltin: true),
        AgentProvider(
            id: UUID(uuidString: "6A1F26F1-0003-4B69-9E30-2D2B9A6E0003")!,
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-chat", "deepseek-reasoner"],
            selectedModel: "deepseek-chat",
            isBuiltin: true),
    ]

    private init() {
        var loaded: [AgentProvider]
        if let data = defaults.data(forKey: "agentProviders"),
           let saved = try? JSONDecoder().decode([AgentProvider].self, from: data),
           !saved.isEmpty {
            loaded = saved
        } else {
            loaded = Self.builtins
        }

        // Reconcile builtins by name: lists saved before IDs were stable
        // carry random builtin IDs — remap them (moving any stored key
        // along) and append builtins introduced by app updates.
        for canonical in Self.builtins {
            if let index = loaded.firstIndex(where: { $0.isBuiltin && $0.name == canonical.name }) {
                if loaded[index].id != canonical.id {
                    CredentialsStore.move(
                        from: loaded[index].id.uuidString,
                        to: canonical.id.uuidString)
                    loaded[index].id = canonical.id
                }
            } else {
                loaded.append(canonical)
            }
        }
        providers = loaded

        if let raw = defaults.string(forKey: "agentDefaultProvider"),
           let id = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == id }) {
            defaultProviderID = id
        } else {
            defaultProviderID = loaded.first?.id
            UserDefaults.standard.set(
                defaultProviderID?.uuidString, forKey: "agentDefaultProvider")
        }
        // Property observers don't fire during init; persist the
        // reconciled list explicitly so a fresh install survives restart.
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: "agentProviders")
        }
    }

    // MARK: Provider management

    @discardableResult
    func addCustomProvider() -> AgentProvider {
        let provider = AgentProvider(
            name: "Custom Provider",
            baseURL: "",
            models: [],
            selectedModel: "",
            isBuiltin: false)
        providers.append(provider)
        return provider
    }

    func remove(_ provider: AgentProvider) {
        guard !provider.isBuiltin else { return }
        CredentialsStore.delete(account: provider.id.uuidString)
        providers.removeAll { $0.id == provider.id }
        if defaultProviderID == provider.id {
            defaultProviderID = providers.first?.id
        }
    }

    func update(_ provider: AgentProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }

    // MARK: API keys (credentials file, one entry per provider)

    func apiKey(for provider: AgentProvider) -> String {
        CredentialsStore.read(account: provider.id.uuidString) ?? ""
    }

    func setAPIKey(_ key: String, for provider: AgentProvider) {
        if key.isEmpty {
            CredentialsStore.delete(account: provider.id.uuidString)
        } else {
            CredentialsStore.write(account: provider.id.uuidString, value: key)
        }
    }

    // MARK: Model discovery

    enum FetchError: LocalizedError {
        case badURL
        case badResponse(Int)
        case noModels

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid base URL"
            case .badResponse(let code): return "HTTP \(code)"
            case .noModels: return "No models in response"
            }
        }
    }

    /// Query the provider's /models endpoint (OpenAI-compatible schema;
    /// Anthropic's variant uses the same shape with different headers).
    func fetchModels(for provider: AgentProvider) async throws -> [String] {
        guard let base = URL(string: provider.baseURL) else { throw FetchError.badURL }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        let key = apiKey(for: provider)
        if provider.baseURL.contains("api.anthropic.com") {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.badResponse(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else { throw FetchError.noModels }
        let ids = entries.compactMap { $0["id"] as? String }.sorted()
        guard !ids.isEmpty else { throw FetchError.noModels }
        return ids
    }
}

/// API-key store: a user-only JSON file at ~/.config/pigeon/credentials.json
/// mapping provider ID → key.
///
/// Deliberately NOT the macOS Keychain: Keychain item ACLs are bound to
/// the app's code identity, and for an app built from source that means
/// authorization prompts whenever the identity shifts — unusable in a
/// rebuild-heavy dev loop, and confusing after every update. A 0600 file
/// is the same trust model used by gh/aws/claude CLI credentials; full-
/// disk encryption covers at rest.
private enum CredentialsStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pigeon/credentials.json")
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
