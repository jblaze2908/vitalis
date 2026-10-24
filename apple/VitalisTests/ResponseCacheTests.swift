import Foundation
import Testing
import VitalisKit

@Suite struct ResponseCacheTests {
    private let etag = #"W/"12.3.v2/today@2026-10-24T22:00""#

    @Test func etagIsSentAnd304ReturnsCachedBody() async throws {
        let body = try Fixture.data("today")
        let tag = etag
        let host = StubURLProtocol.register { request in
            request.headers["If-None-Match"] == tag ? .http(304) : .http(200, headers: ["ETag": tag], body: body)
        }
        let clock = TestClock()
        let cache = try ResponseCache(directory: temporaryDirectory())
        let api = VitalisAPI.stubbed(host, cache: cache, clock: clock)

        let first = try await api.today()
        #expect(first.source == .network && first.etag == tag && first.fetchedAt == clock.now)
        clock.advance(600)
        let second = try await api.today()
        #expect(second.source == .notModified && second.fromCache)
        #expect(second.value == first.value)
        #expect(second.fetchedAt == clock.now, "a 304 confirms the body is current")

        let requests = host.requests
        #expect(requests.count == 2)
        #expect(requests[0].headers["If-None-Match"] == nil)
        #expect(requests[1].headers["If-None-Match"] == tag)
        #expect(requests[0].headers["Authorization"] == "Bearer test-token")
        #expect(requests[0].url.path == "/v2/today")
    }

    @Test func queryIsPartOfTheKey() async throws {
        let body = try Fixture.data("sleep")
        let host = StubURLProtocol.register { _ in .http(200, headers: ["ETag": "W/\"1\""], body: body) }
        let cache = try ResponseCache(directory: temporaryDirectory())
        let api = VitalisAPI.stubbed(host, cache: cache)
        _ = try await api.sleep(date: "2026-10-23")
        _ = try await api.sleep(date: "2026-10-24")
        #expect(await cache.count == 2)
        #expect(host.requests.map { $0.url.query } == ["date=2026-10-23", "date=2026-10-24"])
        #expect(ResponseCache.key(path: "/v2/exercises", query: [.init(name: "q", value: "row"), .init(name: "since", value: "x")])
                == ResponseCache.key(path: "v2/exercises", query: [.init(name: "since", value: "x"), .init(name: "q", value: "row")]))
        #expect(await cache.entry(path: "v2/sleep", query: [.init(name: "date", value: "2026-10-24")])?.day == "2026-10-24")
    }

    @Test func failedRefreshLeavesCacheForOfflineRendering() async throws {
        let body = try Fixture.data("food-day")
        let host = StubURLProtocol.register { _ in .http(200, headers: ["ETag": "W/\"7\""], body: body) }
        let cache = try ResponseCache(directory: temporaryDirectory())
        let clock = TestClock()
        let api = VitalisAPI.stubbed(host, cache: cache, clock: clock)
        let fresh = try await api.foodDay()

        host.setHandler { _ in .failure(URLError(.notConnectedToInternet)) }
        do { _ = try await api.foodDay(); Issue.record("expected a transport error") }
        catch let APIError.transport(error) { #expect(error.code == .notConnectedToInternet) }
        let offline = try #require(await api.cached(FoodDay.self, path: "v2/food/day"))
        #expect(offline.source == .cache && offline.value == fresh.value && offline.fetchedAt == fresh.fetchedAt)

        host.setHandler { _ in .http(401, body: Data(#"{"error":"Missing or invalid token","code":"unauthorized"}"#.utf8)) }
        await #expect(throws: APIError.unauthorized) { _ = try await api.foodDay() }
    }

    @Test func undecodableBodyIsADecodingError() async throws {
        let host = StubURLProtocol.register { _ in .http(200, body: Data(#"{"day":"2026-10-24"}"#.utf8)) }
        let api = VitalisAPI.stubbed(host)
        do {
            _ = try await api.today()
            Issue.record("expected a decoding error")
        } catch let APIError.decoding(message) {
            #expect(message.contains("TodayResponse"))
        }
    }

    @Test func pruneDropsOnlyOldDayKeyedEntries() async throws {
        let clock = TestClock(try #require(APIDate.parse("2026-10-24T12:00:00Z")))
        let cache = try ResponseCache(directory: temporaryDirectory())
        let body = Data("{}".utf8)
        try await cache.store(path: "v2/sleep", query: [.init(name: "date", value: "2026-09-01")], etag: nil, body: body, fetchedAt: clock.now)
        try await cache.store(path: "v2/sleep", query: [.init(name: "date", value: "2026-10-20")], etag: nil, body: body, fetchedAt: clock.now)
        try await cache.store(path: "v2/body", query: [.init(name: "date", value: "2026-10-20")], etag: nil, body: body,
                              fetchedAt: clock.now.addingTimeInterval(-40 * 86_400))
        try await cache.store(path: "v2/today", query: [], etag: nil, body: body, fetchedAt: clock.now.addingTimeInterval(-90 * 86_400))
        #expect(await cache.prune(olderThan: 30 * 86_400, now: clock.now) == 2)
        #expect(await cache.entry(path: "v2/sleep", query: [.init(name: "date", value: "2026-10-20")]) != nil)
        #expect(await cache.entry(path: "v2/sleep", query: [.init(name: "date", value: "2026-09-01")]) == nil)
        #expect(await cache.entry(path: "v2/today") != nil, "undated keys are not pruned")
    }

    @Test func removeAllEmptiesAndFilesAreProtected() async throws {
        let directory = temporaryDirectory()
        let cache = try ResponseCache(directory: directory)
        try await cache.store(path: "v2/targets", query: [], etag: "W/\"1\"", body: Data("{}".utf8), fetchedAt: Date())
        #expect(await cache.count == 1)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        try await cache.removeAll()
        #expect(await cache.count == 0)
        #expect(await cache.entry(path: "v2/targets") == nil)
    }

    @Test func syncStatusBypassesTheCache() async throws {
        let body = try Fixture.data("sync-status")
        let host = StubURLProtocol.register { _ in .http(200, headers: ["ETag": "W/\"1\""], body: body) }
        let cache = try ResponseCache(directory: temporaryDirectory())
        let status = try await VitalisAPI.stubbed(host, cache: cache).syncStatus()
        #expect(status.token?.canWrite == true)
        #expect(await cache.count == 0)
    }

    @Test func exporterStillUsesTheSharedRequestPath() async throws {
        let host = StubURLProtocol.register { _ in .http(200, body: Data(#"{"types":[]}"#.utf8)) }
        let client = HTTPAPIClient(settings: try ServerSettings(host.baseURL.absoluteString), token: { "test-token" },
                                   protocolClasses: [StubURLProtocol.self])
        #expect(try await client.status() == .object(["types": .array([])]))
        #expect(host.requests.first?.url.path == "/v2/sync/status")
        #expect(host.requests.first?.headers["Authorization"] == "Bearer test-token")
    }
}
