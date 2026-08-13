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

/// A capability the agent may invoke. Read-only tools run freely; a tool
/// that mutates anything sets `requiresConfirmation` and the runtime
/// gates every call behind an explicit user yes/no.
protocol AgentTool {
    var spec: AgentToolSpec { get }
    /// Whether every invocation must be confirmed by the user first.
    var requiresConfirmation: Bool { get }
    /// Execute with parsed arguments, relative to the caller's cwd.
    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult
}

extension AgentTool {
    var requiresConfirmation: Bool { false }
}
