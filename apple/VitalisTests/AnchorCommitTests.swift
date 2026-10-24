import Foundation
import XCTest
import VitalisKit

private struct FakeAPI: APIClient {
    enum Mode: Sendable { case ok, non200, networkError, reject, wrongReceipt }
    let mode: Mode
    var failingBatchID: String? = nil
    func upload(_ batch: SampleBatch) async throws -> UploadResponse {
        if batch.batch_id == failingBatchID { throw HTTPAPIClient.Failure.http(503) }
        switch mode {
        case .non200: throw HTTPAPIClient.Failure.http(503)
        case .networkError: throw URLError(.notConnectedToInternet)
        case .wrongReceipt: return UploadResponse(batchID: "wrong")
        case .reject: return UploadResponse(batchID: batch.batch_id, counts: ["rejected": 1], rejected: [RejectedItem(uuid: "sample", reason: "bad object")])
        case .ok: return UploadResponse(batchID: batch.batch_id)
        }
    }
    func status() async throws -> JSONValue { .object([:]) }
}

final class AnchorCommitTests: XCTestCase {
    private let client = ClientInfo(installID: "test", appVersion: "1", os: "iOS 18", model: "test")
    private func files() throws -> SyncFiles {
        try SyncFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    private func stage(_ files: SyncFiles) throws {
        var stager = PageStager(files: files, client: client)
        try stager.append(Sample(["uuid": .string("sample"), "type": .string("type")]))
        try stager.finish(type: "type", destination: "https://test", anchor: Data("new".utf8))
    }

    func testAnchorOnlyMovesAfter200() async throws {
        let files = try files()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try files.write(Data("old".utf8), to: files.anchorURL("type"))
        try stage(files)
        let before = try XCTUnwrap(files.load(PendingPage.self, from: files.pageURL("type")))
        let committer = PageCommitter(files: files)
        for mode: FakeAPI.Mode in [.non200, .networkError, .wrongReceipt] {
            do {
                try await committer.commit(type: "type", destination: "https://test", api: FakeAPI(mode: mode)) { _, _ in }
                XCTFail("Expected failure")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: files.anchorURL("type")), Data("old".utf8))
            let after = try XCTUnwrap(files.load(PendingPage.self, from: files.pageURL("type")))
            XCTAssertEqual(after.nextBatch, 0)
            XCTAssertEqual(after.batchIDs, before.batchIDs, "Retry must retain its original batch IDs")
        }
        try await committer.commit(type: "type", destination: "https://test", api: FakeAPI(mode: .ok)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: files.anchorURL("type")), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.pageURL("type").path))
    }

    func testRejectedItemsAreRecordedAndDoNotBlockAnchor() async throws {
        let files = try files()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try stage(files)
        try await PageCommitter(files: files).commit(type: "type", destination: "https://test", api: FakeAPI(mode: .reject)) { batch, receipt in
            var history = SyncHistory(); history.record(batch, response: receipt)
            try files.save(history, to: files.file("history.json"))
        }
        let history = try XCTUnwrap(files.load(SyncHistory.self, from: files.file("history.json")))
        XCTAssertEqual(history.batches.first?.rejected, [RejectedItem(uuid: "sample", reason: "bad object")])
        XCTAssertEqual(try Data(contentsOf: files.anchorURL("type")), Data("new".utf8))
    }

    func testCursorSkipsSuccessfulPostAfterLaterPostFails() async throws {
        let files = try files()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let batches = (0..<2).map { _ in SampleBatch(client: client, upserts: [Sample(["uuid": .string("sample"), "type": .string("type")])]) }
        for batch in batches { try files.save(batch, to: files.batchURL(batch.batch_id)) }
        let pending = PendingPage(type: "type", destination: "https://test", anchor: Data("new".utf8), batchIDs: batches.map(\.batch_id))
        try files.save(pending, to: files.pageURL("type"))
        do {
            let api = FakeAPI(mode: .ok, failingBatchID: batches[1].batch_id)
            try await PageCommitter(files: files).commit(type: "type", destination: "https://test", api: api) { batch, _ in
                XCTAssertEqual(batch.batch_id, batches[0].batch_id)
            }
            XCTFail("Expected second POST failure")
        } catch {}
        let interrupted = try XCTUnwrap(files.load(PendingPage.self, from: files.pageURL("type")))
        XCTAssertEqual(interrupted.nextBatch, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.anchorURL("type").path))
        try await PageCommitter(files: files).commit(type: "type", destination: "https://test", api: FakeAPI(mode: .ok)) { batch, _ in
            XCTAssertEqual(batch.batch_id, batches[1].batch_id)
        }
        XCTAssertEqual(try Data(contentsOf: files.anchorURL("type")), Data("new".utf8))
    }

    func testDifferentServerCannotConsumeStagedPage() async throws {
        let files = try files()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try stage(files)
        do {
            try await PageCommitter(files: files).commit(type: "type", destination: "https://other", api: FakeAPI(mode: .ok)) { _, _ in XCTFail("Must not send") }
            XCTFail("Expected destination mismatch")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.anchorURL("type").path))
    }
    func testReadinessFailureRetainsPendingPageAndOldAnchor() async throws {
        let files = try files()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try files.write(Data("old".utf8), to: files.anchorURL("type"))
        try stage(files)
        do {
            try await PageCommitter(files: files).commit(type: "type", destination: "https://test", api: FakeAPI(mode: .ok),
                beforeBatch: { throw CancellationError() }) { _, _ in XCTFail("Must not send while paused") }
            XCTFail("Expected cancellation")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: files.anchorURL("type")), Data("old".utf8))
        XCTAssertNotNil(try files.load(PendingPage.self, from: files.pageURL("type")))
    }

}
