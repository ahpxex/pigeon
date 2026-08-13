import Foundation

/// Wire description of a tool (OpenAI function-calling shape).
struct AgentToolSpec {
    var name: String
    var description: String
    /// JSON Schema for the arguments object.
    var parameters: [String: Any]

    var wireFormat: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }
}

/// Outcome of a tool execution. `display` is the short line shown in the
/// terminal; `output` is what goes back to the model.
struct AgentToolResult {
    var ok: Bool
    var output: String
    var display: String
}

/// What the user is asked before a destructive call runs. `message` is
/// natural language in the user's language (the model's `intent`, with a
/// fallback) — users don't read argv. `command` is the literal action,
/// shown dimmed for whoever wants to audit it.
struct ConfirmationRequest {
    var message: String
    var command: String
}

/// A capability the agent may invoke. Reversible calls run freely —
/// including most mutations (move, copy, create, trash). A call returns a
/// ConfirmationRequest only when it would destroy something irrecoverably
/// (rm, git clean/reset --hard, overwriting an existing file), and the
/// runtime then gates it behind an explicit user yes/no.
protocol AgentTool {
    var spec: AgentToolSpec { get }
    /// Per-call sensitivity check: nil = run freely.
    func confirmationRequest(arguments: [String: Any], cwd: String) -> ConfirmationRequest?
    /// Execute with parsed arguments, relative to the caller's cwd.
    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult
}

extension AgentTool {
    func confirmationRequest(arguments: [String: Any], cwd: String) -> ConfirmationRequest? {
        nil
    }
}
