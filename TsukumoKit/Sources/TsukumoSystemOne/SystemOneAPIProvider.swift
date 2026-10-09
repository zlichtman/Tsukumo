import Foundation

// One provider for every hosted model that speaks the System One API (TypeSafe's contract, 0.2.0; ported
// from the app's `JevDecisionProvider` and generalized): `POST` with `Authorization: Bearer <key>` and
// `{state, model, questions}`, where each named question is `choice` (criteria keyed by choice), `noul`
// (yes/no, criteria `false`/`true`), or `score` (ordered criteria, 2 to 10 levels). Answers come back
// under the same names with probabilities, and a `confidence` for choice and score; `model` names the
// model that answered.
//
// - Jev (TypeSafe): `https://api.typesafe.ai/v1/systemone`, the body as it is.
// - Cloudflare Clef and Clef-flash on Workers AI: `https://api.cloudflare.com/client/v4/accounts/{account}/ai/run/@cf/cloudflare/clef-flash`
//   (or `/clef`), model `clef-flash` (or `clef`), and the answer inside Cloudflare's REST envelope
//   `{"result": {model, answers, usage}, "success": true, "errors": [], "messages": []}`
//   (https://developers.cloudflare.com/workers-ai/models/clef-flash/, its schema-input.json and
//   schema-output.json, and https://developers.cloudflare.com/workers-ai/get-started/rest-api/).
// - Any other endpoint with the same contract (a person's own Clef, Kev, or a gateway).
//
// It receives only the decision packet: the request's words, the questions, and the choices.
// `SystemOne.decide` checks the policy before every call.

/// Where a System One API lives, and how it answers.
public struct SystemOneEndpoint: Hashable, Sendable {
    /// Who decided, in the journal and the policy ("clef-flash", "jev").
    public let source: DecisionSource
    /// "Clef-flash"
    public let title: String
    public let url: URL
    public let model: String
    public init(source: DecisionSource, title: String, url: URL, model: String) {
        self.source = source; self.title = title; self.url = url; self.model = model
    }
    public var host: String { url.host() ?? "" }

    public static let jevHost = "api.typesafe.ai"
    public static let cloudflareHost = "api.cloudflare.com"

    /// Jev on TypeSafe. `jev-latest` follows TypeSafe's newest; pin `jev-1.13.0` to keep thresholds valid.
    public static func jev(model: String = "jev-latest") -> SystemOneEndpoint {
        SystemOneEndpoint(source: "jev", title: "Jev", url: URL(string: "https://api.typesafe.ai/v1/systemone")!, model: model)
    }

    /// A Cloudflare account ID: 32 hexadecimal characters.
    public static func isAccountID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// Clef (`clef`, 27B) or Clef-flash (`clef-flash`, 9B) on Workers AI, in the person's own account.
    public static func cloudflare(accountID: String, model: String) -> SystemOneEndpoint? {
        let account = accountID.trimmingCharacters(in: .whitespaces).lowercased()
        guard isAccountID(account), ["clef", "clef-flash"].contains(model),
              let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/run/@cf/cloudflare/\(model)") else { return nil }
        return SystemOneEndpoint(source: DecisionSource(rawValue: model), title: model == "clef" ? "Clef" : "Clef-flash",
                                 url: url, model: model)
    }

    /// Any endpoint with the same contract: HTTPS only, and a model name.
    public static func custom(address: String, model: String) -> SystemOneEndpoint? {
        let model = model.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              url.host()?.isEmpty == false, !model.isEmpty, model.count <= 80 else { return nil }
        return SystemOneEndpoint(source: "custom", title: "Custom endpoint", url: url, model: model)
    }
}

/// A hosted System One model behind `DecisionProvider`.
public struct SystemOneAPIProvider: DecisionProvider {
    /// The longest a decision waits for a hosted model before the caller falls back.
    public static let timeout: TimeInterval = 5
    /// The System One API's score questions have 2 to 10 levels; longer ones are never sent.
    public static let maxScoreLevels = 10

    public let endpoint: SystemOneEndpoint
    let key: String
    let session: URLSession
    public var modelVersion: String { endpoint.title + " · " + endpoint.model }

    public init(endpoint: SystemOneEndpoint, key: String, session: URLSession = .shared) {
        self.endpoint = endpoint; self.key = key; self.session = session
    }

    /// A key as these services issue them: printable ASCII without spaces, 8 to 4,096 characters.
    /// (TypeSafe and Cloudflare document no prefix or length.)
    public static func isKey(_ value: String) -> Bool {
        (8...4096).contains(value.count) && value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
    }

    /// This model as a hosted service System One asks, in its turn.
    public var remote: RemoteDecider { RemoteDecider(source: endpoint.source, host: endpoint.host, provider: self) }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        try request.validate()
        // Never sent: the API refuses a score with more than ten levels.
        guard request.questions.allSatisfy({ $0.kind != .score || $0.options.count <= Self.maxScoreLevels }) else { throw DecisionError.invalidInput }
        try Task.checkCancellation()
        var http = URLRequest(url: endpoint.url)
        http.httpMethod = "POST"
        http.timeoutInterval = min(Self.timeout, max(0.5, request.deadline.timeIntervalSinceNow))
        http.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.httpBody = Self.body(for: request, model: endpoint.model)
        let (data, response) = try await session.data(for: http)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw DecisionError.unavailable }
        switch status {
        case 200: break
        case 401, 403: throw RemoteDecisionError.keyRejected
        case 400, 422: throw DecisionError.invalidInput
        case 429: throw RemoteDecisionError.limited
        default: throw RemoteDecisionError.status(status)
        }
        return try Self.parse(data, for: request, title: endpoint.title)
    }

    /// The whole packet: the request's words, the model name, and each question with its choices, in the
    /// order the caller gave them. These models read the choices in order and are sensitive to it, so the
    /// body is written by hand rather than through a dictionary (which would reorder the keys).
    public static func body(for request: DecisionRequest, model: String) -> Data {
        var questions: [(String, OrderedJSON)] = []
        for question in request.questions {
            switch question.kind {
            case .choice:
                questions.append((question.id, .object([("type", .string("choice")), ("instructions", .string(question.instruction)),
                                                        ("criteria", .object(question.options.map { ($0, .null) }))])))
            case .probability:
                questions.append((question.id, .object([("type", .string("noul")), ("instructions", .string(question.instruction)),
                                                        ("criteria", .object([("false", .string(question.options[0])), ("true", .string(question.options[1]))]))])))
            case .score:
                questions.append((question.id, .object([("type", .string("score")), ("instructions", .string(question.instruction)),
                                                        ("criteria", .array(question.options.map { .string($0) }))])))
            }
        }
        return Data(OrderedJSON.object([("model", .string(model)), ("state", .string(request.state)), ("questions", .object(questions))]).text.utf8)
    }

    /// Probabilities in the question's option order, renormalized, with the model's own confidence;
    /// anything missing, extra, negative, or not finite is refused rather than guessed. Cloudflare's
    /// envelope is opened first (and a body without it is read as it is).
    public static func parse(_ data: Data, for request: DecisionRequest, title: String = "Jev") throws -> DecisionResult {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecisionError.invalidOutput }
        if object["answers"] == nil, object["result"] != nil || object["success"] != nil {
            guard (object["success"] as? Bool) != false, let result = object["result"] as? [String: Any] else { throw DecisionError.invalidOutput }
            object = result
        }
        guard let model = object["model"] as? String, !model.isEmpty, model.count <= 80,
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
            var reported: Double?
            if question.kind != .probability, answer["confidence"] != nil {
                let confidence = try number(answer["confidence"])
                guard confidence.isFinite, (0...1.0001).contains(confidence) else { throw DecisionError.invalidOutput }
                reported = min(1, confidence)
            }
            parsed.append(DecisionAnswer(questionID: question.id, probabilities: values.map { min(1, $0 / total) }, reported: reported))
        }
        let result = DecisionResult(modelVersion: title + " · " + model, answers: parsed, calibrated: false, abstention: nil)
        try result.validate(for: request)
        return result
    }

    private static func number(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw DecisionError.invalidOutput }
        return number.doubleValue
    }
}

/// JSON written in the order given (Foundation's writers sort or shuffle object keys).
enum OrderedJSON {
    case string(String), null
    indirect case array([OrderedJSON])
    indirect case object([(String, OrderedJSON)])

    var text: String {
        switch self {
        case .null: "null"
        case .string(let value): Self.quoted(value)
        case .array(let items): "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let pairs): "{" + pairs.map { Self.quoted($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
