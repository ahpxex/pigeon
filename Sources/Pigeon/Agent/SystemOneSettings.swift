import Foundation
import Combine

/// Configuration for the optional decision model: TypeSafe's System One
/// endpoint (Jev). Not a chat provider — it answers typed questions
/// (SystemOneClient) — so it lives beside AgentSettings rather than in
/// its provider list. Unconfigured (no key) means every feature built on
/// it falls back to its non-gated behavior.
@MainActor
final class SystemOneSettings: ObservableObject {
    static let shared = SystemOneSettings()

    static let baseURL = "https://api.typesafe.ai/v1"
    static let defaultModel = "jev-latest"

    /// Fixed credentials-store key for the single TypeSafe slot. Like the
    /// built-in provider IDs it must never change, or the stored key
    /// becomes an orphan.
    private static let credentialsAccount = "6A1F26F1-0101-4B69-9E30-2D2B9A6E0101"

    struct Config: Equatable {
        var baseURL: String
        var model: String
        var apiKey: String
    }

    @Published var model: String {
        didSet { defaults.set(model, forKey: "systemOneModel") }
    }

    /// Cached `/models` listing backing the model Picker.
    @Published var models: [String] {
        didSet { defaults.set(models, forKey: "systemOneModels") }
    }

    enum TestOverride: Equatable {
        /// Behave as if no decision model were configured.
        case disabled
        case config(Config)
    }

    /// Driver-only, in-memory replacement for the whole config: evals
    /// point decisions at a local mock, or switch them off, without
    /// touching the user's stored key or model. Never persisted.
    var testOverride: TestOverride?

    private let defaults = UserDefaults.standard

    private init() {
        model = defaults.string(forKey: "systemOneModel") ?? Self.defaultModel
        models = defaults.stringArray(forKey: "systemOneModels") ?? []
    }

    var apiKey: String {
        get { CredentialsStore.read(account: Self.credentialsAccount) ?? "" }
        set {
            // Pasted keys routinely carry a trailing newline or spaces.
            let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                CredentialsStore.delete(account: Self.credentialsAccount)
            } else {
                CredentialsStore.write(account: Self.credentialsAccount, value: key)
            }
            objectWillChange.send()
        }
    }

    /// The config decisions should use right now, or nil when the
    /// decision model is not set up.
    var activeConfig: Config? {
        switch testOverride {
        case .disabled: return nil
        case .config(let config): return config
        case nil: break
        }
        let key = apiKey
        guard !key.isEmpty, !model.isEmpty else { return nil }
        return Config(baseURL: Self.baseURL, model: model, apiKey: key)
    }

    func refreshModels() async -> String? {
        switch await SystemOneClient.listModels(baseURL: Self.baseURL, apiKey: apiKey) {
        case .success(let names):
            models = names
            if !names.contains(model) {
                model = names.contains(Self.defaultModel) ? Self.defaultModel : names[0]
            }
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }
}
