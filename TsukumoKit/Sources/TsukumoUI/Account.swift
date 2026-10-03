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
        appleID.remove()
        account = nil
        save()
        onChange?(nil)
    }
    public func finishOnboarding() {
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

/// The account and sync in a few lines, for Settings, Account on iPhone and the dock's settings on a Mac.
public struct AccountSummary: View {
    let accounts: AccountStore
    let syncTitle: String
    let syncDetail: String
    let syncOn: Bool
    let fixtureSignIn: Bool
    let device: String
    @State private var problem: String?
    @Environment(\.colorScheme) private var scheme

    public init(accounts: AccountStore, syncTitle: String, syncDetail: String, syncOn: Bool, fixtureSignIn: Bool = false, device: String) {
        self.accounts = accounts; self.syncTitle = syncTitle; self.syncDetail = syncDetail; self.syncOn = syncOn
        self.fixtureSignIn = fixtureSignIn; self.device = device
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: accounts.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.system(size: 34)).foregroundStyle(TsukumoTheme(scheme).accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accounts.account.map { $0.name.isEmpty ? "Signed in" : $0.name } ?? "Not signed in").font(.headline)
                        .accessibilityIdentifier("accountName")
                    Text(accounts.isSignedIn ? "With Apple, on this \(device)" : "Your bots and chats stay on this \(device).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: syncOn ? "icloud" : "icloud.slash").foregroundStyle(syncOn ? TsukumoTheme(scheme).accent : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(syncTitle).font(.subheadline.weight(.semibold)).accessibilityIdentifier("syncStatus")
                    Text(syncDetail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if accounts.isSignedIn {
                Button("Sign Out", role: .destructive) { accounts.signOut() }
                    .accessibilityIdentifier("signOut")
            } else {
                AppleSignInButton(accounts: accounts, fixture: fixtureSignIn) { problem = $0 }
            }
            // Only after a tap, and calm: a build without the capability says why; it isn't a fault.
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("signInNote")
            }
        }
        .padding(.vertical, 4)
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
    static let height: CGFloat = 32
    static let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    #else
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
