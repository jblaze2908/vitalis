import Foundation
import Testing
import VitalisKit
@testable import Vitalis

@Suite struct WorkoutActivityTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func logged(_ exercise: String, _ kg: Double, _ reps: Int, at minutes: Double, kind: String = "normal") -> Vitalis.LoggedSet {
        LoggedSet(id: UUID(), exercise: exercise, kind: kind, weightKg: kg, reps: reps, performedAt: start.addingTimeInterval(minutes * 60))
    }

    /// Bench: a warm-up and two working sets logged, two to go; rest running after the second working set.
    func session() -> LiveSession {
        let warm = logged("bench", 40, 10, at: 2, kind: "warmup")
        let one = logged("bench", 80, 8, at: 5), two = logged("bench", 80, 7, at: 9)
        let bench = LiveExercise(id: "bench", name: "Barbell Bench Press", best: nil, rows: [
            SetRow(kind: "warmup", weight: "40", reps: "10", loggedID: warm.id),
            SetRow(last: "80 x 8", weight: "80", reps: "8", loggedID: one.id),
            SetRow(last: "80 x 8", weight: "80", reps: "7", loggedID: two.id),
            SetRow(last: "80 x 8", weight: "82.5", reps: "8"),
            SetRow(last: "80 x 6", weight: "82.5", reps: "6"),
        ])
        let dips = LiveExercise(id: "dips", name: "Dips", best: nil, rows: [SetRow(last: "20 x 10", weight: "20", reps: "10")])
        var s = LiveSession(id: UUID(), title: "Push", startedAt: start, exercises: [bench, dips], currentIndex: 0)
        s.sets = [warm, one, two]
        s.restTotal = 120
        s.restEnd = two.performedAt.addingTimeInterval(120)
        return s
    }

    @Test func mapsTheCurrentExerciseRestAndTotals() {
        let s = session()
        let state = WorkoutActivityController.content(for: s, heartRate: 142)
        #expect(state.exercise == "Barbell Bench Press")
        #expect(state.setIndex == 3 && state.setTotal == 4)
        #expect(state.last == "80 × 7")
        #expect(state.next == "82.5 × 8")
        #expect(state.restEnd == s.restEnd && state.restTotal == 120)
        #expect(state.restInterval == s.restEnd!.addingTimeInterval(-120)...s.restEnd!)
        #expect(state.heartRate == 142)
        #expect(state.startedAt == start)
        // Warm-ups count as sets but not as volume: 80×8 + 80×7.
        #expect(state.totalSets == 3 && state.volumeKg == 1200)
        #expect(state.compactSetLine == "Set 3/4")
        #expect(state.setLine == "Set 3 of 4 · last 80 × 7")
        #expect(state.totalsLine == "3 sets · 1,200 kg")
    }

    @Test func freshExerciseShowsLastSessionAndNoRest() {
        var s = session()
        s.currentIndex = 1
        s.restEnd = nil
        let state = WorkoutActivityController.content(for: s)
        #expect(state.exercise == "Dips")
        #expect(state.setIndex == 1 && state.setTotal == 1)
        #expect(state.last == "20 × 10")
        #expect(state.next == "20 × 10")
        #expect(state.restEnd == nil && state.restInterval == nil)
        #expect(state.heartRate == nil)
    }

    @Test func watchSetsCountTowardTotals() {
        var s = session()
        s.watchSets = [logged("dips", 20, 10, at: 12)]
        let state = WorkoutActivityController.content(for: s)
        #expect(state.totalSets == 4 && state.volumeKg == 1400)
    }

    @Test func finishedExerciseStaysOnItsLastSet() {
        var s = session()
        for i in s.exercises[0].rows.indices where !s.exercises[0].rows[i].isDone {
            let set = logged("bench", 82.5, 8, at: 15 + Double(i))
            s.sets.append(set)
            s.exercises[0].rows[i].loggedID = set.id
        }
        let state = WorkoutActivityController.content(for: s)
        #expect(state.setIndex == 4 && state.setTotal == 4)
        #expect(state.next == nil)
        #expect(state.last == "82.5 × 8")
    }
}
