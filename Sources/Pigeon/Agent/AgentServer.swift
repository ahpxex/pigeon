import Foundation
import Network
import Security

/// Always-on localhost server that shell hooks talk to: the zsh
/// command_not_found_handler POSTs the natural-language line here and
/// streams the agent's answer straight back into the pty.
///
/// Protocol:
///   POST /ask
///     Headers:
///       Authorization: Bearer <per-launch token>   (required)
///       Host: 127.0.0.1:<port>                       (validated)
///       X-Pigeon-Cwd: <working directory>
///     Body: raw prompt text (no JSON — avoids shell quoting pain)
///     Response: chunked plain text, ANSI-colored for terminal display.
///       A mutating tool call suspends the stream and emits one line
///         \u{01}PIGEON_CONFIRM\u{01}<id>\u{01}<action summary>
///       and the agent waits (120 s, then auto-deny) for:
///   POST /confirm   (same auth rules)
///     Body: {"id": "...", "allow": true|false}
///
/// The bind is 127.0.0.1-only, but that alone is not a trust boundary:
/// any local process — including a browser tab via a simple POST, or a
/// DNS-rebinding page — can reach it. So every request must carry the
/// per-launch bearer token (exported to the shell as PIGEON_AGENT_TOKEN,
/// never guessable by a web origin), present an exact loopback Host, and
/// carry no browser Origin. Together these close the browser and
/// cross-process vectors.
final class AgentServer {
    static let shared = AgentServer()

    /// Fixed port keeps the shell hook simple; if it's taken we walk up.
    /// Reading the port starts the server if needed — surfaces may be
    /// created before applicationDidFinishLaunching.
    var port: UInt16 {
        start()
        return boundPort
    }

    /// Per-launch secret the shell hook must present. Regenerated every
    /// process start, held only in memory.
    private(set) lazy var token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

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
        // Auth + anti-rebinding + anti-CSRF, before touching the body.
        guard isAuthorized(request) else {
            send(connection, raw: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        if request.method == "POST", request.path == "/confirm" {
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let allow = json["allow"] as? Bool
            else {
                send(connection, raw: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            Task { @MainActor in
                ConfirmationBroker.shared.resolve(id: id, allow: allow)
            }
            send(connection, raw: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
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

        // Markdown in the assistant text is rendered to ANSI as it
        // streams; the renderer is line-buffered, so flush its partial
        // line before interleaving any non-markdown output.
        let renderer = MarkdownANSIRenderer()
        func flushRenderer() {
            let tail = renderer.flush()
            if !tail.isEmpty { sendChunk(connection, tail + "\n") }
        }

        let events = AgentRuntime.run(.init(
            baseURL: provider.baseURL,
            apiKey: key,
            model: provider.selectedModel,
            prompt: prompt,
            cwd: cwd,
            confirm: { [weak self] message, command in
                guard let self else { return false }
                return await self.requestConfirmation(
                    message: message,
                    command: command,
                    connection: connection,
                    flush: { await MainActor.run { flushRenderer() } })
            }))

        for await event in events {
            switch event {
            case .textDelta(let piece):
                sendChunk(connection, renderer.feed(piece))
            case .toolStart(let name, let summary):
                flushRenderer()
                // Dim line so tool activity reads as machinery, not answer.
                sendChunk(connection, "\u{1B}[2m⏺ \(name): \(summary)\u{1B}[0m\n")
            case .toolEnd(_, let ok, let summary):
                if !ok {
                    flushRenderer()
                    sendChunk(connection, "\u{1B}[2m✗ \(summary)\u{1B}[0m\n")
                }
            case .finished(let reason, let message):
                flushRenderer()
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

    /// Emit a confirmation request into the stream and wait for the
    /// shell hook to POST /confirm. The prompt line carries the natural-
    /// language message; the literal command goes first as a dim audit
    /// line. Timeout or cancellation (user hit Ctrl+C) counts as a deny.
    private func requestConfirmation(
        message: String,
        command: String,
        connection: NWConnection,
        flush: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await flush()
        let id = UUID().uuidString
        sendChunk(connection, "\u{1B}[2m→ \(scrubbed(command))\u{1B}[0m\n")
        sendChunk(connection, "\u{01}PIGEON_CONFIRM\u{01}\(id)\u{01}\(scrubbed(message))\n")
        return await withTaskCancellationHandler {
            await ConfirmationBroker.shared.wait(id: id, timeout: 120)
        } onCancel: {
            Task { @MainActor in
                ConfirmationBroker.shared.resolve(id: id, allow: false)
            }
        }
    }

    /// Model- and argv-derived text goes into one-line frames; scrub
    /// control characters so nothing breaks the framing.
    private func scrubbed(_ text: String) -> String {
        String(text.map { char -> Character in
            guard let scalar = char.unicodeScalars.first, scalar.value < 32 else { return char }
            return " "
        })
    }

    /// Bearer token (constant-time compared) + exact loopback Host +
    /// absent browser Origin. A malicious web page cannot forge the
    /// token, cannot set Host, and cannot omit Origin on a cross-origin
    /// request — so it fails all three.
    private func isAuthorized(_ request: ParsedRequest) -> Bool {
        guard let auth = request.headers["authorization"],
              auth.hasPrefix("Bearer "),
              constantTimeEquals(String(auth.dropFirst(7)), token)
        else { return false }

        let host = request.headers["host"] ?? ""
        let validHosts = ["127.0.0.1:\(boundPort)", "localhost:\(boundPort)"]
        guard validHosts.contains(host) else { return false }

        // Browsers attach Origin to cross-origin POSTs; our shell hook
        // never sends one. Any Origin at all is suspicious.
        if request.headers["origin"] != nil { return false }
        return true
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
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

/// Rendezvous between an agent run awaiting a user decision and the
/// /confirm request that carries it. Every id resolves exactly once:
/// first of user answer / timeout / cancellation wins.
@MainActor
final class ConfirmationBroker {
    static let shared = ConfirmationBroker()

    private var pending: [String: CheckedContinuation<Bool, Never>] = [:]

    private init() {}

    func wait(id: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            pending[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolve(id: id, allow: false)
            }
        }
    }

    func resolve(id: String, allow: Bool) {
        pending.removeValue(forKey: id)?.resume(returning: allow)
    }
}
