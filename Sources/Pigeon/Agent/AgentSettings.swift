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
    /// Model for AI tab titles (TabTitleSummarizer); nil = same as
    /// `selectedModel`. Titles are a tiny, frequent job — a cheap
    /// non-reasoning model is the right pick even when the agent itself
    /// runs on a bigger one.
    var titleModel: String? = nil

    /// The model TabTitleSummarizer should call.
    var effectiveTitleModel: String {
        if let titleModel, !titleModel.isEmpty { return titleModel }
        return selectedModel
    }
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
    ///
    /// Model lists are NOT seeded: they come from each provider's /models
    /// endpoint (fetched automatically once a key is set) and persist as a
    /// cache. A hardcoded list is stale the day it ships.
    private static let builtins: [AgentProvider] = [
        AgentProvider(
            id: UUID(uuidString: "6A1F26F1-0001-4B69-9E30-2D2B9A6E0001")!,
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            models: [],
            selectedModel: "",
            isBuiltin: true),
        AgentProvider(
            id: UUID(uuidString: "6A1F26F1-0002-4B69-9E30-2D2B9A6E0002")!,
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            models: [],
            selectedModel: "",
            isBuiltin: true),
        AgentProvider(
            id: UUID(uuidString: "6A1F26F1-0003-4B69-9E30-2D2B9A6E0003")!,
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            models: [],
            selectedModel: "",
            isBuiltin: true),
        AgentProvider(
            id: UUID(uuidString: "6A1F26F1-0004-4B69-9E30-2D2B9A6E0004")!,
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            models: [],
            selectedModel: "",
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
        // Pasted keys routinely carry a trailing newline or spaces, which
        // turn into baffling 401s.
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
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
