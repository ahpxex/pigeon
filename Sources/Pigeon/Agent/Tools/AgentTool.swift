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

/// A capability the agent may invoke. Implementations must be safe to run
/// with no user confirmation (read-only) — anything mutating goes through
/// the permission gate in the runtime.
protocol AgentTool {
    var spec: AgentToolSpec { get }
    /// Execute with parsed arguments, relative to the caller's cwd.
    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult
}
