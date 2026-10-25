import Foundation
import Testing
import VitalisKit

@Suite struct WatchMessagesTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_800_000)

    /// The spec 21 §6 sample with `splits` (11 §7.3) in place of `due`: the phone's pack builder (W-02) must emit these keys.
    static let specPack = """
    {
      "generated_at": "2026-10-24T09:41:02+05:30",
      "settings": { "rest_s": 120, "crown_step_kg": 2.5 },
      "splits": [ { "id": "legs", "template": "legs", "name": "Legs", "ready": true, "days_since": 6, "exercise_ids": ["barbell-squat", "romanian-deadlift", "leg-press", "lying-leg-curls", "standing-calf-raises"] },
                  { "id": "upper", "template": null, "name": "Upper", "ready": false, "days_since": 1, "exercise_ids": ["barbell-bench-press-medium-grip"] } ],
      "recent_sessions": [ { "title": "Push", "template": "push", "day": "2026-10-22", "exercise_ids": ["barbell-bench-press-medium-grip"] } ],
      "exercises": {
        "barbell-squat": { "name": "Barbell Squat", "primary": ["quadriceps"], "secondary": ["calves","glutes","hamstrings","lower-back"],
                           "prefill": { "sets": [ { "kind": "normal", "weight_kg": 97.5, "reps": 6 } ], "next": { "weight_kg": 100, "reps": 6, "sets": 4 } } }
      },
      "recent_exercise_ids": ["barbell-squat"]
    }
    """

    static func pack() throws -> WatchPack {
        try WatchCoding.decoder().decode(WatchPack.self, from: Data(specPack.utf8))
    }

    static func pr() throws -> WorkoutPostResponse.PR {
        let json = #"{"exercise_id":"barbell-squat","exercise":"Barbell Squat","set":"100 kg × 6","e1rm_kg_estimate":120,"previous_best_estimate":116.7}"#
        return try APICoding.decoder().decode(WorkoutPostResponse.PR.self, from: Data(json.utf8))
    }

    static func record() -> WorkoutSessionRecord {
        WorkoutSessionRecord(title: "Legs", template: "legs", startedAt: t0, endedAt: t0.addingTimeInterval(3660), tzOffsetMin: 330,
                             hkWorkoutUUID: UUID(),
                             sets: [LoggedSet(exerciseID: "barbell-squat", kind: .warmup, weightKg: 60, reps: 8, performedAt: t0.addingTimeInterval(60)),
                                    LoggedSet(exerciseID: "barbell-squat", weightKg: 100, reps: 6, performedAt: t0.addingTimeInterval(240.5)),
                                    LoggedSet(exerciseID: "leg-press", weightKg: nil, reps: nil, performedAt: t0.addingTimeInterval(600), deleted: true)],
                             delivery: .sentToPhone, revision: 4, exerciseIDs: ["barbell-squat", "leg-press"])
    }

    static func allMessages() throws -> [WatchMessage] {
        let snapshot = TodaySnapshot(day: "2026-10-24", verdict: .init(band: "good", label: "Ready", headline: "Train legs"),
                                     recovery: .init(score: 82, band: "good"), steps: 3206, stepsTarget: 8000, kcalLeft: 640,
                                     proteinG: 92, proteinTargetG: nil, pulse: nil, lastSync: "2026-10-24T09:39:00+05:30",
                                     generatedAt: "2026-10-24T09:41:02+05:30")
        return [
            .session(record()),
            .ack(WatchAck(sessionID: UUID(), setIDs: [UUID(), UUID()], revision: 4)),
            .result(WatchResult(sessionID: UUID(), heat: ["quadriceps": 4, "lower-back": 2, "glutes": 3], prs: [try pr()],
                                durationMin: 61, workingSets: 16)),
            .result(WatchResult(sessionID: UUID(), heat: [:], prs: [])),
            .pack(try pack()),
            .pack(WatchPack(generatedAt: "2026-10-24T09:41:02+05:30", plan: WatchPlan(template: nil, exerciseIDs: ["leg-press"]))),
            .catalog(WatchCatalogInfo(etag: "W/\"abc\"", count: 873)),
            .plan(WatchPlan(title: "Legs", template: "legs", exerciseIDs: ["barbell-squat", "leg-press"], intensity: "hard")),
            .sessionState(WatchSessionState(sessionID: UUID(), state: .live)),
            .sessionState(WatchSessionState(sessionID: UUID(), state: .ended)),
            .today(snapshot),
        ]
    }

    @Test func everyKindIsCovered() throws {
        #expect(Set(try Self.allMessages().map(\.kind)) == Set(WatchMessage.Kind.allCases))
    }

    @Test func everyMessageRoundTripsThroughJSON() throws {
        for message in try Self.allMessages() {
            let data = try WatchCoding.encoder().encode(message)
            #expect(try WatchCoding.decoder().decode(WatchMessage.self, from: data) == message, "\(message.kind)")
        }
    }

    @Test func everyMessageRoundTripsAsAPropertyListDictionary() throws {
        for message in try Self.allMessages() {
            let dict = try message.dictionary()
            #expect(dict["type"] as? String == message.kind.rawValue)
            // WatchConnectivity only accepts property-list values (no NSNull).
            #expect(PropertyListSerialization.propertyList(dict, isValidFor: .binary), "\(message.kind)")
            #expect(try WatchMessage(dictionary: dict) == message, "\(message.kind)")
        }
    }

    @Test func wireKeysAreSnakeCase() throws {
        let json = try #require(String(data: try WatchCoding.encoder().encode(WatchMessage.session(Self.record())), encoding: .utf8))
        for key in ["\"exercise_id\"", "\"hk_workout_uuid\"", "\"performed_at\"", "\"started_at\"", "\"tz_offset_min\"", "\"weight_kg\""] {
            #expect(json.contains(key), "\(key)")
        }
        #expect(json.contains("\"type\":\"session\""))
    }

    @Test func specPackSampleDecodes() throws {
        let pack = try Self.pack()
        #expect(pack.settings.rest == 120)
        #expect(pack.settings.crownStep == 2.5)
        #expect(pack.settings.suggests)
        #expect(pack.splits.map(\.name) == ["Legs", "Upper"])
        #expect(pack.splits.first?.daysSince == 6 && pack.splits.first?.exerciseIDs.count == 5)
        let upper = try #require(pack.splits.last)
        #expect(upper.template == nil && !upper.ready)
        #expect(pack.recentSessions.first?.exerciseIDs == ["barbell-bench-press-medium-grip"])
        let squat = try #require(pack.exercises["barbell-squat"])
        #expect(squat.secondary.contains("lower-back"))
        #expect(squat.prefill?.next?.weightKg == 100)
        #expect(pack.recentExerciseIDs == ["barbell-squat"])
    }

    @Test func packFromAnOlderPhoneHasNoSplits() throws {
        let json = #"{"generated_at":"2026-10-24T09:41:02+05:30","due":{"template":"legs","name":"Legs","days_since":6,"exercise_ids":[]}}"#
        let pack = try WatchCoding.decoder().decode(WatchPack.self, from: Data(json.utf8))
        #expect(pack.splits.isEmpty, "the old due block is ignored, not promoted to a split")
    }

    @Test func settingsFallBackToDefaults() {
        let s = WatchPack.Settings(restS: 0, crownStepKg: nil)
        #expect(s.rest == 120)
        #expect(s.crownStep == 2.5)
        #expect(WatchPack.Settings(crownStepKg: 1.25).crownStep == 1.25)
    }

    @Test func prefillPicksTheServersValues() throws {
        let squat = try #require(try Self.pack().exercises["barbell-squat"])
        #expect(squat.plannedSets(suggests: true) == 4)
        #expect(squat.plannedSets(suggests: false) == 1)
        #expect(squat.firstSet(suggests: true)?.weightKg == 100)
        #expect(squat.firstSet(suggests: false)?.weightKg == 97.5)
        #expect(squat.lastWeight(setNumber: 1) == 97.5)
        #expect(squat.lastWeight(setNumber: 2) == nil)

        let fresh = WatchPack.Exercise(name: "Leg Press", primary: ["quadriceps"], secondary: [])
        #expect(fresh.plannedSets(suggests: true) == 3)
        #expect(fresh.firstSet(suggests: true) == nil)

        let warmFirst = WatchPack.Exercise(name: "Squat", primary: [], secondary: [], prefill: .init(
            sets: [.init(kind: "warmup", weightKg: 60, reps: 8), .init(weightKg: 95, reps: 8)], next: nil))
        #expect(warmFirst.firstSet(suggests: true)?.weightKg == 95)
        #expect(warmFirst.lastWeight(setNumber: 1) == 95)
        #expect(warmFirst.plannedSets(suggests: true) == 1)
    }

    @Test func recordMapsToTheWorkoutUpsertBody() throws {
        let r = Self.record()
        let body = r.upsert
        #expect(body.session.clientId == r.id.uuidString)
        #expect(body.session.source == "watch")
        #expect(body.session.startedAt == "2026-10-24T05:30:00+05:30")
        #expect(body.session.hkWorkoutUuid == r.hkWorkoutUUID?.uuidString)
        #expect(body.sets.count == 3)
        #expect(body.sets[0].kind == "warmup")
        #expect(body.sets[1].weightKg == 100)
        #expect(body.sets[2] == .deletion(r.sets[2].id.uuidString))
    }

    @Test func olderSessionFilesWithoutRevisionStillDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Legs","source":"watch","started_at":"2026-10-24T09:30:00+05:30",
         "tz_offset_min":330,"sets":[],"delivery":"pending"}
        """
        let r = try WatchCoding.decoder().decode(WorkoutSessionRecord.self, from: Data(json.utf8))
        #expect(r.revision == 0)
        #expect(r.exerciseIDs.isEmpty)
        #expect(r.isLive)
    }
}
