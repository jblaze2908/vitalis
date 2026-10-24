@preconcurrency import HealthKit
import Foundation

/// The only unchecked Sendable boundary: HealthKit may invoke callbacks off-actor.
/// The continuation, query and accumulated result are all protected by this lock.
final class HealthQuery<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private var value: Value
    private var continuation: CheckedContinuation<Value, any Error>?
    private var query: HKQuery?
    private var result: Result<Value, any Error>?

    private init(store: HKHealthStore, initial: Value) { self.store = store; value = initial }

    static func run(store: HKHealthStore, initial: Value,
                    makeQuery: (HealthQuery<Value>) -> HKQuery) async throws -> Value {
        let state = HealthQuery(store: store, initial: initial)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                state.start(makeQuery(state))
            }
        } onCancel: { state.fail(CancellationError()) }
    }

    private func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    private func start(_ query: HKQuery) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        self.query = query
        // execute schedules asynchronous callbacks. Hold the lock so cancellation cannot
        // stop the query between registration and execution, then accidentally start it.
        store.execute(query)
        lock.unlock()
    }
    func update(_ body: (inout Value) throws -> Void) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        do { try body(&value); lock.unlock() }
        catch { lock.unlock(); fail(error) }
    }
    func finish() { resolve(error: nil) }
    func fail(_ error: any Error) { resolve(error: error) }
    private func resolve(error: (any Error)?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let result: Result<Value, any Error> = error.map { .failure($0) } ?? .success(value)
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let query = self.query
        self.query = nil
        lock.unlock()
        if let query { store.stop(query) }
        continuation?.resume(with: result)
    }
}
