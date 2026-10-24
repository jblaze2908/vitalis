#if DEBUG
import Foundation
import VitalisKit

/// Preview bodies: the bundled DemoData responses with a JSON patch deep-merged on top (models are immutable).
enum TodayPreviewData {
    /// Spec 10 §4 example values, i.e. what `spec/design/03-home-today.png` shows.
    static let frame03 = #"""
    {"generated_at": "2026-10-24T09:41:02+05:30",
     "verdict": {"band": "ready", "label": "READY", "headline": "Train legs hard today",
                 "reason": "Recovery 82: HRV above your usual, resting heart rate slightly up.",
                 "action": {"kind": "start_workout", "label": "Start legs on Watch", "template": "legs", "intensity": "normal"}},
     "recovery": {"score": 78, "band": "ready", "status": "ok",
                  "parts": {"sleep": {"score": 85, "band": "good"},
                            "hrv": {"value": 62, "arrow": "up", "tint": "good"},
                            "resting_hr": {"value": 57, "arrow": "up", "tint": "watch"}}},
     "fuel": {"kcal_target": 2300, "kcal_eaten": 520, "kcal_left": 1780, "protein_target_g": 160, "protein_g": 38,
              "next_slot": "lunch", "next_label": "LOG LUNCH"},
     "activity": {"steps": 3206, "steps_target": 9000, "steps_pace": "ahead", "active_kcal": 212, "active_kcal_pace": "on_pace"},
     "training": {"heat": {"abdominals": 1, "abductors": 0, "adductors": 1, "biceps": 2, "calves": 1, "chest": 4, "forearms": 1,
                           "glutes": 1, "hamstrings": 1, "lats": 2, "lower-back": 1, "middle-back": 2, "neck": 0, "quadriceps": 1,
                           "shoulders": 3, "traps": 1, "triceps": 3},
                  "fresh_label": "Legs fresh", "loaded_label": "Chest loaded",
                  "due": {"template": "legs", "name": "Legs", "days_since": 6, "exercises": []}, "trained_today": false},
     "pulse": {"window": {"start": "2026-10-24T06:51:00+05:30", "end": "2026-10-24T23:00:00+05:30"},
               "now": "2026-10-24T09:41:02+05:30",
               "events": [{"at": "2026-10-24T06:51:00+05:30", "kind": "wake"}, {"at": "2026-10-24T08:12:00+05:30", "kind": "meal"}]},
     "freshness": {"last_sync": "2026-10-24T09:39:00+05:30"}}
    """#

    static func today(_ patches: String...) -> TodayResponse { decode("today", patches) }
    static func digest(_ patches: String...) -> DigestResponse { decode("digest", patches) }

    /// The clock the frames were drawn at, so StaleState labels match.
    static func clock(_ iso: String = "2026-10-24T09:41:00+05:30") -> () -> Date {
        let date = APIDate.parse(iso) ?? Date()
        return { date }
    }

    private static func decode<T: Decodable>(_ name: String, _ patches: [String]) -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("DemoData/\(name).json missing from the app bundle")
        }
        for patch in patches {
            guard let p = try? JSONSerialization.jsonObject(with: Data(patch.utf8)) as? [String: Any] else { fatalError("Bad patch: \(patch)") }
            object = merge(object, p)
        }
        do {
            return try APICoding.decoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
        } catch { fatalError("\(name) patch doesn't decode: \(error)") }
    }

    /// Objects merge key by key; anything else (arrays, null, scalars) replaces.
    private static func merge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in patch {
            if let b = base[key] as? [String: Any], let p = value as? [String: Any] { out[key] = merge(b, p) } else { out[key] = value }
        }
        return out
    }
}
#endif
