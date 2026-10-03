import Foundation

/// The optional on-device voice models, each pinned to exact files: the repository commit, every
/// file's size, and its SHA-256. A download is accepted only when every file matches, so a
/// changed or tampered file on the host is refused rather than run. They aren't personal data:
/// they live in this device's Application Support, excluded from backup, and are never synced.
struct VoiceModelPack: Identifiable, Equatable, Sendable {
    struct File: Equatable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }
    /// One Hugging Face repository at one commit, saved under `folder` in the pack.
    struct Source: Equatable, Sendable {
        let repository: String
        let revision: String
        let license: String
        let folder: String
        let files: [File]
        /// The file at this exact commit, never a moving branch. Nil only for a malformed pin.
        func url(for file: File) -> URL? {
            URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")
        }
    }
    let id: String
    let title: String
    /// Bumped when the files change, so an older install is replaced rather than trusted.
    let version: Int
    let sources: [Source]

    var files: [(source: Source, file: File)] { sources.flatMap { source in source.files.map { (source, $0) } } }
    var totalBytes: Int64 { sources.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } } }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    static func == (lhs: VoiceModelPack, rhs: VoiceModelPack) -> Bool { lhs.id == rhs.id && lhs.version == rhs.version }

    /// Kokoro-82M v1.0 (Apache-2.0, hexgrad) in MLX form, nine American English voices, and the
    /// Misaki English G2P lexicons and BART fallback (MIT/Apache-2.0) that turn text into phonemes.
    static let kokoro = VoiceModelPack(id: "kokoro-82m", title: "Kokoro", version: 1, sources: [
        .init(repository: "mlx-community/Kokoro-82M-bf16", revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
              license: "Apache-2.0 (hexgrad/Kokoro-82M)", folder: "model", files: [
            .init(path: "config.json", size: 2351, sha256: "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"),
            .init(path: "kokoro-v1_0.safetensors", size: 327115152, sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"),
            .init(path: "voices/af_heart.safetensors", size: 522320, sha256: "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094"),
            .init(path: "voices/af_bella.safetensors", size: 522320, sha256: "112d310468cbb3cf23404d3d0b50ad3adf017b87bf38bf9edd15f4ad572df6a3"),
            .init(path: "voices/af_nicole.safetensors", size: 522320, sha256: "574656386022c81a029e9a72558191925f44c3de2dad2fa2e45751938557d062"),
            .init(path: "voices/af_aoede.safetensors", size: 522320, sha256: "23809148777f2a2378983dd856bc14b9c261018279f916f98c23d86e844409a5"),
            .init(path: "voices/af_kore.safetensors", size: 522320, sha256: "c491174280cb1ad25210a842f2f34b46a9ef904ec6f6a8e784839531795fa278"),
            .init(path: "voices/af_sarah.safetensors", size: 522320, sha256: "4940072182542f54c1035d1daf4c1cf3136ca9baa9ac57c8e006b4befcc50be6"),
            .init(path: "voices/am_fenrir.safetensors", size: 522320, sha256: "9abed964b906c4cae6f404d9849e76260689aea862bc6ca85fc3f5207ba96538"),
            .init(path: "voices/am_michael.safetensors", size: 522320, sha256: "3940147ded35deba0bb52e8132f89b719298e0520258c34584358aa5a24da2ea"),
            .init(path: "voices/am_puck.safetensors", size: 522320, sha256: "9a8c2e56413bd2063f814cb4c3885fc425876157369117c3f8258d03c8a9ad89"),
        ]),
        .init(repository: "beshkenadze/kitten-tts-g2p", revision: "9c692b92682d959d9013a9cfe6a49541997add18",
              license: "MIT (lexicons from hexgrad/misaki, Apache-2.0)", folder: "g2p", files: [
            .init(path: "us_bart.safetensors", size: 3011692, sha256: "dc4a02e62d4fcb4bb4097ecf00db89b8e1a12a549a52ab6adfbba220b80a55c5"),
            .init(path: "us_bart_config.json", size: 1257, sha256: "8deb3537fb29c63cd9f20d75515ae06e4c92f1b6db0703a2d45bca95b33a53a4"),
            .init(path: "us_gold.json", size: 3001196, sha256: "8507f89840f0813b10cf584740942f58e9cc9ad3660e24088b442ab0a6b126be"),
            .init(path: "us_silver.json", size: 3105352, sha256: "ea0e1abca0c9b18fb0d3402034633a337154a3153e9a9f49f97d668c908e140c"),
        ]),
    ])

    /// Kyutai's Pocket TTS (CC-BY-4.0) in MLX form, including the audio encoder that turns a
    /// short recording into a voice prompt. Used only for the person's own voice.
    static let pocketTTS = VoiceModelPack(id: "pocket-tts", title: "Your voice model", version: 1, sources: [
        .init(repository: "mlx-community/pocket-tts", revision: "cbf71d5f6657bbc3f4bc02f85ee408261225bec7",
              license: "CC-BY-4.0 (kyutai/pocket-tts)", folder: "model", files: [
            .init(path: "config.json", size: 1664, sha256: "403ff12260596fbfa348c7b07237c378b9ad8db9d8acd04d671470421954a68e"),
            .init(path: "model.safetensors", size: 235739497, sha256: "60ddd85019dddbe6c1d220e311ca5fc753972978a89f563c0bbe1ae943120072"),
            .init(path: "tokenizer.json", size: 244993, sha256: "ef29c4871fd62c7beb928150edc095be1327f0924c0eab9e06b95918b39eff5f"),
            .init(path: "tokenizer_config.json", size: 220, sha256: "ad6dc6a5790d0f94170998ab79921c97d28ea54602abcdb33cba3132d13ac233"),
            .init(path: "special_tokens_map.json", size: 95, sha256: "0655d856e7dd462048486aac66d4247753e5cab12480baeb9f4e8f7fe03f7d4c"),
        ]),
    ])
}

/// The Kokoro voices included in the download (American English, which the bundled G2P covers).
enum KokoroVoices {
    struct Voice: Identifiable, Equatable, Sendable { let id: String; let name: String; let detail: String }
    static let all: [Voice] = [
        .init(id: "af_heart", name: "Heart", detail: "Warm · American English"),
        .init(id: "af_bella", name: "Bella", detail: "Bright · American English"),
        .init(id: "af_nicole", name: "Nicole", detail: "Soft, close · American English"),
        .init(id: "af_aoede", name: "Aoede", detail: "Calm · American English"),
        .init(id: "af_kore", name: "Kore", detail: "Clear · American English"),
        .init(id: "af_sarah", name: "Sarah", detail: "Even · American English"),
        .init(id: "am_fenrir", name: "Fenrir", detail: "Deep · American English"),
        .init(id: "am_michael", name: "Michael", detail: "Friendly · American English"),
        .init(id: "am_puck", name: "Puck", detail: "Playful · American English"),
    ]
    static let defaultID = "af_heart"
    static func normalized(_ id: String?) -> String {
        guard let id, all.contains(where: { $0.id == id }) else { return defaultID }
        return id
    }
    static func voice(_ id: String?) -> Voice {
        let wanted = normalized(id)
        return all.first { $0.id == wanted } ?? Voice(id: defaultID, name: "Heart", detail: "Warm · American English")
    }
}
