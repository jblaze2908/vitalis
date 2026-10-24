import Foundation
import Observation
import VitalisKit

/// Sync screen, token-rejected state (spec 20 §4 "Settings and Sync") and the exporter failure that `StaleState` needs.
@MainActor @Observable
final class SyncStore {
    struct Counts: Equatable, Sendable {
        var exporterBatches = 0
        var outboxItems = 0
        var outboxWorkouts = 0
        /// Sets still on the Watch or relayed but not yet posted.
        var watchSetsHeld = 0
    }

    enum Reachability: Equatable, Sendable { case unknown, reachable, unreachable }

    struct Dependencies {
        var authFailureAt: @MainActor () -> Date? = { nil }
        var noteAuthFailure: @MainActor () -> Void = {}
        var noteAuthOK: @MainActor () -> Void = {}
        var outbox: @MainActor () async -> (pending: [Outbox.Item], failed: [Outbox.Item]) = { ([], []) }
        /// Reads the exporter's pending-page manifests from disk; called on appear/refresh only, never per render.
        var exporterPendingBatches: @Sendable () -> Int = { 0 }
        /// Hook for the Watch relay (21 §6): sets acked by the phone but not yet accepted by the server.
        var watchSetsHeld: @MainActor () -> Int = { 0 }
        var probe: @MainActor () async throws -> SyncStatus = { throw APIError.transport(URLError(.notConnectedToInternet)) }
        /// Reconnect, resume the outbox and run the exporter.
        var resume: @MainActor () async -> Void = {}
        /// Reconnect and release the outbox's auth halt only.
        var resumeOutbox: @MainActor () async -> Void = {}
        var saveToken: @MainActor (String) throws -> Void = { _ in }
        var defaults: UserDefaults = .standard
        var now: @MainActor () -> Date = { Date() }
    }

    static let shared = SyncStore(deps: .live)

    private let deps: Dependencies
    private(set) var counts = Counts()
    private(set) var failedItems: [Outbox.Item] = []
    private(set) var reachability: Reachability = .unknown
    private(set) var isWorking = false
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?
    /// When this phone first saw the exporter's current `lastError` (persisted, since the engine keeps no error time).
    private(set) var exporterErrorSeenAt: Date?

    init(deps: Dependencies) {
        self.deps = deps
        exporterErrorSeenAt = deps.defaults.object(forKey: Keys.errorSeenAt) as? Date
    }

    private enum Keys {
        static let errorText = "exporterErrorText"
        static let errorSeenAt = "exporterErrorSeenAt"
    }

    // MARK: Derived state

    var exporterFailure: SyncFailure? {
        Self.isCurrent(errorSeenAt: exporterErrorSeenAt, lastSuccess: lastSuccess) ? Self.classify(lastError) : nil
    }

    var exporterRejected: Bool { exporterFailure == .unauthorized }

    /// Frame 25: any API call or the exporter's last upload got a 401.
    var tokenRejected: Bool { deps.authFailureAt() != nil || exporterRejected }

    var rejectedSince: Date? { deps.authFailureAt() ?? (exporterRejected ? exporterErrorSeenAt : nil) }

    /// Today's banner (spec 20 §6) from the server's `last_sync` and this phone's exporter state.
    func staleState(lastSync: Date?, cachedAt: Date?, refreshFailed: Bool, calendar: Calendar = .current) -> StaleState {
        let failure = deps.authFailureAt() != nil ? .unauthorized : exporterFailure
        return StaleState(lastSync: lastSync, lastSuccess: lastSuccess, failure: failure, cachedAt: cachedAt,
                          refreshFailed: refreshFailed, now: deps.now(), calendar: calendar)
    }

    // MARK: Inputs

    /// Feed every exporter snapshot (AppModel polls once a second); records when a new error first appeared.
    func observe(_ snapshot: SyncSnapshot) {
        lastSuccess = snapshot.history.lastSuccess
        let error = snapshot.history.lastError
        if error != lastError {
            lastError = error
            let known = deps.defaults.string(forKey: Keys.errorText)
            if error == nil {
                exporterErrorSeenAt = nil
            } else if error != known || exporterErrorSeenAt == nil {
                exporterErrorSeenAt = deps.now()
            }
            deps.defaults.set(error, forKey: Keys.errorText)
            deps.defaults.set(exporterErrorSeenAt, forKey: Keys.errorSeenAt)
        }
        // Persist "since" for an exporter 401; clear it once the exporter uploads again.
        if exporterRejected, deps.authFailureAt() == nil { deps.noteAuthFailure() }
        if let since = deps.authFailureAt(), let ok = lastSuccess, ok > since, !exporterRejected {
            deps.noteAuthOK()
            Task { await deps.resumeOutbox() }
        }
    }

    func refresh() async {
        let batches = deps.exporterPendingBatches
        let exporter = await Task.detached { batches() }.value
        let outbox = await deps.outbox()
        counts = Self.counts(exporterBatches: exporter, pending: outbox.pending, watchSetsHeld: deps.watchSetsHeld())
        failedItems = outbox.failed
    }

    /// Try again: resume everything held, then ask the server whether the token works now.
    func tryAgain() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await deps.resume()
        await probe()
        await refresh()
    }

    /// Replace token: Keychain, then the same path as Try again. The value is never kept or logged.
    func replaceToken(_ token: String) async throws {
        try deps.saveToken(token)
        await tryAgain()
    }

    func probe() async {
        do {
            _ = try await deps.probe()
            reachability = .reachable
            deps.noteAuthOK()
        } catch APIError.unauthorized {
            reachability = .reachable
            deps.noteAuthFailure()
        } catch APIError.transport {
            reachability = .unreachable
        } catch {
            reachability = .reachable
        }
    }

    // MARK: Pure rules (tested)

    static func counts(exporterBatches: Int, pending: [Outbox.Item], watchSetsHeld: Int) -> Counts {
        Counts(exporterBatches: exporterBatches, outboxItems: pending.count,
               outboxWorkouts: pending.filter { $0.path.hasPrefix("v2/workouts") }.count, watchSetsHeld: watchSetsHeld)
    }

    /// A recorded error is current unless an upload succeeded after it was first seen.
    static func isCurrent(errorSeenAt: Date?, lastSuccess: Date?) -> Bool {
        guard let errorSeenAt else { return false }
        return lastSuccess.map { $0 < errorSeenAt } ?? true
    }

    /// The engine records failures as text (`SyncEngine.drain`), so this matches the messages it writes.
    static func classify(_ message: String?) -> SyncFailure? {
        guard let m = message?.lowercased() else { return nil }
        if m.contains("http 401") || m.contains("http 403") || m.contains("write token") { return .unauthorized }
        if m.contains("protected data") || m.contains("unlock") { return .protectedDataUnavailable }
        if let match = m.firstMatch(of: /http (5\d\d)/) { return .server(Int(match.1) ?? 500) }
        let transport = ["offline", "could not connect", "timed out", "hostname", "network connection", "cannot find host", "not connected"]
        if transport.contains(where: m.contains) { return .unreachable }
        return nil
    }

    /// "3 batches and 1 workout are waiting on this phone." Counts only; never a sample total we'd have to compute.
    static func waitingCopy(_ c: Counts) -> String {
        func n(_ v: Int, _ one: String, _ many: String) -> String? { v > 0 ? "\(v.formatted()) \(v == 1 ? one : many)" : nil }
        let other = c.outboxItems - c.outboxWorkouts
        let parts = [n(c.exporterBatches, "batch", "batches"), n(c.outboxWorkouts, "workout", "workouts"),
                     n(other, "change", "changes"), n(c.watchSetsHeld, "Watch set", "Watch sets")].compactMap { $0 }
        guard !parts.isEmpty else { return "Nothing is waiting to upload. New readings stay on this phone until the token works." }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        let total = c.exporterBatches + c.outboxItems + c.watchSetsHeld
        return "\(list) \(total == 1 ? "is" : "are") waiting on this phone. \(total == 1 ? "It uploads" : "They upload") as soon as the token works."
    }

    /// Unsent envelopes across the exporter's pending pages (`PendingPage.batchIDs` after `nextBatch`).
    nonisolated static func countPendingBatches(in root: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("pending-") && $0.hasSuffix(".json") }.reduce(0) { sum, name in
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let page = try? JSONDecoder().decode(PendingPage.self, from: data) else { return sum }
            return sum + max(0, page.batchIDs.count - page.nextBatch)
        }
    }

    /// "WED 4:12 PM"
    static func sinceLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE h:mm a"
        return f.string(from: date).uppercased()
    }

    /// "JUST NOW" · "2 MIN AGO" · "3 H AGO" · day label beyond a day.
    static func agoLabel(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "Never" }
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "Just now"
        case ..<3_600: return "\(Int(s / 60)) min ago"
        case ..<86_400: return "\(Int(s / 3_600)) h ago"
        default: return StaleState.dayLabel(date, now: now, calendar: calendar)
        }
    }
}

extension SyncStore.Dependencies {
    @MainActor static var live: Self {
        let root = try? SyncFiles.applicationSupport().root
        return Self(
            authFailureAt: { Services.shared.firstAuthFailureAt },
            noteAuthFailure: { Services.shared.noteAuthFailure() },
            noteAuthOK: { Services.shared.noteAuthOK() },
            outbox: {
                guard let outbox = Services.shared.outbox else { return ([], []) }
                return (await outbox.pendingItems, await outbox.failedItems)
            },
            exporterPendingBatches: { root.map(SyncStore.countPendingBatches(in:)) ?? 0 },
            probe: {
                guard let api = Services.shared.api else { throw APIError.transport(URLError(.badURL)) }
                return try await api.syncStatus()
            },
            resume: {
                await Services.shared.resumeAfterNewToken()
                await AppModel.shared.syncNow()
            },
            resumeOutbox: { await Services.shared.resumeAfterNewToken() },
            saveToken: { try TokenStore.save($0) })
    }
}
