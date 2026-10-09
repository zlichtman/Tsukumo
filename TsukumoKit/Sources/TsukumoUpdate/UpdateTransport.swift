#if os(macOS)
import Foundation

/// How the updater reaches the website. Tests use a stand-in; the app uses `HTTPSUpdateTransport`.
public protocol UpdateTransport: Sendable {
    /// The body of `url`, at most `limit` bytes.
    func data(from url: URL, limit: Int, timeout: TimeInterval) async throws(UpdateFailure) -> Data
    /// Downloads `url` into `file` (created new), at most `limit` bytes.
    func download(from url: URL, to file: URL, limit: Int, timeout: TimeInterval) async throws(UpdateFailure)
}

/// HTTPS to zlichtman.com only: an ephemeral session with no cookies or cache, redirects followed only
/// within the same host, the body refused as soon as it passes its size cap (from Content-Length, or while
/// it arrives), an idle timeout, and an overall deadline. Only a 200 is accepted.
public final class HTTPSUpdateTransport: NSObject, UpdateTransport, URLSessionDataDelegate, @unchecked Sendable {
    private final class Job {
        let limit: Int
        let file: FileHandle?
        var data = Data()
        var received = 0
        var failure: UpdateFailure?
        let finish: (UpdateFailure?, Data) -> Void
        init(limit: Int, file: FileHandle?, finish: @escaping (UpdateFailure?, Data) -> Void) {
            self.limit = limit; self.file = file; self.finish = finish
        }
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var session: URLSession!

    /// `configuration` is for tests (a stand-in URLProtocol); it's made ephemeral-like either way.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Tsukumo-Updater"]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public func data(from url: URL, limit: Int, timeout: TimeInterval) async throws(UpdateFailure) -> Data {
        try await run(url, limit: limit, timeout: timeout, file: nil)
    }

    public func download(from url: URL, to file: URL, limit: Int, timeout: TimeInterval) async throws(UpdateFailure) {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else { throw .copyFailed }
        defer { try? handle.close() }
        _ = try await run(url, limit: limit, timeout: timeout, file: handle)
    }

    private func run(_ url: URL, limit: Int, timeout: TimeInterval, file: FileHandle?) async throws(UpdateFailure) -> Data {
        guard UpdatePolicy.isAllowed(url) else { throw .untrustedLocation }
        var request = URLRequest(url: url)
        request.timeoutInterval = min(timeout, 30)
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        let id = task.taskIdentifier
        let result: Result<Data, UpdateFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, UpdateFailure>, Never>) in
                let job = Job(limit: limit, file: file) { failure, data in
                    continuation.resume(returning: failure.map { .failure($0) } ?? .success(data))
                }
                lock.withLock { jobs[id] = job }
                task.resume()
                // The overall deadline: a stalled server can't leave "Checking…" or "Downloading…" up forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak task] in task?.cancel() }
            }
        } onCancel: {
            task.cancel()
        }
        return try result.get()
    }

    private func job(_ task: URLSessionTask) -> Job? { lock.withLock { jobs[task.taskIdentifier] } }

    private func fail(_ task: URLSessionTask, _ failure: UpdateFailure) {
        if let job = job(task), job.failure == nil { job.failure = failure }
        task.cancel()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Within zlichtman.com over HTTPS only (its /downloads/Tsukumo.dmg redirect is relative); anywhere else ends it.
        if UpdatePolicy.isAllowed(request.url) {
            completionHandler(request)
        } else {
            fail(task, .untrustedLocation)
            completionHandler(nil)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = job(dataTask) else { completionHandler(.cancel); return }
        guard UpdatePolicy.isAllowed(response.url) else { fail(dataTask, .untrustedLocation); completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            fail(dataTask, .badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)); completionHandler(.cancel); return
        }
        if response.expectedContentLength > Int64(job.limit) { fail(dataTask, .tooLarge); completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = job(dataTask), job.failure == nil else { return }
        job.received += data.count
        guard job.received <= job.limit else { fail(dataTask, .tooLarge); return }
        if let file = job.file {
            do { try file.write(contentsOf: data) } catch { fail(dataTask, .copyFailed) }
        } else {
            job.data.append(data)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = lock.withLock({ jobs.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = job.failure { job.finish(failure, Data()); return }
        if error != nil { job.finish(.offline, Data()); return }
        guard let http = task.response as? HTTPURLResponse, http.statusCode == 200 else {
            job.finish(.badResponse((task.response as? HTTPURLResponse)?.statusCode ?? 0), Data()); return
        }
        job.finish(nil, job.data)
    }
}
#endif
