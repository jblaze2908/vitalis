import Foundation
import VitalisKit

/// Fixture bodies for Sleep/Body previews: the bundled demo responses plus the empty states they don't cover.
enum SleepBodyPreviewData {
    static func demo<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? APICoding.decoder().decode(T.self, from: data)
    }

    static func inline<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? APICoding.decoder().decode(T.self, from: Data(json.utf8))
    }

    static var sleep: SleepResponse? { demo(SleepResponse.self, "sleep") }
    static var week: SleepWeekResponse? { demo(SleepWeekResponse.self, "sleep-week") }
    static var body: BodyResponse? { demo(BodyResponse.self, "body") }

    /// `has_night: false`: score, parts, night and stages are null; tonight is still there (10 §5).
    static var noNight: SleepResponse? {
        inline(SleepResponse.self, """
        {"day":"2026-10-24","has_night":false,"prev_day":"2026-10-23","next_day":null,"night":null,"score":null,"band":null,
         "label":null,"status":"missing","duration":null,"parts":null,"stages":null,
         "tonight":{"bed_by":"23:50","wake_time":"06:50","need_h":7,"label":"7H BEFORE YOUR 06:50 WAKE"},
         "freshness":{"last_sync":"2026-10-24T21:44:13+05:30","today":"2026-10-24"}}
        """)
    }

    /// A flagged part with a missing one, to show `watch` tints and `–`.
    static var flagged: SleepResponse? {
        inline(SleepResponse.self, """
        {"day":"2026-10-23","has_night":true,"prev_day":"2026-10-22","next_day":"2026-10-24",
         "night":{"sleep_start":"2026-10-22T23:02:00+05:30","sleep_end":"2026-10-23T06:51:00+05:30","asleep_h":7.68,"asleep_label":"7H41","source":"Apple Watch"},
         "score":85,"band":"good","label":"GOOD","status":"ok",
         "duration":{"asleep_label":"7H41","vs_usual_min":-12,"vs_usual_label":"-12M","need_h":8.0,"need_label":"8H00","need_basis":"target"},
         "parts":[{"key":"duration","label":"DURATION","detail":"OF YOUR 8H NEED","score":90,"flagged":false,"weight":0.4},
                  {"key":"consistency","label":"BEDTIME","detail":"NEEDS 14 NIGHTS","score":null,"flagged":false,"weight":0.2},
                  {"key":"efficiency","label":"EFFICIENCY","detail":"94% ASLEEP","score":94,"flagged":false,"weight":0.2},
                  {"key":"wakeups","label":"WAKE-UPS","detail":"2 · 25 MIN","score":70,"flagged":true,"weight":0.2}],
         "stages":{"core_h":4.1,"deep_h":1.2,"rem_h":1.9,"awake_h":0.42,"note":"Stages are estimates and are not part of the score."},
         "tonight":{"bed_by":"23:00","wake_time":"07:00","need_h":8.0,"label":"8H BEFORE YOUR 07:00 WAKE"},
         "freshness":{"last_sync":"2026-10-24T09:39:00+05:30","today":"2026-10-24"}}
        """)
    }

    /// Weight block with no readings ("No weight yet").
    static var noWeight: BodyResponse? {
        inline(BodyResponse.self, """
        {"day":"2026-10-24","weight":{"trend_kg":null,"month_change_kg":null,"goal_kg":74.0,"toward_goal":null,"latest":null,"series":[]},
         "activity":{"steps":3206,"steps_target":9000,"active_kcal":212,"exercise_min":12,"exercise_target_min":30,
                     "week":[{"day":"2026-10-18","steps":8210},{"day":"2026-10-19","steps":null},{"day":"2026-10-24","steps":3206}]},
         "vitals":[{"key":"hrv","label":"HRV","value":62,"unit":"ms","usual":55,"usual_range":[48,61],"flag":"high","reading":"better"},
                   {"key":"resting_hr","label":"RESTING HR","value":57,"unit":"bpm","usual":55,"usual_range":[54,56],"flag":"high","reading":"worse"},
                   {"key":"spo2","label":"SPO2","value":97,"unit":"%","usual":97,"usual_range":[95,98],"flag":null,"reading":null},
                   {"key":"respiratory_rate","label":"BREATHING","value":14.8,"unit":"/min","usual":15.0,"usual_range":[14.2,15.8],"flag":null,"reading":null}],
         "freshness":{"last_sync":"2026-10-24T09:39:00+05:30","today":"2026-10-24"}}
        """)
    }

}
