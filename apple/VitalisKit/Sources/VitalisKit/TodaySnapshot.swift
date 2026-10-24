import Foundation

/// The slice of `GET /v2/today` that widgets and complications read; they never call the network (spec 20 §9).
public struct TodaySnapshot: Codable, Sendable, Equatable {
    public struct Verdict: Codable, Sendable, Equatable {
        public var band: String?
        public var label: String?
        public var headline: String
        public init(band: String?, label: String?, headline: String) {
            self.band = band; self.label = label; self.headline = headline
        }
    }
    public struct Recovery: Codable, Sendable, Equatable {
        public var score: Int?
        public var band: String?
        public init(score: Int?, band: String?) { self.score = score; self.band = band }
    }

    public var day: String
    public var verdict: Verdict
    public var recovery: Recovery
    public var steps: Int?
    public var stepsTarget: Int?
    public var kcalLeft: Double?
    public var proteinG: Double?
    public var proteinTargetG: Double?
    public var pulse: Pulse?
    public var lastSync: String?
    public var generatedAt: String?

    public init(day: String, verdict: Verdict, recovery: Recovery, steps: Int?, stepsTarget: Int?, kcalLeft: Double?,
                proteinG: Double?, proteinTargetG: Double?, pulse: Pulse?, lastSync: String?, generatedAt: String?) {
        self.day = day; self.verdict = verdict; self.recovery = recovery; self.steps = steps; self.stepsTarget = stepsTarget
        self.kcalLeft = kcalLeft; self.proteinG = proteinG; self.proteinTargetG = proteinTargetG; self.pulse = pulse
        self.lastSync = lastSync; self.generatedAt = generatedAt
    }

    public init(_ today: TodayResponse) {
        self.init(day: today.day,
                  verdict: Verdict(band: today.verdict.band, label: today.verdict.label, headline: today.verdict.headline),
                  recovery: Recovery(score: today.recovery.score, band: today.recovery.band),
                  steps: today.activity.steps, stepsTarget: today.activity.stepsTarget, kcalLeft: today.fuel.kcalLeft,
                  proteinG: today.fuel.proteinG, proteinTargetG: today.fuel.proteinTargetG, pulse: today.pulse,
                  lastSync: today.freshness?.lastSync, generatedAt: today.generatedAt)
    }

    public static let fileName = "today-snapshot.json"

    /// `group.<prefix>.vitalis` from any Vitalis bundle id (app, widgets, watch app, tests).
    public static func appGroupID(bundleIdentifier: String?) -> String? {
        guard let parts = bundleIdentifier?.split(separator: "."), let i = parts.firstIndex(of: "vitalis"), i > 0 else { return nil }
        return "group." + parts[...i].joined(separator: ".")
    }

    /// App Group container when the entitlement resolves, else `Application Support/Vitalis` (App Groups may be
    /// unavailable on a free team, spec 50 Q2).
    public static func defaultDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> URL {
        if let group = appGroupID(bundleIdentifier: bundleIdentifier),
           let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return shared.appendingPathComponent("Library/Application Support/Vitalis", isDirectory: true)
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Vitalis", isDirectory: true)
    }

    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try APICoding.encoder().encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Missing or unreadable file → nil; widgets then show `–`.
    public static func read(from directory: URL) -> TodaySnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? APICoding.decoder().decode(TodaySnapshot.self, from: data)
    }
}
