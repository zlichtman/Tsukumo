# Voice provenance

Tsukumo's voices are the old KemoSabe app's, as it evaluated them (its `design/VOICE-ENGINES.md` and `legacy/ios/VOICE-ENGINES-NOTICE.md`, on the `pre-cleanup-main` branch).

**Code.** TsukumoVoice (in this package) has no dependencies: Apple's on-device recognizer (`SFSpeechRecognizer`, on-device only) and voices (`AVSpeechSynthesizer`), the pinned downloads, and the rules. Whisper and Kokoro run in `MLXVoice/`, a separate package the apps add, with the part of [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) (MIT) they need at the old app's pinned commit `01dec7c9bdce3088a6b6b7ab9f2e403458195efb`, vendored in `MLXVoice/Vendor/MLXAudio/` (why and what: its `VENDORED.md`). It brings [MLX Swift](https://github.com/ml-explore/mlx-swift) 0.32.3 and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) 3.32.3 (MIT; MLX Swift vendors MLX (MIT), {fmt} (MIT), JSON for Modern C++ (MIT), and metal-cpp (Apache-2.0)), [swift-huggingface](https://github.com/huggingface/swift-huggingface) 0.12.0 and [swift-transformers](https://github.com/huggingface/swift-transformers) 1.3.4 (Apache-2.0), swift-jinja, and Apple's swift-crypto, swift-asn1, swift-collections, and swift-numerics (Apache-2.0), plus EventSource and yyjson (MIT). No GPL code: Kokoro's English phonemes come from Misaki's lexicons and BART fallback, not espeak-ng. mlx-audio's own Hugging Face downloader is never used.

The license texts ship in both apps as `VoiceEngines-NOTICE.txt` (`MLXVoice/Sources/TsukumoMLXVoice/Resources/`; Settings, Models, Voice, Licenses).

**Models.** Never bundled or committed. They download only after the owner's one consent ("Download better voice models"), from huggingface.co at pinned commits, and every file is checked against its size and SHA-256 (`Sources/TsukumoVoice/VoiceModels.swift`):

- Whisper large-v3-turbo by OpenAI, MIT: `mlx-community/whisper-large-v3-turbo-asr-4bit@321a6ead9f6e0646bc8188a54d2a470e275c6b76` (4-bit MLX weights with the tokenizer files, 466 MB), used unmodified.
- Kokoro-82M v1.0 by hexgrad, Apache-2.0: `mlx-community/Kokoro-82M-bf16@a71e4d38b236d968966a2002c4c895dbd12b1c3c` (the model and nine American English voices, 332 MB).
- Misaki English G2P (hexgrad, Apache-2.0) as packaged in `beshkenadze/kitten-tts-g2p@9c692b92682d959d9013a9cfe6a49541997add18` (MIT, 9 MB).

On a Mac where the old KemoSabe app already downloaded them, the same pinned files are copied from its folder after the same checks instead of downloaded again; that folder is never changed.

Not carried over: the old app's "Your voice" (Pocket TTS, CC-BY-4.0, cloning the owner's own voice after a spoken consent) and its OpenAI voice and transcription opt-ins. Neither is in Tsukumo.

Original authors keep their rights. Nothing here is an official conversion by hexgrad or OpenAI.
