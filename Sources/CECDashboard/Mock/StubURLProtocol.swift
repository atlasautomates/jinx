import Foundation

/// A `URLProtocol` that answers canned pages, so the PAGED WALKS can be executed by
/// `--selftest` instead of only reasoned about.
///
/// Why this exists: the walks are the load-bearing claim of the leads snapshot —
/// cursor advance, empty-vs-short termination, the page cap, dedupe, and each read's
/// `ok` flag — and every one of them was pinned only at its pure parse seam. A
/// review mutation that flipped an unparseable send_queue page from "degraded" to
/// "fine" passed the entire suite, because nothing ever ran the loop. The repo's own
/// rule: a learning that isn't a test is a wish.
///
/// `SupabaseClient` already accepts an injected `URLSession`, so no production code
/// changes shape to be testable.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// One canned response.
    struct Response: Sendable {
        var status: Int = 200
        var body: String
        /// `Content-Range` value, for the `count=exact` path.
        var contentRange: String? = nil
    }

    /// Answers a request, or nil to 500. Set through `session(_:)`.
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Response?)?
    /// Every request the code under test issued, in order — so a test can assert
    /// HOW the walk paged, not just what it returned.
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    /// A session wired to `handler`. Not thread-safe across concurrent tests — the
    /// selftest is single-threaded and serial by construction.
    static func session(_ handler: @escaping @Sendable (URLRequest) -> Response?) -> URLSession {
        lock.lock()
        Self.handler = handler
        Self.requests = []
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Query value for `name` in the most recent request matching `table`.
    static func queryValues(_ name: String) -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return requests.map { req in
            guard let url = req.url,
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            return comps.queryItems?.first { $0.name == name }?.value
        }
    }

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let response = Self.handler?(request)
        Self.lock.unlock()

        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var headers = ["Content-Type": "application/json"]
        if let range = response.contentRange { headers["Content-Range"] = range }
        let http = HTTPURLResponse(url: url, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
