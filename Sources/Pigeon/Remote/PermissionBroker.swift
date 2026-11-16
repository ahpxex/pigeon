import Foundation

/// Tool approvals routed through Pigeon. A coding agent's PermissionRequest
/// hook (Claude Code, Codex) posts to the agent server's /permission and
/// blocks; the request waits here until someone decides — in the tab's
/// approval banner, or remotely through the control CLI — or until the
/// hook goes away because the agent's own prompt was answered first.
///
/// Every request resolves exactly once (first decision wins). `release`
/// hands the decision back to the agent's own prompt: the hook prints
/// nothing, which both hosts treat as "no opinion".
///
/// Host behavior this relies on (verified 2026-11-16, Claude Code 2.1.325,
/// Codex 0.169): Claude Code shows its own dialog *while* the hook runs
/// and accepts whichever answer comes first, killing the hook when the
/// user answers locally. Codex shows "Running hook" and no dialog until
/// the hook returns, and kills it on Esc. A late hook decision applies in
/// both.
@MainActor
final class PermissionBroker: ObservableObject {
    static let shared = PermissionBroker()

    struct Request: Identifiable, Equatable {
        let id: String
        let surfaceID: String
        /// claude-code | codex
        let source: String
        let tool: String
        /// The essential argument: the command, file path, URL, ...
        let summary: String
        /// The model's own one-line description, when the host sent one.
        let description: String?
        let createdAt: Date

        var summaryLine: String {
            summary.isEmpty ? tool : "\(tool): \(summary)"
        }
    }

    enum Decision: Equatable {
        case allow
        case deny(reason: String?)
        /// No decision from Pigeon; the agent's own prompt decides.
        case release

        var label: String {
            switch self {
            case .allow: return "allowed"
            case .deny: return "denied"
            case .release: return "handed back to the agent's prompt"
            }
        }
    }

    enum Resolver {
        case pigeon
        case remote
        /// The hook went away: answered in the agent's own prompt, or the
        /// turn was interrupted.
        case agent
        case timeout

        var label: String {
            switch self {
            case .pigeon: return "in Pigeon"
            case .remote: return "remotely"
            case .agent: return "in the terminal"
            case .timeout: return "after timing out"
            }
        }
    }

    /// The hook command's timeout is 3600 s and the reporter's request
    /// gives up at 3590 s; release before either so the host gets a clean
    /// "no decision" instead of a killed hook.
    static let holdLimit: TimeInterval = 3_480

    @Published private(set) var pending: [Request] = []
    private var continuations: [String: CheckedContinuation<Decision, Never>] = [:]

    private init() {}

    func requests(for surfaceID: String) -> [Request] {
        pending.filter { $0.surfaceID == surfaceID }
    }

    func request(id: String) -> Request? {
        pending.first { $0.id == id }
    }

    /// Wait for a decision on `request`.
    func hold(_ request: Request) async -> Decision {
        await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            pending.append(request)
            AgentSessions.shared.approvalRequested(request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.holdLimit * 1_000_000_000))
                self?.resolve(id: request.id, decision: .release, by: .timeout)
            }
        }
    }

    /// Returns false when the request no longer exists (already decided).
    @discardableResult
    func resolve(id: String, decision: Decision, by resolver: Resolver) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        let request = pending.first { $0.id == id }
        pending.removeAll { $0.id == id }
        if let request {
            AgentSessions.shared.approvalResolved(request, decision: decision, by: resolver)
        }
        continuation.resume(returning: decision)
        return true
    }

    /// Release every request of a surface (its tab closed).
    func releaseAll(surfaceID: String) {
        for request in requests(for: surfaceID) {
            resolve(id: request.id, decision: .release, by: .agent)
        }
    }

    // MARK: Building requests from hook input

    static func makeRequest(json: [String: Any], surfaceID: String) -> Request {
        let tool = (json["tool_name"] as? String) ?? "tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let description = (input["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Request(
            id: newID(),
            surfaceID: surfaceID,
            source: (json["pigeon_source"] as? String) ?? (json["source"] as? String) ?? "agent",
            tool: tool,
            summary: summarize(input),
            description: description?.isEmpty == false ? description : nil,
            createdAt: Date())
    }

    private static func summarize(_ input: [String: Any]) -> String {
        for key in ["command", "cmd", "file_path", "path", "url", "pattern", "query"] {
            if let string = input[key] as? String, !string.isEmpty {
                return capped(string)
            }
            if let parts = input[key] as? [String], !parts.isEmpty {
                return capped(parts.joined(separator: " "))
            }
        }
        var rest = input
        rest.removeValue(forKey: "description")
        guard !rest.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return capped(json)
    }

    private static func capped(_ text: String) -> String {
        text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text
    }

    /// Short, typeable id ("p" + 5 hex digits), unique among pending.
    private static func newID() -> String {
        while true {
            let id = "p" + String(format: "%05x", Int.random(in: 0..<0x100000))
            if !PermissionBroker.shared.continuations.keys.contains(id) { return id }
        }
    }
}
