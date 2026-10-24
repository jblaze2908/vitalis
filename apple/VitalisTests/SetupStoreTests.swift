import Foundation
import Testing
import VitalisKit
@testable import Vitalis

@MainActor @Suite struct SetupStoreTests {
    /// Records persisted tokens without touching the Keychain.
    final class Saved { var tokens: [String] = []; var urls: [URL] = []; var sent: [APIRequest] = [] }

    func make(_ host: StubURLProtocol.Host, step: SetupStep = .connect, saved: Saved = Saved(), now: Date = Date()) -> SetupStore {
        let deps = SetupStore.Dependencies(
            makeAPI: { _ in .stubbed(host) },
            persist: { settings, token in saved.urls.append(settings.baseURL); saved.tokens.append(token) },
            send: { saved.sent.append($0) },
            now: { now })
        let store = SetupStore(deps: deps, step: step, serverText: host.baseURL.absoluteString)
        store.tokenText = "vtl_test"
        return store
    }

    func status(canWrite: Bool) -> Data {
        Data(#"{"token":{"name":"iphone","scope":"\#(canWrite ? "write" : "ingest")","can_push":true,"can_read":\#(canWrite),"can_write":\#(canWrite)},"types":[],"batches":[]}"#.utf8)
    }

    @Test func tokenThatCanWriteConnectsAndContinues() async throws {
        let body = try Fixture.data("sync-status")
        let host = StubURLProtocol.register { _ in .http(200, body: body) }
        let saved = Saved()
        let store = make(host, saved: saved)
        await store.continueFromConnect()
        #expect(saved.tokens == ["vtl_test"])
        #expect(host.requests.map(\.url.path) == ["/v2/sync/status"])
        #expect(store.step == .health)
        #expect(store.canContinue)
        #expect(store.tokenText.isEmpty)
        #expect(store.connect.label == "Connected · token can write")
    }

    @Test func rejectedTokenBlocksContinue() async {
        let host = StubURLProtocol.register { _ in .http(401, body: Data(#"{"error":"Unauthorized","code":"unauthorized"}"#.utf8)) }
        let store = make(host)
        await store.continueFromConnect()
        #expect(store.connect == .rejected)
        #expect(store.connect.label == "Token rejected")
        #expect(!store.canContinue)
        #expect(store.step == .connect)
    }

    @Test func unreachableServerBlocksContinue() async {
        let host = StubURLProtocol.register { _ in .failure(URLError(.cannotConnectToHost)) }
        let store = make(host)
        await store.continueFromConnect()
        #expect(store.connect == .unreachable)
        #expect(store.connect.isError)
        #expect(store.step == .connect)
    }

    @Test func readOnlyTokenBlocksContinue() async {
        let body = status(canWrite: false)
        let host = StubURLProtocol.register { _ in .http(200, body: body) }
        let store = make(host)
        await store.continueFromConnect()
        #expect(store.connect == .readOnly)
        #expect(store.connect.label == "This token can't log workouts or food")
        #expect(!store.canContinue)
        #expect(store.step == .connect)
    }

    @Test func serverWithoutTokenBlockCannotBeVerified() async {
        let host = StubURLProtocol.register { _ in .http(200, body: Data(#"{"types":[],"batches":[]}"#.utf8)) }
        let store = make(host)
        await store.continueFromConnect()
        #expect(store.connect == .outdatedServer)
        #expect(store.step == .connect)
    }

    @Test func invalidURLNeverSavesTheToken() async {
        let host = StubURLProtocol.register()
        let saved = Saved()
        let store = make(host, saved: saved)
        store.serverText = "vitalis example"
        await store.continueFromConnect()
        #expect(store.connect == .invalidURL)
        #expect(saved.tokens.isEmpty)
        #expect(host.requests.isEmpty)
    }

    @Test func emptyTokenAsksForOne() async {
        let host = StubURLProtocol.register()
        let store = make(host)
        store.tokenText = "  "
        await store.check()
        #expect(store.connect == .missingToken)
        #expect(host.requests.isEmpty)
    }

    @Test func editingAFieldClearsTheResult() async {
        let body = status(canWrite: false)
        let host = StubURLProtocol.register { _ in .http(200, body: body) }
        let store = make(host)
        await store.check()
        #expect(store.connect == .readOnly)
        store.tokenText = "vtl_other"
        #expect(store.connect == .idle)
    }

    @Test func healthThenHistoryThenTargets() async {
        let store = make(StubURLProtocol.register(), step: .health)
        await store.allowHealth()
        #expect(store.step == .history)
        store.goToTargets()
        #expect(store.step == .targets)
    }

    @Test func finishSendsTheShownTargetsAndCalls() async throws {
        let targets = try Fixture.data("targets")
        let status = try Fixture.data("sync-status")
        let host = StubURLProtocol.register { r in .http(200, body: r.url.path.hasSuffix("targets") ? targets : status) }
        let saved = Saved()
        let store = make(host, saved: saved)
        await store.continueFromConnect()
        store.goToTargets()
        await store.loadTargets()
        #expect(store.draft.basis[.steps] == "YOUR USUAL IS 8,000")
        #expect(store.draft.value(.goalWeightKg) == nil)
        store.setTarget(.goalWeightKg, 74)
        var finished = false
        await store.finish { finished = true }
        #expect(finished)
        let request = try #require(saved.sent.first)
        #expect(request.method == "PUT" && request.path == "v2/targets")
        let json = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: Any]
        #expect(json?["steps"] as? Int == 8000)
        #expect(json?["protein_g"] as? Double == 150)
        #expect(json?["sleep_need_h"] as? Double == 7)
        #expect(json?["goal_weight_kg"] as? Double == 74)
        #expect(json?["kcal_mode"] as? String == "adaptive")
        #expect(json?["kcal"] == nil)
    }

    @Test func editedCaloriesBecomeFixed() {
        var draft = TargetDraft(suggested: try? Fixture.decode(TargetsResponse.self, "targets").suggested)
        draft.set(.kcal, 2_100)
        let patch = draft.patch()
        #expect(patch.kcal == .set(2_100))
        #expect(patch.kcalMode == .set("fixed"))
    }

    @Test func finishWithoutTargetsSendsNothing() async {
        let saved = Saved()
        let store = make(StubURLProtocol.register { _ in .failure(URLError(.notConnectedToInternet)) }, step: .targets, saved: saved)
        await store.loadTargets()
        #expect(store.targetsError != nil)
        var finished = false
        await store.finish { finished = true }
        #expect(finished)
        #expect(saved.sent.isEmpty)
    }

    @Test func progressPulseMarksTheStep() {
        #expect(SetupStep.welcome.pulse == nil)
        #expect(SetupStep.connect.pulse?.events == [])
        #expect(SetupStep.health.pulse?.now == 2 / 4.5)
        #expect(SetupStep.targets.pulse?.events == [3 / 4.5])
        #expect(SetupStep.history.statusLabel == "STEP 3 OF 4")
    }

    // MARK: Reading your history

    let now = ISO8601DateFormatter().date(from: "2026-10-24T04:11:00Z")!

    func snapshot(_ newestEnd: String?, sent: Int = 0, phase: String = "Backfilling", lastSuccess: Date? = nil) -> SyncSnapshot {
        var h = SyncHistory()
        var t = TypeHistory(); t.newestEnd = newestEnd; t.objectsSent = sent
        h.types["HKQuantityTypeIdentifierStepCount"] = t
        h.lastSuccess = lastSuccess
        return SyncSnapshot(phase: phase, currentType: phase == "Idle" ? nil : "HKQuantityTypeIdentifierStepCount", page: 1, history: h)
    }

    @Test func percentIsThePageDateBetweenOldestSeenAndNow() {
        let oldest = ISO8601DateFormatter().date(from: "2016-10-24T04:11:00Z")!
        // Halfway between 2016-10-24 and 2026-10-24.
        let p = HistoryProgress.make(snapshot: snapshot("2021-10-24T04:11:00.000Z", sent: 1_840_000), oldestSeen: oldest,
                                     startedAt: now.addingTimeInterval(-600), now: now, calendar: Calendar(identifier: .gregorian))
        #expect(p.percent == 50)
        #expect(p.reading == "OCTOBER 2021")
        #expect(p.samplesSent == "1.84M")
        // elapsed 10 min × (100 − 50) / 50.
        #expect(p.timeLeft == "About 10 min")
    }

    @Test func timeLeftWaitsForFivePercent() {
        let oldest = ISO8601DateFormatter().date(from: "2016-10-24T04:11:00Z")!
        let p = HistoryProgress.make(snapshot: snapshot("2016-11-24T04:11:00.000Z"), oldestSeen: oldest,
                                     startedAt: now.addingTimeInterval(-60), now: now)
        #expect(p.percent == 0)
        #expect(p.timeLeft == nil)
    }

    @Test func storeTracksTheOldestPageSeen() async {
        let store = make(StubURLProtocol.register(), step: .health, now: now)
        await store.allowHealth()
        store.observe(snapshot("2016-10-24T04:11:00.000Z"))
        #expect(store.progress().percent == 0)
        store.observe(snapshot("2021-10-24T04:11:00.000Z"))
        #expect(store.progress().percent == 50)
    }

    @Test func idleAfterASuccessIsDone() {
        let start = now.addingTimeInterval(-600)
        let p = HistoryProgress.make(snapshot: snapshot(nil, phase: "Idle", lastSuccess: now), oldestSeen: nil, startedAt: start, now: now)
        #expect(p.done && p.percent == 100)
        let before = HistoryProgress.make(snapshot: snapshot(nil, phase: "Idle", lastSuccess: start.addingTimeInterval(-60)),
                                          oldestSeen: nil, startedAt: start, now: now)
        #expect(!before.done && before.percent == nil)
    }

    @Test func compactCounts() {
        #expect(HistoryProgress.compact(980) == "980")
        #expect(HistoryProgress.compact(14_820) == "14.8K")
        #expect(HistoryProgress.compact(3_000) == "3K")
        #expect(HistoryProgress.compact(1_840_000) == "1.84M")
    }

    // MARK: Target validation (10 §3)

    @Test func targetRangesFollowTheServer() {
        #expect(TargetField.steps.validate(9_000) == nil)
        #expect(TargetField.steps.validate(500) == "Between 1,000 and 50,000")
        #expect(TargetField.sleepNeedH.validate(7.5) == nil)
        #expect(TargetField.sleepNeedH.validate(7.1) == "Quarter hours only")
        #expect(TargetField.crownStepKg.validate(3) != nil)
        #expect(TargetField.crownStepKg.validate(1.25) == nil)
        #expect(TargetField.restS.format(120) == "2:00")
        #expect(TargetField.patch([.weeklySetsMin: 20, .weeklySetsMax: 10]).patch == nil)
        #expect(TargetField.patch([.weeklySetsMin: 10, .weeklySetsMax: 20]).patch?.weeklySetsMax == .set(20))
    }
}
