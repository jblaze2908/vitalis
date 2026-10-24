import Foundation

/// The Watch's offline queue (spec 21 §5): one JSON file per session, `sessions/<client_id>.json`, rewritten atomically
/// after every change so a crash leaves either the previous or the new copy. Also keeps the last `WatchPack` for offline launches.
/// Every call is synchronous disk I/O on a file of a few KB; callers run it once per user action, never per frame.
public struct WatchSessionStore: Sendable {
    public static let retention: TimeInterval = 14 * 24 * 3600

    public let root: URL
    var sessionsDirectory: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    var packURL: URL { root.appendingPathComponent("pack.json") }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions", isDirectory: true),
                                                withIntermediateDirectories: true)
    }

    /// `Application Support/Watch` of the running app.
    public static func standard() throws -> WatchSessionStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try WatchSessionStore(root: base.appendingPathComponent("Watch", isDirectory: true))
    }

    // MARK: Sessions

    func url(for id: UUID) -> URL { sessionsDirectory.appendingPathComponent("\(id.uuidString).json") }

    /// Writes before the UI confirms (spec 21 §2.2); a throw means the change must not be shown as logged.
    public func save(_ record: WorkoutSessionRecord) throws {
        try Self.write(try WatchCoding.encoder().encode(record), to: url(for: record.id))
    }

    public func load(_ id: UUID) -> WorkoutSessionRecord? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? WatchCoding.decoder().decode(WorkoutSessionRecord.self, from: data)
    }

    /// Every readable session, newest first. Unreadable files are skipped, never deleted: they may hold un-acked sets.
    public func all() -> [WorkoutSessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = WatchCoding.decoder()
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(WorkoutSessionRecord.self, from: $0) } }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Crash recovery: the newest session that never ended.
    public func liveSession() -> WorkoutSessionRecord? { all().first(where: \.isLive) }

    /// Sessions the phone has not yet confirmed, oldest first, for re-sending after a relaunch.
    public func undelivered() -> [WorkoutSessionRecord] {
        all().filter { $0.delivery != .ackedByPhone }.reversed()
    }

    /// `transferUserInfo` queued this revision; a newer local change keeps the record `pending`.
    @discardableResult
    public func markSent(_ id: UUID, revision: Int) throws -> WorkoutSessionRecord? {
        guard var record = load(id), record.revision == revision, record.delivery == .pending else { return load(id) }
        record.delivery = .sentToPhone
        try save(record)
        return record
    }

    /// Applies a phone `ack`: only an ack for the current revision covering every set marks the session delivered.
    @discardableResult
    public func applyAck(_ ack: WatchAck) throws -> WorkoutSessionRecord? {
        guard var record = load(ack.sessionID) else { return nil }
        let acked = Set(ack.setIDs)
        guard ack.revision >= record.revision, record.sets.allSatisfy({ acked.contains($0.id) }) else { return record }
        record.delivery = .ackedByPhone
        try save(record)
        return record
    }

    /// Deletes ended, acked sessions older than 14 days; never an un-acked or live one. Returns the deleted ids.
    @discardableResult
    public func prune(now: Date, retention: TimeInterval = Self.retention) -> [UUID] {
        all().filter { r in
            guard r.delivery == .ackedByPhone, let ended = r.endedAt else { return false }
            return now.timeIntervalSince(ended) > retention
        }
        .compactMap { r in (try? FileManager.default.removeItem(at: url(for: r.id))) == nil ? nil : r.id }
    }

    // MARK: Pack

    public func savePack(_ pack: WatchPack) throws {
        try Self.write(try WatchCoding.encoder().encode(pack), to: packURL)
    }

    public func loadPack() -> WatchPack? {
        guard let data = try? Data(contentsOf: packURL) else { return nil }
        return try? WatchCoding.decoder().decode(WatchPack.self, from: data)
    }

    // `.atomic` writes a temporary file and renames it over the old one.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
