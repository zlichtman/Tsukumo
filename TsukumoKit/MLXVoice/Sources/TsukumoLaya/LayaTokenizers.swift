import Foundation
import Hub
import Tokenizers
import TsukumoSystemOne

// Laya's tokenizer for both apps: the WordPiece tokenizer in Laya's downloaded bundle, read with Hugging
// Face swift-transformers' `Tokenizers` (the same copy Whisper uses in this package, so there's one).
// Built straight from the bundle's two files: no Hub download, no model-service call. TsukumoKit's
// `CoreMLLayaProvider` takes it through its `LayaTokenizer` seam, so TsukumoKit keeps no dependencies.
// Provenance: TsukumoKit/LAYA-NOTICE.md and `Laya-NOTICE.txt` in this target's resources.

/// Laya's bundled tokenizer, behind `LayaTokenizer`.
public struct LayaBundleTokenizer: LayaTokenizer {
    private let tokenizer: any Tokenizer

    /// `folder` is the bundle's `tokenizer/` folder (`tokenizer.json`, `tokenizer_config.json`).
    public init(folder: URL) throws {
        func json(_ name: String) throws -> Config {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name))) as? [NSString: Any] else {
                throw DecisionError.incompatibleBundle
            }
            return Config(object)
        }
        tokenizer = try PreTrainedTokenizer(tokenizerConfig: json("tokenizer_config.json"), tokenizerData: json("tokenizer.json"), strict: true)
    }

    /// The text's token IDs, without special tokens (the provider lays out `[CLS]`, `[SEP]`, and `[MASK]`).
    public func encode(_ text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }
    public func tokenID(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }

    /// What `CoreMLLayaProvider(directory:tokenizer:)` takes.
    public static let make: @Sendable (URL) throws -> any LayaTokenizer = { try LayaBundleTokenizer(folder: $0) }

    /// Laya's attribution, bundled for Settings' Licenses link.
    public static var noticeURL: URL? { Bundle.module.url(forResource: "Laya-NOTICE", withExtension: "txt") }
}
