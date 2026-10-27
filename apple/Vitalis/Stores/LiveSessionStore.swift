import Foundation
import Observation
import VitalisKit

/// A ticked set. `id` is minted once at check time and becomes the server set id, so every upsert repeats it.
struct LoggedSet: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var exercise: String
    /// `normal` | `warmup`
    var kind: String
    var weightKg: Double?
    var reps: Int?
    var targetWeightKg: Double?
    var targetReps: Int?
    var performedAt: Date
    var note: String?
    /// Kept after a delete so the next post tells the server, and Undo can bring it back.
    var deleted: Bool?

    var isLive: Bool { deleted != true }
}

/// One line of the set table: prefill text until it is ticked, then it points at its `LoggedSet`.
struct SetRow: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var kind = "normal"
    /// Last session's set as `60 x 10`; nil when there was none.
    var last: String?
    var weight = ""
    var reps = ""
    var targetWeightKg: Double?
    var targetReps: Int?
    var loggedID: UUID?
    /// A set the Watch logged in a joined workout: shown, never edited or posted by the phone.
    var byWatch: Bool?

    var isWarmup: Bool { kind == "warmup" }
    var isDone: Bool { loggedID != nil }
}

struct LiveExercise: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    /// `records.best_set` from the exercise detail, as the server wrote it.
    var best: String?
    var rows: [SetRow]
    /// Set once rows came from `GET /v2/exercises/:id` (network or cache); otherwise prefill is retried.
    var prefilled = false

    var pendingRowIndex: Int? { rows.firstIndex { !$0.isDone } }
}

/// The iPhone logger's whole state; written to disk after every change (spec 20 §4).
struct LiveSession: Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var template: String?
    var startedAt: Date
    var endedAt: Date?
    var hkWorkoutUUID: String?
    var exercises: [LiveExercise]
    var currentIndex: Int
    var sets: [LoggedSet] = []
    var restEnd: Date?
    var restTotal: TimeInterval = 0
    var restSeconds = RestTimer.defaultSeconds
    /// Joined a workout the Watch owns (20 §4): the Watch records it in Health and ends it; the phone adds sets.
    var joinedWatch: Bool?
    /// The Watch's sets, replaced wholesale from each record it sends.
    var watchSets: [LoggedSet]?

    var isJoined: Bool { joinedWatch == true }
    /// Logged on this phone and not deleted.
    var loggedSets: [LoggedSet] { sets.filter(\.isLive) }
    var current: LiveExercise? { exercises.indices.contains(currentIndex) ? exercises[currentIndex] : nil }
    var plannedSets: Int { exercises.reduce(0) { $0 + $1.rows.count } }
}

/// Rest countdown from a stored end date, so it survives relaunch and needs no ticking state.
enum RestTimer {
    static let defaultSeconds = 120
    static let step: TimeInterval = 15

    static func remaining(end: Date?, now: Date) -> TimeInterval {
        guard let end else { return 0 }
        return max(0, end.timeIntervalSince(now))
    }

    /// Remaining share of the rest for the ProgressTrack.
    static func fraction(end: Date?, total: TimeInterval, now: Date) -> Double {
        guard total > 0 else { return 0 }
        return min(1, remaining(end: end, now: now) / total)
    }

    /// `1:24`, rounding up so the last second shows `0:01`, not `0:00`.
    static func text(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

@MainActor @Observable
final class LiveSessionStore {
    static let shared: LiveSessionStore = {
        #if DEBUG
        // Demo screenshots of the logger: `-VitalisDemo -VitalisRoute vitalis://workout/live` opens a fixture session.
        if Services.shared.isDemo, UserDefaults.standard.string(forKey: "VitalisRoute") == "vitalis://workout/live" {
            return TrainPreviewData.liveStore()
        }
        #endif
        let store = LiveSessionStore(fileURL: LiveSessionStore.defaultFileURL(), api: { Services.shared.api },
                                     send: { _ = await Services.shared.send($0) },
                                     health: HealthWriter(store: AppModel.shared.healthStore))
        store.liveActivity = { WorkoutActivityController.shared.sync($0) }
        // A session restored from disk picks up (or restarts) its Live Activity.
        store.liveActivity?(store.session)
        return store
    }()

    private(set) var session: LiveSession?
    /// True while a Watch session is live; the phone can join it instead of starting its own.
    var watchSessionLive = false
    /// The latest copy of the live Watch workout, from its durable `.session` transfers.
    private(set) var liveWatch: WorkoutSessionRecord?
    /// Phone → Watch path for a joined workout's own sets; wired to `PhoneSessionDelegate` in the app.
    @ObservationIgnored var sendToWatch: (@MainActor (WatchPhoneSets) -> Void)?
    /// Every persisted change (nil = ended); drives the Live Activity in the app, unset in tests.
    @ObservationIgnored var liveActivity: (@MainActor (LiveSession?) -> Void)?

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let api: @MainActor () -> VitalisAPI?
    @ObservationIgnored private let send: @MainActor (APIRequest) async -> Void
    @ObservationIgnored private let health: HealthWriting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private var editedSinceUpsert = false
    /// The last deleted set and where its row was, while the Undo toast shows.
    private(set) var undo: DeletedSet?
    @ObservationIgnored private var undoTask: Task<Void, Never>?

    struct DeletedSet: Equatable {
        let setID: UUID
        let exerciseID: String
        let row: SetRow
        let rowIndex: Int
        let text: String
    }

    init(fileURL: URL?, api: @escaping @MainActor () -> VitalisAPI?, send: @escaping @MainActor (APIRequest) async -> Void,
         health: HealthWriting, now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.fileURL = fileURL; self.api = api; self.send = send; self.health = health; self.now = now; self.timeZone = timeZone
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            session = try? JSONDecoder().decode(LiveSession.self, from: data)
        }
    }

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Vitalis", isDirectory: true).appendingPathComponent("live-session.json")
    }

    var isLive: Bool { session != nil }

    // MARK: Watch

    /// Each Watch record: tracks the live one, refreshes a joined session, and closes it when the Watch ends.
    func watchRecord(_ r: WorkoutSessionRecord) {
        watchSessionLive = r.isLive
        if r.isLive { liveWatch = r } else if liveWatch?.id == r.id { liveWatch = nil }
        guard let s = session, s.isJoined, s.id == r.id else { return }
        if r.isLive { syncWatch(r) } else { session = nil; persist() }
    }

    /// The Watch app opened with this workout's id: it records Health and ends the workout; the phone adds sets.
    func startedWithWatch() {
        guard session != nil else { return }
        session?.joinedWatch = true
        persist()
    }

    /// Opens the live Watch workout on the phone. Its sets show as Watch rows; the phone's own sets are added beside them.
    func join() {
        guard session == nil, let r = liveWatch else { return }
        session = LiveSession(id: r.id, title: r.title, template: r.template, startedAt: r.startedAt, exercises: [],
                              currentIndex: 0, joinedWatch: true)
        syncWatch(r)
        if let i = session?.exercises.lastIndex(where: { $0.rows.contains { $0.byWatch == true } }) { session?.currentIndex = i }
        persist()
    }

    private func syncWatch(_ r: WorkoutSessionRecord) {
        guard var s = session else { return }
        let watch = r.visibleSets.map {
            LoggedSet(id: $0.id, exercise: $0.exerciseID, kind: $0.kind.rawValue, weightKg: $0.weightKg, reps: $0.reps, performedAt: $0.performedAt)
        }
        s.watchSets = watch
        s.title = r.title
        for id in r.exerciseIDs + watch.map(\.exercise) where !s.exercises.contains(where: { $0.id == id }) {
            s.exercises.append(LiveExercise(id: id, name: Self.displayName(id), best: nil, rows: [SetRow()]))
        }
        let at = Dictionary((s.sets + watch).map { ($0.id, $0.performedAt) }, uniquingKeysWith: { a, _ in a })
        for i in s.exercises.indices {
            let id = s.exercises[i].id
            let mine = s.exercises[i].rows.filter { $0.byWatch != true }
            let watchRows = watch.filter { $0.exercise == id }.map {
                SetRow(kind: $0.kind, weight: TrainFormat.kg($0.weightKg, empty: ""), reps: $0.reps.map(String.init) ?? "", loggedID: $0.id, byWatch: true)
            }
            let done = (mine.filter(\.isDone) + watchRows).sorted { (at[$0.loggedID!] ?? .distantFuture) < (at[$1.loggedID!] ?? .distantFuture) }
            s.exercises[i].rows = done + mine.filter { !$0.isDone }
        }
        session = s
        persist()
    }

    /// "barbell-bench-press-medium-grip" → "Barbell Bench Press Medium Grip" until the exercise detail names it.
    nonisolated static func displayName(_ id: String) -> String { id.split(separator: "-").map { $0.capitalized }.joined(separator: " ") }

    private func shareWithWatch() {
        guard let s = session, s.isJoined else { return }
        sendToWatch?(WatchPhoneSets(sessionID: s.id, sets: s.loggedSets.map {
            VitalisKit.LoggedSet(id: $0.id, exerciseID: $0.exercise, kind: $0.kind == "warmup" ? .warmup : .normal,
                                 weightKg: $0.weightKg, reps: $0.reps, performedAt: $0.performedAt)
        }))
    }

    // MARK: Start

    /// Starts a session from the chosen split (or an empty one); an existing session is resumed instead.
    func begin(split: Split?) {
        guard session == nil else { return }
        let exercises = (split?.exercises ?? []).map { e in
            LiveExercise(id: e.id, name: e.name, best: nil, rows: [Self.row(fromLast: e.last)])
        }
        session = LiveSession(id: UUID(), title: split?.name ?? "Workout", template: split?.templateID, startedAt: now(),
                              exercises: exercises, currentIndex: 0)
        persist()
    }

    /// Rest length and per-exercise prefill; safe to call again (only exercises not yet prefilled are fetched).
    func prepare() async {
        guard session != nil else { return }
        if let api = api() {
            var targets = try? await api.targets().value
            if targets == nil { targets = await api.cached(TargetsResponse.self, path: "v2/targets")?.value }
            // `rest_s` lives in `values` (the spec's `effective` block has no rest field); null keeps the 120 s default.
            if let rest = targets?.values.restS, session != nil { session?.restSeconds = rest; persist() }
        }
        for id in session?.exercises.filter({ !$0.prefilled }).map(\.id) ?? [] { await prefill(id) }
    }

    /// `GET /v2/exercises/:id`, else its cached body; with neither the rows stay as they are.
    func prefill(_ exerciseID: String) async {
        guard let api = api() else { return }
        let detail: ExerciseDetail?
        do { detail = try await api.exercise(id: exerciseID).value }
        catch { detail = await api.cached(ExerciseDetail.self, path: "v2/exercises/\(HTTPCore.pathSegment(exerciseID))")?.value }
        if let detail { apply(detail, to: exerciseID) }
    }

    /// Replaces the placeholder rows only while nothing in that exercise was ticked.
    func apply(_ detail: ExerciseDetail, to exerciseID: String) {
        guard let i = index(of: exerciseID), var ex = session?.exercises[i] else { return }
        ex.name = detail.exercise.name
        ex.best = detail.records?.bestSet
        if !ex.rows.contains(where: \.isDone) { ex.rows = Self.rows(from: detail) }
        ex.prefilled = true
        session?.exercises[i] = ex
        persist()
    }

    /// Frame 12: one row per set of the last session (warm-ups as `W`), fields from `next` for working sets,
    /// extra rows up to `next.sets`; one empty row when there is no history.
    nonisolated static func rows(from detail: ExerciseDetail) -> [SetRow] {
        let next = detail.next
        var rows = (detail.lastSession?.sets ?? []).map { s -> SetRow in
            let warm = s.kind == "warmup"
            let w = warm ? s.weightKg : (next?.weightKg ?? s.weightKg)
            let r = warm ? s.reps : (next?.reps ?? s.reps)
            return SetRow(kind: warm ? "warmup" : "normal", last: TrainFormat.set(s.weightKg, s.reps), weight: TrainFormat.kg(w, empty: ""),
                          reps: r.map(String.init) ?? "", targetWeightKg: warm ? nil : next?.weightKg, targetReps: warm ? nil : next?.reps)
        }
        let working = rows.filter { !$0.isWarmup }.count
        if let planned = next?.sets, planned > working {
            for _ in working..<planned {
                rows.append(SetRow(weight: TrainFormat.kg(next?.weightKg, empty: ""), reps: next?.reps.map(String.init) ?? "",
                                   targetWeightKg: next?.weightKg, targetReps: next?.reps))
            }
        }
        return rows.isEmpty ? [SetRow()] : rows
    }

    nonisolated static func row(fromLast last: Split.Exercise.Last?) -> SetRow {
        guard let last else { return SetRow() }
        return SetRow(last: TrainFormat.set(last.weightKg, last.reps), weight: TrainFormat.kg(last.weightKg, empty: ""),
                      reps: last.reps.map(String.init) ?? "")
    }

    // MARK: Editing

    func select(_ exerciseIndex: Int) {
        guard let s = session, s.exercises.indices.contains(exerciseIndex) else { return }
        session?.currentIndex = exerciseIndex
        persist()
    }

    func setWeight(_ text: String, row: UUID, in exerciseIndex: Int) { edit(row, in: exerciseIndex) { $0.weight = text } }
    func setReps(_ text: String, row: UUID, in exerciseIndex: Int) { edit(row, in: exerciseIndex) { $0.reps = text } }

    private func edit(_ rowID: UUID, in exerciseIndex: Int, _ change: (inout SetRow) -> Void) {
        guard let s = session, s.exercises.indices.contains(exerciseIndex),
              let r = s.exercises[exerciseIndex].rows.firstIndex(where: { $0.id == rowID }) else { return }
        var row = s.exercises[exerciseIndex].rows[r]
        guard row.byWatch != true else { return }
        change(&row)
        session?.exercises[exerciseIndex].rows[r] = row
        // A ticked row edits its logged set; the next upsert carries the correction under the same id.
        if let id = row.loggedID, let k = s.sets.firstIndex(where: { $0.id == id }) {
            session?.sets[k].weightKg = Self.number(row.weight)
            session?.sets[k].reps = Int(row.reps)
            editedSinceUpsert = true
        }
        persist()
    }

    /// Keyboard Done: send corrections to already-logged sets.
    func commitEdits() async {
        guard editedSinceUpsert else { return }
        editedSinceUpsert = false
        await upsert()
        shareWithWatch()
    }

    func loggedSet(_ id: UUID) -> LoggedSet? { session?.sets.first { $0.id == id && $0.isLive } }

    /// Any logged set, including one moved to another exercise; the row moves with it, in time order.
    func editLogged(_ id: UUID, _ e: SetEdit) async {
        guard var s = session, let k = s.sets.firstIndex(where: { $0.id == id && $0.isLive }) else { return }
        let from = s.sets[k].exercise
        s.sets[k].exercise = e.exerciseID
        s.sets[k].kind = e.kind
        s.sets[k].weightKg = e.weightKg
        s.sets[k].reps = e.repsValue
        s.sets[k].note = e.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : e.note
        if let i = s.exercises.firstIndex(where: { $0.id == from }), let r = s.exercises[i].rows.firstIndex(where: { $0.loggedID == id }) {
            var row = s.exercises[i].rows[r]
            row.weight = e.weight; row.reps = e.reps; row.kind = e.kind
            if from == e.exerciseID { s.exercises[i].rows[r] = row } else {
                s.exercises[i].rows.remove(at: r)
                row.last = nil
                let j = s.exercises.firstIndex(where: { $0.id == e.exerciseID }) ?? {
                    s.exercises.append(LiveExercise(id: e.exerciseID, name: e.exerciseName, best: nil, rows: []))
                    return s.exercises.count - 1
                }()
                let at = Dictionary(s.sets.map { ($0.id, $0.performedAt) }, uniquingKeysWith: { a, _ in a })
                let mine = at[id] ?? .distantFuture
                let slot = s.exercises[j].rows.prefix { r in r.loggedID.flatMap { at[$0] }.map { $0 < mine } ?? false }.count
                s.exercises[j].rows.insert(row, at: slot)
            }
        }
        session = s
        persist()
        await upsert()
        shareWithWatch()
        if from != e.exerciseID, session?.exercises.first(where: { $0.id == e.exerciseID })?.prefilled == false { await prefill(e.exerciseID) }
    }

    /// Soft delete: the set travels as a deletion marker so the server drops it; Undo within 5 s brings it back.
    func deleteLogged(_ id: UUID) async {
        guard var s = session, let k = s.sets.firstIndex(where: { $0.id == id && $0.isLive }) else { return }
        s.sets[k].deleted = true
        let exerciseID = s.sets[k].exercise
        if let i = s.exercises.firstIndex(where: { $0.id == exerciseID }), let r = s.exercises[i].rows.firstIndex(where: { $0.loggedID == id }) {
            let row = s.exercises[i].rows.remove(at: r)
            let name = s.exercises[i].name, set = TrainFormat.set(s.sets[k].weightKg, s.sets[k].reps) ?? ""
            showUndo(DeletedSet(setID: id, exerciseID: exerciseID, row: row, rowIndex: r, text: "REMOVED \(name.uppercased()) \(set)"))
        }
        session = s
        persist()
        await upsert()
        shareWithWatch()
    }

    func undoDelete() async {
        guard let u = undo, var s = session, let k = s.sets.firstIndex(where: { $0.id == u.setID }) else { return }
        dismissUndo()
        s.sets[k].deleted = nil
        if let i = s.exercises.firstIndex(where: { $0.id == u.exerciseID }) {
            s.exercises[i].rows.insert(u.row, at: min(u.rowIndex, s.exercises[i].rows.count))
        } else {
            s.exercises.append(LiveExercise(id: u.exerciseID, name: Self.displayName(u.exerciseID), best: nil, rows: [u.row]))
        }
        session = s
        persist()
        await upsert()
        shareWithWatch()
    }

    private func showUndo(_ u: DeletedSet) {
        undo = u
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.undo = nil
        }
    }

    func dismissUndo() { undoTask?.cancel(); undo = nil }

    func addSet(to exerciseIndex: Int) {
        guard let ex = session?.exercises[safe: exerciseIndex] else { return }
        let last = ex.rows.last { !$0.isWarmup } ?? ex.rows.last
        session?.exercises[exerciseIndex].rows.append(SetRow(weight: last?.weight ?? "", reps: last?.reps ?? "",
                                                             targetWeightKg: last?.targetWeightKg, targetReps: last?.targetReps))
        persist()
    }

    /// Adds (or re-selects) an exercise and makes it current; the caller prefills it.
    func addExercise(id: String, name: String) {
        guard session != nil else { return }
        if let i = index(of: id) { select(i); return }
        session?.exercises.append(LiveExercise(id: id, name: name, best: nil, rows: [SetRow()]))
        let last = (session?.exercises.count ?? 1) - 1
        session?.currentIndex = last
        persist()
    }

    // MARK: Logging

    /// The row whose check is live: the first unticked row of the current exercise.
    var currentRowID: UUID? {
        guard let ex = session?.current, let i = ex.pendingRowIndex else { return nil }
        return ex.rows[i].id
    }

    nonisolated static func canLog(_ row: SetRow) -> Bool { (Int(row.reps) ?? 0) > 0 }

    /// Check tap: append the set, start rest, persist, queue the whole session as one idempotent upsert.
    func check() async {
        guard var s = session, !watchSessionLive || s.isJoined, let ex = s.current, let r = ex.pendingRowIndex, Self.canLog(ex.rows[r]) else { return }
        let row = ex.rows[r], at = now()
        let set = LoggedSet(id: UUID(), exercise: ex.id, kind: row.isWarmup ? "warmup" : "normal", weightKg: Self.number(row.weight),
                            reps: Int(row.reps), targetWeightKg: row.targetWeightKg, targetReps: row.targetReps, performedAt: at)
        s.sets.append(set)
        s.exercises[s.currentIndex].rows[r].loggedID = set.id
        // Done with this exercise: move on to the next one that still has sets to do.
        if s.exercises[s.currentIndex].pendingRowIndex == nil,
           let next = s.exercises.indices.first(where: { $0 > s.currentIndex && s.exercises[$0].pendingRowIndex != nil }) {
            s.currentIndex = next
        }
        s.restTotal = TimeInterval(s.restSeconds)
        s.restEnd = at.addingTimeInterval(s.restTotal)
        session = s
        persist()
        await upsert()
        shareWithWatch()
    }

    // MARK: Rest

    func adjustRest(by delta: TimeInterval) {
        guard let end = session?.restEnd else { return }
        let t = now(), newEnd = end.addingTimeInterval(delta)
        if newEnd <= t { skipRest(); return }
        // Read before writing: `session` is observation-tracked, so a read inside its own mutation trips exclusivity.
        let total = max((session?.restTotal ?? 0) + delta, newEnd.timeIntervalSince(t))
        session?.restEnd = newEnd
        session?.restTotal = total
        persist()
    }

    func skipRest() {
        session?.restEnd = nil
        persist()
    }

    // MARK: Finish

    /// A named workout becomes a start choice next time (11 §7.2 history splits).
    func rename(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A joined workout's title is the Watch's; its next record would revert a rename.
        guard !t.isEmpty, let s = session, !s.isJoined else { return }
        session?.title = String(t.prefix(80))
        persist()
    }

    /// Saves the HKWorkout (a failure never blocks the server write), sends the final upsert and clears the session.
    /// Returns the session id (`client_id` = server `sessions.id`), or nil when nothing was logged.
    func finish() async -> String? {
        guard var s = session else { return nil }
        // Joined: the Watch ends the workout and records it in Health; the phone only leaves. If the Watch never
        // sent a copy (it didn't start), the phone owns the workout after all and finishes it itself.
        if s.isJoined, s.watchSets != nil { await commitEdits(); session = nil; persist(); return nil }
        s.joinedWatch = nil
        guard !s.loggedSets.isEmpty else { discard(); return nil }
        let end = now()
        s.endedAt = end
        s.restEnd = nil
        session = s
        persist()
        if s.hkWorkoutUUID == nil, let uuid = try? await health.saveStrengthWorkout(start: s.startedAt, end: end) {
            session?.hkWorkoutUUID = uuid.uuidString
            persist()
        }
        await upsert()
        let id = s.id.uuidString
        session = nil
        persist()
        return id
    }

    /// Leaves without saving; only offered while nothing was logged.
    func discard() {
        session = nil
        persist()
    }

    // MARK: Server body

    func upsertBody() -> WorkoutUpsert? {
        guard let s = session else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = timeZone
        // Joined: only the phone's own sets, and no end or Health link, which are the Watch's to set. The title and
        // template match the Watch's copy (synced from it, and rename is off while joined), so sending them is safe.
        let header = s.isJoined
            ? WorkoutUpsert.Session(clientId: s.id.uuidString, title: s.title, template: s.template, source: "phone",
                                    startedAt: iso.string(from: s.startedAt), tzOffsetMin: timeZone.secondsFromGMT(for: s.startedAt) / 60)
            : WorkoutUpsert.Session(clientId: s.id.uuidString, title: s.title, template: s.template, source: "phone",
                                    startedAt: iso.string(from: s.startedAt), endedAt: s.endedAt.map(iso.string(from:)),
                                    tzOffsetMin: timeZone.secondsFromGMT(for: s.startedAt) / 60, hkWorkoutUuid: s.hkWorkoutUUID)
        let sets = s.sets.map {
            $0.isLive ? WorkoutUpsert.Set(id: $0.id.uuidString, exercise: $0.exercise, kind: $0.kind, weightKg: $0.weightKg, reps: $0.reps,
                                          targetWeightKg: $0.targetWeightKg, targetReps: $0.targetReps, performedAt: iso.string(from: $0.performedAt),
                                          note: $0.note)
                : .deletion($0.id.uuidString)
        }
        return WorkoutUpsert(session: header, sets: sets)
    }

    private func upsert() async {
        editedSinceUpsert = false
        guard let body = upsertBody(), !body.sets.isEmpty, let request = try? APIRequest.postWorkout(body) else { return }
        await send(request)
    }

    // MARK: Helpers

    private func index(of exerciseID: String) -> Int? { session?.exercises.firstIndex { $0.id == exerciseID } }

    /// Field text → kg; accepts a decimal comma from the keypad.
    nonisolated static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func persist() {
        liveActivity?(session)
        guard let fileURL else { return }
        do {
            if let session {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(session).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            // Locked-device writes fail until first unlock; the next change rewrites the whole file.
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
