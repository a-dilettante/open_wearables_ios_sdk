import Foundation

/// Scripts HTTP responses for the SDK's foreground session, so the upload, token-refresh
/// and cancellation paths can be driven without a server.
///
/// Register it on a session configuration's `protocolClasses`. Note that `URLSession`
/// converts `httpBody` to a stream before a protocol sees the request, so assertions
/// should be made against headers rather than the body.
final class StubURLProtocol: URLProtocol {

    struct Reply {
        let status: Int
        let body: Data
        let error: Error?

        static func status(_ code: Int, _ json: String = "{}") -> Reply {
            Reply(status: code, body: Data(json.utf8), error: nil)
        }

        static func failure(_ error: Error) -> Reply {
            Reply(status: 0, body: Data(), error: error)
        }

        /// Never responds, leaving the task in flight until something cancels it.
        static let hang = Reply(status: hangStatus, body: Data(), error: nil)
    }

    private static let hangStatus = -1

    private static let lock = NSLock()
    private static var replyProvider: ((URLRequest) -> Reply)?
    private static var seenRequests: [URLRequest] = []

    // MARK: - Scripting

    static func install(_ reply: @escaping (URLRequest) -> Reply) {
        lock.lock()
        replyProvider = reply
        seenRequests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        replyProvider = nil
        seenRequests = []
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seenRequests
    }

    static func requests(matching pathFragment: String) -> [URLRequest] {
        requests.filter { $0.url?.path.contains(pathFragment) == true }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // The provider is read under the lock but called outside it, so a test closure
        // is free to inspect `requests` without deadlocking.
        StubURLProtocol.lock.lock()
        StubURLProtocol.seenRequests.append(request)
        let provider = StubURLProtocol.replyProvider
        StubURLProtocol.lock.unlock()

        guard let reply = provider?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        if reply.status == StubURLProtocol.hangStatus { return }

        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
