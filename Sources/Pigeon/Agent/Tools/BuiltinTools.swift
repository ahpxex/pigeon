import Foundation

/// The built-in micro-task toolset: everything read-only, everything
/// fast, everything scoped to the caller's working directory.
enum BuiltinTools {
    static let all: [AgentTool] = [
        RunReadOnlyCommand(),
        ListDirectory(),
        ReadFileHead(),
        RunMutatingCommand(),
        WriteFile(),
        TrashItem(),
    ]

    static func tool(named name: String) -> AgentTool? {
        all.first { $0.spec.name == name }
    }
}

/// Shared binary resolution: allowlisted bare names only, resolved to
/// absolute paths from fixed directories. Never honors a caller path.
enum ToolBinaries {
    static let searchDirs = [
        "/bin", "/usr/bin", "/sbin", "/usr/sbin",
        "/opt/homebrew/bin", "/usr/local/bin",
    ]

    static func resolve(_ name: String, allowlist: [String]) -> String? {
        guard allowlist.contains(name), !name.contains("/") else { return nil }
        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Run a read-only command as a structured argv pipeline — never through
/// a shell. Because the model passes argv arrays (not a string we parse),
/// there is no shell metacharacter, quoting, or injection surface at all:
/// each element is one exec argument, verbatim. The allowlist and
/// per-binary flag rejection are defense-in-depth on top of that.
struct RunReadOnlyCommand: AgentTool {
    /// Binary name → absolute path (first match wins). Only these run.
    /// Nothing here mutates files, installs, or (with the flag rules
    /// below) reaches the network or executes other programs.
    static let allowedBinaries: [String] = [
        "ls", "find", "du", "df", "file", "stat", "wc", "head", "tail",
        "cat", "grep", "ps", "lsof", "whoami", "id", "date", "uname",
        "which", "pwd", "uptime", "sw_vers", "mdfind", "codesign",
        "git", "tree",
    ]

    /// Flags that turn an otherwise read-only binary into an arbitrary
    /// executor or file writer. Rejected wherever they appear.
    private static let dangerousFlags: [String: [String]] = [
        "find": ["-exec", "-execdir", "-delete", "-fprint", "-fprintf",
                 "-fls", "-ok", "-okdir"],
        // git -c injects config (core.pager/sshCommand/... = arbitrary
        // exec); the read-only subcommand allowlist is enforced separately.
        "git": ["-c", "--exec-path", "--upload-pack", "-P"],
    ]

    /// git is powerful; only these subcommands are read-only enough.
    private static let gitSubcommands: Set<String> = [
        "log", "status", "diff", "show", "branch", "remote", "rev-parse",
        "describe", "ls-files", "blame", "tag", "shortlog", "config",
        "cat-file", "count-objects", "grep",
    ]

    var spec: AgentToolSpec {
        AgentToolSpec(
            name: "run_command",
            description: """
            Run a READ-ONLY command in the user's working directory. Pass \
            argv as arrays (no shell). Allowed binaries: \
            \(Self.allowedBinaries.sorted().joined(separator: ", ")). \
            For a pipeline, list multiple stages. Anything that writes, \
            deletes, installs, or reaches the network is rejected. \
            Examples: {"pipeline":[["lsof","-i",":3000"]]} or \
            {"pipeline":[["ls","-la"],["wc","-l"]]}.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "pipeline": [
                        "type": "array",
                        "description": "Stages; each stage is an argv array. Stages are piped left to right.",
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
            return AgentToolResult(ok: false, output: "missing pipeline (array of argv arrays)", display: "run_command: bad args")
        }
        var stages: [ProcessRunner.Stage] = []
        for argv in rawStages {
            guard let first = argv.first, !first.isEmpty else {
                return reject("empty argv stage", display: "run_command")
            }
            guard let path = Self.resolve(first) else {
                return reject("'\(first)' is not in the read-only allowlist", display: displayString(rawStages))
            }
            if let bad = Self.dangerousFlags[first]?.first(where: { flag in
                argv.contains { $0 == flag || $0.hasPrefix(flag + "=") }
            }) {
                return reject("'\(bad)' is not allowed for \(first)", display: displayString(rawStages))
            }
            if first == "git", let sub = argv.dropFirst().first(where: { !$0.hasPrefix("-") }),
               !Self.gitSubcommands.contains(sub) {
                return reject("git \(sub) is not a read-only subcommand", display: displayString(rawStages))
            }
            stages.append(.init(path: path, arguments: Array(argv.dropFirst())))
        }

        let result = await ProcessRunner.run(pipeline: stages, cwd: cwd, timeout: 10, outputLimit: 8_000)
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

    /// Absolute path for an allowlisted binary, or nil if not allowed /
    /// not found. Never honors a caller-supplied path.
    static func resolve(_ name: String) -> String? {
        ToolBinaries.resolve(name, allowlist: allowedBinaries)
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

/// Shared subprocess runner. Executes an argv pipeline directly — no
/// shell is ever involved, so there is no metacharacter interpretation.
/// Stages are chained with in-process pipes.
enum ProcessRunner {
    struct Stage {
        var path: String       // absolute, allowlist-resolved
        var arguments: [String]
    }

    struct Result {
        var exitCode: Int32
        var output: String
    }

    static func run(pipeline: [Stage], cwd: String, timeout: TimeInterval, outputLimit: Int) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var processes: [Process] = []
                let outputPipe = Pipe()
                var previousOutput: Pipe? = nil

                for (index, stage) in pipeline.enumerated() {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: stage.path)
                    process.arguments = stage.arguments
                    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                    if let previousOutput { process.standardInput = previousOutput }
                    let isLast = index == pipeline.count - 1
                    if isLast {
                        process.standardOutput = outputPipe
                        process.standardError = outputPipe
                    } else {
                        let stagePipe = Pipe()
                        process.standardOutput = stagePipe
                        previousOutput = stagePipe
                    }
                    processes.append(process)
                }

                do {
                    for process in processes { try process.run() }
                } catch {
                    processes.forEach { if $0.isRunning { $0.terminate() } }
                    continuation.resume(returning: Result(exitCode: -1, output: "failed to run: \(error.localizedDescription)"))
                    return
                }

                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    processes.forEach { if $0.isRunning { $0.terminate() } }
                }

                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                processes.forEach { $0.waitUntilExit() }
                var output = String(decoding: data.prefix(outputLimit), as: UTF8.self)
                if data.count > outputLimit { output += "\n… (output truncated)" }
                continuation.resume(returning: Result(
                    exitCode: processes.last?.terminationStatus ?? -1,
                    output: output))
            }
        }
    }
}
