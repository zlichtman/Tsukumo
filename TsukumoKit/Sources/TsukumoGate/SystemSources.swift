import Foundation
import TsukumoCore
import TsukumoPolicy

// The system's side of the catalog: each built-in source's permission, and the Gate's sources made from the
// owner's choices. The apps use these; tests pass fakes to `SourceLibrary` instead.

/// The system's permissions for each built-in source.
@MainActor public final class SystemSourceAuthorizer: SourceAuthorizing {
    /// This Mac's Messages history; nil keeps it closed (`--ui-testing`).
    let messages: MessagesDatabase?
    public init(messages: MessagesDatabase?) { self.messages = messages }

    public func status(_ kind: SourceKind) -> SourcePermission {
        switch kind {
        case .calendar, .reminders: return EventKitAccess.status(kind)
        case .contacts: return SystemContacts.status
        case .photos: return SystemPhotoLibrary.status
        case .messages:
            #if os(macOS)
            guard let messages else { return .unavailable("Messages isn’t read in this test run.") }
            switch messages.access() {
            case .granted: return .granted
            case .needsFullDiskAccess: return .denied
            case .noHistory: return .unavailable("There’s no Messages history on this Mac. Turn on Messages in iCloud in Messages’ settings.")
            }
            #else
            // On iPhone it reads only what the owner's automation gives it: nothing for the system to allow.
            return .granted
            #endif
        case .location:
            #if os(iOS)
            return SystemCoarseLocator.shared.permission
            #else
            return .unavailable("Not on this Mac.")
            #endif
        case .music:
            #if os(iOS)
            return SystemListening.status
            #else
            return .unavailable("Not on this Mac.")
            #endif
        case .mail, .files, .connector: return .granted
        }
    }

    public func request(_ kind: SourceKind) async -> SourcePermission {
        switch kind {
        case .calendar, .reminders: return await EventKitAccess.request(kind)
        case .contacts: return await SystemContacts.request()
        case .photos: return await SystemPhotoLibrary.request()
        case .location:
            #if os(iOS)
            return await SystemCoarseLocator.shared.request()
            #else
            return status(kind)
            #endif
        case .music:
            #if os(iOS)
            return await SystemListening.request()
            #else
            return status(kind)
            #endif
        default: return status(kind)
        }
    }

    public func settingsURL(_ kind: SourceKind) -> URL? {
        #if os(macOS)
        let pane: String? = switch kind {
        case .calendar: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        case .photos: "Privacy_Photos"
        case .messages: "Privacy_AllFiles"
        default: nil
        }
        return pane.flatMap { URL(string: "x-apple.systempreferences:com.apple.preference.security?" + $0) }
        #else
        return URL(string: "app-settings:")
        #endif
    }

    public func guidance(_ kind: SourceKind, _ permission: SourcePermission) -> String {
        if kind == .messages, SourceDevice.current == .mac, permission == .denied {
            return "Tsukumo needs Full Disk Access to read Messages on this Mac. Allow it in System Settings, Privacy & Security, Full Disk Access."
        }
        let device = SourceDevice.current
        switch permission {
        case .restricted: return "\(kind.title) is restricted on this \(device.name) by Screen Time or a device profile."
        case .unavailable(let why): return why
        case .notDetermined: return "Turn it off and on again to allow it."
        default:
            return device == .mac ? "Allow Tsukumo in System Settings, Privacy & Security, \(kind.title)." : "Allow Tsukumo in Settings, Apps, Tsukumo."
        }
    }
}

public extension SourceFactory {
    /// The Gate's real sources. `sharedMessages` is where the iPhone's automation keeps messages.
    static func system(messages: MessagesDatabase?, sharedMessages: SharedMessagesStore?) -> SourceFactory {
        SourceFactory(builtIn: { kind, level, settings in
            switch kind {
            case .calendar: return CalendarSource(level: level)
            case .reminders: return RemindersSource(level: level)
            case .contacts: return ContactsSource(level: level)
            case .photos: return PhotosSource(level: level)
            case .messages:
                #if os(macOS)
                guard let messages else { return nil }
                let contacts: (any ContactsReading)? = settings.setting(.contacts).on ? SystemContacts() : nil
                return MacMessagesSource(database: messages, level: level, contacts: contacts)
                #else
                return sharedMessages.map { SharedMessagesSource(store: $0, level: level) }
                #endif
            case .location:
                #if os(iOS)
                return LocationSource(level: level, locator: SystemCoarseLocator.shared)
                #else
                return nil
                #endif
            case .music:
                #if os(iOS)
                return MusicSource(level: level, reader: SystemListening())
                #else
                return nil
                #endif
            case .mail, .files, .connector: return nil
            }
        }, folder: { FolderSource(folder: $0) },
           account: { ConnectorSource(account: $0, token: $1) })
    }
}

// MARK: UI tests and screenshots

/// `--ui-testing`'s stand-in: every system permission reads as allowed and nothing is asked, so a test can
/// turn sources on without a system prompt. Pair it with `SourceFactory.empty`, so nothing is ever read.
@MainActor public final class StandInSourceAuthorizer: SourceAuthorizing {
    public init() {}
    public func status(_ kind: SourceKind) -> SourcePermission { .granted }
    public func request(_ kind: SourceKind) async -> SourcePermission { .granted }
    public func settingsURL(_ kind: SourceKind) -> URL? { nil }
}

/// A source that reads nothing.
public struct EmptySource: PersonalSource {
    public init() {}
    public func items(matching question: GateQuestion) async -> [PersonalItem] { [] }
}

public extension SourceFactory {
    /// Sources that read nothing (`--ui-testing`), so no test ever touches the owner's data.
    static let empty = SourceFactory(builtIn: { _, _, _ in EmptySource() }, folder: { _ in EmptySource() }, account: { _, _ in EmptySource() })
}
