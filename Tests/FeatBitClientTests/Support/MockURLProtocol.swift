import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `URLProtocol` stub for unit-testing networking without a real server (the Swift analogue of
/// OkHttp's `MockWebServer`). Install it via a `URLSessionConfiguration` and set ``handler``.
final class MockURLProtocol: URLProtocol {
    /// Returns `(statusCode, body)` for a given request. Set before issuing requests.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    /// Captures every request the SUT made, for assertions.
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// Captures request bodies (URLProtocol strips `httpBody` for stream uploads).
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() {
        handler = nil
        requests = []
        bodies = []
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
        if let body = request.httpBody {
            MockURLProtocol.bodies.append(body)
        } else if let stream = request.httpBodyStream {
            MockURLProtocol.bodies.append(MockURLProtocol.readStream(stream))
        }

        let (status, data) = MockURLProtocol.handler?(request) ?? (200, Data())
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
