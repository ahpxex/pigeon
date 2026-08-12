import Foundation

/// Streaming client for OpenAI-compatible /chat/completions endpoints —
/// DeepSeek is the first-class target, but anything speaking the same
/// protocol works (that's every custom provider Pigeon supports).
///
/// Contract (borrowed from Pi's StreamFn): this NEVER throws. Request,
/// network, and protocol failures are all encoded as a `.failed` event so
/// consumers only ever handle one shape.
enum ChatStreamClient {
    enum Event {
        case textDelta(String)
        /// Terminal event: full accumulated assistant turn.
        case completed(text: String?, toolCalls: [ToolCallRequest], finishReason: String?)
        case failed(String)
    }

    struct Request {
        var baseURL: String
        var apiKey: String
        var model: String
        var messages: [AgentMessage]
        var tools: [AgentToolSpec]
    }

    static func stream(_ request: Request) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                await run(request, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        _ request: Request,
        continuation: AsyncStream<Event>.Continuation
    ) async {
        guard let base = URL(string: request.baseURL) else {
            continuation.yield(.failed("invalid base URL: \(request.baseURL)"))
            return
        }

        var urlRequest = URLRequest(url: base.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 120

        do {
            var body: [String: Any] = [
                "model": request.model,
                "stream": true,
                "messages": try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(request.messages)),
            ]
            if !request.tools.isEmpty {
                body["tools"] = request.tools.map { $0.wireFormat }
            }
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            continuation.yield(.failed("failed to encode request: \(error.localizedDescription)"))
            return
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var detail = ""
                for try await line in bytes.lines {
                    detail += line
                    if detail.count > 2000 { break }
                }
                continuation.yield(.failed("HTTP \(http.statusCode): \(detail)"))
                return
            }

            var text = ""
            var sawText = false
            var toolAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]
            var finishReason: String? = nil

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choice = (json["choices"] as? [[String: Any]])?.first
                else { continue }

                if let reason = choice["finish_reason"] as? String {
                    finishReason = reason
                }
                guard let delta = choice["delta"] as? [String: Any] else { continue }

                if let piece = delta["content"] as? String, !piece.isEmpty {
                    text += piece
                    sawText = true
                    continuation.yield(.textDelta(piece))
                }

                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = call["index"] as? Int ?? 0
                    var accumulator = toolAccumulators[index] ?? (id: "", name: "", arguments: "")
                    if let id = call["id"] as? String { accumulator.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String { accumulator.name += name }
                        if let args = function["arguments"] as? String { accumulator.arguments += args }
                    }
                    toolAccumulators[index] = accumulator
                }
            }

            let toolCalls = toolAccumulators.sorted { $0.key < $1.key }.map { _, accumulated in
                ToolCallRequest(
                    id: accumulated.id.isEmpty ? UUID().uuidString : accumulated.id,
                    function: .init(name: accumulated.name, arguments: accumulated.arguments))
            }
            continuation.yield(.completed(
                text: sawText ? text : nil,
                toolCalls: toolCalls,
                finishReason: finishReason))
        } catch is CancellationError {
            continuation.yield(.failed("aborted"))
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }
}
