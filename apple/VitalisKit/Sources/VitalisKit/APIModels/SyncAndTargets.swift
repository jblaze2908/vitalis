import Foundation

// MARK: GET /v2/sync/status (10 §2)

public struct SyncStatus: Codable, Sendable, Equatable {
    public struct Token: Codable, Sendable, Equatable {
        public let name: String?
        public let scope: String
        public let canPush, canRead, canWrite: Bool
    }
    public struct Server: Codable, Sendable, Equatable {
        public let version, time, tz: String?
    }
    public struct TypeCount: Codable, Sendable, Equatable {
        public let type: String
        public let live, deleted: Int
        public let newestEnd: String?
    }
    /// Struct, not a dictionary: the snake-case strategy would rewrite `daily_stats` as a dictionary key.
    public struct Counts: Codable, Sendable, Equatable {
        public let inserted, updated, unchanged, deleted, dailyStats, rejected: Int?
    }
    public struct Batch: Codable, Sendable, Equatable {
        public let batchId: String
        public let payloadId: Int?
        public let receivedAt: String?
        public let counts: Counts?
        public let rejected: [JSONValue]?
    }
    /// Optional: exporter-era servers omit the token/server blocks.
    public let token: Token?
    public let server: Server?
    public let lastBatchAt: String?
    public let types: [TypeCount]
    public let batches: [Batch]
}

// MARK: GET / PUT /v2/targets (10 §3)

public struct TargetsResponse: Codable, Sendable, Equatable {
    public struct Values: Codable, Sendable, Equatable {
        public let steps: Int?
        public let kcalMode: String?
        public let kcal: Int?
        public let proteinG: Double?
        public let sleepNeedH: Double?
        public let wakeTime: String?
        public let goalWeightKg: Double?
        /// `lose` | `maintain` | `gain`; nil from older servers or when unset.
        public let goal: String?
        public let exerciseMin: Int?
        public let weeklySetsMin: Int?
        public let weeklySetsMax: Int?
        public let restS: Int?
        public let crownStepKg: Double?
    }
    public struct Effective: Codable, Sendable, Equatable {
        public let steps: Int?
        public let kcal: Int?
        public let proteinG: Double?
        public let sleepNeedH: Double?
        public let wakeTime: String?
        public let bedBy: String?
    }
    public struct Suggestion: Codable, Sendable, Equatable {
        public let value: Double?
        public let basis: String?
    }
    public struct Suggested: Codable, Sendable, Equatable {
        public let steps, kcal, proteinG, sleepNeedH, goalWeightKg: Suggestion?
    }
    public struct IsSet: Codable, Sendable, Equatable {
        public let steps, kcalMode, kcal, proteinG, sleepNeedH, wakeTime, goalWeightKg, goal: Bool?
        public let exerciseMin, weeklySetsMin, weeklySetsMax, restS, crownStepKg: Bool?
    }
    /// How the calorie target follows from the goal (10 §3, 11 §8.2).
    public struct Plan: Codable, Sendable, Equatable {
        public let goal: String?
        public let goalWeightKg: Double?
        public let trendKg: Double?
        public let rateKgWeek: Double
        public let maintenanceKcal: Int?
        public let kcal: Int?
        public let kcalMode: String?
        /// `adaptive` (logged food + weight), `watch` (resting + active energy) or `estimate` (30 kcal per kg).
        public let basis: String
        public let reached: Bool
    }
    public let values: Values
    public let effective: Effective
    public let suggested: Suggested?
    /// Nil from servers older than goals.
    public let plan: Plan?
    public let isSet: IsSet?
    public let freshness: Freshness?
}
