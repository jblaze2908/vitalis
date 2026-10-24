import Foundation

/// Response models keep timestamps as the server's strings (its clock text is shown as-is); parse with `APIDate`.
public enum APICoding {
    /// Fresh per call: `JSONDecoder` is not `Sendable`.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public enum APIDate {
    /// ISO 8601 with offset, with or without fractional seconds (`2026-10-24T09:39:00+05:30`, `…16:14:13.675Z`).
    public static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
    /// Server-local wall-clock offset of a timestamp, so the UI can keep the server's day/clock.
    public static func offsetSeconds(_ text: String) -> Int? {
        guard text.count >= 6 else { return nil }
        if text.hasSuffix("Z") { return 0 }
        let tail = text.suffix(6)
        guard let sign = tail.first, sign == "+" || sign == "-",
              let h = Int(tail.dropFirst().prefix(2)), let m = Int(tail.suffix(2)) else { return nil }
        return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }
    /// `HH:MM` as written by the server for a timestamp (no device-timezone conversion).
    public static func clockText(_ text: String) -> String? {
        guard let t = text.firstIndex(of: "T") else { return nil }
        let clock = text[text.index(after: t)...].prefix(5)
        return clock.count == 5 ? String(clock) : nil
    }
    /// `x = (t − start) / (end − start)` clamped to 0…1 (10 §4 pulse mapping; display only).
    public static func fraction(_ at: String, start: String, end: String) -> Double? {
        guard let t = parse(at), let s = parse(start), let e = parse(end), e > s else { return nil }
        return min(1, max(0, t.timeIntervalSince(s) / e.timeIntervalSince(s)))
    }
}

/// `{error, code}` body of every non-2xx response (10 §1.3).
public struct APIErrorBody: Codable, Sendable, Equatable {
    public let error: String
    public let code: String?
}

public struct Freshness: Codable, Sendable, Equatable {
    public struct DataThrough: Codable, Sendable, Equatable {
        public let sleep, heart, activity, weight, food, training: String?
    }
    public let lastSync: String?
    public let dataThrough: DataThrough?
    public let today: String?
}

public struct Pulse: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable { public let start, end: String }
    public struct Event: Codable, Sendable, Equatable { public let at, kind: String }
    public let window: Window
    public let now: String
    public let events: [Event]
}

/// Muscle slug → heat 0…4. Slugs use hyphens, so `convertFromSnakeCase` leaves these dictionary keys alone.
public typealias MuscleHeat = [String: Int]

public struct ScoreBand: Codable, Sendable, Equatable {
    public let score: Int?
    public let band: String?
}
