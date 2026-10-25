import Foundation
import Testing
import VitalisKit

@Suite struct WatchSessionStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_792_800_000)

    private func record(startedAt: Date, sets: Int = 2, ended: Bool = false) -> WorkoutSessionRecord {
        WorkoutSessionRecord(title: "Legs", template: "legs", startedAt: startedAt, endedAt: ended ? startedAt.addingTimeInterval(3600) : nil,
                             tzOffsetMin: 330,
                             sets: (0..<sets).map { i in
                                 LoggedSet(exerciseID: "barbell-squat", weightKg: 97.5 + Double(i) * 2.5, reps: 6,
                                           performedAt: startedAt.addingTimeInterval(Double(i) * 180))
                             },
                             exerciseIDs: ["barbell-squat", "leg-press"])
    }

    @Test func saveThenReloadInAFreshStoreIsIdentical() throws {
        let root = temporaryDirectory()
        let r = record(startedAt: t0)
        try WatchSessionStore(root: root).save(r)
        let reopened = try WatchSessionStore(root: root)
        #expect(reopened.load(r.id) == r)
        #expect(reopened.all() == [r])
    }

    @Test func atomicOverwriteLeavesOnlyTheNewCopy() throws {
        let root = temporaryDirectory()
        let store = try WatchSessionStore(root: root)
        var r = record(startedAt: t0)
        try store.save(r)
        r.sets.append(LoggedSet(exerciseID: "barbell-squat", weightKg: 102.5, reps: 5, performedAt: t0.addingTimeInterval(600)))
        r.revision += 1
        try store.save(r)
        #expect(store.load(r.id)?.sets.count == 3)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path)
        #expect(files == ["\(r.id.uuidString).json"])
    }

    @Test func recoveryFindsTheLiveSessionAndSkipsCorruptFiles() throws {
        let root = temporaryDirectory()
        let store = try WatchSessionStore(root: root)
        let old = record(startedAt: t0, ended: true)
        let live = record(startedAt: t0.addingTimeInterval(86_400), sets: 3)
        try store.save(old)
        try store.save(live)
        // A torn or foreign file must not hide the live session (and must not be deleted).
        let junk = root.appendingPathComponent("sessions/\(UUID().uuidString).json")
        try Data("{\"id\":".utf8).write(to: junk)

        let recovered = try #require(try WatchSessionStore(root: root).liveSession())
        #expect(recovered.id == live.id)
        #expect(recovered.sets.count == 3)
        #expect(FileManager.default.fileExists(atPath: junk.path))
        #expect(store.all().map(\.id) == [live.id, old.id])
    }

    @Test func ackMarksDeliveredOnlyForTheCurrentRevisionAndAllSets() throws {
        let store = try WatchSessionStore(root: temporaryDirectory())
        var r = record(startedAt: t0)
        r.revision = 3
        try store.save(r)

        try store.markSent(r.id, revision: 2)
        #expect(store.load(r.id)?.delivery == .pending)
        try store.markSent(r.id, revision: 3)
        #expect(store.load(r.id)?.delivery == .sentToPhone)

        try store.applyAck(WatchAck(sessionID: r.id, setIDs: r.sets.map(\.id), revision: 2))
        #expect(store.load(r.id)?.delivery == .sentToPhone)
        try store.applyAck(WatchAck(sessionID: r.id, setIDs: [r.sets[0].id], revision: 3))
        #expect(store.load(r.id)?.delivery == .sentToPhone)
        try store.applyAck(WatchAck(sessionID: r.id, setIDs: r.sets.map(\.id), revision: 3))
        #expect(store.load(r.id)?.delivery == .ackedByPhone)
        #expect(store.undelivered().isEmpty)
    }

    @Test func pruneDeletesOnlyOldAckedEndedSessions() throws {
        let store = try WatchSessionStore(root: temporaryDirectory())
        var ackedOld = record(startedAt: t0, ended: true); ackedOld.delivery = .ackedByPhone
        var ackedRecent = record(startedAt: t0.addingTimeInterval(13 * 86_400), ended: true); ackedRecent.delivery = .ackedByPhone
        var unackedOld = record(startedAt: t0.addingTimeInterval(-30 * 86_400), ended: true); unackedOld.delivery = .sentToPhone
        var liveOld = record(startedAt: t0.addingTimeInterval(-30 * 86_400)); liveOld.delivery = .ackedByPhone
        for r in [ackedOld, ackedRecent, unackedOld, liveOld] { try store.save(r) }

        let deleted = store.prune(now: t0.addingTimeInterval(16 * 86_400))
        #expect(deleted == [ackedOld.id])
        #expect(Set(store.all().map(\.id)) == [ackedRecent.id, unackedOld.id, liveOld.id])
        #expect(store.undelivered().map(\.id) == [unackedOld.id])
    }

    @Test func packPersistsForOfflineLaunch() throws {
        let root = temporaryDirectory()
        let pack = WatchPack(generatedAt: "2026-10-24T09:41:02+05:30", settings: .init(restS: 90, crownStepKg: 1.25),
                             splits: [.init(id: "legs", template: "legs", name: "Legs", ready: true, daysSince: 6, exerciseIDs: ["barbell-squat"])])
        #expect(try WatchSessionStore(root: root).loadPack() == nil)
        try WatchSessionStore(root: root).savePack(pack)
        #expect(try WatchSessionStore(root: root).loadPack() == pack)
    }
}
