import Foundation

// A minimal HTTP/1.1 for the gateway's own server: one request per connection, a body only by Content-Length,
// small limits everywhere. Written here (no dependency) because the gateway serves a handful of routes to a
// handful of clients, and a small parser is easier to check than a framework.

/// A request, once its headers and body are in.
public struct HTTPRequest: Sendable {
    public static let maxHeader = 16 * 1_024, maxBody = 15 * 1_024 * 1_024

    public var method: String
    /// The path without its query.
    public var path: String
    public var query: [String: String]
    /// Header names in lower case. A repeated header keeps its first value.
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    /// The bearer token, if the request has one.
    public var bearer: String? {
        guard let value = header("authorization"), value.count > 7, value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
    /// A form body (application/x-www-form-urlencoded), or the query for a GET.
    public var form: [String: String] { HTTPRequest.decodeForm(String(data: body, encoding: .utf8) ?? "") }

    public enum ParseResult: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        case complete(consumed: Int)
        /// Malformed, or over a limit: answer with this status and close.
        case invalid(Int)
    }

    /// Parses a request from the bytes so far.
    public static func parse(_ bytes: Data) -> (ParseResult, HTTPRequest?) {
        // Every index below is checked; nothing an unauthenticated sender writes can trap. (A copy, so indices start at 0.)
        let data = Data(bytes)
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return (data.count > maxHeader ? .invalid(431) : .incomplete, nil)
        }
        guard end.lowerBound <= maxHeader, let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return (.invalid(431), nil) }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, lines.count <= 100 else { return (.invalid(431), nil) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0", ["GET", "POST", "DELETE", "OPTIONS", "HEAD"].contains(parts[0]),
              parts[1].hasPrefix("/"), parts[1].count <= 4_096 else { return (.invalid(400), nil) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return (.invalid(400), nil) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return (.invalid(400), nil) }
            if headers[name] == nil { headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        if headers["transfer-encoding"] != nil { return (.invalid(501), nil) }
        var length = 0
        if let text = headers["content-length"] {
            guard let value = Int(text), value >= 0 else { return (.invalid(400), nil) }
            length = value
        }
        guard length <= maxBody else { return (.invalid(413), nil) }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return (.incomplete, nil) }
        let body = data[bodyStart..<(bodyStart + length)]
        let target = parts[1]
        let path: String, query: [String: String]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark]); query = decodeForm(String(target[target.index(after: mark)...]))
        } else {
            path = target; query = [:]
        }
        let request = HTTPRequest(method: parts[0], path: path.removingPercentEncoding ?? path, query: query, headers: headers, body: Data(body))
        return (.complete(consumed: bodyStart - data.startIndex + length), request)
    }

    static func decodeForm(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        func decode(_ value: String) -> String { value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value }
        // Never indexes past what's there: "=", "&&", "=x", and "a=" are all well-formed here.
        for pair in text.split(separator: "&", omittingEmptySubsequences: true).prefix(64) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let first = pieces.first else { continue }
            let key = decode(first)
            guard !key.isEmpty, key.count <= 128 else { continue }
            // A repeated parameter is refused by keeping neither (OAuth says parameters must not repeat).
            if result[key] != nil { result[key] = "" ; continue }
            result[key] = pieces.count > 1 ? decode(pieces[1]) : ""
        }
        return result
    }
}

/// A response.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    static func json(_ status: Int, _ text: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store")] + headers, body: Data(text.utf8))
    }
    static func html(_ status: Int, _ text: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-store"),
                                               ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'"),
                                               ("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer")] + headers,
                     body: Data(text.utf8))
    }
    static func redirect(_ location: String) -> HTTPResponse {
        HTTPResponse(status: 302, headers: [("Location", location), ("Cache-Control", "no-store"), ("Referrer-Policy", "no-referrer")])
    }
    static func status(_ status: Int, headers: [(String, String)] = []) -> HTTPResponse { HTTPResponse(status: status, headers: headers) }

    /// The bytes on the wire, closing the connection after.
    public var wire: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
