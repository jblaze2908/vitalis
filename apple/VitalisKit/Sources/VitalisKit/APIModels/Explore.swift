import Foundation

/// `/v2/heart`: one local day of heart rate in fixed buckets, with that day's sleep and workouts.
public struct HeartDay: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        /// Minute of the local day the bucket starts at.
        public let m: Int
        public let avg, lo, hi: Int
        public init(m: Int, avg: Int, lo: Int, hi: Int) { self.m = m; self.avg = avg; self.lo = lo; self.hi = hi }
    }
    public struct Resting: Codable, Sendable, Equatable {
        public let value: Double?
        public let usual: Double?
        public let usualRange: [Double]?
        public let flag: String?
        public let reading: String?
    }
    public struct Summary: Codable, Sendable, Equatable {
        public let avg, min, max: Int?
        public let minAt, maxAt: String?
        public let avgUsual: Int?
        public let resting: Resting?
    }
    public struct Span: Codable, Sendable, Equatable {
        public let startM, endM: Int
    }
    public struct Workout: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let startM, endM: Int
        public let avgBpm, maxBpm: Int?
    }
    public let day: String
    public let prevDay: String
    public let nextDay: String?
    public let bucketMin: Int
    public let readings: Int
    public let nowM: Int?
    public let points: [Point]
    public let summary: Summary
    public let sleep: [Span]
    public let workouts: [Workout]
    public let freshness: Freshness?
}

/// A workout's heart rate: `s` is seconds from `start`.
public struct WorkoutHeart: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public let s: Double
        public let bpm: Int
        public init(s: Double, bpm: Int) { self.s = s; self.bpm = bpm }
    }
    public let bucketS: Double
    public let points: [Point]
    public let min, avg, max: Int
    public let start: String?
}

/// `/v2/metrics`: every stored metric, grouped, latest value against the owner's usual.
public struct MetricsOverview: Codable, Sendable, Equatable {
    public struct Metric: Codable, Sendable, Equatable {
        public let key: String
        public let name: String
        public let unit: String
        public let better: String?
        public let spark: [Double?]
        public let day: String?
        public let value: Double?
        public let usual: Double?
        public let usualRange: [Double]?
        public let flag: String?
        public let reading: String?
    }
    public struct Group: Codable, Sendable, Equatable {
        public let name: String
        public let metrics: [Metric]
    }
    public let day: String
    public let groups: [Group]
    public let freshness: Freshness?
}

/// `/v2/metrics/:key`: one metric over 7/30/90/365 days, daily up to 90 and weekly beyond.
public struct MetricHistory: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public let day: String
        public let value: Double
        public init(day: String, value: Double) { self.day = day; self.value = value }
    }
    public struct Band: Codable, Sendable, Equatable {
        public let day: String
        public let lo, hi: Double?
    }
    public struct Usual: Codable, Sendable, Equatable {
        public let value, low, high: Double
        public let days: Int
    }
    public let key: String
    public let name: String
    public let unit: String
    public let better: String?
    public let days: Int
    public let from, to: String
    public let every: String
    public let prevEnd: String
    public let nextEnd: String?
    public let points: [Point]
    public let band: [Band]?
    public let daysWithData: Int
    public let average, min, max, previousAverage: Double?
    public let usual: Usual?
    public let freshness: Freshness?
}

/// `/v2/training/exercises`: exercises with at least one working set, most recent first.
public struct PerformedExercises: Codable, Sendable, Equatable {
    public struct Top: Codable, Sendable, Equatable {
        public let weightKg: Double?
        public let reps: Int?
    }
    public struct Exercise: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let equipment: String?
        public let primary: [String]
        public let sessions: Int
        public let workingSets: Int
        public let lastDay: String
        public let lastTop: Top?
        public let heaviestKg: Double?
        public let bestE1rmKg: Double?
        public let e1rmKg: Double?
        public let change8wKg: Double?
        public let spark: [Double]
        private enum CodingKeys: String, CodingKey {
            case id, name, equipment, primary, sessions, workingSets, lastDay, lastTop, heaviestKg
            case bestE1rmKg = "bestE1RmKg", e1rmKg, change8wKg = "change8WKg", spark
        }
    }
    public let count: Int
    public let exercises: [Exercise]
    public let freshness: Freshness?
}
