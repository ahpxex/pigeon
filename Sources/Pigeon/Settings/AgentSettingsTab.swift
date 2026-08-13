import SwiftUI

/// AI provider management for the built-in agent: built-in and custom
/// providers, per-provider API keys (~/.config/pigeon/credentials.json),
/// enumerated models.
struct AgentSettingsTab: View {
    @ObservedObject private var agent = AgentSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $agent.defaultProviderID) {
                    ForEach(agent.providers) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                Button {
                    let provider = agent.addCustomProvider()
                    agent.defaultProviderID = provider.id
                } label: {
                    Label("Add Custom Provider", systemImage: "plus")
                }
            }

            // Only the selected provider's config is shown — it IS the one
            // the agent uses, so there is no wrong field to paste a key
            // into. .id() resets the section's @State on switch.
            if let provider = agent.providers.first(where: { $0.id == agent.defaultProviderID }) {
                ProviderSection(provider: provider)
                    .id(provider.id)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSection: View {
    let provider: AgentProvider
    @ObservedObject private var agent = AgentSettings.shared

    @State private var apiKey: String = ""
    @State private var fetching = false
    @State private var fetchError: String? = nil

    var body: some View {
        Section(provider.isBuiltin ? provider.name : "Custom Provider") {
            if !provider.isBuiltin {
                TextField("Name", text: binding(\.name))
                TextField("Base URL", text: binding(\.baseURL), prompt: Text("https://api.example.com/v1"))
                    .autocorrectionDisabled()
            }

            SecureField("API key", text: $apiKey, prompt: Text("Stored in ~/.config/pigeon"))
                .onSubmit { agent.setAPIKey(apiKey, for: provider) }
                .onChange(of: apiKey) { newValue in
                    agent.setAPIKey(newValue, for: provider)
                }

            HStack {
                if provider.models.isEmpty {
                    Text("No models — set the URL and key, then refresh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: binding(\.selectedModel)) {
                        ForEach(provider.models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                Spacer()

                Button {
                    refreshModels()
                } label: {
                    if fetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Fetch model list from the provider")
                .disabled(fetching)

                if !provider.isBuiltin {
                    Button(role: .destructive) {
                        agent.remove(provider)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove provider")
                }
            }

            if let fetchError {
                Text(fetchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { apiKey = agent.apiKey(for: provider) }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AgentProvider, T>) -> Binding<T> {
        Binding(
            get: {
                agent.providers.first { $0.id == provider.id }?[keyPath: keyPath]
                    ?? provider[keyPath: keyPath]
            },
            set: { newValue in
                guard var current = agent.providers.first(where: { $0.id == provider.id })
                else { return }
                current[keyPath: keyPath] = newValue
                agent.update(current)
            })
    }

    private func refreshModels() {
        fetching = true
        fetchError = nil
        Task { @MainActor in
            defer { fetching = false }
            guard var current = agent.providers.first(where: { $0.id == provider.id })
            else { return }
            do {
                let models = try await agent.fetchModels(for: current)
                current.models = models
                if !models.contains(current.selectedModel) {
                    current.selectedModel = models.first ?? ""
                }
                agent.update(current)
            } catch {
                fetchError = error.localizedDescription
            }
        }
    }
}
