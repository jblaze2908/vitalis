import Foundation

public struct TypeHistory: Codable, Sendable {
    public var objectsSent = 0
    public var deletions = 0
    public var newestEnd: String?
    public var backgroundDelivery = "Not requested"
    public init() {}
}
public struct BatchHistory: Codable, Sendable, Identifiable {
    public var id: String
    public var date: Date
    public var upserts: Int
    public var deletions: Int
    public var dailyStats: Int
    public var counts: [String: Int]
    public var rejected: [RejectedItem]
}
public struct SyncHistory: Codable, Sendable {
    public var lastSuccess: Date?
    public var lastError: String?
    public var types: [String: TypeHistory] = [:]
    public var batches: [BatchHistory] = []
    public var diagnostics: [String] = []
    public init() {}

    public mutating func record(_ batch: SampleBatch, response: UploadResponse) {
        guard !batches.contains(where: { $0.id == batch.batch_id }) else { return }
        for sample in batch.upserts {
            var type = types[sample.type] ?? TypeHistory()
            type.objectsSent += 1
            // Compare actual instants rather than offset-bearing strings lexicographically.
            if let end = sample.end, isNewer(end, than: type.newestEnd) { type.newestEnd = end }
            types[sample.type] = type
        }
        for deletion in batch.deletions {
            var type = types[deletion.type] ?? TypeHistory(); type.deletions += 1
            types[deletion.type] = type
        }
        batches.insert(BatchHistory(id: batch.batch_id, date: Date(), upserts: batch.upserts.count,
            deletions: batch.deletions.count, dailyStats: batch.daily_stats.count,
            counts: response.counts, rejected: response.rejected), at: 0)
        if batches.count > 20 { batches.removeLast(batches.count - 20) }
        lastSuccess = Date()
    }
    private func isNewer(_ value: String, than previous: String?) -> Bool {
        guard let previous else { return true }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let left = formatter.date(from: value), let right = formatter.date(from: previous) else { return value > previous }
        return left > right
    }
}

public struct SyncSnapshot: Sendable {
    public var phase: String
    public var currentType: String?
    public var page: Int
    public var history: SyncHistory
    public init(phase: String = "Idle", currentType: String? = nil, page: Int = 0, history: SyncHistory = SyncHistory()) {
        self.phase = phase; self.currentType = currentType; self.page = page; self.history = history
    }
}
