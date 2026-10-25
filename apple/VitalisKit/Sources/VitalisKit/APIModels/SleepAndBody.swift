import Foundation

// MARK: GET /v2/sleep (10 §5)

public struct SleepResponse: Codable, Sendable, Equatable {
    public struct Night: Codable, Sendable, Equatable {
        public let sleepStart: String
        public let sleepEnd: String
        public let inBedStart: String?
        public let inBedEnd: String?
        public let asleepH: Double?
        public let asleepLabel: String?
        public let source: String?
        /// Stages in time order (`deep` `core` `rem` `awake` `asleep`); nil for summarised nights or older servers.
        public let segments: [Segment]?
    }
    public struct Segment: Codable, Sendable, Equatable {
        public let stage: String
        public let start: String
        public let end: String
    }
    /// Sleep on the same day outside the night (sleep-split.ts): listed, never scored.
    public struct Nap: Codable, Sendable, Equatable {
        public let start: String
        public let end: String
        public let asleepH: Double
        public let asleepLabel: String?
    }
    public struct Duration: Codable, Sendable, Equatable {
        public let asleepLabel: String?
        public let vsUsualMin: Int?
        public let vsUsualLabel: String?
        public let needH: Double?
        public let needLabel: String?
        public let needBasis: String?
        /// Hours a nap before this night took off its need.
        public let napCreditH: Double?
    }
    public struct Part: Codable, Sendable, Equatable {
        public let key: String
        public let label: String
        public let detail: String?
        public let score: Int?
        public let flagged: Bool?
        public let weight: Double?
    }
    public struct Stages: Codable, Sendable, Equatable {
        public let coreH, deepH, remH, awakeH: Double?
        public let note: String?
    }
    public struct Tonight: Codable, Sendable, Equatable {
        public let bedBy: String?
        public let wakeTime: String?
        public let needH: Double?
        public let label: String?
    }
    public let day: String
    public let hasNight: Bool
    public let prevDay: String?
    public let nextDay: String?
    public let night: Night?
    public let score: Int?
    public let band: String?
    public let label: String?
    public let status: String?
    public let duration: Duration?
    public let parts: [Part]?
    public let stages: Stages?
    public let tonight: Tonight?
    public let freshness: Freshness?
    public let naps: [Nap]?
    public let totalH: Double?
}

// MARK: GET /v2/sleep/week and /v2/sleep/month (10 §5)

/// One night in the week or month list; bed and wake are ISO with offset.
public struct SleepNightRow: Codable, Sendable, Equatable {
    public let day: String
    public let score: Int?
    public let asleepH: Double?
    public let sleepStart: String?
    public let sleepEnd: String?
    public let napH: Double?
}

public struct SleepAverages: Codable, Sendable, Equatable {
    public let asleepH: Double?
    public let score: Int?
    public let bedtime: String?
    public let wake: String?
    public let napH: Double?
    public let nights: Int
    public let missing: Int
}

public struct SleepWeekResponse: Codable, Sendable, Equatable {
    public typealias Night = SleepNightRow
    public let end: String
    public let nights: [Night]
    public let avgScore: Int?
    public let bedtimeSpreadMin: Int?
    public let label: String?
    public let freshness: Freshness?
    public let avg: SleepAverages?
    public let prevAvgScore: Int?
}

public struct SleepMonthResponse: Codable, Sendable, Equatable {
    public let month: String
    public let days: [SleepNightRow]
    public let avg: SleepAverages?
    public let prevAvgScore: Int?
    public let prevMonth: String?
    public let nextMonth: String?
    public let freshness: Freshness?
}

// MARK: GET /v2/body, POST/DELETE /v2/weight (10 §5)

public struct WeightBlock: Codable, Sendable, Equatable {
    public struct Latest: Codable, Sendable, Equatable {
        public let kg: Double
        public let at: String?
        public let source: String?
        public let manual: Bool?
    }
    public struct Point: Codable, Sendable, Equatable {
        public let day: String
        public let rawKg: Double?
        public let trendKg: Double?
    }
    public let trendKg: Double?
    public let monthChangeKg: Double?
    public let goalKg: Double?
    public let towardGoal: Bool?
    public let latest: Latest?
    public let series: [Point]
}

public struct BodyResponse: Codable, Sendable, Equatable {
    public struct DaySteps: Codable, Sendable, Equatable {
        public let day: String
        public let steps: Int?
    }
    public struct Activity: Codable, Sendable, Equatable {
        public let steps: Int?
        public let stepsTarget: Int?
        public let activeKcal: Double?
        public let exerciseMin: Int?
        public let exerciseTargetMin: Int?
        public let week: [DaySteps]
    }
    public struct Vital: Codable, Sendable, Equatable {
        public let key: String
        public let label: String
        public let value: Double?
        public let unit: String?
        public let usual: Double?
        public let usualRange: [Double]?
        public let flag: String?
        public let reading: String?
    }
    public let day: String
    public let weight: WeightBlock
    public let activity: Activity
    public let vitals: [Vital]
    public let freshness: Freshness?
}

public struct WeightPostResponse: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public let kg: Double
        public let day: String
    }
    public let entry: Entry
    public let weight: WeightBlock
}

public struct WeightDeleteResponse: Codable, Sendable, Equatable {
    public let weight: WeightBlock
}
