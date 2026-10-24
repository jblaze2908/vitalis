#if DEBUG
import Foundation
import VitalisKit

/// Preview stores built from the bundled DemoData responses (no network, no HealthKit).
@MainActor
enum TrainPreviewData {
    enum Week { case fixture, due, empty }

    /// The demo responses carry `due: null`; previews patch in an example plan to show the due block and sheet.
    static let dueJSON: [String: Any] = [
        "template": "legs", "name": "Legs", "days_since": 6, "exercise_count": 3,
        "exercises": [
            ["id": "barbell-squat", "name": "Barbell Squat", "last": ["weight_kg": 97.5, "reps": 6, "day": "2026-10-18"]],
            ["id": "romanian-deadlift", "name": "Romanian Deadlift", "last": ["weight_kg": 95, "reps": 8, "day": "2026-10-18"]],
            ["id": "leg-press", "name": "Leg Press", "last": ["weight_kg": 180, "reps": 10, "day": "2026-10-18"]],
        ],
    ]

    static func json(_ name: String) -> [String: Any] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? APICoding.decoder().decode(T.self, from: data)
    }

    static var due: DueWorkout? { decode(DueWorkout.self, dueJSON) }

    static func training(_ week: Week) -> TrainingResponse? {
        var t = json("training")
        switch week {
        case .fixture: break
        case .due: t["due"] = dueJSON
        case .empty:
            t["empty"] = true; t["sessions"] = [Any](); t["heat"] = [String: Int]()
            t["stats"] = ["sessions": 0, "working_sets": 0, "muscles_hit": 0, "muscles_total": 17]
        }
        return decode(TrainingResponse.self, t)
    }

    static func trainStore(_ week: Week) -> TrainStore {
        let store = TrainStore(api: { nil })
        if let t = training(week) { store.week.set(t) }
        if let s = decode(SessionDetail.self, json("training-session")) { store.session(s.id).set(s) }
        if let e = decode(ExerciseDetail.self, json("exercise")) { store.exercise(e.exercise.id).set(e) }
        return store
    }

    static var exercise: ExerciseDetail? { decode(ExerciseDetail.self, json("exercise")) }

    static var idleLive: LiveSessionStore { LiveSessionStore(fileURL: nil, api: { nil }, send: { _ in }, health: FakeHealthWriter()) }

    /// Mid-session logger: squat prefilled from the demo exercise detail, warm-up and one set done, rest running.
    static func liveStore(watchLive: Bool = false) -> LiveSessionStore {
        let store = LiveSessionStore(fileURL: nil, api: { nil }, send: { _ in }, health: FakeHealthWriter())
        store.begin(due: due)
        if let e = exercise { store.apply(e, to: "barbell-squat") }
        Task { await store.check(); await store.check(); store.watchSessionLive = watchLive }
        return store
    }
}
#endif
