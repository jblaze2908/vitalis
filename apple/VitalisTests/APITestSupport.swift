import Foundation
import VitalisKit

private final class FixtureAnchor {}

enum Fixture {
    static let bundle = Bundle(for: FixtureAnchor.self)
    /// XcodeGen copies `Fixtures/api/*.json` flat into the test bundle.
    static func data(_ name: String) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).json"])
        }
        return try Data(contentsOf: url)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try APICoding.decoder().decode(T.self, from: data(name))
    }
    static var apiNames: [String] {
        (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []).map { $0.deletingPathExtension().lastPathComponent }
    }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("vitalis-tests-\(UUID().uuidString)", isDirectory: true)
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_792_800_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var closure: @Sendable () -> Date { { [self] in now } }
}

/// Routes requests by host so parallel tests never share a handler. No request leaves the process.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }
    enum Reply: Sendable {
        case http(Int, headers: [String: String] = [:], body: Data = Data())
        case failure(URLError)
    }
    typealias Handler = @Sendable (Recorded) -> Reply

    final class Host: @unchecked Sendable {
        let baseURL: URL
        private let lock = NSLock()
        private var handler: Handler
        private var log: [Recorded] = []
        init(baseURL: URL, handler: @escaping Handler) { self.baseURL = baseURL; self.handler = handler }
        func setHandler(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }
        var requests: [Recorded] { lock.withLock { log } }
        fileprivate func handle(_ request: Recorded) -> Reply {
            let handler = lock.withLock { log.append(request); return self.handler }
            return handler(request)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String: Host] = [:]

    static func register(_ handler: @escaping Handler = { _ in .http(404) }) -> Host {
        let name = "h\(UUID().uuidString.lowercased().prefix(12)).stub.invalid"
        let host = Host(baseURL: URL(string: "https://\(name)")!, handler: handler)
        lock.withLock { hosts[name] = host }
        return host
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let name = url.host,
              let host = Self.lock.withLock({ Self.hosts[name] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        let recorded = Recorded(method: request.httpMethod ?? "GET", url: url,
                                headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? readStream())
        switch host.handle(recorded) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}

    private func readStream() -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

extension VitalisAPI {
    static func stubbed(_ host: StubURLProtocol.Host, cache: ResponseCache? = nil, clock: TestClock = TestClock()) -> VitalisAPI {
        VitalisAPI(baseURL: host.baseURL, cache: cache, token: { "test-token" },
                   protocolClasses: [StubURLProtocol.self], now: clock.closure)
    }
}

/// Scripted transport: replies are consumed per call; once exhausted every call returns 200 `{}`.
actor FakeTransport: OutboxTransport {
    enum Reply: Sendable { case status(Int, String = "{}"), failure(URLError) }
    private var replies: [Reply]
    private(set) var sent: [APIRequest] = []
    private var onSend: (@Sendable (APIRequest) async -> Void)?
    init(_ replies: [Reply] = []) { self.replies = replies }
    func script(_ more: [Reply]) { replies.append(contentsOf: more) }
    func setOnSend(_ hook: (@Sendable (APIRequest) async -> Void)?) { onSend = hook }
    var paths: [String] { sent.map(\.path) }

    func perform(_ request: APIRequest) async throws -> (status: Int, body: Data) {
        sent.append(request)
        if let onSend { await onSend(request) }
        let reply = replies.isEmpty ? .status(200) : replies.removeFirst()
        switch reply {
        case .status(let code, let body): return (code, Data(body.utf8))
        case .failure(let error): throw error
        }
    }
}
