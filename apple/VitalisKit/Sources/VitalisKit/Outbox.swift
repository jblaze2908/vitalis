import Foundation
#if canImport(Network)
import Network
#endif

/// Durable, ordered queue of app writes (20 §5.3). Every body carries client UUIDs, so replays are idempotent.
public actor Outbox {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let method: String
        public let path: String
        /// The JSON body as text, so the file stays readable and numbers stay byte-exact.
        public let body: String?
        public let createdAt: Date
        public var attempts: Int
        public var lastError: String?
        public var nextAttemptAt: Date?

        public var request: APIRequest { APIRequest(method: method, path: path, body: body.map { Data($0.utf8) }) }
    }

    /// A 2xx reply, so a store can render the server's response (e.g. the food day after an add).
    public struct Delivery: Sendable, Equatable {
        public let item: Item
        public let status: Int
        public let body: Data
    }

    public enum Stop: Sendable, Equatable {
        /// Queue drained.
        case empty
        /// 401/403 (or no token): items kept, flushing halted until `resumeAfterAuth()`.
        case unauthorized(Int)
        /// Head kept for retry (429/5xx/transport) or not yet due.
        case retryAt(Date)
        /// Another flush is running.
        case busy
    }

    public struct FlushResult: Sendable, Equatable {
        public var delivered: [Delivery] = []
        public var failed: [Item] = []
        public var stop: Stop = .empty
    }

    /// Retry delays after the 1st, 2nd, 3rd and later failures (10 min cap).
    public static let backoff: [TimeInterval] = [5, 30, 120, 600]

    public nonisolated let directory: URL
    private let now: @Sendable () -> Date
    private var items: [Item]
    private var failed: [Item]
    private var inFlight: UUID?
    private var flushing = false
    private var transport: (any OutboxTransport)?
    private var authFailureHandler: (@Sendable (Int) -> Void)?
    /// The 401/403 that halted flushing, or nil.
    public private(set) var authHaltStatus: Int?
    public var authHalted: Bool { authHaltStatus != nil }
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif

    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("Vitalis/outbox", isDirectory: true)
    }

    /// Re-opening the same directory restores every pending item in order (crash recovery).
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.directory = directory
        self.now = now
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        items = try Self.read(directory.appendingPathComponent("outbox.jsonl"))
        failed = try Self.read(directory.appendingPathComponent("failed.jsonl"))
    }

    // MARK: State

    public var pendingCount: Int { items.count }
    public var pendingItems: [Item] { items }
    public var failedItems: [Item] { failed }

    /// Called on 401/403 with the status; the Sync screen shows the token-rejected state.
    public func setOnAuthFailure(_ handler: (@Sendable (Int) -> Void)?) { authFailureHandler = handler }

    /// After the token is replaced; the next flush tries the head again immediately.
    public func resumeAfterAuth() {
        authHaltStatus = nil
        if let head = items.first { update(head.id) { $0.nextAttemptAt = nil } }
    }

    // MARK: Queue

    /// Appends a write and, when a transport is attached, starts a flush.
    @discardableResult
    public func enqueue(_ request: APIRequest) throws -> UUID {
        let item = Item(id: UUID(), method: request.method, path: request.path,
                        body: request.body.map { String(decoding: $0, as: UTF8.self) },
                        createdAt: now(), attempts: 0, lastError: nil, nextAttemptAt: nil)
        items.append(item)
        do { try persistPending() } catch { items.removeLast(); throw error }
        if let transport { Task { await self.flush(using: transport) } }
        return item.id
    }

    /// Undo before send: removes an item that hasn't gone out. False when it is in flight or already delivered,
    /// in which case the caller enqueues the compensating DELETE.
    @discardableResult
    public func drop(id: UUID) throws -> Bool {
        guard inFlight != id, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let removed = items.remove(at: index)
        do { try persistPending() } catch { items.insert(removed, at: index); throw error }
        return true
    }

    public func dismissFailed(id: UUID) throws {
        failed.removeAll { $0.id == id }
        try Self.write(failed, to: failedURL)
    }

    /// Clears pending and failed items (reset / server change).
    public func removeAll() throws {
        items = []; failed = []; authHaltStatus = nil
        try persistPending(); try Self.write(failed, to: failedURL)
    }

    // MARK: Flush

    /// Sends items strictly in order, stopping at the head on anything retryable so no later write overtakes it.
    @discardableResult
    public func flush(using transport: any OutboxTransport, ignoringBackoff: Bool = false) async -> FlushResult {
        var result = FlushResult()
        guard !flushing else { result.stop = .busy; return result }
        if let status = authHaltStatus { result.stop = .unauthorized(status); return result }
        flushing = true
        defer { flushing = false; inFlight = nil }

        while let head = items.first {
            if !ignoringBackoff, let due = head.nextAttemptAt, due > now() { result.stop = .retryAt(due); return result }
            inFlight = head.id
            let outcome: (status: Int, body: Data)
            do {
                outcome = try await transport.perform(head.request)
            } catch HTTPCore.Failure.missingToken {
                haltForAuth(head.id, status: 401, message: "No token saved")
                result.stop = .unauthorized(401); return result
            } catch {
                let message = (error as? URLError).map { "Network: \($0.code.rawValue)" } ?? String(describing: type(of: error))
                result.stop = .retryAt(scheduleRetry(head.id, message: message)); return result
            }
            inFlight = nil
            let status = outcome.status
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: outcome.body))?.error
            switch status {
            case 200..<300:
                removeHead(head.id)
                result.delivered.append(Delivery(item: head, status: status, body: outcome.body))
            case 401, 403:
                haltForAuth(head.id, status: status, message: message ?? "HTTP \(status)")
                result.stop = .unauthorized(status); return result
            case 408, 429, 500...:
                result.stop = .retryAt(scheduleRetry(head.id, message: message ?? "HTTP \(status)")); return result
            default:
                // 409/422 and other 4xx: resending the same body can never succeed.
                var dead = head
                dead.attempts += 1
                dead.lastError = message ?? "HTTP \(status)"
                dead.nextAttemptAt = nil
                failed.append(dead)
                try? Self.write(failed, to: failedURL)
                removeHead(head.id)
                result.failed.append(dead)
            }
        }
        result.stop = .empty
        return result
    }

    // MARK: Triggers

    /// Lets `enqueue` and network changes flush on their own; tests call `flush(using:)` directly instead.
    public func attach(_ transport: (any OutboxTransport)?) { self.transport = transport }

    /// Flushes (ignoring backoff) whenever the network path becomes satisfied.
    public func startMonitoringNetwork() {
        #if canImport(Network)
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied, let self else { return }
            Task { await self.flushAttached(ignoringBackoff: true) }
        }
        monitor.start(queue: DispatchQueue(label: "Vitalis.Outbox.path"))
        self.monitor = monitor
        #endif
    }

    public func stopMonitoringNetwork() {
        #if canImport(Network)
        monitor?.cancel(); monitor = nil
        #endif
    }

    @discardableResult
    public func flushAttached(ignoringBackoff: Bool = false) async -> FlushResult? {
        guard let transport else { return nil }
        return await flush(using: transport, ignoringBackoff: ignoringBackoff)
    }

    // MARK: Private

    private var pendingURL: URL { directory.appendingPathComponent("outbox.jsonl") }
    private var failedURL: URL { directory.appendingPathComponent("failed.jsonl") }

    private func haltForAuth(_ id: UUID, status: Int, message: String) {
        update(id) { $0.attempts += 1; $0.lastError = message }
        authHaltStatus = status
        authFailureHandler?(status)
    }

    private func scheduleRetry(_ id: UUID, message: String) -> Date {
        var due = now()
        update(id) { item in
            item.attempts += 1
            item.lastError = message
            due = now().addingTimeInterval(Self.backoff[min(item.attempts, Self.backoff.count) - 1])
            item.nextAttemptAt = due
        }
        return due
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        try? persistPending()
    }

    private func removeHead(_ id: UUID) {
        items.removeAll { $0.id == id }
        try? persistPending()
    }

    private func persistPending() throws { try Self.write(items, to: pendingURL) }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    /// One JSON object per line, rewritten atomically so a crash leaves either the old or the new file.
    private static func write(_ items: [Item], to url: URL) throws {
        let encoder = coder().0
        var data = Data()
        for item in items { data.append(try encoder.encode(item)); data.append(0x0A) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func read(_ url: URL) throws -> [Item] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = coder().1
        return try data.split(separator: 0x0A).map { try decoder.decode(Item.self, from: Data($0)) }
    }
}
