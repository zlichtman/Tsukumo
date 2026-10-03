# On-device voice provenance

Kokoro, "Your voice", and on-device Whisper transcription run with [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) (MIT), pinned to `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` in `ios/project.yml` and `macos/project.yml`. Its products `MLXAudioTTS`, `MLXAudioSTT`, and `MLXAudioCore` bring in [MLX Swift](https://github.com/ml-explore/mlx-swift) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) (MIT; MLX Swift vendors MLX (MIT), {fmt} (MIT), JSON for Modern C++ (MIT), and metal-cpp (Apache-2.0)), [swift-huggingface](https://github.com/huggingface/swift-huggingface), swift-jinja, and Apple's swift-crypto, swift-asn1, swift-collections, and swift-numerics (Apache-2.0), plus EventSource and yyjson (MIT). swift-transformers stays pinned at the revision recorded in `LAYA-NOTICE.md`. swift-syntax (macros) and swift-argument-parser (command-line tools) are build-time only. No GPL code: Kokoro's English phonemes come from Misaki's lexicons and BART fallback, not espeak-ng. The package's own Hugging Face download code is never used: models reach the app only through `VoiceModelStore`, and Kokoro's G2P files are copied from the verified download into the folder mlx-audio reads (`KokoroG2PMirror`), inside the app's own backup-excluded `VoiceModels` folder.

The license texts are bundled in `Resources/VoiceEngines-NOTICE.txt`.

Model weights are not bundled. They download only when the person asks, from huggingface.co at pinned commits, and every file is checked against its size and SHA-256 in `VoiceModelPacks.swift`:

- Kokoro-82M v1.0 by hexgrad, Apache-2.0: `mlx-community/Kokoro-82M-bf16@a71e4d38b236d968966a2002c4c895dbd12b1c3c` (the model and nine American English voices, 331.8 MB).
- Misaki English G2P (hexgrad, Apache-2.0) as packaged in `beshkenadze/kitten-tts-g2p@9c692b92682d959d9013a9cfe6a49541997add18` (MIT, 9.1 MB).
- Pocket TTS by Kyutai, CC-BY-4.0: `mlx-community/pocket-tts@cbf71d5f6657bbc3f4bc02f85ee408261225bec7` (236.0 MB), used unmodified. Attribution is required, and Kyutai's terms forbid cloning a voice without explicit, lawful consent; the app clones only the person's own voice after a spoken consent line.
- Whisper large-v3-turbo by OpenAI, MIT: `mlx-community/whisper-large-v3-turbo-asr-4bit@321a6ead9f6e0646bc8188a54d2a470e275c6b76` (4-bit MLX weights with the tokenizer files, 466.5 MB), used unmodified. The tokenizer is part of the pinned download, so mlx-audio's fallback tokenizer fetch is never reached.

Original authors keep their rights. Nothing here is an official conversion by hexgrad, Kyutai, or OpenAI.
