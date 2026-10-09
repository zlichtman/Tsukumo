import Foundation
import Observation
import ServiceManagement

/// Opening Tsukumo when you log in (`SMAppService.mainApp`): on by default once the first run is done
/// (only for a copy in /Applications, so a build run from Xcode or a disk image never registers), and a
/// switch in Settings, General.
@MainActor @Observable final class LaunchAtLogin {
    /// Where the login item really is (`SystemLoginItem`), or a stand-in (`--ui-testing`).
    protocol Item {
        var status: SMAppService.Status { get }
        func register() throws
        func unregister() throws
    }

    private let item: any Item
    private let defaults: UserDefaults?
    private(set) var status: SMAppService.Status
    private(set) var problem: String?
    static let defaultedKey = "launchAtLoginDefaulted"

    init(item: any Item, defaults: UserDefaults?) {
        self.item = item
        self.defaults = defaults
        status = item.status
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    /// macOS asks the owner to allow it in System Settings, General, Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ on: Bool) {
        do {
            if on { try item.register() } else { try item.unregister() }
            problem = nil
        } catch {
            problem = on ? "Tsukumo couldn’t add itself to your login items. Add it in System Settings, General, Login Items."
                         : "Tsukumo couldn’t remove itself from your login items. Remove it in System Settings, General, Login Items."
        }
        status = item.status
        defaults?.set(true, forKey: Self.defaultedKey)
    }

    /// After the first run: on, once. The owner's own choice in Settings is never overridden.
    func turnOnByDefault(appPath: String) {
        guard defaults?.bool(forKey: Self.defaultedKey) != true else { return }
        guard defaults == nil || appPath.hasPrefix("/Applications/") else { return }
        if !isOn { set(true) } else { defaults?.set(true, forKey: Self.defaultedKey) }
    }

    func refresh() { status = item.status }
}

/// The real login item: this app.
struct SystemLoginItem: LaunchAtLogin.Item {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// A login item that only remembers (`--ui-testing`: the owner's login items are never touched).
final class StandInLoginItem: LaunchAtLogin.Item {
    private var on = false
    var status: SMAppService.Status { on ? .enabled : .notRegistered }
    func register() throws { on = true }
    func unregister() throws { on = false }
}
