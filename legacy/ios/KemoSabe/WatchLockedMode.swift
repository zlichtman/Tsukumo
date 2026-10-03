import Foundation
import FoundationModels
import Security
import UIKit

/// Answers a watch request while the iPhone is locked (the owner's instruction, September 25, 2026).
///
/// KemoSabe's own data (state.json with chats and memories, the memory database, the routine
/// ledger) stays at complete protection, so it can't be read while the iPhone is locked, and the
/// full harness can't run. Instead a watch request answered while locked uses a small working set:
///
/// - `working-set.json`: which model answers (Apple on-device, or one connected model's name,
///   endpoint, and model ID). No chats, memories, People, or keys. Protected until first unlock.
/// - The selected connected model's API key, whose Keychain item is readable after first unlock.
///   Every other key stays readable only while unlocked.
/// - `inbox/`: each exchange answered while locked, written with complete-unless-open protection,
///   so it can be created while locked but not read again until the iPhone unlocks. After unlock
///   it moves into the conversation of the model that answered and the file is deleted.
///
/// A locked answer uses no history, memories, or tools. A request to remember something, set a
/// reminder or alarm, or a quick capture waits in the inbox and runs through the full harness
/// after unlock, so Kemo never claims work it couldn't do. When the on-device model or the key
/// can't be used while locked, the watch gets one line: "Unlock your iPhone to answer."
/// See design/ACCOUNTS-AND-PROFILES.md, "Watch requests while the iPhone is locked".
@MainActor final class LockedWatchMode {
    /// The one model a locked answer may use, chosen on the iPhone while it was unlocked.
    struct WorkingSet: Codable, Equatable {
        /// `privateCloud` is Apple's Private Cloud Compute: Apple's model, so its exchanges join the on-device conversation.
        enum Route: String, Codable { case onDevice, privateCloud, api }
        var route: Route
        /// Only for `.api`: where the request goes and which model. Never the key.
        var profile: APIModelProfile?
    }
    /// A watch request made while the iPhone was locked.
    struct Exchange: Codable, Equatable, Identifiable {
        var id = UUID()
        var date = Date()
        /// What the person said or typed.
        var heard: String
        /// Answered while locked by this route (and connected model), or nil when it waits for
        /// the full harness after unlock.
        var route: WorkingSet.Route?
        var profileID: UUID?
        var reply: String?
        /// What runs after unlock, for a request that waits (a capture becomes a note or reminder request).
        var request: String?
    }
    enum Outcome: Equatable {
        case answered(String)
        case failed(String)
    }

    static let unlockToAnswer = "Unlock your iPhone to answer."
    static let waitsForUnlock = "Got it. Unlock your iPhone to finish."
    /// Class C: readable after the first unlock since restart, like the app's settings.
    static let workingSetProtection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication
    /// Class B: can be written while locked, but not read back until the iPhone unlocks.
    static let inboxProtection: Data.WritingOptions = .completeFileProtectionUnlessOpen

    private let folder: () -> URL
    private let keys: any APIKeyStoring
    /// Whether KemoSabe's protected files are readable. Injectable so tests can simulate a lock.
    var protectedDataAvailable: () -> Bool
    /// Whether Apple's on-device model says it can run, and its answer. Injectable for tests.
    var onDeviceAvailable: () -> Bool = { OnDeviceAssistant().isAvailable }
    var onDeviceReply: (String) async throws -> String = { message in
        try await OnDeviceAssistant().reply(to: message, history: [], memories: [], standupFormat: "")
    }
    /// Apple's Private Cloud answer with no history. Injectable for tests.
    var privateCloudReply: (String) async throws -> String = { message in
        let intro = await MainActor.run { CompanionIdentity.intro }
        return try await AppleSessions.make(.privateCloud, instructions: intro + " Answer briefly and plainly, in one to three spoken sentences.")
            .respond(to: String(message.prefix(2000)), options: GenerationOptions(maximumResponseTokens: 450)).content
    }
    /// A connected model's answer with no history. Injectable for tests.
    var apiReply: (APIModelProfile, String, String) async throws -> String = { profile, key, message in
        try await CompatibleAPIModel(profile: profile, key: key).reply(to: message, history: [], memories: [], standupFormat: "")
    }

    init(folder: @escaping () -> URL, keys: any APIKeyStoring = KeychainAPIKeys(),
         protectedDataAvailable: @escaping () -> Bool = { UIApplication.shared.isProtectedDataAvailable }) {
        self.folder = folder; self.keys = keys; self.protectedDataAvailable = protectedDataAvailable
    }

    var isLocked: Bool {
        #if DEBUG
        // Simulator check of the locked path, which a simulator can't produce: --simulate-locked.
        if ProcessInfo.processInfo.arguments.contains("--simulate-locked") { return true }
        #endif
        return !protectedDataAvailable()
    }
    private var workingSetURL: URL { folder().appendingPathComponent("working-set.json") }
    private var inboxURL: URL { folder().appendingPathComponent("inbox", isDirectory: true) }

    // MARK: Working set (written while unlocked)

    var workingSet: WorkingSet? {
        (try? Data(contentsOf: workingSetURL)).flatMap { try? JSONDecoder().decode(WorkingSet.self, from: $0) }
    }
    /// Records which model answers while locked, and makes only that model's key readable after
    /// first unlock. Call while unlocked, whenever the selected model may have changed.
    func refresh(route: KemoModelRoute, apple: AppleModel = .onDevice, profile: APIModelProfile?, allProfiles: [APIModelProfile]) {
        let next: WorkingSet? = switch route {
        case .onDevice: WorkingSet(route: apple == .privateCloud ? .privateCloud : .onDevice)
        case .api: profile.map { WorkingSet(route: .api, profile: $0) }
        }
        (keys as? KeychainAPIKeys)?.allowLockedUse(of: next?.profile?.id, among: allProfiles.map(\.id))
        guard next != workingSet else { return }
        guard let next, let data = try? JSONEncoder().encode(next) else { try? FileManager.default.removeItem(at: workingSetURL); return }
        try? FileManager.default.createDirectory(at: folder(), withIntermediateDirectories: true)
        try? data.write(to: workingSetURL, options: [.atomic, Self.workingSetProtection])
    }
    /// Removes the working set and returns every key to unlocked-only, as when no watch is paired.
    func clear(allProfiles: [APIModelProfile]) {
        (keys as? KeychainAPIKeys)?.allowLockedUse(of: nil, among: allProfiles.map(\.id))
        try? FileManager.default.removeItem(at: workingSetURL)
    }

    // MARK: Answering (while locked)

    /// Answers `text` while the iPhone is locked, or says in one line why it can't.
    func answer(_ text: String, capture: Bool) async -> Outcome {
        guard let set = workingSet else { return .failed(Self.unlockToAnswer) }
        if capture || ExplicitRequest.allows(.remember, in: text) || ExplicitRequest.allows(.alarm, in: text) {
            // Notes, reminders, and alarms need the full harness and review; they wait for unlock.
            let exchange = Exchange(heard: text, request: capture ? WatchCapture.request(text) : text)
            return (try? store(exchange)) != nil ? .answered(Self.waitsForUnlock) : .failed(Self.unlockToAnswer)
        }
        let reply: String
        switch set.route {
        case .onDevice:
            // Apple's model may not run while the iPhone is locked; never fall back to another destination.
            guard onDeviceAvailable() else { return .failed(Self.unlockToAnswer) }
            do { reply = try await onDeviceReply(text) } catch { return .failed(Self.unlockToAnswer) }
        case .privateCloud:
            // Apple's server model, falling back to Apple's on-device model (never another destination).
            if let answer = try? await privateCloudReply(text) { reply = answer }
            else if onDeviceAvailable(), let answer = try? await onDeviceReply(text) { reply = answer }
            else { return .failed(Self.unlockToAnswer) }
        case .api:
            guard let profile = set.profile, let key = try? keys.read(profile.id) else { return .failed(Self.unlockToAnswer) }
            do { reply = try await apiReply(profile, key, text) } catch { return .failed("\(profile.name) didn't answer. Try again.") }
        }
        let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return .failed(Self.unlockToAnswer) }
        // The answer still reaches the watch if the exchange can't be kept for the history.
        try? store(Exchange(heard: text, route: set.route, profileID: set.profile?.id, reply: answer))
        return .answered(answer)
    }
    private func store(_ exchange: Exchange) throws {
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(exchange).write(to: inboxURL.appendingPathComponent(exchange.id.uuidString + ".json"),
                                                 options: [.atomic, Self.inboxProtection])
    }

    // MARK: After unlock

    /// Exchanges made while locked, oldest first. Readable only after unlock.
    var inbox: [Exchange] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Exchange.self, from: $0) } }
            .sorted { $0.date < $1.date }
    }
    func remove(_ exchange: Exchange) {
        try? FileManager.default.removeItem(at: inboxURL.appendingPathComponent(exchange.id.uuidString + ".json"))
    }
    /// Moves answered exchanges into the conversation of the model that answered them, never
    /// another model's, and returns the requests still waiting for the full harness.
    func importAnswered(into store: AppStore) -> [Exchange] {
        guard !isLocked, !store.failedToLoad, store.storageError == nil else { return [] }
        var waiting: [Exchange] = []
        for exchange in inbox {
            guard let route = exchange.route, let reply = exchange.reply else { waiting.append(exchange); continue }
            store.appendWatchExchange(heard: exchange.heard, reply: reply, date: exchange.date, route: route, profileID: exchange.profileID)
            if store.storageError == nil { remove(exchange) } else { break }
        }
        return waiting
    }
}

extension AppStore {
    /// Adds an exchange answered while the iPhone was locked to the conversation it belongs to.
    /// A connected model's exchange goes only to that model's conversation (separate histories
    /// stay an information boundary); if that model was removed since, the exchange is dropped.
    func appendWatchExchange(heard: String, reply: String, date: Date, route: LockedWatchMode.WorkingSet.Route, profileID: UUID?) {
        switch route {
        case .onDevice, .privateCloud:
            let revision = state.contextRevision ?? 0
            state.messages = Array((state.messages + [ChatMessage(role: "You", text: heard, date: date, contextRevision: revision),
                                                      ChatMessage(role: "KemoSabe", text: reply, date: date, contextRevision: revision)]).suffix(80))
        case .api:
            guard let profileID, state.apiProfiles?.contains(where: { $0.id == profileID }) == true else { return }
            var conversations = state.apiConversations ?? [:]
            conversations[profileID.uuidString, default: []] += [ChatMessage(role: "You", text: heard, date: date),
                                                                 ChatMessage(role: "KemoSabe", text: reply, date: date)]
            state.apiConversations = conversations
        }
        save()
    }
}

extension KeychainAPIKeys {
    /// Makes `selected`'s key readable after first unlock, so a watch request can use it while the
    /// iPhone is locked, and every other key readable only while unlocked. Keys never leave this device.
    func allowLockedUse(of selected: UUID?, among ids: [UUID]) {
        for id in ids {
            let access = id == selected ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                        kSecAttrAccount as String: id.uuidString]
            SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: access] as CFDictionary)
        }
    }
    /// The Keychain accessibility class of a saved key, or nil when there is none.
    func accessibility(_ id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: id.uuidString, kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return (value as? [String: Any])?[kSecAttrAccessible as String] as? String
    }
}
