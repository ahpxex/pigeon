import Foundation

/// Client for TypeSafe's System One endpoint (`POST {base}/systemone`).
/// Its model (Jev) does not generate text: it evaluates typed questions
/// against a JSON `state` and returns calibrated answers — a Noul is the
/// probability a statement is true, a Choice picks one option and carries
/// the full distribution plus a confidence. Pigeon uses it where code
/// needs a cheap gut-check decision (input tokens only, output is free)
/// rather than prose.
///
/// Same contract as ChatStreamClient: this NEVER throws. Request,
/// network, and protocol failures come back as `.failed` so callers only
/// handle one shape.
enum SystemOneClient {
    enum Question {
        /// A yes/no statement; answered with P(true).
        case noul(instructions: String, whenTrue: String? = nil, whenFalse: String? = nil)
        /// Pick one option; `criteria` maps option key → description.
        case choice(instructions: String, criteria: [String: String])

        var wireFormat: [String: Any] {
            switch self {
            case .noul(let instructions, let whenTrue, let whenFalse):
                var question: [String: Any] = ["type": "noul", "instructions": instructions]
                var criteria: [String: Any] = [:]
                if let whenTrue { criteria["true"] = whenTrue }
                if let whenFalse { criteria["false"] = whenFalse }
                if !criteria.isEmpty { question["criteria"] = criteria }
                return question
            case .choice(let instructions, let criteria):
                return ["type": "choice", "instructions": instructions, "criteria": criteria]
            }
        }
    }

    enum Answer: Equatable {
        case noul(Double)
        case choice(String, probabilities: [String: Double], confidence: Double)
    }

    enum Outcome {
        /// `model` is the versioned ID that answered (aliases resolve).
        case answered([String: Answer], model: String)
        case failed(String)
    }

    struct Request {
        var baseURL: String
        var apiKey: String
        var model: String
        /// JSON object: the material every question is evaluated against.
        var state: [String: Any]
        var questions: [String: Question]
        /// Callers use this as a gate in front of other work; a slow
        /// answer is worth less than falling back.
        var timeout: TimeInterval = 15
    }

    static func evaluate(_ request: Request) async -> Outcome {
        guard let base = URL(string: request.baseURL) else {
            return .failed("invalid base URL: \(request.baseURL)")
        }
        var urlRequest = URLRequest(url: base.appendingPathComponent("systemone"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = request.timeout

        let body: [String: Any] = [
            "model": request.model,
            "state": request.state,
            "questions": request.questions.mapValues(\.wireFormat),
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let encoded = try? JSONSerialization.data(withJSONObject: body)
        else { return .failed("failed to encode request") }
        urlRequest.httpBody = encoded

        let data: Data
        do {
            let (received, response) = try await URLSession.shared.data(for: urlRequest)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let detail = String(decoding: received.prefix(2000), as: UTF8.self)
                return .failed("HTTP \(http.statusCode): \(detail)")
            }
            data = received
        } catch is CancellationError {
            return .failed("aborted")
        } catch {
            return .failed(error.localizedDescription)
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawAnswers = json["answers"] as? [String: [String: Any]]
        else { return .failed("malformed response: no answers") }

        var answers: [String: Answer] = [:]
        for (id, raw) in rawAnswers {
            switch raw["type"] as? String {
            case "noul":
                guard let value = number(raw["noul"]) else { continue }
                answers[id] = .noul(value)
            case "choice":
                guard let choice = raw["choice"] as? String,
                      let confidence = number(raw["confidence"])
                else { continue }
                let probabilities = (raw["probabilities"] as? [String: Any] ?? [:])
                    .compactMapValues(number)
                answers[id] = .choice(
                    choice, probabilities: probabilities, confidence: confidence)
            default:
                continue
            }
        }
        // Every asked question must come back typed as asked; a partial
        // answer set is a protocol failure, not a decision.
        for (id, question) in request.questions {
            switch (question, answers[id]) {
            case (.noul, .noul?), (.choice, .choice?): continue
            default: return .failed("missing or mistyped answer for \(id)")
            }
        }
        return .answered(answers, model: json["model"] as? String ?? request.model)
    }

    /// Model names the account can send (`GET {base}/models`).
    static func listModels(baseURL: String, apiKey: String) async -> Result<[String], ModelListError> {
        guard let base = URL(string: baseURL) else { return .failure(.badURL) }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failure(.badResponse(http.statusCode))
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entries = json["models"] as? [[String: Any]]
            else { return .failure(.noModels) }
            let names = entries.compactMap { $0["name"] as? String }.sorted()
            return names.isEmpty ? .failure(.noModels) : .success(names)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    enum ModelListError: LocalizedError {
        case badURL
        case badResponse(Int)
        case noModels
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid base URL"
            case .badResponse(let code): return "HTTP \(code)"
            case .noModels: return "No models in response"
            case .network(let message): return message
            }
        }
    }

    /// JSON numbers arrive as NSNumber (Int or Double); accept both.
    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
