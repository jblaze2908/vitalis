import Foundation

public protocol APIClient: Sendable {
    /// Must throw unless the server returned exactly HTTP 200 and a valid receipt.
    func upload(_ batch: SampleBatch) async throws -> UploadResponse
    func status() async throws -> JSONValue
}

public struct HTTPAPIClient: APIClient {
    public let settings: ServerSettings
    public init(settings: ServerSettings) { self.settings = settings }

    public enum Failure: LocalizedError {
        case missingToken, invalidResponse, http(Int), receiptMismatch
        public var errorDescription: String? {
            switch self {
            case .missingToken: "Save a Vitalis write token in Settings."
            case .invalidResponse: "The server returned an invalid response."
            case .http(let status): "Server returned HTTP \(status). The anchor was kept."
            case .receiptMismatch: "The receipt batch_id does not match the uploaded batch."
            }
        }
    }

    public func upload(_ batch: SampleBatch) async throws -> UploadResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try Gzip.compress(encoder.encode(batch))
        let data = try await request(path: "v2/samples", body: body)
        let response = try JSONDecoder().decode(UploadResponse.self, from: data)
        guard response.batch_id == batch.batch_id else { throw Failure.receiptMismatch }
        return response
    }
    public func status() async throws -> JSONValue {
        let data = try await request(path: "v2/sync/status", body: nil)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private func request(path: String, body: Data?) async throws -> Data {
        guard let token = try TokenStore.read(), !token.isEmpty else { throw Failure.missingToken }
        var request = URLRequest(url: settings.baseURL.appendingPathComponent(path), timeoutInterval: 60)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        // An ephemeral session avoids cookies, credentials, or cached health payloads on disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        return data
    }
}

/// Prevent forwarding the bearer token and health samples to a redirected server.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
