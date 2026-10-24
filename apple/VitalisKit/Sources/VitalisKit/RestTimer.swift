import Foundation

/// Rest countdown (spec 21 §2.3). Time is read from a stored end date, so it stays right after wrist-down or a suspended view.
public struct RestTimer: Codable, Sendable, Equatable {
    public static let step: TimeInterval = 15

    public private(set) var endsAt: Date
    /// Ring denominator; grows when +15 pushes the remaining time past it, so the ring never overfills.
    public private(set) var total: TimeInterval

    public init(start: Date, duration: TimeInterval) {
        total = max(duration, 1)
        endsAt = start.addingTimeInterval(max(duration, 0))
    }

    public func remaining(at now: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }

    public func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }

    /// Ring length 0…1: remaining / total.
    public func fraction(at now: Date) -> Double { min(1, max(0, remaining(at: now) / total)) }

    /// ±15 s from now's remaining time; −15 near zero ends the rest.
    public func adjusted(by delta: TimeInterval, at now: Date) -> RestTimer {
        var copy = self
        let remaining = max(0, remaining(at: now) + delta)
        copy.endsAt = now.addingTimeInterval(remaining)
        copy.total = max(total, remaining)
        return copy
    }

    /// `1:24`; whole seconds rounded up so the clock shows 0:00 only when the rest is over.
    public static func clockText(_ remaining: TimeInterval) -> String {
        let s = Int(max(0, remaining).rounded(.up))
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}
