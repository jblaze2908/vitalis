import Foundation
import Testing
import VitalisKit
@testable import Vitalis

@MainActor @Suite struct SyncStoreTests {
    /// Stands in for Services' auth bookkeeping and the Keychain.
    final class Auth {
        var failureAt: Date?
        var failures = 0, oks = 0, resumes = 0
        var savedTokens: [String] = []
    }

    let now = ISO8601DateFormatter().date(from: "2026-10-24T04:11:00Z")!

    func defaults() -> UserDefaults {
        let name = "sync-store-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func make(_ auth: Auth, probe: @escaping @MainActor () async throws -> SyncStatus = { throw APIError.unauthorized },
              pending: [Outbox.Item] = [], batches: Int = 0, watch: Int = 0, clock: @escaping @MainActor () -> Date) -> SyncStore {
        SyncStore(deps: .init(
            authFailureAt: { auth.failureAt },
            noteAuthFailure: { auth.failures += 1; if auth.failureAt == nil { auth.failureAt = clock() } },
            noteAuthOK: { auth.oks += 1; auth.failureAt = nil },
            outbox: { (pending, []) },
            exporterPendingBatches: { batches },
            watchSetsHeld: { watch },
            probe: probe,
            resume: { auth.resumes += 1 },
            saveToken: { auth.savedTokens.append($0) },
            defaults: defaults(),
            now: clock))
    }

    func snapshot(error: String?, lastSuccess: Date?) -> SyncSnapshot {
        var h = SyncHistory(); h.lastError = error; h.lastSuccess = lastSuccess
        return SyncSnapshot(history: h)
    }

    // MARK: Counts

    @Test func countsAddExporterOutboxAndWatch() async throws {
        let outbox = try Outbox(directory: temporaryDirectory())
        let workout = WorkoutUpsert(session: .init(clientId: "c1", source: "phone", startedAt: "2026-10-24T09:00:00+05:30", tzOffsetMin: 330), sets: [])
        try await outbox.enqueue(.postWorkout(workout))
        try await outbox.enqueue(.postWeight(WeightEntry(id: "w1", kg: 76.4, measuredAt: "2026-10-24T08:00:00+05:30")))
        let store = make(Auth(), pending: await outbox.pendingItems, batches: 3, watch: 16, clock: { now })
        await store.refresh()
        #expect(store.counts == .init(exporterBatches: 3, outboxItems: 2, outboxWorkouts: 1, watchSetsHeld: 16))
        #expect(SyncStore.waitingCopy(store.counts)
                == "3 batches, 1 workout, 1 change and 16 Watch sets are waiting on this phone. They upload as soon as the token works.")
    }

    @Test func waitingCopyReadsNaturally() {
        #expect(SyncStore.waitingCopy(.init(exporterBatches: 3, outboxItems: 1, outboxWorkouts: 1))
                == "3 batches and 1 workout are waiting on this phone. They upload as soon as the token works.")
        #expect(SyncStore.waitingCopy(.init(exporterBatches: 1))
                == "1 batch is waiting on this phone. It uploads as soon as the token works.")
        #expect(SyncStore.waitingCopy(.init()).hasPrefix("Nothing is waiting"))
    }

    @Test func pendingBatchesComeFromThePageManifests() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var half = PendingPage(type: "a", destination: "x", anchor: Data(), batchIDs: ["1", "2", "3"])
        half.nextBatch = 1
        try JSONEncoder().encode(half).write(to: dir.appendingPathComponent("pending-a.json"))
        try JSONEncoder().encode(PendingPage(type: "b", destination: "x", anchor: Data(), batchIDs: ["4"]))
            .write(to: dir.appendingPathComponent("pending-b.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("batch-1.json"))
        #expect(SyncStore.countPendingBatches(in: dir) == 3)
        #expect(SyncStore.countPendingBatches(in: dir.appendingPathComponent("missing")) == 0)
    }

    // MARK: Token rejected

    @Test func apiAuthFailureShowsRejectedWithItsTime() {
        let auth = Auth()
        auth.failureAt = ISO8601DateFormatter().date(from: "2026-10-21T10:42:00Z")!
        let store = make(auth, clock: { now })
        #expect(store.tokenRejected)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        #expect(SyncStore.sinceLabel(store.rejectedSince!, calendar: cal) == "WED 4:12 PM")
    }

    @Test func exporter401IsRecordedAndClearedByTheNextUpload() {
        let auth = Auth()
        let clock = TestClock(now)
        let store = make(auth, clock: { clock.now })
        store.observe(snapshot(error: "HKQuantityTypeIdentifierStepCount: Server returned HTTP 401. The anchor was kept.",
                               lastSuccess: now.addingTimeInterval(-3_600)))
        #expect(store.exporterRejected)
        #expect(store.tokenRejected)
        #expect(auth.failureAt == now)
        clock.advance(600)
        // The engine keeps the old text after a later success.
        store.observe(snapshot(error: "HKQuantityTypeIdentifierStepCount: Server returned HTTP 401. The anchor was kept.", lastSuccess: clock.now))
        #expect(!store.exporterRejected)
        #expect(auth.failureAt == nil)
        #expect(!store.tokenRejected)
    }

    @Test func tryAgainClearsTheStateOnA200() async throws {
        let auth = Auth()
        auth.failureAt = now
        let status = try Fixture.decode(SyncStatus.self, "sync-status")
        let store = make(auth, probe: { status }, clock: { now })
        await store.tryAgain()
        #expect(auth.resumes == 1)
        #expect(auth.oks == 1)
        #expect(!store.tokenRejected)
        #expect(store.reachability == .reachable)
    }

    @Test func replaceTokenSavesThenRetries() async throws {
        let auth = Auth()
        auth.failureAt = now
        let store = make(auth, probe: { throw APIError.unauthorized }, clock: { now })
        try await store.replaceToken("vtl_new")
        #expect(auth.savedTokens == ["vtl_new"])
        #expect(auth.resumes == 1)
        // Still 401: the state stays, reachable but rejected.
        #expect(store.tokenRejected)
        #expect(store.reachability == .reachable)
    }

    @Test func unreachableProbeLeavesTheTokenAlone() async {
        let auth = Auth()
        let store = make(auth, probe: { throw APIError.transport(URLError(.cannotConnectToHost)) }, clock: { now })
        await store.probe()
        #expect(store.reachability == .unreachable)
        #expect(auth.failures == 0 && auth.oks == 0)
    }

    // MARK: Failure for StaleState

    @Test(arguments: [
        ("x: Server returned HTTP 401. The anchor was kept.", SyncFailure?.some(.unauthorized)),
        ("Save a Vitalis write token in Settings.", .unauthorized),
        ("x: Server returned HTTP 503. The anchor was kept.", .server(503)),
        ("Skipped: protected data is unavailable. Unlock the iPhone and sync again.", .protectedDataUnavailable),
        ("x: The Internet connection appears to be offline.", .unreachable),
        ("x: Could not connect to the server.", .unreachable),
        ("x: Something HealthKit said", nil),
    ])
    func classifiesEngineMessages(_ message: String, _ failure: SyncFailure?) {
        #expect(SyncStore.classify(message) == failure)
    }

    @Test func staleStateUsesTheCurrentExporterFailure() {
        let store = make(Auth(), clock: { now })
        store.observe(snapshot(error: "x: Could not connect to the server.", lastSuccess: now.addingTimeInterval(-13 * 3_600)))
        let state = store.staleState(lastSync: now.addingTimeInterval(-2 * 3_600), cachedAt: nil, refreshFailed: false)
        guard case .stale(_, _, let cause) = state.status else { Issue.record("not stale"); return }
        #expect(cause == "Your phone can't reach your server.")
    }

    @Test func anErrorBeforeTheLastSuccessIsHistory() {
        #expect(!SyncStore.isCurrent(errorSeenAt: now.addingTimeInterval(-60), lastSuccess: now))
        #expect(SyncStore.isCurrent(errorSeenAt: now, lastSuccess: now.addingTimeInterval(-60)))
        #expect(SyncStore.isCurrent(errorSeenAt: now, lastSuccess: nil))
        #expect(!SyncStore.isCurrent(errorSeenAt: nil, lastSuccess: nil))
    }

    @Test func agoLabels() {
        #expect(SyncStore.agoLabel(now.addingTimeInterval(-120), now: now) == "2 min ago")
        #expect(SyncStore.agoLabel(now.addingTimeInterval(-10), now: now) == "Just now")
        #expect(SyncStore.agoLabel(nil, now: now) == "Never")
    }
}
