import Foundation
import Observation
import UIKit
import VitalisKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// The phone's WatchConnectivity surface, so the relay runs in tests without a paired Watch.
@MainActor protocol PhoneWatchChannel: AnyObject {
    /// Activated, paired, and the Watch app installed.
    var hasWatchApp: Bool { get }
    var isReachable: Bool { get }
    var remainingComplicationTransfers: Int { get }
    /// The application context this phone last sent (survives relaunch).
    var lastContext: [String: Any] { get }
    func queueUserInfo(_ info: [String: Any])
    func queueComplicationInfo(_ info: [String: Any])
    /// `sendMessage`; `failed` runs when it couldn't be delivered.
    func sendNow(_ message: [String: Any], failed: @escaping @MainActor @Sendable () -> Void)
    func replaceContext(_ context: [String: Any])
    func queueFile(_ url: URL, metadata: [String: Any])
}

/// Watch ⇄ phone relay (spec 21 §6): Watch sessions go into the Outbox first, then `ack`; once the server has the
/// ended session, its heat and PRs go back as `result`. Also owns the one application context (pack + plan + today).
@MainActor @Observable
final class PhoneSessionDelegate {
    /// What the phone holds for one Watch session; persisted so latest-wins and `result` survive a relaunch.
    struct Relay: Codable, Equatable, Sendable {
        var outboxID: UUID
        var revision: Int
        var setIDs: [UUID]
        var ended: Bool
        var awaitingResult: Bool
        var updatedAt: Date
        /// Failed attempts to read the server's answer, and when to try next (Outbox backoff, then give up).
        var resultAttempts = 0
        var nextResultCheck: Date?
    }

    struct Dependencies {
        /// Durably queues the write; nil when it couldn't be stored (then no `ack`).
        var persist: @MainActor (APIRequest) async -> UUID?
        var drop: @MainActor (UUID) async -> Bool
        var outbox: @MainActor () async -> (pending: [Outbox.Item], failed: [Outbox.Item])
        /// The 2xx body for a delivered item when the Outbox reported it; nil falls back to refetching the session.
        var deliveredBody: @MainActor (UUID) async -> Data? = { _ in nil }
        var fetchSession: @MainActor (String) async throws -> SessionDetail
        var setWatchLive: @MainActor (Bool) -> Void
        var stateURL: URL?
        /// Re-check undelivered results this often while any are outstanding; nil in tests.
        var retryEvery: Duration?
        var now: @MainActor () -> Date = { Date() }
    }

    static let shared = PhoneSessionDelegate(deps: .live)
    static let relayRetention: TimeInterval = 14 * 24 * 3600
    /// A plan parked in the pack is dropped after this, so a stale start choice never launches a later workout.
    static let planLifetime: TimeInterval = 3600
    /// Reads of the server's answer before the summary is left on catalog lighting.
    static let maxResultAttempts = 6

    /// Sets in Watch `POST /v2/workouts` bodies not yet sent (the token-rejected screen's `WATCH SETS HELD`).
    private(set) var watchSetsHeld = 0

    @ObservationIgnored var channel: (any PhoneWatchChannel)?
    @ObservationIgnored private(set) var relays: [UUID: Relay]
    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var unpersisted: [UUID: WorkoutSessionRecord] = [:]
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pack: WatchPack?
    @ObservationIgnored private var today: TodaySnapshot?
    @ObservationIgnored private var parkedPlan: (plan: WatchPlan, at: Date)?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var recheck = false
    /// `POST /v2/workouts` 2xx bodies for relayed sessions, fed by `noteDelivery` (needs the Outbox delivery hook).
    @ObservationIgnored private(set) var deliveredBodies: [UUID: Data] = [:]
    @ObservationIgnored private var deliveredOrder: [UUID] = []
    #if canImport(WatchConnectivity)
    @ObservationIgnored private let bridge = PhoneWCBridge()
    #endif

    init(deps: Dependencies) {
        self.deps = deps
        relays = deps.stateURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? Self.coder.decoder.decode([UUID: Relay].self, from: $0) } ?? [:]
    }

    // MARK: Activation

    /// Called once at launch (AppDelegate) so queued Watch transfers are delivered to a live delegate.
    func activate() {
        #if canImport(WatchConnectivity)
        guard channel == nil, WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = bridge
        channel = LiveWatchChannel(session: session)
        session.activate()
        Task { await Services.shared.outbox?.setOnDelivered { d in Task { @MainActor in PhoneSessionDelegate.shared.noteDelivery(d) } } }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await PhoneSessionDelegate.shared.wake() } }
        }
        #endif
    }

    /// Activation, Watch state change or foreground: retry what's held and refresh the pack.
    func wake() async {
        seedPack()
        for record in unpersisted.values { await handle(.session(record)) }
        await checkDeliveries()
        guard channel?.hasWatchApp == true else { return }
        await WatchPackSender.shared.refresh()
    }

    // MARK: Inbound

    /// Messages are handled one at a time, in arrival order, so an older revision never overtakes a newer one.
    func handle(_ message: WatchMessage) async {
        let previous = tail
        let task = Task { await previous?.value; await self.process(message) }
        tail = task
        await task.value
    }

    private func process(_ message: WatchMessage) async {
        switch message {
        case .session(let record): await receive(record)
        case .sessionState(let state): deps.setWatchLive(state.state == .live)
        default: break
        }
    }

    private func receive(_ record: WorkoutSessionRecord) async {
        // `sendMessage` is best effort, so the session itself also says whether the Watch is logging.
        deps.setWatchLive(record.isLive)
        parkedPlan = nil
        if let known = relays[record.id], known.revision >= record.revision {
            sendAck(record.id, relay: known)
            return
        }
        guard let request = try? APIRequest.postWorkout(record.upsert), let outboxID = await deps.persist(request) else {
            unpersisted[record.id] = record
            return
        }
        unpersisted[record.id] = nil
        let replaced = relays[record.id]?.outboxID
        let relay = Relay(outboxID: outboxID, revision: record.revision, setIDs: record.sets.map(\.id),
                          ended: !record.isLive, awaitingResult: !record.isLive, updatedAt: deps.now())
        relays[record.id] = relay
        saveRelays()
        sendAck(record.id, relay: relay)
        // Latest wins: the older body is redundant once the newer one is durable. In flight → the server upserts it.
        if let replaced, replaced != outboxID { _ = await deps.drop(replaced) }
        await checkDeliveries()
    }

    /// `set_ids` covers every set, soft-deleted ones included: the Watch only marks the session acked when all are listed.
    private func sendAck(_ sessionID: UUID, relay: Relay) {
        send(.ack(WatchAck(sessionID: sessionID, setIDs: relay.setIDs, revision: relay.revision)))
    }

    // MARK: Server answers

    /// Runs after each relayed session, on wake, and every `retryEvery` while a result is outstanding; reads the
    /// Outbox's in-memory queue and decodes its few workout bodies, no network unless a result is due.
    func checkDeliveries() async {
        // One pass at a time, so a result is never sent twice; a call during a pass asks for one more.
        guard !checking else { recheck = true; return }
        checking = true
        defer { checking = false }
        repeat {
            recheck = false
            await checkOnce()
        } while recheck
    }

    private func checkOnce() async {
        let (pending, failed) = await deps.outbox()
        watchSetsHeld = Self.heldSets(in: pending)
        let pendingIDs = Set(pending.map(\.id)), failedIDs = Set(failed.map(\.id))
        var relayed = false
        let now = deps.now()
        for (sessionID, relay) in relays where relay.awaitingResult && !pendingIDs.contains(relay.outboxID) {
            if failedIDs.contains(relay.outboxID) {
                relays[sessionID]?.awaitingResult = false
                continue
            }
            if let due = relay.nextResultCheck, due > now { continue }
            guard let result = await result(for: sessionID, outboxID: relay.outboxID) else {
                guard relays[sessionID]?.outboxID == relay.outboxID else { continue }
                let attempts = relay.resultAttempts + 1
                relays[sessionID]?.resultAttempts = attempts
                relays[sessionID]?.nextResultCheck = now.addingTimeInterval(Outbox.backoff[min(attempts, Outbox.backoff.count) - 1])
                if attempts >= Self.maxResultAttempts { relays[sessionID]?.awaitingResult = false }
                continue
            }
            send(.result(result))
            relayed = true
            deliveredBodies[relay.outboxID] = nil
            if relays[sessionID]?.outboxID == relay.outboxID { relays[sessionID]?.awaitingResult = false }
        }
        let cutoff = deps.now().addingTimeInterval(-Self.relayRetention)
        relays = relays.filter { $0.value.awaitingResult || $0.value.updatedAt > cutoff }
        saveRelays()
        scheduleRetry()
        // A finished session changes the server's prefill; the next pack should carry it.
        if relayed { WatchPackSender.shared.markStale() }
    }

    private func result(for sessionID: UUID, outboxID: UUID) async -> WatchResult? {
        if let body = await deps.deliveredBody(outboxID),
           let response = try? APICoding.decoder().decode(WorkoutPostResponse.self, from: body),
           let heat = response.session.heat {
            return WatchResult(sessionID: sessionID, heat: heat, prs: response.prs,
                               durationMin: response.session.durationMin, workingSets: response.session.workingSets)
        }
        // The session detail has no `prs` list, and a PR's e1rm can't be made up, so this path relays none.
        // The id is the `client_id` exactly as posted (`uuidString`, upper case).
        guard let detail = try? await deps.fetchSession(sessionID.uuidString), let heat = detail.heat else { return nil }
        return WatchResult(sessionID: sessionID, heat: heat, prs: [], durationMin: detail.durationMin, workingSets: detail.workingSets)
    }

    private func scheduleRetry() {
        guard let every = deps.retryEvery, retryTask == nil, relays.values.contains(where: \.awaitingResult) else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: every)
            self?.retryTask = nil
            await self?.checkDeliveries()
        }
    }

    /// Outbox 2xx for a relayed session's body (wire with `Outbox.setOnDelivered` once it exists).
    /// Kept for any workout write (the relay may not be recorded yet when the flush inside `persist` delivers it); last 10.
    func noteDelivery(_ delivery: Outbox.Delivery) {
        guard delivery.item.path.hasPrefix("v2/workouts") else { return }
        deliveredBodies[delivery.item.id] = delivery.body
        deliveredOrder.append(delivery.item.id)
        if deliveredOrder.count > 10 { deliveredBodies[deliveredOrder.removeFirst()] = nil }
    }

    /// Latest Watch body per session in the queue, non-deleted sets counted (spec 21 §6 held counts).
    nonisolated static func heldSets(in pending: [Outbox.Item]) -> Int {
        var latest: [String: Int] = [:]
        let decoder = APICoding.decoder()
        for item in pending where item.path.hasPrefix("v2/workouts") {
            guard let body = item.body, let upsert = try? decoder.decode(WorkoutUpsert.self, from: Data(body.utf8)),
                  upsert.session.source == "watch" else { continue }
            latest[upsert.session.clientId] = upsert.sets.filter { $0.deleted != true }.count
        }
        return latest.values.reduce(0, +)
    }

    // MARK: Outbound (pack, plan, today)

    func publish(pack newPack: WatchPack) {
        pack = newPack
        publishContext()
    }

    /// Start-choice plan: straight to a reachable Watch, else parked in the pack (spec 21 §6 `plan`).
    func sendPlan(_ plan: WatchPlan) {
        guard let channel, channel.hasWatchApp else { return }
        guard channel.isReachable, let message = try? WatchMessage.plan(plan).dictionary() else { park(plan); return }
        channel.sendNow(message) { [weak self] in self?.park(plan) }
    }

    private func park(_ plan: WatchPlan) {
        parkedPlan = (plan, deps.now())
        publishContext()
    }

    /// Complication data (spec 21 §3): the budgeted complication transfer, else the next application context.
    func sendToday(_ snapshot: TodaySnapshot) {
        today = snapshot
        guard let channel else { return }
        switch ComplicationTransfer.channel(isPaired: channel.hasWatchApp, isWatchAppInstalled: channel.hasWatchApp,
                                            remainingComplicationTransfers: channel.remainingComplicationTransfers) {
        case .complicationUserInfo:
            if let payload = ComplicationTransfer.payload(snapshot) { channel.queueComplicationInfo(payload) }
        case .applicationContext:
            publishContext()
        case .none:
            break
        }
    }

    /// One context, latest wins: the pack (with a parked plan) plus the newest `today`, so neither erases the other.
    private func publishContext() {
        guard let channel, channel.hasWatchApp, let context = context() else { return }
        channel.replaceContext(context)
    }

    func context() -> [String: Any]? {
        seedPack()
        guard var outgoing = pack ?? (parkedPlan != nil ? WatchPack(generatedAt: WatchPackBuilder.timestamp(deps.now())) : nil) else {
            return today.flatMap(ComplicationTransfer.payload)
        }
        if let parkedPlan, deps.now().timeIntervalSince(parkedPlan.at) < Self.planLifetime { outgoing.plan = parkedPlan.plan }
        guard var dict = try? WatchMessage.pack(outgoing).dictionary() else { return nil }
        if let today, let payload = ComplicationTransfer.payload(today) { dict.merge(payload) { _, new in new } }
        return dict
    }

    /// False when nothing was queued, so the sender retries the catalog next time.
    func queueCatalog(_ url: URL, info: WatchCatalogInfo) -> Bool {
        guard let channel, channel.hasWatchApp, let metadata = try? WatchMessage.catalog(info).dictionary() else { return false }
        channel.queueFile(url, metadata: metadata)
        return true
    }

    /// The pack this phone last sent survives relaunch in `applicationContext`; never replace it with an empty one.
    private func seedPack() {
        guard pack == nil, let last = channel?.lastContext, case .pack(let lastPack)? = Self.decode(Self.contextWithoutToday(last))
        else { return }
        pack = lastPack
    }

    private func send(_ message: WatchMessage) {
        guard let dict = try? message.dictionary() else { return }
        channel?.queueUserInfo(dict)
    }

    // MARK: Coding

    /// `JSONSerialization` raises (not throws) on non-JSON values such as the `today` Data, so check first.
    nonisolated static func decode(_ dict: [String: Any]) -> WatchMessage? {
        guard !dict.isEmpty, JSONSerialization.isValidJSONObject(dict) else { return nil }
        return try? WatchMessage(dictionary: dict)
    }

    nonisolated static func contextWithoutToday(_ dict: [String: Any]) -> [String: Any] {
        dict.filter { $0.key != ComplicationTransfer.key }
    }

    private static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }()

    private func saveRelays() {
        guard let url = deps.stateURL, let data = try? Self.coder.encoder.encode(relays) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension PhoneSessionDelegate.Dependencies {
    @MainActor static var live: Self {
        Self(
            persist: { await Services.shared.send($0) },
            drop: { await Services.shared.drop($0) },
            outbox: {
                guard let outbox = Services.shared.outbox else { return ([], []) }
                return (await outbox.pendingItems, await outbox.failedItems)
            },
            deliveredBody: { PhoneSessionDelegate.shared.deliveredBodies[$0] },
            fetchSession: { id in
                guard let api = Services.shared.api else { throw APIError.transport(URLError(.badURL)) }
                return try await api.session(id: id).value
            },
            setWatchLive: { LiveSessionStore.shared.watchSessionLive = $0 },
            stateURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Vitalis/watch-relay.json"),
            retryEvery: .seconds(30))
    }
}

#if canImport(WatchConnectivity)
@MainActor final class LiveWatchChannel: PhoneWatchChannel {
    let session: WCSession
    init(session: WCSession) { self.session = session }

    var hasWatchApp: Bool { session.activationState == .activated && session.isPaired && session.isWatchAppInstalled }
    var isReachable: Bool { session.isReachable }
    var remainingComplicationTransfers: Int { session.remainingComplicationUserInfoTransfers }
    var lastContext: [String: Any] { session.applicationContext }

    func queueUserInfo(_ info: [String: Any]) { session.transferUserInfo(info) }
    func queueComplicationInfo(_ info: [String: Any]) { session.transferCurrentComplicationUserInfo(info) }
    func sendNow(_ message: [String: Any], failed: @escaping @MainActor @Sendable () -> Void) {
        session.sendMessage(message, replyHandler: nil) { _ in Task { @MainActor in failed() } }
    }
    func replaceContext(_ context: [String: Any]) { try? session.updateApplicationContext(context) }
    /// One catalog file at a time: a newer list supersedes any transfer still queued.
    func queueFile(_ url: URL, metadata: [String: Any]) {
        session.outstandingFileTransfers.forEach { $0.cancel() }
        session.transferFile(url, metadata: metadata)
    }
}

/// WCSession calls back on a background queue; dictionaries are decoded there and only `Sendable` messages hop to the main actor.
final class PhoneWCBridge: NSObject, WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in await PhoneSessionDelegate.shared.wake() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    /// Owner switched Watches: reactivate for the new one.
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in await PhoneSessionDelegate.shared.wake() }
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { deliver(userInfo) }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { deliver(message) }
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard error != nil else { return }
        Task { @MainActor in WatchPackSender.shared.catalogTransferFailed() }
    }

    private func deliver(_ dict: [String: Any]) {
        guard let message = PhoneSessionDelegate.decode(dict) else { return }
        Task { @MainActor in await PhoneSessionDelegate.shared.handle(message) }
    }
}
#endif
