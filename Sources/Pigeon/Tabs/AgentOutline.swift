import AppKit
import Combine
import Foundation

/// Message outline for one surface: every prompt the user submitted to
/// a coding agent (pi / Claude Code / Codex), captured by the activity
/// hooks. Drives the right-side outline panel — click an entry to jump
/// the terminal scrollback to that message.
@MainActor
final class AgentOutlineModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        /// The user's message verbatim (single line, capped).
        let prompt: String
        /// Agent source ("pi" / "claude-code" / "codex"), if reported.
        let source: String?
        /// Wall-clock time of submission.
        let date = Date()
    }

    @Published private(set) var entries: [Entry] = []

    /// Whether the current coding-agent session is still active. Message
    /// entries outlive the session so cmd+L remains useful after the agent
    /// returns to the shell prompt.
    @Published private(set) var isActive = false

    static let maxEntries = 200
    static let maxPromptLength = 200

    func append(prompt: String, source: String?) {
        let trimmed = String(prompt.prefix(Self.maxPromptLength))
        guard !trimmed.isEmpty else { return }
        entries.append(Entry(prompt: trimmed, source: source))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        isActive = true
    }

    /// The surface went back to a shell prompt, ending the active session.
    /// Keep the bounded entry list as this tab's message history.
    func endSession() {
        isActive = false
    }
}

/// Per-process registry of outlines by surface id — the outline must
/// survive view re-creation (panel toggle, window resize) and follow
/// the surface, not the SwiftUI identity.
@MainActor
enum AgentOutlineStore {
    private static var outlines: [String: AgentOutlineModel] = [:]

    static func outline(for surfaceID: String) -> AgentOutlineModel {
        if let existing = outlines[surfaceID] { return existing }
        let model = AgentOutlineModel()
        outlines[surfaceID] = model
        return model
    }

    /// Existing outline without creating one (presence checks).
    static func outlineIfAny(for surfaceID: String?) -> AgentOutlineModel? {
        guard let surfaceID else { return nil }
        return outlines[surfaceID]
    }

    static func remove(surfaceID: String) {
        outlines.removeValue(forKey: surfaceID)
    }
}
