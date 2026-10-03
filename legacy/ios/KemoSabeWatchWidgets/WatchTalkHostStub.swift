/// The extension's stand-in: `TalkFromControlIntent` opens the app and runs there.
enum WatchTalkHost {
    @MainActor static func talk() {}
}
