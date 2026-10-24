import CryptoKit
import Foundation

/// Last good body per (path, normalised query), so screens render offline and reads revalidate with ETags (20 §5.2).
public actor ResponseCache {
    public struct Entry: Codable, Sendable, Equatable {
        public let key: String
        public let etag: String?
        public let fetchedAt: Date
        /// The `date`/`end`/`week` query value, for pruning day-keyed responses.
        public let day: String?
        public let body: Data
    }

    public let directory: URL

    /// App Group container when `appGroup` resolves, else `Application Support/Vitalis/cache`.
    public static func defaultDirectory(appGroup: String?) throws -> URL {
        if let appGroup, let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return shared.appendingPathComponent("Library/Caches/Vitalis/cache", isDirectory: true)
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("Vitalis/cache", isDirectory: true)
    }

    public init(appGroup: String?) throws {
        try self.init(directory: Self.defaultDirectory(appGroup: appGroup))
    }

    public init(directory: URL) throws {
        self.directory = directory
        try Self.prepare(directory)
    }

    /// Stable key: path without a leading slash, then query items sorted by name and value.
    public static func key(path: String, query: [URLQueryItem]) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let items = query.filter { $0.value != nil }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        guard !items.isEmpty else { return trimmed }
        return trimmed + "?" + items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    static let dayParameters: Swift.Set<String> = ["date", "end", "week"]

    public func entry(forKey key: String) -> Entry? {
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A corrupt or foreign file is treated as a miss and removed.
        guard let entry = try? Self.decoder.decode(Entry.self, from: data), entry.key == key else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return entry
    }

    public func entry(path: String, query: [URLQueryItem] = []) -> Entry? {
        entry(forKey: Self.key(path: path, query: query))
    }

    @discardableResult
    public func store(path: String, query: [URLQueryItem], etag: String?, body: Data, fetchedAt: Date) throws -> Entry {
        let day = query.first { Self.dayParameters.contains($0.name) }?.value
        let entry = Entry(key: Self.key(path: path, query: query), etag: etag, fetchedAt: fetchedAt, day: day, body: body)
        try write(entry)
        return entry
    }

    /// A 304 confirms the cached body is current, so its `fetchedAt` moves to now.
    public func touch(_ entry: Entry, at date: Date) throws -> Entry {
        let updated = Entry(key: entry.key, etag: entry.etag, fetchedAt: date, day: entry.day, body: entry.body)
        try write(updated)
        return updated
    }

    /// Drops day-keyed entries whose day, or fetch time, is older than `age`; undated keys (today, targets) stay.
    @discardableResult
    public func prune(olderThan age: TimeInterval = 30 * 86_400, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-age)
        let cutoffDay = Date.ISO8601FormatStyle().year().month().day().format(cutoff)
        var removed = 0
        for url in files() {
            guard let data = try? Data(contentsOf: url), let entry = try? Self.decoder.decode(Entry.self, from: data) else {
                try? FileManager.default.removeItem(at: url); removed += 1; continue
            }
            guard let day = entry.day else { continue }
            if day < cutoffDay || entry.fetchedAt < cutoff {
                try? FileManager.default.removeItem(at: url); removed += 1
            }
        }
        return removed
    }

    /// On "Reset local export state" and when the token moves to a different server.
    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try Self.prepare(directory)
    }

    public var count: Int { files().count }

    // MARK: Files

    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; d.dateDecodingStrategy = .secondsSince1970
        return d
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func fileURL(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }

    private func write(_ entry: Entry) throws {
        try Self.encoder.encode(entry).write(to: fileURL(entry.key),
                                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }
}
