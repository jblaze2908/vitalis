import Foundation
import Testing
import VitalisKit
@testable import Vitalis

/// Records every search call; optionally holds each one until released.
@MainActor
final class SearchRecorder {
    private(set) var calls: [String] = []
    private(set) var active = 0
    private(set) var maxActive = 0
    var holds = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    let reply: FoodSearchResponse

    init(_ fixture: String = "food-search") throws { reply = try Fixture.decode(FoodSearchResponse.self, fixture) }

    func search(_ q: String) async throws -> FoodSearchResponse {
        calls.append(q)
        active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        if holds { await withCheckedContinuation { waiters.append($0) } }
        return reply
    }

    func release() { holds = false; waiters.forEach { $0.resume() }; waiters = [] }
}

@MainActor @Suite struct FoodSearchTests {
    private func type(_ text: String, into store: FoodSearchStore) {
        for i in 1...text.count { store.update(query: String(text.prefix(i))) }
    }

    @Test func typingSendsOneRequestOnlyAfter500ms() async throws {
        let recorder = try SearchRecorder()
        let store = FoodSearchStore { try await recorder.search($0) }
        type("Paneer", into: store)
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.calls.isEmpty, "no request inside the 500 ms debounce")
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.calls == ["paneer"], "one request for six keystrokes")
        #expect(store.results.count == recorder.reply.results.count)
    }

    @Test func fewerThanThreeCharactersNeverSearch() async throws {
        let recorder = try SearchRecorder()
        let store = FoodSearchStore(debounce: .milliseconds(10)) { try await recorder.search($0) }
        type("pa", into: store)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.calls.isEmpty)
    }

    @Test func atMostOneRequestInFlight() async throws {
        let recorder = try SearchRecorder()
        recorder.holds = true
        let store = FoodSearchStore(debounce: .milliseconds(20)) { try await recorder.search($0) }
        type("paneer", into: store)
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.calls == ["paneer"])

        type("paneer tikka", into: store)
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.calls == ["paneer"], "the newer query waits for the one in flight")

        recorder.release()
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.calls == ["paneer", "paneer tikka"], "then only the latest query goes")
        #expect(recorder.maxActive == 1)
    }

    @Test func busyRemoteShowsTheMonoLine() async throws {
        let recorder = try SearchRecorder("food-search-busy")
        let store = FoodSearchStore(debounce: .milliseconds(10)) { try await recorder.search($0) }
        store.update(query: "paneer")
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.remoteLine == "ONLINE SEARCH BUSY · SHOWING YOURS")
        #expect(store.results.first?.name == "Paneer wrap")
    }
}
