import Foundation

/// Decides whether a coding-agent submission changes what a tab is
/// about, so the (generative, comparatively costly) title model only runs
/// when the title could actually change. Follow-ups such as "继续",
/// "yes", or "also fix the test" keep the existing title for the price
/// of one System One call — input tokens only, no generation.
///
/// Confidence-gated: the title is only kept when Jev is confident the
/// new requests continue the same task AND independently agrees the
/// current title still fits. Anything else — a new task, a split or
/// low-confidence answer, a failed call — regenerates, which is exactly
/// the behavior without a decision model. A wrong call can therefore
/// only cost one extra title request, never freeze a stale title on
/// uncertain evidence.
enum TitleChangeJudge {
    enum Verdict: String {
        /// Confident continuation: keep the current title.
        case keep
        /// Confident change of task: regenerate.
        case retitle
        /// Evidence split, low confidence, or the call failed: fall back
        /// to regenerating.
        case undecided
    }

    struct Decision {
        var verdict: Verdict
        var relation: String?
        var relationConfidence: Double?
        var titleFits: Double?
        var model: String?
        var error: String?
        var seconds: Double

        var json: [String: Any] {
            [
                "verdict": verdict.rawValue,
                "relation": relation as Any,
                "relationConfidence": relationConfidence as Any,
                "titleFits": titleFits as Any,
                "model": model as Any,
                "error": error as Any,
                "seconds": seconds,
            ]
        }
    }

    // Calibrated on evals/cases/titles-live.json against jev-1.13
    // (2026-09-27, 35 labeled zh/en prompts): real continuations scored
    // relation confidence ≥ 0.87 and title_fits ≥ 0.83, while every
    // task change stayed ≤ 0.61 / ≤ 0.58 — the near misses being mixed
    // "ok, and now do X" prompts. Both thresholds sit mid-gap, so run-to-
    // run jitter (±0.1 observed at the boundary) can't flip a keep.
    // Re-run the live suite before moving them or the model version.

    /// Minimum Choice confidence to act on the relation answer.
    static let minRelationConfidence = 0.75
    /// Minimum P(new requests are part of the titled work) to keep it.
    static let minTitleFits = 0.7

    static func judge(
        config: SystemOneSettings.Config,
        currentTitle: String,
        earlierRequests: [String],
        newRequests: [String]
    ) async -> Decision {
        let started = Date()
        // Only the three fields the questions refer to: unrelated
        // material (terminal output, paths) is a distractor for Jev.
        let state: [String: Any] = [
            "current_title": currentTitle,
            "earlier_requests": earlierRequests,
            "new_requests": newRequests,
        ]
        let outcome = await SystemOneClient.evaluate(.init(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            state: state,
            questions: [
                "relation": .choice(
                    instructions: """
                    A user is working with a coding agent in a terminal tab titled \
                    `current_title`. `earlier_requests` are the user's earlier messages \
                    to the agent, oldest first; `new_requests` are the messages sent \
                    since the title was chosen. Do `new_requests` continue the task \
                    that `current_title` names, or start a different task?
                    """,
                    criteria: [
                        "same_task": """
                        `new_requests` continue the same task: confirmations or approvals \
                        (for example "yes", "ok", "go ahead", "继续", "好的", "可以"), \
                        answers to the agent's questions, requests to retry, continue, \
                        or explain, and fixes, tweaks, tests, or next steps for the same \
                        feature, bug, or goal.
                        """,
                        "new_task": """
                        `new_requests` start a task that `current_title` does not \
                        describe: a different feature, bug, file, topic, or goal, even \
                        within the same project.
                        """,
                    ]),
                // Worded as "part of the work", not "an accurate name for":
                // Jev reads literally, and "explain that" or "retry" are
                // not literally named by a title like "optimize page load"
                // even though they belong to that work (live eval, jev-1.13).
                "title_fits": .noul(
                    instructions: """
                    `new_requests` are part of the work that `current_title` names.
                    """,
                    whenTrue: """
                    `new_requests` ask to continue, confirm, retry, explain, test, \
                    commit, document, or refine the work that `current_title` names, \
                    even without repeating its words.
                    """,
                    whenFalse: """
                    `new_requests` ask for work toward a goal that `current_title` \
                    does not name.
                    """),
            ]))
        let seconds = Date().timeIntervalSince(started)

        switch outcome {
        case .failed(let error):
            return Decision(verdict: .undecided, error: error, seconds: seconds)

        case .answered(let answers, let model):
            guard case .choice(let relation, _, let confidence)? = answers["relation"],
                  case .noul(let fits)? = answers["title_fits"]
            else {
                // SystemOneClient guarantees typed answers for every
                // question; this is unreachable short of a client bug.
                return Decision(
                    verdict: .undecided, model: model,
                    error: "answers missing", seconds: seconds)
            }
            let verdict: Verdict
            if relation == "same_task", confidence >= minRelationConfidence,
               fits >= minTitleFits {
                verdict = .keep
            } else if relation == "new_task", confidence >= minRelationConfidence {
                verdict = .retitle
            } else {
                verdict = .undecided
            }
            return Decision(
                verdict: verdict, relation: relation, relationConfidence: confidence,
                titleFits: fits, model: model, seconds: seconds)
        }
    }
}
