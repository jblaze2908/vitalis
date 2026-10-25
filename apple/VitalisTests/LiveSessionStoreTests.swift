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

    func split(_ ids: [String]) throws -> Split {
        let exercises = ids.map { #"{"id":"\#($0)","name":"\#($0)","last":{"weight_kg":60,"reps":8,"day":"2026-10-20"}}"# }.joined(separator: ",")
        let json = #"{"id":"push","name":"Push","source":"defined","ready":true,"days_since":2,"exercise_count":\#(ids.count),"exercises":[\#(exercises)]}"#
        return try APICoding.decoder().decode(Split.self, from: Data(json.utf8))
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
        store.begin(split: try split([bench, "barbell-squat"]))
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
        online.begin(split: try split([bench]))
        await online.prefill(bench)
        #expect(online.session?.exercises[0].best == "78 kg × 8")
        #expect(online.session?.exercises[0].rows.count == 4)

        host.setHandler { _ in .failure(URLError(.notConnectedToInternet)) }
        let offline = make(api: api)
        offline.begin(split: try split([bench]))
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
        store.begin(split: try split([bench]))
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
        store.begin(split: try split([bench]))
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
        store.begin(split: try split([bench]))
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
        store.begin(split: try split([bench]))
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
        store.begin(split: try split([bench]))
        await store.check()
        #expect(await store.finish() != nil)
        #expect(sent.workouts.last?.session.endedAt != nil)
        #expect(sent.workouts.last?.session.hkWorkoutUuid == nil)
    }

    // Still true after shared workouts: until the phone joins, a live Watch workout keeps phone logging off.
    @Test func watchSessionMakesThePhoneReadOnly() async throws {
        let sent = SentRequests()
        let store = make(sent: sent)
        store.begin(split: try split([bench]))
        store.watchSessionLive = true
        await store.check()
        #expect(store.session?.sets.isEmpty == true)
        #expect(sent.all.isEmpty)
    }

    // MARK: Shared workout (20 §4)

    func watchRecord(_ sets: [VitalisKit.LoggedSet], ended: Bool = false, phoneSets: [VitalisKit.LoggedSet] = []) -> WorkoutSessionRecord {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return WorkoutSessionRecord(id: UUID(uuidString: "6F0E6A44-0000-4000-8000-000000000001")!, title: "Push", startedAt: start,
                                    endedAt: ended ? start.addingTimeInterval(3600) : nil, tzOffsetMin: 330, sets: sets, revision: 3,
                                    exerciseIDs: [bench], phoneSets: phoneSets)
    }

    @Test func joiningShowsTheWatchSetsAndLogsThePhonesOwn() async throws {
        let sent = SentRequests(), clock = TestClock()
        let store = make(file: nil, sent: sent, clock: clock)
        var shared: [WatchPhoneSets] = []
        store.sendToWatch = { shared.append($0) }
        let w1 = VitalisKit.LoggedSet(exerciseID: bench, weightKg: 60, reps: 8, performedAt: clock.now.addingTimeInterval(-120))
        store.watchRecord(watchRecord([w1]))
        #expect(store.watchSessionLive && store.liveWatch != nil)
        store.join()
        let s = try #require(store.session)
        #expect(s.isJoined && s.id == watchRecord([]).id && s.title == "Push")
        #expect(s.exercises.first?.rows.first?.byWatch == true && s.exercises.first?.rows.first?.loggedID == w1.id)
        // The pending row after the Watch's set is the phone's to log.
        store.setReps("8", row: try #require(store.currentRowID), in: 0)
        store.setWeight("62.5", row: try #require(store.currentRowID), in: 0)
        await store.check()
        let body = try #require(sent.workouts.last)
        #expect(body.session.clientId == s.id.uuidString && body.session.source == "phone")
        #expect(body.session.title == nil && body.session.endedAt == nil && body.session.template == nil, "the Watch's to set")
        #expect(body.sets.map(\.id) == [try #require(store.session?.sets.first?.id).uuidString], "only the phone's own set")
        #expect(shared.last?.sets.map(\.id) == store.session?.sets.map(\.id))
        // The Watch's next record keeps the phone's row and adds its own in time order.
        let w2 = VitalisKit.LoggedSet(exerciseID: bench, weightKg: 60, reps: 7, performedAt: clock.now.addingTimeInterval(60))
        store.watchRecord(watchRecord([w1, w2]))
        #expect(store.session?.exercises.first?.rows.compactMap(\.loggedID) == [w1.id, try #require(store.session?.sets.first?.id), w2.id])
    }

    @Test func theWatchEndingTheWorkoutClosesItOnThePhoneWithoutAPhoneHealthWorkout() async throws {
        let health = FakeHealthWriter()
        let store = make(file: nil, health: health)
        store.watchRecord(watchRecord([]))
        store.join()
        store.rename("Chest")
        #expect(store.session?.title == "Push", "a joined workout keeps the Watch's title")
        store.watchRecord(watchRecord([], ended: true))
        #expect(store.session == nil && !store.watchSessionLive && store.liveWatch == nil)
        #expect(await store.finish() == nil)
    }

    @Test func mergedSetsTakeTheOwnCopyAndRunInTimeOrder() {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let a = VitalisKit.LoggedSet(exerciseID: bench, weightKg: 60, reps: 8, performedAt: t)
        var aEdited = a; aEdited.reps = 9
        let b = VitalisKit.LoggedSet(exerciseID: bench, weightKg: 60, reps: 7, performedAt: t.addingTimeInterval(-30))
        let gone = VitalisKit.LoggedSet(exerciseID: bench, weightKg: 60, reps: 5, performedAt: t.addingTimeInterval(30), deleted: true)
        let merged = VitalisKit.LoggedSet.merged(own: [aEdited, gone], foreign: [a, b])
        #expect(merged.map(\.id) == [b.id, a.id] && merged[1].reps == 9)
        let r = watchRecord([a], phoneSets: [b])
        #expect(r.allSets.map(\.id) == [b.id, a.id])
        #expect(r.upsert.sets.map(\.id) == [a.id.uuidString], "the Watch never posts the phone's sets")
    }
}
