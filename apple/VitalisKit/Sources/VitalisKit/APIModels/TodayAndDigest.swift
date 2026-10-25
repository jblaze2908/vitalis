import Foundation

// MARK: GET /v2/today (10 §4)

public struct TodayResponse: Codable, Sendable, Equatable {
    public struct Action: Codable, Sendable, Equatable {
        public let kind: String
        public let label: String
        public let template: String?
        public let intensity: String?
    }
    public struct Verdict: Codable, Sendable, Equatable {
        public let band: String?
        public let label: String?
        public let headline: String
        public let reason: String?
        public let action: Action?
    }
    public struct VitalPart: Codable, Sendable, Equatable {
        public let value: Double?
        public let unit: String?
        public let basis: String?
        public let usual: Double?
        public let usualRange: [Double]?
        public let z: Double?
        public let score: Int?
        public let arrow: String?
        public let tint: String?
        /// Seven daily values ending today, oldest first (Today's sparkline); nil from older servers.
        public let week: [Double?]?
    }
    /// Band floors (`ready ≥ 75`, `steady ≥ 60`, `ease ≥ 45`, else rest), so the band bar never keeps its own copy.
    public struct Bands: Codable, Sendable, Equatable {
        public let ready: Int
        public let steady: Int
        public let ease: Int
    }
    /// Last night for Today's Sleep card: hours asleep (naps excluded), need after any nap credit, score.
    public struct SleepSummary: Codable, Sendable, Equatable {
        public let asleepH: Double?
        public let needH: Double?
        public let score: Int?
        public let band: String?
    }
    public struct RecoveryParts: Codable, Sendable, Equatable {
        public let sleep: ScoreBand?
        public let hrv: VitalPart?
        public let restingHr: VitalPart?
    }
    public struct Recovery: Codable, Sendable, Equatable {
        public let score: Int?
        public let band: String?
        /// `ok` | `calibrating` | `missing`
        public let status: String
        public let reason: String?
        public let nightsOfHistory: Int?
        public let nightsNeeded: Int?
        public let parts: RecoveryParts?
        public let bands: Bands?
    }
    public struct Fuel: Codable, Sendable, Equatable {
        public let kcalTarget: Double?
        public let kcalEaten: Double?
        public let kcalLeft: Double?
        public let proteinTargetG: Double?
        public let proteinG: Double?
        public let nextSlot: String?
        public let nextLabel: String?
    }
    public struct Activity: Codable, Sendable, Equatable {
        public let steps: Int?
        public let stepsTarget: Int?
        public let stepsExpectedNow: Int?
        public let stepsPace: String?
        public let activeKcal: Double?
        public let activeKcalExpectedNow: Double?
        public let activeKcalPace: String?
    }
    public struct Training: Codable, Sendable, Equatable {
        public let heat: MuscleHeat
        public let freshLabel: String?
        public let loadedLabel: String?
        /// Nil from servers older than splits (11 §7.2).
        public let splits: [Split]?
        public let trainedToday: Bool?
    }
    public struct DigestFlag: Codable, Sendable, Equatable {
        public let available: Bool
        public let nightEndedAt: String?
    }
    public let day: String
    public let generatedAt: String?
    public let verdict: Verdict
    public let recovery: Recovery
    public let sleep: SleepSummary?
    public let fuel: Fuel
    public let activity: Activity
    public let training: Training
    public let pulse: Pulse?
    public let digest: DigestFlag?
    public let freshness: Freshness?
}

/// One of the owner's splits, shared by /v2/today and /v2/training (11 §7.2–7.3). Offered as a choice, never picked for them.
public struct Split: Codable, Sendable, Equatable, Identifiable {
    public struct Exercise: Codable, Sendable, Equatable {
        public struct Last: Codable, Sendable, Equatable {
            public let weightKg: Double?
            public let reps: Int?
            public let day: String?
        }
        public let id: String
        public let name: String
        public let last: Last?
        public init(id: String, name: String, last: Last? = nil) { self.id = id; self.name = name; self.last = last }
    }
    public let id: String
    public let name: String
    /// `defined` (Settings) or `history` (a logged workout name).
    public let source: String
    public let ready: Bool
    public let daysSince: Int?
    public let muscles: [String]?
    public let exerciseCount: Int?
    public let exercises: [Exercise]

    public init(id: String, name: String, source: String = "defined", ready: Bool = true, daysSince: Int? = nil, muscles: [String]? = nil,
                exerciseCount: Int? = nil, exercises: [Exercise] = []) {
        self.id = id; self.name = name; self.source = source; self.ready = ready; self.daysSince = daysSince; self.muscles = muscles
        self.exerciseCount = exerciseCount; self.exercises = exercises
    }

    /// The id to send as `session.template`: only Settings splits have a stable id; history splits match by title.
    public var templateID: String? { source == "defined" ? id : nil }
}

// MARK: GET /v2/splits, PUT / DELETE /v2/splits/:id (10 §6)

public struct DefinedSplit: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var muscles: [String]
    public let ord: Int
}

public struct SplitsResponse: Codable, Sendable, Equatable {
    public let splits: [DefinedSplit]
}

public struct SplitPut: Codable, Sendable, Equatable {
    public let name: String
    public let muscles: [String]
    public let ord: Int?
    public init(name: String, muscles: [String], ord: Int? = nil) { self.name = name; self.muscles = muscles; self.ord = ord }
}

// MARK: GET /v2/digest (10 §4)

public struct DigestResponse: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable {
        public let key: String
        public let label: String
        public let value: String?
        /// Absent on some rows (e.g. efficiency).
        public let delta: String?
        public let tint: String?
    }
    public struct Sleep: Codable, Sendable, Equatable {
        public let score: Int?
        public let band: String?
        public let rows: [Row]
    }
    public struct Signal: Codable, Sendable, Equatable {
        public let value: Double?
        public let arrow: String?
        public let tint: String?
    }
    public struct Recovery: Codable, Sendable, Equatable {
        public let score: Int?
        public let band: String?
        public let label: String?
        public let hrv: Signal?
        public let restingHr: Signal?
    }
    public struct Workout: Codable, Sendable, Equatable {
        public let id: String
        public let title: String?
        public let kind: String?
    }
    public struct Yesterday: Codable, Sendable, Equatable {
        public let day: String
        public let steps: Int?
        public let activeKcal: Double?
        public let workout: Workout?
    }
    public struct PlanItem: Codable, Sendable, Equatable {
        public let kind: String
        public let title: String
        public let reason: String?
        public let primary: Bool
    }
    public let day: String
    public let available: Bool
    public let nightEndedAt: String?
    public let dateLabel: String?
    public let greeting: String?
    public let headline: [String]
    public let sleep: Sleep?
    public let recovery: Recovery?
    public let yesterday: Yesterday?
    public let plan: [PlanItem]
    public let pulse: Pulse?
    public let freshness: Freshness?
}
