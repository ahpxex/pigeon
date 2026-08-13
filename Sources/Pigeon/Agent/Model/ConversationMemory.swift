import Foundation

/// Per-tab conversation memory: each surface (terminal tab) is one
/// ongoing conversation, so a follow-up question can reference what was
/// just asked and answered. In-memory only — history dies with the app,
/// which matches the scope of "the conversation I'm having in this tab".
///
/// Only the visible exchange is kept (user prompt + final assistant
/// text). Tool calls and tool outputs from past requests are deliberately
/// dropped: they're bulky, stale, and the answer already summarizes them.
@MainActor
final class ConversationMemory {
    static let shared = ConversationMemory()

    /// Newest exchange last.
    private struct Exchange {
        var user: String
        var assistant: String
    }

    private var conversations: [String: [Exchange]] = [:]

    /// Bounds per surface: keep the tail that fits both limits.
    private let maxExchanges = 6
    private let maxTotalChars = 8_000

    private init() {}

    /// History as chat messages, oldest first, ready to slot between the
    /// system prompt and the new user message.
    func history(surface: String) -> [AgentMessage] {
        (conversations[surface] ?? []).flatMap { exchange in
            [.user(exchange.user), .assistant(exchange.assistant)]
        }
    }

    func append(surface: String, user: String, assistant: String) {
        guard !assistant.isEmpty else { return }
        var exchanges = conversations[surface] ?? []
        exchanges.append(Exchange(user: user, assistant: assistant))

        while exchanges.count > maxExchanges { exchanges.removeFirst() }
        while exchanges.count > 1,
              exchanges.reduce(0, { $0 + $1.user.count + $1.assistant.count }) > maxTotalChars {
            exchanges.removeFirst()
        }
        conversations[surface] = exchanges
    }
}
