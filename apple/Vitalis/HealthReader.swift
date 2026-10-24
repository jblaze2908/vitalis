@preconcurrency import HealthKit
import CoreLocation
import Foundation
import OSLog
import VitalisKit

struct AnchoredPage: Sendable {
    var samples: [HKSample] = []
    var deletions: [Deletion] = []
    var anchor: Data?
}

struct HealthReader: Sendable {
    let store: HKHealthStore
    let registry: HealthTypes
    var serializer: HealthSerializer { HealthSerializer(registry: registry) }

    func page(type: HKSampleType, anchor: HKQueryAnchor?) async throws -> AnchoredPage {
        try await HealthQuery.run(store: store, initial: AnchoredPage()) { state in
            HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: 5_000) { _, samples, deleted, anchor, error in
                if let error { state.fail(error); return }
                guard let anchor else { state.fail(HealthReadError.missingAnchor); return }
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
                    state.update {
                        $0.samples = samples ?? []
                        $0.deletions = (deleted ?? []).map { Deletion(uuid: $0.uuid.uuidString, type: type.identifier) }
                        $0.anchor = data
                    }
                    state.finish()
                } catch { state.fail(error) }
            }
        }
    }

    func sample(_ sample: HKSample) async throws -> Sample {
        try Task.checkCancellation()
        var output = try serializer.sample(sample)
        if let quantity = sample as? HKQuantitySample, quantity.count > 1 {
            output.fields["series"] = .array(try await quantitySeries(quantity))
        } else if let route = sample as? HKWorkoutRoute {
            output.fields["workout_uuid"] = .optional(try await workoutUUID(for: route))
            output.fields["points"] = .array(try await locations(route))
        } else if let heartbeat = sample as? HKHeartbeatSeriesSample {
            output.fields["beats"] = .array(try await beats(heartbeat))
        } else if let ecg = sample as? HKElectrocardiogram {
            output.fields["voltages_uv"] = .array(try await voltages(ecg))
        }
        return output
    }

    private func quantitySeries(_ sample: HKQuantitySample) async throws -> [JSONValue] {
        let unit = try registry.unit(for: sample.quantityType)
        return try await HealthQuery.run(store: store, initial: [JSONValue]()) { state in
            HKQuantitySeriesSampleQuery(quantityType: sample.quantityType, predicate: HKQuery.predicateForObject(with: sample.uuid)) {
                _, quantity, interval, _, done, error in
                if let error { state.fail(error); return }
                if let quantity, let interval {
                    state.update { values in
                        try Self.checkCap(values.count + 1, uuid: sample.uuid)
                        values.append(.array([.string(WireDate.string(interval.start)), .string(WireDate.string(interval.end)),
                                              .finite(quantity.doubleValue(for: unit))]))
                    }
                }
                if done { state.finish() }
            }
        }
    }

    private func locations(_ route: HKWorkoutRoute) async throws -> [JSONValue] {
        try await HealthQuery.run(store: store, initial: [JSONValue]()) { state in
            HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error { state.fail(error); return }
                if let locations {
                    state.update { values in
                        try Self.checkCap(values.count + locations.count, uuid: route.uuid)
                        values.append(contentsOf: locations.map { location in
                            .array([.string(WireDate.string(location.timestamp)), .finite(location.coordinate.latitude),
                                .finite(location.coordinate.longitude), .finite(location.altitude), .finite(location.horizontalAccuracy),
                                .finite(location.verticalAccuracy), .finite(location.speed), .finite(location.course)])
                        })
                    }
                }
                if done { state.finish() }
            }
        }
    }

    private func beats(_ sample: HKHeartbeatSeriesSample) async throws -> [JSONValue] {
        try await HealthQuery.run(store: store, initial: [JSONValue]()) { state in
            HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, seconds, gap, done, error in
                if let error { state.fail(error); return }
                // VERIFY: Validate final-callback semantics on a real device. Use the
                // declared count so both a final beat with done=true and a separate
                // completion sentinel preserve exactly the stored number of beats.
                state.update { values in
                    if values.count < sample.count {
                        try Self.checkCap(values.count + 1, uuid: sample.uuid)
                        values.append(.array([.finite(seconds), .bool(gap)]))
                    }
                    if done && values.count != sample.count { throw HTTPAPIClient.Failure.invalidResponse }
                }
                if done { state.finish() }
            }
        }
    }

    private func voltages(_ sample: HKElectrocardiogram) async throws -> [JSONValue] {
        try await HealthQuery.run(store: store, initial: [JSONValue]()) { state in
            HKElectrocardiogramQuery(sample) { _, result in
                switch result {
                case .measurement(let measurement):
                    state.update { values in
                        try Self.checkCap(values.count + 1, uuid: sample.uuid)
                        values.append(.finite(measurement.quantity(for: .appleWatchSimilarToLeadI)?.doubleValue(for: .voltUnit(with: .micro))))
                    }
                case .done: state.finish()
                case .error(let error): state.fail(error)
                @unknown default: state.fail(HTTPAPIClient.Failure.invalidResponse)
                }
            }
        }
    }

    private static func checkCap(_ count: Int, uuid: UUID) throws {
        if count > 200_000 { throw HealthReadError.tooManyPoints(uuid.uuidString) }
    }

    private func samples(type: HKSampleType, predicate: NSPredicate?, limit: Int,
                         sortDescriptors: [NSSortDescriptor]? = nil) async throws -> [HKSample] {
        try await HealthQuery.run(store: store, initial: [HKSample]()) { state in
            HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: sortDescriptors) { _, samples, error in
                if let error { state.fail(error); return }
                state.update { $0 = samples ?? [] }; state.finish()
            }
        }
    }

    private func workoutUUID(for route: HKWorkoutRoute) async throws -> String? {
        // VERIFY: On-device validate reverse route linkage for replaced routes. There is no
        // general predicateForObjectsAssociated(with:) in the public iOS 18 HKQuery API.
        // Find candidate workouts, then test their documented forward association by UUID.
        // Never infer a relationship merely from dates or source.
        let overlap = HKQuery.predicateForSamples(withStart: route.startDate, end: route.endDate, options: [])
        let workouts = try await samples(type: HKObjectType.workoutType(), predicate: overlap, limit: HKObjectQueryNoLimit)
        for case let workout as HKWorkout in workouts {
            try Task.checkCancellation()
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(from: workout), HKQuery.predicateForObject(with: route.uuid)])
            let routes = try await samples(type: HKSeriesType.workoutRoute(), predicate: predicate, limit: 1)
            if routes.contains(where: { $0.uuid == route.uuid }) { return workout.uuid.uuidString }
        }
        // A workout's read permission is independent of the route's. Preserve the route
        // with null linkage rather than guessing a UUID or dropping readable locations.
        Logger(subsystem: "Vitalis", category: "Route").notice("No readable workout association for a route; exporting workout_uuid=null")
        return nil
    }

    func dailyStats(type: HKQuantityType, samples: [HKSample]) async throws -> [DailyStat] {
        let calendar = Calendar.current
        let timeZone = calendar.timeZone
        let unit = try registry.unit(for: type)
        var days = Set<Date>()
        for sample in samples {
            var day = calendar.startOfDay(for: sample.startDate)
            let last = calendar.startOfDay(for: sample.endDate)
            while day <= last {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        guard let first = days.min(), let last = days.max(),
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        let cumulative = type.aggregationStyle == .cumulative
        let options: HKStatisticsOptions = cumulative ? .cumulativeSum : [.discreteMin, .discreteAverage, .discreteMax]
        let predicate = HKQuery.predicateForSamples(withStart: first, end: end, options: [])
        let touchedDays = days
        return try await HealthQuery.run(store: store, initial: [DailyStat]()) { state in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                options: options, anchorDate: first, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { state.fail(error); return }
                guard let collection else { state.fail(HTTPAPIClient.Failure.invalidResponse); return }
                var result: [DailyStat] = []
                collection.enumerateStatistics(from: first, to: end) { stats, _ in
                    guard touchedDays.contains(calendar.startOfDay(for: stats.startDate)) else { return }
                    result.append(DailyStat(type: type.identifier, day: WireDate.day(stats.startDate, timeZone: timeZone),
                        tz: timeZone.identifier, sum: cumulative ? stats.sumQuantity()?.doubleValue(for: unit) : nil,
                        min: cumulative ? nil : stats.minimumQuantity()?.doubleValue(for: unit),
                        avg: cumulative ? nil : stats.averageQuantity()?.doubleValue(for: unit),
                        max: cumulative ? nil : stats.maximumQuantity()?.doubleValue(for: unit), unit: unit.unitString))
                }
                state.update { $0 = result }; state.finish()
            }
            return query
        }
    }
}
