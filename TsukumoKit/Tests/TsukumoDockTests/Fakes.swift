#if os(macOS)
import Foundation
import TsukumoCore
import TsukumoUI
@testable import TsukumoDock

/// A bot that answers after a pause, word by word, so a test can watch its tile think, talk, and finish.
struct SlowRunner: BotTurnRunning {
    var reply = "Problems 4 to 6 are left. It’s due at 5."
    var pause: Double = 0.15
    func run(_ turn: BotTurn) -> AsyncThrowingStream<BotTurnEvent, Error> {
        let reply = self.reply, pause = self.pause
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(pause))
                for word in reply.split(separator: " ") {
                    continuation.yield(.text(String(word) + " "))
                    try? await Task.sleep(for: .seconds(pause / 3))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// KemoSabe that never has to answer (these tests don't ask it anything).
struct SilentKemoSabe: KemoSabeAnswering {
    let device = "Mac"
    func ask(_ question: KemoSabeQuestion, consent: @escaping @Sendable () async -> ConsentChoice,
             share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard {
        GateAnswerCard(exchange: question.exchange, askerName: question.asker.name, question: question.question, outcome: .nothingToShare, device: device)
    }
}

@MainActor func makeDock(file: URL? = nil, runner: any BotTurnRunning = SlowRunner()) -> BotDock {
    BotDock(store: BotDockStore(file: file)) { thread, bots in
        ChatSession(thread: thread, bots: bots, runner: runner, gate: SilentKemoSabe())
    }
}

/// Waits until `condition` holds (or a few seconds pass), checking every 20 ms.
@MainActor func waitUntil(_ seconds: Double = 5, until condition: () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 50) {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

func temporaryFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
}
#endif
