import Foundation
import Network

/// Always-on localhost server that shell hooks talk to: the zsh
/// command_not_found_handler POSTs the natural-language line here and
/// streams the agent's answer straight back into the pty.
///
/// Protocol:
///   POST /ask
///     Headers: X-Pigeon-Cwd: <working directory>
///     Body: raw prompt text (no JSON — avoids shell quoting pain)
///     Response: chunked plain text, ANSI-colored for terminal display.
final class AgentServer {
    static let shared = AgentServer()

    /// Fixed port keeps the shell hook simple; if it's taken we walk up.
    /// Reading the port starts the server if needed — surfaces may be
    /// created before applicationDidFinishLaunching.
    var port: UInt16 {
        start()
        return boundPort
    }

    private var boundPort: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pigeon.agent-server")

    private init() {}

    func start() {
        guard listener == nil else { return }
        for candidate in UInt16(8791)...UInt16(8799) {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: candidate)!)
            guard let listener = try? NWListener(using: params) else { continue }
            self.listener = listener
            self.boundPort = candidate
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
            Ghostty.logger.info("agent server on 127.0.0.1:\(candidate)")
            return
        }
        Ghostty.logger.error("agent server: no free port in 8791-8799")
    }

    // MARK: HTTP plumbing (request parse + chunked streaming response)

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = ParsedRequest(data: buffer) {
                self.handle(request, connection: connection)
            } else if complete || buffer.count > 512 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private struct ParsedRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        init?(data: Data) {
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
            else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines[0].components(separatedBy: " ")
            guard parts.count >= 2 else { return nil }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2 {
                    headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let bodyStart = headerEnd.upperBound
            guard data.count - bodyStart >= contentLength else { return nil }

            self.method = parts[0]
            self.path = parts[1]
            self.headers = headers
            self.body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        }
    }

    private func handle(_ request: ParsedRequest, connection: NWConnection) {
        guard request.method == "POST", request.path == "/ask" else {
            send(connection, raw: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let prompt = String(data: request.body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            send(connection, raw: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        let cwd = request.headers["x-pigeon-cwd"] ?? FileManager.default.homeDirectoryForCurrentUser.path

        send(connection, raw: "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")

        Task { @MainActor in
            await self.streamAgent(prompt: prompt, cwd: cwd, connection: connection)
        }
    }

    @MainActor
    private func streamAgent(prompt: String, cwd: String, connection: NWConnection) async {
        let agent = AgentSettings.shared
        guard let provider = agent.providers.first(where: { $0.id == agent.defaultProviderID })
                ?? agent.providers.first
        else {
            sendChunk(connection, "pigeon: no AI provider configured (Settings → Agent)\n")
            finishChunks(connection)
            return
        }
        let key = agent.apiKey(for: provider)
        guard !key.isEmpty else {
            sendChunk(connection, "pigeon: no API key for \(provider.name) (Settings → Agent)\n")
            finishChunks(connection)
            return
        }
        guard !provider.selectedModel.isEmpty else {
            sendChunk(connection, "pigeon: no model selected for \(provider.name) (Settings → Agent)\n")
            finishChunks(connection)
            return
        }

        let events = AgentRuntime.run(.init(
            baseURL: provider.baseURL,
            apiKey: key,
            model: provider.selectedModel,
            prompt: prompt,
            cwd: cwd))

        for await event in events {
            switch event {
            case .textDelta(let piece):
                sendChunk(connection, piece)
            case .toolStart(let name, let summary):
                // Dim line so tool activity reads as machinery, not answer.
                sendChunk(connection, "\u{1B}[2m⏺ \(name): \(summary)\u{1B}[0m\n")
            case .toolEnd(_, let ok, let summary):
                if !ok {
                    sendChunk(connection, "\u{1B}[2m✗ \(summary)\u{1B}[0m\n")
                }
            case .finished(let reason, let message):
                switch reason {
                case .done, .toolCalls:
                    sendChunk(connection, "\n")
                case .aborted:
                    sendChunk(connection, "\n\u{1B}[2m(aborted)\u{1B}[0m\n")
                case .error:
                    sendChunk(connection, "\n\u{1B}[31mpigeon: \(message ?? "error")\u{1B}[0m\n")
                }
            }
        }
        finishChunks(connection)
    }

    // MARK: Low-level send helpers

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

    private func finishChunks(_ connection: NWConnection) {
        connection.send(
            content: Data("0\r\n\r\n".utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
