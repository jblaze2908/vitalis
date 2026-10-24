import Foundation
import HealthKit

/// HealthKit write-back (spec 20 §8). Server entries are the source of truth; a failed write here never blocks them.
protocol HealthWriting: Sendable {
    /// Saves a body-mass sample (kg) marked user-entered; returns its UUID.
    func saveWeight(kg: Double, at date: Date) async throws -> UUID
    /// Saves one food correlation per item; returns the correlation UUIDs in item order.
    func saveFood(_ items: [FoodItemSample]) async throws -> [UUID]
    /// Deletes objects this app wrote, by UUID (Undo / delete).
    func delete(uuids: [UUID]) async throws
    /// Saves a finished strength workout; returns its UUID (sent as `hk_workout_uuid`).
    func saveStrengthWorkout(start: Date, end: Date) async throws -> UUID
}

struct FoodItemSample: Sendable {
    let entryID: String
    let name: String
    let eatenAt: Date
    let kcal: Double
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
}

/// The types Vitalis writes; requested alongside the exporter's read types during setup.
enum HealthShareTypes {
    static let all: Set<HKSampleType> = [
        HKQuantityType(.bodyMass), HKCorrelationType(.food), HKQuantityType(.dietaryEnergyConsumed), HKQuantityType(.dietaryProtein),
        HKQuantityType(.dietaryCarbohydrates), HKQuantityType(.dietaryFatTotal), HKObjectType.workoutType(),
    ]
}

struct HealthWriter: HealthWriting {
    let store: HKHealthStore

    func saveWeight(kg: Double, at date: Date) async throws -> UUID {
        let sample = HKQuantitySample(type: HKQuantityType(.bodyMass), quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
                                      start: date, end: date, metadata: [HKMetadataKeyWasUserEntered: true])
        try await store.save(sample)
        return sample.uuid
    }

    func saveFood(_ items: [FoodItemSample]) async throws -> [UUID] {
        var correlations: [HKCorrelation] = []
        for item in items {
            func q(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ v: Double?) -> HKQuantitySample? {
                v.map { HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: $0), start: item.eatenAt, end: item.eatenAt) }
            }
            let parts = [q(.dietaryEnergyConsumed, .kilocalorie(), item.kcal), q(.dietaryProtein, .gram(), item.proteinG),
                         q(.dietaryCarbohydrates, .gram(), item.carbsG), q(.dietaryFatTotal, .gram(), item.fatG)].compactMap { $0 }
            correlations.append(HKCorrelation(type: HKCorrelationType(.food), start: item.eatenAt, end: item.eatenAt, objects: Set(parts),
                                              metadata: [HKMetadataKeyFoodType: item.name, HKMetadataKeyExternalUUID: item.entryID]))
        }
        try await store.save(correlations)
        return correlations.map(\.uuid)
    }

    func delete(uuids: [UUID]) async throws {
        guard !uuids.isEmpty else { return }
        let ids = Set(uuids)
        for type in [HKCorrelationType(.food), HKQuantityType(.bodyMass), HKObjectType.workoutType()] as [HKSampleType] {
            let found: [HKSample] = try await withCheckedThrowingContinuation { cont in
                store.execute(HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForObjects(with: ids), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: s ?? []) }
                })
            }
            // A food correlation's own samples go with it, so the dietary totals in Health drop too.
            let children = found.compactMap { $0 as? HKCorrelation }.flatMap { Array($0.objects) }
            if !found.isEmpty { try await store.delete(found + children) }
        }
    }

    func saveStrengthWorkout(start: Date, end: Date) async throws -> UUID {
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: start)
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { throw HKError(.errorInvalidArgument) }
        return workout.uuid
    }
}

/// In-memory writer for tests and previews.
final class FakeHealthWriter: HealthWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: [UUID: String] = [:]
    var failNext = false
    var saved: [UUID: String] { lock.withLock { _saved } }

    private func record(_ what: String) throws -> UUID {
        try lock.withLock {
            if failNext { failNext = false; throw HKError(.errorHealthDataUnavailable) }
            let id = UUID(); _saved[id] = what; return id
        }
    }
    func saveWeight(kg: Double, at date: Date) async throws -> UUID { try record("weight \(kg)") }
    func saveFood(_ items: [FoodItemSample]) async throws -> [UUID] { try items.map { try record("food \($0.entryID)") } }
    func delete(uuids: [UUID]) async throws { lock.withLock { for id in uuids { _saved[id] = nil } } }
    func saveStrengthWorkout(start: Date, end: Date) async throws -> UUID { try record("workout") }
}
