import Foundation

/// Fixture building and check evaluation for eval cases.
enum Checks {
    // MARK: ANSI

    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\u{1B}(?:\\[[0-9;]*[A-Za-z]|\\]8;;[^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\))")

    static func stripANSI(_ text: String) -> String {
        ansiPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    // MARK: Fixtures

    /// Builds a temp cwd from the case's fixture spec: string values are
    /// file contents, `{"repeat": "x", "n": 20000}` generates bulk, keys
    /// ending in "/" create directories.
    static func buildFixture(_ spec: [String: Any]) throws -> String {
        let root = NSTemporaryDirectory() + "pigeon-eval-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        for (name, value) in spec {
            let path = root + "/" + name
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(
                    atPath: path, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            var content = value as? String ?? ""
            if let generator = value as? [String: Any],
               let unit = generator["repeat"] as? String,
               let count = generator["n"] as? Int {
                content = String(repeating: unit, count: count)
            }
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: Check evaluation

    /// Returns failure descriptions (empty = case passed).
    static func run(
        expect: [[String: Any]], raw: String, seconds: Double, cwd: String
    ) -> [String] {
        let text = stripANSI(raw)
        var failures: [String] = []

        for check in expect {
            let kind = check["type"] as? String ?? "?"
            let value = check["value"] as? String ?? ""
            var ok: Bool
            switch kind {
            case "contains":
                ok = text.contains(value)
            case "not_contains":
                ok = !text.contains(value)
            case "regex":
                ok = text.range(of: value, options: .regularExpression) != nil
            case "raw_contains":
                ok = raw.contains(value)
            case "raw_not_contains":
                ok = !raw.contains(value)
            case "count":
                let n = check["n"] as? Int ?? -1
                ok = text.components(separatedBy: value).count - 1 == n
            case "tool_used":
                ok = text.contains("⏺ \(value)")
            case "max_lines":
                let n = check["n"] as? Int ?? 0
                let lines = text.components(separatedBy: "\n").filter {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("⏺")
                }
                ok = lines.count <= n
            case "max_seconds":
                ok = seconds <= (check["n"] as? Double ?? Double(check["n"] as? Int ?? 0))
            case "no_error":
                ok = !text.contains("pigeon:")
            case "fixture_exists":
                let path = cwd + "/" + value
                ok = FileManager.default.fileExists(atPath: path)
                if ok, let needle = check["contains"] as? String {
                    ok = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                        .contains(needle)
                }
            case "fixture_missing":
                ok = !FileManager.default.fileExists(atPath: cwd + "/" + value)
            case "single_trailing_newline":
                ok = text.hasSuffix("\n") && !text.hasSuffix("\n\n")
            default:
                ok = false
            }
            if !ok {
                let extra = check["n"].map { " n=\($0)" } ?? ""
                failures.append("\(kind): '\(value)'\(extra)")
            }
        }
        return failures
    }
}
