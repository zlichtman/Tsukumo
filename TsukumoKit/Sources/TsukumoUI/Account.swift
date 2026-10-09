import AuthenticationServices
import Foundation
import Observation
import Security
import SwiftUI
import TsukumoCore

// The owner's Tsukumo account, made with Sign in with Apple, and whether the first run is done. The
// account is local: a name and when it was made, saved in the app's folder; the Apple user ID that
// identifies it is in the Keychain on this device only. Sync uses the owner's own iCloud, so the
// account is what turns sync on; "Continue without an account" leaves it off.

/// The owner's account on this device.
public struct TsukumoAccount: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case apple
        /// UI tests' and screenshots' stand-in for Sign in with Apple (`--ui-testing`).
        case fixture
    }
    /// The name Apple shared the first time, or what the owner typed; may be empty.
    public var name: String
    public var method: Method
    public var created: Date
    public init(name: String, method: Method, created: Date = Date()) { self.name = name; self.method = method; self.created = created }
}

/// Where the Apple user ID is kept.
public protocol AppleIDStore: Sendable {
    func save(_ userID: String) throws
    func read() -> String?
    func remove()
}

/// The Keychain, this device only (never synced, never in a backup another device restores).
public struct KeychainAppleIDStore: AppleIDStore {
    public let service: String
    public init(service: String) { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "apple-user-id"]
    }
    public func save(_ userID: String) throws {
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(userID.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
    }
    public func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func remove() { SecItemDelete(query as CFDictionary) }
}

/// In memory, for tests and previews.
public final class MemoryAppleIDStore: AppleIDStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func save(_ userID: String) throws { lock.withLock { value = userID } }
    public func read() -> String? { lock.withLock { value } }
    public func remove() { lock.withLock { value = nil } }
}

public enum AccountError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    case signIn(String)
    public var errorDescription: String? {
        switch self {
        case .keychain: "Tsukumo couldn’t keep your sign-in in the Keychain. Try again."
        case .signIn(let message): message
        }
    }
}

/// The account and the first run, saved as `account.json` in the folder the app picks.
@MainActor @Observable public final class AccountStore {
    /// The host may refuse persisted mutations while its store is recovering.
    @ObservationIgnored public var canWrite: @MainActor () -> Bool = { true }
    public private(set) var account: TsukumoAccount?
    /// The first run is done (with or without an account).
    public private(set) var onboarded: Bool
    @ObservationIgnored public let appleID: any AppleIDStore
    @ObservationIgnored private let file: URL?
    /// Signed in or out (sync follows).
    @ObservationIgnored public var onChange: ((TsukumoAccount?) -> Void)?

    private struct Saved: Codable { var account: TsukumoAccount?; var onboarded: Date? }

    public init(file: URL?, appleID: any AppleIDStore) {
        self.file = file; self.appleID = appleID
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? TsukumoJSON.decoder.decode(Saved.self, from: $0) }
        account = saved?.account
        onboarded = saved?.onboarded != nil
        // An account whose Apple user ID is gone from the Keychain (a restore to a new device) signs in again.
        if account != nil && appleID.read() == nil { account = nil }
    }

    public var isSignedIn: Bool { account != nil }

    /// Makes the account from Sign in with Apple's answer: the user ID into the Keychain, the name here.
    public func signIn(userID: String, name: String, method: TsukumoAccount.Method = .apple) throws {
        guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
        try appleID.save(userID)
        let kept = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Apple shares the name only the first time; keep the one we have after that.
        account = TsukumoAccount(name: kept.isEmpty ? (account?.name ?? "") : kept, method: method)
        save()
        onChange?(account)
    }
    /// The answer from `SignInWithAppleButton`.
    public func signIn(with result: Result<ASAuthorization, Error>) -> String? {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return "Sign in with Apple didn’t answer. Try again." }
            let name = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) } ?? ""
            do { try signIn(userID: credential.user, name: name) } catch { return error.localizedDescription }
            return nil
        case .failure(let error):
            if let error = error as? ASAuthorizationError, error.code == .canceled { return nil }
            return "Sign in with Apple isn’t turned on in this build of Tsukumo yet. Your bots and chats stay on this device for now; you can sign in later in Settings, Account."
        }
    }
    /// Signs out on this device: the account and its Apple user ID go; bots and chats stay here.
    public func signOut() {
        guard canWrite() else { return }
        appleID.remove()
        account = nil
        save()
        onChange?(nil)
    }
    public func finishOnboarding() {
        guard canWrite() else { return }
        onboarded = true
        save()
    }
    /// Asks Apple whether this Apple ID still allows Tsukumo (the owner can revoke it in Settings).
    public func checkAppleCredential() async {
        guard account?.method == .apple, let userID = appleID.read() else { return }
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
        if state == .revoked || state == .notFound { signOut() }
    }

    private func save() {
        guard let file else { return }
        let saved = Saved(account: account, onboarded: onboarded ? Date() : nil)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? TsukumoJSON.encoder.encode(saved).write(to: file, options: [.atomic])
    }
}

/// Sync's state for the account page, from the app's `LibrarySyncController`.
public struct AccountSync: Equatable, Sendable {
    public enum Tone: Sendable { case on, waiting, off, paused }
    /// The whole line ("Waiting for iCloud to be turned on for Tsukumo"), what VoiceOver reads.
    public var title: String
    /// The pill ("Waiting for iCloud").
    public var short: String
    public var detail: String
    public var tone: Tone
    public var lastSynced: Date?
    public init(title: String, short: String, detail: String, tone: Tone, lastSynced: Date? = nil) {
        self.title = title; self.short = short; self.detail = detail; self.tone = tone; self.lastSynced = lastSynced
    }
}

/// Settings, Account on iPhone and Mac (October 3). Signed out: KemoSabe's cloud in its palette, one headline
/// and one line, and Sign in with Apple at a sensible width; the note about a build without the capability
/// shows only after a tap. Signed in: the name with its initials, sync as a small pill with when it last
/// synced, and Sign Out as plain destructive text. What syncs and what never leaves is `SyncFacts`, once.
public struct AccountSummary: View {
    let accounts: AccountStore
    let companion: BotSpec
    let sync: AccountSync
    let fixtureSignIn: Bool
    let device: String
    @State private var problem: String?
    @Environment(\.colorScheme) private var scheme

    public init(accounts: AccountStore, companion: BotSpec = .kemoSabe(), sync: AccountSync, fixtureSignIn: Bool = false, device: String) {
        self.accounts = accounts; self.companion = companion; self.sync = sync; self.fixtureSignIn = fixtureSignIn; self.device = device
    }

    public var body: some View {
        if let account = accounts.account { signedIn(account) } else { signedOut }
    }

    private var signedOut: some View {
        let theme = TsukumoTheme(scheme)
        return VStack(spacing: 14) {
            KemoSabeFigure(bot: companion, shadow: false)
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Your bots, on every device").font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Sign in with Apple and your bots and chats stay in step on your iPhone and Mac, through your own iCloud.")
                    .font(.system(size: 13)).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            AppleSignInButton(accounts: accounts, fixture: fixtureSignIn) { problem = $0 }
                .frame(width: AppleSignInButton.heroWidth)
                .padding(.top, 4)
            // Only after a tap, and calm: a build without the capability says why; it isn't a fault.
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
                    .accessibilityIdentifier("signInNote")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accountSignedOut")
    }

    private func signedIn(_ account: TsukumoAccount) -> some View {
        let theme = TsukumoTheme(scheme)
        let name = account.name.isEmpty ? "Signed in" : account.name
        return VStack(alignment: .leading, spacing: 14) {
            // The pill beside the name where it fits (a Mac), under it where it doesn't (an iPhone).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    InitialsAvatar(name: account.name, size: 52)
                    identity(name, theme: theme)
                    Spacer(minLength: 8)
                    SyncPill(sync: sync).fixedSize()
                }
                HStack(alignment: .top, spacing: 14) {
                    InitialsAvatar(name: account.name, size: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        identity(name, theme: theme)
                        SyncPill(sync: sync, alignment: .leading).fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(sync.detail).font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Sign Out", role: .destructive) { accounts.signOut() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("signOut")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accountSignedIn")
    }

    private func identity(_ name: String, theme: TsukumoTheme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 17, weight: .semibold)).accessibilityIdentifier("accountName")
            Text("With Apple, on this \(device)").font(.footnote).foregroundStyle(theme.secondary).fixedSize()
        }
    }
}

/// A person's initials on a soft disc in Tsukumo's coral.
public struct InitialsAvatar: View {
    let name: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    public init(name: String, size: CGFloat) { self.name = name; self.size = size }
    nonisolated static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).filter { $0.first?.isLetter == true }
        let letters = (words.count > 1 ? [words.first!, words.last!] : words.prefix(1).map { $0 }).compactMap(\.first)
        return letters.isEmpty ? "" : String(letters).uppercased()
    }
    public var body: some View {
        let accent = BotPalette.named("apricot").accentRGB
        let initials = Self.initials(name)
        ZStack {
            Circle().fill(LinearGradient(colors: [accent.mix(.white, 0.25).color, accent.color], startPoint: .top, endPoint: .bottom))
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Sync's state as a small pill, with when it last synced under it.
public struct SyncPill: View {
    let sync: AccountSync
    var alignment: HorizontalAlignment = .trailing
    @Environment(\.colorScheme) private var scheme
    public init(sync: AccountSync, alignment: HorizontalAlignment = .trailing) { self.sync = sync; self.alignment = alignment }
    public var body: some View {
        let color: Color = switch sync.tone {
        case .on: .green
        case .waiting: .orange
        case .paused: .yellow
        case .off: .secondary
        }
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(sync.short).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sync.title)
            .accessibilityIdentifier("syncStatus")
            if let last = sync.lastSynced {
                Text("Synced " + last.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(TsukumoTheme(scheme).secondary)
            }
        }
    }
}

/// What syncs through the owner's own iCloud, and what never leaves this device: two short columns of
/// icons and words, said once.
public struct SyncFacts: View {
    let device: String
    var columns: Bool
    @Environment(\.colorScheme) private var scheme
    public init(device: String, columns: Bool = true) { self.device = device; self.columns = columns }

    public static let syncs: [(symbol: String, text: String)] = [
        ("person.2", "Your bots and how they look"), ("bubble.left.and.bubble.right", "Your chats"),
        ("star", "The default model"), ("link", "Connections, without keys")
    ]
    public static func stays(_ device: String) -> [(symbol: String, text: String)] {
        [("key", "API keys"), ("lock.shield", "What KemoSabe reads, its answers, and its journal"),
         ("checkmark.shield", "Who KemoSabe answers"), (device == "Mac" ? "laptopcomputer" : "iphone", "Chats you keep on this \(device)")]
    }

    public var body: some View {
        let layout = columns ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            column("Syncs with iCloud", symbol: "icloud", items: Self.syncs)
            column("Never leaves this \(device)", symbol: "lock", items: Self.stays(device))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("syncFacts")
    }

    private func column(_ title: String, symbol: String, items: [(symbol: String, text: String)]) -> some View {
        let theme = TsukumoTheme(scheme)
        return VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.secondary)
            ForEach(items, id: \.text) { item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: item.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.accent).frame(width: 18)
                    Text(item.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sign in with Apple (Apple's own button, black in light and white in dark), or under `--ui-testing` a
/// stand-in drawn the same way that signs in a test owner. It takes the width it's given, so it lines up
/// with the content around it: on a Mac at a control's height (32 pt) with Apple's own corners, on
/// iPhone 50 pt tall as a capsule.
public struct AppleSignInButton: View {
    let accounts: AccountStore
    let fixture: Bool
    let failed: (String?) -> Void
    @Environment(\.colorScheme) private var scheme
    public init(accounts: AccountStore, fixture: Bool, failed: @escaping (String?) -> Void) {
        self.accounts = accounts; self.fixture = fixture; self.failed = failed
    }
    #if os(macOS)
    /// Its width in Settings, Account's hero.
    public static let heroWidth: CGFloat = 260
    static let height: CGFloat = 32
    static let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    #else
    public static let heroWidth: CGFloat = 300
    static let height: CGFloat = 50
    static let shape = Capsule()
    #endif
    public var body: some View {
        Group {
            if fixture {
                Button {
                    do { try accounts.signIn(userID: "fixture-000001", name: "Test Owner", method: .fixture); failed(nil) }
                    catch { failed(error.localizedDescription) }
                } label: {
                    Label("Sign in with Apple", systemImage: "apple.logo")
                        .font(.system(size: Self.height * 0.36, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: Self.height)
                        .foregroundStyle(scheme == .dark ? Color.black : .white)
                        .background(scheme == .dark ? Color.white : .black, in: Self.shape)
                        .contentShape(Self.shape)
                }
                .buttonStyle(.plain)
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    failed(accounts.signIn(with: result))
                }
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: Self.height)
                #if os(iOS)
                .clipShape(Capsule())
                #endif
            }
        }
        // Apple's button is at most 375 pt wide; the stand-in matches it.
        .frame(maxWidth: 375)
        .accessibilityIdentifier("signInWithApple")
    }
}
