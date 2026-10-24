import Foundation
import HealthKit
import XCTest
@testable import Vitalis
import VitalisKit

final class SerializerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var serializer: HealthSerializer {
        HealthSerializer(registry: HealthTypes(), timeZone: TimeZone(secondsFromGMT: 0)!)
    }
    private func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func normalized(_ sample: HKSample) throws -> [String: Any] {
        var object = try dictionary(serializer.sample(sample))
        XCTAssertEqual(object["uuid"] as? String, sample.uuid.uuidString)
        let source = try XCTUnwrap(object["source"] as? [String: Any])
        XCTAssertEqual(Set(source.keys), Set(["name", "bundle_id", "version", "product_type", "os_version"]))
        XCTAssertNotNil(source["name"] as? String)
        XCTAssertNotNil(source["bundle_id"] as? String)
        XCTAssertNotNil(source["os_version"] as? String)
        object["uuid"] = "UUID"; object["source"] = "SOURCE"
        return object
    }
    private func assertGolden(_ actual: [String: Any], _ expected: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
        XCTAssertEqual(actual as NSDictionary, expected, file: file, line: line)
    }

    func testQuantityGoldenWithMetadataAndDevice() throws {
        let type = HKQuantityType(.stepCount)
        let device = HKDevice(name: "Watch", manufacturer: "Apple", model: "Watch", hardwareVersion: "1",
                              firmwareVersion: nil, softwareVersion: "11", localIdentifier: "local", udiDeviceIdentifier: nil)
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 42),
            start: start, end: start.addingTimeInterval(60), device: device,
            metadata: [HKMetadataKeyTimeZone: "Asia/Kolkata", "date": start,
                       "quantity": HKQuantity(unit: .count(), doubleValue: 2), "flag": true])
        try assertGolden(normalized(sample), """
        {"uuid":"UUID","type":"HKQuantityTypeIdentifierStepCount","kind":"quantity",
         "start":"2023-11-14T22:13:20.000Z","end":"2023-11-14T22:14:20.000Z","tz":"Asia/Kolkata",
         "source":"SOURCE","value":42,"unit":"count",
         "device":{"name":"Watch","manufacturer":"Apple","model":"Watch","hardware_version":"1",
                   "firmware_version":null,"software_version":"11","local_identifier":"local","udi_device_identifier":null},
         "metadata":{"HKTimeZone":"Asia/Kolkata","date":"2023-11-14T22:13:20.000Z",
                     "quantity":{"value":2,"unit":"count"},"flag":true}}
        """)
    }

    func testSleepCategoryGolden() throws {
        let sample = HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                      start: start, end: start.addingTimeInterval(60))
        try assertGolden(normalized(sample), """
        {"uuid":"UUID","type":"HKCategoryTypeIdentifierSleepAnalysis","kind":"category",
         "start":"2023-11-14T22:13:20.000Z","end":"2023-11-14T22:14:20.000Z",
         "tz":null,"source":"SOURCE","device":null,"metadata":null,"value":5,"value_label":"asleepREM"}
        """)
    }

    func testWorkoutGolden() throws {
        // The deprecated convenience initializer is intentionally limited to tests.
        let workout = HKWorkout(activityType: .traditionalStrengthTraining, start: start, end: start.addingTimeInterval(60),
                                duration: 60, totalEnergyBurned: nil, totalDistance: nil, metadata: nil)
        var object = try normalized(workout)
        let activities = try XCTUnwrap(object.removeValue(forKey: "activities") as? [[String: Any]])
        for activity in activities {
            XCTAssertEqual(Set(activity.keys), Set(["uuid", "activity_type", "activity_name", "start", "end", "metadata", "statistics"]))
            XCTAssertNotNil(activity["statistics"] as? [String: Any])
        }
        try assertGolden(object, """
        {"uuid":"UUID","type":"HKWorkoutTypeIdentifier","kind":"workout",
         "start":"2023-11-14T22:13:20.000Z","end":"2023-11-14T22:14:20.000Z",
         "tz":null,"source":"SOURCE","device":null,"metadata":null,
         "activity_type":50,"activity_name":"traditionalStrengthTraining","duration_s":60,
         "events":[],"statistics":{}}
        """)
    }

    func testDeletionGolden() throws {
        let deletion = serializer.deletion(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, type: HKQuantityType(.stepCount))
        try assertGolden(dictionary(deletion), """
        {"uuid":"00000000-0000-0000-0000-000000000001","type":"HKQuantityTypeIdentifierStepCount"}
        """)
    }

    func testDailyStatsEnvelopeGolden() throws {
        let client = ClientInfo(installID: "install", appVersion: "0.1.0", os: "iOS 18.0", model: "iPhone17,1")
        let stat = DailyStat(type: "HKQuantityTypeIdentifierStepCount", day: "2026-10-23", tz: "Asia/Kolkata",
                             sum: 9_120, min: nil, avg: nil, max: nil, unit: "count")
        let batch = SampleBatch(client: client, dailyStats: [stat])
        var object = try dictionary(batch)
        XCTAssertNotNil(UUID(uuidString: batch.batch_id))
        object["batch_id"] = "BATCH"
        try assertGolden(object, """
        {"schema":1,"batch_id":"BATCH","client":{"install_id":"install","app_version":"0.1.0","os":"iOS 18.0","model":"iPhone17,1"},
         "upserts":[],"deletions":[],"daily_stats":[{"type":"HKQuantityTypeIdentifierStepCount","day":"2026-10-23",
         "tz":"Asia/Kolkata","sum":9120,"min":null,"avg":null,"max":null,"unit":"count"}]}
        """)
    }

    func testAllRegisteredQuantityUnitsAreCompatibleAndUnique() {
        let registry = HealthTypes()
        XCTAssertEqual(Set(registry.samples.map(\.identifier)).count, registry.samples.count)
        let ids = HealthTypes.quantityUnits.map { $0.0.rawValue }
        XCTAssertEqual(ids.count, Set(ids).count)
        for (id, unit) in HealthTypes.quantityUnits {
            guard let type = HKObjectType.quantityType(forIdentifier: id) else { continue }
            XCTAssertTrue(type.is(compatibleWith: unit), "\(id.rawValue): \(unit.unitString)")
        }
    }

    func testTimestampHasMillisecondsAndRequestedCurrentOffset() {
        let zone = TimeZone(secondsFromGMT: 19_800)!
        XCTAssertEqual(WireDate.string(start, timeZone: zone), "2023-11-15T03:43:20.000+05:30")
    }
}
