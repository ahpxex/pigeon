import Foundation
import Network

/// HTTP plumbing for the eval runner: driver calls, the streaming /ask
/// request (answering confirmation sentinels mid-flight, like the zsh
/// hook does), and raw-socket probes for the security preflight.
enum AgentClient {
    // MARK: Driver (DriverServer on PIGEON_DRIVER_PORT)

    static let driverPort = Int(ProcessInfo.processInfo.environment["PIGEON_DRIVER_PORT"] ?? "8790") ?? 8790

    static func driver(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(driverPort)\(path)")!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EvalError("driver \(method) \(path): HTTP \(code) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: /ask streaming

    private static let sentinel = Data([0x01] + Array("PIGEON_CONFIRM".utf8) + [0x01])

    /// Incremental Transfer-Encoding: chunked decoder.
    private struct ChunkedDecoder {
        var buffer = Data()
        var finished = false

        mutating func feed(_ data: Data) -> Data {
            buffer.append(data)
            var out = Data()
            while !finished {
                guard let sizeEnd = buffer.range(of: Data("\r\n".utf8)) else { break }
                let sizeHex = String(decoding: buffer[..<sizeEnd.lowerBound], as: UTF8.self)
                guard let size = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    buffer.removeSubrange(..<sizeEnd.upperBound)
                    continue
                }
                if size == 0 {
                    finished = true
                    break
                }
                let frameEnd = sizeEnd.upperBound + size + 2
                guard buffer.count >= frameEnd else { break }
                out.append(buffer.subdata(in: sizeEnd.upperBound..<(sizeEnd.upperBound + size)))
                buffer.removeSubrange(..<frameEnd)
            }
            return out
        }
    }

    /// POST /ask and stream the answer. Deliberately a raw socket, not
    /// URLSession: its AsyncBytes buffers small amounts, which deadlocks
    /// against a stream that pauses awaiting /confirm — the sentinel
    /// would sit in the buffer while both sides wait. Confirmation
    /// sentinels are answered per `confirm` ("allow"/"deny") and
    /// rewritten in the returned text as "[confirm-request] <display>".
    static func ask(
        port: Int, token: String, prompt: String, cwd: String,
        timeout: Double, confirm: String, surface: String?
    ) async throws -> (status: Int, raw: String) {
        let body = Data(prompt.utf8)
        var head = "POST /ask HTTP/1.1\r\n"
        head += "Host: 127.0.0.1:\(port)\r\n"
        head += "Authorization: Bearer \(token)\r\n"
        head += "X-Pigeon-Cwd: \(cwd)\r\n"
        if let surface { head += "X-Pigeon-Surface: \(surface)\r\n" }
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var request = Data(head.utf8)
        request.append(body)

        let stream = openStream(port: port, request: request)

        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            group.addTask {
                try await readAnswer(from: stream, port: port, token: token, confirm: confirm)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EvalError("timed out after \(Int(timeout))s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func openStream(port: Int, request: Data) -> AsyncThrowingStream<Data, Error> {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "pigeon-eval.ask")
        return AsyncThrowingStream { continuation in
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, complete, error in
                    if let data, !data.isEmpty { continuation.yield(data) }
                    if let error { return continuation.finish(throwing: error) }
                    if complete { return continuation.finish() }
                    receive()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error { continuation.finish(throwing: error) } else { receive() }
                    })
                case .failed(let error):
                    continuation.finish(throwing: error)
                default: break
                }
            }
            connection.start(queue: queue)
            continuation.onTermination = { _ in connection.cancel() }
        }
    }

    private static func readAnswer(
        from stream: AsyncThrowingStream<Data, Error>,
        port: Int, token: String, confirm: String
    ) async throws -> (Int, String) {
        var status = -1
        var headersDone = false
        var headBuffer = Data()
        var decoder = ChunkedDecoder()
        var lineBuffer = Data()
        var raw = Data()

        func handleLine(_ line: Data) async {
            if line.starts(with: sentinel) {
                let fields = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                    .components(separatedBy: "\u{01}")
                let id = fields.count > 2 ? fields[2] : ""
                let display = fields.count > 3 ? fields[3] : ""
                raw.append(Data("[confirm-request] \(display)\n".utf8))
                try? await postConfirm(port: port, token: token, id: id, allow: confirm == "allow")
            } else {
                raw.append(line)
            }
        }
        func process(_ payload: Data) async {
            for byte in payload {
                lineBuffer.append(byte)
                if byte == 0x0A {
                    await handleLine(lineBuffer)
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            }
        }

        for try await piece in stream {
            if headersDone {
                await process(decoder.feed(piece))
            } else {
                headBuffer.append(piece)
                guard let headerEnd = headBuffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
                let headText = String(decoding: headBuffer[..<headerEnd.lowerBound], as: UTF8.self)
                status = Int(headText.dropFirst(9).prefix(3)) ?? -1
                headersDone = true
                if status != 200 { return (status, "") }
                let rest = headBuffer.subdata(in: headerEnd.upperBound..<headBuffer.endIndex)
                headBuffer.removeAll()
                await process(decoder.feed(rest))
            }
            if decoder.finished { break }
        }
        if !lineBuffer.isEmpty { await handleLine(lineBuffer) }
        return (status, String(decoding: raw, as: UTF8.self))
    }

    private static func postConfirm(port: Int, token: String, id: String, allow: Bool) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/confirm")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "allow": allow])
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: Security preflight (raw sockets: full control of Host/Origin)

    /// Sends a hand-built HTTP request and returns the response status.
    static func rawStatus(port: Int, request: String) async throws -> Int {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "pigeon-eval.probe")
        defer { connection.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            var resumed = false
            func finish(_ result: Result<Int, Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                    if let error { return finish(.failure(error)) }
                    if let data { buffer.append(data) }
                    let head = String(decoding: buffer.prefix(64), as: UTF8.self)
                    if head.hasPrefix("HTTP/1.1 "),
                       let code = Int(head.dropFirst(9).prefix(3)) {
                        return finish(.success(code))
                    }
                    if complete { return finish(.failure(EvalError("connection closed without status"))) }
                    receive()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: Data(request.utf8),
                        completion: .contentProcessed { error in
                            if let error { finish(.failure(error)) } else { receive() }
                        })
                case .failed(let error):
                    finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// The /ask and /confirm auth red lines, asserted on every run.
    static func securityPreflight(port: Int, token: String) async -> [String] {
        func probe(headers: [String], body: String, path: String = "/ask") -> String {
            var lines = ["POST \(path) HTTP/1.1"] + headers
            lines.append("Content-Length: \(body.utf8.count)")
            lines.append("Connection: close")
            return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        }
        let host = "Host: 127.0.0.1:\(port)"
        let auth = "Authorization: Bearer \(token)"
        let wrongAuth = "Authorization: Bearer " + String(repeating: "0", count: 64)
        let probes: [(String, String)] = [
            ("no token", probe(headers: [host], body: "ping")),
            ("wrong token", probe(headers: [host, wrongAuth], body: "ping")),
            ("browser origin", probe(headers: [host, auth, "Origin: https://evil.example"], body: "ping")),
            ("dns-rebinding host", probe(headers: ["Host: pigeon.evil.example:80", auth], body: "ping")),
            ("unauthenticated /confirm", probe(
                headers: [host], body: #"{"id":"x","allow":true}"#, path: "/confirm")),
        ]
        var failures: [String] = []
        for (name, request) in probes {
            do {
                let status = try await rawStatus(port: port, request: request)
                if status != 403 {
                    failures.append("\(name): expected 403, got \(status)")
                }
            } catch {
                failures.append("\(name): request error \(error.localizedDescription)")
            }
        }
        return failures
    }
}

struct EvalError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
