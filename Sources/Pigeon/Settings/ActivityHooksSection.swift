import SwiftUI

/// "Coding Agents" section of the Agent settings tab: installs the
/// activity hooks that let pi / Claude Code / Codex report their real
/// run state, so the sidebar spinner never lights for an agent that
/// isn't working (scrolling, resizes, and other screen churn stop
/// counting as activity for hook-equipped tabs).
///
/// Rows stay single-line: the Agent tab is a fixed-height Settings
/// pane, and two-line rows pushed the last sources below the fold.
struct ActivityHooksSection: View {
    @State private var installed: [ActivityHooks.Source: Bool] = [:]
    @State private var errorText: String?

    var body: some View {
        Section {
            ForEach(ActivityHooks.Source.allCases, id: \.rawValue) { source in
                row(for: source)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Coding Agents")
        } footer: {
            Text("Report real run state to Pigeon: the spinner follows the "
                + "agent's own events instead of guessing from screen changes. "
                + "Works in any terminal tab launched from Pigeon; agents "
                + "without hooks keep the current behavior.")
        }
        .onAppear { refresh() }
    }

    private func row(for source: ActivityHooks.Source) -> some View {
        HStack {
            Text(source.displayName)
            Spacer()
            Button(installed[source] == true ? "Remove" : "Install") {
                toggle(source)
            }
        }
        .help(helpText(for: source))
    }

    private func helpText(for source: ActivityHooks.Source) -> String {
        let where_: String
        switch source {
        case .pi:
            where_ = "Installs an extension at ~/.pi/agent/extensions"
        case .claudeCode:
            where_ = "Adds hooks to ~/.claude/settings.json"
        case .codex:
            where_ = "Adds hooks to ~/.codex/hooks.json (reviewed on next Codex start)"
        }
        return where_ + ". Only active in Pigeon tabs; harmless elsewhere."
    }

    private func refresh() {
        installed = Dictionary(
            uniqueKeysWithValues: ActivityHooks.Source.allCases.map {
                ($0, ActivityHooks.isInstalled($0))
            })
    }

    private func toggle(_ source: ActivityHooks.Source) {
        errorText = nil
        do {
            if installed[source] == true {
                try ActivityHooks.remove(source)
            } else {
                try ActivityHooks.install(source)
            }
            refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
