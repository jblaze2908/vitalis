import Foundation

/// The one request path shared by the exporter (`HTTPAPIClient`) and `VitalisAPI`.
/// One `URLSession` per instance; tokens are read per request and never logged.
public final class HTTPCore: Sendable {
    public typealias TokenProvider = @Sendable () throws -> String?

    public static let readTimeout: TimeInterval = 30
    public static let writeTimeout: TimeInterval = 60

    public enum Failure: Error, Sendable { case missingToken, invalidResponse }

    public let baseURL: URL
    private let token: TokenProvider
    private let session: URLSession

    /// `protocolClasses` lets tests route through a stub `URLProtocol`; ephemeral sessions ignore `registerClass`.
    public init(baseURL: URL, token: @escaping TokenProvider = { try TokenStore.read() },
                protocolClasses: [AnyClass] = []) {
        self.baseURL = baseURL
        self.token = token
        // Ephemeral and no URLCache: no cookies or health payloads on disk, and 304s reach the caller.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.writeTimeout
        configuration.timeoutIntervalForResource = Self.writeTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? []) }
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// `path` is relative to `baseURL` (a leading slash is ignored) and already percent-encoded (see `pathSegment`).
    public func url(path: String, query: [URLQueryItem] = []) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent(trimmed)
        }
        var base = components.percentEncodedPath
        if !base.hasSuffix("/") { base += "/" }
        components.percentEncodedPath = base + trimmed
        components.queryItems = query.isEmpty ? nil : query
        return components.url ?? baseURL.appendingPathComponent(trimmed)
    }

    /// Percent-encodes one path segment (ids, barcodes), including any `/`.
    public static func pathSegment(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// Returns the status and body for any HTTP status; throws only for transport or a missing token.
    public func send(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
                     headers: [String: String] = [:]) async throws -> (status: Int, data: Data, response: HTTPURLResponse) {
        guard let token = try token(), !token.isEmpty else { throw Failure.missingToken }
        var request = URLRequest(url: url(path: path, query: query),
                                 timeoutInterval: method == "GET" ? Self.readTimeout : Self.writeTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return (http.statusCode, data, http)
    }
}

/// Prevent forwarding the bearer token and health samples to a redirected server.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
