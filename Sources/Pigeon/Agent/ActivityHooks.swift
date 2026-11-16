import Foundation

/// Integrations that let coding agents (pi, Claude Code, Codex) report
/// their real run state to Pigeon. The sidebar spinner follows these
/// events exclusively; terminal input and output are never interpreted
/// as agent state.
///
/// Two moving parts:
///
/// - One shared reporter script, `~/.config/pigeon/hooks/pigeon-activity`.
///   It is env-driven: PIGEON_AGENT_PORT / PIGEON_AGENT_TOKEN /
///   PIGEON_SURFACE_ID are inherited from the environment of whatever
///   process fired the hook (the tab's shell → the agent), so a single
///   file serves dev and production Pigeon alike and always reports to
///   the right instance and tab. Outside Pigeon it no-ops silently.
///
/// - Per-agent hook configuration pointing at that script. JSON configs
///   are merged in place — unknown keys and the user's own hooks are
///   preserved; our entries are exactly the ones whose command mentions
///   the reporter name, which is also how removal finds them.
///
/// Events: `busy` lights the spinner, `idle` clears it (and flags
/// unread; carries the agent's final reply when the host provides one),
/// `ping` establishes an idle baseline at session start, `attention`
/// says the agent is waiting on the user, and `permission` hands a tool
/// approval to Pigeon (PermissionBroker) and blocks for its decision.
enum ActivityHooks {
    enum Source: String, CaseIterable {
        case pi
        case claudeCode = "claude-code"
        case codex

        var displayName: String {
            switch self {
            case .pi: return "pi"
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            }
        }
    }

    enum HookError: LocalizedError {
        /// The user (or their tooling) explicitly opted out of Codex
        /// hooks; we won't silently flip their choice back.
        case codexFeatureDisabled

        var errorDescription: String? {
            switch self {
            case .codexFeatureDisabled:
                return "Codex hooks are disabled in ~/.codex/config.toml "
                    + "(features.hooks = false). Enable them to use this."
            }
        }
    }

    static let reporterName = "pigeon-activity"
    /// Keep JSON hook commands byte-for-byte stable while upgrading the
    /// shared reporter. Codex trusts the command itself, so needlessly
    /// changing this marker would invalidate an already-approved hook.
    private static let jsonHookVersionMarker = "pigeon-activity-v2"

    /// The reporter is stateless glue driven by per-tab env vars, so it
    /// lives in the production config directory regardless of which app
    /// variant installed it — both variants share it happily.
    static var reporterURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pigeon/hooks/\(reporterName)")
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var claudeSettingsURL: URL {
        home.appendingPathComponent(".claude/settings.json")
    }
    private static var codexHooksURL: URL {
        home.appendingPathComponent(".codex/hooks.json")
    }
    private static var codexConfigURL: URL {
        home.appendingPathComponent(".codex/config.toml")
    }
    private static var piExtensionURL: URL {
        home.appendingPathComponent(".pi/agent/extensions/\(reporterName).ts")
    }

    // MARK: - Reporter script

    static var isReporterInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: reporterURL.path),
              let installed = try? String(contentsOf: reporterURL, encoding: .utf8)
        else { return false }
        return installed.contains(reporterVersionMarker)
    }

    @discardableResult
    static func installReporter() throws -> URL {
        let dir = reporterURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let data = Data(reporterScript.utf8)
        try data.write(to: reporterURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: reporterURL.path)
        return reporterURL
    }

    static func removeReporter() throws {
        try? FileManager.default.removeItem(at: reporterURL)
    }

    // MARK: - Per-source status

    /// One entry in a JSON hook config (Claude Code settings.json, Codex
    /// hooks.json).
    private struct JSONHook {
        let event: String
        let action: String
        /// Save stdin to a file and pass its path. Kept for the prompt
        /// hooks so their commands stay byte-identical to what earlier
        /// versions installed (Codex re-asks for trust when a command
        /// changes); the v4 reporter reads stdin itself for every other
        /// event.
        var promptFile = false
        /// Seconds the host waits for the command. nil = host default.
        var timeout: Int?
    }

    /// The permission hook holds until someone decides in Pigeon; the
    /// reporter's own request gives up just before this.
    private static let permissionHookTimeout = 3600

    private static func jsonHooks(for source: Source) -> [JSONHook] {
        var hooks = [
            JSONHook(event: "SessionStart", action: "ping"),
            JSONHook(event: "UserPromptSubmit", action: "busy", promptFile: true),
            JSONHook(event: "Stop", action: "idle"),
            JSONHook(event: "StopFailure", action: "idle"),
            // idle, not a new event: older Pigeon builds share these hooks
            // and only know busy/idle/ping. The SessionEnd hook name in the
            // forwarded input tells current Pigeon the session is over.
            JSONHook(event: "SessionEnd", action: "idle"),
            JSONHook(
                event: "PermissionRequest", action: "permission",
                timeout: permissionHookTimeout),
        ]
        switch source {
        case .claudeCode:
            hooks.append(JSONHook(event: "Notification", action: "attention"))
        case .codex:
            // Esc interrupts a Codex turn without a Stop event. Codex caps
            // Interrupt hooks at 3 s (default 1 s).
            hooks.append(JSONHook(event: "Interrupt", action: "idle", timeout: 3))
        case .pi:
            return []
        }
        return hooks
    }

    static func isInstalled(_ source: Source) -> Bool {
        guard isReporterInstalled else { return false }
        switch source {
        case .pi:
            guard let installed = try? String(contentsOf: piExtensionURL, encoding: .utf8)
            else { return false }
            return installed.contains(reporterVersionMarker)
        case .claudeCode:
            return jsonHookEventsContainReporter(
                at: claudeSettingsURL, events: jsonHooks(for: source).map(\.event),
                requireCurrentVersion: true)
        case .codex:
            return jsonHookEventsContainReporter(
                at: codexHooksURL, events: jsonHooks(for: source).map(\.event),
                requireCurrentVersion: true)
        }
    }

    /// Bring integrations installed by an older Pigeon up to the current
    /// protocol. Presence is checked independently of version so an app
    /// update repairs stale scripts and commands without requiring a
    /// remove/reinstall cycle in Settings.
    static func upgradeInstalledHooks() {
        for source in Source.allCases where isConfigured(source) && !isInstalled(source) {
            do {
                try install(source)
            } catch {
                Ghostty.logger.error(
                    "activity hooks: failed to upgrade \(source.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private static func isConfigured(_ source: Source) -> Bool {
        switch source {
        case .pi:
            return FileManager.default.fileExists(atPath: piExtensionURL.path)
        case .claudeCode:
            return jsonHooksMentionReporter(at: claudeSettingsURL)
        case .codex:
            return jsonHooksMentionReporter(at: codexHooksURL)
        }
    }

    // MARK: - Install / remove

    static func install(_ source: Source) throws {
        try installReporter()
        switch source {
        case .pi:
            try installPiExtension()
        case .claudeCode:
            try mergeJSONHooks(at: claudeSettingsURL, source: source)
        case .codex:
            try ensureCodexHooksEnabled()
            try mergeJSONHooks(at: codexHooksURL, source: source)
        }
    }

    static func remove(_ source: Source) throws {
        switch source {
        case .pi:
            try? FileManager.default.removeItem(at: piExtensionURL)
        case .claudeCode:
            try removeJSONHooks(
                at: claudeSettingsURL, events: jsonHooks(for: source).map(\.event))
        case .codex:
            try removeJSONHooks(
                at: codexHooksURL, events: jsonHooks(for: source).map(\.event))
        }
        // The reporter only matters while some agent still points at it.
        if !Source.allCases.contains(where: isInstalled) {
            try removeReporter()
        }
    }

    // MARK: - JSON hook merge (Claude Code settings.json, Codex hooks.json)

    /// Both hosts use the same shape: `hooks.<Event>[].hooks[].command`.
    /// Ours are appended per event; entries mentioning the reporter name
    /// (ours or stale copies from another variant) are replaced; anything
    /// else in the file is preserved untouched.
    private static func mergeJSONHooks(at url: URL, source: Source) throws {
        var root = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            as? [String: Any] ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for hook in jsonHooks(for: source) {
            var groups = hooks[hook.event] as? [[String: Any]] ?? []
            groups.removeAll { mentionsReporter($0) }
            var command =
                "$HOME/.config/pigeon/hooks/\(reporterName) \(hook.action) \(source.rawValue)"
            if hook.promptFile {
                // Both hosts deliver event JSON on stdin. Preserve it in a
                // temporary file so prompt text is never interpolated into
                // shell or JSON syntax.
                command = "f=$(mktemp); cat > \"$f\"; \(command) \"$f\"; rm -f \"$f\""
            }
            command += " # \(jsonHookVersionMarker)"
            var entry: [String: Any] = [
                "type": "command",
                // Both hosts run command hooks through a shell, so $HOME
                // expands; the path must not depend on which app variant
                // did the installing.
                "command": command,
            ]
            if let timeout = hook.timeout { entry["timeout"] = timeout }
            groups.append(["hooks": [entry]])
            hooks[hook.event] = groups
        }

        root["hooks"] = hooks
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func removeJSONHooks(at url: URL, events: [String]) throws {
        guard var root = (try? Data(contentsOf: url))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any]
        else { return }
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll { mentionsReporter($0) }
            if groups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func jsonHookEventsContainReporter(
        at url: URL, events: [String], requireCurrentVersion: Bool
    ) -> Bool {
        guard let root = (try? Data(contentsOf: url))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains { group in
                guard mentionsReporter(group) else { return false }
                guard requireCurrentVersion else { return true }
                return (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains(jsonHookVersionMarker) == true
                } == true
            } == true
        }
    }

    private static func jsonHooksMentionReporter(at url: URL) -> Bool {
        guard let root = (try? Data(contentsOf: url))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains(where: mentionsReporter) == true
        }
    }

    /// A matcher group is ours if any of its hook commands invokes the
    /// reporter script (matched by name, not full path, so entries from
    /// either config directory count).
    private static func mentionsReporter(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains(reporterName) == true
        } == true
    }

    // MARK: - Codex feature flag (config.toml)

    /// Codex gates hooks behind `features.hooks`. Enabled by default in
    /// recent versions; if the key is absent we add it under `[features]`,
    /// and if the user explicitly set it to false we refuse rather than
    /// override their choice.
    private static func ensureCodexHooksEnabled() throws {
        let url = codexConfigURL
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: "\n")

        var inFeatures = false
        var featureHeaderIndex: Int?
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inFeatures = trimmed == "[features]"
                if inFeatures, featureHeaderIndex == nil { featureHeaderIndex = i }
            } else if inFeatures, trimmed.hasPrefix("hooks") {
                let value = trimmed
                    .drop(while: { $0 != "=" })
                    .dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                if value == "true" { return }
                if value == "false" { throw HookError.codexFeatureDisabled }
                return // comment or malformed — treat as present, Codex will warn
            }
            i += 1
        }

        if let header = featureHeaderIndex {
            lines.insert("hooks = true # added by Pigeon", at: header + 1)
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append(contentsOf: [
                "[features] # added by Pigeon",
                "hooks = true",
            ])
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - pi extension

    private static func installPiExtension() throws {
        let dir = piExtensionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try piExtensionSource.write(
            to: piExtensionURL, atomically: true, encoding: .utf8)
    }
}
