import Foundation
import Testing
import VitalisKit

@Suite struct OutboxTests {
    private func post(_ n: Int) -> APIRequest {
        APIRequest(method: "POST", path: "v2/test/\(n)", body: Data(#"{"id":"\#(n)","kg":76.6}"#.utf8))
    }

    @Test func flushSendsInOrderAndRemoves() async throws {
        let outbox = try Outbox(directory: temporaryDirectory())
        for n in 1...3 { try await outbox.enqueue(post(n)) }
        let transport = FakeTransport()
        let result = await outbox.flush(using: transport)
        #expect(await transport.paths == ["v2/test/1", "v2/test/2", "v2/test/3"])
        #expect(result.delivered.count == 3 && result.stop == .empty)
        #expect(await outbox.pendingCount == 0)
        #expect(await transport.sent.first?.body == post(1).body, "body bytes are replayed exactly")
    }

    @Test func reopenAfterCrashKeepsOrderAndDropsNothing() async throws {
        let directory = temporaryDirectory()
        let clock = TestClock()
        var ids: [UUID] = []
        do {
            let outbox = try Outbox(directory: directory, now: clock.closure)
            for n in 1...4 { ids.append(try await outbox.enqueue(post(n))) }
            // First goes through, then the connection drops mid-queue.
            _ = await outbox.flush(using: FakeTransport([.status(200), .failure(URLError(.networkConnectionLost))]))
        }
        let reopened = try Outbox(directory: directory, now: clock.closure)
        let pending = await reopened.pendingItems
        #expect(pending.map(\.id) == Array(ids.dropFirst()))
        #expect(pending.first?.attempts == 1 && pending.first?.lastError != nil)
        #expect(pending.map(\.path) == ["v2/test/2", "v2/test/3", "v2/test/4"])

        let transport = FakeTransport()
        _ = await reopened.flush(using: transport, ignoringBackoff: true)
        #expect(await transport.paths == ["v2/test/2", "v2/test/3", "v2/test/4"])
        #expect(await reopened.pendingCount == 0)
    }

    @Test func unauthorizedHaltsTheQueueAndKeepsItems() async throws {
        let outbox = try Outbox(directory: temporaryDirectory())
        let calls = Counter()
        await outbox.setOnAuthFailure { status in calls.add(status) }
        for n in 1...3 { try await outbox.enqueue(post(n)) }
        let transport = FakeTransport([.status(401, #"{"error":"Missing or invalid token","code":"unauthorized"}"#)])

        let result = await outbox.flush(using: transport)
        #expect(result.stop == .unauthorized(401))
        #expect(await transport.sent.count == 1)
        #expect(await outbox.pendingCount == 3)
        #expect(await outbox.authHalted)
        #expect(calls.values == [401])
        #expect(await outbox.pendingItems.first?.lastError == "Missing or invalid token")

        // Halted: nothing goes out until the token is replaced.
        _ = await outbox.flush(using: transport, ignoringBackoff: true)
        #expect(await transport.sent.count == 1)
        await outbox.resumeAfterAuth()
        let resumed = await outbox.flush(using: transport)
        #expect(resumed.stop == .empty && resumed.delivered.count == 3)
        #expect(await transport.paths == ["v2/test/1", "v2/test/1", "v2/test/2", "v2/test/3"])
    }

    @Test func forbiddenAlsoHalts() async throws {
        let outbox = try Outbox(directory: temporaryDirectory())
        try await outbox.enqueue(post(1))
        let result = await outbox.flush(using: FakeTransport([.status(403, #"{"error":"This token can't change data","code":"scope"}"#)]))
        #expect(result.stop == .unauthorized(403))
        #expect(await outbox.pendingCount == 1)
    }

    @Test func conflictAndInvalidMoveToFailedAndQueueContinues() async throws {
        let directory = temporaryDirectory()
        let outbox = try Outbox(directory: directory)
        for n in 1...3 { try await outbox.enqueue(post(n)) }
        let transport = FakeTransport([
            .status(409, #"{"error":"set s1 belongs to another session","code":"conflict"}"#),
            .status(422, #"{"error":"steps: Too small","code":"invalid"}"#),
            .status(200),
        ])
        let result = await outbox.flush(using: transport)
        #expect(result.stop == .empty)
        #expect(result.failed.map(\.path) == ["v2/test/1", "v2/test/2"])
        #expect(result.delivered.map(\.item.path) == ["v2/test/3"])
        #expect(await outbox.pendingCount == 0)
        #expect(await outbox.failedItems.map(\.lastError) == ["set s1 belongs to another session", "steps: Too small"])

        let reopened = try Outbox(directory: directory)
        #expect(await reopened.failedItems.count == 2, "failed.jsonl survives a relaunch")
        let first = try #require(await reopened.failedItems.first)
        try await reopened.dismissFailed(id: first.id)
        #expect(await reopened.failedItems.count == 1)
    }

    @Test func serverErrorsKeepTheHeadWithBackoff() async throws {
        let clock = TestClock()
        let start = clock.now
        let outbox = try Outbox(directory: temporaryDirectory(), now: clock.closure)
        for n in 1...2 { try await outbox.enqueue(post(n)) }
        let transport = FakeTransport(Array(repeating: .status(503), count: 5))

        var expectedDelay: TimeInterval = 0
        for delay in [5.0, 30, 120, 600, 600] {
            let result = await outbox.flush(using: transport)
            #expect(result.stop == .retryAt(clock.now.addingTimeInterval(delay)))
            // Not due yet: nothing is sent and order is untouched.
            let early = await outbox.flush(using: transport)
            #expect(early.stop == .retryAt(clock.now.addingTimeInterval(delay)))
            clock.advance(delay)
            expectedDelay += delay
        }
        #expect(clock.now == start.addingTimeInterval(expectedDelay))
        #expect(await transport.paths == Array(repeating: "v2/test/1", count: 5), "later items never overtake the head")
        #expect(await outbox.pendingItems.first?.attempts == 5)

        let drained = await outbox.flush(using: transport)
        #expect(drained.stop == .empty)
        #expect(await transport.paths.suffix(2) == ["v2/test/1", "v2/test/2"])
    }

    @Test func rateLimitAndTransportErrorsAreKept() async throws {
        let outbox = try Outbox(directory: temporaryDirectory())
        try await outbox.enqueue(post(1))
        let r1 = await outbox.flush(using: FakeTransport([.status(429)]))
        guard case .retryAt = r1.stop else { Issue.record("429 should retry"); return }
        let r2 = await outbox.flush(using: FakeTransport([.failure(URLError(.notConnectedToInternet))]), ignoringBackoff: true)
        guard case .retryAt = r2.stop else { Issue.record("offline should retry"); return }
        #expect(await outbox.pendingCount == 1)
        #expect(await outbox.failedItems.isEmpty)
    }

    @Test func dropBeforeSendRemovesOnlyThatItem() async throws {
        let outbox = try Outbox(directory: temporaryDirectory())
        let a = try await outbox.enqueue(post(1))
        let b = try await outbox.enqueue(post(2))
        let c = try await outbox.enqueue(post(3))
        #expect(try await outbox.drop(id: b))
        #expect(try await outbox.drop(id: b) == false)
        #expect(await outbox.pendingItems.map(\.id) == [a, c])
        let transport = FakeTransport()
        _ = await outbox.flush(using: transport)
        #expect(await transport.paths == ["v2/test/1", "v2/test/3"])
        #expect(try await outbox.drop(id: a) == false, "already delivered: Undo must enqueue the DELETE")
    }

    @Test func dropWhileInFlightIsRefused() async throws {
        let outbox = try Outbox(directory: temporaryDirectory())
        let a = try await outbox.enqueue(post(1))
        let transport = FakeTransport()
        let refused = Counter()
        await transport.setOnSend { _ in
            if (try? await outbox.drop(id: a)) == false { refused.add(1) }
        }
        _ = await outbox.flush(using: transport)
        #expect(refused.values == [1])
        #expect(await outbox.pendingCount == 0)
    }

    @Test func flushThroughVitalisAPIDeliversTheServerBody() async throws {
        let response = try Fixture.data("food-entries-post")
        let host = StubURLProtocol.register { request in
            request.method == "POST" && request.url.path == "/v2/food/entries" ? .http(200, body: response) : .http(404)
        }
        let api = VitalisAPI.stubbed(host)
        let outbox = try Outbox(directory: temporaryDirectory())
        let entry = FoodEntry(id: "E1", mealId: "M1", slot: "lunch", eatenAt: "2026-10-24T13:05:00+05:30",
                              name: "Paneer tikka", kcal: 420, source: "describe", estimate: true)
        let request = try APIRequest.postFoodEntries([entry])
        try await outbox.enqueue(request)

        let result = await outbox.flush(using: api)
        let delivery = try #require(result.delivered.first)
        let day = try APICoding.decoder().decode(FoodEntriesResponse.self, from: delivery.body)
        #expect(day.accepted.inserted == 1)
        #expect(host.requests.first?.body == request.body)
        #expect(host.requests.first?.headers["Content-Type"] == "application/json")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Int] = []
    func add(_ value: Int) { lock.withLock { log.append(value) } }
    var values: [Int] { lock.withLock { log } }
}
