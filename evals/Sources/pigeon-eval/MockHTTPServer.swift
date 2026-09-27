import Foundation
import Network

/// Minimal in-process HTTP/1.1 server shared by the mocks (MockLLM,
/// MockSystemOne): loopback-only, ephemeral port, one request per
/// connection (the app's clients send `Connection: close` semantics
/// anyway). The handler owns the response — it may stream chunks.
final class MockHTTPServer {
    struct Request {
        let method: String
        let path: String
        let body: Data
    }

    typealias Handler = (Request, NWConnection) async -> Void

    private let listener: NWListener
    private let handler: Handler
    private let queue: DispatchQueue

    static func start(label: String, handler: @escaping Handler) async throws -> MockHTTPServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let server = MockHTTPServer(listener: listener, label: label, handler: handler)

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
            listener.start(queue: server.queue)
        }
        return server
    }

    private init(listener: NWListener, label: String, handler: @escaping Handler) {
        self.listener = listener
        self.handler = handler
        self.queue = DispatchQueue(label: label)
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

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = Self.parse(buffer) {
                let handler = self.handler
                Task { await handler(request, connection) }
            } else if complete || buffer.count > 4 * 1024 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// The request once the full Content-Length worth of body arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        return Request(
            method: requestLine[0],
            path: requestLine[1],
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength)))
    }

    // MARK: Response helpers

    static func send(_ connection: NWConnection, raw: String) {
        connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in })
    }

    static func sendChunk(_ connection: NWConnection, _ text: String) {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        var frame = Data(String(format: "%X\r\n", data.count).utf8)
        frame.append(data)
        frame.append(Data("\r\n".utf8))
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    static func finishChunked(_ connection: NWConnection) {
        connection.send(
            content: Data("0\r\n\r\n".utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A complete (non-streamed) JSON response, then close.
    static func sendJSON(_ connection: NWConnection, status: Int, _ object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        var response = Data(
            "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
