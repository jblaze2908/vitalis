import Foundation
import Observation
import VitalisKit

/// One API client, response cache and outbox for the whole app. Stores read through `api`; every write goes
/// through `send(_:)` so it survives offline and crashes (spec 20 §5.3).
@MainActor @Observable
final class Services {
    static let shared = Services()

    let cache: ResponseCache?
    let outbox: Outbox?
    private(set) var api: VitalisAPI?
    private(set) var outboxPending = 0
    private(set) var outboxFailed: [Outbox.Item] = []
    /// Bumped after each flush that delivered something, so screens refetch.
    private(set) var writesVersion = 0
    /// When a 401/403 was first seen; cleared by the next success (drives the token-rejected state).
    private(set) var firstAuthFailureAt: Date? = UserDefaults.standard.object(forKey: "firstAuthFailureAt") as? Date
    let isDemo: Bool

    private init() {
        #if DEBUG
        isDemo = ProcessInfo.processInfo.arguments.contains("-VitalisDemo")
        #else
        isDemo = false
        #endif
        cache = try? ResponseCache(appGroup: nil)
        outbox = try? Outbox(directory: Outbox.defaultDirectory())
        reconnect()
    }

    /// Rebuild the client after the server URL or token changes.
    func reconnect() {
        #if DEBUG
        if isDemo {
            api = VitalisAPI(baseURL: URL(string: "https://demo.vitalis.invalid")!, cache: nil, token: { "vtl_demo" }, protocolClasses: [DemoURLProtocol.self])
            return
        }
        #endif
        api = (try? ServerSettings(SettingsStore.baseURL)).map { VitalisAPI(settings: $0, cache: cache) }
        Task { await outbox?.attach(api) }
    }

    func start() {
        guard let outbox else { return }
        Task {
            await outbox.setOnAuthFailure { _ in Task { @MainActor in Services.shared.noteAuthFailure() } }
            await outbox.attach(api)
            await outbox.startMonitoringNetwork()
            await flush()
        }
    }

    /// Queue a write and try to deliver it now. Returns the outbox id (Undo can drop it before it is sent).
    @discardableResult
    /// A direct (not queued) write landed: screens keyed on `writesVersion` refetch.
    func noteWrite() { writesVersion += 1 }

    func send(_ request: APIRequest) async -> UUID? {
        guard let outbox else { return nil }
        let id = try? await outbox.enqueue(request)
        await flush()
        return id
    }

    func flush() async {
        guard let outbox, let api else { return }
        let result = await outbox.flush(using: api)
        outboxPending = await outbox.pendingCount
        outboxFailed = await outbox.failedItems
        if !result.delivered.isEmpty { writesVersion += 1; noteAuthOK() }
    }

    /// Drop a queued write that hasn't been sent yet (Undo before sync).
    func drop(_ id: UUID) async -> Bool {
        let dropped = (try? await outbox?.drop(id: id)) ?? false
        outboxPending = await outbox?.pendingCount ?? 0
        return dropped
    }

    func noteAuthFailure() {
        if firstAuthFailureAt == nil { firstAuthFailureAt = Date(); UserDefaults.standard.set(firstAuthFailureAt, forKey: "firstAuthFailureAt") }
    }

    func noteAuthOK() {
        guard firstAuthFailureAt != nil else { return }
        firstAuthFailureAt = nil
        UserDefaults.standard.removeObject(forKey: "firstAuthFailureAt")
    }

    /// After a token replacement: clear the halt and retry everything held.
    func resumeAfterNewToken() async {
        reconnect()
        await outbox?.resumeAfterAuth()
        await flush()
    }
}

/// A screen's data: the last good value (possibly cached), when it was fetched, and the latest error.
@MainActor @Observable
final class Loadable<Value: Sendable> {
    private(set) var value: Value?
    private(set) var fetchedAt: Date?
    private(set) var fromCache = false
    private(set) var error: Error?
    private(set) var isLoading = false

    init(_ value: Value? = nil) { self.value = value }

    /// Show the cached body first (no spinner), then revalidate.
    func load(cached: (() async -> APIResponse<Value>?)? = nil, _ fetch: () async throws -> APIResponse<Value>) async {
        if value == nil, let c = await cached?() { apply(c) }
        isLoading = true
        defer { isLoading = false }
        do { apply(try await fetch()); error = nil }
        catch {
            self.error = error
            if case APIError.unauthorized = error { Services.shared.noteAuthFailure() }
        }
    }

    func set(_ v: Value) { value = v; fetchedAt = Date(); fromCache = false }

    private func apply(_ r: APIResponse<Value>) { value = r.value; fetchedAt = r.fetchedAt; fromCache = r.fromCache }
}

extension APIError {
    /// Short mono line for a failed refresh with cached data on screen.
    var statusLine: String {
        switch self {
        case .unauthorized: "TOKEN REJECTED"
        case .scope: "TOKEN CAN'T DO THIS"
        case .transport: "OFFLINE"
        case .unavailable: "SERVER UNAVAILABLE"
        case .rateLimited: "SERVER BUSY"
        default: "COULDN'T UPDATE"
        }
    }
}

#if DEBUG
/// `-VitalisDemo`: answers every request from bundled fixtures, so screens can be shown and screenshotted without a server.
final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    static let routes: [(prefix: String, file: String)] = [
        ("/v2/sync/status", "sync-status"), ("/v2/targets", "targets"), ("/v2/today", "today"), ("/v2/digest", "digest"),
        ("/v2/sleep/week", "sleep-week"), ("/v2/sleep/month", "sleep-month"), ("/v2/sleep", "sleep"), ("/v2/body", "body"), ("/v2/training/sessions/", "training-session"),
        ("/v2/training/exercises", "training-exercises"), ("/v2/heart", "heart"), ("/v2/metrics/", "metric"), ("/v2/metrics", "metrics"),
        ("/v2/training/sessions", "training-sessions"), ("/v2/training", "training"), ("/v2/exercises/", "exercise"),
        ("/v2/exercises", "exercises-search"), ("/v2/food/day", "food-day"), ("/v2/food/entries", "food-entries-post"), ("/v2/food/meals/", "food-meal-delete"), ("/v2/food/quick", "food-quick"),
        ("/v2/food/search", "food-search"), ("/v2/food/barcode/00000000", "barcode-not-found"), ("/v2/food/barcode/", "barcode"),
        ("/v2/food/describe", "describe"), ("/v2/weight", "weight-post"),
    ]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let file = Self.routes.first { path.hasPrefix($0.prefix) }?.file
        var data = file.flatMap { Bundle.main.url(forResource: $0, withExtension: "json") }.flatMap { try? Data(contentsOf: $0) }
        // Fixtures are recorded once; stamping last_sync with now keeps the demo out of the stale state on any later day.
        if let d = data, var text = String(data: d, encoding: .utf8),
           let r = text.range(of: #""last_sync": ?"[^"]*""#, options: .regularExpression) {
            text.replaceSubrange(r, with: "\"last_sync\": \"\(ISO8601DateFormatter().string(from: Date()))\"")
            data = Data(text.utf8)
        }
        let status = data == nil ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data(#"{"error":"Not in demo data","code":"not_found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
