import Combine
import Foundation
import Observation
import UserNotifications
import VitalisKit
import VitalisUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What Today's primary action does, decided from `verdict.action.kind` alone (spec 20 §4 Today).
enum TodayIntent: Equatable, Sendable {
    case startWorkout
    case quickAdd(slot: String?)
    /// `bed_by − 30 min`; `bed_by` is `pulse.window.end` (10 §4).
    case bedReminder(fireAt: Date, bedBy: String)
    case none
}

/// The exporter's last upload outcome, reduced to what the stale rule needs.
struct ExporterState: Equatable, Sendable {
    var lastSuccess: Date?
    var lastError: String?

    init(lastSuccess: Date? = nil, lastError: String? = nil) { self.lastSuccess = lastSuccess; self.lastError = lastError }
    init(_ history: SyncHistory) { self.init(lastSuccess: history.lastSuccess, lastError: history.lastError) }

    /// The exporter records failures as text only; map the kinds the stale copy distinguishes. Unknown text → nil, so the
    /// copy falls back to "hasn't synced since", which is true whatever the cause.
    var failure: SyncFailure? {
        guard let text = lastError?.lowercased() else { return nil }
        if let range = text.range(of: #"http (\d{3})"#, options: .regularExpression),
           let code = Int(text[range].suffix(3)) {
            return code == 401 || code == 403 ? .unauthorized : .server(code)
        }
        if text.contains("token") { return .unauthorized }
        if text.contains("protected data") { return .protectedDataUnavailable }
        let transport = ["offline", "could not connect", "hostname", "timed out", "network connection", "not connected", "ssl", "secure connection"]
        return transport.contains { text.contains($0) } ? .unreachable : nil
    }
}

protocol ReminderScheduling: Sendable {
    /// Asks for notification permission on first use; false when denied or the request failed.
    func schedule(id: String, title: String, at date: Date) async -> Bool
}

struct NotificationReminders: ReminderScheduling {
    func schedule(id: String, title: String, at date: Date) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        return (try? await center.add(request)) != nil
    }
}

/// Today and the morning digest gate. One shared instance: RootView presents `DigestScreen` as a sibling of `TodayScreen`.
@MainActor @Observable
final class TodayStore {
    enum Phase: Equatable { case loading, loaded, cached, failed }

    static let shared = TodayStore()

    static let digestDismissedKey = "digestDismissedDay"
    static let rememberedStartKey = "rememberedStart"
    static let reminderDayKey = "bedReminderDay"

    let today: Loadable<TodayResponse>
    private(set) var exporter = ExporterState()
    /// No server configured (and not demo): show the connect line instead of loading forever.
    private(set) var notConfigured = false
    private(set) var reminderDay: String?
    /// Day the digest was auto-presented for; only that presentation's "Start my day" sets the flag.
    private(set) var autoDigestDay: String?

    @ObservationIgnored private let api: @MainActor () -> VitalisAPI?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let snapshotDirectory: (() -> URL?)?
    @ObservationIgnored private let reminders: ReminderScheduling
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var lastSnapshot: TodaySnapshot?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var exporterSubscription: AnyCancellable?
    /// Previews only: Loadable keeps `fetchedAt`/`error` private, so the cached and offline states are injected here.
    @ObservationIgnored private let previewFetchedAt: Date?
    @ObservationIgnored private let previewFailed: Bool

    init(api: @escaping @MainActor () -> VitalisAPI? = { Services.shared.api },
         defaults: UserDefaults = .standard,
         snapshotDirectory: (() -> URL?)? = { try? TodaySnapshot.defaultDirectory() },
         reminders: ReminderScheduling = NotificationReminders(),
         now: @escaping () -> Date = { Date() },
         preview: TodayResponse? = nil, previewFetchedAt: Date? = nil, previewFailed: Bool = false) {
        self.api = api
        self.defaults = defaults
        self.snapshotDirectory = snapshotDirectory
        self.reminders = reminders
        self.now = now
        self.previewFetchedAt = previewFetchedAt
        self.previewFailed = previewFailed
        today = Loadable(preview)
        reminderDay = defaults.string(forKey: Self.reminderDayKey)
    }

    private var refreshFailed: Bool { previewFailed || today.error != nil }

    var phase: Phase {
        if today.value == nil { return refreshFailed || notConfigured ? .failed : .loading }
        return refreshFailed ? .cached : .loaded
    }

    // MARK: Refresh

    /// Concurrent triggers (appear, foreground, outbox flush, sync) share one request.
    func refresh() async {
        if let inFlight { await inFlight.value; return }
        let task = Task { await self.load() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func load() async {
        guard let api = api() else { notConfigured = true; return }
        notConfigured = false
        await today.load(cached: { await api.cached(TodayResponse.self, path: "v2/today") }) { try await api.today() }
        if today.error == nil, let value = today.value { writeSnapshot(value) }
    }

    /// Runs per successful fetch (≤ every 15 min plus triggers); unchanged bodies (304s) skip the file write and the
    /// widget reload, which the system budgets.
    private func writeSnapshot(_ value: TodayResponse) {
        let snapshot = TodaySnapshot(value)
        guard snapshot != lastSnapshot, let directory = snapshotDirectory?() else { return }
        do { try snapshot.write(to: directory); lastSnapshot = snapshot } catch { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        WatchBridge.sendToday(snapshot)
    }

    /// Follows the exporter: its state feeds the stale rule, and a new successful upload refetches (spec 20 §4).
    func observeExporter(_ publisher: some Publisher<SyncSnapshot, Never>) {
        guard exporterSubscription == nil else { return }
        exporterSubscription = publisher.map { ExporterState($0.history) }.removeDuplicates()
            .sink { [weak self] state in MainActor.assumeIsolated { self?.updateExporter(state) } }
    }

    func updateExporter(_ state: ExporterState) {
        guard state != exporter else { return }
        let uploaded = state.lastSuccess != nil && state.lastSuccess != exporter.lastSuccess
        exporter = state
        if uploaded { Task { await refresh() } }
    }

    // MARK: Stale / status

    func status(now: Date) -> StaleState {
        Self.status(lastSync: today.value?.freshness?.lastSync, exporter: exporter, cachedAt: previewFetchedAt ?? today.fetchedAt,
                    refreshFailed: refreshFailed, now: now)
    }

    static func status(lastSync: String?, exporter: ExporterState, cachedAt: Date?, refreshFailed: Bool, now: Date) -> StaleState {
        StaleState(lastSync: APIDate.parse(lastSync), lastSuccess: exporter.lastSuccess, failure: exporter.failure,
                   cachedAt: cachedAt, refreshFailed: refreshFailed, now: now)
    }

    // MARK: Digest gate (spec 20 §4 Morning digest)

    static func shouldPresentDigest(_ today: TodayResponse?, dismissedDay: String?) -> Bool {
        guard let today, today.digest?.available == true else { return false }
        return dismissedDay != today.day
    }

    /// After a foreground refresh: present once per day, never from a stale cached body, never over another sheet.
    func presentDigestIfDue(router: Router) {
        guard today.error == nil, let day = today.value?.day,
              Self.shouldPresentDigest(today.value, dismissedDay: defaults.string(forKey: Self.digestDismissedKey)),
              !router.showsDigest, router.sheet == nil, !router.showsSettings, !router.showsLiveWorkout,
              !router.openedByLink(now: now()) else { return }
        autoDigestDay = day
        router.showsDigest = true
    }

    /// "Start my day". A reopen from the date label or a deep link leaves the flag alone.
    func finishDigest() {
        guard let day = autoDigestDay else { return }
        defaults.set(day, forKey: Self.digestDismissedKey)
        autoDigestDay = nil
    }

    // MARK: Primary action

    static func intent(for action: TodayResponse.Action?, nextSlot: String?, bedBy: String?) -> TodayIntent {
        switch action?.kind {
        case "start_workout": return .startWorkout
        case "log_meal": return .quickAdd(slot: nextSlot)
        case "bed_reminder":
            guard let bedBy, let bed = APIDate.parse(bedBy) else { return .none }
            return .bedReminder(fireAt: bed.addingTimeInterval(-30 * 60), bedBy: bedBy)
        default: return .none
        }
    }

    var intent: TodayIntent {
        guard let t = today.value else { return .none }
        return Self.intent(for: t.verdict.action, nextSlot: t.fuel.nextSlot, bedBy: t.pulse?.window.end)
    }

    /// The only client-side text change on Today: `on Watch` → `on iPhone` when the start sheet remembered the phone.
    static func actionLabel(_ action: TodayResponse.Action?, rememberedStart: String?) -> String? {
        guard let action else { return nil }
        guard action.kind == "start_workout", rememberedStart == "phone" else { return action.label }
        return action.label.replacingOccurrences(of: "on Watch", with: "on iPhone", options: .caseInsensitive)
    }

    var actionLabel: String? {
        guard let t = today.value else { return nil }
        if t.verdict.action?.kind == "bed_reminder", reminderDay == t.day { return "Reminder set" }
        return Self.actionLabel(t.verdict.action, rememberedStart: defaults.string(forKey: Self.rememberedStartKey))
    }

    /// Secondary start on the empty-training block (brief 01 States); Watch or iPhone is chosen in the start sheet.
    var startLabel: String { "Start workout" }

    /// Navigation intents go to the router; the reminder is scheduled here.
    func apply(_ intent: TodayIntent, router: Router) {
        switch intent {
        case .startWorkout: router.open(.workoutStart)
        case .quickAdd(let slot): router.sheet = .quickAdd(slot: slot)
        case .bedReminder(let fireAt, let bedBy): Task { await scheduleReminder(fireAt: fireAt, bedBy: bedBy) }
        case .none: break
        }
    }

    func scheduleReminder(fireAt: Date, bedBy: String) async {
        guard let day = today.value?.day, reminderDay != day else { return }
        // Past the wind-down time already: remind in a minute rather than never.
        let at = max(fireAt, now().addingTimeInterval(60))
        let title = APIDate.clockText(bedBy).map { "Bed by \($0)" } ?? "Bed time"
        guard await reminders.schedule(id: "vitalis.bed-reminder", title: title, at: at) else { return }
        reminderDay = day
        defaults.set(day, forKey: Self.reminderDayKey)
    }
}

/// Formatting only: grouping, uppercase words for server enums, date labels. No values are derived here.
enum TodayFormat {
    private static let grouping = Locale(identifier: "en_US")

    static func number(_ v: Int?) -> String? { v.map { $0.formatted(.number.grouping(.automatic).locale(grouping)) } }
    static func number(_ v: Double?) -> String? { v.map { Int($0.rounded()).formatted(.number.grouping(.automatic).locale(grouping)) } }

    /// `activity.*_pace` → `AHEAD` / `BEHIND` / `ON PACE`; nothing for `early` / `unknown`.
    static func pace(_ raw: String?) -> String? {
        switch raw {
        case "ahead": "AHEAD"
        case "behind": "BEHIND"
        case "on_pace": "ON PACE"
        default: nil
        }
    }

    private static let dayParse = Date.ISO8601FormatStyle().year().month().day()
    private static let dayStyle = Date.VerbatimFormatStyle(format: "\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated)",
                                                           locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt, calendar: Calendar(identifier: .gregorian))

    /// `2026-10-24` → `SAT 24 OCT`. Runs per body evaluation, so the styles are built once.
    static func dateLabel(day: String?) -> String? {
        guard let day, let date = try? Date(day, strategy: dayParse) else { return nil }
        return date.formatted(dayStyle).uppercased()
    }

    static func arrow(_ raw: String?) -> VArrow? { raw.flatMap(VArrow.init(rawValue:)) }

    static func arrowGlyph(_ raw: String?) -> String? {
        switch raw { case "up": "↑"; case "down": "↓"; default: nil }
    }

    /// Band words → tint: ready/steady read as good, ease/rest as watch.
    static func bandTint(_ band: String?) -> VTint {
        switch band {
        case "ready", "steady", "good": .good
        case "ease", "rest", "watch", "poor": .watch
        default: .steel
        }
    }
}
