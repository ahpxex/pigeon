import Foundation

/// What a cmd+clicked link in terminal output refers to.
///
/// Two sources feed it. libghostty's link matcher hands us the text of a
/// regex match: a scheme URL (`https://…`) or a path (`/abs`, `./x`,
/// `~/y`, `$HOME/z`, `src/a.swift:12`) — see `resolve`. For everything the
/// regex can't see (bare names in `ls` output, `` `a.swift` ``, `src/`),
/// SurfaceView falls back to the token under the pointer — see
/// `resolveToken`. Relative paths are relative to the *shell's* cwd, which
/// only the app knows (OSC 7), so resolution happens here.
enum TerminalLink: Equatable {
    /// A URL with a non-file scheme (http, mailto, ssh, …).
    case url(URL)
    /// An existing file or directory on disk.
    case file(FileTarget)
    /// Looked like a path, but nothing exists there — or it is relative
    /// and the tab has no known working directory. Carries the best
    /// expansion of the text for display.
    case missing(String)

    struct FileTarget: Equatable {
        var url: URL
        var isDirectory: Bool
        /// From a `:line[:col]` / `(line[,col])` suffix in the text.
        var line: Int?
        var column: Int?
    }

    /// Resolves regex-matched link text against the tab's working directory.
    static func resolve(
        _ text: String,
        cwd: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> TerminalLink {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Scheme URLs. A path never starts with a letter-led scheme
        // ("src/a:1" has a slash before the colon, so URL finds no
        // scheme), but guard on the first character anyway so ~/, ./,
        // / and $VAR paths can never be mistaken for one.
        var path = raw
        if let first = raw.first, first.isLetter,
           let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty {
            guard url.isFileURL else { return .url(url) }
            path = url.path
        }
        if let target = firstExisting(candidates(for: path), cwd: cwd,
                                      environment: environment, fileManager: fileManager) {
            return .file(target)
        }
        let display = expand(path, cwd: cwd, environment: environment) ?? path
        return .missing(display)
    }

    /// Resolves a whitespace-delimited token from the screen (no regex
    /// match). Unlike `resolve`, only an existing file counts: arbitrary
    /// words are not links, so there is no "missing" result.
    static func resolveToken(
        _ token: String,
        cwd: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> FileTarget? {
        let cleaned = trimDecoration(token)
        var readings = [token]
        if cleaned != token, !cleaned.isEmpty { readings.append(cleaned) }
        return firstExisting(readings.flatMap(candidates), cwd: cwd,
                             environment: environment, fileManager: fileManager)
    }

    // MARK: - Candidates

    struct Candidate: Equatable {
        var path: String
        var line: Int?
        var column: Int?
    }

    /// Readings of the text, most literal first, so a file whose name
    /// really ends in ":12" still wins. Compiler/grep output appends
    /// `:line[:col]` (tsc/MSBuild: `(line,col)`); `git diff` prefixes
    /// `a/` and `b/`.
    static func candidates(for raw: String) -> [Candidate] {
        var result = [Candidate(path: raw)]
        let suffixes = [#":(\d+)(?::(\d+))?$"#, #"\((\d+)(?:,\s*(\d+))?\)$"#]
        for pattern in suffixes {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let whole = Range(match.range, in: raw)
            else { continue }
            let number = { (index: Int) -> Int? in
                Range(match.range(at: index), in: raw).flatMap { Int(raw[$0]) }
            }
            result.append(Candidate(path: String(raw[..<whole.lowerBound]),
                                    line: number(1), column: number(2)))
        }
        for candidate in result where candidate.path.hasPrefix("a/") || candidate.path.hasPrefix("b/") {
            var stripped = candidate
            stripped.path = String(candidate.path.dropFirst(2))
            result.append(stripped)
        }
        return result.filter { !$0.path.isEmpty }
    }

    /// Strips what surrounds a name in prose and listings: quotes,
    /// brackets, trailing punctuation, and `ls -F` type markers (`*@=|`).
    /// A trailing `)` stays when it closes a `(` inside the token, so
    /// `a.ts(12,4)` keeps its location suffix.
    static func trimDecoration(_ token: String) -> String {
        var s = Substring(token)
        let leading: Set<Character> = ["(", "[", "{", "<", "'", "\"", "`"]
        let trailing: Set<Character> = ["]", "}", ">", "'", "\"", "`", ",", ";", ".", "!", "?", "*", "@", "=", "|", ":"]
        while true {
            if let first = s.first, leading.contains(first) {
                s = s.dropFirst()
            } else if let last = s.last, trailing.contains(last) {
                s = s.dropLast()
            } else if s.last == ")", s.filter({ $0 == ")" }).count > s.filter({ $0 == "(" }).count {
                s = s.dropLast()
            } else {
                break
            }
        }
        return String(s)
    }

    private static func firstExisting(
        _ candidates: [Candidate],
        cwd: String?,
        environment: [String: String],
        fileManager: FileManager
    ) -> FileTarget? {
        for candidate in candidates {
            guard let path = expand(candidate.path, cwd: cwd, environment: environment) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let directory = isDirectory.boolValue
            return FileTarget(
                url: URL(fileURLWithPath: path),
                isDirectory: directory,
                line: directory ? nil : candidate.line,
                column: directory ? nil : candidate.column)
        }
        return nil
    }

    /// Expands `~`, `$VAR` / `${VAR}` and makes the path absolute. Nil
    /// when that is impossible: an unknown variable, or a relative path
    /// with no known cwd.
    static func expand(_ path: String, cwd: String?, environment: [String: String]) -> String? {
        var expanded = ""
        var rest = Substring(path)
        let variable = #/^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/#
        while let dollar = rest.firstIndex(of: "$") {
            expanded += rest[..<dollar]
            rest = rest[dollar...]
            guard let match = rest.firstMatch(of: variable) else {
                expanded.append("$")
                rest = rest.dropFirst()
                continue
            }
            let name = String(match.output.1 ?? match.output.2 ?? "")
            // $PWD is the *tab's* directory, not Pigeon's own.
            let value = name == "PWD" ? cwd : (name == "HOME" ? NSHomeDirectory() : environment[name])
            guard let value else { return nil }
            expanded += value
            rest = rest[match.range.upperBound...]
        }
        expanded += rest

        if expanded == "~" || expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + expanded.dropFirst()
        }
        if !expanded.hasPrefix("/") {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            expanded = (cwd as NSString).appendingPathComponent(expanded)
        }
        return (expanded as NSString).standardizingPath
    }
}
