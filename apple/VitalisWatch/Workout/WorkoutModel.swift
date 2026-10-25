import Foundation
import Observation
import VitalisKit
import VitalisUI

/// The Watch logger (spec 21 §2): Start → Set entry → Rest → … → End → Summary. Every logged change is written to the
/// session file before the UI moves on; W-02 wires `outbound` to WatchConnectivity and feeds `apply(…)` from the phone.
@MainActor @Observable final class WorkoutModel {
    enum Phase: Equatable { case start, logging, summary }
    enum Step: Equatable { case setEntry, rest(RestTimer), handoff }
    enum Field { case weight, reps }

    static let shared = WorkoutModel(store: try? WatchSessionStore.standard(), session: HealthWorkoutSession())

    static let weightRange: ClosedRange<Double> = 0...500
    static let repsRange: ClosedRange<Double> = 0...100

    private(set) var phase: Phase = .start
    private(set) var step: Step = .setEntry
    private(set) var pack: WatchPack?
    private(set) var record: WorkoutSessionRecord?
    private(set) var result: WatchResult?
    private(set) var plan: WatchPlan?
    private(set) var currentIndex = 0
    var weight: Double?
    var reps: Int?
    var focus: Field = .weight
    /// Hook for W-02's Add exercise sheet (from Start, Set entry `+` and handoff).
    var showsAddExercise = false

    let session: any WorkoutSessionControlling
    @ObservationIgnored let store: WatchSessionStore?
    /// Queues a message to the phone; returns true once WatchConnectivity has accepted it (W-02).
    @ObservationIgnored var outbound: (WatchMessage) -> Bool = { _ in false }
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    init(store: WatchSessionStore?, session: any WorkoutSessionControlling, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.session = session
        self.now = now
    }

    // MARK: Launch and recovery

    /// Loads the last pack and resumes a session left live by a crash (spec 21 §4). Safe to call repeatedly.
    func bootstrap() async {
        if let bootstrapTask { return await bootstrapTask.value }
        let task = Task { await self.recover() }
        bootstrapTask = task
        await task.value
    }

    private func recover() async {
        if pack == nil { pack = store?.loadPack() }
        if record == nil, let live = store?.liveSession() {
            record = live
            let lastExercise = live.visibleSets.last?.exerciseID
            currentIndex = lastExercise.flatMap { live.exerciseIDs.firstIndex(of: $0) } ?? 0
            phase = .logging
            step = .setEntry
            prefill()
        }
        resendUndelivered()
        if record?.isLive == true { _ = await session.recover() }
    }

    /// Re-queues sessions WatchConnectivity never accepted (crash, or no session yet); W-02 calls it after `WCSession` activation.
    /// The phone upserts by client id, so a duplicate is harmless.
    func resendUndelivered() {
        for pending in store?.undelivered() ?? [] where pending.delivery == .pending { deliver(pending) }
    }

    // MARK: Starting

    var settings: WatchPack.Settings { pack?.settings ?? .init() }

    /// The title stays the split's name verbatim: history splits have no template and the server matches them by title.
    func start(split: WatchPack.Split) {
        start(WatchPlan(title: split.name, template: split.template, exerciseIDs: split.exerciseIDs))
        // A Settings split never trained yet has no exercises: pick as you go (11 §7.2).
        if split.exerciseIDs.isEmpty, record?.isLive == true { showsAddExercise = true }
    }

    func repeatSession(_ recent: WatchPack.RecentSession) {
        start(WatchPlan(title: recent.title, template: recent.template, exerciseIDs: recent.exerciseIDs))
    }

    /// Phone's `startWatchApp`: skip Start and log the plan it sent (spec 21 §2 flow). No plan: Start stays up, since no
    /// split is picked for the owner.
    func startFromPhone() async {
        await bootstrap()
        guard record?.isLive != true, let plan = plan ?? pack?.plan else { return }
        start(plan)
    }

    func start(_ plan: WatchPlan) {
        guard record?.isLive != true else { return }
        let started = now()
        let fresh = WorkoutSessionRecord(title: plan.title ?? "Workout", template: plan.template, startedAt: started,
                                         tzOffsetMin: TimeZone.current.secondsFromGMT(for: started) / 60, exerciseIDs: plan.exerciseIDs)
        guard persist(fresh) else { Haptic.play(.failure); return }
        record = fresh
        self.plan = nil
        result = nil
        currentIndex = 0
        phase = .logging
        step = .setEntry
        prefill()
        _ = outbound(.sessionState(WatchSessionState(sessionID: fresh.id, state: .live)))
        deliver(fresh)
        Task { try? await session.start(at: started) }
    }

    /// Add exercise selection: inserted as next (or the first exercise of a new session).
    func addExercise(_ id: String) {
        showsAddExercise = false
        guard var r = record, r.isLive else {
            start(WatchPlan(title: pack?.exercises[id]?.name, template: nil, exerciseIDs: [id]))
            return
        }
        // A later, not-yet-started copy moves up instead of duplicating; indices up to the current one stay put.
        let later = r.exerciseIDs.indices.filter { $0 > currentIndex && r.exerciseIDs[$0] == id }
        if !loggedAny(id) { for i in later.reversed() { r.exerciseIDs.remove(at: i) } }
        let insertAt = currentExerciseID == nil ? r.exerciseIDs.count : min(currentIndex + 1, r.exerciseIDs.count)
        r.exerciseIDs.insert(id, at: insertAt)
        guard commit(r) else { return }
        currentIndex = insertAt
        step = .setEntry
        prefill()
    }

    // MARK: Set entry

    var currentExerciseID: String? {
        guard let ids = record?.exerciseIDs, ids.indices.contains(currentIndex) else { return nil }
        return ids[currentIndex]
    }

    func exercise(_ id: String) -> WatchPack.Exercise? { pack?.exercises[id] }
    func name(of id: String) -> String { exercise(id)?.name ?? WatchFormat.name(forID: id) }

    // Counts include sets the phone added to this workout, so "2/4" matches what was actually done.
    private func sets(for id: String) -> [LoggedSet] { record?.allSets.filter { $0.exerciseID == id } ?? [] }
    private func loggedAny(_ id: String) -> Bool { !sets(for: id).isEmpty }
    private func workingCount(_ id: String) -> Int { sets(for: id).filter { $0.kind == .normal }.count }

    func plannedSets(_ id: String) -> Int {
        exercise(id)?.plannedSets(suggests: settings.suggests) ?? WatchPack.Exercise.defaultPlannedSets
    }

    /// `SQUAT · 2/4`: the set being entered over the server's planned count.
    var setEntryTitle: String {
        guard let id = currentExerciseID else { return "Vitalis" }
        return "\(name(of: id)) · \(workingCount(id) + 1)/\(plannedSets(id))"
    }

    /// `LAST 97.5`: last session's weight for this set number, nil when the server has none.
    var lastWeightText: String? {
        guard let id = currentExerciseID, let kg = exercise(id)?.lastWeight(setNumber: workingCount(id) + 1) else { return nil }
        return "Last \(WatchFormat.kg(kg))"
    }

    /// One dip per set logged for this exercise at x = i / (planned + 1), now-dot after the last (spec 30 → PulseLine).
    var pulseEvents: [Double] {
        guard let id = currentExerciseID else { return [] }
        let n = sets(for: id).count
        let slots = Double(max(plannedSets(id), n) + 1)
        return n == 0 ? [] : (1...n).map { Double($0) / slots }
    }
    var pulseNow: Double { pulseEvents.last ?? 0 }

    /// The Crown edits the focused field: weight in the server's step, reps by 1 (spec 21 §2.2).
    var crownValue: Double {
        get { focus == .weight ? (weight ?? 0) : Double(reps ?? 0) }
        set {
            switch focus {
            case .weight: weight = min(max(newValue, Self.weightRange.lowerBound), Self.weightRange.upperBound)
            case .reps: reps = Int(min(max(newValue, Self.repsRange.lowerBound), Self.repsRange.upperBound).rounded())
            }
        }
    }
    var crownRange: ClosedRange<Double> { focus == .weight ? Self.weightRange : Self.repsRange }
    var crownStep: Double { focus == .weight ? settings.crownStep : 1 }

    /// Writes the set durably first; only then haptic, dip, phone transfer and Rest. False means nothing changed.
    @discardableResult
    func logSet(kind: LoggedSet.Kind = .normal) -> Bool {
        guard var r = record, r.isLive, let id = currentExerciseID, let reps, reps > 0 else {
            if reps == nil || reps == 0 { focus = .reps }
            Haptic.play(.failure)
            return false
        }
        r.sets.append(LoggedSet(exerciseID: id, kind: kind, weightKg: weight, reps: reps, performedAt: now()))
        guard commit(r) else { Haptic.play(.failure); return false }
        Haptic.play(.success)
        step = .rest(RestTimer(start: now(), duration: TimeInterval(settings.rest)))
        return true
    }

    // MARK: Rest

    /// `Squat 100 kg · 6`: what the set after this rest will be prefilled with.
    var nextSetText: String {
        guard let id = upcomingExerciseID else { return WatchFormat.missing }
        let values = prefillValues(for: id)
        return WatchFormat.setLine(name: name(of: id), weightKg: values.weightKg, reps: values.reps)
    }

    func adjustRest(by delta: TimeInterval) {
        guard case .rest(let timer) = step else { return }
        let adjusted = timer.adjusted(by: delta, at: now())
        step = .rest(adjusted)
        if adjusted.isFinished(at: now()) { restFinished(adjusted) }
    }

    func skipRest() {
        guard case .rest = step else { return }
        advanceAfterRest()
    }

    /// Called when the countdown reaches zero; ignored if the owner already skipped or adjusted this timer.
    func restFinished(_ timer: RestTimer) {
        guard case .rest(let current) = step, current == timer || current.isFinished(at: now()) else { return }
        Haptic.play(.notification)
        advanceAfterRest()
    }

    private var upcomingExerciseID: String? {
        guard let id = currentExerciseID else { return nil }
        if workingCount(id) >= plannedSets(id), let next = nextExerciseID { return next }
        return id
    }

    private var nextExerciseID: String? {
        guard let ids = record?.exerciseIDs, ids.indices.contains(currentIndex + 1) else { return nil }
        return ids[currentIndex + 1]
    }

    private func advanceAfterRest() {
        if let id = currentExerciseID, workingCount(id) >= plannedSets(id), nextExerciseID != nil {
            step = .handoff
        } else {
            step = .setEntry
            prefill()
        }
    }

    // MARK: Handoff (W-02 screen)

    var handoffExerciseID: String? { nextExerciseID }

    func startNextExercise() {
        guard nextExerciseID != nil else { step = .setEntry; return }
        currentIndex += 1
        step = .setEntry
        prefill()
    }

    /// `Skip` on the handoff moves the next exercise to the end of the plan.
    func skipNextExercise() {
        guard var r = record, r.exerciseIDs.indices.contains(currentIndex + 1) else { return }
        r.exerciseIDs.append(r.exerciseIDs.remove(at: currentIndex + 1))
        _ = commit(r)
    }

    // MARK: Controls and end (W-02 screens)

    var isPaused: Bool { session.isPaused }
    func pause() { session.pause() }
    func resume() { session.resume() }

    /// Ends the session (spec 21 §2.7): end time saved first, then the HealthKit workout, then its uuid.
    func end() async {
        guard var r = record, r.isLive else { return }
        let ended = now()
        r.endedAt = ended
        guard commit(r) else { return }
        _ = outbound(.sessionState(WatchSessionState(sessionID: r.id, state: .ended)))
        phase = .summary
        if let uuid = await session.end(at: ended), var latest = record, latest.id == r.id {
            latest.hkWorkoutUUID = uuid
            _ = commit(latest)
        }
    }

    /// Summary → Start; also the moment old acked sessions are pruned.
    func done() {
        record = nil
        result = nil
        currentIndex = 0
        step = .setEntry
        phase = .start
        store?.prune(now: now())
    }

    // MARK: Summary

    /// Server session heat once relayed, else catalog lighting of the logged exercises (primary 4, secondary 3).
    var summaryHeat: [String: Int] {
        if let result, result.sessionID == record?.id { return result.heat }
        var heat: [String: Int] = [:]
        let ids = Array(Set(record?.allSets.map(\.exerciseID) ?? []))
        for id in ids {
            guard let info = exercise(id) else { continue }
            let lit = MuscleMap.catalogLighting(primary: Self.muscles(info.primary), secondary: Self.muscles(info.secondary))
            for (muscle, level) in lit { heat[muscle.rawValue] = max(heat[muscle.rawValue] ?? 0, level) }
        }
        return heat
    }

    var hasServerResult: Bool { result != nil && result?.sessionID == record?.id }
    var hasPR: Bool { hasServerResult && !(result?.prs.isEmpty ?? true) }

    /// `61 MIN · 16 SETS`: the server's totals once relayed, else the owner's own clock and count.
    var summaryStats: String {
        guard let r = record else { return WatchFormat.missing }
        let serverResult = hasServerResult ? result : nil
        let minutes = serverResult?.durationMin ?? Int((r.endedAt ?? now()).timeIntervalSince(r.startedAt) / 60)
        let count = serverResult?.workingSets ?? r.allSets.filter { $0.kind == .normal }.count
        return "\(minutes) min · \(count) sets"
    }

    private static func muscles(_ slugs: [String]) -> [Muscle] {
        slugs.compactMap { Muscle(rawValue: $0.replacingOccurrences(of: " ", with: "-")) }
    }

    // MARK: From the phone (W-02 calls these)

    func apply(pack newPack: WatchPack) {
        pack = newPack
        try? store?.savePack(newPack)
    }

    func apply(plan newPlan: WatchPlan) { plan = newPlan }

    func apply(ack: WatchAck) {
        guard let updated = try? store?.applyAck(ack) else { return }
        if record?.id == updated.id, record?.revision == updated.revision { record?.delivery = updated.delivery }
    }

    /// The phone's sets in this workout (20 §4 shared workout). Saved without a revision bump or delivery: they are
    /// the phone's to post, so they never enter this record's upsert. New exercises join the end of the list.
    func apply(phoneSets: WatchPhoneSets) {
        guard var r = record, r.id == phoneSets.sessionID, r.isLive else { return }
        r.phoneSets = phoneSets.sets
        for id in phoneSets.sets.map(\.exerciseID) where !r.exerciseIDs.contains(id) { r.exerciseIDs.append(id) }
        guard persist(r) else { return }
        record = r
    }

    /// Swaps the summary to server heat and PRs, even while it is open.
    func apply(result newResult: WatchResult) { result = newResult }

    // MARK: Persistence

    /// Saves before the in-memory record changes, so the UI never shows a set the file doesn't hold.
    private func commit(_ updated: WorkoutSessionRecord) -> Bool {
        var next = updated
        next.revision += 1
        next.delivery = .pending
        guard persist(next) else { return false }
        record = next
        deliver(next)
        return true
    }

    private func persist(_ r: WorkoutSessionRecord) -> Bool {
        guard let store else { return false }
        do { try store.save(r); return true } catch { return false }
    }

    private func deliver(_ r: WorkoutSessionRecord) {
        guard outbound(.session(r)), let sent = try? store?.markSent(r.id, revision: r.revision) else { return }
        if record?.id == sent.id, record?.revision == sent.revision { record?.delivery = sent.delivery }
    }

    // MARK: Prefill (spec 21 §2.2)

    private func prefillValues(for id: String) -> (weightKg: Double?, reps: Int?) {
        if let previous = sets(for: id).last(where: { $0.kind == .normal }) { return (previous.weightKg, previous.reps) }
        return exercise(id)?.firstSet(suggests: settings.suggests) ?? (nil, nil)
    }

    private func prefill() {
        focus = .weight
        guard let id = currentExerciseID else { weight = nil; reps = nil; return }
        (weight, reps) = prefillValues(for: id)
    }
}

#if DEBUG
extension WorkoutModel {
    enum PreviewState { case start, startNoPack, setEntry, setEntryFirstEver, rest, handoff, summarySyncing, summaryServer }

    /// Fixture-only models for previews: a throwaway store, no HealthKit, no phone.
    static func preview(_ state: PreviewState) -> WorkoutModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitalis-watch-preview-\(UUID().uuidString)")
        let base = Date(timeIntervalSince1970: 1_792_822_920) // 2026-10-24 18:22 IST
        let model = WorkoutModel(store: try? WatchSessionStore(root: root), session: PreviewWorkoutSession(), now: { base })
        if state != .startNoPack { model.pack = WatchPreviewData.pack }
        switch state {
        case .start, .startNoPack:
            return model
        case .setEntryFirstEver:
            model.start(WatchPlan(title: "Leg day", template: nil, exerciseIDs: ["hack-squat"]))
        default:
            model.start(split: WatchPreviewData.pack.splits[0])
            model.weight = 97.5; model.reps = 8
            model.logSet(kind: .warmup)
            model.prefill()
            model.weight = 100; model.reps = 6
            model.logSet()
            model.prefill()
        }
        switch state {
        case .rest:
            // The rest view reads the wall clock, so the fixture timer is anchored to it: 84 s of 120 s left.
            model.step = .rest(RestTimer(start: Date.now.addingTimeInterval(-36), duration: 120))
        case .handoff:
            for _ in 0..<3 { model.logSet() }
            model.step = .handoff
        case .summarySyncing, .summaryServer:
            for _ in 0..<2 { model.logSet() }
            model.currentIndex = 2
            model.prefill()
            for _ in 0..<3 { model.logSet() }
            if var r = model.record {
                r.startedAt = base.addingTimeInterval(-61 * 60)
                r.endedAt = base
                model.record = r
            }
            model.phase = .summary
            if state == .summaryServer, let id = model.record?.id {
                model.result = WatchResult(sessionID: id, heat: WatchPreviewData.serverHeat, prs: WatchPreviewData.prs,
                                           durationMin: 61, workingSets: 16)
            }
        default:
            break
        }
        return model
    }
}
#endif
