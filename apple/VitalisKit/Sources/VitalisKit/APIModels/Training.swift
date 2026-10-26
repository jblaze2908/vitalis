import Foundation

// MARK: GET /v2/training (10 §6)

public struct SessionRow: Codable, Sendable, Equatable {
    public struct Tag: Codable, Sendable, Equatable {
        public let kind: String
        public let label: String
    }
    public let id: String
    /// `strength` | `cardio`
    public let kind: String
    public let title: String?
    public let day: String
    public let start: String?
    public let durationMin: Int?
    public let workingSets: Int?
    public let hrAvg: Double?
    /// Set when back-to-back workouts were merged into one visit.
    public let partCount: Int?
    public let tag: Tag?
}

public struct TrainingResponse: Codable, Sendable, Equatable {
    public struct Muscle: Codable, Sendable, Equatable {
        public let slug: String
        public let heat: Int
        public let load: Double?
        public let daysSince: Int?
        public let weekSets: Int?
        public let status: String?
    }
    public struct Stats: Codable, Sendable, Equatable {
        public let sessions, workingSets, musclesHit, musclesTotal: Int
    }
    public struct WeeklySets: Codable, Sendable, Equatable {
        public let min: Int
        public let max: Int
        public let byMuscle: [String: Int]
    }
    public let weekStart: String
    public let weekEnd: String
    public let label: String?
    public let heat: MuscleHeat
    public let muscles: [Muscle]
    /// Nil from servers older than splits (11 §7.2).
    public let splits: [Split]?
    public let stats: Stats?
    public let weeklySets: WeeklySets?
    public let sessions: [SessionRow]
    public let empty: Bool
    public let freshness: Freshness?
}

// MARK: GET /v2/training/sessions (10 §6)

public struct SessionsPage: Codable, Sendable, Equatable {
    public let sessions: [SessionRow]
    public let next: String?
    public let freshness: Freshness?
}

// MARK: GET /v2/training/sessions/:id (10 §6)

/// Strength sessions fill the first group; Watch-only cardio ids return the `hk_workouts` row
/// (`name`, `duration_s`, `hr_*`, `distance_km`), so almost everything is optional.
public struct SessionDetail: Codable, Sendable, Equatable {
    public struct TopSet: Codable, Sendable, Equatable {
        public let weightKg: Double?
        public let reps: Int?
    }
    public struct LoggedSet: Codable, Sendable, Equatable {
        public let id: String
        public let kind: String
        public let weightKg: Double?
        public let reps: Int?
        public let at: String?
        public let note: String?
    }
    public struct Exercise: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let workingSets: Int
        public let topSet: TopSet?
        public let summary: String?
        public let pr: Bool
        public let sets: [LoggedSet]
    }
    public struct Watch: Codable, Sendable, Equatable {
        public let workoutId: String
        public let hrAvg: Double?
        public let hrMax: Double?
    }
    /// One workout inside a visit (a walk, the elliptical, the logged sets).
    public struct Part: Codable, Sendable, Equatable {
        public let id: String
        public let kind: String
        public let title: String?
        public let start: String
        public let end: String
        public let durationMin: Int
        public let hrAvg: Double?
        public let hrMax: Double?
        public let activeKcal: Double?
        public let distanceKm: Double?
        public let workingSets: Int?
    }
    public let id: String
    public let kind: String
    public let title: String?
    public let template: String?
    public let clientSource: String?
    public let start: String?
    public let end: String?
    public let durationMin: Int?
    public let contextLabel: String?
    public let workingSets: Int?
    public let volumeKg: Double?
    public let avgBpm: Double?
    public let activeKcal: Double?
    public let heat: MuscleHeat?
    public let exercises: [Exercise]?
    public let watch: Watch?
    // Cardio (`hk_workouts`) fields.
    public let name: String?
    public let day: String?
    public let durationS: Double?
    public let hrMin: Double?
    public let hrAvg: Double?
    public let hrMax: Double?
    public let distanceKm: Double?
    public let source: String?
    public let hr: WorkoutHeart?
    public let parts: [Part]?
    public let freshness: Freshness?

    public var isCardio: Bool { kind == "cardio" }
}

// MARK: GET / POST /v2/exercises, GET /v2/exercises/:id (10 §6)

public struct ExerciseInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let equipment: String?
    public let primary: [String]
    public let secondary: [String]
    /// Not emitted by the detail endpoint.
    public let aliases: [String]?
    public let custom: Bool?
}

public struct ExerciseList: Codable, Sendable, Equatable {
    public let generatedAt: String?
    public let count: Int
    public let exercises: [ExerciseInfo]
}

public struct ExerciseCreated: Codable, Sendable, Equatable {
    public let exercise: ExerciseInfo
    public let created: Bool
}

public struct ExerciseDetail: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public let day: String
        public let kg: Double
        public let sessionId: String?
    }
    public struct E1RM: Codable, Sendable, Equatable {
        public let currentKg: Double?
        public let change8wKg: Double?
        public let points: [Point]
        public let estimate: Bool?
        // convertFromSnakeCase capitalises after a digit: `change_8w_kg` arrives as `change8WKg`.
        private enum CodingKeys: String, CodingKey { case currentKg, change8wKg = "change8WKg", points, estimate }
    }
    public struct Records: Codable, Sendable, Equatable {
        public let bestE1rmKg: Double?
        public let bestSet: String?
        public let on: String?
        public let heaviestKg: Double?
        // convertFromSnakeCase capitalises after a digit: `best_e1rm_kg` arrives as `bestE1RmKg`.
        private enum CodingKeys: String, CodingKey { case bestE1rmKg = "bestE1RmKg", bestSet, on, heaviestKg }
    }
    public struct Next: Codable, Sendable, Equatable {
        public let rule: String?
        public let lastTop: String?
        public let suggestion: String?
        public let weightKg: Double?
        public let reps: Int?
        public let sets: Int?
    }
    public struct PlannedSet: Codable, Sendable, Equatable {
        public let kind: String
        public let weightKg: Double?
        public let reps: Int?
    }
    public struct LastSession: Codable, Sendable, Equatable {
        public let sessionId: String
        public let day: String
        public let sets: [PlannedSet]
    }
    public struct Performance: Codable, Sendable, Equatable {
        public let sessionId: String
        public let day: String
        public let title: String?
        public let bestSet: String?
        public let e1rmKg: Double?
        public let volumeKg: Double?
        public let sets: [PlannedSet]
    }
    public let exercise: ExerciseInfo
    public let contextLabel: String?
    public let e1rm: E1RM?
    public let records: Records?
    public let next: Next?
    public let lastSession: LastSession?
    public let sessionsTotal: Int?
    public let history: [Performance]?
    public let freshness: Freshness?
}

// MARK: POST /v2/workouts (10 §6)

public struct WorkoutPostResponse: Codable, Sendable, Equatable {
    public struct Accepted: Codable, Sendable, Equatable {
        public let inserted, updated, deleted, unchanged: Int
    }
    public struct PR: Codable, Sendable, Equatable {
        public let exerciseId: String
        public let exercise: String
        public let set: String
        public let e1rmKgEstimate: Double
        public let previousBestEstimate: Double?
    }
    public let session: SessionDetail
    public let accepted: Accepted
    public let prs: [PR]
}
