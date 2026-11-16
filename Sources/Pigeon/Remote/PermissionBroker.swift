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
        /// Everything the tool would run with, untruncated: the bare
        /// command/path when that is the only argument, else one
        /// `key: value` line per argument. This is what gets approved, so
        /// it is never shortened; control characters are made visible
        /// (\u{1B} etc.) so nothing can hide or rewrite what is shown.
        let input: String
        /// The model's own one-line description, when the host sent one.
        let description: String?
        let createdAt: Date

        /// One line for notifications only — says so when it is cut.
        var summaryLine: String {
            let flat = input.replacingOccurrences(of: "\n", with: " ⏎ ")
            let head = flat.count > Self.summaryLimit
                ? String(flat.prefix(Self.summaryLimit))
                    + "… (\(input.count) characters in full: `pigeon approvals`)"
                : flat
            return head.isEmpty ? tool : "\(tool): \(head)"
        }

        static let summaryLimit = 160
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
            input: render(input),
            description: description?.isEmpty == false ? visible(description!) : nil,
            createdAt: Date())
    }

    /// Every argument except the model's description (shown separately).
    private static func render(_ input: [String: Any]) -> String {
        var arguments = input
        arguments.removeValue(forKey: "description")
        if arguments.count == 1, let only = arguments.first {
            if let string = only.value as? String { return visible(string) }
            if let parts = only.value as? [String] { return visible(parts.joined(separator: " ")) }
        }
        return arguments.keys.sorted().map { key in
            "\(key): \(visible(text(of: arguments[key]!)))"
        }.joined(separator: "\n")
    }

    private static func text(of value: Any) -> String {
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }

    /// Newlines and tabs stay; every other control character (ESC, CR,
    /// backspace, bidi overrides, ...) is shown as \u{XXXX} so it can't
    /// move the cursor, overwrite text or reorder what the approver sees.
    static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let hidden = scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format
            if hidden, scalar != "\n", scalar != "\t" {
                out += String(format: "\\u{%04X}", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Short, typeable id ("p" + 5 hex digits), unique among pending.
    private static func newID() -> String {
        while true {
            let id = "p" + String(format: "%05x", Int.random(in: 0..<0x100000))
            if !PermissionBroker.shared.continuations.keys.contains(id) { return id }
        }
    }
}
