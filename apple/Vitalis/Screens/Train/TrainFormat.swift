import Foundation

/// Display formatting for training values (grouping, units, day labels). Never derives a value.
enum TrainFormat {
    static let dash = "–"

    /// `82.5`, `100`; `empty` when missing.
    static func kg(_ value: Double?, empty: String = dash) -> String {
        guard let value else { return empty }
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US")))
    }

    /// `82.5 x 6` as the frames print a set; nil when both parts are missing.
    static func set(_ weight: Double?, _ reps: Int?) -> String? {
        switch (weight, reps) {
        case (nil, nil): nil
        case (let w?, let r?): "\(kg(w)) x \(r)"
        case (nil, let r?): "\(r) reps"
        case (let w?, nil): "\(kg(w)) kg"
        }
    }

    /// Server set text (`82.5 kg × 6`) in the frames' mono style (`82.5 x 6`).
    static func serverSet(_ text: String?) -> String? {
        text.map { $0.replacingOccurrences(of: " kg × ", with: " x ").replacingOccurrences(of: "×", with: "x") }
    }

    static func grouped(_ value: Double?) -> String {
        guard let value else { return dash }
        return Int(value.rounded()).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    static func int(_ value: Int?) -> String { value.map(String.init) ?? dash }

    /// Server days are local `YYYY-MM-DD`; parse and print in UTC so the device zone never shifts them.
    static func day(_ text: String?) -> Date? {
        guard let text else { return nil }
        return formatter("yyyy-MM-dd").date(from: text)
    }

    static func dayText(_ date: Date, _ format: String) -> String { formatter(format).string(from: date).uppercased() }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = format
        return f
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// `22:41`, or `1:02:41` past an hour.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let mmss = String(format: "%02d:%02d", (s / 60) % 60, s % 60)
        return s >= 3600 ? "\(s / 3600):\(mmss)" : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
