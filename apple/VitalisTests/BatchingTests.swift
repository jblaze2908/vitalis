import Foundation
import XCTest
import VitalisKit

final class BatchingTests: XCTestCase {
    private let client = ClientInfo(installID: "test", appVersion: "1", os: "iOS 18", model: "test")
    private func sample(_ id: Int, points: Int = 0) -> Sample {
        Sample(["uuid": .string("\(id)"), "type": .string("type"),
                "points": .array(Array(repeating: .array([.number(1)]), count: points))])
    }
    func testObjectCapIncludesDeletionsAndDailyStats() throws {
        let samples = (0..<4_999).map { sample($0) }
        let deletions = [Deletion(uuid: "deleted1", type: "type"), Deletion(uuid: "deleted2", type: "type")]
        let stats = [DailyStat(type: "type", day: "2026-10-23", tz: "UTC", sum: 1, min: nil, avg: nil, max: nil, unit: "count")]
        let batches = try Batcher.split(client: client, upserts: samples, deletions: deletions, dailyStats: stats)
        XCTAssertEqual(batches.map(\.objectCount), [5_000, 2])
        XCTAssertEqual(batches.flatMap(\.upserts), samples)
        XCTAssertEqual(batches.flatMap(\.deletions), deletions)
        XCTAssertEqual(batches.flatMap(\.daily_stats), stats)
        XCTAssertEqual(Set(batches.map(\.batch_id)).count, batches.count)
    }
    func testPointCapAndSingleSampleBoundary() throws {
        let samples = [sample(1, points: 100_000), sample(2, points: 100_000), sample(3, points: 1), sample(4, points: 200_000)]
        let batches = try Batcher.split(client: client, upserts: samples, deletions: [], dailyStats: [])
        XCTAssertEqual(batches.map(\.pointCount), [200_000, 1, 200_000])
        XCTAssertEqual(batches.flatMap(\.upserts), samples)
        XCTAssertThrowsError(try Batcher.split(client: client, upserts: [sample(5, points: 200_001)], deletions: [], dailyStats: []))
    }
    func testEmptyBatchProducesNoPost() throws {
        XCTAssertTrue(try Batcher.split(client: client, upserts: [], deletions: [], dailyStats: []).isEmpty)
    }
    func testDiskStagingMatchesBatcherCapsWithoutDroppingObjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try SyncFiles(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = [sample(1, points: 100_000), sample(2, points: 100_000), sample(3, points: 1)] +
            (4..<5_006).map { sample($0) }
        let expected = try Batcher.split(client: client, upserts: samples, deletions: [], dailyStats: [])
        var stager = PageStager(files: files, client: client)
        for sample in samples { try stager.append(sample) }
        try stager.finish(type: "type", destination: "https://test", anchor: Data([1]))
        let page = try XCTUnwrap(files.load(PendingPage.self, from: files.pageURL("type")))
        let actual = try page.batchIDs.map { id in try XCTUnwrap(files.load(SampleBatch.self, from: files.batchURL(id))) }
        XCTAssertEqual(actual.map(\.objectCount), expected.map(\.objectCount))
        XCTAssertEqual(actual.map(\.pointCount), expected.map(\.pointCount))
        XCTAssertEqual(actual.flatMap(\.upserts).map(\.uuid), samples.map(\.uuid))
        XCTAssertTrue(actual.allSatisfy { $0.objectCount <= 5_000 && $0.pointCount <= 200_000 })
    }

}
