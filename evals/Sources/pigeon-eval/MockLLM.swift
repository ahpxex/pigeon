import Foundation
import Network

/// In-process mock of an OpenAI-compatible /chat/completions SSE
/// endpoint. Deterministic: scenarios map a prompt substring to scripted
/// assistant turns.
///
/// Matching mirrors how the real runtime shapes messages:
/// - the LAST user message is the current prompt (earlier ones are
///   conversation history);
/// - turn N answers loop round N, counting assistant messages AFTER the
///   last user message;
/// - a turn with `echo_user_count: true` replies "user_count=N" — used
///   to assert conversation memory.
///
/// SSE text goes out in 7-char chunks so markdown tokens split across
/// deltas, exercising the streaming renderer.
final class MockLLM {
    private var server: MockHTTPServer?
    private let scenarios: [[String: Any]]

    static func start(scenarios: [[String: Any]]) async throws -> MockLLM {
        let mock = MockLLM(scenarios: scenarios)
        mock.server = try await MockHTTPServer.start(label: "pigeon-eval.mock-llm") {
            [weak mock] request, connection in
            await mock?.respond(connection, body: request.body)
        }
        return mock
    }

    private init(scenarios: [[String: Any]]) {
        self.scenarios = scenarios
    }

    var boundPort: UInt16 { server?.boundPort ?? 0 }

    func stop() {
        server?.stop()
    }

    private func respond(_ connection: NWConnection, body: Data) async {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let messages = json["messages"] as? [[String: Any]] ?? []

        var lastUser = -1
        for (index, message) in messages.enumerated()
        where message["role"] as? String == "user" {
            lastUser = index
        }
        let prompt = lastUser >= 0 ? (messages[lastUser]["content"] as? String ?? "") : ""
        let rounds = messages.dropFirst(lastUser + 1)
            .filter { $0["role"] as? String == "assistant" }.count
        let userCount = messages.filter { $0["role"] as? String == "user" }.count

        var turn = pickTurn(prompt: prompt, round: rounds)
        if turn["echo_user_count"] as? Bool == true {
            turn["text"] = "user_count=\(userCount)\n"
        }

        MockHTTPServer.send(connection, raw: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")

        func sse(_ payload: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            MockHTTPServer.sendChunk(connection, "data: " + String(decoding: data, as: UTF8.self) + "\n\n")
        }
        func delta(_ d: [String: Any], finish: String? = nil) {
            sse(["choices": [["delta": d, "finish_reason": finish as Any]]])
        }

        let text = turn["text"] as? String ?? ""
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 7, limitedBy: text.endIndex) ?? text.endIndex
            delta(["content": String(text[index..<end])])
            index = end
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let calls = turn["tool_calls"] as? [[String: Any]] ?? []
        for (callIndex, call) in calls.enumerated() {
            let arguments = (try? JSONSerialization.data(
                withJSONObject: call["arguments"] ?? [:])) ?? Data("{}".utf8)
            delta([
                "tool_calls": [[
                    "index": callIndex,
                    "id": "call_\(callIndex)",
                    "function": [
                        "name": call["name"] as? String ?? "",
                        "arguments": String(decoding: arguments, as: UTF8.self),
                    ],
                ]]
            ])
        }

        delta([:], finish: calls.isEmpty ? "stop" : "tool_calls")
        MockHTTPServer.sendChunk(connection, "data: [DONE]\n\n")
        MockHTTPServer.finishChunked(connection)
    }

    private func pickTurn(prompt: String, round: Int) -> [String: Any] {
        for scenario in scenarios {
            guard let match = scenario["match"] as? String, prompt.contains(match),
                  let turns = scenario["turns"] as? [[String: Any]]
            else { continue }
            return round < turns.count
                ? turns[round]
                : ["text": "mock: scenario ran out of turns\n"]
        }
        return ["text": "mock: no scenario matched this prompt\n"]
    }
}
