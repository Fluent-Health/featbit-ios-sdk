import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `URLProtocol` stub for unit-testing networking without a real server (the Swift analogue of
/// OkHttp's `MockWebServer`).
///
/// Two APIs coexist:
///
/// 1. **Handler API** (pre-existing). Set ``handler`` to a closure that returns
///    `(statusCode, body)` for each request. Used by tests written before the
///    FIFO-stub migration.
///
/// 2. **FIFO stub queue API** (added for the hardening pass). Call
///    ``enqueue(status:headers:body:)`` (or the JSON variant) once per expected
///    request; requests pop stubs in FIFO order. Tests that need structural
///    assertions on the request body read from ``receivedRequests``. Reset with
///    ``reset()`` between tests.
///
/// If both are configured the handler wins. Prefer the FIFO API for new tests.
final class MockURLProtocol: URLProtocol {
    /// Returns `(statusCode, body)` for a given request. Set before issuing requests.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    /// Captures every request the SUT made, for assertions.
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// Captures request bodies (URLProtocol strips `httpBody` for stream uploads).
    nonisolated(unsafe) static var bodies: [Data] = []

    // MARK: FIFO stub queue

    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private static let queueLock = NSLock()
    nonisolated(unsafe) private static var stubs: [StubResponse] = []
    nonisolated(unsafe) private static var _receivedRequests: [URLRequest] = []

    /// FIFO-recorded requests (populated by both the handler and the stub-queue paths so
    /// callers can assert on requests regardless of which API produced the response).
    static var receivedRequests: [URLRequest] {
        queueLock.lock(); defer { queueLock.unlock() }
        return _receivedRequests
    }

    static func enqueue(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        queueLock.lock(); defer { queueLock.unlock() }
        stubs.append(StubResponse(statusCode: status, headers: headers, body: body))
    }

    static func enqueue(status: Int, jsonBody: String) {
        enqueue(status: status, headers: ["Content-Type": "application/json"], body: Data(jsonBody.utf8))
    }

    static func reset() {
        handler = nil
        requests = []
        bodies = []
        queueLock.lock()
        stubs.removeAll()
        _receivedRequests.removeAll()
        queueLock.unlock()
    }

    /// Builds a `URLSession` wired to this stub.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requests.append(request)
        var recorded = request
        if let body = request.httpBody {
            MockURLProtocol.bodies.append(body)
            recorded.httpBody = body
        } else if let stream = request.httpBodyStream {
            let body = MockURLProtocol.readStream(stream)
            MockURLProtocol.bodies.append(body)
            recorded.httpBody = body
        }
        MockURLProtocol.queueLock.lock()
        MockURLProtocol._receivedRequests.append(recorded)
        MockURLProtocol.queueLock.unlock()

        let (status, data): (Int, Data)
        if let handler = MockURLProtocol.handler {
            (status, data) = handler(request)
        } else {
            let stub: StubResponse? = MockURLProtocol.queueLock.withLock {
                MockURLProtocol.stubs.isEmpty ? nil : MockURLProtocol.stubs.removeFirst()
            }
            let s = stub ?? StubResponse(statusCode: 200, headers: [:], body: Data())
            status = s.statusCode
            data = s.body
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
