import Foundation

/// What widgets and complications show, formatted from a `TodaySnapshot` (spec 20 §9, 21 §3).
/// Formatting only; a nil field renders as `–` in steel, never 0.
public struct WidgetModel: Sendable, Equatable {
    /// Band words → tint role name; mirrors the app's `TodayFormat.bandTint`, which the extensions can't link.
    public enum Tone: String, Sendable { case good, watch, steel }

    public static let dash = "–"

    public var recovery: String?
    /// `score / 100` for the corner gauge (display scaling, like a ProgressTrack fraction).
    public var recoveryGauge: Double?
    public var label: String?
    public var tone: Tone
    public var headline: String?
    public var steps: String?
    public var stepsTarget: String?
    public var kcalLeft: String?
    public var protein: String?
    public var proteinTarget: String?
    /// `HH:MM` of `generated_at` in the server's offset.
    public var asOf: String?
    public var pulse: Pulse?

    public init(_ snapshot: TodaySnapshot?) {
        let score = snapshot?.recovery.score
        recovery = Self.number(score)
        recoveryGauge = score.map { min(max(Double($0) / 100, 0), 1) }
        // The verdict's band word is what Today shows under the score; the recovery band is the fallback.
        let band = snapshot?.verdict.label != nil ? snapshot?.verdict.band : snapshot?.recovery.band
        label = snapshot?.verdict.label ?? snapshot?.recovery.band?.uppercased()
        tone = Self.tone(band)
        headline = snapshot.flatMap { $0.verdict.headline.isEmpty ? nil : $0.verdict.headline }
        steps = Self.number(snapshot?.steps)
        stepsTarget = Self.number(snapshot?.stepsTarget)
        kcalLeft = Self.number(snapshot?.kcalLeft)
        protein = Self.number(snapshot?.proteinG)
        proteinTarget = Self.number(snapshot?.proteinTargetG)
        asOf = snapshot?.generatedAt.flatMap(APIDate.clockText)
        pulse = snapshot?.pulse
    }

    public static let missing = WidgetModel(nil)

    /// `TODAY · 09:39`
    public var context: String { asOf.map { "TODAY · \($0)" } ?? "TODAY" }
    /// `3,206 / 9,000`
    public var stepsReading: String { Self.pair(steps, stepsTarget, unit: nil) }
    /// `1,780 KCAL`
    public var fuelReading: String { kcalLeft.map { "\($0) KCAL" } ?? Self.dash }
    /// `38 / 160 G`
    public var proteinReading: String { Self.pair(protein, proteinTarget, unit: "G") }
    /// `3,206 STEPS`
    public var stepsLine: String { "\(steps ?? Self.dash) STEPS" }
    /// `1,780 KCAL LEFT`
    public var kcalLine: String { "\(kcalLeft ?? Self.dash) KCAL LEFT" }
    /// `78 READY · 3,206 STEPS` (accessoryInline).
    public var inline: String {
        let head = [recovery ?? Self.dash, label].compactMap { $0 }.joined(separator: " ")
        return "\(head) · \(stepsLine)"
    }

    private static let grouping = Locale(identifier: "en_US")
    static func number(_ v: Int?) -> String? { v.map { $0.formatted(.number.grouping(.automatic).locale(grouping)) } }
    static func number(_ v: Double?) -> String? { v.map { Int($0.rounded()).formatted(.number.grouping(.automatic).locale(grouping)) } }

    static func tone(_ band: String?) -> Tone {
        switch band {
        case "ready", "steady", "good": .good
        case "ease", "rest", "watch", "poor": .watch
        default: .steel
        }
    }

    private static func pair(_ value: String?, _ target: String?, unit: String?) -> String {
        guard let value else { return dash }
        let text = target.map { "\(value) / \($0)" } ?? value
        return unit.map { "\(text) \($0)" } ?? text
    }
}

/// `vitalis://` targets for widget taps (spec 20 §3). No `slot` on log-meal: the snapshot doesn't carry `fuel.next_slot`.
public enum WidgetLink {
    public static let today = URL(string: "vitalis://today")!
    public static let logMeal = URL(string: "vitalis://eat/add")!
    public static let liveWorkout = URL(string: "vitalis://workout/live")!
}

public struct WidgetEntryModel: Sendable, Equatable {
    public let date: Date
    public let model: WidgetModel
    public init(date: Date, model: WidgetModel) { self.date = date; self.model = model }
}

/// The testable half of the timeline providers: read the shared snapshot file, one entry at `now`.
/// Runs once per timeline request (the app reloads after each new snapshot), so the file read is fine here.
public enum WidgetTimeline {
    public static func entries(directory: URL?, now: Date) -> [WidgetEntryModel] {
        [WidgetEntryModel(date: now, model: WidgetModel(directory.flatMap(TodaySnapshot.read)))]
    }

    /// The App Group directory, or nil when the group isn't provisioned (Q2): the widgets then show `–`
    /// instead of reading the extension's own, always-empty container.
    public static func sharedDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL? {
        guard let group = TodaySnapshot.appGroupID(bundleIdentifier: bundleIdentifier),
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else { return nil }
        return try? TodaySnapshot.defaultDirectory(bundleIdentifier: bundleIdentifier)
    }
}

/// Phone → Watch complication data (spec 21 §3, message `today` in §6). W-02's WatchConnectivity code calls these;
/// this file holds only the decisions and the payload format.
public enum ComplicationTransfer {
    public enum Channel: Equatable, Sendable {
        /// `transferCurrentComplicationUserInfo(_:)`, which wakes the complication but is budgeted per day.
        case complicationUserInfo
        /// Budget spent: ride along in the next `updateApplicationContext(_:)` (latest wins).
        case applicationContext
        /// No paired Watch with the app installed.
        case none
    }

    public static let key = "today"

    public static func channel(isPaired: Bool, isWatchAppInstalled: Bool, remainingComplicationTransfers: Int) -> Channel {
        guard isPaired, isWatchAppInstalled else { return .none }
        return remainingComplicationTransfers > 0 ? .complicationUserInfo : .applicationContext
    }

    /// `["today": <snapshot JSON>]`; property-list safe for userInfo and application context alike.
    public static func payload(_ snapshot: TodaySnapshot) -> [String: Any]? {
        guard let data = try? APICoding.encoder().encode(snapshot) else { return nil }
        return [key: data]
    }

    public static func snapshot(from payload: [String: Any]) -> TodaySnapshot? {
        guard let data = payload[key] as? Data else { return nil }
        return try? APICoding.decoder().decode(TodaySnapshot.self, from: data)
    }

    /// Watch side: store a received snapshot for the complication extension. Returns true when the file changed,
    /// so the caller reloads timelines only then (reloads are budgeted).
    @discardableResult
    public static func receive(_ payload: [String: Any], into directory: URL) -> Bool {
        guard let snapshot = snapshot(from: payload), snapshot != TodaySnapshot.read(from: directory) else { return false }
        return (try? snapshot.write(to: directory)) != nil
    }
}
