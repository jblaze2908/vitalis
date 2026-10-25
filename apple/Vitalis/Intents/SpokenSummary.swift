import Foundation
import VitalisKit

/// Siri's spoken answers, built only from server fields so the voice matches the screens. Pure, for tests.
enum SpokenSummary {
    static func sleep(_ r: SleepResponse?) -> String {
        guard let r else { return "No sleep data yet. Open Vitalis to sync." }
        let asleep = r.night?.asleepH.map(duration)
        guard r.hasNight, let score = r.score else {
            if r.hasNight, let asleep { return "No sleep score yet. \(asleep) asleep." }
            return "No sleep recorded for last night."
        }
        var text = "Sleep score \(score)" + (r.band.map { ", \($0)." } ?? ".")
        if let asleep {
            text += " \(asleep) asleep"
            text += r.duration?.needH.map { ", need \(duration(hours: $0))." } ?? "."
        }
        return text
    }

    static func recovery(_ r: TodayResponse?) -> String {
        guard let r else { return "No recovery data yet. Open Vitalis to sync." }
        let headline = sentence(r.verdict.headline)
        guard let score = r.recovery.score else {
            let reason = r.recovery.reason.map { ": " + lowercasedFirst(sentence($0)) } ?? "."
            return "No recovery score yet" + reason + (headline.map { " \($0)" } ?? "")
        }
        let band = (r.recovery.band ?? r.verdict.band).map { ", \($0)." } ?? "."
        return "Recovery \(score)" + band + (headline.map { " \($0)" } ?? "")
    }

    static func weightLogged(kg: Double, waitingToSync: Bool, healthFailed: Bool) -> String {
        var text = "Logged \(String(format: "%.1f", kg)) kilograms."
        if healthFailed { text += " Apple Health didn't save it." }
        if waitingToSync { text += " It'll sync when your server is reachable." }
        return text
    }

    /// 6.47 → "6 hours 28"; whole hours drop the minutes, under an hour drops the hours.
    static func duration(hours: Double) -> String {
        let total = max(0, Int((hours * 60).rounded()))
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m) minute\(m == 1 ? "" : "s")" }
        let hourText = "\(h) hour\(h == 1 ? "" : "s")"
        return m == 0 ? hourText : "\(hourText) \(m)"
    }

    /// Headlines can carry a line break (two condensed lines on screen) and no full stop.
    private static func sentence(_ raw: String) -> String? {
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let last = text.last else { return nil }
        return ".!?".contains(last) ? text : text + "."
    }

    private static func lowercasedFirst(_ s: String?) -> String {
        guard let s, let first = s.first else { return "" }
        return first.lowercased() + s.dropFirst()
    }
}
