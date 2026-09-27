import SwiftUI

/// "Decision Model" section of the Agent settings tab: the optional
/// TypeSafe System One key (SystemOneSettings). With it, AI tab titles
/// skip the title model whenever a new prompt just continues the same
/// task (TitleChangeJudge); without it, nothing changes.
struct DecisionModelSection: View {
    @ObservedObject private var settings = SystemOneSettings.shared

    @State private var apiKey = ""
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var autoFetchTask: Task<Void, Never>?

    var body: some View {
        Section {
            SecureField("TypeSafe API key", text: $apiKey,
                        prompt: Text("Stored in \(AppVariant.configDirectoryDisplayPath)"))
                .onChange(of: apiKey) { newValue in
                    let stored = settings.apiKey
                    settings.apiKey = newValue
                    if settings.apiKey != stored, !settings.apiKey.isEmpty {
                        scheduleFetch()
                    }
                }

            HStack {
                if settings.models.isEmpty {
                    Text(apiKey.isEmpty
                        ? "Models load from TypeSafe once a key is set"
                        : "No models yet — check the key, or refresh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $settings.model) {
                        ForEach(settings.models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
                Spacer()
                Button {
                    refresh()
                } label: {
                    if fetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Fetch model list from TypeSafe")
                .disabled(fetching || apiKey.isEmpty)
            }

            if let fetchError {
                Text(fetchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Decision Model")
        } footer: {
            Text("Optional. TypeSafe's Jev answers yes/no-style questions "
                + "cheaply; Pigeon uses it to skip re-titling a tab when your "
                + "new prompt continues the same task.")
        }
        .onAppear {
            apiKey = settings.apiKey
            if !apiKey.isEmpty, settings.models.isEmpty {
                scheduleFetch(after: 0.1)
            }
        }
        .onDisappear { autoFetchTask?.cancel() }
    }

    /// Debounced so typing a key doesn't fire a request per keystroke.
    private func scheduleFetch(after delay: TimeInterval = 0.8) {
        autoFetchTask?.cancel()
        autoFetchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func refresh() {
        fetching = true
        fetchError = nil
        Task { @MainActor in
            fetchError = await settings.refreshModels()
            fetching = false
        }
    }
}
