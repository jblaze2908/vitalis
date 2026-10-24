import Foundation
import HealthKit

/// The HealthKit side of a workout (spec 21 §4), behind a protocol so previews never touch HealthKit.
@MainActor protocol WorkoutSessionControlling: AnyObject {
    var isPaused: Bool { get }
    /// Latest heart rate and active energy from the live builder, for W-02's live metrics page.
    var heartRate: Double? { get }
    var activeKcal: Double? { get }
    func elapsed(at date: Date) -> TimeInterval?
    func start(at date: Date) async throws
    func pause()
    func resume()
    /// Ends the session and saves the workout; returns the saved `HKWorkout.uuid`.
    func end(at date: Date) async -> UUID?
    /// Reattaches to a session that survived an app crash; true when one was found.
    func recover() async -> Bool
}

#if os(watchOS)
/// HealthKit hands over freshly created objects in callbacks; nothing else holds them while they cross to the main actor.
private struct Handoff<Value>: @unchecked Sendable { let value: Value }

@MainActor @Observable final class HealthWorkoutSession: NSObject, WorkoutSessionControlling {
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    private(set) var state: HKWorkoutSessionState = .notStarted
    private(set) var heartRate: Double?
    private(set) var activeKcal: Double?

    var isPaused: Bool { state == .paused }

    static var configuration: HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        return config
    }

    func elapsed(at date: Date) -> TimeInterval? { builder?.elapsedTime(at: date) }

    func authorize() async throws {
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned), HKObjectType.workoutType()]
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: share, read: read) { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func start(at date: Date) async throws {
        guard session == nil else { return }
        try await authorize()
        let config = Self.configuration
        let session = try HKWorkoutSession(healthStore: store, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
        attach(session, builder)
        session.startActivity(with: date)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: date) { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    func end(at date: Date) async -> UUID? {
        guard let session, let builder else { return nil }
        session.end()
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            builder.endCollection(withEnd: date) { ok, _ in c.resume(returning: ok) }
        }
        let uuid = await withCheckedContinuation { (c: CheckedContinuation<UUID?, Never>) in
            builder.finishWorkout { workout, _ in c.resume(returning: workout?.uuid) }
        }
        self.session = nil
        self.builder = nil
        return uuid
    }

    func recover() async -> Bool {
        if session != nil { return true }
        let recovered = await withCheckedContinuation { (c: CheckedContinuation<Handoff<HKWorkoutSession?>, Never>) in
            store.recoverActiveWorkoutSession { session, _ in c.resume(returning: Handoff(value: session)) }
        }
        guard let session = recovered.value else { return false }
        attach(session, session.associatedWorkoutBuilder())
        state = session.state
        return true
    }

    private func attach(_ session: HKWorkoutSession, _ builder: HKLiveWorkoutBuilder) {
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
    }
}

extension HealthWorkoutSession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.state = toState }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {}
}

extension HealthWorkoutSession: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity()?
            .doubleValue(for: .count().unitDivided(by: .minute()))
        let kcal = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in
            if let bpm { self.heartRate = bpm }
            if let kcal { self.activeKcal = kcal }
        }
    }
}

#else
/// iOS slice of `-sdk iphonesimulator` builds: no live workout builder before iOS 26.
typealias HealthWorkoutSession = PreviewWorkoutSession
#endif

/// Fixture session for previews: fixed readings, no HealthKit.
@MainActor @Observable final class PreviewWorkoutSession: WorkoutSessionControlling {
    var isPaused = false
    var heartRate: Double? = 128
    var activeKcal: Double? = 212
    var startedAt: Date?
    func elapsed(at date: Date) -> TimeInterval? { startedAt.map { date.timeIntervalSince($0) } }
    func start(at date: Date) async throws { startedAt = date }
    func pause() { isPaused = true }
    func resume() { isPaused = false }
    func end(at date: Date) async -> UUID? { nil }
    func recover() async -> Bool { false }
}
