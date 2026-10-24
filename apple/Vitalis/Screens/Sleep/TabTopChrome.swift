import SwiftUI
import VitalisKit
import VitalisUI

/// StatusRow and PulseLine above the Sleep and Body headers (brief 03 shared tab frame).
struct TabTopChrome: View {
    let status: (label: String, tint: VTint)

    var body: some View {
        VStack(spacing: 0) {
            StatusRow(status.label, tint: status.tint).padding(.top, VSpace.statusTop)
            // Tabs other than Today aren't timelines: a flat line with only the now-dot (spec 30 → PulseLine).
            PulseLine(events: [], now: 0.64)
            .frame(height: PulseLine.Style.phone.height)
            .padding(.top, 14)
            .accessibilityHidden(true)
        }
    }

    /// Status label for a tab read: stale/offline via `StaleState`, else the refresh error, else `SYNCED HH:MM`.
    @MainActor static func status<V>(_ loadable: Loadable<V>, freshness: Freshness?, now: Date = Date()) -> (label: String, tint: VTint) {
        let refreshFailed = loadable.error != nil
        if loadable.value == nil {
            if let error = loadable.error { return ((error as? APIError)?.statusLine ?? "COULDN'T UPDATE", .steel) }
            return ("UPDATING", .steel)
        }
        let state = StaleState(lastSync: APIDate.parse(freshness?.lastSync), lastSuccess: nil, failure: nil,
                               cachedAt: loadable.fetchedAt, refreshFailed: refreshFailed, now: now)
        switch state.status {
        case .stale(let label, _, _): return (label, .watch)
        case .offline(let label): return (label, .steel)
        case .synced(let label):
            if let error = loadable.error as? APIError, case .transport = error { return (label, .steel) }
            return (loadable.error.map { ($0 as? APIError)?.statusLine ?? "COULDN'T UPDATE" } ?? label, .steel)
        }
    }
}

/// Display formatting shared by Sleep and Body; every number here arrives from the server.
enum SleepBodyFormat {
    static let dash = "–"

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f
    }

    /// `2026-10-24` → `SAT 24 OCT`.
    static func dayTitle(_ day: String) -> String {
        guard let d = formatter("yyyy-MM-dd").date(from: day) else { return day }
        return formatter("EEE d MMM").string(from: d).uppercased()
    }

    /// `2026-10-24` → `S` (weekday initial under week bars).
    static func letter(_ day: String) -> String {
        guard let d = formatter("yyyy-MM-dd").date(from: day) else { return "" }
        return String(formatter("EEEEE").string(from: d).prefix(1)).uppercased()
    }

    /// One decimal (`76.4`, `14.8`); whole numbers stay whole for vitals (`62`).
    static func kg(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? dash }

    static func signedKg(_ v: Double?) -> String {
        guard let v else { return dash }
        let text = String(format: "%.1f", abs(v))
        return v > 0.04 ? "+\(text)" : v < -0.04 ? "-\(text)" : text
    }

    static func vital(_ v: Double?) -> String {
        guard let v else { return dash }
        return v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    static func grouped(_ v: Int?) -> String {
        v.map { $0.formatted(.number.locale(Locale(identifier: "en_US"))) } ?? dash
    }

    /// Hours as the server's `7H41` style.
    static func hours(_ h: Double?) -> String {
        guard let h, h >= 0 else { return dash }
        var whole = Int(h), minutes = Int(((h - Double(whole)) * 60).rounded())
        if minutes == 60 { whole += 1; minutes = 0 }
        return String(format: "%dH%02d", whole, minutes)
    }
}
