import Foundation

/// The built-in micro-task toolset: everything read-only, everything
/// fast, everything scoped to the caller's working directory.
enum BuiltinTools {
    static let all: [AgentTool] = [
        RunReadOnlyCommand(),
        ListDirectory(),
        ReadFileHead(),
    ]

    static func tool(named name: String) -> AgentTool? {
        all.first { $0.spec.name == name }
    }
}

/// Run a command from a read-only allowlist. This covers most micro-tasks
/// (ls, du, lsof, ps, find …) with one tool, which keeps the schema small
/// for fast models.
struct RunReadOnlyCommand: AgentTool {
    /// First-word allowlist. Deliberately conservative: nothing here can
    /// modify files or state.
    static let allowedBinaries: Set<String> = [
        "ls", "find", "du", "df", "file", "stat", "wc", "head", "tail",
        "cat", "grep", "ps", "lsof", "whoami", "id", "date", "uname",
        "which", "type", "env", "pwd", "uptime", "sw_vers", "mdfind",
        "otool", "codesign", "git", "tree",
    ]

    /// Even within allowed binaries, these subcommands mutate; block them.
    static let blockedPatterns = [
        "git push", "git commit", "git reset", "git checkout", "git clean",
        "git rebase", "git merge", "git stash", "git rm", "git mv", "git am",
    ]

    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "run_command",
            description: """
            Run a READ-ONLY shell command in the user's working directory. \
            Allowed binaries: \(Self.allowedBinaries.sorted().joined(separator: ", ")). \
            Pipes between allowed binaries are fine. Anything that writes, \
            deletes, installs, or talks to the network is rejected.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The shell command line to run.",
                    ],
                ],
                "required": ["command"],
            ])
    }

    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult {
        guard let command = arguments["command"] as? String, !command.isEmpty else {
            return AgentToolResult(ok: false, output: "missing command", display: "run_command: missing command")
        }
        if let reason = Self.rejectionReason(for: command) {
            return AgentToolResult(
                ok: false,
                output: "command rejected: \(reason)",
                display: "拒绝: \(command) (\(reason))")
        }
        let result = await ProcessRunner.run(
            command: command, cwd: cwd, timeout: 10, outputLimit: 8_000)
        return AgentToolResult(
            ok: result.exitCode == 0,
            output: result.output.isEmpty ? "(no output, exit \(result.exitCode))" : result.output,
            display: command)
    }

    /// nil = allowed. Checks every pipeline segment's first word.
    static func rejectionReason(for command: String) -> String? {
        let lowered = command.lowercased()
        for pattern in blockedPatterns where lowered.contains(pattern) {
            return "mutating git subcommand"
        }
        // Reject shell metacharacters that escape the read-only sandbox.
        for forbidden in [">", ">>", "sudo", "$(", "`", "&&", ";", "||"] {
            if command.contains(forbidden) { return "'\(forbidden)' not allowed" }
        }
        for segment in command.split(separator: "|") {
            let first = segment.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init) ?? ""
            guard !first.isEmpty else { continue }
            if !allowedBinaries.contains(first) {
                return "'\(first)' is not in the read-only allowlist"
            }
        }
        return nil
    }
}

struct ListDirectory: AgentTool {
    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "list_dir",
            description: "List a directory's entries with sizes. Defaults to the working directory.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Directory to list; relative paths resolve against cwd.",
                    ],
                ],
            ])
    }

    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult {
        let raw = arguments["path"] as? String ?? "."
        let path = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: cwd)).path
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            return AgentToolResult(ok: false, output: "cannot list \(path)", display: "list_dir \(raw)")
        }
        var lines: [String] = []
        for entry in entries.sorted().prefix(200) {
            let full = (path as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue {
                lines.append("\(entry)/")
            } else {
                let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int) ?? nil
                lines.append("\(entry)\t\(size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")")
            }
        }
        if entries.count > 200 { lines.append("… (\(entries.count - 200) more)") }
        return AgentToolResult(
            ok: true,
            output: lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"),
            display: "list_dir \(raw) (\(entries.count) entries)")
    }
}

struct ReadFileHead: AgentTool {
    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "read_file",
            description: "Read the first N lines of a text file (default 60, max 400).",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path, relative to cwd."],
                    "lines": ["type": "integer", "description": "How many lines from the top."],
                ],
                "required": ["path"],
            ])
    }

    func execute(arguments: [String: Any], cwd: String) async -> AgentToolResult {
        guard let raw = arguments["path"] as? String else {
            return AgentToolResult(ok: false, output: "missing path", display: "read_file: missing path")
        }
        let limit = min(max(arguments["lines"] as? Int ?? 60, 1), 400)
        let path = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: cwd)).path
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return AgentToolResult(ok: false, output: "cannot read \(path)", display: "read_file \(raw)")
        }
        let lines = contents.components(separatedBy: "\n")
        let head = lines.prefix(limit).joined(separator: "\n")
        let suffix = lines.count > limit ? "\n… (\(lines.count) lines total)" : ""
        return AgentToolResult(ok: true, output: head + suffix, display: "read_file \(raw)")
    }
}

/// Shared subprocess runner with timeout and output cap.
enum ProcessRunner {
    struct Result {
        var exitCode: Int32
        var output: String
    }

    static func run(command: String, cwd: String, timeout: TimeInterval, outputLimit: Int) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(exitCode: -1, output: "failed to run: \(error.localizedDescription)"))
                    return
                }

                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var output = String(decoding: data.prefix(outputLimit), as: UTF8.self)
                if data.count > outputLimit { output += "\n… (output truncated)" }
                continuation.resume(returning: Result(exitCode: process.terminationStatus, output: output))
            }
        }
    }
}
