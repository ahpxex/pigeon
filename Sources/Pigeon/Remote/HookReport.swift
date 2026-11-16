import Foundation

/// One coding-agent hook event as delivered to `POST /activity`: the
/// host's own hook input (Claude Code / Codex JSON, forwarded verbatim by
/// the reporter script) or pi's extension payload, plus the event and
/// source Pigeon's hook command named.
struct HookReport {
    /// busy | idle | ping | attention
    let event: String
    /// pi | claude-code | codex
    let source: String?
    /// The user's message (busy).
    let prompt: String?
    /// The agent's final message of the turn (idle).
    let reply: String?
    /// What the agent is waiting for (attention).
    let message: String?
    /// attention: the wait is over (pi's ui_prompt_end).
    let attentionCleared: Bool
    /// attention: Claude Code's notification type, when present.
    let notificationType: String?
    /// The agent process is going away (SessionEnd / pi shutdown).
    let ended: Bool

    static let events: Set<String> = ["busy", "idle", "ping", "attention"]

    init?(json: [String: Any]) {
        // The reporter splices pigeon_* keys in last; they are the
        // unambiguous copies (a host payload may carry its own `source`).
        guard let event = (json["pigeon_event"] as? String) ?? (json["event"] as? String),
              Self.events.contains(event)
        else { return nil }
        self.event = event
        source = (json["pigeon_source"] as? String) ?? (json["source"] as? String)
        prompt = Self.text(json["prompt"])
        reply = Self.text(json["last_assistant_message"]) ?? Self.text(json["reply"])
        message = Self.text(json["message"])
        attentionCleared = json["cleared"] as? Bool == true
        notificationType = json["notification_type"] as? String
        ended = json["hook_event_name"] as? String == "SessionEnd"
            || json["ended"] as? Bool == true
    }

    /// Convenience for callers that only have the core fields (driver).
    init(event: String, source: String?, prompt: String? = nil, reply: String? = nil) {
        self.event = event
        self.source = source
        self.prompt = prompt
        self.reply = reply
        message = nil
        attentionCleared = false
        notificationType = nil
        ended = false
    }

    /// Claude Code notifications that do not mean "blocked on the user".
    /// permission_prompt is covered by the PermissionRequest hook (Pigeon
    /// holds the request itself), idle_prompt just means "done a while
    /// ago", the rest are informational.
    private static let passiveNotifications: Set<String> = [
        "permission_prompt", "idle_prompt", "auth_success", "elicitation_complete",
        "elicitation_response", "agent_completed", "quota_auto_resume_fired",
        "quota_auto_resume_stale", "quota_auto_resume_disabled", "plugin_notification",
    ]

    /// An attention report that actually means the agent is blocked on
    /// the user.
    var isBlockingAttention: Bool {
        guard event == "attention", !attentionCleared else { return false }
        if let notificationType, Self.passiveNotifications.contains(notificationType) {
            return false
        }
        return true
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
