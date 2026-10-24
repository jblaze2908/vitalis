import Foundation
import Observation
import VitalisKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The Watch's WatchConnectivity surface, so `WorkoutModel` never touches `WCSession`.
@MainActor protocol WatchPhoneChannel: AnyObject {
    var isActivated: Bool { get }
    var isReachable: Bool { get }
    func queueUserInfo(_ info: [String: Any])
    func sendNow(_ message: [String: Any])
}

/// Watch ⇄ phone (spec 21 §6): sessions leave via `transferUserInfo`; ack, result, pack, plan, catalog and today
/// arrive here and go to the model. Pruning stays in `WatchSessionStore`, which only drops acked sessions.
@MainActor final class WatchSessionDelegate {
    static let shared = WatchSessionDelegate(model: .shared, catalog: .shared)

    let model: WorkoutModel
    let catalog: WatchCatalog
    var channel: (any WatchPhoneChannel)?
    #if canImport(WatchConnectivity)
    private let bridge = WatchWCBridge()
    #endif

    init(model: WorkoutModel, catalog: WatchCatalog) {
        self.model = model
        self.catalog = catalog
    }

    /// At launch, before the model's bootstrap sends anything.
    func activate() {
        model.outbound = { [weak self] message in self?.send(message) ?? false }
        #if canImport(WatchConnectivity)
        guard channel == nil, WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = bridge
        channel = LiveWatchChannel(session: session)
        session.activate()
        #endif
    }

    /// True once WatchConnectivity holds the message; `transferUserInfo` queues durably across termination.
    func send(_ message: WatchMessage) -> Bool {
        guard let channel, channel.isActivated, let dict = try? message.dictionary() else { return false }
        if case .sessionState = message {
            guard channel.isReachable else { return false }
            channel.sendNow(dict)
        } else {
            channel.queueUserInfo(dict)
        }
        return true
    }

    private(set) var hasActivated = false

    /// The context pack is applied first, so a phone-started launch waiting in `awaitActivation` sees its plan.
    /// Sessions written while the session wasn't active are still `pending`; queue them now.
    func activated(context: WatchMessage?) {
        if let context { receive(context) }
        hasActivated = true
        model.resendUndelivered()
    }

    /// Phone-started launch: the plan rides in the application context, which lands on activation. Polls ≤ 2 s once.
    func awaitActivation(timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while channel != nil, !hasActivated, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func receive(_ message: WatchMessage) {
        switch message {
        case .ack(let ack): model.apply(ack: ack)
        case .result(let result): model.apply(result: result)
        case .pack(let pack): model.apply(pack: pack)
        case .plan(let plan): model.apply(plan: plan)
        case .catalog: Task { await catalog.reload() }
        case .today(let snapshot): Self.store(snapshot)
        case .session, .sessionState: break
        }
    }

    /// A failed transfer leaves the session `sentToPhone`, which `resendUndelivered` skips; queue its latest copy again.
    func transferFailed(sessionID: UUID) {
        guard let record = model.store?.load(sessionID), record.delivery != .ackedByPhone else { return }
        _ = send(.session(record))
    }

    // MARK: Complications (spec 21 §3)

    /// Writes into the App Group the complication reads; reloads only when the snapshot changed (reloads are budgeted).
    nonisolated static func receiveToday(_ payload: [String: Any]) {
        guard let directory = WidgetTimeline.sharedDirectory(), ComplicationTransfer.receive(payload, into: directory) else { return }
        Task { @MainActor in reloadComplications() }
    }

    static func store(_ snapshot: TodaySnapshot) {
        guard let directory = WidgetTimeline.sharedDirectory(), snapshot != TodaySnapshot.read(from: directory),
              (try? snapshot.write(to: directory)) != nil else { return }
        reloadComplications()
    }

    static func reloadComplications() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// `JSONSerialization` raises (not throws) on non-JSON values such as the `today` Data, so check first.
    nonisolated static func decode(_ dict: [String: Any]) -> WatchMessage? {
        guard !dict.isEmpty, JSONSerialization.isValidJSONObject(dict) else { return nil }
        return try? WatchMessage(dictionary: dict)
    }
}

/// `GET /v2/exercises` as last sent by the phone (`transferFile`), for Add exercise search.
@MainActor @Observable final class WatchCatalog {
    static let shared = WatchCatalog(url: WatchCatalog.defaultURL())

    let url: URL?
    private(set) var exercises: [ExerciseInfo] = []
    @ObservationIgnored private var loaded = false

    init(url: URL?) { self.url = url }

    /// Previews: a fixed list, no file.
    init(exercises: [ExerciseInfo]) {
        url = nil
        self.exercises = exercises
        loaded = true
    }

    nonisolated static func defaultURL() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Watch/catalog.json")
    }

    /// Decoded off the main actor (several hundred entries), once per launch and after each new file.
    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        guard let url else { return }
        loaded = true
        exercises = await Task.detached {
            (try? Data(contentsOf: url)).flatMap { try? APICoding.decoder().decode(ExerciseList.self, from: $0) }?.exercises ?? []
        }.value
    }

    /// WatchConnectivity deletes the received file when its callback returns, so it is moved in place synchronously.
    nonisolated static func install(_ received: URL) -> Bool {
        guard let url = defaultURL() else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: received, to: url)
            return true
        } catch {
            return false
        }
    }
}

#if canImport(WatchConnectivity)
@MainActor final class LiveWatchChannel: WatchPhoneChannel {
    let session: WCSession
    init(session: WCSession) { self.session = session }

    var isActivated: Bool { session.activationState == .activated }
    var isReachable: Bool { session.isReachable }
    func queueUserInfo(_ info: [String: Any]) { session.transferUserInfo(info) }
    func sendNow(_ message: [String: Any]) { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
}

/// WCSession calls back on a background queue: dictionaries are decoded (and files moved) there, and only
/// `Sendable` messages hop to the main actor.
final class WatchWCBridge: NSObject, WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        // A pack or today that arrived while the app wasn't running.
        let context = session.receivedApplicationContext
        if context[ComplicationTransfer.key] != nil { WatchSessionDelegate.receiveToday(context) }
        let message = WatchSessionDelegate.decode(context.filter { $0.key != ComplicationTransfer.key })
        Task { @MainActor in WatchSessionDelegate.shared.activated(context: message) }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleContext(applicationContext)
    }

    /// Complication transfers arrive as user info too, keyed `today`.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo[ComplicationTransfer.key] != nil {
            WatchSessionDelegate.receiveToday(userInfo)
        } else {
            deliver(userInfo)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { deliver(message) }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata, let message = WatchSessionDelegate.decode(metadata), case .catalog = message,
              WatchCatalog.install(file.fileURL) else { return }
        Task { @MainActor in WatchSessionDelegate.shared.receive(message) }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?) {
        guard error != nil, case .session(let record)? = WatchSessionDelegate.decode(userInfoTransfer.userInfo) else { return }
        let id = record.id
        Task { @MainActor in WatchSessionDelegate.shared.transferFailed(sessionID: id) }
    }

    private func handleContext(_ context: [String: Any]) {
        if context[ComplicationTransfer.key] != nil { WatchSessionDelegate.receiveToday(context) }
        deliver(context.filter { $0.key != ComplicationTransfer.key })
    }

    private func deliver(_ dict: [String: Any]) {
        guard let message = WatchSessionDelegate.decode(dict) else { return }
        Task { @MainActor in WatchSessionDelegate.shared.receive(message) }
    }
}
#endif
