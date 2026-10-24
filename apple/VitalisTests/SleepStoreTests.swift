import Foundation
import Testing
import VitalisKit
@testable import Vitalis

/// Records reminders instead of touching UNUserNotificationCenter.
private final class FakeReminders: BedReminding, @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduled: [Date] = []
    let allow: Bool
    init(allow: Bool = true) { self.allow = allow }
    var scheduled: [Date] { lock.withLock { _scheduled } }
    func schedule(at date: Date, title: String, body: String) async -> Bool {
        lock.withLock { if allow { _scheduled.append(date) } }
        return allow
    }
}

@MainActor
struct SleepStoreTests {
    /// Answers `/v2/sleep?date=` with the fixture moved to that day (prev/next shifted), and the week fixture.
    private static func host() throws -> StubURLProtocol.Host {
        let night = try Fixture.data("sleep"), week = try Fixture.data("sleep-week")
        return StubURLProtocol.register { req in
            switch req.url.path {
            case "/v2/sleep/week": return .http(200, body: week)
            case "/v2/sleep":
                let day = URLComponents(url: req.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "date" }?.value
                return .http(200, body: day.map { shifted(night, to: $0) } ?? night)
            default: return .http(404)
            }
        }
    }

    nonisolated private static func shifted(_ data: Data, to day: String) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        let days = ["2026-10-22", "2026-10-23", "2026-10-24"]
        guard let i = days.firstIndex(of: day) else { return data }
        json["day"] = day
        json["prev_day"] = i > 0 ? days[i - 1] : NSNull()
        json["next_day"] = i < days.count - 1 ? days[i + 1] : NSNull()
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }

    private static func count(_ host: StubURLProtocol.Host, _ path: String) -> Int {
        host.requests.filter { $0.url.path == path }.count
    }

    @Test func forwardIsDisabledAndInertOnTheLatestNight() async throws {
        let host = try Self.host()
        let store = SleepStore(api: { VitalisAPI.stubbed(host) }, reminders: FakeReminders())
        await store.load()
        #expect(store.value?.nextDay == nil)
        #expect(store.canGoForward == false)
        #expect(store.canGoBack)

        await store.forward()
        #expect(Self.count(host, "/v2/sleep") == 1)
        #expect(store.value?.day == "2026-10-24")
    }

    @Test func backUsesPrevDayAndEachWeekIsFetchedOncePerEndDate() async throws {
        let host = try Self.host()
        let store = SleepStore(api: { VitalisAPI.stubbed(host) }, reminders: FakeReminders())
        await store.load()
        #expect(store.week != nil)

        await store.back()
        #expect(store.value?.day == "2026-10-23")
        #expect(store.canGoForward)
        let dates = host.requests.filter { $0.url.path == "/v2/sleep" }.map { $0.url.query ?? "" }
        #expect(dates == ["", "date=2026-10-23"])

        await store.forward()
        #expect(store.value?.day == "2026-10-24")
        let weekEnds = host.requests.filter { $0.url.path == "/v2/sleep/week" }.map { $0.url.query ?? "" }
        #expect(weekEnds == ["end=2026-10-24", "end=2026-10-23"])

        await store.load(force: true)
        #expect(Self.count(host, "/v2/sleep/week") == 3)
    }

    @Test func reminderIsThirtyMinutesBeforeBedByTonightOrTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 19800))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 21)))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 20)))
        #expect(SleepStore.reminderDate(bedBy: "23:50", now: evening, calendar: calendar) == expected)

        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 30)))
        #expect(SleepStore.reminderDate(bedBy: "23:50", now: late, calendar: calendar) == expected.addingTimeInterval(86_400))
        #expect(SleepStore.reminderDate(bedBy: "late", now: evening, calendar: calendar) == nil)
    }

    @Test func remindMeSchedulesOnceAllowedAndReportsDenial() async throws {
        let host = try Self.host()
        let reminders = FakeReminders()
        let store = SleepStore(api: { VitalisAPI.stubbed(host) }, reminders: reminders)
        await store.load()
        await store.remindMe()
        #expect(reminders.scheduled.count == 1)
        #expect(store.reminder == .set)

        let denied = SleepStore(api: { VitalisAPI.stubbed(host) }, reminders: FakeReminders(allow: false))
        await denied.load()
        await denied.remindMe()
        #expect(denied.reminder == .denied)
    }

    @Test func noNightKeepsTonight() throws {
        let json = """
        {"day":"2026-10-24","has_night":false,"prev_day":"2026-10-23","next_day":null,"night":null,"score":null,
         "parts":null,"stages":null,"tonight":{"bed_by":"23:50","label":"7H BEFORE YOUR 06:50 WAKE"}}
        """
        let value = try APICoding.decoder().decode(SleepResponse.self, from: Data(json.utf8))
        let store = SleepStore(api: { nil }, reminders: FakeReminders())
        store.preload(value)
        #expect(store.value?.hasNight == false)
        #expect(store.value?.tonight?.bedBy == "23:50")
        #expect(store.canGoForward == false)
    }
}
