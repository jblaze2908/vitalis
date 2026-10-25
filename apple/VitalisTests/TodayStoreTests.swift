import Foundation
import Testing
import VitalisKit
@testable import Vitalis

private actor FakeReminders: ReminderScheduling {
    private(set) var scheduled: [(id: String, title: String, at: Date)] = []
    let grant: Bool
    init(grant: Bool = true) { self.grant = grant }
    func schedule(id: String, title: String, at date: Date) async -> Bool {
        guard grant else { return false }
        scheduled.append((id, title, date))
        return true
    }
}

@MainActor @Suite struct TodayStoreTests {
    let suite = "today-tests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    let fixture: TodayResponse = try! Fixture.decode(TodayResponse.self, "today")
    // 24 Oct 2026 09:41 +05:30.
    let now = APIDate.parse("2026-10-24T09:41:00+05:30")!

    func makeStore(_ today: TodayResponse? = nil, api: VitalisAPI? = nil, snapshotDirectory: URL? = nil,
                   reminders: ReminderScheduling = FakeReminders()) -> TodayStore {
        TodayStore(api: { api }, defaults: defaults, snapshotDirectory: { snapshotDirectory }, reminders: reminders,
                   now: { [now] in now }, preview: today)
    }

    func action(_ kind: String, _ label: String) throws -> TodayResponse.Action {
        try APICoding.decoder().decode(TodayResponse.Action.self, from: Data(#"{"kind": "\#(kind)", "label": "\#(label)"}"#.utf8))
    }

    // MARK: Digest

    @Test func digestGateIsPureOnAvailabilityAndDay() {
        #expect(TodayStore.shouldPresentDigest(fixture, dismissedDay: nil))
        #expect(TodayStore.shouldPresentDigest(fixture, dismissedDay: "2026-10-23"))
        #expect(!TodayStore.shouldPresentDigest(fixture, dismissedDay: fixture.day))
        #expect(!TodayStore.shouldPresentDigest(nil, dismissedDay: nil))
    }

    @Test func digestUnavailableNeverShows() throws {
        let data = try Fixture.data("today")
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["digest"] = ["available": false]
        let unavailable = try APICoding.decoder().decode(TodayResponse.self, from: JSONSerialization.data(withJSONObject: object))
        object["digest"] = NSNull()
        let missing = try APICoding.decoder().decode(TodayResponse.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!TodayStore.shouldPresentDigest(unavailable, dismissedDay: nil))
        #expect(!TodayStore.shouldPresentDigest(missing, dismissedDay: nil))
    }

    @Test func digestShowsOncePerDayAcrossRelaunch() {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let router = Router()
        let store = makeStore(fixture)
        store.presentDigestIfDue(router: router)
        #expect(router.showsDigest)

        store.finishDigest()   // "Start my day"
        router.showsDigest = false
        #expect(defaults.string(forKey: TodayStore.digestDismissedKey) == fixture.day)

        store.presentDigestIfDue(router: router)
        #expect(!router.showsDigest)
        // Relaunch the same day: a fresh store reads the persisted flag.
        makeStore(fixture).presentDigestIfDue(router: router)
        #expect(!router.showsDigest)
    }

    @Test func reopeningFromTheDateLabelLeavesTheFlagAlone() {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let router = Router()
        let store = makeStore(fixture)
        router.showsDigest = true   // date label tap
        store.finishDigest()
        #expect(defaults.string(forKey: TodayStore.digestDismissedKey) == nil)
        router.showsDigest = false
        store.presentDigestIfDue(router: router)
        #expect(router.showsDigest)
    }

    @Test func aLinkWinsOverTheMorningDigest() throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let router = Router()
        router.open(try #require(URL(string: "vitalis://train")), at: now)
        makeStore(fixture).presentDigestIfDue(router: router)
        #expect(router.tab == .train && !router.showsDigest)
        #expect(!router.openedByLink(now: now.addingTimeInterval(11)), "the digest can show on a later foreground")
    }

    @Test func digestWaitsWhileAnotherSheetIsUp() {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let router = Router()
        router.sheet = .quickAdd(slot: "lunch")
        makeStore(fixture).presentDigestIfDue(router: router)
        #expect(!router.showsDigest)
    }

    // MARK: Action routing

    @Test func intentPerActionKind() throws {
        #expect(TodayStore.intent(for: try action("start_workout", "Start legs on Watch"), nextSlot: "lunch", bedBy: nil) == .startWorkout)
        #expect(TodayStore.intent(for: try action("log_meal", "Log lunch"), nextSlot: "lunch", bedBy: nil) == .quickAdd(slot: "lunch"))
        let bed = "2026-10-24T23:00:00+05:30"
        #expect(TodayStore.intent(for: try action("bed_reminder", "Remind me"), nextSlot: nil, bedBy: bed)
                == .bedReminder(fireAt: APIDate.parse("2026-10-24T22:30:00+05:30")!, bedBy: bed))
        #expect(TodayStore.intent(for: try action("bed_reminder", "Remind me"), nextSlot: nil, bedBy: nil) == TodayIntent.none)
        #expect(TodayStore.intent(for: try action("something_new", "?"), nextSlot: nil, bedBy: nil) == TodayIntent.none)
        #expect(TodayStore.intent(for: nil, nextSlot: nil, bedBy: nil) == TodayIntent.none)
    }

    @Test func fixtureEveningUsesPulseWindowEndAsBedBy() {
        // The evening fixture's action is bed_reminder; bed_by is pulse.window.end (23:50) → 23:20.
        #expect(makeStore(fixture).intent == .bedReminder(fireAt: APIDate.parse("2026-10-24T23:20:00+05:30")!, bedBy: "2026-10-24T23:50:00+05:30"))
    }

    @Test func intentsApplyToTheRouter() {
        let store = makeStore(fixture)
        let router = Router()
        store.apply(.startWorkout, router: router)
        #expect(router.tab == .train)
        #expect(router.sheet == .workoutStart)

        let meal = Router()
        store.apply(.quickAdd(slot: "lunch"), router: meal)
        #expect(meal.sheet == .quickAdd(slot: "lunch"))
        #expect(meal.tab == .today)
    }

    @Test func bedReminderSchedulesOnceAndRelabels() async {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let reminders = FakeReminders()
        let store = makeStore(fixture, reminders: reminders)
        #expect(store.actionLabel == "Remind me")
        let fire = APIDate.parse("2026-10-24T23:20:00+05:30")!
        await store.scheduleReminder(fireAt: fire, bedBy: "2026-10-24T23:50:00+05:30")
        await store.scheduleReminder(fireAt: fire, bedBy: "2026-10-24T23:50:00+05:30")
        let scheduled = await reminders.scheduled
        #expect(scheduled.count == 1)
        #expect(scheduled.first?.title == "Bed by 23:50")
        #expect(scheduled.first?.at == fire)
        #expect(store.actionLabel == "Reminder set")
        #expect(makeStore(fixture).actionLabel == "Reminder set")   // survives relaunch
    }

    @Test func deniedNotificationsKeepTheAction() async {
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = makeStore(fixture, reminders: FakeReminders(grant: false))
        await store.scheduleReminder(fireAt: now.addingTimeInterval(3600), bedBy: "2026-10-24T23:50:00+05:30")
        #expect(store.actionLabel == "Remind me")
    }

    // MARK: Label substitution

    @Test func onlyStartWorkoutSwapsWatchForIPhone() throws {
        let start = try action("start_workout", "Start legs on Watch")
        #expect(TodayStore.actionLabel(start, rememberedStart: "phone") == "Start legs on iPhone")
        #expect(TodayStore.actionLabel(start, rememberedStart: "watch") == "Start legs on Watch")
        #expect(TodayStore.actionLabel(start, rememberedStart: nil) == "Start legs on Watch")
        let meal = try action("log_meal", "Log lunch on Watch")
        #expect(TodayStore.actionLabel(meal, rememberedStart: "phone") == "Log lunch on Watch")
        #expect(TodayStore.actionLabel(nil, rememberedStart: "phone") == nil)
    }

    // MARK: Stale inputs

    @Test(arguments: [
        ("HKQuantityTypeIdentifierStepCount: Server returned HTTP 401. The anchor was kept.", SyncFailure.unauthorized),
        ("HKQuantityTypeIdentifierStepCount: Server returned HTTP 403. The anchor was kept.", .unauthorized),
        ("HKQuantityTypeIdentifierHeartRate: Server returned HTTP 503. The anchor was kept.", .server(503)),
        ("Skipped: protected data is unavailable. Unlock the iPhone and sync again.", .protectedDataUnavailable),
        ("HKQuantityTypeIdentifierStepCount: The Internet connection appears to be offline.", .unreachable),
        ("HKQuantityTypeIdentifierStepCount: Could not connect to the server.", .unreachable),
        ("HKQuantityTypeIdentifierStepCount: Save a Vitalis write token in Settings.", .unauthorized),
    ])
    func exporterErrorTextMapsToAFailureKind(_ text: String, _ kind: SyncFailure) {
        #expect(ExporterState(lastSuccess: nil, lastError: text).failure == kind)
    }

    @Test func unknownOrNoExporterErrorHasNoKind() {
        #expect(ExporterState(lastError: "Health authorization: denied").failure == nil)
        #expect(ExporterState().failure == nil)
    }

    @Test func staleWhenTheExporterFailedForOver12Hours() {
        let store = makeStore(fixture)
        let since = APIDate.parse("2026-10-21T16:12:00+05:30")!
        store.updateExporter(ExporterState(lastSuccess: since, lastError: "x: Server returned HTTP 401. The anchor was kept."))
        guard case .stale(_, _, let cause) = store.status(now: now).status else { Issue.record("not stale"); return }
        #expect(cause == "Your server stopped accepting uploads.")
    }

    // MARK: Snapshot

    @Test func snapshotRoundTrips() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = TodaySnapshot(fixture)
        try snapshot.write(to: dir)
        #expect(TodaySnapshot.read(from: dir) == snapshot)
        #expect(snapshot.day == "2026-10-24")
        #expect(snapshot.recovery.score == 78)
        #expect(snapshot.kcalLeft == 110)
        #expect(snapshot.lastSync == "2026-10-24T21:44:13+05:30")
        #expect(TodaySnapshot.read(from: dir.appendingPathComponent("missing")) == nil)
    }

    @Test func appGroupComesFromTheBundlePrefix() {
        #expect(TodaySnapshot.appGroupID(bundleIdentifier: "com.example.vitalis") == "group.com.example.vitalis")
        #expect(TodaySnapshot.appGroupID(bundleIdentifier: "com.example.vitalis.watchkitapp") == "group.com.example.vitalis")
        #expect(TodaySnapshot.appGroupID(bundleIdentifier: "com.example.other") == nil)
        #expect(TodaySnapshot.appGroupID(bundleIdentifier: nil) == nil)
    }

    @Test func successfulFetchWritesTheSnapshot() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = try Fixture.data("today")
        let host = StubURLProtocol.register { _ in .http(200, headers: ["ETag": "W/\"1\""], body: body) }
        let store = makeStore(api: .stubbed(host), snapshotDirectory: dir)
        await store.refresh()
        #expect(store.phase == .loaded)
        #expect(TodaySnapshot.read(from: dir) == TodaySnapshot(fixture))
    }

    @Test func failedFetchWritesNothingAndShowsFailed() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = StubURLProtocol.register { _ in .failure(URLError(.notConnectedToInternet)) }
        let store = makeStore(api: .stubbed(host), snapshotDirectory: dir)
        await store.refresh()
        #expect(store.phase == .failed)
        #expect(TodaySnapshot.read(from: dir) == nil)
    }

    @Test func noServerConfiguredIsNotLoadingForever() async {
        let store = makeStore()
        #expect(store.phase == .loading)
        await store.refresh()
        #expect(store.phase == .failed)
    }

    // MARK: Formatting

    @Test func formatting() {
        #expect(TodayFormat.dateLabel(day: "2026-10-24") == "SAT 24 OCT")
        #expect(TodayFormat.number(1780.0) == "1,780")
        #expect(TodayFormat.number(3206) == "3,206")
        #expect(TodayFormat.number(Optional<Int>.none) == nil)
        #expect(TodayFormat.pace("on_pace") == "ON PACE")
        #expect(TodayFormat.pace("early") == nil)
    }
}
