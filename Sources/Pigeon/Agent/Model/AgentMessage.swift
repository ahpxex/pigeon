import Foundation

/// Chat message in the OpenAI-compatible wire shape (DeepSeek speaks it
/// natively). Kept deliberately simple — text plus tool calls — instead of
/// Pi's generalized content blocks; Pigeon's micro-tasks don't need more.
struct AgentMessage: Codable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    var role: Role
    var content: String?
    var toolCalls: [ToolCallRequest]?
    /// For role == .tool: which call this message answers.
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    static func system(_ text: String) -> AgentMessage {
        AgentMessage(role: .system, content: text)
    }

    static func user(_ text: String) -> AgentMessage {
        AgentMessage(role: .user, content: text)
    }

    static func assistant(_ text: String?, toolCalls: [ToolCallRequest]? = nil) -> AgentMessage {
        AgentMessage(role: .assistant, content: text, toolCalls: toolCalls)
    }

    static func toolResult(callID: String, _ text: String) -> AgentMessage {
        AgentMessage(role: .tool, content: text, toolCallID: callID)
    }
}

/// A tool invocation requested by the model.
struct ToolCallRequest: Codable, Identifiable {
    struct FunctionCall: Codable {
        var name: String
        /// JSON-encoded argument object, as streamed by the model.
        var arguments: String
    }

    var id: String
    var type: String = "function"
    var function: FunctionCall
}

/// Why an assistant turn stopped.
enum StopReason: String {
    case done          // natural end of answer
    case toolCalls     // model wants tools executed
    case aborted       // cancelled by the caller
    case error         // request/stream failure (message in event)
}
