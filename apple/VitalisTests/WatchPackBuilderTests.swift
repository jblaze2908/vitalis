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

        #expect(pack.due == nil, "training.json has no due template")
        #expect(pack.settings.restS == nil && pack.settings.crownStepKg == nil)
        #expect(pack.settings.rest == 120 && pack.settings.crownStep == 2.5, "unset targets fall back on the Watch")

        // Only the session with a cached detail can be repeated; the other rows are left out, not sent empty.
        #expect(pack.recentSessions.count == 1)
        let recent = try #require(pack.recentSessions.first)
        #expect(recent.title == "pull" && recent.day == "2026-10-24")
        #expect(recent.exerciseIDs == detail.exercises?.map(\.id))
        #expect(pack.recentExerciseIDs == ["wide-grip-lat-pulldown", "bent-over-barbell-row", "barbell-curl"])
        #expect(Set(pack.exercises.keys) == [], "no detail or catalog entry for those ids: nothing invented")
    }

    @Test func prefillCopiesTheServersLastSessionAndNext() throws {
        let bench = try Fixture.decode(ExerciseDetail.self, "exercise")
        let entry = try #require(WatchPackBuilder.exercise(detail: bench, info: nil, dueName: nil))
        #expect(entry.name == bench.exercise.name && entry.primary == ["chest"] && entry.secondary == ["shoulders", "triceps"])
        let prefill = try #require(entry.prefill)
        #expect(prefill.sets.count == bench.lastSession?.sets.count)
        #expect(prefill.sets.first == WatchPack.PlannedSet(kind: "normal", weightKg: 62, reps: 8))
        #expect(prefill.next == WatchPack.Next(weightKg: 64.5, reps: 8, sets: 4))
        #expect(entry.firstSet(suggests: true)?.weightKg == 64.5 && entry.plannedSets(suggests: true) == 4)
    }

    @Test func dueTemplateAndItsExercisesComeThrough() throws {
        var inputs = try Self.inputs()
        let due = #"{"template":"push","name":"Push","days_since":2,"exercise_count":1,"exercises":[{"id":"barbell-bench-press-medium-grip","name":"Barbell Bench Press - Medium Grip","last":null},{"id":"dips","name":"Dips","last":null}]}"#
        inputs.training = try TrainingResponse.replacingDue(inputs.training, with: due)
        let pack = WatchPackBuilder.build(inputs, generatedAt: Self.now)

        #expect(pack.due == WatchPack.Due(template: "push", name: "Push", daysSince: 2,
                                          exerciseIDs: ["barbell-bench-press-medium-grip", "dips"]))
        #expect(pack.exercises["barbell-bench-press-medium-grip"]?.prefill != nil)
        #expect(pack.exercises["dips"] == WatchPack.Exercise(name: "Dips", primary: [], secondary: []), "name only, from the due list")
        #expect(WatchPackBuilder.neededExerciseIDs(inputs).prefix(2) == ["barbell-bench-press-medium-grip", "dips"])
    }

    @Test func trimmingDropsTheOldestRecentExercisesFirst() throws {
        let filler = String(repeating: "x", count: 400)
        var exercises: [String: WatchPack.Exercise] = [:]
        let recent = (0..<20).map { "ex-\($0)" }
        for id in recent + ["squat"] { exercises[id] = WatchPack.Exercise(name: id + filler, primary: [], secondary: []) }
        let pack = WatchPack(generatedAt: "2026-10-24T09:41:02+05:30",
                             due: .init(template: "legs", name: "Legs", daysSince: 6, exerciseIDs: ["squat"]),
                             exercises: exercises, recentExerciseIDs: recent)
        let limit = WatchPackBuilder.size(pack) - 1000
        let trimmed = WatchPackBuilder.trimmed(pack, limit: limit)

        #expect(WatchPackBuilder.size(trimmed) <= limit)
        #expect(trimmed.exercises["squat"] != nil, "the due template's exercises stay")
        #expect(trimmed.exercises["ex-0"] != nil && trimmed.exercises["ex-19"] == nil, "newest kept, oldest dropped")
        #expect(trimmed.recentExerciseIDs == Array(recent.prefix(trimmed.recentExerciseIDs.count)))
        #expect(WatchPackBuilder.trimmed(pack) == pack, "under 64 KB nothing changes")
    }
}

private extension TrainingResponse {
    /// The fixture with a `due` block swapped in, decoded the same way as a server body.
    static func replacingDue(_ training: TrainingResponse?, with due: String) throws -> TrainingResponse {
        guard var object = try JSONSerialization.jsonObject(with: Fixture.data("training")) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        object["due"] = try JSONSerialization.jsonObject(with: Data(due.utf8))
        return try APICoding.decoder().decode(TrainingResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
