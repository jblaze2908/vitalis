import Foundation

/// JSON without Any crossing concurrency boundaries. Nulls are encoded explicitly.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try box.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        }
    }

    public static func optional(_ value: String?) -> JSONValue { value.map(Self.string) ?? .null }
    public static func finite(_ value: Double?) -> JSONValue {
        guard let value, value.isFinite else { return .null }
        return .number(value)
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

/// A flat contract sample. Fields vary by kind, so encode the field dictionary directly.
public struct Sample: Codable, Sendable, Equatable {
    public var fields: [String: JSONValue]
    public init(_ fields: [String: JSONValue]) { self.fields = fields }
    public init(from decoder: any Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        try box.encode(fields)
    }
    public var uuid: String { fields["uuid"]?.stringValue ?? "" }
    public var type: String { fields["type"]?.stringValue ?? "" }
    public var end: String? { fields["end"]?.stringValue }
    public var pointCount: Int {
        ["points", "beats", "voltages_uv", "series"].reduce(0) {
            $0 + (fields[$1]?.arrayValue?.count ?? 0)
        }
    }
}

public struct Deletion: Codable, Sendable, Equatable {
    public let uuid: String
    public let type: String
    public init(uuid: String, type: String) { self.uuid = uuid; self.type = type }
}

public struct DailyStat: Codable, Sendable, Equatable {
    public let type: String
    public let day: String
    public let tz: String
    public let sum: Double?
    public let min: Double?
    public let avg: Double?
    public let max: Double?
    public let unit: String

    public init(type: String, day: String, tz: String, sum: Double?, min: Double?, avg: Double?, max: Double?, unit: String) {
        self.type = type; self.day = day; self.tz = tz
        self.sum = sum; self.min = min; self.avg = avg; self.max = max; self.unit = unit
    }
    enum CodingKeys: String, CodingKey { case type, day, tz, sum, min, avg, max, unit }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(type, forKey: .type); try box.encode(day, forKey: .day)
        try box.encode(tz, forKey: .tz); try box.encode(unit, forKey: .unit)
        try box.encode(sum, forKey: .sum); try box.encode(min, forKey: .min)
        try box.encode(avg, forKey: .avg); try box.encode(max, forKey: .max)
    }
}

public struct ClientInfo: Codable, Sendable, Equatable {
    public let install_id: String
    public let app_version: String
    public let os: String
    public let model: String
    public init(installID: String, appVersion: String, os: String, model: String) {
        install_id = installID; app_version = appVersion; self.os = os; self.model = model
    }
}

public struct SampleBatch: Codable, Sendable, Equatable {
    public let schema: Int
    public let batch_id: String
    public let client: ClientInfo
    public var upserts: [Sample]
    public var deletions: [Deletion]
    public var daily_stats: [DailyStat]
    public init(client: ClientInfo, upserts: [Sample] = [], deletions: [Deletion] = [], dailyStats: [DailyStat] = []) {
        schema = 1; batch_id = UUID().uuidString; self.client = client
        self.upserts = upserts; self.deletions = deletions; daily_stats = dailyStats
    }
    public var objectCount: Int { upserts.count + deletions.count + daily_stats.count }
    public var pointCount: Int { upserts.reduce(0) { $0 + $1.pointCount } }
}

public struct RejectedItem: Codable, Sendable, Equatable {
    public let uuid: String
    public let reason: String
    public init(uuid: String, reason: String) { self.uuid = uuid; self.reason = reason }
}
public struct UploadResponse: Codable, Sendable, Equatable {
    public let batch_id: String
    public let duplicate: Bool
    public let counts: [String: Int]
    public let rejected: [RejectedItem]
    public init(batchID: String, duplicate: Bool = false, counts: [String: Int] = [:], rejected: [RejectedItem] = []) {
        batch_id = batchID; self.duplicate = duplicate; self.counts = counts; self.rejected = rejected
    }
}

public enum WireDate {
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Use the device's current offset, including for historical samples.
        formatter.timeZone = TimeZone(secondsFromGMT: timeZone.secondsFromGMT(for: Date()))
        return formatter.string(from: date)
    }
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
