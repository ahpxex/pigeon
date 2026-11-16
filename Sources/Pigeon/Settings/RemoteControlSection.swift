import AppKit
import SwiftUI

/// "Remote Control" section of the Agent settings tab: the `pigeon` CLI
/// that lets an outside program (a personal-agent bot that can run
/// commands on this Mac, a script) watch, message and approve the coding
/// agents running in Pigeon tabs.
struct RemoteControlSection: View {
    @ObservedObject private var remote = RemoteControl.shared
    @State private var copied = false

    var body: some View {
        Section {
            Toggle("Allow control through the pigeon CLI", isOn: Binding(
                get: { remote.isEnabled },
                set: { remote.setEnabled($0) }))
            if remote.isEnabled {
                LabeledContent("CLI") {
                    Text(remote.cliPath)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Button(copied ? "Copied" : "Copy Setup Instructions for a Bot") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(remote.botInstructions, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .help("Paste into your bot so it knows how to use the CLI")
            }
            if let error = remote.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Remote Control")
        } footer: {
            Text("Lets programs on this Mac list your coding-agent sessions, read their "
                + "replies, send them messages and answer their tool approvals. While on, "
                + "Claude Code and Codex approvals also appear in the tab. Needs the hooks "
                + "above.")
        }
    }
}
