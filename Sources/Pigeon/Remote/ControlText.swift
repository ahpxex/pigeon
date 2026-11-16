import Foundation

/// Rendering for the `pigeon` CLI (ControlCommands): help, session and
/// event text, and the --json shapes.
@MainActor
enum ControlText {
    static let help = """
        pigeon — watch and control the coding agents (Claude Code, Codex, pi)
        running in Pigeon terminal tabs.

        Sessions
          pigeon sessions [--all]          List agent sessions: id, agent, state, directory,
                                           latest prompt/reply. --all also lists plain tabs.
          pigeon show <id> [--last N]      The recent conversation (default 3 exchanges,
                                           full replies), plus anything it is waiting on.
          pigeon screen <id> [--lines N]   The tab's terminal text (default last 60 lines).

        Acting
          pigeon send <id> <message>       Type a message into the agent and press Enter.
          pigeon interrupt <id>            Press Esc: stop the agent's current turn. (Claude Code
                                           doesn't report it, so it may stay "working".)
          pigeon key <id> <key>            Press one key, for the agent's own menus and
                                           dialogs: \(ControlKeys.names)
          pigeon new <dir> <claude|codex|pi>   Open a tab in <dir> and start that agent.

        Approvals (an agent asking to run a tool)
          pigeon approvals                 Pending requests, with ids.
          pigeon approve <request-id>
          pigeon deny <request-id> [reason]   The reason is shown to the agent.

        Waiting
          pigeon events [--since N] [--wait SECONDS]
                                           What happened after cursor N: replies finished,
                                           approvals needed, agents waiting on input. Waits up
                                           to SECONDS (default 30, max 600) for the first new
                                           event. Without --since: the recent backlog. Always
                                           prints the cursor to pass next time.

        States: idle (done, ready for a message), working, awaiting_approval,
        needs_input (blocked on a question in the terminal), ended.
        <id> is the 8-character session id (any unique prefix of 4+ characters).
        Add --json to any command for structured output.
        """

    static func shortID(_ tab: TerminalTab) -> String {
        String(tab.id.uuidString.lowercased().prefix(8))
    }

    static func agentName(_ source: String?) -> String {
        guard let source else { return "agent" }
        return ActivityHooks.Source(rawValue: source)?.displayName ?? source
    }

    static func displayPath(_ path: String?) -> String {
        guard let path else { return "?" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func state(_ tab: TerminalTab) -> AgentSessions.State? {
        AgentSessions.shared.state(of: tab.surfaceView.agentSurfaceID, isBusy: tab.isBusy)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func oneLine(_ text: String, max: Int = 240) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }

    // MARK: Sessions

    static func header(_ tab: TerminalTab) -> String {
        let record = AgentSessions.shared.sessions[tab.surfaceView.agentSurfaceID]
        var parts = ["[\(shortID(tab))]"]
        if let record { parts.append(agentName(record.source)) }
        if let state = state(tab) {
            var label = state.rawValue
            if state == .working,
               let activity = TabActivityMonitor.shared.activity(for: tab.id) {
                label += " (\(duration(activity.workSecondsSinceSubmit)))"
            }
            parts.append(label)
        }
        parts.append(displayPath(tab.surfaceView.pwd))
        return parts.joined(separator: " — ") + "\n  tab: \(tab.displayTitle)"
    }

    static func sessionSummary(_ tab: TerminalTab) -> String {
        let surfaceID = tab.surfaceView.agentSurfaceID
        var out = header(tab) + "\n"
        if !agentInForeground(tab) {
            out += "  the agent is no longer in the foreground (exited without saying so, "
                + "or suspended); it can't be messaged\n"
        }
        for request in PermissionBroker.shared.requests(for: surfaceID) {
            out += "  needs approval \(request.id): \(oneLine(request.summaryLine, max: 160))\n"
        }
        if let attention = AgentSessions.shared.sessions[surfaceID]?.attention {
            out += "  waiting for the user: \(oneLine(attention, max: 160))\n"
        }
        if let exchanges = AgentSessions.shared.sessions[surfaceID]?.exchanges {
            if let prompt = exchanges.last(where: { $0.prompt != nil }) {
                out += "  last prompt (\(time(prompt.startedAt))): \(oneLine(prompt.prompt!, max: 160))\n"
            }
            if let reply = exchanges.last(where: { $0.reply != nil }) {
                out += "  last reply (\(time(reply.finishedAt ?? reply.startedAt))): "
                    + "\(oneLine(reply.reply!))\n"
            }
        }
        return out
    }

    /// The agent that reported in still owns the terminal (see
    /// ControlContext.typingProblem).
    static func agentInForeground(_ tab: TerminalTab) -> Bool {
        guard let group = AgentSessions.shared.sessions[tab.surfaceView.agentSurfaceID]?
            .agentProcessGroup
        else { return false }
        return tab.surfaceView.foregroundProcessGroup == group
    }

    static func tabLine(_ tab: TerminalTab) -> String {
        "  [\(shortID(tab))] \(tab.displayTitle) — \(displayPath(tab.surfaceView.pwd))"
    }

    static func sessionJSON(_ tab: TerminalTab) -> [String: Any] {
        let surfaceID = tab.surfaceView.agentSurfaceID
        let record = AgentSessions.shared.sessions[surfaceID]
        var object: [String: Any] = [
            "id": shortID(tab),
            "title": tab.displayTitle,
            "cwd": tab.surfaceView.pwd ?? NSNull(),
            "agent": record?.source ?? NSNull(),
            "state": state(tab)?.rawValue ?? NSNull(),
            "waiting_for": record?.attention ?? NSNull(),
            "can_send": record?.active == true && agentInForeground(tab),
            "pending_approvals": PermissionBroker.shared.requests(for: surfaceID).map(approvalJSON),
        ]
        if let exchanges = record?.exchanges {
            object["last_prompt"] = exchanges.last(where: { $0.prompt != nil })?.prompt ?? NSNull()
            object["last_reply"] = exchanges.last(where: { $0.reply != nil })?.reply ?? NSNull()
        }
        return object
    }

    static func tabJSON(_ tab: TerminalTab) -> [String: Any] {
        ["id": shortID(tab), "title": tab.displayTitle, "cwd": tab.surfaceView.pwd ?? NSNull()]
    }

    static func exchangeText(_ exchange: AgentSessions.Exchange, agent: String) -> String {
        var out = ""
        if let prompt = exchange.prompt {
            out += "\n── \(time(exchange.startedAt)) user ──\n\(prompt)\n"
        }
        if let reply = exchange.reply {
            out += "\n── \(time(exchange.finishedAt ?? exchange.startedAt)) \(agent) ──\n\(reply)\n"
        } else if exchange.finishedAt == nil {
            out += "\n── \(agent) is still working on this ──\n"
        } else {
            out += "\n── \(agent) finished without a final message ──\n"
        }
        return out
    }

    static func exchangeJSON(_ exchange: AgentSessions.Exchange) -> [String: Any] {
        [
            "prompt": exchange.prompt ?? NSNull(),
            "reply": exchange.reply ?? NSNull(),
            "started_at": iso(exchange.startedAt),
            "finished_at": exchange.finishedAt.map(iso) ?? NSNull(),
        ]
    }

    // MARK: Approvals

    static func approvalBlock(_ request: PermissionBroker.Request) -> String {
        let tab = tab(surfaceID: request.surfaceID)
        var out = "\nApproval \(request.id) — \(agentName(request.source))"
        if let tab { out += " in [\(shortID(tab))] \(displayPath(tab.surfaceView.pwd))" }
        out += ", waiting since \(time(request.createdAt))\n"
        out += "  \(request.tool): \(request.summary)\n"
        if let description = request.description { out += "  (\(description))\n" }
        out += "  → `pigeon approve \(request.id)` or `pigeon deny \(request.id) [reason]`\n"
        return out
    }

    static func approvalJSON(_ request: PermissionBroker.Request) -> [String: Any] {
        [
            "id": request.id,
            "session": tab(surfaceID: request.surfaceID).map(shortID) ?? NSNull(),
            "agent": request.source,
            "tool": request.tool,
            "summary": request.summary,
            "description": request.description ?? NSNull(),
            "created_at": iso(request.createdAt),
        ]
    }

    // MARK: Events

    static func eventLine(_ event: AgentSessions.Event) -> String {
        let tab = tab(surfaceID: event.surfaceID)
        let id = tab.map { "[\(shortID($0))]" } ?? "[closed tab]"
        let agent = agentName(AgentSessions.shared.sessions[event.surfaceID]?.source)
        let prefix = "#\(event.seq) \(time(event.at)) \(id) \(agent)"
        let text = event.text.map { oneLine($0) }
        switch event.kind {
        case .started:
            return "\(prefix) started"
        case .working:
            return "\(prefix) working on: \(text ?? "")"
        case .finished:
            let more = tab.map { " (full: `pigeon show \(shortID($0))`)" } ?? ""
            return text.map { "\(prefix) finished: \($0)\(more)" } ?? "\(prefix) finished"
        case .needsInput:
            return "\(prefix) needs input: \(text ?? "")"
        case .approval:
            let id = event.approvalID ?? "?"
            return "\(prefix) needs approval \(id) — \(text ?? "") "
                + "(`pigeon approve \(id)` / `pigeon deny \(id)`)"
        case .approvalResolved:
            return "\(prefix) approval \(event.approvalID ?? "?") \(text ?? "")"
        case .ended:
            return "\(prefix) ended\(text.map { " (\($0))" } ?? "")"
        }
    }

    static func eventJSON(_ event: AgentSessions.Event) -> [String: Any] {
        [
            "seq": event.seq,
            "at": iso(event.at),
            "session": tab(surfaceID: event.surfaceID).map(shortID) ?? NSNull(),
            "kind": event.kind.rawValue,
            "text": event.text ?? NSNull(),
            "approval_id": event.approvalID ?? NSNull(),
        ]
    }

    // MARK: Helpers

    static func tab(surfaceID: String) -> TerminalTab? {
        TabManager.all.flatMap(\.tabs).first { $0.surfaceView.agentSurfaceID == surfaceID }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}\n" }
        return text + "\n"
    }
}

/// Key presses the CLI may send, encoded like real key events (keycode +
/// text) so TUIs using the kitty keyboard protocol see the right keys.
@MainActor
enum ControlKeys {
    private struct Key {
        let code: UInt32
        let text: String?
        let codepoint: UInt32
    }

    private static let keys: [String: Key] = {
        var keys: [String: Key] = [
            "enter": Key(code: 36, text: "\r", codepoint: 0x0D),
            "escape": Key(code: 53, text: "\u{1B}", codepoint: 0x1B),
            "tab": Key(code: 48, text: "\t", codepoint: 0x09),
            "space": Key(code: 49, text: " ", codepoint: 0x20),
            "backspace": Key(code: 51, text: "\u{7F}", codepoint: 0x7F),
            "up": Key(code: 126, text: nil, codepoint: 0),
            "down": Key(code: 125, text: nil, codepoint: 0),
            "left": Key(code: 123, text: nil, codepoint: 0),
            "right": Key(code: 124, text: nil, codepoint: 0),
            "y": Key(code: 16, text: "y", codepoint: 0x79),
            "n": Key(code: 45, text: "n", codepoint: 0x6E),
        ]
        // macOS virtual keycodes for the digit row.
        let digitCodes: [UInt32] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (digit, code) in digitCodes.enumerated() {
            keys[String(digit)] = Key(
                code: code, text: String(digit), codepoint: UInt32(0x30 + digit))
        }
        return keys
    }()

    static let names = "enter escape tab space backspace up down left right y n 0-9"

    @discardableResult
    static func press(_ name: String, on view: Ghostty.SurfaceView) -> Bool {
        guard let key = keys[name] else { return false }
        view.sendKey(keyCode: key.code, text: key.text, unshiftedCodepoint: key.codepoint)
        return true
    }
}
