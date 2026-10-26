import Foundation
import Testing
import VitalisKit
@testable import Vitalis

/// A real Outbox in a temp directory, flushed through the stubbed API; no auto-flush, so tests decide when it sends.
@MainActor
final class TestFoodQueue: FoodWriteQueue {
    let outbox: Outbox
    let transport: any OutboxTransport
    init(outbox: Outbox, transport: any OutboxTransport) { self.outbox = outbox; self.transport = transport }
    func send(_ request: APIRequest) async -> UUID? {
        let id = try? await outbox.enqueue(request)
        await outbox.flush(using: transport)
        return id
    }
    func drop(_ id: UUID) async -> Bool { (try? await outbox.drop(id: id)) ?? false }
    func pendingItems() async -> [Outbox.Item] { await outbox.pendingItems }
    func flushNow() async { await outbox.flush(using: transport, ignoringBackoff: true) }
}

/// Fake server for Eat: food day from the fixture, POST/DELETE succeed only while `online`.
final class FoodServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _online = true
    private var _deliveredPosts = 0
    var online: Bool { get { lock.withLock { _online } } set { lock.withLock { _online = newValue } } }
    var deliveredPosts: Int { lock.withLock { _deliveredPosts } }
    let host: StubURLProtocol.Host

    init() throws {
        let day = try Fixture.data("food-day"), posted = try Fixture.data("food-entries-post"), deleted = try Fixture.data("food-meal-delete")
        host = StubURLProtocol.register()
        host.setHandler { [unowned self] r in
            switch (r.method, r.url.path) {
            case ("GET", "/v2/food/day"): return .http(200, body: day)
            case ("POST", "/v2/food/entries"):
                guard self.online else { return .failure(URLError(.notConnectedToInternet)) }
                self.lock.withLock { self._deliveredPosts += 1 }
                return .http(200, body: posted)
            case ("DELETE", let p) where p.hasPrefix("/v2/food/meals/"):
                return self.online ? .http(200, body: deleted) : .failure(URLError(.notConnectedToInternet))
            default: return .http(404)
            }
        }
    }
    func requests(_ method: String) -> [StubURLProtocol.Recorded] { host.requests.filter { $0.method == method } }
}

@MainActor @Suite struct EatStoreTests {
    let server: FoodServer
    let queue: TestFoodQueue
    let health = FakeHealthWriter()
    let store: EatStore
    let calendar: Calendar

    init() throws {
        server = try FoodServer()
        let api = VitalisAPI.stubbed(server.host)
        queue = TestFoodQueue(outbox: try Outbox(directory: temporaryDirectory()), transport: api)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        calendar = cal
        // 12:30 IST on the fixture's day, so adds land on the day on screen.
        let now = try Date("2026-10-24T12:30:00+05:30", strategy: .iso8601)
        store = EatStore(api: { api }, queue: queue, health: health, now: { now }, calendar: cal, recheckAfter: nil)
    }

    private func postedEntries(_ index: Int = 0) throws -> [FoodEntry] {
        let body = try #require(server.requests("POST")[index].body)
        return try APICoding.decoder().decode(FoodEntriesRequest.self, from: body).entries
    }

    @Test func oneTapOnUsualLogsOneMealAndWritesHealth() async throws {
        await store.load()
        let usual = try #require(store.day.value?.usualNext)
        await store.logUsual()

        #expect(server.requests("POST").count == 1)
        let entries = try postedEntries()
        #expect(entries.count == usual.items.count)
        #expect(Set(entries.map(\.mealId)).count == 1)
        #expect(Set(entries.map(\.id)).count == entries.count && entries.allSatisfy { UUID(uuidString: $0.id) != nil })
        #expect(entries.allSatisfy { $0.source == "usual" && $0.slot == "breakfast" && $0.hkUuid != nil })
        #expect(entries.first?.eatenAt == "2026-10-24T12:30:00+05:30", "eaten_at keeps the local offset")
        #expect(health.saved.count == entries.count)
        #expect(Set(health.saved.keys.map(\.uuidString)) == Set(entries.compactMap(\.hkUuid)))
        #expect(store.toast?.mealID == entries.first?.mealId)
        #expect(store.toast?.text == "ADDED TO BREAKFAST · 530 KCAL")
        #expect(store.pending.isEmpty)
        #expect(server.requests("GET").count == 2, "delivered add refetches the day for JUST NOW")
    }

    @Test func savedMealIsTypedOnceThenLoggedInOneTap() async throws {
        await store.load()
        let shake = SavedMeal.Item(name: "Protein shake", portionText: "1 scoop + 300 ml milk", kcal: 310, proteinG: 40, carbsG: 18, fatG: 8)
        await store.saveMeal(id: "shake", name: "Protein shake", items: [shake])
        let sent = try #require(server.requests("POST").first { $0.url.path == "/v2/food/saved" }?.body)
        let meal = try APICoding.decoder().decode(SavedMeal.self, from: sent)
        #expect(meal.id == "shake" && meal.items == [shake])
        #expect(store.savedMeals.map(\.name) == ["Protein shake"], "shown before the server answers")

        await store.logSaved(try #require(store.savedMeals.first))
        let entries = try postedEntries(server.requests("POST").firstIndex { $0.url.path == "/v2/food/entries" }!)
        #expect(entries.count == 1 && entries[0].kcal == 310 && entries[0].proteinG == 40)
        #expect(entries[0].source == "saved" && entries[0].sourceRef == "shake" && entries[0].slot == "breakfast")

        await store.deleteSavedMeal("shake")
        #expect(store.savedMeals.isEmpty)
        #expect(server.requests("DELETE").contains { $0.url.path == "/v2/food/saved/shake" })
    }

    @Test func undoAfterDeliveryDeletesTheMealAndTheHealthSamples() async throws {
        await store.load()
        await store.logUsual()
        let mealID = try #require(store.toast?.mealID)
        #expect(!health.saved.isEmpty)

        await store.undo()
        #expect(server.requests("DELETE").map(\.url.path) == ["/v2/food/meals/\(mealID)"])
        #expect(health.saved.isEmpty)
        #expect(store.toast == nil)
        #expect(await queue.pendingItems().isEmpty)
    }

    @Test func undoBeforeSendDropsTheOutboxItem() async throws {
        await store.load()
        server.online = false
        await store.logUsual()
        #expect(!store.pending.isEmpty)

        await store.undo()
        #expect(await queue.pendingItems().isEmpty)
        #expect(store.pending.isEmpty)
        #expect(health.saved.isEmpty)
        server.online = true
        await queue.flushNow()
        #expect(server.deliveredPosts == 0)
        #expect(server.requests("DELETE").isEmpty, "nothing reached the server, so no DELETE")
    }

    @Test func offlineAddShowsWaitingAndSyncsExactlyOnce() async throws {
        await store.load()
        let before = try #require(store.day.value)
        server.online = false
        await store.logUsual()

        let waiting = store.pendingEntries(slot: "breakfast")
        #expect(waiting.count == before.usualNext?.items.count)
        #expect(store.day.value?.kcalLeft == before.kcalLeft, "top numbers stay the server's")
        #expect(store.toast != nil)

        server.online = true
        await queue.flushNow()
        await store.writesDelivered()
        #expect(store.pending.isEmpty)
        #expect(server.deliveredPosts == 1)
        await queue.flushNow()
        #expect(server.deliveredPosts == 1, "a later flush doesn't resend")
        let attempts = server.requests("POST")
        #expect(attempts.count == 2 && attempts[0].body == attempts[1].body, "the retry replays the same ids")
    }

    @Test func healthFailureNeverBlocksTheServerWrite() async throws {
        await store.load()
        health.failNext = true
        await store.logUsual()
        #expect(server.deliveredPosts == 1)
        #expect(try postedEntries().allSatisfy { $0.hkUuid == nil })
        #expect(store.healthError != nil)
    }

    @Test func pastDayAddUsesTheSlotTimeOnThatDay() async throws {
        let now = try Date("2026-10-25T09:00:00+05:30", strategy: .iso8601)
        let other = EatStore(api: { VitalisAPI.stubbed(server.host) }, queue: queue, health: health, now: { now }, calendar: calendar, recheckAfter: nil)
        await other.load()
        await other.log([FoodDraft(name: "Roti", portionText: "2 pieces", grams: 80, kcal: 240)], slot: "lunch", source: "recent")
        #expect(try postedEntries().first?.eatenAt == "2026-10-24T13:00:00+05:30")
    }
}
