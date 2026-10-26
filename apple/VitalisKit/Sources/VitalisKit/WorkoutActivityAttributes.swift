#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// The live workout on the Lock Screen and Dynamic Island (Draft frame "05 · Live workout").
/// Shared so the app can start it and the widget extension can draw it.
public struct WorkoutActivityAttributes: ActivityAttributes {
    /// `LiveSession.id`, so a relaunched app (or an intent run in the background) finds its own activity.
    public var sessionID: String
    public var title: String

    public init(sessionID: String, title: String) {
        self.sessionID = sessionID
        self.title = title
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var exercise: String
        /// Working set about to be done, 1-based; equals `setTotal` once the exercise is finished.
        public var setIndex: Int
        public var setTotal: Int
        /// The last set logged for this exercise, `80 × 8`; last session's set before the first one.
        public var last: String?
        /// The set the rest leads into, `80 × 8`.
        public var next: String?
        public var restEnd: Date?
        /// Full rest length, so the bar and ring empty from `restEnd - restTotal`.
        public var restTotal: TimeInterval
        public var heartRate: Int?
        public var startedAt: Date
        public var totalSets: Int
        public var volumeKg: Double

        public init(exercise: String, setIndex: Int, setTotal: Int, last: String?, next: String?, restEnd: Date?,
                    restTotal: TimeInterval, heartRate: Int?, startedAt: Date, totalSets: Int, volumeKg: Double) {
            self.exercise = exercise; self.setIndex = setIndex; self.setTotal = setTotal; self.last = last; self.next = next
            self.restEnd = restEnd; self.restTotal = restTotal; self.heartRate = heartRate; self.startedAt = startedAt
            self.totalSets = totalSets; self.volumeKg = volumeKg
        }

        /// The rest as a closed range for `Text(timerInterval:)` / `ProgressView(timerInterval:)`; nil when not resting.
        public var restInterval: ClosedRange<Date>? {
            guard let restEnd else { return nil }
            return restEnd.addingTimeInterval(-max(restTotal, 1))...restEnd
        }

        /// `Set 3/4`
        public var compactSetLine: String { "Set \(setIndex)/\(setTotal)" }

        /// `Set 3 of 4 · last 80 × 8`
        public var setLine: String {
            ["Set \(setIndex) of \(setTotal)", last.map { "last \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }

        /// `9 sets · 3,105 kg`
        public var totalsLine: String {
            let kg = Int(volumeKg.rounded()).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
            return "\(totalSets) \(totalSets == 1 ? "set" : "sets") · \(kg) kg"
        }
    }
}
#endif
