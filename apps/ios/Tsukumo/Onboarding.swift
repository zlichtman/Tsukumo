import Foundation
import TsukumoCore
import TsukumoEngines
import TsukumoPolicy
import TsukumoUI
import TsukumoGate

/// The first run on iPhone (TsukumoUI's `OnboardingFlow`) on the app's own parts: the account, API
/// connections with keys in the Keychain (each brings its service's bot), and KemoSabe's everyday sources.
extension AppModel: OnboardingHost {
    var deviceName: String { "iPhone" }
    var fixtureSignIn: Bool { launch.uiTesting }
    var appleIntelligence: (ready: Bool, text: String) { AppleOnDevice.status }
    var kemoSabe: BotSpec { saved[0] }

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

    /// The first run offers the everyday few; the whole catalog is in Settings, KemoSabe.
    var onboardingSources: [OnboardingSource] {
        [SourceKind.calendar, .reminders, .contacts].compactMap { sources.entry($0.rawValue) }.map {
            OnboardingSource(id: $0.id, title: $0.title, symbol: $0.symbol, on: $0.isOn, level: $0.level)
        }
    }
    func setSource(_ id: String, on: Bool) async { await sources.set(id, on: on) }
    func setSource(_ id: String, level: PrivacyLevel) async { sources.set(id, level: level) }
}
