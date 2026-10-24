import Foundation
import Testing
import VitalisKit
@testable import Vitalis

/// In-memory outbox: `deliver` decides whether a queued write goes out at once or stays pending.
@MainActor
private final class FakeWrites: BodyStore.Writes {
    var deliver: Bool
    private(set) var sent: [APIRequest] = []
    private(set) var pending: Set<UUID> = []
    init(deliver: Bool) { self.deliver = deliver }

    func send(_ request: APIRequest) async -> UUID? {
        sent.append(request)
        let id = UUID()
        if !deliver { pending.insert(id) }
        return id
    }
    func drop(_ id: UUID) async -> Bool { pending.remove(id) != nil }
    func isPending(_ id: UUID) async -> Bool { pending.contains(id) }
}

@MainActor
struct BodyStoreTests {
    private static func host() throws -> StubURLProtocol.Host {
        let body = try Fixture.data("body")
        return StubURLProtocol.register { $0.url.path == "/v2/body" ? .http(200, body: body) : .http(404) }
    }

    private static func entry(_ request: APIRequest) throws -> WeightEntry {
        try APICoding.decoder().decode(WeightEntry.self, from: try #require(request.body))
    }

    private let at = Date(timeIntervalSince1970: 1_792_800_000)

    @Test func toggleOffWritesNothingToHealthButTheServerEntryAppears() async throws {
        let host = try Self.host()
        let health = FakeHealthWriter(), writes = FakeWrites(deliver: true)
        let store = BodyStore(api: { VitalisAPI.stubbed(host) }, health: health, writes: writes)

        await store.saveWeight(tenths: 766, at: at, alsoHealth: false)

        #expect(health.saved.isEmpty)
        let post = try #require(writes.sent.first)
        #expect(post.method == "POST" && post.path == "v2/weight")
        let entry = try Self.entry(post)
        #expect(entry.kg == 76.6)
        #expect(entry.hkUuid == nil)
        #expect(UUID(uuidString: entry.id) != nil)
        // Delivered: the server's weight block is refetched, nothing waits.
        #expect(store.waitingToSync == false)
        #expect(store.weight?.trendKg == 76.2)
        #expect(host.requests.contains { $0.url.path == "/v2/body" })
    }

    @Test func toggleOnSavesHealthSampleAndSendsItsUUID() async throws {
        let host = try Self.host()
        let health = FakeHealthWriter(), writes = FakeWrites(deliver: true)
        let store = BodyStore(api: { VitalisAPI.stubbed(host) }, health: health, writes: writes)

        await store.saveWeight(tenths: 766, at: at, alsoHealth: true)

        #expect(health.saved.values.sorted() == ["weight 76.6"])
        let hk = try #require(health.saved.keys.first)
        #expect(try Self.entry(try #require(writes.sent.first)).hkUuid == hk.uuidString)
        #expect(store.lastSaved?.hkUUID == hk)
    }

    @Test func undoBeforeSendDropsTheQueuedPostAndTheHealthSample() async throws {
        let host = try Self.host()
        let health = FakeHealthWriter(), writes = FakeWrites(deliver: false)
        let store = BodyStore(api: { VitalisAPI.stubbed(host) }, health: health, writes: writes)
        await store.load()

        await store.saveWeight(tenths: 770, at: at, alsoHealth: true)
        #expect(store.waitingToSync)
        #expect(store.weight != nil)
        #expect(health.saved.count == 1)

        await store.undoLastSave()
        #expect(writes.pending.isEmpty)
        #expect(writes.sent.map(\.method) == ["POST"])
        #expect(health.saved.isEmpty)
        #expect(store.waitingToSync == false)
        #expect(store.lastSaved == nil)
    }

    @Test func undoAfterDeliveryQueuesDeleteAndRemovesTheHealthSample() async throws {
        let host = try Self.host()
        let health = FakeHealthWriter(), writes = FakeWrites(deliver: true)
        let store = BodyStore(api: { VitalisAPI.stubbed(host) }, health: health, writes: writes)

        await store.saveWeight(tenths: 770, at: at, alsoHealth: true)
        let id = try Self.entry(try #require(writes.sent.first)).id
        await store.undoLastSave()

        #expect(writes.sent.count == 2)
        #expect(writes.sent.last?.method == "DELETE")
        #expect(writes.sent.last?.path == "v2/weight/\(id)")
        #expect(health.saved.isEmpty)
    }

    @Test func healthFailureNeverBlocksTheServerEntry() async throws {
        let host = try Self.host()
        let health = FakeHealthWriter(), writes = FakeWrites(deliver: true)
        health.failNext = true
        let store = BodyStore(api: { VitalisAPI.stubbed(host) }, health: health, writes: writes)

        await store.saveWeight(tenths: 766, at: at, alsoHealth: true)

        #expect(writes.sent.count == 1)
        #expect(try Self.entry(try #require(writes.sent.first)).hkUuid == nil)
        #expect(store.lastSaved?.healthFailed == true)
    }

    @Test func waitingClearsOnceTheOutboxDelivers() async throws {
        let host = try Self.host()
        let writes = FakeWrites(deliver: false)
        let store = BodyStore(api: { VitalisAPI.stubbed(host) }, health: FakeHealthWriter(), writes: writes)
        await store.saveWeight(tenths: 766, at: at, alsoHealth: false)
        #expect(store.waitingToSync)

        let id = try #require(store.lastSaved?.outboxID)
        _ = await writes.drop(id)
        await store.recheckWaiting()
        #expect(store.waitingToSync == false)
    }

    @Test func prefillAndTimestampFormatting() throws {
        let store = BodyStore(api: { nil }, health: FakeHealthWriter(), writes: FakeWrites(deliver: true))
        store.preload(try Fixture.decode(BodyResponse.self, "body"))
        #expect(store.prefillTenths == 762)
        let ist = try #require(TimeZone(secondsFromGMT: 19800))
        #expect(BodyStore.timestamp(Date(timeIntervalSince1970: 1_792_800_000), timeZone: ist) == "2026-10-24T05:30:00+05:30")
    }
}
