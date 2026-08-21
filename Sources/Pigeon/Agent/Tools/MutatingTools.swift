import Foundation

/// Mutating counterpart of RunReadOnlyCommand. Same injection-free shape —
/// argv arrays, allowlisted bare binaries, direct exec, never a shell.
/// Reversible calls (mv, cp, mkdir, chmod, git add/commit/fetch/pull/
/// clone…) run freely; irrecoverable ones (rm, git clean, git reset
/// --hard) and outward-facing ones (git push) stop for user
/// confirmation, with a natural-language `intent` as the prompt.
struct RunMutatingCommand: AgentTool {
    /// Binaries that mutate the filesystem or repository state. The
    /// allowlist keeps the surface intentional: no network, no
    /// interpreters, no installs.
    static let   allowedBinaries: [String] = [
        "mv", "cp", "mkdir", "rmdir", "touch", "ln", "rm", "chmod", "git",
    ]

    /// git subcommands allowed here: working-tree/history edits plus
    /// remote traffic. fetch/pull/clone run freely (recoverable via
    /// reflog at worst); push is outward-facing and asks the user first.
    private static let gitSubcommands: Set<String> = [
        "add", "commit", "restore", "switch", "checkout", "mv", "rm",
        "stash", "tag", "branch", "reset", "clean",
        "fetch", "pull", "push", "clone",
    ]

    /// Same config-injection holes as the read-only tool. --receive-pack
    /// runs locally for file:// remotes — an exec hole, like --upload-pack.
    private static let dangerousGitFlags = [
        "-c", "--exec-path", "--upload-pack", "--receive-pack", "-P",
    ]

    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "run_mutating_command",
            description: """
            Run a command that CHANGES files or repository state (move, \
            copy, delete, mkdir, chmod, git — including fetch, pull, \
            clone, push). Pass argv as arrays (no shell). \
            Allowed binaries: \
            \(Self.allowedBinaries.sorted().joined(separator: ", ")). \
            Reversible operations (and git fetch/pull/clone) run \
            immediately. Destructive or outward-facing ones (rm, git \
            clean, git reset --hard, git push) ask the user first — for \
            those, set `intent` to one short sentence in the user's \
            language saying exactly what happens. Prefer the `trash` tool \
            over rm so files stay recoverable. \
            Example: {"pipeline":[["mv","old.txt","new.txt"]]}.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "pipeline": [
                        "type": "array",
                        "description": "Stages; each stage is an argv array. Usually one stage.",
                        "items": [
                            "type": "array",
                            "items": ["type": "string"],
                        ],
                    ],
                    "intent": [
                        "type": "string",
                        "description": "For destructive calls: one plain-language sentence, in the user's language, describing exactly what will be deleted or lost. Shown to the user for approval.",
                    ],
                ],
                "required": ["pipeline"],
            ])
    }

    /// A call is sensitive when it can destroy data with no way back, or
    /// when it publishes state beyond this machine (git push). Everything
    /// else (mv, cp, mkdir, chmod, git add/commit/fetch/pull/clone…) is
    /// recoverable enough to run freely.
    static func needsConfirmation(_ pipeline: [[String]]) -> Bool {
        for argv in pipeline {
            guard let binary = argv.first else { continue }
            if binary == "rm" { return true }
            if binary == "git" {
                let subcommand = argv.dropFirst().first { !$0.hasPrefix("-") }
                if subcommand == "clean" { return true }
                if subcommand == "push" { return true }
                if subcommand == "reset", argv.contains("--hard") { return true }
            }
        }
        return false
    }

    func confirmationRequest(arguments: [String: Any], cwd: String) -> ConfirmationRequest? {
        guard let pipeline = arguments["pipeline"] as? [[String]],
              Self.needsConfirmation(pipeline) else { return nil }
        let command = Self.displayString(pipeline)
        let intent = (arguments["intent"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ConfirmationRequest(
            message: (intent?.isEmpty == false) ? intent! : "Run: \(command)",
            command: command)
    }

    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult {
        guard let rawStages = arguments["pipeline"] as? [[String]], !rawStages.isEmpty else {
            return AgentToolResult(
                ok: false,
                output: "missing pipeline (array of argv arrays)",
                display: "run_mutating_command: bad args")
        }
        var stages: [ProcessRunner.Stage] = []
        for argv in rawStages {
            guard let first = argv.first, !first.isEmpty else {
                return reject("empty argv stage", display: Self.displayString(rawStages))
            }
            guard let path = ToolBinaries.resolve(first, allowlist: Self.allowedBinaries) else {
                return reject("'\(first)' is not in the mutating allowlist", display: Self.displayString(rawStages))
            }
            if first == "git" {
                if let bad = Self.dangerousGitFlags.first(where: { flag in
                    argv.contains { $0 == flag || $0.hasPrefix(flag + "=") }
                }) {
                    return reject("'\(bad)' is not allowed for git", display: Self.displayString(rawStages))
                }
                if let sub = argv.dropFirst().first(where: { !$0.hasPrefix("-") }),
                   !Self.gitSubcommands.contains(sub) {
                    return reject("git \(sub) is not a local mutating subcommand", display: Self.displayString(rawStages))
                }
            }
            stages.append(.init(path: path, arguments: Array(argv.dropFirst())))
        }

        // Remote git traffic (clone of a real repo, pull over a slow
        // link) can legitimately take minutes; local file operations
        // never should.
        let remoteSubcommands: Set<String> = ["fetch", "pull", "push", "clone"]
        let touchesRemote = rawStages.contains { argv in
            argv.first == "git" && argv.dropFirst().first(where: { !$0.hasPrefix("-") })
                .map(remoteSubcommands.contains) == true
        }
        let result = await ProcessRunner.run(
            pipeline: stages, cwd: cwd,
            timeout: touchesRemote ? 300 : 20, outputLimit: 8_000)
        return AgentToolResult(
            ok: result.exitCode == 0,
            output: result.output.isEmpty ? "(no output, exit \(result.exitCode))" : result.output,
            display: Self.displayString(rawStages))
    }

    private func reject(_ reason: String, display: String) -> AgentToolResult {
        AgentToolResult(ok: false, output: "command rejected: \(reason)", display: "拒绝: \(display) (\(reason))")
    }

    static func displayString(_ stages: [[String]]) -> String {
        stages.map { $0.joined(separator: " ") }.joined(separator: " | ")
    }
}

/// Create or overwrite a text file. Creating is reversible-enough (the
/// worst case is deleting the new file) and runs freely; overwriting an
/// EXISTING file destroys its content and asks the user first.
struct WriteFile: AgentTool {
    static let contentLimit = 256 * 1024

    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "write_file",
            description: """
            Create or overwrite a TEXT file with the given content. \
            Creating a new file runs immediately; overwriting an existing \
            one asks the user first — then set `intent` to one short \
            sentence in the user's language saying which file gets \
            replaced.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path, relative to cwd."],
                    "content": ["type": "string", "description": "Full file content."],
                    "intent": [
                        "type": "string",
                        "description": "When overwriting: plain-language sentence, user's language, shown for approval.",
                    ],
                ],
                "required": ["path", "content"],
            ])
    }

    func confirmationRequest(arguments: [String: Any], cwd: String) -> ConfirmationRequest? {
        guard let raw = arguments["path"] as? String, !raw.isEmpty else { return nil }
        let path = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: cwd)).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let oldBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        let newBytes = (arguments["content"] as? String)?.utf8.count ?? 0
        let intent = (arguments["intent"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Overwrite \(raw) (\(oldBytes.map(String.init) ?? "?") bytes → \(newBytes) bytes)"
        return ConfirmationRequest(
            message: (intent?.isEmpty == false) ? intent! : fallback,
            command: "write_file \(raw) (\(newBytes) bytes, overwrites existing)")
    }

    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult {
        guard let raw = arguments["path"] as? String, !raw.isEmpty,
              let content = arguments["content"] as? String else {
            return AgentToolResult(ok: false, output: "need {path, content}", display: "write_file: bad args")
        }
        guard content.utf8.count <= Self.contentLimit else {
            return AgentToolResult(
                ok: false,
                output: "content too large (\(content.utf8.count) bytes, limit \(Self.contentLimit))",
                display: "write_file \(raw)")
        }
        let path = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: cwd)).path
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return AgentToolResult(
                ok: false,
                output: "write failed: \(error.localizedDescription)",
                display: "write_file \(raw)")
        }
        return AgentToolResult(
            ok: true,
            output: "wrote \(content.utf8.count) bytes to \(path)",
            display: "write_file \(raw) (\(content.utf8.count) bytes)")
    }
}

/// Move files to the macOS Trash — recoverable, so it runs freely. The
/// preferred way for the agent to "delete" anything.
struct TrashItem: AgentTool {
    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "trash",
            description: """
            Move files or directories to the macOS Trash (recoverable via \
            Finder). ALWAYS prefer this over rm when the user asks to \
            delete or clean up something.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "paths": [
                        "type": "array",
                        "description": "Paths to trash, relative to cwd.",
                        "items": ["type": "string"],
                    ],
                ],
                "required": ["paths"],
            ])
    }

    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult {
        guard let raw = arguments["paths"] as? [String], !raw.isEmpty else {
            return AgentToolResult(ok: false, output: "need {paths: [...]}", display: "trash: bad args")
        }
        var trashed: [String] = []
        var failures: [String] = []
        for item in raw {
            let url = URL(fileURLWithPath: item, relativeTo: URL(fileURLWithPath: cwd))
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed.append(item)
            } catch {
                failures.append("\(item): \(error.localizedDescription)")
            }
        }
        let display = "trash \(raw.joined(separator: " "))"
        if failures.isEmpty {
            return AgentToolResult(
                ok: true,
                output: "moved to Trash: \(trashed.joined(separator: ", "))",
                display: display)
        }
        return AgentToolResult(
            ok: trashed.isEmpty ? false : true,
            output: "trashed: \(trashed.joined(separator: ", ")); failed: \(failures.joined(separator: "; "))",
            display: display)
    }
}
