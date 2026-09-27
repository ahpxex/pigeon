import Foundation
import Network

/// In-process mock of TypeSafe's `POST /v1/systemone`. Scenarios map a
/// marker substring (searched in the request's `state.new_requests`) to
/// a scripted answer:
///
///   {"relation": "same_task"|"new_task", "confidence": 0.9, "fits": 0.8}
///   {"http": 500}                       — error status
///   {..., "omit": "title_fits"}         — drop one answer (protocol error)
///
/// Every request body is recorded so the runner can assert the wire
/// shape the app sends.
final class MockSystemOne {
    private var server: MockHTTPServer?
    private let scenarios: [[String: Any]]
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []

    static func start(scenarios: [[String: Any]]) async throws -> MockSystemOne {
        let mock = MockSystemOne(scenarios: scenarios)
        mock.server = try await MockHTTPServer.start(label: "pigeon-eval.mock-systemone") {
            [weak mock] request, connection in
            mock?.respond(connection, request: request)
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

    /// Request bodies received so far, oldest first.
    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func respond(_ connection: NWConnection, request: MockHTTPServer.Request) {
        guard request.method == "POST", request.path.hasSuffix("/systemone") else {
            MockHTTPServer.sendJSON(connection, status: 404, ["error": "unknown path \(request.path)"])
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        lock.lock(); recorded.append(json); lock.unlock()

        let newRequests = ((json["state"] as? [String: Any])?["new_requests"] as? [String] ?? [])
            .joined(separator: "\n")
        guard let answer = scenarios.first(where: {
            newRequests.contains($0["match"] as? String ?? "\u{0}")
        })?["answer"] as? [String: Any] else {
            MockHTTPServer.sendJSON(connection, status: 422, ["error": "mock: no scenario matched"])
            return
        }
        if let status = answer["http"] as? Int {
            MockHTTPServer.sendJSON(connection, status: status, ["error": "mock: scripted failure"])
            return
        }

        let relation = answer["relation"] as? String ?? "same_task"
        let confidence = answer["confidence"] as? Double ?? 0.9
        let other = relation == "same_task" ? "new_task" : "same_task"
        // Two options: confidence = 2p − 1 ⇒ p = (1 + confidence) / 2.
        let top = (1 + confidence) / 2
        var answers: [String: Any] = [
            "relation": [
                "type": "choice",
                "choice": relation,
                "confidence": confidence,
                "probabilities": [relation: top, other: 1 - top],
            ],
            "title_fits": ["type": "noul", "noul": answer["fits"] as? Double ?? 0.5],
        ]
        if let omit = answer["omit"] as? String { answers.removeValue(forKey: omit) }
        MockHTTPServer.sendJSON(connection, status: 200, [
            "model": "jev-mock",
            "answers": answers,
            "usage": ["input_tokens": 100, "output_tokens": 10],
        ])
    }
}
