@preconcurrency import HealthKit
@preconcurrency import BackgroundTasks
import Combine
import Foundation
import UIKit
import VitalisKit
import Darwin

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var snapshot = SyncSnapshot()
    @Published var setupError: String?
    @Published var isAuthorizing = false
    @Published var isRequestingSync = false
    let registry = HealthTypes()
    let healthStore = HKHealthStore()
    private(set) var engine: SyncEngine?
    private var observers: [HKObserverQuery] = []
    private var started = false
    private var pollTask: Task<Void, Never>?

    var taskIdentifier: String { (Bundle.main.bundleIdentifier ?? "com.example.vitalis") + ".catchup" }
    var isSyncing: Bool { isRequestingSync || snapshot.phase != "Idle" }

    private init() {
        // Do not open protected files during a locked launch. Observers and BG registration
        // still get registered; lazily create the engine after protected data is available.
    }

    func start() {
        guard !started else { return }
        started = true
        // Hosted unit tests construct their own samples/storage; do not start real sync.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        registerBackgroundTask()
        registerObservers()
        scheduleCatchUp()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task { await syncNow() }
    }

    @discardableResult
    private func prepareEngine() -> SyncEngine? {
        if let engine { return engine }
        guard UIApplication.shared.isProtectedDataAvailable else {
            setupError = "Skipped: protected data is unavailable. Unlock the iPhone to sync."
            return nil
        }
        do {
            let files = try SyncFiles.applicationSupport()
            let client = ClientInfo(installID: SettingsStore.installID,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
                os: "iOS \(UIDevice.current.systemVersion)", model: Self.hardwareModel())
            let engine = try SyncEngine(registry: registry, store: healthStore, files: files, clientInfo: client,
                server: try? ServerSettings(SettingsStore.baseURL))
            let deferredMessage = setupError
            self.engine = engine; setupError = nil
            Task {
                if let deferredMessage { await engine.recordError(deferredMessage) }
                for (type, status) in deliveryStatuses { await engine.backgroundStatus(type: type, message: status) }
            }
            return engine
        } catch { setupError = "Cannot open local sync storage: \(error.localizedDescription)"; return nil }
    }
    func refresh() async {
        guard let engine = prepareEngine() else { return }
        snapshot = await engine.snapshot()
    }
    func authorize() async {
        guard HKHealthStore.isHealthDataAvailable() else { setupError = "Health data is unavailable on this device."; return }
        isAuthorizing = true
        defer { isAuthorizing = false }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: registry.readTypes)
            try await prepareEngine()?.requestHistoryBackfill()
            // Permission success doesn't disclose which read types the user allowed.
            // Reinstall observers that may have failed before permission was requested.
            for observer in observers { healthStore.stop(observer) }
            observers.removeAll()
            registerObservers()
            await syncNow()
        } catch { await report("Health authorization: \(error.localizedDescription)") }
    }
    func syncNow() async {
        guard let engine = prepareEngine() else { return }
        guard HKHealthStore.isHealthDataAvailable() else { await report("Health data is unavailable on this device."); return }
        isRequestingSync = true
        _ = await engine.sync()
        isRequestingSync = false
        await refresh()
        scheduleCatchUp()
    }
    func saveSettings(url: String, token: String) async throws {
        guard !isSyncing else { throw SyncEngine.EngineError.busy }
        let settings = try ServerSettings(url)
        try TokenStore.save(token)
        try await prepareEngine()?.configure(settings)
        SettingsStore.baseURL = settings.baseURL.absoluteString
    }
    func resetExport() async throws {
        guard let engine = prepareEngine() else { throw SyncEngine.EngineError.protectedDataUnavailable }
        try await engine.resetExport()
        retryBackgroundDelivery()
        await refresh()
    }
    private func report(_ message: String) async {
        if let engine = prepareEngine() { await engine.recordError(message); await refresh() }
        else { setupError = message }
    }

    private var deliveryStatuses: [String: String] = [:]
    private func registerObservers() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        for type in registry.samples {
            let id = type.identifier
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                // The completion box has exactly one owner and is invoked in defer on every path.
                let completion = ObserverCompletion(completion)
                let errorText = error?.localizedDescription
                Task { @MainActor in
                    defer { completion.finish() }
                    if let errorText { await self.report("Observer \(id): \(errorText)"); return }
                    guard let engine = self.prepareEngine() else { return }
                    var ids = [id]
                    // Member updates also wake their correlation pipelines.
                    if id == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue || id == HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue {
                        ids.append(HKCorrelationTypeIdentifier.bloodPressure.rawValue)
                    }
                    if id.hasPrefix("HKQuantityTypeIdentifierDietary") { ids.append(HKCorrelationTypeIdentifier.food.rawValue) }
                    _ = await engine.sync(types: ids)
                    await self.refresh()
                }
            }
            observers.append(observer)
            healthStore.execute(observer)
            enableDelivery(type, frequency: .immediate, priorError: nil)
        }
    }
    func retryBackgroundDelivery() {
        for type in registry.samples { enableDelivery(type, frequency: .immediate, priorError: nil) }
    }
    private func enableDelivery(_ type: HKSampleType, frequency: HKUpdateFrequency, priorError: String?) {
        healthStore.enableBackgroundDelivery(for: type, frequency: frequency) { success, error in
            let errorText = error?.localizedDescription
            Task { @MainActor in
                let mode = frequency == .immediate ? "immediate" : "hourly"
                if success {
                    let fallback = priorError.map { " (immediate failed: \($0))" } ?? ""
                    await self.setDelivery(type.identifier, "Enabled: \(mode)\(fallback)")
                } else if frequency == .immediate {
                    self.enableDelivery(type, frequency: .hourly, priorError: errorText ?? "Not supported")
                } else {
                    await self.setDelivery(type.identifier, "Failed: immediate: \(priorError ?? "unknown"); hourly: \(errorText ?? "Not supported")")
                }
            }
        }
    }
    private func setDelivery(_ type: String, _ message: String) async {
        deliveryStatuses[type] = message
        if let engine = prepareEngine() { await engine.backgroundStatus(type: type, message: message) }
    }

    private func registerBackgroundTask() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            let taskBox = BackgroundTaskBox(task)
            Task { @MainActor in self.handleCatchUp(taskBox) }
        }
        if !registered { Task { await report("BGProcessingTask registration failed.") } }
    }
    private func handleCatchUp(_ box: BackgroundTaskBox) {
        scheduleCatchUp()
        let worker = Task { @MainActor in
            guard let engine = prepareEngine() else { box.complete(success: false); return }
            let success = await engine.sync()
            await refresh()
            box.complete(success: success && !Task.isCancelled)
        }
        box.setExpiration {
            worker.cancel()
            Task { @MainActor in
                await self.engine?.cancel()
                await self.report("Background catch-up expired; anchor retained for unfinished pages.")
            }
        }
    }
    func scheduleCatchUp() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { Task { await report("Cannot schedule catch-up: \(error.localizedDescription)") } }
    }
    private static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}

/// HealthKit's completion is not annotated Sendable in all SDK overlays; transfer
/// its sole ownership to the main-actor Task and invoke it exactly once there.
private final class ObserverCompletion: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @MainActor func finish() { handler() }
}

/// BGTask is delivered by a system callback. All mutation/termination is locked.
private final class BackgroundTaskBox: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var completed = false
    init(_ task: BGTask) { self.task = task }
    func setExpiration(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        task.expirationHandler = { [self] in expire(handler) }
        lock.unlock()
    }
    private func expire(_ handler: @Sendable () -> Void) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        task.expirationHandler = nil
        lock.unlock()
        handler()
        task.setTaskCompleted(success: false)
    }
    func complete(success: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        task.expirationHandler = nil
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}
