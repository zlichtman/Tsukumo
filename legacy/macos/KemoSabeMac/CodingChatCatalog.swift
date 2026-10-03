import Foundation
import Observation

/// A model an agent offers, with the reasoning efforts it supports.
struct CodingAgentModel: Equatable, Identifiable {
    var id: String
    var name: String
    var detail: String = ""
    var efforts: [String] = []
    var defaultEffort: String?
    var isDefault = false
}

/// What each installed agent says it can run: its models (and their efforts) and its slash
/// commands. Asked of the agent itself without sending a prompt: Codex's `model/list` after
/// `initialize`, and Claude Code's `initialize` control request (the Agent SDK's first message),
/// whose answer lists models and commands. Running tasks add what they report (`system/init`).
@MainActor @Observable final class CodingAgentCatalog {
    static let shared = CodingAgentCatalog()
    private(set) var models: [CodingProvider: [CodingAgentModel]] = [:]
    private(set) var commands: [CodingProvider: [String]] = [:]
    private(set) var loading: Set<CodingProvider> = []
    private(set) var problems: [CodingProvider: String] = [:]
    private var asked: Set<CodingProvider> = []
    /// Claude Code's documented aliases and effort levels (`claude --help`), until it answers.
    static let claudeFallback: [CodingAgentModel] = ["opus", "sonnet", "haiku"].map {
        .init(id: $0, name: $0.capitalized, detail: "Latest \($0.capitalized)", efforts: ["low", "medium", "high", "xhigh", "max"])
    }
    func modelsFor(_ provider: CodingProvider) -> [CodingAgentModel] {
        if let known = models[provider], !known.isEmpty { return known }
        return CodingAgentRegistry.shared.adapter(for: provider).fallbackModels
    }
    func efforts(_ provider: CodingProvider, model: String) -> [String] { Self.efforts(in: modelsFor(provider), model: model) }
    /// The efforts a model lists; for a model the agent didn't list, every effort any model has.
    nonisolated static func efforts(in list: [CodingAgentModel], model: String) -> [String] {
        if let match = entry(in: list, model: model) { return match.efforts }
        return Array(Set(list.flatMap(\.efforts))).sorted { effortOrder($0) < effortOrder($1) }
    }
    /// The effort a model uses when none is chosen, when the agent says.
    nonisolated static func defaultEffort(in list: [CodingAgentModel], model: String) -> String? { entry(in: list, model: model)?.defaultEffort }
    nonisolated private static func entry(in list: [CodingAgentModel], model: String) -> CodingAgentModel? {
        list.first(where: { $0.id == model }) ?? (model.isEmpty ? list.first(where: \.isDefault) : nil)
    }
    /// Lightest to heaviest, as Codex and Claude Code name them.
    nonisolated static let effortWeights = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    nonisolated static let unknownEffortRank = 99
    nonisolated static func effortOrder(_ effort: String) -> Int { effortWeights.firstIndex(of: effort.lowercased()) ?? unknownEffortRank }
    func record(_ provider: CodingProvider, report: CodingAgentReport) {
        if !report.commands.isEmpty { commands[provider] = report.commands }
        if let reported = report.models, !reported.isEmpty, models[provider] != reported { models[provider] = reported }
    }
    /// Asks the agent once per launch (again when `force`).
    func load(_ provider: CodingProvider, force: Bool = false) {
        guard force || !asked.contains(provider), !loading.contains(provider) else { return }
        asked.insert(provider); loading.insert(provider); problems[provider] = nil
        // Each adapter asks in its own protocol; ACP agents list models only inside a session,
        // so theirs arrive with the first task (`record`).
        let started = CodingAgentRegistry.shared.adapter(for: provider).loadCatalog { [weak self] result in
            guard let self else { return }
            loading.remove(provider)
            switch result {
            case .success(let answer):
                if !answer.models.isEmpty { models[provider] = answer.models }
                if !answer.commands.isEmpty { commands[provider] = answer.commands }
            case .failure(let error): problems[provider] = error.localizedDescription
            }
        }
        if !started { loading.remove(provider) }
    }

    // MARK: Reading the answers

    /// Codex `model/list` → models, hidden ones left out.
    static func codexModels(_ result: [String: Any]) -> [CodingAgentModel] {
        (result["data"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["model"] as? String ?? entry["id"] as? String, entry["hidden"] as? Bool != true else { return nil }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            return .init(id: id, name: entry["displayName"] as? String ?? id, detail: entry["description"] as? String ?? "", efforts: efforts,
                         defaultEffort: entry["defaultReasoningEffort"] as? String, isDefault: entry["isDefault"] as? Bool == true)
        }
    }
    /// Claude Code's `initialize` answer → models (`value`, `displayName`, `supportedEffortLevels`).
    static func claudeModels(_ response: [String: Any]) -> [CodingAgentModel] {
        (response["models"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["value"] as? String else { return nil }
            return .init(id: id, name: entry["displayName"] as? String ?? id, detail: entry["description"] as? String ?? "",
                         efforts: entry["supportedEffortLevels"] as? [String] ?? [], isDefault: id == "default")
        }
    }
    /// Claude Code's commands: names (with or without their slash) or objects with a `name`.
    static func claudeCommands(_ response: [String: Any]) -> [String] {
        (response["commands"] as? [Any] ?? []).compactMap { entry -> String? in
            let name = (entry as? String) ?? (entry as? [String: Any])?["name"] as? String
            return name.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        }
    }
}

/// One short-lived agent process that answers the catalog's question and exits. It never
/// starts a thread or sends a message, so nothing is billed.
@MainActor final class CodingCatalogProbe {
    struct Answer { var models: [CodingAgentModel] = []; var commands: [String] = [] }
    private let provider: CodingProvider
    private let executableOverride: URL?
    private let transport = CodingProcess(grace: 1)
    private var done: ((Result<Answer, Error>) -> Void)?
    private var timeout: Task<Void, Never>?
    private var keepAlive: CodingCatalogProbe?
    init(provider: CodingProvider, executableOverride: URL? = nil) { self.provider = provider; self.executableOverride = executableOverride }
    func run(_ completion: @escaping (Result<Answer, Error>) -> Void) {
        done = completion; keepAlive = self
        transport.onJSON = { [weak self] in self?.receive($0) }
        transport.onExit = { [weak self] code in self?.finish(.failure(CodingFailure("\(self?.provider.title ?? "The agent") exited (\(code)) before listing its models."))) }
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            if provider == .codex {
                try transport.start(executable: executableOverride ?? CodingProcess.executable("codex"), arguments: ["app-server", "--listen", "stdio://"], directory: home)
                try transport.send(["id": "catalog-init", "method": "initialize", "params": ["clientInfo": ["name": "tsukumo", "version": "1.0.0"], "capabilities": ["experimentalApi": true]]])
            } else {
                try transport.start(executable: executableOverride ?? CodingProcess.executable("claude"), arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"], directory: home)
                try transport.send(["type": "control_request", "request_id": "catalog-init", "request": ["subtype": "initialize"]])
            }
        } catch { finish(.failure(error)); return }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(CodingFailure("The agent didn't list its models in time.")))
        }
    }
    private func receive(_ object: [String: Any]) {
        if provider == .codex {
            if object["id"] as? String == "catalog-init" {
                try? transport.send(["method": "initialized"])
                try? transport.send(["id": "catalog-models", "method": "model/list", "params": [String: Any]()])
            } else if object["id"] as? String == "catalog-models" {
                if let error = object["error"] as? [String: Any] { finish(.failure(CodingFailure(error["message"] as? String ?? "Codex couldn't list models."))); return }
                finish(.success(.init(models: CodingAgentCatalog.codexModels(object["result"] as? [String: Any] ?? [:]))))
            }
        } else if object["type"] as? String == "control_response", let response = object["response"] as? [String: Any], response["request_id"] as? String == "catalog-init" {
            let body = response["response"] as? [String: Any] ?? [:]
            finish(.success(.init(models: CodingAgentCatalog.claudeModels(body), commands: CodingAgentCatalog.claudeCommands(body))))
        }
    }
    private func finish(_ result: Result<Answer, Error>) {
        guard let done else { return }
        self.done = nil; timeout?.cancel()
        transport.onExit = nil; transport.stop()
        done(result)
        keepAlive = nil
    }
}
