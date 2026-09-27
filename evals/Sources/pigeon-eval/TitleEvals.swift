import Foundation

/// AI tab title evals. Three case kinds (see evals/README.md):
///
///   judge (mock)   `judge` + `systemone`: TitleChangeJudge's routing via
///                  the driver's /titles/judge against MockSystemOne —
///                  verdict thresholds, failure fallbacks, wire shape.
///   title_flow     End to end through TabTitleSummarizer: activity hooks
///                  (driver /tabs/activity) on a real tab, mock title LLM,
///                  mock decision model; asserts which model ran per
///                  submission and the resulting title.
///   judge (live)   `judge` + `expect` keep|change, no `systemone`: the
///                  real configured decision model on labeled prompts.
///                  Reports the probabilities for threshold calibration.
enum TitleEvals {
    // MARK: Mock judge cases

    static func runMockJudgeCases(
        _ cases: [[String: Any]], mock: MockSystemOne
    ) async -> [CaseResult] {
        var results: [CaseResult] = []
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            let judge = testCase["judge"] as? [String: Any] ?? [:]
            let started = Date()
            var failures: [String] = []
            var raw = ""
            do {
                let decision = try await AgentClient.driver("POST", "/titles/judge", body: judge)
                raw = describe(decision)
                let verdict = decision["verdict"] as? String
                if let expected = testCase["expect_verdict"] as? String, verdict != expected {
                    failures.append("verdict \(verdict ?? "nil"), expected \(expected)")
                }
                let hasError = !(decision["error"] is NSNull) && decision["error"] != nil
                if let expectError = testCase["expect_error"] as? Bool, hasError != expectError {
                    failures.append(expectError ? "expected an error, got none" : "unexpected error: \(decision["error"]!)")
                }
                failures += wireShapeFailures(
                    of: mock.requests.last {
                        ($0["state"] as? [String: Any])?["new_requests"] as? [String]
                            == judge["newRequests"] as? [String]
                    },
                    for: judge)
            } catch {
                failures.append("request error: \(error.localizedDescription)")
            }
            results.append(report(name, started: started, failures: failures, raw: raw))
        }
        return results
    }

    /// The request the app sent must carry exactly the judge input as
    /// state and the two typed questions the verdict logic reads.
    private static func wireShapeFailures(
        of body: [String: Any]?, for judge: [String: Any]
    ) -> [String] {
        guard let body else { return ["mock received no request for this case"] }
        var failures: [String] = []
        let state = body["state"] as? [String: Any] ?? [:]
        if state["current_title"] as? String != judge["currentTitle"] as? String {
            failures.append("state.current_title mismatch")
        }
        if state["earlier_requests"] as? [String] != (judge["earlierRequests"] as? [String] ?? []) {
            failures.append("state.earlier_requests mismatch")
        }
        if Set(state.keys) != ["current_title", "earlier_requests", "new_requests"] {
            failures.append("state carries unexpected keys: \(state.keys.sorted())")
        }
        let questions = body["questions"] as? [String: [String: Any]] ?? [:]
        let relation = questions["relation"] ?? [:]
        if relation["type"] as? String != "choice"
            || Set((relation["criteria"] as? [String: Any] ?? [:]).keys) != ["same_task", "new_task"] {
            failures.append("relation question is not a same_task/new_task choice")
        }
        if questions["title_fits"]?["type"] as? String != "noul" {
            failures.append("title_fits question is not a noul")
        }
        if (body["model"] as? String ?? "").isEmpty {
            failures.append("request has no model")
        }
        return failures
    }

    // MARK: End-to-end title flows

    /// Mock-LLM and mock-System-One scenarios for every flow step. The
    /// title request carries all recent prompts, so later steps' markers
    /// must win: scenarios are ordered newest step first.
    static func scenarios(for flows: [[String: Any]]) -> (llm: [[String: Any]], systemOne: [[String: Any]]) {
        var llm: [[String: Any]] = []
        var systemOne: [[String: Any]] = []
        for flow in flows {
            for step in (flow["title_flow"] as? [[String: Any]] ?? []).reversed() {
                let prompt = step["prompt"] as? String ?? ""
                if let title = step["llm_title"] as? String {
                    llm.append(["match": prompt, "turns": [["text": title]]])
                }
                if let answer = step["systemone"] as? [String: Any] {
                    systemOne.append(["match": prompt, "answer": answer])
                }
            }
        }
        return (llm, systemOne)
    }

    static func runFlows(
        _ flows: [[String: Any]], systemOnePort: UInt16
    ) async -> [CaseResult] {
        var results: [CaseResult] = []
        for flow in flows {
            let name = flow["name"] as? String ?? "?"
            let started = Date()
            var failures: [String] = []
            var log: [String] = []
            var tabID: String?
            do {
                let created = try await AgentClient.driver("POST", "/tabs/new")
                tabID = created["id"] as? String
                guard let tabID, let surface = try await titleState(tab: tabID)?["surface"] as? String
                else { throw EvalError("new tab has no surface") }
                // The shell must be up so the screen tail isn't empty.
                try await Task.sleep(nanoseconds: 1_500_000_000)

                for (index, step) in (flow["title_flow"] as? [[String: Any]] ?? []).enumerated() {
                    let useDecisionModel = step["decision_model"] as? Bool ?? true
                    try await setDecisionModel(enabled: useDecisionModel, port: systemOnePort)

                    let prompt = step["prompt"] as? String ?? ""
                    _ = try await AgentClient.driver("POST", "/tabs/activity", body: [
                        "surface": surface, "event": "busy", "prompt": prompt, "source": "eval",
                    ])
                    // Past the summarizer's minimum work time, then done.
                    try await Task.sleep(nanoseconds: 3_500_000_000)
                    _ = try await AgentClient.driver("POST", "/tabs/activity", body: [
                        "surface": surface, "event": "idle", "source": "eval",
                    ])

                    let expect = step["expect"] as? [String: Any] ?? [:]
                    let state = try await waitForTitleState(tab: tabID, expect: expect)
                    log.append("step \(index + 1): \(describe(state))")
                    failures += flowFailures(state: state, expect: expect)
                        .map { "step \(index + 1): \($0)" }
                    if !failures.isEmpty { break }
                }
            } catch {
                failures.append("flow error: \(error.localizedDescription)")
            }
            if let tabID {
                _ = try? await AgentClient.driver("POST", "/tabs/close", body: ["id": tabID])
            }
            results.append(report(
                name, started: started, failures: failures, raw: log.joined(separator: "\n")))
        }
        return results
    }

    private static func setDecisionModel(enabled: Bool, port: UInt16) async throws {
        if enabled {
            _ = try await AgentClient.driver("POST", "/agent/systemone", body: [
                "baseURL": "http://127.0.0.1:\(port)/v1", "model": "jev-mock", "apiKey": "eval",
            ])
        } else {
            // Explicitly off — clearing the override would fall back to
            // the user's real key, if one is configured.
            _ = try await AgentClient.driver("POST", "/agent/systemone", body: ["enabled": false])
        }
    }

    private static func titleState(tab: String) async throws -> [String: Any]? {
        let state = try await AgentClient.driver("GET", "/titles/state")
        return (state["tabs"] as? [[String: Any]])?.first { $0["id"] as? String == tab }
    }

    /// Polls until the summarizer settled on the expected request counts
    /// (tick 5s + settle 4s after idle), or times out and returns the
    /// last state for the failure message.
    private static func waitForTitleState(
        tab: String, expect: [String: Any]
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(25)
        var last: [String: Any] = [:]
        while Date() < deadline {
            if let state = try await titleState(tab: tab) {
                last = state
                if state["inFlight"] as? Bool == false,
                   state["titleRequests"] as? Int == expect["titleRequests"] as? Int,
                   state["judgeRequests"] as? Int == expect["judgeRequests"] as? Int {
                    return state
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return last
    }

    private static func flowFailures(state: [String: Any], expect: [String: Any]) -> [String] {
        var failures: [String] = []
        for key in ["titleRequests", "judgeRequests"] {
            if let want = expect[key] as? Int, state[key] as? Int != want {
                failures.append("\(key) \(state[key] ?? "nil"), expected \(want)")
            }
        }
        if let want = expect["aiTitle"] as? String, state["aiTitle"] as? String != want {
            failures.append("aiTitle \(state["aiTitle"] ?? "nil"), expected \(want)")
        }
        if let want = expect["verdict"] as? String {
            let got = (state["lastDecision"] as? [String: Any])?["verdict"] as? String
            if got != want { failures.append("verdict \(got ?? "nil"), expected \(want)") }
        }
        return failures
    }

    // MARK: Live judge cases

    static func runLiveJudgeCases(_ cases: [[String: Any]]) async -> [CaseResult] {
        var results: [CaseResult] = []
        var falseKeeps = 0, missedKeeps = 0, keeps = 0, changes = 0
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            let expected = testCase["expect"] as? String ?? "change"
            let started = Date()
            var failures: [String] = []
            var raw = ""
            do {
                let decision = try await AgentClient.driver(
                    "POST", "/titles/judge", body: testCase["judge"] as? [String: Any] ?? [:])
                raw = describe(decision)
                let kept = decision["verdict"] as? String == "keep"
                if expected == "keep" {
                    keeps += 1
                    // Efficiency, not correctness: the fallback just
                    // regenerates. Counted in the summary line, not failed.
                    if !kept {
                        missedKeeps += 1
                        raw = "MISSED KEEP (extra title call) " + raw
                    }
                } else {
                    changes += 1
                    if kept { falseKeeps += 1; failures.append("FALSE KEEP (stale title): \(raw)") }
                }
            } catch {
                failures.append("request error: \(error.localizedDescription)")
            }
            let result = report(name, started: started, failures: failures, raw: raw)
            if failures.isEmpty { print("       \(raw)") }
            results.append(result)
        }
        print("  judge: \(falseKeeps)/\(changes) false keeps (stale titles), "
            + "\(missedKeeps)/\(keeps) missed keeps (extra title calls)")
        return results
    }

    // MARK: Helpers

    private static func describe(_ json: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func report(
        _ name: String, started: Date, failures: [String], raw: String
    ) -> CaseResult {
        let seconds = Date().timeIntervalSince(started)
        print("  \(failures.isEmpty ? "PASS" : "FAIL") \(name) (\(String(format: "%.1f", seconds))s)")
        for failure in failures { print("       ✗ \(failure)") }
        return CaseResult(name: name, seconds: seconds, failures: failures, raw: raw)
    }
}
