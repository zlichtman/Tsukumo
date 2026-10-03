import Foundation
import TsukumoCore
import TsukumoEngines
import TsukumoPolicy
import TsukumoUI

/// The first run on iPhone (TsukumoUI's `OnboardingFlow`) on the app's own parts: the account, API
/// connections with keys in the Keychain, KemoSabe's Calendar and Reminders, and the bots.
extension AppModel: OnboardingHost {
    var deviceName: String { "iPhone" }
    var fixtureSignIn: Bool { launch.uiTesting }
    var appleIntelligence: (ready: Bool, text: String) { AppleOnDevice.status }

    private func provider(_ provider: OnboardingProvider) -> ConnectionRecord.Provider { provider == .claude ? .anthropic : .openAI }

    func isConnected(_ provider: OnboardingProvider) -> Bool {
        connections.contains { $0.provider == self.provider(provider) && hasKey($0.id) }
    }

    /// Checks the key against the provider's model list, then saves the connection (the key into this
    /// iPhone's Keychain only).
    func connect(_ provider: OnboardingProvider, key: String) async throws {
        let kind = self.provider(provider)
        if let detected = ConnectionRecord.Provider.detect(key: key), detected != kind {
            throw ModelCatalog.Failure.key
        }
        guard let endpoint = URL(string: kind.endpoint) else { throw ModelCatalog.Failure.unreachable }
        let models = try await ModelCatalog.models(provider: kind, endpoint: endpoint, key: key)
        let model = models.contains(kind.defaultModel) ? kind.defaultModel : models.first ?? kind.defaultModel
        let connection = try APIConnection.validated(id: connections.first { $0.provider == kind }?.id ?? UUID(), name: kind.title,
                                                     endpoint: kind.endpoint, model: model, wire: kind.wire)
        try save(connection: ConnectionRecord(connection: connection, provider: kind, models: models), key: key)
    }

    var onboardingSources: [OnboardingSource] {
        SourceKind.allCases.map { OnboardingSource(id: $0.rawValue, title: $0.title, symbol: $0.symbol, on: setting($0).on, level: setting($0).level) }
    }
    func setSource(_ id: String, on: Bool) async {
        guard let kind = SourceKind(rawValue: id) else { return }
        await set(kind, on: on)
    }
    func setSource(_ id: String, level: PrivacyLevel) async {
        guard let kind = SourceKind(rawValue: id) else { return }
        await set(kind, level: level)
    }

    func add(starter: StarterBot) -> BotSpec? {
        let (engine, model) = engine(for: starter)
        var bot = starter.bot(existing: bots, engine: engine)
        bot.model = model
        guard case .success(let valid) = bot.validated(existing: bots) else {
            // A bot with the starter's name is already here: number it.
            var rng = SeededGenerator()
            bot.name = BotNames.next(taken: bots.map(\.name), using: &rng)
            save(bot: bot)
            return bot
        }
        save(bot: valid)
        return valid
    }
}
