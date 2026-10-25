import Foundation
import Testing
import VitalisKit
@testable import Vitalis

/// Records what the phone would hand to WatchConnectivity, decoded back into messages.
@MainActor final class FakeWatchChannel: PhoneWatchChannel {
    var hasWatchApp = true
    var isReachable = false
    var remainingComplicationTransfers = 1
    var lastContext: [String: Any] = [:]
    var userInfo: [WatchMessage] = []
    var complicationInfo: [[String: Any]] = []
    var contexts: [[String: Any]] = []
    var sentNow: [WatchMessage] = []
    var deliverNow = true
    var log: (String) -> Void = { _ in }

    func queueUserInfo(_ info: [String: Any]) {
        guard let message = PhoneSessionDelegate.decode(info) else { return }
        userInfo.append(message)
        log("send \(message.kind.rawValue)")
    }
    func queueComplicationInfo(_ info: [String: Any]) { complicationInfo.append(info) }
    func sendNow(_ message: [String: Any], failed: @escaping @MainActor @Sendable () -> Void) {
        if let decoded = PhoneSessionDelegate.decode(message) { sentNow.append(decoded) }
        if !deliverNow { failed() }
    }
    func replaceContext(_ context: [String: Any]) { contexts.append(context); lastContext = context }
    func queueFile(_ url: URL, metadata: [String: Any]) {}

    var acks: [WatchAck] { userInfo.compactMap { if case .ack(let a) = $0 { a } else { nil } } }
    var results: [WatchResult] { userInfo.compactMap { if case .result(let r) = $0 { r } else { nil } } }
}

@MainActor @Suite struct PhoneSessionDelegateTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_800_000)

    /// A real Outbox in a temp directory (no transport attached) stands in for `Services.send`.
    @MainActor final class Harness {
        let outbox: Outbox
        let channel = FakeWatchChannel()
        var events: [String] = []
        var liveStates: [Bool] = []
        var persistFails = false
        var bodies: [UUID: Data] = [:]
        var sessionDetail: SessionDetail?
        var fetchCalls = 0
        var clock = PhoneSessionDelegateTests.t0
        var delegate: PhoneSessionDelegate!

        init() throws {
            outbox = try Outbox(directory: temporaryDirectory())
            let deps = PhoneSessionDelegate.Dependencies(
                persist: { [unowned self] request in
                    // The ack must not have left yet when the body is being made durable.
                    self.events.append("persist (acks so far: \(self.channel.acks.count))")
                    guard !self.persistFails else { return nil }
                    return try? await self.outbox.enqueue(request)
                },
                drop: { [unowned self] id in (try? await self.outbox.drop(id: id)) ?? false },
                outbox: { [unowned self] in (await self.outbox.pendingItems, await self.outbox.failedItems) },
                deliveredBody: { [unowned self] id in self.bodies[id] },
                fetchSession: { [unowned self] _ in
                    self.fetchCalls += 1
                    guard let detail = self.sessionDetail else { throw APIError.transport(URLError(.notConnectedToInternet)) }
                    return detail
                },
                setWatchLive: { [unowned self] in self.liveStates.append($0) },
                stateURL: temporaryDirectory().appendingPathComponent("watch-relay.json"),
                retryEvery: nil,
                now: { [unowned self] in self.clock })
            delegate = PhoneSessionDelegate(deps: deps)
            delegate.channel = channel
            channel.log = { [unowned self] in self.events.append($0) }
        }

        /// The server accepts everything queued; 2xx bodies are kept the way an Outbox delivery hook would.
        func serverAccepts(_ body: String = "{}") async {
            let result = await outbox.flush(using: FakeTransport([.status(200, body), .status(200, body), .status(200, body)]))
            for d in result.delivered { bodies[d.item.id] = d.body }
        }

        func pendingUpserts() async throws -> [WorkoutUpsert] {
            try await outbox.pendingItems.map { try APICoding.decoder().decode(WorkoutUpsert.self, from: Data(($0.body ?? "").utf8)) }
        }
    }

    static func record(revision: Int = 3, ended: Bool = false, extraSet: Bool = false) -> WorkoutSessionRecord {
        var sets = [LoggedSet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, exerciseID: "barbell-squat", kind: .warmup,
                              weightKg: 60, reps: 8, performedAt: t0.addingTimeInterval(60)),
                    LoggedSet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, exerciseID: "barbell-squat",
                              weightKg: 100, reps: 6, performedAt: t0.addingTimeInterval(240)),
                    LoggedSet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!, exerciseID: "leg-press",
                              weightKg: nil, reps: nil, performedAt: t0.addingTimeInterval(600), deleted: true)]
        if extraSet {
            sets.append(LoggedSet(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!, exerciseID: "barbell-squat",
                                  weightKg: 100, reps: 6, performedAt: t0.addingTimeInterval(420)))
        }
        return WorkoutSessionRecord(id: UUID(uuidString: "5A0E9C2F-0000-4000-8000-000000000001")!, title: "Legs", template: "legs",
                                    startedAt: t0, endedAt: ended ? t0.addingTimeInterval(3600) : nil, tzOffsetMin: 330, sets: sets,
                                    delivery: .sentToPhone, revision: revision, exerciseIDs: ["barbell-squat", "leg-press"])
    }

    @Test func ackIsSentOnlyAfterTheSessionIsPersistedAndCarriesItsRevision() async throws {
        let h = try Harness()
        let record = Self.record(revision: 3)
        await h.delegate.handle(.session(record))

        #expect(h.events == ["persist (acks so far: 0)", "send ack"])
        let ack = try #require(h.channel.acks.first)
        #expect(ack.sessionID == record.id && ack.revision == 3)
        #expect(ack.setIDs == record.sets.map(\.id), "deleted sets are listed too, or the Watch never marks the session acked")
        let queued = try await h.pendingUpserts()
        #expect(queued.count == 1)
        #expect(queued.first?.session.clientId == record.id.uuidString && queued.first?.session.source == "watch")
        #expect(queued.first?.sets.map(\.id) == record.sets.map(\.id.uuidString))
    }

    @Test func noAckWhenTheOutboxCannotStoreItThenAckOnRetry() async throws {
        let h = try Harness()
        h.channel.hasWatchApp = false
        h.persistFails = true
        await h.delegate.handle(.session(Self.record()))
        #expect(h.channel.acks.isEmpty)
        #expect(await h.outbox.pendingCount == 0)

        h.persistFails = false
        await h.delegate.wake()
        #expect(h.channel.acks.map(\.revision) == [3])
        #expect(await h.outbox.pendingCount == 1)
    }

    @Test func duplicateSessionIsIdempotent() async throws {
        let h = try Harness()
        let record = Self.record(revision: 3)
        await h.delegate.handle(.session(record))
        await h.delegate.handle(.session(record))

        #expect(h.events.filter { $0.hasPrefix("persist") }.count == 1, "a replay is not queued twice")
        #expect(h.channel.acks.count == 2 && h.channel.acks[0] == h.channel.acks[1], "but it is acked again")
        let queued = try await h.pendingUpserts()
        #expect(queued.count == 1 && queued[0] == record.upsert, "same client ids: the server upserts the same rows")
    }

    @Test func newerRevisionReplacesTheUnsentBody() async throws {
        let h = try Harness()
        await h.delegate.handle(.session(Self.record(revision: 3)))
        await h.delegate.handle(.session(Self.record(revision: 4, extraSet: true)))

        let queued = try await h.pendingUpserts()
        #expect(queued.count == 1, "latest wins")
        #expect(queued.first?.sets.count == 4)
        #expect(h.channel.acks.map(\.revision) == [3, 4])
    }

    @Test func olderRevisionIsNotQueuedAfterANewerOne() async throws {
        let h = try Harness()
        await h.delegate.handle(.session(Self.record(revision: 4, extraSet: true)))
        await h.delegate.handle(.session(Self.record(revision: 3)))

        let queued = try await h.pendingUpserts()
        #expect(queued.count == 1 && queued.first?.sets.count == 4)
        #expect(h.channel.acks.map(\.revision) == [4, 4], "the replay is answered with what the phone holds")
    }

    @Test func watchSetsHeldCountsUnsentSetsUntilTheServerTakesThem() async throws {
        let h = try Harness()
        await h.delegate.handle(.session(Self.record(revision: 3)))
        #expect(h.delegate.watchSetsHeld == 2, "the soft-deleted set is not held")

        await h.delegate.handle(.session(Self.record(revision: 4, extraSet: true)))
        #expect(h.delegate.watchSetsHeld == 3)

        await h.serverAccepts()
        await h.delegate.checkDeliveries()
        #expect(h.delegate.watchSetsHeld == 0)
    }

    @Test func heldSetsIgnoresPhoneWorkoutsAndOtherWrites() async throws {
        let outbox = try Outbox(directory: temporaryDirectory())
        var phone = Self.record().upsert
        phone.session.source = "phone"
        phone.session.clientId = UUID().uuidString
        try await outbox.enqueue(.postWorkout(phone))
        try await outbox.enqueue(APIRequest(method: "POST", path: "v2/weight", body: Data(#"{"kg":76.6}"#.utf8)))
        try await outbox.enqueue(.postWorkout(Self.record().upsert))
        try await outbox.enqueue(.postWorkout(Self.record(revision: 4, extraSet: true).upsert))
        #expect(PhoneSessionDelegate.heldSets(in: await outbox.pendingItems) == 3, "only the latest Watch body per session counts")
    }

    @Test func resultIsRelayedFromTheServerResponseOnceTheEndedSessionIsAccepted() async throws {
        let h = try Harness()
        await h.delegate.handle(.session(Self.record(revision: 3)))
        await h.serverAccepts(String(decoding: try Fixture.data("workouts-post"), as: UTF8.self))
        await h.delegate.checkDeliveries()
        #expect(h.channel.results.isEmpty, "mid-workout upserts don't relay a result")

        await h.delegate.handle(.session(Self.record(revision: 5, ended: true)))
        #expect(h.channel.results.isEmpty, "not before the server answered")
        await h.serverAccepts(String(decoding: try Fixture.data("workouts-post"), as: UTF8.self))
        await h.delegate.checkDeliveries()

        let response = try Fixture.decode(WorkoutPostResponse.self, "workouts-post")
        let result = try #require(h.channel.results.first)
        #expect(result.sessionID == Self.record().id)
        #expect(result.heat == response.session.heat && result.prs == response.prs)
        await h.delegate.checkDeliveries()
        #expect(h.channel.results.count == 1, "relayed once")
    }

    @Test func resultFallsBackToTheSessionDetailWithoutInventingPRs() async throws {
        let h = try Harness()
        let detail = try Fixture.decode(SessionDetail.self, "training-session")
        h.sessionDetail = detail
        await h.delegate.handle(.session(Self.record(revision: 5, ended: true)))
        await h.serverAccepts()
        h.bodies = [:]
        await h.delegate.checkDeliveries()

        let result = try #require(h.channel.results.first)
        #expect(result.heat == detail.heat && result.prs.isEmpty)
        #expect(result.durationMin == detail.durationMin && result.workingSets == detail.workingSets)
    }

    @Test func unreadableServerAnswerBacksOffThenGivesUp() async throws {
        let h = try Harness()
        await h.delegate.handle(.session(Self.record(revision: 5, ended: true)))
        await h.serverAccepts()
        h.bodies = [:]
        await h.delegate.checkDeliveries()
        await h.delegate.checkDeliveries()
        #expect(h.fetchCalls == 1, "the second check is inside the backoff window")

        for _ in 0..<10 {
            h.clock = h.clock.addingTimeInterval(601)
            await h.delegate.checkDeliveries()
        }
        #expect(h.fetchCalls == PhoneSessionDelegate.maxResultAttempts)
        #expect(h.delegate.relays.values.allSatisfy { !$0.awaitingResult })
        #expect(h.channel.results.isEmpty)
    }

    @Test func watchStateDisablesPhoneLogging() async throws {
        let h = try Harness()
        let id = Self.record().id
        await h.delegate.handle(.sessionState(WatchSessionState(sessionID: id, state: .live)))
        await h.delegate.handle(.session(Self.record(revision: 5, ended: true)))
        #expect(h.liveStates == [true, false], "an ended session also re-enables the phone when sendMessage was missed")
    }

    @Test func oneContextCarriesPackParkedPlanAndToday() async throws {
        let h = try Harness()
        h.delegate.publish(pack: try WatchMessagesTests.pack())
        h.delegate.sendPlan(WatchPlan(template: "legs", exerciseIDs: ["barbell-squat"]))
        #expect(h.channel.sentNow.isEmpty, "not reachable: the plan rides in the pack")

        h.channel.remainingComplicationTransfers = 0
        let today = TodaySnapshot(try Fixture.decode(TodayResponse.self, "today"))
        h.delegate.sendToday(today)

        let context = try #require(h.channel.contexts.last)
        #expect(ComplicationTransfer.snapshot(from: context) == today)
        guard case .pack(let pack)? = PhoneSessionDelegate.decode(PhoneSessionDelegate.contextWithoutToday(context)) else {
            Issue.record("context has no pack"); return
        }
        #expect(pack.splits.first?.template == "legs" && pack.plan?.exerciseIDs == ["barbell-squat"])
    }

    @Test func reachablePlanGoesStraightToTheWatch() async throws {
        let h = try Harness()
        h.channel.isReachable = true
        h.delegate.sendPlan(WatchPlan(template: "push", exerciseIDs: ["barbell-bench-press-medium-grip"]))
        #expect(h.channel.sentNow == [.plan(WatchPlan(template: "push", exerciseIDs: ["barbell-bench-press-medium-grip"]))])
        #expect(h.channel.contexts.isEmpty)

        h.channel.deliverNow = false
        h.delegate.sendPlan(WatchPlan(template: "pull", exerciseIDs: ["pullups"]))
        #expect(h.channel.contexts.count == 1, "a failed sendMessage parks the plan in the pack")
    }
}
