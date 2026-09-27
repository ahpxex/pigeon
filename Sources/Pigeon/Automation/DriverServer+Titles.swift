import Foundation

/// Driver routes for AI tab titles and the decision model behind them.
///
///   GET  /titles/state          -> {tabs: [{id, surface, aiTitle, submitCount,
///                                   summarizedSubmitCount, inFlight, titleRequests,
///                                   judgeRequests, lastDecision}]}
///   POST /titles/judge          <- {currentTitle, earlierRequests?, newRequests}
///                               -> TitleChangeJudge decision (same code path as
///                                  the summarizer), 409 when no decision model
///   GET  /agent/systemone       -> {configured, model, overridden}
///   POST /agent/systemone       <- {baseURL, model, apiKey} | {enabled: false}
///                                  in-memory override
///                                  (evals use a mock or none; never persisted)
///   POST /agent/systemone/clear -> drop the override
extension DriverServer {
    @MainActor
    func handleTitlesRoute(_ request: HTTPRequest) -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/titles/state"):
            let tabs = TabManager.all.flatMap(\.tabs).map { tab -> [String: Any] in
                var json = TabTitleSummarizer.shared.debugState(for: tab)
                json["id"] = tab.id.uuidString
                json["surface"] = tab.surfaceView.agentSurfaceID
                return json
            }
            return HTTPResponse(json: ["tabs": tabs])

        case ("GET", "/agent/systemone"):
            let settings = SystemOneSettings.shared
            return HTTPResponse(json: [
                "configured": settings.activeConfig != nil,
                "model": settings.activeConfig?.model as Any,
                "overridden": settings.testOverride != nil,
            ])

        case ("POST", "/agent/systemone"):
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            else { return HTTPResponse(status: 400, error: "body must be JSON") }
            if json["enabled"] as? Bool == false {
                SystemOneSettings.shared.testOverride = .disabled
                return HTTPResponse(json: ["ok": true])
            }
            guard let baseURL = json["baseURL"] as? String,
                  let model = json["model"] as? String,
                  let apiKey = json["apiKey"] as? String
            else {
                return HTTPResponse(
                    status: 400, error: "need {baseURL, model, apiKey} or {enabled: false}")
            }
            SystemOneSettings.shared.testOverride = .config(
                .init(baseURL: baseURL, model: model, apiKey: apiKey))
            return HTTPResponse(json: ["ok": true])

        case ("POST", "/agent/systemone/clear"):
            SystemOneSettings.shared.testOverride = nil
            return HTTPResponse(json: ["ok": true])

        default:
            return nil
        }
    }

    /// Routes that must await network work. Returns nil for every other
    /// route so the synchronous handler takes it.
    @MainActor
    func handleAsyncOnMain(_ request: HTTPRequest) async -> HTTPResponse? {
        guard request.method == "POST", request.path == "/titles/judge" else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let currentTitle = json["currentTitle"] as? String,
              let newRequests = json["newRequests"] as? [String], !newRequests.isEmpty
        else {
            return HTTPResponse(
                status: 400, error: "need {currentTitle, earlierRequests?, newRequests}")
        }
        guard let config = SystemOneSettings.shared.activeConfig else {
            return HTTPResponse(status: 409, error: "decision model not configured")
        }
        let decision = await TitleChangeJudge.judge(
            config: config,
            currentTitle: currentTitle,
            earlierRequests: json["earlierRequests"] as? [String] ?? [],
            newRequests: newRequests)
        return HTTPResponse(json: decision.json)
    }
}
