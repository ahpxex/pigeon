import Foundation
import Network

/// Coding-agent hook endpoints on the agent server (same auth as /ask):
///
///   POST /activity
///     Headers: X-Pigeon-Surface: <surface id>
///     Body: the host's hook input JSON with event/source spliced in (see
///       ActivityHooks.reporterScript) — {"event": busy|idle|ping|attention,
///       "source": pi|claude-code|codex, prompt?, last_assistant_message?,
///       message?, ...}. busy/idle drive the tab spinner authoritatively;
///       the rest feeds AgentSessions. Returns an empty 200 (404 when the
///       surface is gone).
///
///   POST /permission
///     Headers: X-Pigeon-Surface: <surface id>
///     Body: a PermissionRequest hook input (tool_name, tool_input, ...).
///     With remote control off: an immediate empty 200 — the agent's own
///     prompt decides, exactly as without the hook. With it on: held in
///     PermissionBroker until decided, then the decision as the host's
///     hookSpecificOutput JSON (empty body = no decision). Closing the
///     connection (the host killed the hook) withdraws the request.
extension AgentServer {
    /// Handle the hook endpoints; false for any other path.
    func handleHookRequest(_ request: ParsedRequest, connection: NWConnection) -> Bool {
        switch request.path {
        case "/activity":
            handleActivity(request, connection: connection)
        case "/permission":
            handlePermission(request, connection: connection)
        default:
            return false
        }
        return true
    }

    private func handleActivity(_ request: ParsedRequest, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let report = HookReport(json: json),
              let surfaceID = request.headers["x-pigeon-surface"], !surfaceID.isEmpty
        else {
            send(connection, raw: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        Task { @MainActor in
            let accepted = TabActivityMonitor.shared.handle(report, surfaceID: surfaceID)
            let status = accepted ? "200 OK" : "404 Not Found"
            self.send(
                connection,
                raw: "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
    }

    private func handlePermission(_ request: ParsedRequest, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let surfaceID = request.headers["x-pigeon-surface"], !surfaceID.isEmpty
        else {
            send(connection, raw: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        Task { @MainActor in
            guard RemoteControl.shared.isEnabled,
                  TabManager.all.flatMap(\.tabs)
                      .contains(where: { $0.surfaceView.agentSurfaceID == surfaceID })
            else {
                self.respond(connection, decision: .release)
                return
            }
            let pending = PermissionBroker.makeRequest(json: json, surfaceID: surfaceID)
            self.withdrawOnDisconnect(connection, requestID: pending.id)
            let decision = await PermissionBroker.shared.hold(pending)
            self.respond(connection, decision: decision)
        }
    }

    /// The request body is fully read; the next thing the hook's curl does
    /// is close the socket — which only happens early if the host killed
    /// the hook (local answer, Esc). That withdraws the request.
    private func withdrawOnDisconnect(_ connection: NWConnection, requestID: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            _, _, isComplete, error in
            guard isComplete || error != nil else { return }
            Task { @MainActor in
                PermissionBroker.shared.resolve(id: requestID, decision: .release, by: .agent)
            }
        }
    }

    private func respond(_ connection: NWConnection, decision: PermissionBroker.Decision) {
        var body = Data()
        if let output = Self.hookOutput(for: decision) {
            body = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
        }
        var response = Data((
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// The PermissionRequest hook output both hosts understand.
    static func hookOutput(for decision: PermissionBroker.Decision) -> [String: Any]? {
        let verdict: [String: Any]
        switch decision {
        case .release:
            return nil
        case .allow:
            verdict = ["behavior": "allow"]
        case .deny(let reason):
            verdict = [
                "behavior": "deny",
                "message": reason.map { "Denied by the user: \($0)" }
                    ?? "Denied by the user. Do not retry this action; ask how to proceed instead.",
            ]
        }
        return ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": verdict,
        ]]
    }
}
