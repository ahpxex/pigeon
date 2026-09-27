import Foundation

// Pigeon agent eval runner. Drives the REAL /ask path of the running app
// (token via the driver's /agent/info). Two kinds of suite:
//
//   regression (deterministic)  cases carry scripted mock-LLM turns; an
//                               in-process mock serves them. No network,
//                               no keys, stable.
//   live (quality)              cases without turns run against a real
//                               provider already configured in Pigeon.
//
// Usage (via the wrapper):
//   scripts/eval                                      # regression
//   scripts/eval --suite evals/cases/live.json --live --provider DeepSeek
//   scripts/eval --only markdown --verbose
//
// Prereq: the app is running under the driver (scripts/pigeonctl launch).
// Every run also asserts the /ask + /confirm auth red lines (missing or
// wrong token, browser Origin, non-loopback Host ⇒ 403).
//
// Case schema: see evals/README.md.

struct Args {
    var suite: String
    var live = false
    var provider = "DeepSeek"
    var model = ""
    var timeout: Double = 90
    var verbose = false
    var only = ""

    static func parse() -> Args {
        // Default suite path relative to this package (works from any cwd).
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // pigeon-eval
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // evals
        var args = Args(suite: packageRoot.appendingPathComponent("cases/regression.json").path)
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--suite": args.suite = iterator.next() ?? args.suite
            case "--live": args.live = true
            case "--provider": args.provider = iterator.next() ?? args.provider
            case "--model": args.model = iterator.next() ?? args.model
            case "--timeout": args.timeout = Double(iterator.next() ?? "") ?? args.timeout
            case "--verbose": args.verbose = true
            case "--only": args.only = iterator.next() ?? args.only
            default:
                FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
                exit(2)
            }
        }
        return args
    }
}

struct CaseResult {
    var name: String
    var seconds: Double
    var failures: [String]
    var raw: String
}

/// Per-run suffix for conversation surfaces: the app's memory outlives
/// eval runs, so reused literal surface keys would leak history between
/// runs and make user_count assertions flaky.
let runID = String(UUID().uuidString.prefix(8))

func runCases(
    _ cases: [[String: Any]], agentPort: Int, token: String, args: Args
) async -> [CaseResult] {
    var results: [CaseResult] = []
    for testCase in cases {
        let name = testCase["name"] as? String ?? "?"
        let fixtureSpec = testCase["fixture"] as? [String: Any]
        let cwd: String
        do {
            cwd = try fixtureSpec.map(Checks.buildFixture)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        } catch {
            results.append(CaseResult(name: name, seconds: 0, failures: ["fixture: \(error)"], raw: ""))
            continue
        }
        defer {
            if fixtureSpec != nil { try? FileManager.default.removeItem(atPath: cwd) }
        }

        let started = Date()
        var failures: [String]
        var raw = ""
        do {
            let response = try await AgentClient.ask(
                port: agentPort,
                token: token,
                prompt: testCase["prompt"] as? String ?? "",
                cwd: cwd,
                timeout: args.timeout,
                confirm: testCase["confirm"] as? String ?? "deny",
                surface: (testCase["surface"] as? String).map { "\($0)-\(runID)" })
            raw = response.raw
            let seconds = Date().timeIntervalSince(started)
            failures = response.status != 200
                ? ["HTTP \(response.status)"]
                : Checks.run(
                    expect: testCase["expect"] as? [[String: Any]] ?? [],
                    raw: raw, seconds: seconds, cwd: cwd)
        } catch {
            failures = ["request error: \(error.localizedDescription)"]
        }
        let seconds = Date().timeIntervalSince(started)

        print("  \(failures.isEmpty ? "PASS" : "FAIL") \(name) (\(String(format: "%.1f", seconds))s)")
        for failure in failures { print("       ✗ \(failure)") }
        results.append(CaseResult(name: name, seconds: seconds, failures: failures, raw: raw))
    }
    return results
}

// MARK: - Main

let args = Args.parse()

let allCases: [[String: Any]]
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: args.suite))
    allCases = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? [])
        .filter { args.only.isEmpty || ($0["name"] as? String ?? "").contains(args.only) }
} catch {
    FileHandle.standardError.write(Data("cannot load suite \(args.suite): \(error)\n".utf8))
    exit(2)
}

// Case kinds: /ask cases (scripted `turns` = mock, else live), title
// judge cases (`judge`; scripted `systemone` = mock, else live), and
// end-to-end title flows (`title_flow`, always mock). See TitleEvals.
let judgeCases = allCases.filter { $0["judge"] != nil }
let mockJudgeCases = judgeCases.filter { $0["systemone"] != nil }
var liveJudgeCases = judgeCases.filter { $0["systemone"] == nil }
let flowCases = allCases.filter { $0["title_flow"] != nil }
let askCases = allCases.filter { $0["judge"] == nil && $0["title_flow"] == nil }
let mockCases = askCases.filter { $0["turns"] != nil }
var liveCases = askCases.filter { $0["turns"] == nil }
let skippedLive = liveCases.count + liveJudgeCases.count
if skippedLive > 0 && !args.live {
    print("note: skipping \(skippedLive) live case(s) — pass --live to run them")
    liveCases = []
    liveJudgeCases = []
}

let info: [String: Any]
do {
    info = try await AgentClient.driver("GET", "/agent/info")
} catch {
    FileHandle.standardError.write(Data("driver unreachable — scripts/pigeonctl launch first (\(error.localizedDescription))\n".utf8))
    exit(2)
}
guard let agentPort = info["port"] as? Int, let token = info["token"] as? String else {
    FileHandle.standardError.write(Data("driver /agent/info returned no port/token\n".utf8))
    exit(2)
}
let savedProvider = info["defaultProvider"] as? String
let savedModel = info["defaultModel"] as? String

print("== security preflight ==")
let securityFailures = await AgentClient.securityPreflight(port: agentPort, token: token)
for failure in securityFailures { print("  FAIL \(failure)") }
if securityFailures.isEmpty {
    print("  PASS /ask and /confirm reject unauthenticated, wrong-token, origin, host probes")
}

var results: [CaseResult] = []
var abortReason: String? = nil
var mock: MockLLM? = nil
var systemOneMock: MockSystemOne? = nil
let savedSettings = try? await AgentClient.driver("GET", "/settings")

do {
    let flowScenarios = TitleEvals.scenarios(for: flowCases)

    if !mockCases.isEmpty || !flowCases.isEmpty {
        let scenarios = mockCases.map { testCase -> [String: Any] in
            ["match": testCase["prompt"] as? String ?? "", "turns": testCase["turns"] ?? []]
        } + flowScenarios.llm
        let started = try await MockLLM.start(scenarios: scenarios)
        mock = started
        _ = try await AgentClient.driver("POST", "/agent/provider", body: [
            "name": "PigeonEvalMock",
            "baseURL": "http://127.0.0.1:\(started.boundPort)/v1",
            "model": "mock-1",
            "apiKey": "eval",
        ])
        if !mockCases.isEmpty {
            print("\n== regression (\(mockCases.count) cases, mock llm :\(started.boundPort)) ==")
            results += await runCases(mockCases, agentPort: agentPort, token: token, args: args)
        }
    }

    if !mockJudgeCases.isEmpty || !flowCases.isEmpty {
        let judgeScenarios = mockJudgeCases.map { testCase -> [String: Any] in
            let newRequests = (testCase["judge"] as? [String: Any])?["newRequests"] as? [String] ?? []
            return ["match": newRequests.joined(separator: "\n"), "answer": testCase["systemone"] ?? [:]]
        } + flowScenarios.systemOne
        let started = try await MockSystemOne.start(scenarios: judgeScenarios)
        systemOneMock = started
        _ = try await AgentClient.driver("POST", "/agent/systemone", body: [
            "baseURL": "http://127.0.0.1:\(started.boundPort)/v1",
            "model": "jev-mock",
            "apiKey": "eval",
        ])
        if !mockJudgeCases.isEmpty {
            print("\n== title judge (\(mockJudgeCases.count) cases, mock system one :\(started.boundPort)) ==")
            results += await TitleEvals.runMockJudgeCases(mockJudgeCases, mock: started)
        }
        if !flowCases.isEmpty {
            _ = try await AgentClient.driver("POST", "/settings", body: ["aiTabTitles": true])
            print("\n== title flows (\(flowCases.count) flows, ~15s per step) ==")
            results += await TitleEvals.runFlows(flowCases, systemOnePort: started.boundPort)
        }
        _ = try await AgentClient.driver("POST", "/agent/systemone/clear")
    }

    if !liveCases.isEmpty {
        _ = try await AgentClient.driver("POST", "/agent/default", body: [
            "name": args.provider, "model": args.model,
        ])
        let modelSuffix = args.model.isEmpty ? "" : "/\(args.model)"
        print("\n== live (\(liveCases.count) cases, \(args.provider)\(modelSuffix)) ==")
        results += await runCases(liveCases, agentPort: agentPort, token: token, args: args)
    }

    if !liveJudgeCases.isEmpty {
        let systemOne = try await AgentClient.driver("GET", "/agent/systemone")
        guard systemOne["configured"] as? Bool == true else {
            throw EvalError("live judge cases need a TypeSafe key in Settings → Agent → Decision Model")
        }
        print("\n== live title judge (\(liveJudgeCases.count) cases, \(systemOne["model"] ?? "?")) ==")
        results += await TitleEvals.runLiveJudgeCases(liveJudgeCases)
    }
} catch {
    abortReason = error.localizedDescription
    FileHandle.standardError.write(Data("eval aborted: \(error.localizedDescription)\n".utf8))
}

// Restore the user's provider and settings state whatever happened above.
mock?.stop()
if mock != nil {
    _ = try? await AgentClient.driver("POST", "/agent/provider/remove", body: ["name": "PigeonEvalMock"])
}
systemOneMock?.stop()
if systemOneMock != nil {
    _ = try? await AgentClient.driver("POST", "/agent/systemone/clear")
}
if let enabled = savedSettings?["aiTabTitles"] as? Bool {
    _ = try? await AgentClient.driver("POST", "/settings", body: ["aiTabTitles": enabled])
}
if let savedProvider {
    _ = try? await AgentClient.driver("POST", "/agent/default", body: [
        "name": savedProvider, "model": savedModel ?? "",
    ])
}

let failed = results.filter { !$0.failures.isEmpty }
let securitySuffix = (securityFailures.isEmpty ? "" : ", security preflight FAILED")
    + (abortReason.map { ", ABORTED: \($0)" } ?? "")
print("\n== summary: \(results.count - failed.count)/\(results.count) cases passed\(securitySuffix) ==")
if args.verbose {
    for result in failed {
        print("\n--- \(result.name) output ---\n\(Checks.stripANSI(result.raw))\n---")
    }
}
exit(failed.isEmpty && securityFailures.isEmpty && abortReason == nil ? 0 : 1)
