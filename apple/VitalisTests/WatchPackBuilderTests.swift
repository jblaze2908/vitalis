import Foundation
import Testing
import VitalisKit
@testable import Vitalis

@Suite struct WatchPackBuilderTests {
    static let now = Date(timeIntervalSince1970: 1_792_800_000)

    /// training.json (no due template), targets.json (rest and crown unset), one session detail and one exercise detail.
    static func inputs() throws -> WatchPackBuilder.Inputs {
        let training = try Fixture.decode(TrainingResponse.self, "training")
        let detail = try Fixture.decode(SessionDetail.self, "training-session")
        let bench = try Fixture.decode(ExerciseDetail.self, "exercise")
        var inputs = WatchPackBuilder.Inputs()
        inputs.training = training
        inputs.targets = try Fixture.decode(TargetsResponse.self, "targets")
        inputs.sessions = training.sessions
        inputs.sessionDetails = [detail.id: detail]
        inputs.exercises = [bench.exercise.id: bench]
        return inputs
    }

    @Test func buildsFromFixtures() throws {
        let inputs = try Self.inputs()
        let pack = WatchPackBuilder.build(inputs, generatedAt: Self.now)
        let detail = try #require(inputs.sessionDetails.values.first)

        #expect(pack.splits.map(\.id) == (inputs.training?.splits ?? []).map(\.id), "whatever training.json carries, in order")
        #expect(pack.settings.restS == nil && pack.settings.crownStepKg == nil)
        #expect(pack.settings.rest == 120 && pack.settings.crownStep == 2.5, "unset targets fall back on the Watch")

        // Only the session with a cached detail can be repeated; the other rows are left out, not sent empty.
        #expect(pack.recentSessions.count == 1)
        let recent = try #require(pack.recentSessions.first)
        #expect(recent.title == "pull" && recent.day == "2026-10-24")
        #expect(recent.exerciseIDs == detail.exercises?.map(\.id))
        #expect(pack.recentExerciseIDs == ["wide-grip-lat-pulldown", "bent-over-barbell-row", "barbell-curl"])
        let splitExerciseIDs = (inputs.training?.splits ?? []).flatMap { $0.exercises.map(\.id) }
        #expect(Set(pack.exercises.keys) == Set(splitExerciseIDs), "recent ids without a detail or catalog entry: nothing invented")
    }

    @Test func prefillCopiesTheServersLastSessionAndNext() throws {
        let bench = try Fixture.decode(ExerciseDetail.self, "exercise")
        let entry = try #require(WatchPackBuilder.exercise(detail: bench, info: nil, splitName: nil))
        #expect(entry.name == bench.exercise.name && entry.primary == ["chest"] && entry.secondary == ["shoulders", "triceps"])
        let prefill = try #require(entry.prefill)
        #expect(prefill.sets.count == bench.lastSession?.sets.count)
        #expect(prefill.sets.first == WatchPack.PlannedSet(kind: "normal", weightKg: 62, reps: 8))
        #expect(prefill.next == WatchPack.Next(weightKg: 64.5, reps: 8, sets: 4))
        #expect(entry.firstSet(suggests: true)?.weightKg == 64.5 && entry.plannedSets(suggests: true) == 4)
    }

    @Test func everySplitComesThroughInServerOrder() throws {
        var inputs = try Self.inputs()
        let splits = #"""
        [{"id":"chest-and-back","name":"Chest & Back","source":"defined","ready":false,"days_since":1,"muscles":["chest","lats"],"exercise_count":2,
          "exercises":[{"id":"barbell-bench-press-medium-grip","name":"Barbell Bench Press - Medium Grip","last":null},{"id":"dips","name":"Dips","last":null}]},
         {"id":"lower-body","name":"Lower Body","source":"history","ready":true,"days_since":5,"muscles":["quadriceps"],"exercise_count":1,
          "exercises":[{"id":"hack-squat","name":"Hack Squat","last":null}]},
         {"id":"arms","name":"Arms","source":"defined","ready":true,"days_since":null,"muscles":["biceps"],"exercise_count":0,"exercises":[]}]
        """#
        inputs.training = try TrainingResponse.replacingSplits(inputs.training, with: splits)
        let pack = WatchPackBuilder.build(inputs, generatedAt: Self.now)

        #expect(pack.splits == [
            WatchPack.Split(id: "chest-and-back", template: "chest-and-back", name: "Chest & Back", ready: false, daysSince: 1,
                            exerciseIDs: ["barbell-bench-press-medium-grip", "dips"]),
            WatchPack.Split(id: "lower-body", template: nil, name: "Lower Body", ready: true, daysSince: 5, exerciseIDs: ["hack-squat"]),
            WatchPack.Split(id: "arms", template: "arms", name: "Arms", ready: true, daysSince: nil, exerciseIDs: []),
        ], "defined splits send their id as template; history splits match by title")
        #expect(pack.exercises["barbell-bench-press-medium-grip"]?.prefill != nil)
        #expect(pack.exercises["dips"] == WatchPack.Exercise(name: "Dips", primary: [], secondary: []), "name only, from the split list")
        #expect(pack.exercises["hack-squat"]?.name == "Hack Squat", "a not-first split's exercises are covered too")
        #expect(WatchPackBuilder.neededExerciseIDs(inputs).prefix(3) == ["barbell-bench-press-medium-grip", "dips", "hack-squat"])
    }

    @Test func trimmingDropsTheOldestRecentExercisesFirst() throws {
        let filler = String(repeating: "x", count: 400)
        var exercises: [String: WatchPack.Exercise] = [:]
        let recent = (0..<20).map { "ex-\($0)" }
        for id in recent + ["bench", "squat"] { exercises[id] = WatchPack.Exercise(name: id + filler, primary: [], secondary: []) }
        let pack = WatchPack(generatedAt: "2026-10-24T09:41:02+05:30",
                             splits: [.init(id: "push", template: "push", name: "Push", ready: true, daysSince: 3, exerciseIDs: ["bench"]),
                                      .init(id: "legs", template: nil, name: "Legs", ready: false, daysSince: 1, exerciseIDs: ["squat"])],
                             exercises: exercises, recentExerciseIDs: recent)
        let limit = WatchPackBuilder.size(pack) - 1000
        let trimmed = WatchPackBuilder.trimmed(pack, limit: limit)

        #expect(WatchPackBuilder.size(trimmed) <= limit)
        #expect(trimmed.exercises["bench"] != nil && trimmed.exercises["squat"] != nil, "every split's exercises stay, ready or not")
        #expect(trimmed.exercises["ex-0"] != nil && trimmed.exercises["ex-19"] == nil, "newest kept, oldest dropped")
        #expect(trimmed.recentExerciseIDs == Array(recent.prefix(trimmed.recentExerciseIDs.count)))
        #expect(WatchPackBuilder.trimmed(pack) == pack, "under 64 KB nothing changes")
    }
}

private extension TrainingResponse {
    /// The fixture with a `due` block swapped in, decoded the same way as a server body.
    static func replacingSplits(_ training: TrainingResponse?, with splits: String) throws -> TrainingResponse {
        guard var object = try JSONSerialization.jsonObject(with: Fixture.data("training")) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        object["splits"] = try JSONSerialization.jsonObject(with: Data(splits.utf8))
        return try APICoding.decoder().decode(TrainingResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
