@preconcurrency import HealthKit
import Foundation
import UIKit
import VitalisKit

actor SyncEngine {
    private let registry: HealthTypes
    private let reader: HealthReader
    private let files: SyncFiles
    private let clientInfo: ClientInfo
    private var server: ServerSettings?
    private var history: SyncHistory
    private var requestedBackfills: Set<String>
    private var phase = "Idle"
    private var currentType: String?
    private var pageCount = 0
    private var pending: Set<String> = []
    private var job: Task<Void, Never>?
    private struct Waiter {
        var remaining: Set<String>
        var success = true
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [UUID: Waiter] = [:]
    private var cancellationRequested = false

    init(registry: HealthTypes, store: HKHealthStore, files: SyncFiles, clientInfo: ClientInfo, server: ServerSettings?) throws {
        self.registry = registry; reader = HealthReader(store: store, registry: registry)
        self.files = files; self.clientInfo = clientInfo; self.server = server
        history = try files.load(SyncHistory.self, from: files.file("history.json")) ?? SyncHistory()
        requestedBackfills = Set(try files.load([String].self, from: files.file("backfills.json")) ?? [])
        history.diagnostics = registry.diagnostics
        for type in registry.samples where history.types[type.identifier] == nil { history.types[type.identifier] = TypeHistory() }
        try Self.cleanOrphanBatches(files)
    }

    func snapshot() -> SyncSnapshot { SyncSnapshot(phase: phase, currentType: currentType, page: pageCount, history: history) }
    func configure(_ server: ServerSettings) throws {
        guard job == nil else { throw EngineError.busy }
        self.server = server
    }
    func backgroundStatus(type: String, message: String) {
        var status = history.types[type] ?? TypeHistory(); status.backgroundDelivery = message
        history.types[type] = status
        persistOrRecordFailure()
    }
    func recordError(_ message: String) {
        history.lastError = message
        persistOrRecordFailure()
    }

    /// Coalesce observer/manual/BG requests while resolving each caller as soon as
    /// its requested pipelines finish. Observers need not wait for unrelated backfills.
    func sync(types: [String]? = nil) async -> Bool {
        let known = Set(registry.samples.map(\.identifier))
        let requested = Set(types ?? Array(known)).intersection(known)
        guard !requested.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            waiters[UUID()] = Waiter(remaining: requested, continuation: continuation)
            pending.formUnion(requested)
            if job == nil {
                cancellationRequested = false
                job = Task { await self.drain() }
            }
        }
    }
    func cancel() {
        cancellationRequested = true
        pending.removeAll()
        job?.cancel() // Query bridges stop their active queries and resume continuations.
    }
    func requestHistoryBackfill() throws {
        // HealthKit hides read denials. A newly granted type may expose old samples,
        // so a completed authorization sheet explicitly requests a new history pass.
        requestedBackfills.formUnion(registry.samples.map(\.identifier))
        try files.save(requestedBackfills.sorted(), to: files.file("backfills.json"))
    }
    func resetExport() throws {
        guard job == nil else { throw EngineError.busy }
        let names = try FileManager.default.contentsOfDirectory(atPath: files.root.path)
        for name in names where name.hasPrefix("anchor-") || name.hasPrefix("pending-") || name.hasPrefix("batch-") || name == "destination.json" || name == "backfills.json" {
            try FileManager.default.removeItem(at: files.file(name))
        }
        requestedBackfills.removeAll()
        history = SyncHistory()
        for type in registry.samples { history.types[type.identifier] = TypeHistory() }
        try persist()
    }

    private func drain() async {
        var allSucceeded = true
        while !pending.isEmpty && !cancellationRequested {
            guard let id = pending.sorted().first else { break }
            pending.remove(id)
            // Requests arriving during this pipeline queue a further anchored check.
            let interested = Set(waiters.keys.filter { waiters[$0]?.remaining.contains(id) == true })
            guard let type = registry.samples.first(where: { $0.identifier == id }) else {
                resolve(interested, type: id, success: false)
                continue
            }
            do {
                try await pipeline(type)
                resolve(interested, type: id, success: true)
            } catch {
                allSucceeded = false
                history.lastError = "\(id): \(error.localizedDescription)"
                persistOrRecordFailure()
                resolve(interested, type: id, success: false)
                // Transport, token, storage and protocol failures affect every type.
                let healthFailure = (error as NSError).domain == HKErrorDomain || error is HealthReadError || error is BatchingError
                if Task.isCancelled || !healthFailure { pending.removeAll(); break }
            }
        }
        if allSucceeded && !cancellationRequested { history.lastSuccess = Date(); persistOrRecordFailure() }
        // Expiration/global errors must release every observer's completion path.
        for waiter in waiters.values { waiter.continuation.resume(returning: false) }
        waiters.removeAll()
        phase = "Idle"; currentType = nil; pageCount = 0
        job = nil
    }

    private func resolve(_ ids: Set<UUID>, type: String, success: Bool) {
        for id in ids {
            guard var waiter = waiters[id] else { continue }
            waiter.remaining.remove(type)
            waiter.success = waiter.success && success
            if waiter.remaining.isEmpty {
                waiters.removeValue(forKey: id)
                waiter.continuation.resume(returning: waiter.success)
            } else { waiters[id] = waiter }
        }
    }

    private func pipeline(_ type: HKSampleType) async throws {
        try await checkReady()
        guard let server else { throw EngineError.settingsMissing }
        let destination = server.baseURL.absoluteString
        if let saved = try files.load(String.self, from: files.file("destination.json")), saved != destination {
            throw PageCommitter.Failure.differentServer
        }
        try files.save(destination, to: files.file("destination.json"))
        let api = HTTPAPIClient(settings: server)
        let wasBackfill = requestedBackfills.contains(type.identifier) || !FileManager.default.fileExists(atPath: files.anchorURL(type.identifier).path)
        phase = wasBackfill ? "Backfilling" : "Syncing"; currentType = type.identifier; pageCount = 0
        // Resume an interrupted page before fetching anything else from HealthKit.
        try await commit(type.identifier, destination: destination, api: api)
        if requestedBackfills.contains(type.identifier) {
            let anchor = files.anchorURL(type.identifier)
            if FileManager.default.fileExists(atPath: anchor.path) { try FileManager.default.removeItem(at: anchor) }
            requestedBackfills.remove(type.identifier)
            try files.save(requestedBackfills.sorted(), to: files.file("backfills.json"))
        }
        while true {
            try await checkReady()
            pageCount += 1
            let count = try await stagePage(type, destination: destination)
            try await checkReady()
            try await commit(type.identifier, destination: destination, api: api)
            // Include deleted objects when deciding whether the page is short.
            if count < 5_000 { break }
        }
    }

    /// This scope owns a page; it is released before the next anchored query.
    private func stagePage(_ type: HKSampleType, destination: String) async throws -> Int {
        let anchorURL = files.anchorURL(type.identifier)
        let anchor: HKQueryAnchor?
        if FileManager.default.fileExists(atPath: anchorURL.path) {
            let data = try Data(contentsOf: anchorURL)
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else {
                throw HealthReadError.missingAnchor
            }
            anchor = decoded
        } else { anchor = nil }
        let page = try await reader.page(type: type, anchor: anchor)
        guard let newAnchor = page.anchor else { throw HealthReadError.missingAnchor }
        var stager = PageStager(files: files, client: clientInfo)
        do {
            for sample in page.samples {
                try await checkReady()
                let output = try await reader.sample(sample)
                try stager.append(output)
            }
            for deletion in page.deletions { try stager.append(deletion) }
            if let quantityType = type as? HKQuantityType {
                let stats = try await reader.dailyStats(type: quantityType, samples: page.samples)
                for stat in stats { try stager.append(stat) }
            }
            try stager.finish(type: type.identifier, destination: destination, anchor: newAnchor)
        } catch {
            stager.discard()
            throw error
        }
        return page.samples.count + page.deletions.count
    }

    private func commit(_ type: String, destination: String, api: any APIClient) async throws {
        try await PageCommitter(files: files).commit(type: type, destination: destination, api: api, beforeBatch: {
            try await self.checkReady()
        }) { batch, receipt in
            try await self.accept(batch, receipt: receipt)
        }
    }
    private func accept(_ batch: SampleBatch, receipt: UploadResponse) throws {
        history.record(batch, response: receipt)
        try persist()
    }
    private func checkReady() async throws {
        try Task.checkCancellation()
        if cancellationRequested { throw CancellationError() }
        let available = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        if !available { throw EngineError.protectedDataUnavailable }
    }
    private func persist() throws { try files.save(history, to: files.file("history.json")) }
    private func persistOrRecordFailure() {
        do { try persist() }
        catch { history.lastError = "Unable to persist sync history: \(error.localizedDescription)" }
    }
    private static func cleanOrphanBatches(_ files: SyncFiles) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: files.root.path)
        var referenced = Set<String>()
        for name in names where name.hasPrefix("pending-") && name.hasSuffix(".json") {
            if let page = try files.load(PendingPage.self, from: files.file(name)) { referenced.formUnion(page.batchIDs) }
        }
        for name in names where name.hasPrefix("batch-") && name.hasSuffix(".json") {
            let id = String(name.dropFirst(6).dropLast(5))
            if !referenced.contains(id) { try FileManager.default.removeItem(at: files.file(name)) }
        }
    }
    enum EngineError: LocalizedError {
        case settingsMissing, protectedDataUnavailable, busy
        var errorDescription: String? {
            switch self {
            case .settingsMissing: "Set the server URL and token in Settings."
            case .protectedDataUnavailable: "Skipped: protected data is unavailable. Unlock the iPhone and sync again."
            case .busy: "Wait for the current sync to finish."
            }
        }
    }
}
