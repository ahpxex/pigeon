import Foundation
import Combine
import Security

/// An AI provider configuration. API keys are NOT stored here — they live
/// in the Keychain, one entry per provider.
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

    private static let builtins: [AgentProvider] = [
        AgentProvider(
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            models: ["claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"],
            selectedModel: "claude-sonnet-5",
            isBuiltin: true),
        AgentProvider(
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-5.1", "gpt-5.1-mini", "gpt-4.1", "o4-mini"],
            selectedModel: "gpt-5.1",
            isBuiltin: true),
        AgentProvider(
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-chat", "deepseek-reasoner"],
            selectedModel: "deepseek-chat",
            isBuiltin: true),
    ]

    private init() {
        if let data = defaults.data(forKey: "agentProviders"),
           let saved = try? JSONDecoder().decode([AgentProvider].self, from: data),
           !saved.isEmpty {
            providers = saved
        } else {
            providers = Self.builtins
        }
        if let raw = defaults.string(forKey: "agentDefaultProvider"),
           let id = UUID(uuidString: raw) {
            defaultProviderID = id
        } else {
            defaultProviderID = providers.first?.id
        }
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
        Keychain.delete(account: provider.id.uuidString)
        providers.removeAll { $0.id == provider.id }
        if defaultProviderID == provider.id {
            defaultProviderID = providers.first?.id
        }
    }

    func update(_ provider: AgentProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
    }

    // MARK: API keys (Keychain, one entry per provider)

    func apiKey(for provider: AgentProvider) -> String {
        Keychain.read(account: provider.id.uuidString) ?? ""
    }

    func setAPIKey(_ key: String, for provider: AgentProvider) {
        if key.isEmpty {
            Keychain.delete(account: provider.id.uuidString)
        } else {
            Keychain.write(account: provider.id.uuidString, value: key)
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

/// Minimal generic-password Keychain wrapper.
private enum Keychain {
    private static let service = "dev.ahpx.pigeon.agent"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
