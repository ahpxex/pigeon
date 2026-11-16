import Foundation

/// Driver routes for Remote Control (the `pigeon` CLI).
///
///   GET  /remote/state   -> {enabled, socket, cli, lastError, pending: [...],
///                            sessions: {surface: {active, source, state,
///                            attention, exchanges, agentProcessGroup}},
///                            cursor}
///   POST /remote/enable  <- {"enabled": bool}   same as the Settings toggle
///   POST /remote/resolve <- {"id": "...", "decision": "allow"|"deny"|"release"}
///                            answer a held approval as the banner would
extension DriverServer {
    @MainActor
    func handleRemoteRoute(_ request: HTTPRequest) -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/remote/state"):
            let remote = RemoteControl.shared
            var sessions: [String: Any] = [:]
            for tab in TabManager.all.flatMap(\.tabs) {
                let surfaceID = tab.surfaceView.agentSurfaceID
                guard let record = AgentSessions.shared.sessions[surfaceID] else { continue }
                sessions[surfaceID] = [
                    "tab": tab.id.uuidString,
                    "active": record.active,
                    "source": record.source,
                    "state": AgentSessions.shared.state(of: surfaceID, isBusy: tab.isBusy)?
                        .rawValue as Any,
                    "attention": record.attention as Any,
                    "exchanges": record.exchanges.map {
                        ["prompt": $0.prompt as Any, "reply": $0.reply as Any]
                    },
                    "agentProcessGroup": record.agentProcessGroup.map(Int.init) as Any,
                    "foregroundProcessGroup":
                        tab.surfaceView.foregroundProcessGroup.map(Int.init) as Any,
                ]
            }
            return HTTPResponse(json: [
                "enabled": remote.isEnabled,
                "socket": remote.socketURL.path,
                "cli": remote.cliPath,
                "lastError": remote.lastError as Any,
                "pending": PermissionBroker.shared.pending.map {
                    ["id": $0.id, "surface": $0.surfaceID, "tool": $0.tool, "summary": $0.summary]
                },
                "sessions": sessions,
                "cursor": AgentSessions.shared.lastSeq,
            ])

        case ("POST", "/remote/enable"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let enabled = json["enabled"] as? Bool
            else { return HTTPResponse(status: 400, error: "body must be {\"enabled\": bool}") }
            RemoteControl.shared.setEnabled(enabled)
            return HTTPResponse(json: [
                "enabled": RemoteControl.shared.isEnabled,
                "lastError": RemoteControl.shared.lastError as Any,
            ])

        case ("POST", "/remote/resolve"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = json["id"] as? String,
                  let raw = json["decision"] as? String
            else { return HTTPResponse(status: 400, error: "need {id, decision}") }
            let decision: PermissionBroker.Decision
            switch raw {
            case "allow": decision = .allow
            case "deny": decision = .deny(reason: json["reason"] as? String)
            case "release": decision = .release
            default: return HTTPResponse(status: 400, error: "decision: allow|deny|release")
            }
            let resolved = PermissionBroker.shared.resolve(id: id, decision: decision, by: .pigeon)
            return resolved
                ? HTTPResponse(json: ["ok": true])
                : HTTPResponse(status: 404, error: "no pending approval \(id)")

        default:
            return nil
        }
    }
}
