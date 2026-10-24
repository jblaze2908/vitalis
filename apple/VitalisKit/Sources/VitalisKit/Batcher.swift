import Foundation

public enum BatchingError: LocalizedError {
    case oversizedSample(String, Int)
    public var errorDescription: String? {
        switch self {
        case .oversizedSample(let uuid, let count):
            return "Sample \(uuid) has \(count) points. The server contract needs lossless chunking before it can fit the point cap."
        }
    }
}

public enum Batcher {
    public static func split(client: ClientInfo, upserts: [Sample], deletions: [Deletion], dailyStats: [DailyStat],
                             objectCap: Int = 5_000, pointCap: Int = 200_000) throws -> [SampleBatch] {
        precondition(objectCap > 0 && pointCap > 0)
        var result: [SampleBatch] = []
        var batch = SampleBatch(client: client)
        var points = 0
        func flush() {
            guard batch.objectCount > 0 else { return }
            result.append(batch)
            batch = SampleBatch(client: client)
            points = 0
        }
        for sample in upserts {
            let count = sample.pointCount
            guard count <= pointCap else { throw BatchingError.oversizedSample(sample.uuid, count) }
            if batch.objectCount >= objectCap || points + count > pointCap { flush() }
            batch.upserts.append(sample)
            points += count
        }
        for deletion in deletions {
            if batch.objectCount >= objectCap { flush() }
            batch.deletions.append(deletion)
        }
        for stat in dailyStats {
            if batch.objectCount >= objectCap { flush() }
            batch.daily_stats.append(stat)
        }
        flush()
        return result
    }
}
