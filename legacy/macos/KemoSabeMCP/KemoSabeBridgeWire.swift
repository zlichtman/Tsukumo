import Foundation
import Darwin

// The channel between the `kemosabe-mcp` helper (Tsukumo.app/Contents/Helpers) and the running
// Tsukumo app (design/CONTEXT-HARNESS.md#agents-asking-kemosabe). Compiled into both.
//
// - A Unix socket in Tsukumo's Application Support folder (`KemoSabeBridge/bridge.sock`). The folder
//   is 0700 and the socket 0600, so only this macOS user can reach it; the app also checks each
//   peer's user ID (`getpeereid`) and closes anything else.
// - A per-install secret (`KemoSabeBridge/secret`, 0600, 32 random bytes) that every request
//   carries and the app compares in constant time.
// - One request per connection: a JSON line in, a JSON line out. No network, no port.

enum KemoSabeBridgeWire {
    static let version = 1
    static let socketName = "bridge.sock"
    static let secretName = "secret"
    /// Tests point the helper and the app at a temporary folder.
    static let folderEnvironment = "KEMOSABE_BRIDGE_DIR"
    /// The longest line either side accepts.
    static let maxLine = 64 * 1024

    /// `~/Library/Application Support/Tsukumo/KemoSabeBridge`, or the folder a test names.
    static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment[folderEnvironment], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Tsukumo/KemoSabeBridge", isDirectory: true)
    }

    struct Client: Codable, Equatable, Sendable {
        var name: String?
        var title: String?
        var version: String?
    }

    /// Helper → app.
    struct Request: Codable, Equatable, Sendable {
        var v = KemoSabeBridgeWire.version
        var secret: String
        /// The identity the connection's config gave the helper (`--agent claude-code`), if any.
        var agent: String?
        /// The MCP client's own `clientInfo`.
        var client: Client?
        var question: String
        var purpose: String
        /// The KemoSabe chat hand-off that started this agent (`--handoff`), so its chat shows the exchange.
        var handoff: String?
    }

    /// App → helper. `status` is one of `Status`; `text` is what the agent reads.
    struct Response: Codable, Equatable, Sendable {
        var v = KemoSabeBridgeWire.version
        var status: String
        var text: String
    }

    enum Status: String, Sendable {
        /// KemoSabe answered; `text` is exactly what was shared.
        case answered
        case notFound
        /// The owner said no (to the agent, or to this item).
        case declined
        /// The owner hasn't answered the prompt yet.
        case waiting
        /// Locked, signed out, or Apple's on-device model isn't ready.
        case unavailable
        /// The request itself was refused (malformed, wrong secret, too long).
        case refused
        /// Only the helper uses this: nothing is listening.
        case notRunning
        /// Whether the agent should read it as a tool error.
        var isError: Bool { ![.answered, .notFound].contains(self) }
    }

    /// Equal lengths and bytes, compared without an early exit.
    static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// The socket's address, or nil when the path is too long for `sun_path`.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Reads bytes until a newline, the limit, a timeout, or the end. Nil on any of the last three
    /// without a full line.
    static func readLine(_ fd: Int32, limit: Int = maxLine) -> Data? {
        var data = Data(), byte: UInt8 = 0
        while data.count < limit {
            let count = read(fd, &byte, 1)
            if count == 1 {
                if byte == UInt8(ascii: "\n") { return data }
                data.append(byte)
            } else if count < 0, errno == EINTR { continue }
            else { return nil }
        }
        return nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    static func setTimeout(_ fd: Int32, seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The helper's side: one request, one response. Nil status `notRunning` when nothing listens.
    static func send(_ request: Request, folder: URL, timeout: Int) -> Response {
        let path = folder.appendingPathComponent(socketName).path
        guard var address = address(path) else { return .init(status: Status.notRunning.rawValue, text: "The KemoSabe socket path is too long.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .init(status: Status.notRunning.rawValue, text: "Couldn't open a socket.") }
        defer { close(fd) }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            return .init(status: Status.notRunning.rawValue, text: "KemoSabe isn't running. Ask the owner to open Tsukumo on this Mac, then ask again.")
        }
        setTimeout(fd, seconds: timeout)
        guard let body = try? JSONEncoder().encode(request), writeAll(fd, body + Data([UInt8(ascii: "\n")])) else {
            return .init(status: Status.notRunning.rawValue, text: "KemoSabe closed the connection.")
        }
        guard let line = readLine(fd), let response = try? JSONDecoder().decode(Response.self, from: line) else {
            return .init(status: Status.waiting.rawValue, text: "KemoSabe didn't answer in time. The owner may still be deciding; ask again in a minute.")
        }
        return response
    }
}
