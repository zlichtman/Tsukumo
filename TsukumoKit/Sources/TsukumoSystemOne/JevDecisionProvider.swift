import Foundation

/// Jev, TypeSafe's hosted System One model, behind `DecisionProvider` (ported from the app).
/// Contract (TypeSafe 0.2.0): `POST /v1/systemone` with `Authorization: Bearer <key>` and
/// `{state, model, questions}`, where each named question is `choice` (criteria keyed by choice),
/// `noul` (yes/no, criteria `false`/`true`), or `score` (ordered criteria). Answers come back under
/// the same names with probabilities; `model` names the model that answered.
///
/// It receives only the decision packet: the request's words, the questions, and the choices.
/// `SystemOne.decide` checks the policy before every call.
public struct JevDecisionProvider: DecisionProvider {
    public static let host = "api.typesafe.ai"
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let defaultModel = "jev-latest"
    /// The longest a decision waits for Jev before the caller falls back.
    public static let timeout: TimeInterval = 5

    let key: String
    let model: String
    let endpoint: URL
    let session: URLSession
    public var modelVersion: String { "Jev · " + model }

    public init(key: String, model: String = JevDecisionProvider.defaultModel, endpoint: URL = JevDecisionProvider.endpoint,
                session: URLSession = .shared) {
        self.key = key; self.model = model; self.endpoint = endpoint; self.session = session
    }

    /// Jev as a hosted service System One asks after Laya.
    public static func remote(key: String, session: URLSession = .shared) -> RemoteDecider {
        RemoteDecider(source: "jev", host: host, provider: JevDecisionProvider(key: key, session: session))
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        try request.validate()
        try Task.checkCancellation()
        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.timeoutInterval = min(Self.timeout, max(0.5, request.deadline.timeIntervalSinceNow))
        http.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.httpBody = try Self.body(for: request, model: model)
        let (data, response) = try await session.data(for: http)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw DecisionError.unavailable }
        switch status {
        case 200: break
        case 401, 403: throw RemoteDecisionError.keyRejected
        case 422: throw DecisionError.invalidInput
        case 429: throw RemoteDecisionError.limited
        default: throw RemoteDecisionError.status(status)
        }
        return try Self.parse(data, for: request)
    }

    /// The whole packet: the request's words, the model name, and each question with its choices.
    public static func body(for request: DecisionRequest, model: String) throws -> Data {
        var questions: [String: Any] = [:]
        for question in request.questions {
            switch question.kind {
            case .choice:
                questions[question.id] = ["type": "choice", "instructions": question.instruction,
                                          "criteria": Dictionary(uniqueKeysWithValues: question.options.map { ($0, NSNull()) })] as [String: Any]
            case .probability:
                questions[question.id] = ["type": "noul", "instructions": question.instruction,
                                          "criteria": ["false": question.options[0], "true": question.options[1]]] as [String: Any]
            case .score:
                questions[question.id] = ["type": "score", "instructions": question.instruction, "criteria": question.options] as [String: Any]
            }
        }
        return try JSONSerialization.data(withJSONObject: ["state": request.state, "model": model, "questions": questions], options: [.sortedKeys])
    }

    /// Probabilities in the question's option order, renormalized; anything missing, extra,
    /// negative, or not finite is refused rather than guessed.
    public static func parse(_ data: Data, for request: DecisionRequest) throws -> DecisionResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? String, !model.isEmpty, model.count <= 80,
              let answers = object["answers"] as? [String: Any] else { throw DecisionError.invalidOutput }
        var parsed: [DecisionAnswer] = []
        for question in request.questions {
            guard let answer = answers[question.id] as? [String: Any], let type = answer["type"] as? String else { throw DecisionError.invalidOutput }
            var values: [Double]
            switch question.kind {
            case .choice:
                guard type == "choice", let probabilities = answer["probabilities"] as? [String: Any],
                      Set(probabilities.keys) == Set(question.options) else { throw DecisionError.invalidOutput }
                values = try question.options.map { try number(probabilities[$0]) }
            case .probability:
                guard type == "noul" else { throw DecisionError.invalidOutput }
                let yes = try number(answer["noul"])
                values = [1 - yes, yes]
            case .score:
                guard type == "score", let probabilities = answer["probabilities"] as? [String: Any],
                      Set(probabilities.keys) == Set(question.options.indices.map(String.init)) else { throw DecisionError.invalidOutput }
                values = try question.options.indices.map { try number(probabilities[String($0)]) }
            }
            let total = values.reduce(0, +)
            guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1.0001 }), total > 0.5, total < 1.5 else { throw DecisionError.invalidOutput }
            parsed.append(DecisionAnswer(questionID: question.id, probabilities: values.map { min(1, $0 / total) }))
        }
        let result = DecisionResult(modelVersion: "Jev · " + model, answers: parsed, calibrated: false, abstention: nil)
        try result.validate(for: request)
        return result
    }

    private static func number(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw DecisionError.invalidOutput }
        return number.doubleValue
    }
}
