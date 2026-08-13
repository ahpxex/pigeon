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
    private let listener: NWListener
    private let scenarios: [[String: Any]]
    private let queue = DispatchQueue(label: "pigeon-eval.mock")

    static func start(scenarios: [[String: Any]]) async throws -> MockLLM {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let mock = MockLLM(listener: listener, scenarios: scenarios)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume()
                case .failed(let error): resumed = true; cont.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: mock.queue)
        }
        return mock
    }

    private init(listener: NWListener, scenarios: [[String: Any]]) {
        self.listener = listener
        self.scenarios = scenarios
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
    }

    /// Actual bound port (listener.port is only valid once ready).
    var boundPort: UInt16 { listener.port?.rawValue ?? 0 }

    func stop() {
        listener.cancel()
    }

    // MARK: Request handling

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let body = Self.completeBody(of: buffer) {
                Task { await self.respond(connection, body: body) }
            } else if complete || buffer.count > 4 * 1024 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Body once the full Content-Length worth of bytes arrived.
    private static func completeBody(of data: Data) -> Data? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }
        var contentLength = 0
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        return data.subdata(in: bodyStart..<(bodyStart + contentLength))
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

        send(connection, raw: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")

        func sse(_ payload: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            sendChunk(connection, "data: " + String(decoding: data, as: UTF8.self) + "\n\n")
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
        sendChunk(connection, "data: [DONE]\n\n")
        connection.send(
            content: Data("0\r\n\r\n".utf8),
            completion: .contentProcessed { _ in connection.cancel() })
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

    // MARK: Low-level send

    private func send(_ connection: NWConnection, raw: String) {
        connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
    }

    private func sendChunk(_ connection: NWConnection, _ text: String) {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        var frame = Data(String(format: "%X\r\n", data.count).utf8)
        frame.append(data)
        frame.append(Data("\r\n".utf8))
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}
