import Foundation
import Testing
import VitalisKit
@testable import Vitalis

@MainActor
final class SentRequests {
    var all: [APIRequest] = []
    var workouts: [WorkoutUpsert] { all.compactMap { $0.body.flatMap { try? APICoding.decoder().decode(WorkoutUpsert.self, from: $0) } } }
}

@MainActor @Suite struct LiveSessionStoreTests {
    let bench = "barbell-bench-press-medium-grip"

    func due(_ ids: [String]) throws -> DueWorkout {
        let exercises = ids.map { #"{"id":"\#($0)","name":"\#($0)","last":{"weight_kg":60,"reps":8,"day":"2026-10-20"}}"# }.joined(separator: ",")
        let json = #"{"template":"push","name":"Push","days_since":2,"exercise_count":\#(ids.count),"exercises":[\#(exercises)]}"#
        return try APICoding.decoder().decode(DueWorkout.self, from: Data(json.utf8))
    }

    func make(file: URL? = temporaryDirectory().appendingPathComponent("live-session.json"), api: VitalisAPI? = nil,
              sent: SentRequests = SentRequests(), clock: TestClock = TestClock(), health: FakeHealthWriter = FakeHealthWriter()) -> LiveSessionStore {
        LiveSessionStore(fileURL: file, api: { api }, send: { sent.all.append($0) }, health: health, now: { clock.now },
                         timeZone: TimeZone(identifier: "Asia/Kolkata")!)
    }

    @Test func sessionSurvivesRelaunchWithTheSameSetIds() async throws {
        let file = temporaryDirectory().appendingPathComponent("live-session.json")
        let clock = TestClock()
        let store = make(file: file, clock: clock)
        store.begin(due: try due([bench, "barbell-squat"]))
        await store.check()
        clock.advance(20)
        store.adjustRest(by: 15)
        let rowID = try #require(store.currentRowID)
        store.setWeight("62.5", row: rowID, in: try #require(store.session?.currentIndex))

        let relaunched = make(file: file, clock: clock)
        #expect(relaunched.session == store.session)
        #expect(relaunched.session?.sets.map(\.id) == store.session?.sets.map(\.id))
        #expect(relaunched.session?.exercises.count == 2)

        _ = await relaunched.finish()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(make(file: file).session == nil)
    }

    @Test func prefillMirrorsLastSessionWithNextSuggestion() throws {
        let rows = LiveSessionStore.rows(from: try Fixture.decode(ExerciseDetail.self, "exercise"))
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.kind == "normal" && $0.last == "62 x 8" && $0.weight == "64.5" && $0.reps == "8" })
        #expect(rows.allSatisfy { $0.targetWeightKg == 64.5 && $0.targetReps == 8 && !$0.isDone })
    }

    @Test func prefillUsesTheCachedDetailWhenOffline() async throws {
        let body = try Fixture.data("exercise")
        let host = StubURLProtocol.register { r in
            r.url.path.hasSuffix("/v2/exercises/barbell-bench-press-medium-grip") ? .http(200, body: body) : .http(404)
        }
        let api = VitalisAPI.stubbed(host, cache: try ResponseCache(directory: temporaryDirectory()))
        let online = make(api: api)
        online.begin(due: try due([bench]))
        await online.prefill(bench)
        #expect(online.session?.exercises[0].best == "78 kg × 8")
        #expect(online.session?.exercises[0].rows.count == 4)

        host.setHandler { _ in .failure(URLError(.notConnectedToInternet)) }
        let offline = make(api: api)
        offline.begin(due: try due([bench]))
        await offline.prefill(bench)
        func shape(_ s: LiveSession?) -> [String] { s?.exercises[0].rows.map { "\($0.kind) \($0.last ?? "-") \($0.weight) \($0.reps)" } ?? [] }
        #expect(shape(offline.session) == shape(online.session))
        #expect(offline.session?.exercises[0].prefilled == true)

        // Nothing cached for this one: the placeholder row from `due.last` stays.
        offline.addExercise(id: "barbell-squat", name: "Barbell Squat")
        await offline.prefill("barbell-squat")
        #expect(offline.session?.exercises[1].rows.count == 1)
        #expect(offline.session?.exercises[1].prefilled == false)
    }

    @Test func restTimerRunsFromItsEndDate() async throws {
        let clock = TestClock()
        let store = make(clock: clock)
        store.begin(due: try due([bench]))
        let start = clock.now
        await store.check()
        let s = try #require(store.session)
        #expect(s.restEnd == start.addingTimeInterval(120))
        #expect(s.restTotal == 120)

        clock.advance(30)
        #expect(RestTimer.remaining(end: store.session?.restEnd, now: clock.now) == 90)
        #expect(RestTimer.text(90) == "1:30")
        #expect(RestTimer.fraction(end: store.session?.restEnd, total: 120, now: clock.now) == 0.75)

        store.adjustRest(by: 15)
        #expect(RestTimer.remaining(end: store.session?.restEnd, now: clock.now) == 105)
        store.adjustRest(by: -15)
        store.adjustRest(by: -15)
        #expect(RestTimer.remaining(end: store.session?.restEnd, now: clock.now) == 75)
        #expect(RestTimer.text(74.2) == "1:15")

        clock.advance(80)
        #expect(RestTimer.remaining(end: store.session?.restEnd, now: clock.now) == 0)
        store.adjustRest(by: -15)
        #expect(store.session?.restEnd == nil)
    }

    @Test func plusFifteenNeverOverfillsTheTrack() async throws {
        let clock = TestClock()
        let store = make(clock: clock)
        store.begin(due: try due([bench]))
        await store.check()
        store.adjustRest(by: 15)
        let s = try #require(store.session)
        #expect(s.restTotal == 135)
        #expect(RestTimer.fraction(end: s.restEnd, total: s.restTotal, now: clock.now) == 1)
        store.skipRest()
        #expect(store.session?.restEnd == nil)
    }

    @Test func everyUpsertCarriesTheWholeSessionWithStableIds() async throws {
        let sent = SentRequests()
        let store = make(sent: sent)
        store.begin(due: try due([bench]))
        store.addSet(to: 0)
        await store.check()
        await store.check()

        #expect(sent.all.count == 2)
        #expect(sent.all.allSatisfy { $0.method == "POST" && $0.path == "v2/workouts" })
        let posts = sent.workouts
        let logged = try #require(store.session?.sets.map(\.id.uuidString))
        #expect(posts[0].sets.map(\.id) == [logged[0]])
        #expect(posts[1].sets.map(\.id) == logged)
        #expect(posts[0].session.clientId == posts[1].session.clientId)
        #expect(posts[1].session.source == "phone")
        #expect(posts[1].session.tzOffsetMin == 330)
        #expect(posts[1].session.startedAt.hasSuffix("+05:30"))
        #expect(posts[1].sets.allSatisfy { $0.exercise == bench && $0.kind == "normal" && $0.weightKg == 60 && $0.reps == 8 })

        // A correction to a ticked set goes out under the same id on Done.
        let firstRow = try #require(store.session?.exercises[0].rows[0].id)
        store.setReps("7", row: firstRow, in: 0)
        await store.commitEdits()
        let corrected = try #require(sent.workouts.last)
        #expect(corrected.sets.map(\.id) == logged)
        #expect(corrected.sets[0].reps == 7)
    }

    @Test func finishSavesTheWorkoutAndPostsItsUUID() async throws {
        let sent = SentRequests()
        let health = FakeHealthWriter()
        let store = make(sent: sent, health: health)
        store.begin(due: try due([bench]))
        await store.check()
        let id = await store.finish()
        let last = try #require(sent.workouts.last)
        #expect(id == last.session.clientId)
        #expect(last.session.endedAt != nil)
        #expect(last.session.hkWorkoutUuid.flatMap(UUID.init(uuidString:)).flatMap { health.saved[$0] } == "workout")
        #expect(store.session == nil)
    }

    @Test func aHealthKitFailureStillPostsTheSession() async throws {
        let sent = SentRequests()
        let health = FakeHealthWriter()
        health.failNext = true
        let store = make(sent: sent, health: health)
        store.begin(due: try due([bench]))
        await store.check()
        #expect(await store.finish() != nil)
        #expect(sent.workouts.last?.session.endedAt != nil)
        #expect(sent.workouts.last?.session.hkWorkoutUuid == nil)
    }

    @Test func watchSessionMakesThePhoneReadOnly() async throws {
        let sent = SentRequests()
        let store = make(sent: sent)
        store.begin(due: try due([bench]))
        store.watchSessionLive = true
        await store.check()
        #expect(store.session?.sets.isEmpty == true)
        #expect(sent.all.isEmpty)
    }
}
