import Foundation
import Security

/// Jev, TypeSafe's hosted System One model, behind the same `DecisionProvider` interface as Laya.
/// Contract (read September 27, 2026 from https://api.typesafe.ai/openapi.json, "TypeSafe" 0.2.0):
/// `POST /v1/systemone` with `Authorization: Bearer <key>` and `{state, model, questions}`, where
/// each named question is `choice` (criteria keyed by choice name), `noul` (yes/no, criteria
/// `true`/`false`), or `score` (ordered criteria). Answers come back under the same names with
/// probabilities; `model` names the model that answered. `GET /v1/models` lists model names;
/// `jev-latest` is the documented alias.
///
/// It is a cloud recipient (`SystemOne.jevRecipient`). It receives only the decision packet: the
/// request's own words, the question, and the candidate labels. Never chat history, memories,
/// People, or tool results. `SystemOne.decide` checks `ContextPolicy` before every call.
struct JevDecisionProvider: DecisionProvider {
    static let host = "api.typesafe.ai"
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let defaultModel = "jev-latest"
    /// The longest a decision waits for Jev before the caller falls back.
    static let timeout: TimeInterval = 5
    let key: String
    var model = JevDecisionProvider.defaultModel
    /// TypeSafe's endpoint; tests point it at a stub server on this device.
    var endpoint = JevDecisionProvider.endpoint
    var session: URLSession = .shared
    var modelVersion: String { "Jev · " + model }
    /// Where a person makes a key: TypeSafe's console.
    static let keysPage = URL(string: "https://console.typesafe.ai/")!

    typealias Failure = RemoteDecisionError

    func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        try request.validate(); try Task.checkCancellation()
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
        case 401, 403: throw Failure.keyRejected
        case 422: throw DecisionError.invalidInput
        case 429: throw Failure.limited
        default: throw Failure.status(status)
        }
        let result = try Self.parse(data, for: request)
        try request.validate()
        return result
    }

    /// The whole packet: the request's words, the model name, and each question with its choices.
    static func body(for request: DecisionRequest, model: String) throws -> Data {
        var questions: [String: Any] = [:]
        for question in request.questions {
            switch question.kind {
            case .choice:
                // A choice without a description is interpreted by its name alone.
                questions[question.id] = ["type": "choice", "instructions": question.instruction,
                                          "criteria": Dictionary(uniqueKeysWithValues: question.options.map { ($0, NSNull()) })] as [String: Any]
            case .probability:
                // Laya's convention: option 0 is false, option 1 is true.
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
    static func parse(_ data: Data, for request: DecisionRequest) throws -> DecisionResult {
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
            values = values.map { min(1, $0 / total) }
            parsed.append(.init(questionID: question.id, probabilities: values))
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

/// The person's own Jev key, in the Keychain like the other API keys: this device only, readable
/// while it's unlocked. Tests use their own Keychain service, so they never see the real key.
protocol JevKeyStoring: Sendable {
    func read() -> String?
    /// Whether a key is saved, without reading the secret itself.
    func exists() -> Bool
    func save(_ key: String) throws
    func remove() throws
}
extension JevKeyStoring {
    func exists() -> Bool { read() != nil }
}

/// A key as it's saved: surrounding spaces and line breaks removed.
enum JevKey {
    static func normalized(_ key: String) -> String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Printable ASCII with no spaces, 8 to 4,096 characters.
    static func isValid(_ key: String) -> Bool {
        let key = normalized(key)
        return (8...4096).contains(key.utf8.count) && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
}
enum JevKeyError: Error, LocalizedError, Equatable {
    case invalid, keychain(OSStatus), notSaved
    var errorDescription: String? {
        switch self {
        case .invalid: "That doesn't look like a Jev key. Paste the whole key from TypeSafe, with no spaces."
        case .keychain(let status): "Keychain didn't save the key (error \(status)). Unlock this device and try again."
        case .notSaved: "Keychain didn't keep the key. Try adding it again."
        }
    }
}

/// The Jev key as a plain generic password: no access group and no data-protection-keychain flag,
/// so it works the same in the App Store, TestFlight, and Developer ID (Homebrew and website)
/// builds, none of which carries a keychain-access-groups entitlement. On the Mac it's in the
/// login keychain.
struct KeychainJevKey: JevKeyStoring {
    /// Unit tests use ".tests"; the iPhone UI test's fixture (`--system-one-fixture`) uses ".uitests".
    static let service = "com.zlichtman.kemosabe.system-one" + (AccountDirectory.isTestHost ? ".tests" : SystemOneFixture.requested ? ".uitests" : "")
    var service = KeychainJevKey.service
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "jev"]
    }
    func read() -> String? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }
    /// Attributes only, so showing a status never asks for the Keychain password.
    func exists() -> Bool {
        var query = query; query[kSecReturnAttributes as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess
    }
    func save(_ key: String) throws {
        let key = JevKey.normalized(key)
        guard JevKey.isValid(key) else { throw JevKeyError.invalid }
        let fields: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw JevKeyError.keychain(added) }
        } else if status != errSecSuccess { throw JevKeyError.keychain(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw JevKeyError.keychain(status) }
    }
}

/// A hosted decision service's failure (Jev today), shared so the next service reports the same way.
enum RemoteDecisionError: Error, Equatable { case keyRejected, limited, status(Int) }
