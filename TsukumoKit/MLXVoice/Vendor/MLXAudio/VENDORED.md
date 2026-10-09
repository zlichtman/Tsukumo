# mlx-audio-swift, the part Tsukumo runs

From [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) (MIT, `LICENSE` here) at `01dec7c9bdce3088a6b6b7ab9f2e403458195efb`, the commit the old KemoSabe app pinned and measured (Whisper large-v3-turbo and Kokoro-82M).

Why it's here instead of a package dependency: at that commit the whole package doesn't compile with Swift 6.4 (Xcode 27) in Swift 6 language mode (`MLXAudioSTT/Models/Parakeet/ParakeetModel.swift`, a model Tsukumo doesn't use, captures non-Sendable values in `@Sendable` closures), and forcing Swift 5 mode on every package breaks swift-jinja. Upstream's newest commit (`8d86630`, two commits later) has the same problem. So the files Tsukumo needs are copied here and built in Swift 5 mode by `../../Package.swift`.

What's included, unchanged:

- `MLXAudioCore/`: all of it.
- `MLXAudioG2P/`: all of it.
- `MLXAudioTTS/`: `Generation.swift`, `TextProcessor.swift`, and `Models/StyleTTS2/` (`Albert.swift`, `SharedConfigs.swift`, `Blocks/`, `G2P/` with Misaki's English G2P, `Kokoro/`). KittenTTS is left out.
- `MLXAudioSTT/`: `Generation.swift`, `Models/Whisper/`, and `Models/GLMASR/STTOutput.swift` (where `STTOutput` and `STTGeneration` live).

Left out: every other model, the command-line tools, the tests, and the two model loaders (`MLXAudioTTS/TTSModel.swift` and `MLXAudioSTT/MLXAudioSTT.swift`), which name every model and would download from Hugging Face. Tsukumo never uses mlx-audio's own downloader: the models arrive only through TsukumoVoice's `VoiceModelStore`, pinned and SHA-256 checked.

The dependencies are pinned to what that commit resolved to on October 3, 2026: mlx-swift 0.32.3, mlx-swift-lm 3.32.3, swift-transformers 1.3.4, swift-huggingface 0.12.0. To update, copy the same files from a newer commit, check `swift build --package-path TsukumoKit/MLXVoice`, and run the Mac app's DEBUG `--voice-check`.
