import Foundation

/// Why the exporter's last upload failed, as the Sync screen records it.
enum SyncFailure: Equatable, Sendable {
    case unauthorized
    case unreachable
    case server(Int)
    case protectedDataUnavailable
}

/// Today's freshness banner (spec 20 §6): stale when the server's `last_sync` is older than 12 h, or the exporter's
/// last upload failed and its last success is older than 12 h. Pure: every input, including now, is a parameter.
struct StaleState: Equatable, Sendable {
    static let threshold: TimeInterval = 12 * 3600
    static let offlineAfter: TimeInterval = 15 * 60

    enum Status: Equatable, Sendable {
        case synced(label: String)
        /// Cached body older than 15 min whose refresh failed.
        case offline(label: String)
        case stale(statusLabel: String, sectionLabel: String, cause: String)
    }

    let status: Status
    static let body = "Everything is safe on this phone until it's fixed."

    /// - Parameters:
    ///   - lastSync: the server's `freshness.last_sync`.
    ///   - lastSuccess: the exporter's last successful upload on this phone.
    ///   - failure: the exporter's last failure, if its latest attempt failed.
    ///   - cachedAt: when the shown body was fetched; `refreshFailed` when the latest refetch didn't succeed.
    init(lastSync: Date?, lastSuccess: Date?, failure: SyncFailure?, cachedAt: Date?, refreshFailed: Bool, now: Date, calendar: Calendar = .current) {
        let newest = [lastSync, lastSuccess].compactMap { $0 }.max()
        let serverStale = lastSync.map { now.timeIntervalSince($0) > Self.threshold } ?? true
        let failedStale = failure != nil && (lastSuccess.map { now.timeIntervalSince($0) > Self.threshold } ?? true)
        if (lastSync != nil || failure != nil) && (serverStale || failedStale) {
            let day = newest.map { Self.dayLabel($0, now: now, calendar: calendar) }
            status = .stale(statusLabel: day.map { "LAST SYNC \($0)" } ?? "NOT SYNCED",
                            sectionLabel: day.map { "NOT SYNCED SINCE \($0)" } ?? "NOT SYNCED YET",
                            cause: Self.cause(failure, since: day))
        } else if refreshFailed, let cachedAt, now.timeIntervalSince(cachedAt) > Self.offlineAfter {
            status = .offline(label: "OFFLINE · UPDATED \(Self.clock(cachedAt, calendar: calendar))")
        } else {
            status = .synced(label: lastSync.map { "SYNCED \(Self.clock($0, calendar: calendar))" } ?? "NOT SYNCED YET")
        }
    }

    var isStale: Bool { if case .stale = status { true } else { false } }

    static func cause(_ failure: SyncFailure?, since day: String?) -> String {
        switch failure {
        case .unauthorized: "Your server stopped accepting uploads."
        case .unreachable: "Your phone can't reach your server."
        case .server: "Your server is having trouble."
        case .protectedDataUnavailable: "Unlock your phone to sync."
        case nil: "Your phone hasn't synced since \(day?.capitalized ?? "setup")."
        }
    }

    /// TODAY / YESTERDAY / weekday within a week / "12 OCT" beyond.
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "YESTERDAY" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = days < 7 ? "EEE" : "d MMM"
        return f.string(from: date).uppercased()
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
