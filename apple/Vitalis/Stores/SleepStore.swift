import Foundation
import Observation
import UserNotifications
import VitalisKit

/// Schedules the one bed-time reminder; injected so tests never touch UNUserNotificationCenter.
protocol BedReminding: Sendable {
    /// Asks permission (first use only shows the prompt) and schedules; false when notifications are denied.
    func schedule(at date: Date, title: String, body: String) async -> Bool
}

struct NotificationBedReminder: BedReminding {
    static let identifier = "vitalis.bed-reminder"

    func schedule(at date: Date, title: String, body: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        // Today's `bed_reminder` should reuse this id, so the two buttons replace rather than stack notifications.
        do { try await center.add(request); return true } catch { return false }
    }
}

/// Sleep tab (spec 20 §4 Sleep): one night by wake day, the week ending on that day, and the tonight reminder.
@MainActor @Observable
final class SleepStore {
    /// One per app: the tab is rebuilt on every switch, and its night, scroll target and toasts should survive that.
    static let shared = SleepStore()

    enum Reminder: Equatable { case idle, set, denied }

    private(set) var night = Loadable<SleepResponse>()
    /// `nil` = today (the server's default); otherwise the wake day being shown.
    private(set) var requestedDay: String?
    private(set) var weeks: [String: SleepWeekResponse] = [:]
    private(set) var weekError: Error?

    enum Range: String, CaseIterable { case night = "Night", week = "Week", month = "Month" }
    var range: Range = .night
    /// Last day of the week on show; nil follows the shown night.
    private(set) var weekEnd: String?
    /// `YYYY-MM` on show; nil = this month until the first answer names it.
    private(set) var monthKey: String?
    private(set) var months: [String: SleepMonthResponse] = [:]
    private(set) var monthError: Error?
    private(set) var reminder: Reminder = .idle

    private let api: @MainActor () -> VitalisAPI?
    private let reminders: any BedReminding
    private let now: () -> Date

    init(api: @escaping @MainActor () -> VitalisAPI? = { Services.shared.api },
         reminders: any BedReminding = NotificationBedReminder(), now: @escaping () -> Date = { Date() }) {
        self.api = api; self.reminders = reminders; self.now = now
    }

    var value: SleepResponse? { night.value }
    var canGoBack: Bool { value?.prevDay != nil }
    var canGoForward: Bool { value?.nextDay != nil }
    /// The week for the shown day, once fetched.
    var week: SleepWeekResponse? { value.flatMap { weeks[$0.day] } }
    /// The week the Week view steps through.
    var shownWeek: SleepWeekResponse? { (weekEnd ?? value?.day).flatMap { weeks[$0] } }
    var shownMonth: SleepMonthResponse? { monthKey.flatMap { months[$0] } }
    /// The latest week is the one ending on the latest night; later weeks don't exist yet.
    var canStepWeekForward: Bool { guard let end = weekEnd ?? value?.day, let latest = latestDay else { return false }; return end < latest }
    private var latestDay: String? { value?.nextDay == nil ? value?.day : nil ?? lastLatest }
    private var lastLatest: String?

    func select(_ r: Range) async {
        range = r
        switch r {
        case .night: return
        case .week:
            if weekEnd == nil { weekEnd = value?.day }
            if let end = weekEnd { await loadWeek(end: end, force: false) }
        case .month: await loadMonth(monthKey)
        }
    }

    func stepWeek(_ direction: Int) async {
        guard let end = weekEnd ?? value?.day, let next = Self.addDays(end, 7 * direction) else { return }
        if direction > 0, let latest = latestDay, next > latest { weekEnd = latest } else { weekEnd = next }
        await loadWeek(end: weekEnd!, force: false)
    }

    func stepMonth(_ direction: Int) async {
        guard let m = shownMonth, let target = direction < 0 ? m.prevMonth : m.nextMonth else { return }
        await loadMonth(target)
    }

    private func loadMonth(_ key: String?) async {
        if let key, months[key] != nil { monthKey = key; return }
        guard let api = api() else { return }
        do { let r = try await api.sleepMonth(month: key).value; months[r.month] = r; monthKey = r.month; monthError = nil }
        catch { monthError = error }
    }

    nonisolated static func addDays(_ day: String, _ n: Int) -> String? {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day), let out = f.calendar.date(byAdding: .day, value: n, to: d) else { return nil }
        return f.string(from: out)
    }

    /// Loads (or revalidates) the shown day; `force` also refetches its week.
    func load(force: Bool = false) async {
        guard let api = api() else { return }
        let day = requestedDay
        let query = VitalisAPI.query(["date": day])
        await night.load(cached: { await api.cached(SleepResponse.self, path: "v2/sleep", query: query) }) {
            try await api.sleep(date: day)
        }
        guard day == requestedDay, let shown = night.value?.day else { return }
        if night.value?.nextDay == nil { lastLatest = shown }
        await loadWeek(end: shown, force: force)
    }

    func back() async {
        guard let prev = value?.prevDay else { return }
        await show(day: prev)
    }

    /// No-op on the latest night (`next_day` is null).
    func forward() async {
        guard let next = value?.nextDay else { return }
        await show(day: next)
    }

    func show(day: String) async {
        requestedDay = day
        night = Loadable()
        await load()
    }

    /// Schedules a local notification 30 min before tonight's bed-by (design default).
    func remindMe() async {
        guard let tonight = value?.tonight, let bedBy = tonight.bedBy,
              let at = Self.reminderDate(bedBy: bedBy, now: now()) else { return }
        let ok = await reminders.schedule(at: at, title: "Bed by \(bedBy)", body: tonight.label?.capitalized ?? "Time to wind down.")
        reminder = ok ? .set : .denied
    }

    /// Tonight's `HH:MM` minus 30 min, rolled to tomorrow when that moment has passed. Nil when unparseable.
    nonisolated static func reminderDate(bedBy: String, now: Date, calendar: Calendar = .current) -> Date? {
        let parts = bedBy.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m),
              let bed = calendar.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
        let at = bed.addingTimeInterval(-30 * 60)
        return at > now ? at : calendar.date(byAdding: .day, value: 1, to: at)
    }

    /// Previews: show fixture bodies without an API.
    func preload(_ value: SleepResponse?, week: SleepWeekResponse? = nil) {
        if let value { night.set(value); if let week { weeks[value.day] = week } }
        
    }

    private func loadWeek(end: String, force: Bool) async {
        guard force || weeks[end] == nil, let api = api() else { return }
        do { weeks[end] = try await api.sleepWeek(end: end).value; weekError = nil }
        catch { weekError = error }
    }

}
