#if canImport(CoreML)
import Foundation
import CoreML

/// The tokenizer Laya's bundle ships (a WordPiece tokenizer). TsukumoKit has no package
/// dependencies, so the app supplies one (the old app used swift-transformers' `Tokenizers`).
public protocol LayaTokenizer: Sendable {
    func encode(_ text: String) -> [Int]
    func tokenID(_ token: String) -> Int?
}

/// Laya on this device through Core ML (ported from the app's `CoreMLLayaProvider`; prompt layout
/// follows mizorewww/laya-coreml, Apache-2.0, attribution in TsukumoKit/LAYA-NOTICE.md). The bundle is
/// downloaded on demand by the app, never shipped; its probabilities use the upstream
/// temperatures, so results say `calibrated: false`, and System One accepts an answer only above
/// each decision's threshold.
public actor CoreMLLayaProvider: DecisionProvider {
    public static let version = "Laya English · c5d7873"
    public nonisolated let modelVersion: String
    private let directory: URL?
    private let makeTokenizer: @Sendable (URL) throws -> any LayaTokenizer
    private var model: MLModel?
    private var tokenizer: (any LayaTokenizer)?
    private var shape: Shape?
    private var configuration: Configuration?
    private var working = false

    struct Shape: Decodable { let batch_size: Int; let max_length: Int; let max_options: Int; let lengths: [Int]? }
    struct Manifest: Decodable { let format: String; let format_version: Int; let shape: Shape }
    struct Configuration: Decodable {
        let max_len: Int; let head_max_len: Int; let temperature: [Double]
        let temperature_by_options: [String: Double]?
    }

    /// `directory` holds the downloaded bundle (`coreml_config.json`, `rl_agent_config.json`,
    /// `tokenizer/`, and `model.mlmodelc` or `model.mlpackage`); `tokenizer` builds the tokenizer
    /// from the bundle's `tokenizer/` folder.
    public init(directory: URL?, modelVersion: String = CoreMLLayaProvider.version,
                tokenizer: @escaping @Sendable (URL) throws -> any LayaTokenizer) {
        self.directory = directory; self.modelVersion = modelVersion; self.makeTokenizer = tokenizer
    }

    /// Compiled once: a `model.mlpackage` becomes `model.mlmodelc` beside it, and the package is removed.
    static func compiledModel(in directory: URL) async throws -> URL {
        let files = FileManager.default
        let compiled = directory.appendingPathComponent("model.mlmodelc")
        if files.fileExists(atPath: compiled.path) { return compiled }
        let package = directory.appendingPathComponent("model.mlpackage")
        guard files.fileExists(atPath: package.path) else { throw DecisionError.unavailable }
        let temporary = try await MLModel.compileModel(at: package)
        try files.moveItem(at: temporary, to: compiled)
        try? files.removeItem(at: package)
        return compiled
    }

    private func load() async throws {
        if model != nil { return }
        guard let directory else { throw DecisionError.unavailable }
        let decoder = JSONDecoder()
        guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent("coreml_config.json")),
              let configData = try? Data(contentsOf: directory.appendingPathComponent("rl_agent_config.json")) else { throw DecisionError.unavailable }
        let manifest = try decoder.decode(Manifest.self, from: manifestData)
        guard manifest.format == "laya-coreml", manifest.format_version == 1, manifest.shape.batch_size == 1,
              manifest.shape.max_length <= 1024, manifest.shape.max_options >= 12, manifest.shape.lengths != nil else { throw DecisionError.incompatibleBundle }
        let config = try decoder.decode(Configuration.self, from: configData)
        guard config.temperature.count == 3 else { throw DecisionError.incompatibleBundle }
        let tokenizer = try makeTokenizer(directory.appendingPathComponent("tokenizer"))
        let options = MLModelConfiguration()
        options.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: try await Self.compiledModel(in: directory), configuration: options)
        self.tokenizer = tokenizer; configuration = config; shape = manifest.shape
    }

    /// The synchronous prediction, run on this actor: `MLModel` isn't Sendable, so it never leaves.
    private static func predict(_ model: MLModel, _ features: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: features)
    }

    /// Loads (and on first use compiles) the model ahead of the first decision.
    public func prepare() async throws { try await load() }
    /// Frees the model; the next decision loads it again.
    public func unload() { guard !working else { return }; model = nil; tokenizer = nil; configuration = nil; shape = nil }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        guard !working else { throw DecisionError.unavailable }
        working = true
        defer { working = false }
        try request.validate()
        try Task.checkCancellation()
        try await load()
        guard let model, let tokenizer, let config = configuration, let shape,
              let cls = tokenizer.tokenID("[CLS]"), let sep = tokenizer.tokenID("[SEP]"),
              let mask = tokenizer.tokenID("[MASK]"), let pad = tokenizer.tokenID("[PAD]") else { throw DecisionError.incompatibleBundle }
        var answers: [DecisionAnswer] = []
        for question in request.questions {
            try Task.checkCancellation()
            let kind = question.kind == .probability ? "noul" : question.kind.rawValue
            let typeIndex = question.kind == .choice ? 0 : question.kind == .score ? 1 : 2
            func encode(_ value: String) -> [Int] { tokenizer.encode(value.replacingOccurrences(of: "[MASK]", with: " ")) }
            let head = encode("\(kind) question: \(question.instruction)")
            let options = question.options.enumerated().map { index, value -> [Int] in
                let rendered = question.kind == .score ? "level \(index): \(value)"
                    : question.kind == .probability ? "\(index == 0 ? "false" : "true"): \(value)" : value
                return encode(" " + rendered)
            }
            guard options.allSatisfy({ $0.count <= 48 }),
                  head.count + options.reduce(0, { $0 + $1.count + 1 }) <= config.head_max_len else { throw DecisionError.contextLimit }
            var ids = [cls] + head + [sep], markers: [Int] = []
            for option in options { markers.append(ids.count); ids += [mask] + option }
            ids += [sep] + encode(request.state) + [sep]
            guard ids.count <= config.max_len, let length = shape.lengths?.sorted().first(where: { $0 >= ids.count }) else { throw DecisionError.contextLimit }
            func array(_ count: Int, _ fill: Int = 0, vector: Bool = false) throws -> MLMultiArray {
                let value = try MLMultiArray(shape: vector ? [NSNumber(value: count)] : [1, NSNumber(value: count)], dataType: .int32)
                for index in 0..<value.count { value[index] = NSNumber(value: fill) }
                return value
            }
            let input = try array(length, pad), attention = try array(length)
            let positions = try array(shape.max_options), masks = try array(shape.max_options), qtype = try array(1, typeIndex, vector: true)
            for (index, id) in ids.enumerated() { input[index] = NSNumber(value: id); attention[index] = 1 }
            for (index, position) in markers.enumerated() { positions[index] = NSNumber(value: position); masks[index] = 1 }
            let features = try MLDictionaryFeatureProvider(dictionary: ["input_ids": input, "attention_mask": attention, "marker_pos": positions,
                                                                        "marker_mask": masks, "qtype": qtype])
            let output = try Self.predict(model, features)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else { throw DecisionError.invalidOutput }
            let count = options.count, bucket = count <= 2 ? "2" : count <= 5 ? "3-5" : count <= 10 ? "6-10" : "11+"
            let temperature = config.temperature_by_options?["\(kind):\(bucket)"] ?? config.temperature[typeIndex]
            guard temperature.isFinite, temperature > 0 else { throw DecisionError.invalidOutput }
            let scaled = (0..<count).map { logits[$0].doubleValue / min(max(temperature, 0.5), 5) }
            let top = scaled.max() ?? 0, exponentials = scaled.map { exp($0 - top) }, total = exponentials.reduce(0, +)
            answers.append(DecisionAnswer(questionID: question.id, probabilities: exponentials.map { $0 / total }))
        }
        let result = DecisionResult(modelVersion: modelVersion, answers: answers, calibrated: false, abstention: nil)
        try result.validate(for: request)
        return result
    }
}
#endif
