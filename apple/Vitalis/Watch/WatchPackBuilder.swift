import Foundation
import VitalisKit

/// The Watch's `WatchPack` (spec 21 §6) from server responses. Pure: every value is copied from a body, nothing derived.
enum WatchPackBuilder {
    /// Design limit for the encoded pack; the oldest recent exercises go first.
    static let byteLimit = 64 * 1024
    static let recentSessionCount = 3
    static let recentExerciseCount = 20
    /// Session rows read for `recent_exercise_ids`.
    static let historyRows = 10

    struct Inputs {
        var training: TrainingResponse?
        var targets: TargetsResponse?
        /// Newest first.
        var sessions: [SessionRow] = []
        /// `GET /v2/training/sessions/:id` bodies by session id.
        var sessionDetails: [String: SessionDetail] = [:]
        /// `GET /v2/exercises/:id` bodies by exercise id.
        var exercises: [String: ExerciseDetail] = [:]
        /// `GET /v2/exercises` entries by id (names, muscles and aliases for ids without a detail body).
        var catalog: [String: ExerciseInfo] = [:]
    }

    static func strengthRows(_ inputs: Inputs) -> [SessionRow] {
        Array(inputs.sessions.filter { $0.kind == "strength" }.prefix(historyRows))
    }

    /// Last 20 exercise ids used, newest session first; empty when no session detail is cached.
    static func recentExerciseIDs(_ inputs: Inputs) -> [String] {
        var seen = Set<String>()
        let ids = strengthRows(inputs).flatMap { inputs.sessionDetails[$0.id]?.exercises?.map(\.id) ?? [] }
        return Array(ids.filter { seen.insert($0).inserted }.prefix(recentExerciseCount))
    }

    static func recentSessions(_ inputs: Inputs) -> [WatchPack.RecentSession] {
        // A row without its detail has no exercise list to repeat, so it is left out rather than sent empty.
        strengthRows(inputs).compactMap { row -> WatchPack.RecentSession? in
            guard let detail = inputs.sessionDetails[row.id], let ids = detail.exercises?.map(\.id), !ids.isEmpty else { return nil }
            return WatchPack.RecentSession(title: row.title ?? detail.title ?? "Workout", template: detail.template, day: row.day,
                                           exerciseIDs: ids)
        }
        .prefix(recentSessionCount).map { $0 }
    }

    /// Ids whose `GET /v2/exercises/:id` the sender fetches: due, recent sessions, recent exercises.
    static func neededExerciseIDs(_ inputs: Inputs) -> [String] {
        var seen = Set<String>()
        let ids = (inputs.training?.due?.exercises.map(\.id) ?? []) + recentSessions(inputs).flatMap(\.exerciseIDs)
            + recentExerciseIDs(inputs)
        return ids.filter { seen.insert($0).inserted }
    }

    static func build(_ inputs: Inputs, generatedAt: Date) -> WatchPack {
        let due = inputs.training?.due.map {
            WatchPack.Due(template: $0.template, name: $0.name, daysSince: $0.daysSince, exerciseIDs: $0.exercises.map(\.id))
        }
        let dueNames = Dictionary(inputs.training?.due?.exercises.map { ($0.id, $0.name) } ?? [], uniquingKeysWith: { a, _ in a })
        var exercises: [String: WatchPack.Exercise] = [:]
        for id in neededExerciseIDs(inputs) {
            exercises[id] = exercise(detail: inputs.exercises[id], info: inputs.catalog[id], dueName: dueNames[id])
        }
        let values = inputs.targets?.values
        let pack = WatchPack(generatedAt: timestamp(generatedAt),
                             settings: .init(restS: values?.restS, crownStepKg: values?.crownStepKg),
                             due: due, recentSessions: recentSessions(inputs), exercises: exercises,
                             recentExerciseIDs: recentExerciseIDs(inputs))
        return trimmed(pack)
    }

    static func exercise(detail: ExerciseDetail?, info: ExerciseInfo?, dueName: String?) -> WatchPack.Exercise? {
        if let detail {
            let e = detail.exercise
            return WatchPack.Exercise(name: e.name, equipment: e.equipment, primary: e.primary, secondary: e.secondary,
                                      aliases: info?.aliases ?? e.aliases, prefill: prefill(detail))
        }
        if let info {
            return WatchPack.Exercise(name: info.name, equipment: info.equipment, primary: info.primary, secondary: info.secondary,
                                      aliases: info.aliases)
        }
        return dueName.map { WatchPack.Exercise(name: $0, primary: [], secondary: []) }
    }

    /// Last session's sets and the server's `next` suggestion, as returned.
    static func prefill(_ detail: ExerciseDetail) -> WatchPack.Prefill? {
        let sets = detail.lastSession?.sets.map { WatchPack.PlannedSet(kind: $0.kind, weightKg: $0.weightKg, reps: $0.reps) } ?? []
        let next = detail.next.map { WatchPack.Next(weightKg: $0.weightKg, reps: $0.reps, sets: $0.sets) }
        return sets.isEmpty && next == nil ? nil : WatchPack.Prefill(sets: sets, next: next)
    }

    /// Drops the oldest recent exercises (never the due template's or a recent session's) until the pack fits.
    /// Encodes once per drop, and only when the first encode is over the limit.
    static func trimmed(_ pack: WatchPack, limit: Int = byteLimit) -> WatchPack {
        var out = pack
        let keep = Set((pack.due?.exerciseIDs ?? []) + pack.recentSessions.flatMap(\.exerciseIDs) + (pack.plan?.exerciseIDs ?? []))
        var droppable = pack.recentExerciseIDs.reversed().filter { !keep.contains($0) }
        while size(out) > limit, !droppable.isEmpty {
            let id = droppable.removeFirst()
            out.exercises[id] = nil
            out.recentExerciseIDs.removeAll { $0 == id }
        }
        return out
    }

    static func size(_ pack: WatchPack) -> Int { (try? WatchCoding.encoder().encode(pack).count) ?? .max }

    /// `2026-10-24T09:41:02+05:30`, the phone's own offset.
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
}

/// Fetches the pack's inputs and hands the result to `PhoneSessionDelegate`; also sends the catalog when its ETag changes.
@MainActor final class WatchPackSender {
    static let shared = WatchPackSender()
    /// Rebuilds at most this often unless a finished Watch workout changed the server's prefill.
    static let minimumInterval: TimeInterval = 15 * 60
    private static let catalogKey = "watchCatalogVersion"

    private var lastBuilt: Date?
    private var running = false
    private var stale = false

    func markStale() {
        stale = true
        Task { await refresh() }
    }

    /// Per wake or Today refresh, throttled to 15 min. One run: training, targets, sessions, ≤ 10 session details,
    /// the catalog and ≤ ~26 exercise details, all ETag-revalidated (mostly 304s), details fetched concurrently.
    func refresh() async {
        let relay = PhoneSessionDelegate.shared
        guard !running, relay.channel?.hasWatchApp == true, let api = Services.shared.api else { return }
        if !stale, let lastBuilt, Date().timeIntervalSince(lastBuilt) < Self.minimumInterval { return }
        running = true
        stale = false
        defer { running = false }

        var inputs = WatchPackBuilder.Inputs()
        inputs.training = await Self.read({ try await api.training() }, { await api.cached(TrainingResponse.self, path: "v2/training") })?.value
        inputs.targets = await Self.read({ try await api.targets() }, { await api.cached(TargetsResponse.self, path: "v2/targets") })?.value
        let limit = WatchPackBuilder.historyRows
        inputs.sessions = await Self.read({ try await api.sessions(limit: limit) },
                                          { await api.cached(SessionsPage.self, path: "v2/training/sessions",
                                                             query: VitalisAPI.query(["limit": String(limit)])) })?.value.sessions
            ?? inputs.training?.sessions ?? []
        inputs.sessionDetails = await Self.details(WatchPackBuilder.strengthRows(inputs).map(\.id)) { id in
            await Self.read({ try await api.session(id: id) },
                            { await api.cached(SessionDetail.self, path: "v2/training/sessions/\(HTTPCore.pathSegment(id))") })?.value
        }
        if let catalog = await Self.read({ try await api.exercises() }, { await api.cached(ExerciseList.self, path: "v2/exercises") }) {
            inputs.catalog = Dictionary(catalog.value.exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            sendCatalogIfChanged(catalog)
        }
        inputs.exercises = await Self.details(WatchPackBuilder.neededExerciseIDs(inputs)) { id in
            await Self.read({ try await api.exercise(id: id) },
                            { await api.cached(ExerciseDetail.self, path: "v2/exercises/\(HTTPCore.pathSegment(id))") })?.value
        }
        relay.publish(pack: WatchPackBuilder.build(inputs, generatedAt: Date()))
        lastBuilt = Date()
    }

    /// The catalog travels as a file (`transferFile`), only when its version changes.
    private func sendCatalogIfChanged(_ response: APIResponse<ExerciseList>) {
        let version = response.etag ?? "\(response.value.count)-\(response.value.generatedAt ?? "")"
        guard version != UserDefaults.standard.string(forKey: Self.catalogKey),
              let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? APICoding.encoder().encode(response.value) else { return }
        let url = dir.appendingPathComponent("watch-catalog.json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        guard PhoneSessionDelegate.shared.queueCatalog(url, info: WatchCatalogInfo(etag: response.etag, count: response.value.count))
        else { return }
        UserDefaults.standard.set(version, forKey: Self.catalogKey)
    }

    /// A failed or superseded file transfer: send the catalog again on the next refresh.
    func catalogTransferFailed() {
        UserDefaults.standard.removeObject(forKey: Self.catalogKey)
    }

    nonisolated private static func read<T: Sendable>(_ fetch: @Sendable () async throws -> APIResponse<T>,
                                                      _ cached: @Sendable () async -> APIResponse<T>?) async -> APIResponse<T>? {
        do { return try await fetch() } catch { return await cached() }
    }

    nonisolated private static func details<T: Sendable>(_ ids: [String], _ load: @escaping @Sendable (String) async -> T?) async -> [String: T] {
        await withTaskGroup(of: (String, T?).self) { group in
            for id in ids { group.addTask { (id, await load(id)) } }
            var out: [String: T] = [:]
            for await (id, value) in group { if let value { out[id] = value } }
            return out
        }
    }
}
