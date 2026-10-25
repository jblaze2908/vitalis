import Foundation

// Watch ⇄ phone models and messages (spec 21 §5–§6), shared by both apps. The Watch never calls the server:
// everything it shows arrives here from the phone, and everything it logs leaves as a `session` message.

// MARK: - Coding

/// One coder for messages, the pack and the Watch's session files. Keys are spelled out per type (no key strategy)
/// so catalog-id dictionary keys and `…ID` properties survive a round trip untouched.
public enum WatchCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = APIDate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }
}

// MARK: - Session (spec 21 §5)

public struct LoggedSet: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID              // client id = server set id (idempotent)
    public var exerciseID: String    // catalog id, e.g. "barbell-squat"
    public var kind: Kind
    public var weightKg: Double?
    public var reps: Int?
    public var performedAt: Date
    public var deleted: Bool
    public enum Kind: String, Codable, Sendable { case normal, warmup }

    public init(id: UUID = UUID(), exerciseID: String, kind: Kind = .normal, weightKg: Double?, reps: Int?,
                performedAt: Date, deleted: Bool = false) {
        self.id = id; self.exerciseID = exerciseID; self.kind = kind; self.weightKg = weightKg; self.reps = reps
        self.performedAt = performedAt; self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, reps, deleted
        case exerciseID = "exercise_id", weightKg = "weight_kg", performedAt = "performed_at"
    }

    /// One workout logged from two devices (20 §4 shared workout): union by id, `own` wins for its ids, time order.
    public static func merged(own: [LoggedSet], foreign: [LoggedSet]) -> [LoggedSet] {
        let ownIDs = Set(own.map(\.id))
        return (own + foreign.filter { !ownIDs.contains($0.id) }).filter { !$0.deleted }
            .sorted { ($0.performedAt, $0.id.uuidString) < ($1.performedAt, $1.id.uuidString) }
    }
}

public struct WorkoutSessionRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID              // session client_id
    public var title: String
    public var template: String?     // a Settings split id, or nil
    public var source: String        // "watch"
    public var startedAt: Date
    public var endedAt: Date?
    public var tzOffsetMin: Int
    public var hkWorkoutUUID: UUID?
    public var sets: [LoggedSet]
    public var delivery: Delivery
    /// Bumped on every change; the phone echoes it in `ack` so an ack for an older copy can't mark a newer one delivered.
    public var revision: Int
    /// Exercise order for this session (plan, then additions), so crash recovery rebuilds the same sequence.
    public var exerciseIDs: [String]
    /// Sets the phone logged into this workout. Shown and counted, never in `upsert`: the phone posts its own sets.
    public var phoneSets: [LoggedSet]
    public enum Delivery: String, Codable, Sendable { case pending, sentToPhone, ackedByPhone }

    public init(id: UUID = UUID(), title: String, template: String? = nil, source: String = "watch", startedAt: Date,
                endedAt: Date? = nil, tzOffsetMin: Int, hkWorkoutUUID: UUID? = nil, sets: [LoggedSet] = [],
                delivery: Delivery = .pending, revision: Int = 0, exerciseIDs: [String] = [], phoneSets: [LoggedSet] = []) {
        self.id = id; self.title = title; self.template = template; self.source = source; self.startedAt = startedAt
        self.endedAt = endedAt; self.tzOffsetMin = tzOffsetMin; self.hkWorkoutUUID = hkWorkoutUUID; self.sets = sets
        self.delivery = delivery; self.revision = revision; self.exerciseIDs = exerciseIDs; self.phoneSets = phoneSets
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, template, source, sets, delivery, revision
        case startedAt = "started_at", endedAt = "ended_at", tzOffsetMin = "tz_offset_min"
        case hkWorkoutUUID = "hk_workout_uuid", exerciseIDs = "exercise_ids", phoneSets = "phone_sets"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        template = try c.decodeIfPresent(String.self, forKey: .template)
        source = try c.decode(String.self, forKey: .source)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        tzOffsetMin = try c.decode(Int.self, forKey: .tzOffsetMin)
        hkWorkoutUUID = try c.decodeIfPresent(UUID.self, forKey: .hkWorkoutUUID)
        sets = try c.decode([LoggedSet].self, forKey: .sets)
        delivery = try c.decode(Delivery.self, forKey: .delivery)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        exerciseIDs = try c.decodeIfPresent([String].self, forKey: .exerciseIDs) ?? []
        phoneSets = try c.decodeIfPresent([LoggedSet].self, forKey: .phoneSets) ?? []
    }

    public var isLive: Bool { endedAt == nil }
    /// Every set in the workout, both devices, in time order.
    public var allSets: [LoggedSet] { LoggedSet.merged(own: sets, foreign: phoneSets) }
    /// Sets the owner can still see (soft-deleted ones still travel so the server deletes them).
    public var visibleSets: [LoggedSet] { sets.filter { !$0.deleted } }

    /// The `POST /v2/workouts` body the phone queues for this record (10 §6), timestamps in the session's own offset.
    public var upsert: WorkoutUpsert {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: tzOffsetMin * 60) ?? .current
        return WorkoutUpsert(
            session: .init(clientId: id.uuidString, title: title, template: template, source: source,
                           startedAt: iso.string(from: startedAt), endedAt: endedAt.map(iso.string(from:)), tzOffsetMin: tzOffsetMin,
                           hkWorkoutUuid: hkWorkoutUUID?.uuidString),
            sets: sets.map { s in
                s.deleted ? .deletion(s.id.uuidString)
                    : .init(id: s.id.uuidString, exercise: s.exerciseID, kind: s.kind.rawValue, weightKg: s.weightKg,
                            reps: s.reps, performedAt: iso.string(from: s.performedAt))
            })
    }
}

// MARK: - WatchPack (spec 21 §6)

/// Built by the phone from cached server responses; every number here is the server's.
public struct WatchPack: Codable, Sendable, Equatable {
    public struct Settings: Codable, Sendable, Equatable {
        public var restS: Int?
        public var crownStepKg: Double?
        /// Prefill set 1 from the server's `next` suggestion (default on).
        public var useSuggestion: Bool?
        public init(restS: Int? = nil, crownStepKg: Double? = nil, useSuggestion: Bool? = nil) {
            self.restS = restS; self.crownStepKg = crownStepKg; self.useSuggestion = useSuggestion
        }
        private enum CodingKeys: String, CodingKey {
            case restS = "rest_s", crownStepKg = "crown_step_kg", useSuggestion = "use_suggestion"
        }
        public static let defaultRestS = 120
        public static let defaultCrownStepKg = 2.5
        public var rest: Int { restS.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultRestS }
        public var crownStep: Double { crownStepKg.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultCrownStepKg }
        public var suggests: Bool { useSuggestion ?? true }
    }

    /// The owner's split as a start choice (11 §7.3); `template` is nil for history splits, which match by title.
    public struct Split: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var template: String?
        public var name: String
        public var ready: Bool
        public var daysSince: Int?
        public var exerciseIDs: [String]
        public init(id: String, template: String?, name: String, ready: Bool, daysSince: Int?, exerciseIDs: [String]) {
            self.id = id; self.template = template; self.name = name; self.ready = ready; self.daysSince = daysSince; self.exerciseIDs = exerciseIDs
        }
        private enum CodingKeys: String, CodingKey {
            case id, template, name, ready, daysSince = "days_since", exerciseIDs = "exercise_ids"
        }
    }

    public struct RecentSession: Codable, Sendable, Equatable {
        public var title: String
        public var template: String?
        /// Server day, `yyyy-MM-dd`.
        public var day: String
        public var exerciseIDs: [String]
        public init(title: String, template: String?, day: String, exerciseIDs: [String]) {
            self.title = title; self.template = template; self.day = day; self.exerciseIDs = exerciseIDs
        }
        private enum CodingKeys: String, CodingKey { case title, template, day, exerciseIDs = "exercise_ids" }
    }

    public struct PlannedSet: Codable, Sendable, Equatable {
        public var kind: String
        public var weightKg: Double?
        public var reps: Int?
        public init(kind: String = "normal", weightKg: Double?, reps: Int?) { self.kind = kind; self.weightKg = weightKg; self.reps = reps }
        private enum CodingKeys: String, CodingKey { case kind, reps, weightKg = "weight_kg" }
        public var isWorking: Bool { kind != LoggedSet.Kind.warmup.rawValue }
    }

    public struct Next: Codable, Sendable, Equatable {
        public var weightKg: Double?
        public var reps: Int?
        public var sets: Int?
        public init(weightKg: Double?, reps: Int?, sets: Int?) { self.weightKg = weightKg; self.reps = reps; self.sets = sets }
        private enum CodingKeys: String, CodingKey { case reps, sets, weightKg = "weight_kg" }
    }

    public struct Prefill: Codable, Sendable, Equatable {
        /// The server's last session sets for this exercise (`last_session.sets`).
        public var sets: [PlannedSet]
        public var next: Next?
        public init(sets: [PlannedSet], next: Next?) { self.sets = sets; self.next = next }
    }

    public struct Exercise: Codable, Sendable, Equatable {
        public var name: String
        public var equipment: String?
        public var primary: [String]
        public var secondary: [String]
        public var aliases: [String]?
        public var prefill: Prefill?
        public init(name: String, equipment: String? = nil, primary: [String], secondary: [String], aliases: [String]? = nil,
                    prefill: Prefill? = nil) {
            self.name = name; self.equipment = equipment; self.primary = primary; self.secondary = secondary
            self.aliases = aliases; self.prefill = prefill
        }
    }

    public var generatedAt: String
    public var settings: Settings
    public var splits: [Split]
    public var recentSessions: [RecentSession]
    public var exercises: [String: Exercise]
    public var recentExerciseIDs: [String]
    /// The start-choice plan when `sendMessage` couldn't reach the Watch (spec 21 §6 `plan`).
    public var plan: WatchPlan?

    public init(generatedAt: String, settings: Settings = .init(), splits: [Split] = [], recentSessions: [RecentSession] = [],
                exercises: [String: Exercise] = [:], recentExerciseIDs: [String] = [], plan: WatchPlan? = nil) {
        self.generatedAt = generatedAt; self.settings = settings; self.splits = splits; self.recentSessions = recentSessions
        self.exercises = exercises; self.recentExerciseIDs = recentExerciseIDs; self.plan = plan
    }

    private enum CodingKeys: String, CodingKey {
        case settings, splits, exercises, plan
        case generatedAt = "generated_at", recentSessions = "recent_sessions", recentExerciseIDs = "recent_exercise_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? .init()
        splits = try c.decodeIfPresent([Split].self, forKey: .splits) ?? []
        recentSessions = try c.decodeIfPresent([RecentSession].self, forKey: .recentSessions) ?? []
        exercises = try c.decodeIfPresent([String: Exercise].self, forKey: .exercises) ?? [:]
        recentExerciseIDs = try c.decodeIfPresent([String].self, forKey: .recentExerciseIDs) ?? []
        plan = try c.decodeIfPresent(WatchPlan.self, forKey: .plan)
    }
}

/// Selection of server values for set entry (spec 21 §2.2). Nothing is derived beyond picking which value applies.
public extension WatchPack.Exercise {
    static let defaultPlannedSets = 3

    /// `next.sets` when suggestions are on, else last session's working-set count, else 3.
    func plannedSets(suggests: Bool) -> Int {
        if suggests, let n = prefill?.next?.sets, n > 0 { return n }
        let working = prefill?.sets.filter(\.isWorking).count ?? 0
        return working > 0 ? working : Self.defaultPlannedSets
    }

    /// Set 1's values: the server's `next` when suggestions are on, else last session's first working set.
    func firstSet(suggests: Bool) -> (weightKg: Double?, reps: Int?)? {
        if suggests, let next = prefill?.next, next.weightKg != nil || next.reps != nil { return (next.weightKg, next.reps) }
        guard let first = prefill?.sets.first(where: \.isWorking) ?? prefill?.sets.first else { return nil }
        return (first.weightKg, first.reps)
    }

    /// `LAST 97.5`: last session's weight for working set `number` (1-based).
    func lastWeight(setNumber: Int) -> Double? {
        let working = prefill?.sets.filter(\.isWorking) ?? []
        return working.indices.contains(setNumber - 1) ? working[setNumber - 1].weightKg : nil
    }
}

// MARK: - Messages (spec 21 §6)

/// Start-choice plan from the phone (template, exercise ids, intensity).
public struct WatchPlan: Codable, Sendable, Equatable {
    public var title: String?
    public var template: String?
    public var exerciseIDs: [String]
    public var intensity: String?
    /// The phone's workout id, so both devices log one workout (20 §4); nil lets the Watch mint its own.
    public var sessionID: UUID?
    public init(title: String? = nil, template: String?, exerciseIDs: [String], intensity: String? = nil, sessionID: UUID? = nil) {
        self.title = title; self.template = template; self.exerciseIDs = exerciseIDs; self.intensity = intensity; self.sessionID = sessionID
    }
    private enum CodingKeys: String, CodingKey { case title, template, intensity, exerciseIDs = "exercise_ids", sessionID = "session_id" }
}

/// Sent by the phone after its Outbox durably holds `revision` of the session.
public struct WatchAck: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var setIDs: [UUID]
    public var revision: Int
    public init(sessionID: UUID, setIDs: [UUID], revision: Int) { self.sessionID = sessionID; self.setIDs = setIDs; self.revision = revision }
    private enum CodingKeys: String, CodingKey { case revision, sessionID = "session_id", setIDs = "set_ids" }
}

/// Relayed from the `POST /v2/workouts` response: the server's session heat, PRs and totals.
public struct WatchResult: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var heat: MuscleHeat
    public var prs: [WorkoutPostResponse.PR]
    public var durationMin: Int?
    public var workingSets: Int?
    public init(sessionID: UUID, heat: MuscleHeat, prs: [WorkoutPostResponse.PR], durationMin: Int? = nil, workingSets: Int? = nil) {
        self.sessionID = sessionID; self.heat = heat; self.prs = prs; self.durationMin = durationMin; self.workingSets = workingSets
    }
    private enum CodingKeys: String, CodingKey {
        case heat, prs, sessionID = "session_id", durationMin = "duration_min", workingSets = "working_sets"
    }
}

/// Metadata for the catalog file sent with `transferFile` (the file is the `GET /v2/exercises` JSON).
public struct WatchCatalogInfo: Codable, Sendable, Equatable {
    public var etag: String?
    public var count: Int
    public init(etag: String?, count: Int) { self.etag = etag; self.count = count }
}

/// The phone's own sets in a Watch-owned workout, the whole list each time (20 §4 shared workout).
public struct WatchPhoneSets: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var sets: [LoggedSet]
    public init(sessionID: UUID, sets: [LoggedSet]) { self.sessionID = sessionID; self.sets = sets }
    private enum CodingKeys: String, CodingKey { case sets, sessionID = "session_id" }
}

/// Tells the phone a Watch workout is live, so it offers to join it (20 §4).
public struct WatchSessionState: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case live, ended }
    public var sessionID: UUID
    public var state: State
    public init(sessionID: UUID, state: State) { self.sessionID = sessionID; self.state = state }
    private enum CodingKeys: String, CodingKey { case state, sessionID = "session_id" }
}

public enum WatchMessage: Sendable, Equatable {
    case session(WorkoutSessionRecord)
    case ack(WatchAck)
    case result(WatchResult)
    case pack(WatchPack)
    case catalog(WatchCatalogInfo)
    case plan(WatchPlan)
    case sessionState(WatchSessionState)
    case today(TodaySnapshot)
    case phoneSets(WatchPhoneSets)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case session, ack, result, pack, catalog, plan, sessionState = "session_state", today, phoneSets = "phone_sets"
    }

    public var kind: Kind {
        switch self {
        case .session: .session
        case .ack: .ack
        case .result: .result
        case .pack: .pack
        case .catalog: .catalog
        case .plan: .plan
        case .sessionState: .sessionState
        case .today: .today
        case .phoneSets: .phoneSets
        }
    }
}

/// Wire shape `{"type": "<kind>", "body": {…}}`.
extension WatchMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, body }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .session: self = .session(try c.decode(WorkoutSessionRecord.self, forKey: .body))
        case .ack: self = .ack(try c.decode(WatchAck.self, forKey: .body))
        case .result: self = .result(try c.decode(WatchResult.self, forKey: .body))
        case .pack: self = .pack(try c.decode(WatchPack.self, forKey: .body))
        case .catalog: self = .catalog(try c.decode(WatchCatalogInfo.self, forKey: .body))
        case .plan: self = .plan(try c.decode(WatchPlan.self, forKey: .body))
        case .sessionState: self = .sessionState(try c.decode(WatchSessionState.self, forKey: .body))
        case .today: self = .today(try c.decode(TodaySnapshot.self, forKey: .body))
        case .phoneSets: self = .phoneSets(try c.decode(WatchPhoneSets.self, forKey: .body))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .session(let v): try c.encode(v, forKey: .body)
        case .ack(let v): try c.encode(v, forKey: .body)
        case .result(let v): try c.encode(v, forKey: .body)
        case .pack(let v): try c.encode(v, forKey: .body)
        case .catalog(let v): try c.encode(v, forKey: .body)
        case .plan(let v): try c.encode(v, forKey: .body)
        case .sessionState(let v): try c.encode(v, forKey: .body)
        case .today(let v): try c.encode(v, forKey: .body)
        case .phoneSets(let v): try c.encode(v, forKey: .body)
        }
    }
}

public extension WatchMessage {
    /// Property-list dictionary for `transferUserInfo` / `updateApplicationContext` / `sendMessage`.
    /// Nil optionals are omitted by the encoder, so no `NSNull` (not a plist type) reaches WatchConnectivity.
    func dictionary() throws -> [String: Any] {
        let data = try WatchCoding.encoder().encode(self)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "WatchMessage is not an object"))
        }
        return dict
    }

    init(dictionary: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        self = try WatchCoding.decoder().decode(WatchMessage.self, from: data)
    }
}
