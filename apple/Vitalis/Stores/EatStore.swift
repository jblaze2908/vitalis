import Foundation
import Observation
import VitalisKit

/// Where Eat's writes go: the app's durable Outbox via `Services`, or a test outbox.
@MainActor
protocol FoodWriteQueue: AnyObject {
    @discardableResult func send(_ request: APIRequest) async -> UUID?
    func drop(_ id: UUID) async -> Bool
    func pendingItems() async -> [Outbox.Item]
}

extension Services: FoodWriteQueue {
    func pendingItems() async -> [Outbox.Item] { await outbox?.pendingItems ?? [] }
}

/// One food item about to be logged, before it gets ids and a time.
struct FoodDraft: Sendable, Equatable {
    var name: String
    var portionText: String?
    var grams: Double?
    var kcal: Double
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
}

/// Which part of the add flow the Quick add sheet should open in (set by Eat's quick-action tiles).
enum FoodAddMode: Equatable {
    case home
    case search(text: String)
    case describe(text: String, barcode: String?)
}

/// Eat tab state plus every food add and Undo (spec 20 §4 Eat, §5.3, §8).
@MainActor @Observable
final class EatStore {
    struct Toast: Equatable {
        let mealID: String
        let text: String
        /// Set when the toast follows a delete: Undo posts this entry back under its id (the server revives it).
        var restore: FoodDayEntry? = nil
    }

    /// An entry still in the outbox, shown under its meal with `WAITING TO SYNC`.
    struct PendingEntry: Equatable, Identifiable {
        let entry: FoodEntry
        let day: String
        var id: String { entry.id }
    }

    /// The app's store, shared by Eat and the Quick add sheet so the toast lands on Eat after the sheet closes.
    static let shared = EatStore(api: { Services.shared.api }, queue: Services.shared,
                                 health: HealthWriter(store: AppModel.shared.healthStore))

    let day = Loadable<FoodDay>()
    let quick = Loadable<FoodQuick>()
    private(set) var date: String?
    private(set) var pending: [PendingEntry] = []
    /// Meals whose Undo DELETE hasn't reached the server; hidden until it has.
    private(set) var deleting: Set<String> = []
    /// Single entries deleted from Eat, hidden until the server's day stops listing them.
    private(set) var deletedEntries: Set<String> = []
    private(set) var toast: Toast?
    /// Saved-meal changes still in the outbox, by id (nil = deleted); applied over the server's list until it shows them.
    private(set) var savedEdits: [String: SavedMealInfo?] = [:]
    private(set) var todayPulse: Pulse?
    private(set) var healthError: String?
    /// False after a 503 from describe: the tile hides everywhere for this launch.
    var describeAvailable = true
    var requestedMode: FoodAddMode?

    private let api: @MainActor () -> VitalisAPI?
    private let queue: FoodWriteQueue
    private let health: HealthWriting
    private let now: () -> Date
    private let calendar: Calendar
    private let recheckAfter: Duration?
    private let toastDuration: Duration
    /// Undo state per add; HealthKit UUIDs only matter inside the toast window, so memory is enough.
    private var adds: [String: (outboxID: UUID?, healthUUIDs: [UUID])] = [:]
    private var toastTask: Task<Void, Never>?

    init(api: @escaping @MainActor () -> VitalisAPI?, queue: FoodWriteQueue, health: HealthWriting,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         recheckAfter: Duration? = .milliseconds(1500), toastDuration: Duration = .seconds(5)) {
        self.api = api; self.queue = queue; self.health = health; self.now = now; self.calendar = calendar
        self.recheckAfter = recheckAfter; self.toastDuration = toastDuration
    }

    // MARK: Reads

    func load() async {
        // Previews (and a phone without a server) keep whatever is shown instead of flagging an error.
        if api() == nil, day.value != nil { return }
        let date = self.date
        await day.load(cached: { await self.api()?.cached(FoodDay.self, path: "v2/food/day", query: VitalisAPI.query(["date": date])) }) {
            guard let api = self.api() else { throw APIError.transport(URLError(.notConnectedToInternet)) }
            return try await api.foodDay(date: date)
        }
        await refreshPending()
        if todayPulse == nil { todayPulse = await api()?.cached(TodayResponse.self, path: "v2/today")?.value.pulse }
    }

    func loadQuick(slot: String?) async {
        await quick.load(cached: { await self.api()?.cached(FoodQuick.self, path: "v2/food/quick", query: VitalisAPI.query(["slot": slot])) }) {
            guard let api = self.api() else { throw APIError.transport(URLError(.notConnectedToInternet)) }
            return try await api.foodQuick(slot: slot)
        }
        // Drop edits the server now reflects.
        guard quick.error == nil, let server = quick.value?.saved else { return }
        for (id, edit) in savedEdits {
            let row = server.first { $0.id == id }
            if (edit == nil && row == nil) || (edit != nil && row?.name == edit?.name && row?.kcal == edit?.kcal) { savedEdits[id] = nil }
        }
    }

    /// Pull to refresh and each return to the foreground: the day on screen and Quick add's lists.
    func refresh() async {
        await load()
        await loadQuick(slot: nil)
    }

    func goBack() async { guard let prev = day.value?.prevDay else { return }; date = prev; await load() }
    func goForward() async { guard let next = day.value?.nextDay else { return }; date = next; await load() }

    /// After a flush delivered something (`Services.writesVersion`): pending rows that left the outbox are now server rows.
    func writesDelivered() async {
        await refreshPending()
        await load()
        if !savedEdits.isEmpty { await loadQuick(slot: nil) }
    }

    // MARK: Adds

    /// The slot an add goes to when none was picked: the server's `next_slot`, else the time-of-day windows of brief 03.
    var defaultSlot: String {
        day.value?.nextSlot ?? slotNow
    }

    func logUsual() async {
        guard let usual = day.value?.usualNext else { return }
        await log(usual.items.map(FoodDraft.init), slot: day.value?.nextSlot ?? defaultSlot, source: "usual")
    }

    /// Every add: client UUIDs and one meal_id, HealthKit first (never blocking), then the outbox, then the toast.
    func log(_ drafts: [FoodDraft], slot: String, source: String, sourceRef: String? = nil, estimate: Bool? = nil) async {
        guard !drafts.isEmpty else { return }
        let mealID = UUID().uuidString.lowercased()
        let eatenAt = eatenAt(slot: slot)
        var entries = drafts.map {
            FoodEntry(id: UUID().uuidString.lowercased(), mealId: mealID, slot: slot, eatenAt: Self.iso(eatenAt, calendar: calendar),
                      name: $0.name, portionText: $0.portionText, grams: $0.grams, kcal: $0.kcal, proteinG: $0.proteinG,
                      carbsG: $0.carbsG, fatG: $0.fatG, source: source, sourceRef: sourceRef, estimate: estimate)
        }
        var healthUUIDs: [UUID] = []
        do {
            healthUUIDs = try await health.saveFood(entries.map {
                FoodItemSample(entryID: $0.id, name: $0.name, eatenAt: eatenAt, kcal: $0.kcal, proteinG: $0.proteinG, carbsG: $0.carbsG, fatG: $0.fatG)
            })
            healthError = nil
        } catch { healthError = String(describing: type(of: error)) }
        for i in entries.indices where i < healthUUIDs.count { entries[i].hkUuid = healthUUIDs[i].uuidString }

        guard let request = try? APIRequest.postFoodEntries(entries), let outboxID = await queue.send(request) else {
            try? await health.delete(uuids: healthUUIDs)
            return
        }
        adds[mealID] = (outboxID, healthUUIDs)
        showToast(Toast(mealID: mealID, text: "ADDED TO \(Self.slotName(slot).uppercased()) · \(FoodFormat.kcal(entries.reduce(0) { $0 + $1.kcal })) KCAL"))
        await settle()
    }

    // MARK: Saved meals

    /// The server's saved meals with this launch's unsent edits on top, by name.
    var savedMeals: [SavedMealInfo] {
        var byID = Dictionary((quick.value?.saved ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, edit) in savedEdits { byID[id] = edit }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Create or replace a saved meal (same id = edit). Goes through the outbox, so it survives being offline.
    func saveMeal(id: String = UUID().uuidString.lowercased(), name: String, items: [SavedMeal.Item]) async {
        guard let request = try? APIRequest.postSavedMeal(SavedMeal(id: id, name: name, items: items)) else { return }
        savedEdits[id] = SavedMealInfo(id: id, name: name, slot: nil, kcal: items.reduce(0) { $0 + $1.kcal }.rounded(),
                                       items: items.map { FoodItem(name: $0.name, portionText: $0.portionText, grams: $0.grams, kcal: $0.kcal,
                                                                   proteinG: $0.proteinG, carbsG: $0.carbsG, fatG: $0.fatG) })
        await queue.send(request)
        VitalisShortcuts.updateAppShortcutParameters()
    }

    func deleteSavedMeal(_ id: String) async {
        savedEdits[id] = .some(nil)
        await queue.send(.deleteSavedMeal(id: id))
        VitalisShortcuts.updateAppShortcutParameters()
    }

    /// One tap: every item of the saved meal, eaten now, so into the meal window it's now (a shake at 09:00 is breakfast
    /// even when breakfast is already logged). On a past day on screen it goes to that day's next meal.
    func logSaved(_ meal: SavedMealInfo, slot: String? = nil) async {
        let viewingToday = day.value.map { $0.nextDay == nil } ?? true
        await log(meal.items.map(FoodDraft.init), slot: slot ?? (viewingToday ? slotNow : day.value?.nextSlot ?? defaultSlot), source: "saved", sourceRef: meal.id)
        VitalisShortcuts.updateAppShortcutParameters()
    }

    /// The meal window the clock is in: breakfast 04:00–10:29, lunch to 14:59, snack to 17:59, dinner after (the server's windows).
    var slotNow: String {
        let h = calendar.component(.hour, from: now()), m = calendar.component(.minute, from: now())
        switch h * 60 + m {
        case 240..<630: return "breakfast"
        case 630..<900: return "lunch"
        case 900..<1080: return "snack"
        default: return "dinner"
        }
    }

    /// Queues the owner's numbers for an unknown barcode so the next scan finds them.
    func rememberBarcode(_ code: String, item: BarcodeItem) async {
        guard let request = try? APIRequest.putBarcode(code: code, item: item) else { return }
        await queue.send(request)
    }

    // MARK: Edit and delete

    /// A changed amount, meal or time: the entry is re-posted under its id (the server updates it) and its Health sample
    /// is replaced, since a HealthKit sample can't be edited. `factor` scales calories and macros from the logged numbers.
    func update(_ e: FoodDayEntry, factor: Double, grams: Double?, portion: String?, slot: String, eatenAt: String?) async {
        await repost(e, kcalFactor: factor, grams: grams, portion: portion, slot: slot, eatenAt: eatenAt)
    }

    func delete(_ e: FoodDayEntry) async {
        deletedEntries.insert(e.id)
        await queue.send(.deleteFoodEntry(id: e.id))
        if let id = e.hkUuid.flatMap(UUID.init(uuidString:)) { try? await health.delete(uuids: [id]) }
        showToast(Toast(mealID: e.mealId, text: "REMOVED \(e.name.uppercased())", restore: e))
        await settle()
    }

    private func repost(_ e: FoodDayEntry, kcalFactor f: Double, grams: Double?, portion: String?, slot: String, eatenAt: String?) async {
        let at = eatenAt ?? Self.iso(self.eatenAt(slot: slot), calendar: calendar)
        let scale = { (v: Double?) in v.map { ($0 * f * 10).rounded() / 10 } }
        var entry = FoodEntry(id: e.id, mealId: e.mealId, slot: slot, eatenAt: at, name: e.name, portionText: portion, grams: grams,
                              kcal: (e.kcal * f).rounded(), proteinG: scale(e.proteinG), carbsG: scale(e.carbsG), fatG: scale(e.fatG),
                              source: e.source, sourceRef: e.sourceRef, estimate: e.estimate)
        if let old = e.hkUuid.flatMap(UUID.init(uuidString:)) { try? await health.delete(uuids: [old]) }
        if let date = APIDate.parse(at),
           let ids = try? await health.saveFood([FoodItemSample(entryID: e.id, name: e.name, eatenAt: date, kcal: entry.kcal,
                                                                proteinG: entry.proteinG, carbsG: entry.carbsG, fatG: entry.fatG)]) {
            entry.hkUuid = ids.first?.uuidString
        }
        guard let request = try? APIRequest.postFoodEntries([entry]) else { return }
        await queue.send(request)
        await settle()
    }

    // MARK: Undo

    func undo() async {
        guard let toast else { return }
        dismissToast()
        if let e = toast.restore {
            deletedEntries.remove(e.id)
            await repost(e, kcalFactor: 1, grams: e.grams, portion: e.portionText, slot: e.slot ?? defaultSlot, eatenAt: e.eatenAt)
            return
        }
        let record = adds.removeValue(forKey: toast.mealID)
        if let id = record?.outboxID, await queue.drop(id) {
            await refreshPending()
        } else {
            deleting.insert(toast.mealID)
            await queue.send(.deleteMeal(mealId: toast.mealID))
            await settle()
        }
        try? await health.delete(uuids: record?.healthUUIDs ?? [])
    }

    func dismissToast() {
        toastTask?.cancel(); toastTask = nil
        toast = nil
    }

    // MARK: View helpers

    /// Server meals, without slots whose every entry is being undone.
    var meals: [FoodDay.Meal] { (day.value?.meals ?? []).filter { !entries($0).isEmpty } }

    /// A meal's entries minus adds whose Undo hasn't reached the server (a slot can hold several adds).
    func entries(_ meal: FoodDay.Meal) -> [FoodDayEntry] {
        meal.entries.filter { !deleting.contains($0.mealId) && !deletedEntries.contains($0.id) }
    }

    /// Unsent entries for the day on screen, by slot.
    func pendingEntries(slot: String) -> [FoodEntry] {
        guard let shown = day.value?.day else { return [] }
        return pending.filter { $0.day == shown && $0.entry.slot == slot }.map(\.entry)
    }

    nonisolated static func slotName(_ slot: String) -> String { slot == "snack" ? "snacks" : slot }

    #if DEBUG
    func previewToast(_ text: String) { toast = Toast(mealID: "preview", text: text) }
    func previewPending(_ entries: [FoodEntry]) { pending = entries.map { PendingEntry(entry: $0, day: String($0.eatenAt.prefix(10))) } }
    #endif

    // MARK: Private

    private func showToast(_ t: Toast) {
        toastTask?.cancel()
        toast = t
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self?.toast == t else { return }
            self?.toast = nil
        }
    }

    /// Delivered → refetch the day (the server marks the meal `just_added`); still queued → show it as waiting.
    /// Recheck once shortly after, since `Outbox.enqueue` starts its own flush that may still hold the item.
    private func settle() async {
        let before = pending.count
        await refreshPending()
        await load()
        guard let delay = recheckAfter, pending.count > 0 || before > 0 || !deleting.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.writesDelivered()
        }
    }

    /// Rebuilt from the outbox file itself, so waiting rows survive a relaunch.
    private func refreshPending() async {
        let items = await queue.pendingItems()
        var entries: [PendingEntry] = []
        var deletes: Set<String> = []
        for item in items {
            if item.method == "POST", item.path == "v2/food/entries", let body = item.body,
               let request = try? APICoding.decoder().decode(FoodEntriesRequest.self, from: Data(body.utf8)) {
                entries += request.entries.map { PendingEntry(entry: $0, day: String($0.eatenAt.prefix(10))) }
            } else if item.method == "DELETE", item.path.hasPrefix("v2/food/meals/") {
                deletes.insert(String(item.path.dropFirst("v2/food/meals/".count)).removingPercentEncoding ?? "")
            }
        }
        pending = entries.filter { !deletes.contains($0.entry.mealId) }
        // Keep hiding an undone meal until the refetched day no longer has it.
        let shown = Set((day.value?.meals ?? []).flatMap { $0.entries.map(\.mealId) })
        deleting = deletes.union(deleting.intersection(shown))
    }

    /// Now on today; on another day, a fixed time inside the slot's window (design default: 08:00, 13:00, 16:30, 20:00).
    private func eatenAt(slot: String) -> Date {
        guard let shown = day.value?.day, shown != Self.dayString(now(), calendar: calendar),
              let start = Self.date(shown, calendar: calendar) else { return now() }
        let (h, m) = switch slot {
        case "breakfast": (8, 0)
        case "lunch": (13, 0)
        case "snack": (16, 30)
        default: (20, 0)
        }
        return calendar.date(bySettingHour: h, minute: m, second: 0, of: start) ?? start
    }

    /// ISO 8601 with the device's offset, so the server files the entry on the owner's local day.
    nonisolated static func iso(_ date: Date, calendar: Calendar) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }

    nonisolated static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    nonisolated static func date(_ day: String, calendar: Calendar) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

extension FoodDraft {
    init(_ item: FoodItem) {
        self.init(name: item.name, portionText: item.portionText, grams: item.grams, kcal: item.kcal,
                  proteinG: item.proteinG, carbsG: item.carbsG, fatG: item.fatG)
    }
    init(_ recent: FoodQuick.Recent) {
        self.init(name: recent.name, portionText: recent.portionText, grams: recent.grams, kcal: recent.kcal,
                  proteinG: recent.proteinG, carbsG: recent.carbsG, fatG: recent.fatG)
    }
    init(name: String, serving: Serving) {
        self.init(name: name, portionText: serving.label, grams: serving.grams, kcal: serving.kcal,
                  proteinG: serving.proteinG, carbsG: serving.carbsG, fatG: serving.fatG)
    }
}

/// Display formatting only (grouping, rounding for display, `–` for missing).
enum FoodFormat {
    static let dash = "–"
    static func kcal(_ v: Double?) -> String {
        guard let v else { return dash }
        return Int(v.rounded()).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
    static func grams(_ v: Double?) -> String {
        guard let v else { return dash }
        return v < 10 && v != v.rounded() ? String(format: "%.1f", v) : kcal(v)
    }
}
