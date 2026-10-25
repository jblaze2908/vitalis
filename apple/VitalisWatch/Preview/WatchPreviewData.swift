#if DEBUG
import Foundation
import VitalisKit

/// Preview fixtures in the phone's pack shape: a ready, a loaded and a never-trained split; `Push` also repeats (deduped on Start).
enum WatchPreviewData {
    static let packJSON = """
    {
      "generated_at": "2026-10-24T18:09:41+05:30",
      "settings": { "rest_s": 120, "crown_step_kg": 2.5 },
      "splits": [ { "id": "legs", "template": "legs", "name": "Legs", "ready": true, "days_since": 6,
                    "exercise_ids": ["barbell-squat", "romanian-deadlift", "leg-press", "lying-leg-curls", "standing-calf-raises"] },
                  { "id": "push", "template": null, "name": "Push", "ready": false, "days_since": 1,
                    "exercise_ids": ["barbell-bench-press-medium-grip"] },
                  { "id": "arms", "template": "arms", "name": "Arms", "ready": true, "days_since": null, "exercise_ids": [] } ],
      "recent_sessions": [ { "title": "Push", "template": null, "day": "2026-10-23", "exercise_ids": ["barbell-bench-press-medium-grip"] },
                           { "title": "Workout", "template": null, "day": "2026-10-20", "exercise_ids": ["pullups"] } ],
      "exercises": {
        "barbell-squat": { "name": "Squat", "equipment": "barbell", "primary": ["quadriceps"], "secondary": ["calves","glutes","hamstrings","lower back"],
                           "prefill": { "sets": [ { "kind": "warmup", "weight_kg": 60, "reps": 8 }, { "kind": "normal", "weight_kg": 97.5, "reps": 6 },
                                                  { "kind": "normal", "weight_kg": 97.5, "reps": 6 }, { "kind": "normal", "weight_kg": 97.5, "reps": 5 } ],
                                        "next": { "weight_kg": 100, "reps": 6, "sets": 4 } } },
        "romanian-deadlift": { "name": "Romanian Deadlift", "equipment": "barbell", "primary": ["hamstrings"], "secondary": ["glutes","lower-back"],
                               "prefill": { "sets": [ { "kind": "normal", "weight_kg": 95, "reps": 8 } ], "next": { "weight_kg": 95, "reps": 8, "sets": 3 } } },
        "leg-press": { "name": "Leg Press", "equipment": "machine", "primary": ["quadriceps"], "secondary": ["glutes","hamstrings"],
                       "prefill": { "sets": [ { "kind": "normal", "weight_kg": 180, "reps": 10 } ], "next": null } },
        "barbell-bench-press-medium-grip": { "name": "Bench Press", "equipment": "barbell", "primary": ["chest"], "secondary": ["shoulders","triceps"] },
        "hack-squat": { "name": "Hack Squat", "equipment": "machine", "primary": ["quadriceps"], "secondary": ["glutes"] }
      },
      "recent_exercise_ids": ["barbell-squat", "barbell-bench-press-medium-grip"]
    }
    """

    static let pack: WatchPack = try! WatchCoding.decoder().decode(WatchPack.self, from: Data(packJSON.utf8))

    /// `session.heat` as the server returns it for this legs session.
    static let serverHeat: [String: Int] = [
        "quadriceps": 4, "glutes": 4, "hamstrings": 3, "calves": 3, "lower-back": 2, "adductors": 3, "abductors": 1,
    ]

    static let prs: [WorkoutPostResponse.PR] = try! APICoding.decoder().decode([WorkoutPostResponse.PR].self, from: Data("""
    [{"exercise_id":"barbell-squat","exercise":"Barbell Squat","set":"100 kg × 6","e1rm_kg_estimate":120,"previous_best_estimate":116.7}]
    """.utf8))
}
#endif
