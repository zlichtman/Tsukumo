#if os(macOS)
import Foundation
import os

// The Muse device API: the owner's leased VMs and rotating the device token. Ported from Meta's Muse
// Gadget SDK (Apache-2.0), `linux/src/musegadget/muse_api.py`: `api_url_v2` or https://api.muse.ai with
// bare paths, the refresh token sent as `hatch_refresh:<raw>` (never doubled, and the access token never
// presented), the SDK token in refresh bodies. Provenance: TsukumoKit/MUSE-NOTICE.md.

/// How the API is reached (URLSession in the app; a fake in tests, which never touch the network).
public protocol MuseHTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Where Tsukumo will send Muse's credentials: exactly the two hosts the SDK itself uses, and nothing else.
/// The API is `api.muse.ai` (`muse_api.py`'s `API_BASE`; the ESP32 firmware's `VM_API_DEFAULT_BASE_URL`) and
/// the Noise host is `hatch.metaaivm.com` (`service.py`'s `DEFAULT_NOISE_HOST`; the firmware's
/// `NOISE_DEFAULT_HOST`). The SDK builds no other host; `gadgets.muse.ai` is only the token website. Anything
/// else from provisioning, a saved pairing, or a redirect is refused and logged.
public enum MuseEndpoints {
    public static let apiHosts: Set<String> = ["api.muse.ai"]
    public static let noiseHosts: Set<String> = ["hatch.metaaivm.com"]
    static let log = Logger(subsystem: "com.zlichtman.tsukumo", category: "muse")

    static func allowed(_ host: String, in hosts: Set<String>) -> Bool { hosts.contains(host.lowercased()) }

    /// The API root for `api_url_v2`: Muse's own when it's empty; nil (refused) unless it's https on api.muse.ai
    /// with no credentials, port, query, or fragment.
    public static func apiRoot(_ apiURLv2: String) -> String? {
        if apiURLv2.isEmpty { return MuseAPI.base }
        guard let url = URLComponents(string: apiURLv2), url.scheme == "https", let host = url.host, allowed(host, in: apiHosts),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443, url.query == nil, url.fragment == nil else {
            log.error("refused a Muse API address that isn't Muse's")
            return nil
        }
        return apiURLv2.hasSuffix("/") ? String(apiURLv2.dropLast()) : apiURLv2
    }

    /// The Noise host: the SDK's default when it's empty; nil (refused) unless it's exactly the SDK's host.
    public static func noiseHost(_ host: String) -> String? {
        if host.isEmpty { return MuseService.defaultNoiseHost }
        let bare = host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
        guard bare, allowed(host, in: noiseHosts) else {
            log.error("refused a Muse Noise host that isn't Muse's")
            return nil
        }
        return host.lowercased()
    }
}

/// Refuses every redirect, so a bearer or device token never follows one to another origin.
final class MuseNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        MuseEndpoints.log.error("refused a redirect from the Muse API")
        return nil
    }
}

public struct URLSessionMuseHTTP: MuseHTTP {
    let session: URLSession
    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: MuseNoRedirects(), delegateQueue: nil)
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// One VM leased to the owner's Muse.
public struct MuseVM: Hashable, Sendable {
    public let url: String, authToken: String, name: String, id: String, isDefault: Bool
    public init(url: String, authToken: String, name: String = "", id: String = "", isDefault: Bool = false) {
        self.url = url; self.authToken = authToken; self.name = name; self.id = id; self.isDefault = isDefault
    }
}

public struct MuseAPI: Sendable {
    public static let base = "https://api.muse.ai"
    static let fetchPath = "/fetch_vms", refreshPath = "/device_token/refresh"
    public let http: any MuseHTTP
    public let userAgent: String

    public init(http: any MuseHTTP = URLSessionMuseHTTP(), version: String = "1") {
        self.http = http
        let os = ProcessInfo.processInfo.operatingSystemVersion
        userAgent = "TsukumoMuse/\(version) (macOS \(os.majorVersion).\(os.minorVersion))"
    }

    /// `api_url_v2`, or Muse's API; nil when it isn't one of Muse's (`MuseEndpoints`). `api_url` is ignored
    /// (only older firmware reads it).
    public static func root(_ apiURLv2: String = "") -> String? { MuseEndpoints.apiRoot(apiURLv2) }

    /// The leased VMs and the HTTP status (nil when no response came). A 401 means the device token was refused.
    public func fetchVMs(accessToken: String, root: String) async -> (vms: [MuseVM], status: Int?) {
        guard let url = URL(string: root + Self.fetchPath) else { return ([], nil) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "X-API-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await http.data(for: request) else { return ([], nil) }
        guard (200..<300).contains(response.statusCode) else { return ([], response.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], response.statusCode) }
        if object["error_title"] != nil || object["backend_error_code"] != nil { return ([], response.statusCode) }
        guard let list = object["vm_list"] as? [Any] else { return ([], response.statusCode) }
        let vms = list.compactMap { entry -> MuseVM? in
            guard let entry = entry as? [String: Any] else { return nil }
            guard let url = (entry["vm_ws_url"] as? String) ?? (entry["vm_url"] as? String), !url.isEmpty,
                  let token = entry["vm_auth_token"] as? String, !token.isEmpty else { return nil }
            return MuseVM(url: url, authToken: token, name: entry["vm_name"] as? String ?? "", id: entry["vm_id"] as? String ?? "",
                          isDefault: entry["default"] as? Bool ?? false)
        }
        return (vms, response.statusCode)
    }

    /// Rotates the device token pair. Returns the new tokens, or nil and the status that ended it (401: the
    /// pairing is gone).
    public func refresh(refreshToken: String, deviceID: String, root: String, sdkToken: String?) async -> (tokens: (access: String, refresh: String)?, status: Int?) {
        guard let url = URL(string: root + Self.refreshPath) else { return (nil, nil) }
        // Apps may hand over a refresh token that already has the prefix; doubling it is refused.
        let raw = refreshToken.components(separatedBy: ":").last ?? refreshToken
        var body: [String: String] = ["device_id": deviceID]
        if let sdkToken { body["sdk_token"] = sdkToken }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("Bearer hatch_refresh:\(raw)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await http.data(for: request) else { return (nil, nil) }
        guard (200..<300).contains(response.statusCode) else { return (nil, response.statusCode) }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, response.statusCode) }
        if let payload = object["payload"] as? [String: Any] { object = payload }
        guard let access = object["access_token"] as? String, !access.isEmpty, let refresh = object["refresh_token"] as? String, !refresh.isEmpty else {
            return (nil, response.statusCode)
        }
        return ((access, refresh), response.statusCode)
    }
}
#endif
