import Foundation
import CoreML
import Tokenizers
import Hub

/// Offline port of the pinned Laya Core ML input contract. Prompt layout follows
/// mizorewww/laya-coreml (Apache-2.0); attribution is in LAYA-NOTICE.md.
///
/// The model is the base Laya checkpoint (convaiinnovations/laya@c5d7873), converted by
/// aac6fef/laya-coreml@fff78b2 and downloaded on demand (`LayaModel`), never bundled. The owner
/// activated it on September 27, 2026 under strict abstention (design/LAYA-TRAINING.md): its
/// probabilities use the upstream temperatures, so results say `calibrated: false`, and
/// `SystemOne` accepts an answer only above a per-decision threshold.
actor CoreMLLayaProvider: DecisionProvider {
    static let version = "Laya English · c5d7873"
    /// The downloaded bundle. Nothing is loaded until a decision needs it.
    static let shared = CoreMLLayaProvider(directory: LayaModel.modelDirectory)
    nonisolated let modelVersion: String
    private let directory: URL?
    private var model: MLModel?
    private var tokenizer: (any Tokenizer)?
    private var shape: Shape?
    private var configuration: Configuration?
    private var working = false
    struct Shape: Decodable {
        let batch_size: Int; let max_length: Int; let max_options: Int; let lengths: [Int]?
    }
    struct Manifest: Decodable { let format: String; let format_version: Int; let shape: Shape }
    struct Configuration: Decodable {
        let max_len: Int; let head_max_len: Int; let temperature: [Double]
        let temperature_by_options: [String: Double]?
    }
    init(directory: URL?, modelVersion: String = CoreMLLayaProvider.version) {
        self.directory = directory; self.modelVersion = modelVersion
    }
    /// Compiled once. A downloaded `model.mlpackage` is compiled into `model.mlmodelc` beside it
    /// and the package is removed, so the device keeps one copy of the weights. The evaluation
    /// bundle's read-only `weights.laya` is compiled into a temporary folder each time.
    static func compiledModel(in directory: URL) async throws -> URL {
        let files = FileManager.default
        let compiled = directory.appendingPathComponent("model.mlmodelc")
        if files.fileExists(atPath: compiled.appendingPathComponent(LayaModel.compiledMarker).path) { return compiled }
        let package = directory.appendingPathComponent("model.mlpackage")
        if files.fileExists(atPath: package.path) {
            let temporary = try await MLModel.compileModel(at: package)
            try? files.removeItem(at: compiled)
            try files.moveItem(at: temporary, to: compiled)
            try Data(CoreMLLayaProvider.version.utf8).write(to: compiled.appendingPathComponent(LayaModel.compiledMarker), options: .atomic)
            try? files.removeItem(at: package)
            return compiled
        }
        let raw = directory.appendingPathComponent("weights.laya")
        guard files.fileExists(atPath: raw.path) else { throw DecisionError.unavailable }
        // iCloud attaches FinderInfo to recognized .mlpackage folders, which prevents signing the
        // test bundle; the evaluation copy restores the suffix in a private temporary folder.
        let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mlpackage")
        try files.copyItem(at: raw, to: temporary)
        defer { try? files.removeItem(at: temporary) }
        return try await MLModel.compileModel(at: temporary)
    }
    private func load() async throws {
        if model != nil { return }
        guard let directory else { throw DecisionError.unavailable }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("coreml_config.json")))
        guard manifest.format == "laya-coreml", manifest.format_version == 1,
              manifest.shape.batch_size == 1, manifest.shape.max_length <= 1024,
              manifest.shape.max_options >= 12, manifest.shape.lengths != nil else { throw DecisionError.incompatibleBundle }
        let config = try decoder.decode(Configuration.self, from: Data(contentsOf: directory.appendingPathComponent("rl_agent_config.json")))
        guard config.temperature.count == 3 else { throw DecisionError.incompatibleBundle }
        // Direct local construction avoids Hub download or fallback APIs.
        func json(_ name: String) throws -> Config {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("tokenizer/" + name))) as? [NSString: Any] else { throw DecisionError.incompatibleBundle }
            return Config(object)
        }
        let tokenizer = try PreTrainedTokenizer(tokenizerConfig: json("tokenizer_config.json"), tokenizerData: json("tokenizer.json"), strict: true)
        let modelURL = try await Self.compiledModel(in: directory)
        let options = MLModelConfiguration(); options.computeUnits = .cpuAndGPU
        self.model = try MLModel(contentsOf: modelURL, configuration: options)
        self.tokenizer = tokenizer; self.configuration = config; self.shape = manifest.shape
    }
    /// Loads (and on first use compiles) the model ahead of the first decision.
    func prepare() async throws { try await load() }
    /// Frees the model; the next decision loads it again.
    func unload() { guard !working else { return }; model = nil; tokenizer = nil; configuration = nil; shape = nil }
    func tokenIDs(_ text: String) async throws -> [Int] {
        try await load(); return tokenizer!.encode(text: text, addSpecialTokens: false)
    }
    func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        guard !working else { throw DecisionError.unavailable }
        working = true; defer { working = false }
        try request.validate(); try Task.checkCancellation(); try await load()
        guard let model, let tokenizer, let config = configuration, let shape,
              let cls = tokenizer.convertTokenToId("[CLS]"), let sep = tokenizer.convertTokenToId("[SEP]"),
              let mask = tokenizer.convertTokenToId("[MASK]"), let pad = tokenizer.convertTokenToId("[PAD]") else { throw DecisionError.incompatibleBundle }
        var answers: [DecisionAnswer] = []
        for question in request.questions {
            try request.validate(); try Task.checkCancellation()
            let kind = question.kind == .probability ? "noul" : question.kind.rawValue
            let typeIndex = question.kind == .choice ? 0 : question.kind == .score ? 1 : 2
            func encode(_ value: String) -> [Int] { tokenizer.encode(text: value.replacingOccurrences(of: "[MASK]", with: " "), addSpecialTokens: false) }
            let head = encode("\(kind) question: \(question.instruction)")
            let options = question.options.enumerated().map { index, value -> [Int] in
                let rendered = question.kind == .score ? "level \(index): \(value)" : question.kind == .probability ? "\(index == 0 ? "false" : "true"): \(value)" : value
                return encode(" " + rendered)
            }
            guard question.kind != .probability || options.count == 2,
                  options.allSatisfy({ $0.count <= 48 }), head.count + options.reduce(0, { $0 + $1.count + 1 }) <= config.head_max_len else { throw DecisionError.contextLimit }
            var ids = [cls] + head + [sep], markers: [Int] = []
            for option in options { markers.append(ids.count); ids += [mask] + option }
            ids += [sep] + encode(request.state) + [sep]
            guard ids.count <= config.max_len, let length = shape.lengths?.sorted().first(where: { $0 >= ids.count }) else { throw DecisionError.contextLimit }
            func array(_ count: Int, _ fill: Int = 0, vector: Bool = false) throws -> MLMultiArray {
                let value = try MLMultiArray(shape: vector ? [NSNumber(value: count)] : [1,NSNumber(value: count)], dataType: .int32)
                for index in 0..<value.count { value[index] = NSNumber(value: fill) }; return value
            }
            let input = try array(length, pad), attention = try array(length)
            let positions = try array(shape.max_options), masks = try array(shape.max_options), qtype = try array(1, typeIndex, vector: true)
            for (index,id) in ids.enumerated() { input[index] = NSNumber(value: id); attention[index] = 1 }
            for (index,position) in markers.enumerated() { positions[index] = NSNumber(value: position); masks[index] = 1 }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input_ids":input,"attention_mask":attention,"marker_pos":positions,"marker_mask":masks,"qtype":qtype])
            let result = try await model.prediction(from: provider)
            guard let logits = result.featureValue(for: "logits")?.multiArrayValue else { throw DecisionError.invalidOutput }
            let count = options.count, bucket = count <= 2 ? "2" : count <= 5 ? "3-5" : count <= 10 ? "6-10" : "11+"
            let temperature = config.temperature_by_options?["\(kind):\(bucket)"] ?? config.temperature[typeIndex]
            guard temperature.isFinite, temperature > 0 else { throw DecisionError.invalidOutput }
            let safeTemperature = min(max(temperature,0.5),5)
            let values = (0..<count).map { logits[$0].doubleValue / safeTemperature }
            let maximum = values.max() ?? 0, exponential = values.map { exp($0-maximum) }, total = exponential.reduce(0,+)
            answers.append(.init(questionID: question.id, probabilities: exponential.map { $0 / total }))
        }
        try request.validate(); try Task.checkCancellation()
        // Upstream temperatures, not a Kemo calibration: never reported as calibrated.
        let result = DecisionResult(modelVersion: modelVersion, answers: answers, calibrated: false, abstention: nil)
        try result.validate(for: request); return result
    }
}
