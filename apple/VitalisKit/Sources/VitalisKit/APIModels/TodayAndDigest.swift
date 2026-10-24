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
        public let due: DueWorkout?
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
    public let fuel: Fuel
    public let activity: Activity
    public let training: Training
    public let pulse: Pulse?
    public let digest: DigestFlag?
    public let freshness: Freshness?
}

/// `due` block shared by /v2/today and /v2/training.
public struct DueWorkout: Codable, Sendable, Equatable {
    public struct Exercise: Codable, Sendable, Equatable {
        public struct Last: Codable, Sendable, Equatable {
            public let weightKg: Double?
            public let reps: Int?
            public let day: String?
        }
        public let id: String
        public let name: String
        public let last: Last?
    }
    public let template: String
    public let name: String
    public let daysSince: Int?
    public let exerciseCount: Int?
    public let exercises: [Exercise]
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
