import Foundation

public protocol APIClient: Sendable {
    /// Must throw unless the server returned exactly HTTP 200 and a valid receipt.
    func upload(_ batch: SampleBatch) async throws -> UploadResponse
    func status() async throws -> JSONValue
}

public struct HTTPAPIClient: APIClient {
    public let settings: ServerSettings
    private let core: HTTPCore
    public init(settings: ServerSettings, token: @escaping HTTPCore.TokenProvider = { try TokenStore.read() },
                protocolClasses: [AnyClass] = []) {
        self.settings = settings
        core = HTTPCore(baseURL: settings.baseURL, token: token, protocolClasses: protocolClasses)
    }

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
        let data = try await request(method: "POST", path: "v2/samples", body: body)
        let response = try JSONDecoder().decode(UploadResponse.self, from: data)
        guard response.batch_id == batch.batch_id else { throw Failure.receiptMismatch }
        return response
    }
    public func status() async throws -> JSONValue {
        let data = try await request(method: "GET", path: "v2/sync/status", body: nil)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private func request(method: String, path: String, body: Data?) async throws -> Data {
        let result: (status: Int, data: Data, response: HTTPURLResponse)
        do {
            result = try await core.send(method: method, path: path, body: body,
                                         headers: body == nil ? [:] : ["Content-Encoding": "gzip"])
        } catch HTTPCore.Failure.missingToken { throw Failure.missingToken }
        catch HTTPCore.Failure.invalidResponse { throw Failure.invalidResponse }
        guard result.status == 200 else { throw Failure.http(result.status) }
        return result.data
    }
}
