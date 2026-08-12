import Foundation

/// The agent loop, shaped after Pi's agent-loop but sized for Pigeon's
/// micro-task scope: stream an assistant turn, execute requested tools
/// sequentially, feed results back, repeat — bounded by a small round
/// budget because our tasks are supposed to be one-shot.
enum AgentRuntime {
    /// Hard cap on model round-trips per request.
    static let maxRounds = 6

    struct RunConfig {
        var baseURL: String
        var apiKey: String
        var model: String
        var prompt: String
        var cwd: String
    }

    static func run(_ config: RunConfig) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                await loop(config, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func systemPrompt(cwd: String) -> String {
        """
        You are Pigeon, a terminal-native assistant for quick, small tasks: \
        inspecting directories, finding files, explaining errors, checking \
        ports and processes. You are not a coding agent; keep answers short \
        and act immediately.

        Rules:
        - Reply in the user's language.
        - Plain text only: no markdown headers, no code fences. This prints \
        directly into a terminal.
        - Prefer one tool call that answers the question over asking the \
        user anything.
        - Keep the final answer under ~15 lines.

        Context: working directory is \(cwd), OS is macOS.
        """
    }

    private static func loop(
        _ config: RunConfig,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        var messages: [AgentMessage] = [
            .system(systemPrompt(cwd: config.cwd)),
            .user(config.prompt),
        ]
        let tools = BuiltinTools.all

        for _ in 0..<maxRounds {
            if Task.isCancelled {
                continuation.yield(.finished(.aborted, message: nil))
                return
            }

            var completed: (text: String?, toolCalls: [ToolCallRequest])? = nil
            let stream = ChatStreamClient.stream(.init(
                baseURL: config.baseURL,
                apiKey: config.apiKey,
                model: config.model,
                messages: messages,
                tools: tools.map(\.spec)))

            for await event in stream {
                switch event {
                case .textDelta(let piece):
                    continuation.yield(.textDelta(piece))
                case .completed(let text, let toolCalls, _):
                    completed = (text, toolCalls)
                case .failed(let message):
                    let reason: StopReason = message == "aborted" ? .aborted : .error
                    continuation.yield(.finished(reason, message: message))
                    return
                }
            }

            guard let turn = completed else {
                continuation.yield(.finished(.error, message: "stream ended without completion"))
                return
            }

            if turn.toolCalls.isEmpty {
                continuation.yield(.finished(.done, message: nil))
                return
            }

            messages.append(.assistant(turn.text, toolCalls: turn.toolCalls))

            // Sequential tool execution: micro-tasks rarely need more than
            // one call, and ordering keeps terminal output readable.
            for call in turn.toolCalls {
                let result = await execute(call, cwd: config.cwd, continuation: continuation)
                messages.append(.toolResult(callID: call.id, result.output))
            }
        }

        continuation.yield(.finished(
            .error,
            message: "round budget (\(maxRounds)) exhausted — task too large for the built-in agent"))
    }

    private static func execute(
        _ call: ToolCallRequest,
        cwd: String,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> AgentToolResult {
        guard let tool = BuiltinTools.tool(named: call.function.name) else {
            let result = AgentToolResult(
                ok: false,
                output: "unknown tool: \(call.function.name)",
                display: call.function.name)
            continuation.yield(.toolEnd(name: call.function.name, ok: false, summary: result.display))
            return result
        }

        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(call.function.arguments.utf8))) as? [String: Any] ?? [:]

        continuation.yield(.toolStart(
            name: call.function.name,
            summary: (arguments["command"] as? String)
                ?? (arguments["path"] as? String)
                ?? call.function.name))

        let result = await tool.execute(arguments: arguments, cwd: cwd)
        continuation.yield(.toolEnd(name: call.function.name, ok: result.ok, summary: result.display))
        return result
    }
}
