import Foundation
import Testing
import VitalisKit
@testable import Vitalis

@MainActor @Suite struct TrainStoreTests {
    static let olderPage = #"""
    { "sessions": [
        { "id": "ef7647ca-7072-4dfa-bdd5-48bd91c05e24", "kind": "strength", "title": "push", "day": "2026-10-22", "start": "2026-10-22T18:00:00+05:30",
          "duration_min": 30, "working_sets": 12, "tag": null },
        { "id": "old-1", "kind": "strength", "title": "legs", "day": "2026-10-15", "start": "2026-10-15T18:00:00+05:30",
          "duration_min": 41, "working_sets": 14, "tag": { "kind": "pr", "label": "PR · SQUAT" } } ],
      "next": null }
    """#

    func stubbedStore() throws -> (TrainStore, StubURLProtocol.Host) {
        let training = try Fixture.data("training"), firstPage = try Fixture.data("training-sessions"), older = Data(Self.olderPage.utf8)
        let host = StubURLProtocol.register { r in
            let before = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
            switch r.url.path {
            case "/v2/training": return .http(200, body: training)
            case "/v2/training/sessions": return .http(200, body: before == nil ? firstPage : older)
            default: return .http(404)
            }
        }
        let api = VitalisAPI.stubbed(host)
        return (TrainStore(api: { api }), host)
    }

    @Test func pagingAppendsEachSessionOnce() async throws {
        let (store, host) = try stubbedStore()
        await store.load()
        let week = ["7ad4a98b-290a-4d12-b99a-c3ab21b20d1d", "ef7647ca-7072-4dfa-bdd5-48bd91c05e24", "5b995e50-20bc-4aa2-9145-b9b49fb7f76f"]
        // Load also fetches the first history page, which repeats this week's three sessions.
        #expect(store.sessions.map(\.id) == week)
        #expect(store.hasMore)
        #expect(store.nextCursor == "MTc5MjQ5OTQwMDAwMDo1Yjk5NWU1MC0yMGJjLTRhYTItOTE0NS1iOWI0OWZiN2Y3NmY")

        await store.loadMore()
        #expect(store.sessions.map(\.id) == week + ["old-1"])
        #expect(!store.hasMore)
        let cursors = host.requests.filter { $0.url.path == "/v2/training/sessions" }.map { $0.url.query ?? "" }
        #expect(cursors == ["", "before=MTc5MjQ5OTQwMDAwMDo1Yjk5NWU1MC0yMGJjLTRhYTItOTE0NS1iOWI0OWZiN2Y3NmY"])

        await store.loadMore()
        #expect(host.requests.filter { $0.url.path == "/v2/training/sessions" }.count == 2)
        #expect(Set(store.sessions.map(\.id)).count == store.sessions.count)
    }

    @Test func finishPushesTheSessionDetail() {
        let store = TrainStore(api: { nil })
        store.path = [.exercise(id: "x")]
        store.showFinished("ABC")
        #expect(store.path == [.session(id: "ABC")])
        #expect(store.isPending("ABC"))
    }

    @Test func pulseUsesTodaysWindowAndDropsFutureEvents() throws {
        let today = try Fixture.decode(TodayResponse.self, "today")
        let pulse = try #require(today.pulse)
        let now = try #require(APIDate.parse(pulse.now))
        let p = try #require(TrainStore.positions(pulse, now: now))
        #expect(p.events.count == pulse.events.filter { APIDate.parse($0.at)! <= now }.count)
        #expect(p.now > 0 && p.now <= 1)
    }
}
