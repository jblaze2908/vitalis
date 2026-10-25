import Foundation
import Testing
import VitalisKit
@testable import Vitalis

struct SpokenSummaryTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoding.decoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func durationWords() {
        #expect(SpokenSummary.duration(hours: 6 + 28.0 / 60) == "6 hours 28")
        #expect(SpokenSummary.duration(hours: 8) == "8 hours")
        #expect(SpokenSummary.duration(hours: 1.0 + 1.0 / 60) == "1 hour 1")
        #expect(SpokenSummary.duration(hours: 0.5) == "30 minutes")
    }

    @Test func sleepWithScore() throws {
        let r = try decode(SleepResponse.self, """
        {"day":"2026-10-24","has_night":true,"score":64,"band":"low",
         "night":{"sleep_start":"2026-10-23T23:50:00+05:30","sleep_end":"2026-10-24T06:40:00+05:30","asleep_h":6.4667},
         "duration":{"need_h":8.5}}
        """)
        #expect(SpokenSummary.sleep(r) == "Sleep score 64, low. 6 hours 28 asleep, need 8 hours 30.")
    }

    @Test func sleepFixtureAndNoNight() throws {
        #expect(SpokenSummary.sleep(try Fixture.decode(SleepResponse.self, "sleep")).hasPrefix("Sleep score "))
        let none = try decode(SleepResponse.self, #"{"day":"2026-10-24","has_night":false,"score":null}"#)
        #expect(SpokenSummary.sleep(none) == "No sleep recorded for last night.")
        #expect(SpokenSummary.sleep(nil) == "No sleep data yet. Open Vitalis to sync.")
    }

    @Test func recoveryWithAndWithoutScore() throws {
        let today = try Fixture.decode(TodayResponse.self, "today")
        let score = try #require(today.recovery.score)
        #expect(SpokenSummary.recovery(today).hasPrefix("Recovery \(score), "))

        var body = try #require(try JSONSerialization.jsonObject(with: Fixture.data("today")) as? [String: Any])
        body["recovery"] = ["score": NSNull(), "band": NSNull(), "status": "missing", "reason": "No sleep recorded for last night"]
        let r = try APICoding.decoder().decode(TodayResponse.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(SpokenSummary.recovery(r).hasPrefix("No recovery score yet: no sleep recorded for last night. "))
    }

    @Test func weightSentence() {
        #expect(SpokenSummary.weightLogged(kg: 76.4, waitingToSync: false, healthFailed: false) == "Logged 76.4 kilograms.")
        #expect(SpokenSummary.weightLogged(kg: 76.4, waitingToSync: true, healthFailed: false)
                == "Logged 76.4 kilograms. It'll sync when your server is reachable.")
    }
}
