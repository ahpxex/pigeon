import Foundation

/// The `pigeon` CLI's commands (see RemoteControl). Output is plain text
/// written for whoever runs the CLI — often an LLM agent — so every
/// response says what happened and what to run next; `--json` gives the
/// same data structured.
@MainActor
enum ControlCommands {
    struct Response {
        var status: Int
        var body: String

        static func ok(_ body: String) -> Response { Response(status: 200, body: body) }
        static func fail(_ status: Int, _ message: String) -> Response {
            Response(status: status, body: "pigeon: " + message + "\n")
        }
    }

    /// Parsed command line: positional words plus --flags.
    struct Invocation {
        var words: [String] = []
        var flags: [String: String] = [:]
        var json: Bool { flags["json"] != nil }

        func int(_ name: String, default value: Int, range: ClosedRange<Int>) -> Int? {
            guard let raw = flags[name] else { return value }
            guard let number = Int(raw) else { return nil }
            return min(max(number, range.lowerBound), range.upperBound)
        }
    }

    /// Flags that take a value; everything else starting with -- is a
    /// switch. "--" ends flag parsing (so a message may start with "--").
    private static let valueFlags: Set<String> = ["since", "wait", "last", "lines"]

    static func parse(_ argv: [String]) -> Invocation {
        var invocation = Invocation()
        var index = 0
        var flagsDone = false
        while index < argv.count {
            let arg = argv[index]
            if !flagsDone, arg == "--" {
                flagsDone = true
            } else if !flagsDone, arg.hasPrefix("--"), arg.count > 2 {
                let name = String(arg.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    invocation.flags[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if valueFlags.contains(name), index + 1 < argv.count {
                    invocation.flags[name] = argv[index + 1]
                    index += 1
                } else {
                    invocation.flags[name] = ""
                }
            } else {
                invocation.words.append(arg)
            }
            index += 1
        }
        return invocation
    }

    static func run(argv: [String], cwd: String?, callerInsidePigeon: Bool) async -> Response {
        var invocation = parse(argv)
        guard !invocation.words.isEmpty else { return .ok(ControlText.help) }
        let command = invocation.words.removeFirst().lowercased()
        let context = ControlContext(
            invocation: invocation, cwd: cwd, callerInsidePigeon: callerInsidePigeon)

        switch command {
        case "help", "-h", "--help":
            return .ok(ControlText.help)
        case "sessions", "ls", "list", "status":
            return context.sessions()
        case "show":
            return context.show()
        case "screen":
            return context.screen()
        case "send":
            return await context.send()
        case "interrupt", "stop":
            return context.interrupt()
        case "key":
            return context.key()
        case "approvals":
            return context.approvals()
        case "approve":
            return context.decide(allow: true)
        case "deny":
            return context.decide(allow: false)
        case "events":
            return await context.events()
        case "new":
            return context.newSession()
        default:
            return .fail(400, "unknown command '\(command)'. Run `pigeon help`.")
        }
    }
}

/// One command invocation's view of the app.
@MainActor
struct ControlContext {
    typealias Response = ControlCommands.Response

    let invocation: ControlCommands.Invocation
    let cwd: String?
    let callerInsidePigeon: Bool

    private var store: AgentSessions { .shared }
    private var broker: PermissionBroker { .shared }

    // MARK: Read-only

    func sessions() -> Response {
        let tabs = TabManager.all.flatMap(\.tabs)
        let agentTabs = tabs.filter { isAgentSession($0) }
        let otherTabs = tabs.filter { !isAgentSession($0) }
        if invocation.json {
            var object: [String: Any] = [
                "sessions": agentTabs.map { ControlText.sessionJSON($0) },
                "cursor": store.lastSeq,
            ]
            if invocation.flags["all"] != nil {
                object["other_tabs"] = otherTabs.map { ControlText.tabJSON($0) }
            }
            return .ok(ControlText.json(object))
        }
        var out = ""
        if agentTabs.isEmpty {
            out += "No coding-agent sessions are running in Pigeon.\n"
            out += "Start one with `pigeon new <directory> claude|codex|pi`.\n"
        } else {
            out += agentTabs.count == 1
                ? "1 agent session:\n" : "\(agentTabs.count) agent sessions:\n"
            for tab in agentTabs { out += "\n" + ControlText.sessionSummary(tab) }
        }
        if invocation.flags["all"] != nil {
            if !otherTabs.isEmpty {
                out += "\nOther tabs (no agent session):\n"
                for tab in otherTabs { out += ControlText.tabLine(tab) + "\n" }
            }
        } else if !otherTabs.isEmpty {
            out += "\n\(otherTabs.count) other tab(s) without an agent (`pigeon sessions --all`).\n"
        }
        let missingHooks = ActivityHooks.Source.allCases.filter { !ActivityHooks.isInstalled($0) }
        if !missingHooks.isEmpty {
            out += "\nNot tracked (Pigeon hooks not installed): "
                + missingHooks.map(\.displayName).joined(separator: ", ")
                + ". Install in Pigeon → Settings → Agent → Coding Agents.\n"
        }
        out += "\nEvent cursor: \(store.lastSeq)  (`pigeon events --since \(store.lastSeq) --wait 60`)\n"
        return .ok(out)
    }

    func show() -> Response {
        guard let tab = resolveTab() else { return tabError() }
        guard let last = invocation.int("last", default: 3, range: 1...AgentSessions.maxExchanges)
        else { return .fail(400, "--last needs a number") }
        let surfaceID = tab.surfaceView.agentSurfaceID
        let record = store.sessions[surfaceID]
        let exchanges = Array((record?.exchanges ?? []).suffix(last))
        if invocation.json {
            var object = ControlText.sessionJSON(tab)
            object["exchanges"] = exchanges.map(ControlText.exchangeJSON)
            return .ok(ControlText.json(object))
        }
        var out = ControlText.header(tab) + "\n"
        if let attention = record?.attention {
            out += "Waiting for the user: \(attention)\n"
            out += "(see `pigeon screen \(ControlText.shortID(tab))`, answer with `pigeon key`)\n"
        }
        for request in broker.requests(for: surfaceID) {
            out += ControlText.approvalBlock(request)
        }
        if record == nil {
            out += "\nNo coding agent has reported from this tab. `pigeon screen \(ControlText.shortID(tab))` shows the terminal.\n"
        } else if exchanges.isEmpty {
            out += "\nNo messages recorded yet (Pigeon records messages sent since it started).\n"
        } else {
            for exchange in exchanges {
                out += ControlText.exchangeText(exchange, agent: ControlText.agentName(record?.source))
            }
        }
        return .ok(out)
    }

    func screen() -> Response {
        guard let tab = resolveTab() else { return tabError() }
        guard let count = invocation.int("lines", default: 60, range: 1...500)
        else { return .fail(400, "--lines needs a number") }
        var lines = tab.surfaceView.screenText()
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let text = lines.suffix(count).joined(separator: "\n")
        if invocation.json {
            return .ok(ControlText.json(["id": ControlText.shortID(tab), "text": text]))
        }
        return .ok(ControlText.header(tab) + "\n--- last \(count) lines ---\n" + text + "\n")
    }

    func approvals() -> Response {
        let pending = broker.pending
        if invocation.json {
            return .ok(ControlText.json(["approvals": pending.map(ControlText.approvalJSON)]))
        }
        guard !pending.isEmpty else { return .ok("No pending approvals.\n") }
        var out = ""
        for request in pending { out += ControlText.approvalBlock(request) }
        return .ok(out)
    }

    func events() async -> Response {
        let since: Int
        let wait: Int
        if let raw = invocation.flags["since"] {
            guard let value = Int(raw) else { return .fail(400, "--since needs a number") }
            since = value
            guard let seconds = invocation.int("wait", default: 30, range: 0...600)
            else { return .fail(400, "--wait needs a number of seconds") }
            wait = seconds
        } else {
            // No cursor yet: the recent backlog, without waiting.
            since = max(0, store.lastSeq - 20)
            wait = 0
        }
        let events = await store.waitForEvents(after: since, timeout: TimeInterval(wait))
        let cursor = events.last?.seq ?? max(since, 0)
        if invocation.json {
            return .ok(ControlText.json([
                "events": events.map(ControlText.eventJSON),
                "cursor": cursor,
            ]))
        }
        var out = events.isEmpty
            ? "No new events\(wait > 0 ? " in \(wait)s" : "").\n"
            : events.map(ControlText.eventLine).joined(separator: "\n") + "\n"
        out += "cursor: \(cursor)  (next: `pigeon events --since \(cursor) --wait 60`)\n"
        return .ok(out)
    }

    // MARK: Actions

    func send() async -> Response {
        if let refusal = refuseInsidePigeon() { return refusal }
        guard invocation.words.count >= 2 else {
            return .fail(400, "usage: pigeon send <session> <message>")
        }
        let message = invocation.words.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .fail(400, "the message is empty") }
        guard message.count <= 20_000 else { return .fail(400, "the message is too long (20000 characters max)") }
        guard let tab = resolveTab() else { return tabError() }
        if let problem = typingProblem(tab) { return problem }

        let surfaceID = tab.surfaceView.agentSurfaceID
        if let request = broker.requests(for: surfaceID).first {
            return .fail(409, "\(ControlText.shortID(tab)) is waiting for approval \(request.id) — "
                + "answer it first (`pigeon approve \(request.id)` / `pigeon deny \(request.id)`).")
        }
        if let attention = store.sessions[surfaceID]?.attention {
            return .fail(409, "\(ControlText.shortID(tab)) is waiting on a prompt (\(attention)); typed text "
                + "would go into it. Look with `pigeon screen \(ControlText.shortID(tab))` and answer with `pigeon key`.")
        }
        let wasBusy = tab.isBusy
        tab.surfaceView.sendText(message)
        // Let the TUI finish handling the paste before Enter arrives.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard typingProblem(tab) == nil else {
            return .fail(409, "the agent left the foreground while sending; Enter was not pressed")
        }
        ControlKeys.press("enter", on: tab.surfaceView)

        let id = ControlText.shortID(tab)
        let cursor = store.lastSeq
        if invocation.json {
            return .ok(ControlText.json(["ok": true, "id": id, "was_busy": wasBusy, "cursor": cursor]))
        }
        let state = wasBusy
            ? "It was busy, so the agent queues the message until its current turn ends."
            : "It is working on it now."
        return .ok("Sent to \(id). \(state)\n"
            + "Wait for the reply: `pigeon events --since \(cursor) --wait 60`, then `pigeon show \(id)`.\n")
    }

    func interrupt() -> Response {
        if let refusal = refuseInsidePigeon() { return refusal }
        guard let tab = resolveTab() else { return tabError() }
        if let problem = typingProblem(tab) { return problem }
        ControlKeys.press("escape", on: tab.surfaceView)
        return .ok("Pressed Esc in \(ControlText.shortID(tab)) (interrupts the current turn).\n")
    }

    func key() -> Response {
        if let refusal = refuseInsidePigeon() { return refusal }
        guard invocation.words.count == 2 else {
            return .fail(400, "usage: pigeon key <session> <\(ControlKeys.names)>")
        }
        guard let tab = resolveTab() else { return tabError() }
        if let problem = typingProblem(tab), !launchedAgentInFront(tab) { return problem }
        let name = invocation.words[1].lowercased()
        guard ControlKeys.press(name, on: tab.surfaceView) else {
            return .fail(400, "unknown key '\(name)'; use one of: \(ControlKeys.names)")
        }
        return .ok("Pressed \(name) in \(ControlText.shortID(tab)).\n")
    }

    func decide(allow: Bool) -> Response {
        if let refusal = refuseInsidePigeon() { return refusal }
        guard let id = invocation.words.first?.lowercased() else {
            return .fail(400, "usage: pigeon \(allow ? "approve <id>" : "deny <id> [reason]")")
        }
        guard let request = broker.request(id: id) else {
            return .fail(404, "no pending approval '\(id)' (already answered or withdrawn). See `pigeon approvals`.")
        }
        let reason = invocation.words.dropFirst().joined(separator: " ")
        let decision: PermissionBroker.Decision = allow
            ? .allow : .deny(reason: reason.isEmpty ? nil : reason)
        guard broker.resolve(id: id, decision: decision, by: .remote) else {
            return .fail(404, "approval '\(id)' was answered meanwhile")
        }
        let verb = allow ? "Allowed" : "Denied"
        return .ok("\(verb) \(id) (\(request.summaryLine)).\n")
    }

    func newSession() -> Response {
        if let refusal = refuseInsidePigeon() { return refusal }
        guard invocation.words.count == 2 else {
            return .fail(400, "usage: pigeon new <directory> <claude|codex|pi>")
        }
        let agent = invocation.words[1].lowercased()
        let commands = ["claude": ActivityHooks.Source.claudeCode,
                        "codex": .codex, "pi": .pi]
        guard let source = commands[agent] else {
            return .fail(400, "agent must be one of: claude, codex, pi")
        }
        let directory = resolvePath(invocation.words[0])
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .fail(404, "no such directory: \(directory)") }
        guard let manager = TabManager.forKeyWindow else {
            return .fail(409, "no Pigeon window is open")
        }
        // Only the fixed agent name is typed; any first message goes
        // through `send` once the session reports in.
        guard let tab = manager.newTab(workingDirectory: directory, initialInput: agent + "\n")
        else { return .fail(500, "could not open a tab") }
        AgentSessions.shared.markLaunched(surfaceID: tab.surfaceView.agentSurfaceID)
        let id = ControlText.shortID(tab)
        var out = "Opened \(id) in \(ControlText.displayPath(directory)) and started `\(agent)`.\n"
        if ActivityHooks.isInstalled(source) {
            out += "It appears in `pigeon sessions` once \(source.displayName) is up; "
                + "then `pigeon send \(id) <message>`. If it doesn't, it may be asking "
                + "something first (e.g. whether to trust the folder): check "
                + "`pigeon screen \(id)` and answer with `pigeon key \(id) <key>`.\n"
        } else {
            out += "Note: Pigeon's \(source.displayName) hooks are not installed, so this session "
                + "can't be tracked or messaged (Pigeon → Settings → Agent → Coding Agents).\n"
        }
        if invocation.json {
            return .ok(ControlText.json(["ok": true, "id": id, "cursor": store.lastSeq]))
        }
        return .ok(out)
    }

    // MARK: Guards

    /// Mutations are refused from inside this Pigeon's own terminals, so
    /// an agent can't approve its own tool requests (or drive its
    /// siblings) through the CLI. A process running as the user can
    /// always get around local checks — this keeps the ordinary path
    /// honest, it is not a sandbox.
    private func refuseInsidePigeon() -> Response? {
        guard callerInsidePigeon else { return nil }
        return .fail(403, "refused: this command was run from inside a Pigeon terminal. "
            + "Approving or driving agents is only allowed from outside Pigeon.")
    }

    /// Typing is only safe while the agent that reported in is still the
    /// pty's foreground process group: after a crash or kill (no final
    /// hook) the shell is back in front, and text would run as commands.
    private func typingProblem(_ tab: TerminalTab) -> Response? {
        let id = ControlText.shortID(tab)
        guard let record = store.sessions[tab.surfaceView.agentSurfaceID], record.active else {
            return .fail(409, "\(id) has no running coding agent; refusing to type into a shell.")
        }
        guard let agentGroup = record.agentProcessGroup,
              tab.surfaceView.foregroundProcessGroup == agentGroup
        else {
            return .fail(409, "the agent in \(id) is no longer in the foreground (it may have exited); "
                + "refusing to type into whatever replaced it.")
        }
        return nil
    }

    /// A tab opened by `pigeon new` whose launched agent is up but hasn't
    /// reported in yet — typically it is asking whether to trust the
    /// folder, before any hook runs. Single key presses are allowed then,
    /// as long as a program started from the shell (not the shell itself)
    /// is in the foreground.
    private func launchedAgentInFront(_ tab: TerminalTab) -> Bool {
        let surface = tab.surfaceView
        guard store.launched.contains(surface.agentSurfaceID),
              store.sessions[surface.agentSurfaceID] == nil,
              let group = surface.foregroundProcessGroup
        else { return false }
        return ProcessAncestry.isShellJob(foregroundGroup: group, app: getpid())
    }

    private func isAgentSession(_ tab: TerminalTab) -> Bool {
        store.sessions[tab.surfaceView.agentSurfaceID]?.active == true
    }

    // MARK: Resolution

    /// The tab named by the first word: a prefix (4+ characters) of its id.
    private func resolveTab() -> TerminalTab? {
        guard case .found(let tab) = lookup() else { return nil }
        return tab
    }

    private enum Lookup {
        case found(TerminalTab)
        case missing
        case none(String)
        case ambiguous(String)
    }

    private func lookup() -> Lookup {
        guard let reference = invocation.words.first?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]#"))
        else { return .missing }
        guard reference.count >= 4 else { return .none(reference) }
        let matches = TabManager.all.flatMap(\.tabs).filter {
            $0.id.uuidString.lowercased().hasPrefix(reference)
        }
        switch matches.count {
        case 1: return .found(matches[0])
        case 0: return .none(reference)
        default: return .ambiguous(reference)
        }
    }

    private func tabError() -> Response {
        switch lookup() {
        case .missing:
            return .fail(400, "name a session (an id from `pigeon sessions`)")
        case .none(let reference):
            return .fail(404, "no session '\(reference)'. See `pigeon sessions`.")
        case .ambiguous(let reference):
            return .fail(400, "'\(reference)' matches several sessions; use more characters")
        case .found:
            return .fail(500, "internal error")
        }
    }

    private func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        let base = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        return ((base as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}
