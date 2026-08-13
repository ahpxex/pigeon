import Foundation

/// Mutating counterpart of RunReadOnlyCommand. Same injection-free shape —
/// argv arrays, allowlisted bare binaries, direct exec, never a shell —
/// but these binaries change things, so `requiresConfirmation` gates every
/// call behind an explicit user yes/no showing the exact argv.
struct RunMutatingCommand: AgentTool {
    /// Binaries that mutate the filesystem or repository state. The
    /// confirmation prompt is the safety boundary; this list just keeps
    /// the surface intentional (no network, no interpreters, no installs).
    static let allowedBinaries: [String] = [
        "mv", "cp", "mkdir", "rmdir", "touch", "ln", "rm", "chmod", "git",
    ]

    /// git subcommands allowed here: local working-tree/history edits.
    /// Nothing that talks to a remote (push/pull/fetch) — the agent's
    /// blast radius stays on this machine.
    private static let gitSubcommands: Set<String> = [
        "add", "commit", "restore", "switch", "checkout", "mv", "rm",
        "stash", "tag", "branch", "reset", "clean",
    ]

    /// Same config-injection holes as the read-only tool.
    private static let dangerousGitFlags = ["-c", "--exec-path", "--upload-pack", "-P"]

    var requiresConfirmation: Bool { true }

    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "run_mutating_command",
            description: """
            Run a command that CHANGES files (move, copy, delete, mkdir, \
            chmod, local git operations). Pass argv as arrays (no shell). \
            Allowed binaries: \
            \(Self.allowedBinaries.sorted().joined(separator: ", ")). \
            Every call is shown to the user for confirmation before it \
            runs, so only call this when the user asked for a change, and \
            keep each call minimal. Use read-only tools for questions. \
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
                ],
                "required": ["pipeline"],
            ])
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
                return reject("empty argv stage", display: displayString(rawStages))
            }
            guard let path = ToolBinaries.resolve(first, allowlist: Self.allowedBinaries) else {
                return reject("'\(first)' is not in the mutating allowlist", display: displayString(rawStages))
            }
            if first == "git" {
                if let bad = Self.dangerousGitFlags.first(where: { flag in
                    argv.contains { $0 == flag || $0.hasPrefix(flag + "=") }
                }) {
                    return reject("'\(bad)' is not allowed for git", display: displayString(rawStages))
                }
                if let sub = argv.dropFirst().first(where: { !$0.hasPrefix("-") }),
                   !Self.gitSubcommands.contains(sub) {
                    return reject("git \(sub) is not a local mutating subcommand", display: displayString(rawStages))
                }
            }
            stages.append(.init(path: path, arguments: Array(argv.dropFirst())))
        }

        let result = await ProcessRunner.run(pipeline: stages, cwd: cwd, timeout: 20, outputLimit: 8_000)
        return AgentToolResult(
            ok: result.exitCode == 0,
            output: result.output.isEmpty ? "(no output, exit \(result.exitCode))" : result.output,
            display: displayString(rawStages))
    }

    private func reject(_ reason: String, display: String) -> AgentToolResult {
        AgentToolResult(ok: false, output: "command rejected: \(reason)", display: "拒绝: \(display) (\(reason))")
    }

    private func displayString(_ stages: [[String]]) -> String {
        stages.map { $0.joined(separator: " ") }.joined(separator: " | ")
    }
}

/// Create or overwrite a text file. Confirmation shows the path, size and
/// whether an existing file would be replaced.
struct WriteFile: AgentTool {
    static let contentLimit = 256 * 1024

    var requiresConfirmation: Bool { true }

    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "write_file",
            description: """
            Create or overwrite a TEXT file with the given content. The \
            user confirms before anything is written. Use for "write me a \
            .gitignore" style requests; use run_mutating_command for \
            moves/renames/deletes.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path, relative to cwd."],
                    "content": ["type": "string", "description": "Full file content."],
                ],
                "required": ["path", "content"],
            ])
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

    /// Confirmation line: make "this will replace an existing file"
    /// visible before the user answers.
    static func confirmSummary(arguments: [String: Any], cwd: String) -> String {
        let raw = arguments["path"] as? String ?? "?"
        let bytes = (arguments["content"] as? String)?.utf8.count ?? 0
        let path = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: cwd)).path
        let exists = FileManager.default.fileExists(atPath: path)
        return "write_file \(raw) (\(bytes) bytes\(exists ? ", overwrites existing file" : ", new file"))"
    }
}
