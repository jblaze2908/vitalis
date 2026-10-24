import Foundation
import Testing
@testable import Vitalis

@Suite struct StaleStateTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    // Saturday 24 Oct 2026 09:41 +05:30.
    let now = ISO8601DateFormatter().date(from: "2026-10-24T04:11:00Z")!
    func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

    func make(lastSync: Date?, lastSuccess: Date? = nil, failure: SyncFailure? = nil, cachedAt: Date? = nil, refreshFailed: Bool = false) -> StaleState {
        StaleState(lastSync: lastSync, lastSuccess: lastSuccess, failure: failure, cachedAt: cachedAt, refreshFailed: refreshFailed, now: now, calendar: cal)
    }

    @Test func freshSyncShowsTheTime() {
        #expect(make(lastSync: hoursAgo(0.05)).status == .synced(label: "SYNCED 09:38"))
    }

    @Test func serverLastSyncOlderThan12HoursIsStaleWithNoFailureCopy() {
        let s = make(lastSync: hoursAgo(60), lastSuccess: hoursAgo(60))
        #expect(s.status == .stale(statusLabel: "LAST SYNC WED", sectionLabel: "NOT SYNCED SINCE WED", cause: "Your phone hasn't synced since Wed."))
    }

    @Test(arguments: [
        (SyncFailure.unauthorized, "Your server stopped accepting uploads."),
        (.unreachable, "Your phone can't reach your server."),
        (.server(503), "Your server is having trouble."),
        (.protectedDataUnavailable, "Unlock your phone to sync."),
    ])
    func eachFailureHasItsCopy(_ failure: SyncFailure, _ copy: String) {
        // Server saw a sync 2 h ago, but this phone's last successful upload is 13 h old and its latest attempt failed.
        let s = make(lastSync: hoursAgo(2), lastSuccess: hoursAgo(13), failure: failure)
        guard case .stale(_, _, let cause) = s.status else { Issue.record("not stale"); return }
        #expect(cause == copy)
        #expect(StaleState.body == "Everything is safe on this phone until it's fixed.")
    }

    @Test func aRecentFailureIsNotStaleYet() {
        #expect(!make(lastSync: hoursAgo(2), lastSuccess: hoursAgo(3), failure: .unreachable).isStale)
    }

    @Test func offlineCachedBodyOlderThan15Minutes() {
        #expect(make(lastSync: hoursAgo(1), cachedAt: hoursAgo(0.5), refreshFailed: true).status == .offline(label: "OFFLINE · UPDATED 09:11"))
        #expect(make(lastSync: hoursAgo(1), cachedAt: hoursAgo(0.1), refreshFailed: true).status == .synced(label: "SYNCED 08:41"))
    }

    @Test func dayLabels() {
        #expect(StaleState.dayLabel(hoursAgo(1), now: now, calendar: cal) == "TODAY")
        #expect(StaleState.dayLabel(hoursAgo(24), now: now, calendar: cal) == "YESTERDAY")
        #expect(StaleState.dayLabel(hoursAgo(24 * 12), now: now, calendar: cal) == "12 OCT")
        #expect(make(lastSync: nil).status == .synced(label: "NOT SYNCED YET"))
    }
}
