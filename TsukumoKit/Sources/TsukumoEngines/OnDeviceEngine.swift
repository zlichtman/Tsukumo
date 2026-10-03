import Foundation
import TsukumoCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A language model on this device: text in, text out, streamed as deltas.
public protocol OnDeviceLanguageModel: Sendable {
    var isAvailable: Bool { get }
    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error>
}

/// KemoSabe the bot: Apple's on-device model (ported from the app's Foundation Models path). Nothing
/// leaves the device, so it has no `ask_kemosabe`; it may be given Device only references directly
/// (the policy allows an on-device recipient), and it offers no tools in v1.
public struct OnDeviceEngine: Engine {
    public let model: any OnDeviceLanguageModel
    public var id: EngineID { .appleOnDevice }
    public init(model: any OnDeviceLanguageModel) { self.model = model }

    public func run(_ turn: EngineTurn) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard model.isAvailable else { continuation.finish(throwing: EngineError.notOnThisDevice); return }
                do {
                    var text = ""
                    for try await delta in model.stream(instructions: turn.systemPrompt, prompt: Self.prompt(turn)) {
                        try Task.checkCancellation()
                        text += delta
                        continuation.yield(.text(delta))
                    }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.incomplete }
                    continuation.yield(.done(EngineReply(text: text)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The thread so far and the new message, as one prompt.
    static func prompt(_ turn: EngineTurn) -> String {
        let history = turn.history.suffix(12).map { ($0.role == .user ? "Owner: " : "\(turn.bot.name): ") + $0.text }
        return (history + ["Owner: " + turn.message]).joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
/// Apple's on-device model through Foundation Models (iOS 26, macOS 26).
@available(iOS 26, macOS 26, *)
public struct AppleOnDeviceModel: OnDeviceLanguageModel {
    public init() {}
    public var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why Apple's model can't answer here, in words to show, or nil when it's ready.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off. Turn it on in Settings, under Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .unavailable(.deviceNotEligible): "This device can’t run Apple Intelligence. Add a model connection in Settings to chat."
        case .unavailable: "Apple Intelligence isn’t available right now."
        }
    }
    public func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        let content = snapshot.content
                        // Snapshots are cumulative; pass on only what's new.
                        if content.hasPrefix(previous) { continuation.yield(String(content.dropFirst(previous.count))) }
                        else { continuation.yield(content) }
                        previous = content
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: OnDeviceProblem(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A Foundation Models error, in words to show instead of the framework's own.
@available(iOS 26, macOS 26, *)
public struct OnDeviceProblem: LocalizedError, Sendable {
    public let errorDescription: String?
    init(_ error: LanguageModelSession.GenerationError) {
        errorDescription = switch error {
        case .exceededContextWindowSize: "This chat is longer than Apple’s on-device model can read. Start a new chat."
        case .assetsUnavailable: "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .guardrailViolation, .refusal: "Apple’s on-device model won’t answer that."
        case .unsupportedLanguageOrLocale: "Apple’s on-device model doesn’t support this language yet."
        case .rateLimited, .concurrentRequests: "Apple’s on-device model is busy. Try again in a moment."
        default: "Apple’s on-device model couldn’t answer just now. Try again."
        }
    }
}
#endif
