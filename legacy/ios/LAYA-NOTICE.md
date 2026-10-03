# Laya integration provenance

The Swift prompt/input-layout port in `CoreMLLayaProvider.swift` adapts the independent [laya-coreml project](https://github.com/mizorewww/laya-coreml), licensed Apache-2.0. Its source lineage includes [Laya](https://github.com/NandhaKishorM/laya) and [laya-mlx](https://github.com/mizorewww/laya-mlx). Changes here include a Swift tokenizer adapter, strict no-truncation limits, Kemosabe decision types, the System One router with abstention thresholds, and native test instrumentation. The upstream notice and Apache license are bundled in `Resources/Laya-NOTICE.txt`.

The tokenizer runtime is [Hugging Face swift-transformers](https://github.com/huggingface/swift-transformers), pinned to `9088d55148b799e853cf4e039b0f0a1e3efe034c`. Only its local Tokenizers/Hub configuration types are used; it makes no model-service calls or downloads.

Runtime weights (since September 27, 2026): `aac6fef/laya-coreml@fff78b2d9750c6b748fe8c90fcbf8bed0a1522a9`, the FP16 Core ML conversion of the base checkpoint `convaiinnovations/laya@c5d78730f3493e4fe16d61507ef4b78eef7318cf` (Apache-2.0). The app downloads them on request (`LayaModel.swift`, the same pinned, SHA-256-checked store as on-device Whisper), 847 MB including the conversion's own `LICENSE` and `NOTICE`, and compiles them once on the device. Nothing is bundled or committed. An earlier fine-tune is not used. Original authors retain their rights. This is not an official Apple or Convai conversion certification.

Jev is TypeSafe's hosted System One API (`JevDecisionProvider.swift`), used only with the person's own key. No TypeSafe code, weights, or SDK is included; the adapter implements the public HTTP contract at https://api.typesafe.ai/openapi.json.
