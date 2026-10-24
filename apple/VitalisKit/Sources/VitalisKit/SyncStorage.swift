import CryptoKit
import Foundation

/// All health payloads and anchors stay in Application Support, never UserDefaults.
public struct SyncFiles: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    public static func applicationSupport() throws -> SyncFiles {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return try SyncFiles(root: base.appendingPathComponent("Vitalis", isDirectory: true))
    }
    public func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    public func key(_ type: String) -> String { SHA256.hash(data: Data(type.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(value), to: url)
    }
    public func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public func anchorURL(_ type: String) -> URL { file("anchor-\(key(type)).data") }
    public func pageURL(_ type: String) -> URL { file("pending-\(key(type)).json") }
    public func batchURL(_ id: String) -> URL { file("batch-\(id).json") }
}

public struct PendingPage: Codable, Sendable {
    public let type: String
    public let destination: String
    public let anchor: Data
    public let batchIDs: [String]
    public var nextBatch: Int
    public init(type: String, destination: String, anchor: Data, batchIDs: [String]) {
        self.type = type; self.destination = destination; self.anchor = anchor
        self.batchIDs = batchIDs; nextBatch = 0
    }
}

/// Stage one envelope at a time, retaining at most one capped batch in memory.
/// The pending manifest is written last; incomplete staging cannot advance an anchor.
public struct PageStager {
    private let files: SyncFiles
    private let client: ClientInfo
    private var batch: SampleBatch
    private var ids: [String] = []
    private var points = 0
    public init(files: SyncFiles, client: ClientInfo) {
        self.files = files; self.client = client; batch = SampleBatch(client: client)
    }
    public mutating func append(_ sample: Sample) throws {
        let count = sample.pointCount
        guard count <= 200_000 else { throw BatchingError.oversizedSample(sample.uuid, count) }
        if batch.objectCount >= 5_000 || points + count > 200_000 { try flush() }
        batch.upserts.append(sample)
        points += count
    }
    public mutating func append(_ deletion: Deletion) throws {
        if batch.objectCount >= 5_000 { try flush() }
        batch.deletions.append(deletion)
    }
    public mutating func append(_ stat: DailyStat) throws {
        if batch.objectCount >= 5_000 { try flush() }
        batch.daily_stats.append(stat)
    }
    public mutating func finish(type: String, destination: String, anchor: Data) throws {
        try flush()
        try files.save(PendingPage(type: type, destination: destination, anchor: anchor, batchIDs: ids), to: files.pageURL(type))
    }
    public mutating func discard() {
        for id in ids { try? FileManager.default.removeItem(at: files.batchURL(id)) }
        ids.removeAll()
    }
    private mutating func flush() throws {
        guard batch.objectCount > 0 else { return }
        try files.save(batch, to: files.batchURL(batch.batch_id))
        ids.append(batch.batch_id)
        batch = SampleBatch(client: client)
        points = 0
    }
}

public struct PageCommitter: Sendable {
    public let files: SyncFiles
    public init(files: SyncFiles) { self.files = files }
    public enum Failure: LocalizedError {
        case missingBatch, differentServer
        public var errorDescription: String? {
            switch self {
            case .missingBatch: "A staged batch is missing. Restore app data before syncing."
            case .differentServer: "This export belongs to a different server. Restore its URL or reset local export state."
            }
        }
    }

    /// A durable cursor skips acknowledged batches, including rejected objects. If a crash
    /// occurs after HTTP 200 but before the cursor write, retry uses the SAME batch_id.
    public func commit(type: String, destination: String, api: any APIClient,
                       beforeBatch: @Sendable () async throws -> Void = {},
                       didUpload: @Sendable (SampleBatch, UploadResponse) async throws -> Void) async throws {
        guard var page = try files.load(PendingPage.self, from: files.pageURL(type)) else { return }
        guard page.destination == destination else { throw Failure.differentServer }
        while page.nextBatch < page.batchIDs.count {
            try Task.checkCancellation()
            try await beforeBatch()
            let id = page.batchIDs[page.nextBatch]
            guard let batch = try files.load(SampleBatch.self, from: files.batchURL(id)) else { throw Failure.missingBatch }
            let receipt = try await api.upload(batch)
            guard receipt.batch_id == batch.batch_id else { throw HTTPAPIClient.Failure.receiptMismatch }
            // Persist history before the cursor, with batch-id deduplication at the caller.
            try await didUpload(batch, receipt)
            page.nextBatch += 1
            try files.save(page, to: files.pageURL(type))
        }
        try Task.checkCancellation()
        try await beforeBatch()
        // The anchor can move only after every envelope has a successful receipt.
        try files.write(page.anchor, to: files.anchorURL(type))
        try FileManager.default.removeItem(at: files.pageURL(type))
        for id in page.batchIDs { try? FileManager.default.removeItem(at: files.batchURL(id)) }
    }
}
