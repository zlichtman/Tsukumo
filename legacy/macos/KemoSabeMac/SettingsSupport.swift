import AppKit
import Foundation
import UserNotifications

/// The Git author name and email from the person's own configuration, read-only.
struct GitIdentity: Equatable {
    var name: String?
    var email: String?
    var version: String?
    static func load() async -> GitIdentity {
        await Task.detached(priority: .utility) {
            GitIdentity(name: run(["config", "--global", "user.name"]),
                        email: run(["config", "--global", "user.email"]),
                        version: run(["--version"]).map { $0.replacingOccurrences(of: "git version ", with: "") })
        }.value
    }
    private static func run(_ arguments: [String]) -> String? {
        // Only the real git; the /usr/bin shim would offer to install the developer tools.
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"]
        guard let git = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !text.isEmpty ? text : nil
    }
}

