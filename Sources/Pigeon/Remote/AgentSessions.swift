import Foundation

/// What each coding-agent session (pi / Claude Code / Codex running in a
/// Pigeon tab) is doing, built from hook reports only: the conversation
/// so far (prompts and final replies), whether it waits on the user, and
/// an append-only event feed that remote controllers poll with a cursor.
///
/// Keyed by surface id (the tab's PIGEON_SURFACE_ID). In memory only,
/// like the rest of the hook state.
@MainActor
final class AgentSessions {
    static let shared = AgentSessions()

    struct Exchange {
        var prompt: String?
        var reply: String?
        let startedAt: Date
        var finishedAt: Date?
    }

    struct Session {
        var source: String
        /// False once the agent reported its own exit.
        var active = true
        /// The pty's foreground process group when the agent last
        /// reported in — the agent itself. Typing into the tab is only
        /// safe while this is still the foreground group; otherwise the
        /// text would land in whatever replaced it (usually the shell,
        /// after the agent crashed or was killed without a final hook).
        var agentProcessGroup: pid_t?
        /// Set while the agent is blocked on a question/dialog.
        var attention: String?
        var exchanges: [Exchange] = []
        var lastEventAt = Date()
    }

    enum State: String {
        case idle
        case working
        case awaitingApproval = "awaiting_approval"
        case needsInput = "needs_input"
        case ended
    }

    struct Event {
        enum Kind: String {
            case started
            case working
            case finished
            case needsInput = "needs_input"
            case approval
            case approvalResolved = "approval_resolved"
            case ended
        }

        let seq: Int
        let at: Date
        let surfaceID: String
        let kind: Kind
        let text: String?
        var approvalID: String?
    }

    static let maxExchanges = 20
    static let maxPromptLength = 4_000
    static let maxReplyLength = 20_000
    static let maxEvents = 500

    private(set) var sessions: [String: Session] = [:]
    /// Surfaces whose agent was started by `pigeon new`, before (and
    /// after) the agent's first hook — see ControlContext.key().
    private(set) var launched: Set<String> = []
    private var log: [Event] = []
    private(set) var lastSeq = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init() {}

    // MARK: Hook input

    /// Apply a hook report for a surface that exists. `foregroundGroup` is
    /// the pty's foreground process group right now — hooks fire from
    /// inside the running agent, so this is the agent's group.
    func record(_ report: HookReport, surfaceID: String, foregroundGroup: pid_t?) {
        let now = Date()
        var session = sessions[surfaceID] ?? Session(source: report.source ?? "agent")
        let isNew = sessions[surfaceID] == nil || !session.active
        if let source = report.source { session.source = source }
        session.lastEventAt = now
        if !report.ended {
            // Hooks normally fire while the agent owns the terminal, but a
            // headless run (`claude -p … &`) reports with the shell in
            // front. Only a program the shell started counts as the agent;
            // otherwise nothing may be typed into this tab.
            session.agentProcessGroup = foregroundGroup.flatMap {
                ProcessAncestry.isShellJob(foregroundGroup: $0, app: getpid()) ? $0 : nil
            }
        }

        switch report.event {
        case "ping":
            session.active = true
            session.attention = nil
            sessions[surfaceID] = session
            emit(.started, surfaceID: surfaceID, text: nil)
            return

        case "busy":
            if isNew { session.active = true }
            session.attention = nil
            if let prompt = report.prompt {
                session.exchanges.append(Exchange(
                    prompt: String(prompt.prefix(Self.maxPromptLength)), startedAt: now))
                trim(&session)
                sessions[surfaceID] = session
                emit(.working, surfaceID: surfaceID, text: prompt)
                return
            }

        case "idle":
            session.attention = nil
            if let reply = report.reply.map({ String($0.prefix(Self.maxReplyLength)) }) {
                if let last = session.exchanges.indices.last,
                   session.exchanges[last].reply == nil {
                    session.exchanges[last].reply = reply
                    session.exchanges[last].finishedAt = now
                } else {
                    session.exchanges.append(Exchange(
                        prompt: nil, reply: reply, startedAt: now, finishedAt: now))
                    trim(&session)
                }
            } else if let last = session.exchanges.indices.last,
                      session.exchanges[last].finishedAt == nil {
                session.exchanges[last].finishedAt = now
            }
            if report.ended {
                session.active = false
                session.agentProcessGroup = nil
            }
            sessions[surfaceID] = session
            if report.ended {
                emit(.ended, surfaceID: surfaceID, text: nil)
            } else {
                emit(.finished, surfaceID: surfaceID, text: report.reply)
            }
            return

        case "attention":
            if report.attentionCleared {
                session.attention = nil
            } else if report.isBlockingAttention {
                let message = report.message ?? "waiting for your input"
                session.attention = message
                sessions[surfaceID] = session
                emit(.needsInput, surfaceID: surfaceID, text: message)
                return
            }

        default:
            break
        }
        sessions[surfaceID] = session
    }

    func markLaunched(surfaceID: String) {
        launched.insert(surfaceID)
    }

    /// The tab is gone.
    func remove(surfaceID: String) {
        launched.remove(surfaceID)
        guard let session = sessions.removeValue(forKey: surfaceID) else { return }
        if session.active { emit(.ended, surfaceID: surfaceID, text: "tab closed") }
    }

    // MARK: Approvals (from PermissionBroker)

    func approvalRequested(_ request: PermissionBroker.Request) {
        var event = makeEvent(.approval, surfaceID: request.surfaceID, text: request.summaryLine)
        event.approvalID = request.id
        append(event)
    }

    func approvalResolved(
        _ request: PermissionBroker.Request,
        decision: PermissionBroker.Decision,
        by resolver: PermissionBroker.Resolver
    ) {
        var event = makeEvent(
            .approvalResolved, surfaceID: request.surfaceID,
            text: "\(decision.label) \(resolver.label)")
        event.approvalID = request.id
        append(event)
    }

    // MARK: Queries

    func state(of surfaceID: String, isBusy: Bool) -> State? {
        guard let session = sessions[surfaceID] else { return nil }
        if !session.active { return .ended }
        if !PermissionBroker.shared.requests(for: surfaceID).isEmpty { return .awaitingApproval }
        if session.attention != nil { return .needsInput }
        return isBusy ? .working : .idle
    }

    func events(after seq: Int) -> [Event] {
        log.filter { $0.seq > seq }
    }

    /// Events after `seq`, waiting up to `timeout` seconds for the first
    /// one if there are none yet.
    func waitForEvents(after seq: Int, timeout: TimeInterval) async -> [Event] {
        let existing = events(after: seq)
        guard existing.isEmpty, timeout > 0 else { return existing }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.waiters.removeValue(forKey: id)?.resume()
            }
        }
        return events(after: seq)
    }

    // MARK: Private

    private func trim(_ session: inout Session) {
        if session.exchanges.count > Self.maxExchanges {
            session.exchanges.removeFirst(session.exchanges.count - Self.maxExchanges)
        }
    }

    private func makeEvent(_ kind: Event.Kind, surfaceID: String, text: String?) -> Event {
        lastSeq += 1
        return Event(seq: lastSeq, at: Date(), surfaceID: surfaceID, kind: kind, text: text)
    }

    private func emit(_ kind: Event.Kind, surfaceID: String, text: String?) {
        append(makeEvent(kind, surfaceID: surfaceID, text: text))
    }

    private func append(_ event: Event) {
        log.append(event)
        if log.count > Self.maxEvents { log.removeFirst(log.count - Self.maxEvents) }
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume() }
    }
}
