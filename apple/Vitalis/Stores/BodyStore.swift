import Foundation
import Observation
import VitalisKit

/// Body tab and the Log weight sheet (spec 20 §4 Body, §8): renders `GET /v2/body`; Save writes Health then queues the POST.
@MainActor @Observable
final class BodyStore {
    /// The durable write path; the app uses the Outbox via `Services.shared`, tests a fake.
    @MainActor protocol Writes {
        /// Queues and tries to deliver; returns the outbox id.
        func send(_ request: APIRequest) async -> UUID?
        /// Undo before send; false when it is in flight or already delivered.
        func drop(_ id: UUID) async -> Bool
        func isPending(_ id: UUID) async -> Bool
    }

    struct ServicesWrites: Writes {
        func send(_ request: APIRequest) async -> UUID? { await Services.shared.send(request) }
        func drop(_ id: UUID) async -> Bool { await Services.shared.drop(id) }
        func isPending(_ id: UUID) async -> Bool {
            await Services.shared.outbox?.pendingItems.contains { $0.id == id } ?? false
        }
    }

    /// What Undo needs to remove both copies of the last save.
    struct SavedWeight: Equatable {
        let outboxID: UUID?
        let entryID: String
        let hkUUID: UUID?
        let kg: Double
        let healthFailed: Bool
    }

    private(set) var body = Loadable<BodyResponse>()
    /// The save the toast can undo; cleared when the toast goes.
    private(set) var lastSaved: SavedWeight?
    /// Outbox id of a weight write not yet delivered; while set the screen shows the cached block plus `WAITING TO SYNC`.
    private(set) var waitingID: UUID?
    var waitingToSync: Bool { waitingID != nil }

    private let api: @MainActor () -> VitalisAPI?
    private let health: any HealthWriting
    private let writes: any Writes
    private let now: () -> Date

    init(api: @escaping @MainActor () -> VitalisAPI? = { Services.shared.api },
         health: any HealthWriting = HealthWriter(store: AppModel.shared.healthStore),
         writes: any Writes = ServicesWrites(), now: @escaping () -> Date = { Date() }) {
        self.api = api; self.health = health; self.writes = writes; self.now = now
    }

    var value: BodyResponse? { body.value }
    var weight: WeightBlock? { body.value?.weight }

    /// Prefill for the sheet in tenths of a kg, so the ruler stays on its 0.1 grid. Nil when there's no reading yet.
    var prefillTenths: Int? {
        (weight?.latest?.kg ?? weight?.trendKg).map { Int(($0 * 10).rounded()) }
    }

    func load() async {
        guard let api = api() else { return }
        await body.load(cached: { await api.cached(BodyResponse.self, path: "v2/body") }) { try await api.body() }
        if let id = waitingID, body.error == nil, !(await writes.isPending(id)) { waitingID = nil }
    }

    /// Spec 20 §4 Log weight: (1) Health sample when asked, (2) queue `POST /v2/weight`, (3) show the server's block.
    func saveWeight(tenths: Int, at date: Date, alsoHealth: Bool) async {
        let kg = Double(tenths) / 10
        var hkUUID: UUID?
        var healthFailed = false
        if alsoHealth {
            // A failed Health write never blocks the server entry (spec 20 §8).
            do { hkUUID = try await health.saveWeight(kg: kg, at: date) } catch { healthFailed = true }
        }
        let entryID = UUID().uuidString
        let entry = WeightEntry(id: entryID, kg: kg, measuredAt: Self.timestamp(date), hkUuid: hkUUID?.uuidString)
        guard let request = try? APIRequest.postWeight(entry) else { return }
        let outboxID = await writes.send(request)
        lastSaved = SavedWeight(outboxID: outboxID, entryID: entryID, hkUUID: hkUUID, kg: kg, healthFailed: healthFailed)
        await settle(outboxID)
    }

    /// Removes both copies: drops the queued POST if unsent, else queues the DELETE; deletes the Health sample either way.
    func undoLastSave() async {
        guard let saved = lastSaved else { return }
        lastSaved = nil
        var dropped = false
        if let id = saved.outboxID { dropped = await writes.drop(id) }
        if dropped {
            if waitingID == saved.outboxID { waitingID = nil }
        } else {
            await settle(await writes.send(APIRequest.deleteWeight(id: saved.entryID)))
        }
        if let hk = saved.hkUUID { try? await health.delete(uuids: [hk]) }
    }

    func dismissToast() { lastSaved = nil }

    /// The Outbox may deliver a waiting write from its own flush without bumping `writesVersion`; the screen polls this.
    func recheckWaiting() async {
        guard let id = waitingID, !(await writes.isPending(id)) else { return }
        await load()
    }

    /// Delivered → refetch the server's weight block; still queued → keep the cached block and mark it waiting.
    private func settle(_ outboxID: UUID?) async {
        guard let outboxID else { return }
        if await writes.isPending(outboxID) { waitingID = outboxID } else { waitingID = nil; await load() }
    }

    /// Previews: show a fixture body without an API.
    func preload(_ value: BodyResponse?, waiting: Bool = false) {
        if let value { body.set(value) }
        
        if waiting { waitingID = UUID() }
    }

    /// ISO 8601 with the device's offset (`2026-10-24T07:05:00+05:30`), as the server stores wall-clock days.
    nonisolated static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

}
