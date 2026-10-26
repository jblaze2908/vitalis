import Foundation
import Testing
import VitalisKit
@testable import Vitalis

/// The detail screens' server bodies decode with every field the screens read (snake-case keys like `best_e1rm_kg` map by hand).
@Suite struct ExploreDecodingTests {
    @Test func heartDay() throws {
        let h = try Fixture.decode(HeartDay.self, "heart")
        #expect(h.points.count == 288 && h.bucketMin == 5)
        #expect(h.summary.maxAt != nil && h.summary.resting?.usualRange?.count == 2)
        #expect(h.workouts.first?.startM == 540)
    }

    @Test func metricsAndHistory() throws {
        let o = try Fixture.decode(MetricsOverview.self, "metrics")
        #expect(o.groups.map(\.name).prefix(4) == ["Heart", "Sleep", "Activity", "Body"])
        #expect(o.groups[0].metrics.first?.spark.count == 14)
        let m = try Fixture.decode(MetricHistory.self, "metric")
        #expect(m.key == "resting_hr" && m.days == 30 && m.usual != nil && m.daysWithData == m.points.count)
    }

    @Test func exercisesAndHistory() throws {
        let e = try Fixture.decode(PerformedExercises.self, "training-exercises")
        let first = try #require(e.exercises.first)
        #expect(first.bestE1rmKg != nil && first.e1rmKg != nil && first.change8wKg != nil && first.lastTop?.weightKg != nil)
        let d = try Fixture.decode(ExerciseDetail.self, "exercise-history")
        #expect((d.history?.count ?? 0) > 1 && d.history?.first?.e1rmKg != nil && d.history?.first?.volumeKg != nil)
    }

    @Test func workoutHeartAndSetTimes() throws {
        let s = try Fixture.decode(SessionDetail.self, "training-session-hr")
        let hr = try #require(s.hr)
        #expect(hr.points.count > 10 && hr.min <= hr.avg && hr.avg <= hr.max && hr.start != nil)
        #expect(s.exercises?.flatMap(\.sets).allSatisfy { $0.at != nil } == true)
    }

    @Test func visitRowAndParts() throws {
        let row = try APICoding.decoder().decode(SessionRow.self, from: Data(#"{"id":"w1","kind":"cardio","title":"walking · elliptical","day":"2026-10-14","start":"2026-10-14T19:10:29+05:30","duration_min":39,"hr_avg":162,"part_count":2,"parts":["walking","elliptical"],"tag":null}"#.utf8))
        #expect(row.partCount == 2)
        let part = try APICoding.decoder().decode(SessionDetail.Part.self, from: Data(#"{"id":"w1","kind":"cardio","title":"walking","start":"2026-10-14T19:10:29+05:30","end":"2026-10-14T19:15:33+05:30","duration_min":5,"hr_avg":165.7,"hr_max":180,"active_kcal":57,"distance_km":null,"working_sets":null}"#.utf8))
        #expect(part.durationMin == 5 && part.activeKcal == 57 && part.distanceKm == nil)
        #expect(WorkoutCopy.name("walking · elliptical") == "Walking · Elliptical")
    }

    @Test func launchPathParsesOnlyItsTab() {
        UserDefaults.standard.set("body/metric/hrv", forKey: "VitalisDetail")
        defer { UserDefaults.standard.removeObject(forKey: "VitalisDetail") }
        #expect(Detail.launchPath("body") == [.metric(key: "hrv")])
        #expect(Detail.launchPath("train").isEmpty)
    }

    @Test func workoutNamesReadAsWords() {
        #expect(WorkoutCopy.name("traditionalStrengthTraining") == "Traditional strength training")
        #expect(WorkoutCopy.name("running") == "Running")
    }
}
