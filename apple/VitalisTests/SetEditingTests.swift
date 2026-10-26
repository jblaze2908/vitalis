import Foundation
import Testing
import VitalisKit
@testable import Vitalis

@MainActor @Suite struct SetEditingTests {
    let bench = "barbell-bench-press-medium-grip", incline = "smith-machine-incline-bench-press"

    private func logged(_ sent: SentRequests) async throws -> LiveSessionStore {
        let base = LiveSessionStoreTests()
        let store = base.make(sent: sent)
        store.begin(split: try base.split([bench, incline]))
        store.addSet(to: 0)
        await store.check()
        await store.check()
        return store
    }

    private func edit(_ store: LiveSessionStore, _ id: UUID, exercise: String? = nil, reps: String = "8", kind: String = "normal") -> SetEdit {
        let set = store.loggedSet(id)!
        return SetEdit(exerciseID: exercise ?? set.exercise, exerciseName: exercise ?? set.exercise, kind: kind,
                       weight: TrainFormat.kg(set.weightKg, empty: ""), reps: reps, note: "")
    }

    @Test func editingAnEarlierSetChangesOnlyThatSetAndPostsIt() async throws {
        let sent = SentRequests()
        let store = try await logged(sent)
        let first = try #require(store.session?.sets.first?.id)
        await store.editLogged(first, edit(store, first, reps: "10", kind: "warmup"))

        let post = try #require(sent.workouts.last)
        let s = try #require(post.sets.first { $0.id == first.uuidString })
        #expect(s.reps == 10 && s.kind == "warmup")
        #expect(post.sets.count == 2)
        #expect(store.session?.exercises[0].rows.first { $0.loggedID == first }?.reps == "10")
    }

    @Test func changingTheExerciseMovesTheRowInTimeOrder() async throws {
        let sent = SentRequests()
        let store = try await logged(sent)
        let ids = try #require(store.session?.sets.map(\.id))
        await store.editLogged(ids[0], edit(store, ids[0], exercise: incline))

        #expect(sent.workouts.last?.sets.first { $0.id == ids[0].uuidString }?.exercise == incline)
        #expect(store.session?.exercises[0].rows.compactMap(\.loggedID) == [ids[1]])
        let moved = try #require(store.session?.exercises.first { $0.id == incline })
        #expect(moved.rows.first?.loggedID == ids[0])
        #expect(moved.rows.first?.last == nil)
    }

    @Test func movingToAnExerciseNotInTheSessionAddsIt() async throws {
        let sent = SentRequests()
        let store = try await logged(sent)
        let ids = try #require(store.session?.sets.map(\.id))
        let custom = "custom-selectorized-incline-chest-press"
        await store.editLogged(ids[1], edit(store, ids[1], exercise: custom))

        let added = try #require(store.session?.exercises.last)
        #expect(added.id == custom && added.rows.first?.loggedID == ids[1] && !added.prefilled)
        #expect(store.session?.exercises[0].rows.compactMap(\.loggedID) == [ids[0]])
        #expect(sent.workouts.last?.sets.first { $0.id == ids[1].uuidString }?.exercise == custom)
    }

    @Test func deleteSendsAMarkerAndUndoBringsTheSetBackInPlace() async throws {
        let sent = SentRequests()
        let store = try await logged(sent)
        let ids = try #require(store.session?.sets.map(\.id))
        let before = store.session?.exercises[0].rows

        await store.deleteLogged(ids[0])
        let marker = try #require(sent.workouts.last?.sets.first { $0.id == ids[0].uuidString })
        #expect(marker.deleted == true && marker.exercise == nil)
        #expect(store.session?.loggedSets.map(\.id) == [ids[1]])
        #expect(store.session?.exercises[0].rows.contains { $0.loggedID == ids[0] } == false)
        #expect(store.undo?.setID == ids[0])

        await store.undoDelete()
        #expect(store.undo == nil)
        #expect(store.session?.exercises[0].rows == before)
        #expect(sent.workouts.last?.sets.first { $0.id == ids[0].uuidString }?.deleted == nil)
    }

    @Test func aSessionWhoseSetsWereAllDeletedIsDiscardedOnFinish() async throws {
        let sent = SentRequests()
        let store = try await logged(sent)
        for id in store.session?.sets.map(\.id) ?? [] { await store.deleteLogged(id) }
        #expect(await store.finish() == nil)
        #expect(store.session == nil)
    }

    @Test func aSessionSavedBeforeDeletesExistedStillLoads() throws {
        let json = #"{"id":"6F1C2A2E-6F7B-4B53-9E35-6D9D2C3E1A10","exercise":"x","kind":"normal","weightKg":60,"reps":8,"performedAt":0}"#
        let set = try JSONDecoder().decode(Vitalis.LoggedSet.self, from: Data(json.utf8))
        #expect(set.isLive && set.note == nil)
    }

    @Test func aFinishedSetPatchSendsOnlyWhatChanged() async throws {
        let sent = SentRequests()
        let train = TrainStore(api: { nil }, send: { sent.all.append($0) })
        let was = SetEdit(exerciseID: bench, exerciseName: "Bench", kind: "normal", weight: "60", reps: "8", note: "")
        var now = was; now.exerciseID = incline; now.reps = "9"
        await train.editSet("S1", in: "W1", now, was: was)
        let r = try #require(sent.all.last)
        #expect(r.method == "PATCH" && r.path == "v2/sets/S1")
        let body = try JSONSerialization.jsonObject(with: try #require(r.body)) as? [String: Any]
        #expect(body?.keys.sorted() == ["exercise", "reps"])

        await train.editSet("S1", in: "W1", was, was: was)
        #expect(sent.all.count == 1)

        await train.deleteSet("S1", in: "W1", label: "Bench 60 x 8")
        #expect(train.undo?.setID == "S1")
        await train.undoDelete()
        let restore = try JSONSerialization.jsonObject(with: try #require(sent.all.last?.body)) as? [String: Any]
        #expect(restore?["restore"] as? Bool == true)
        #expect(train.undo == nil)
    }
}
