import HealthKit
import Testing
@testable import Vitalis

@Suite struct HealthShareProbeTests {
    /// HealthKit raises (a crash, not an error) for a disallowed type, e.g. a prescription in the read set; reaching
    /// either outcome means validation passed. Unsigned simulator builds then fail on the missing entitlement.
    @Test func authorizationRequestPassesValidation() async {
        _ = try? await HKHealthStore().requestAuthorization(toShare: HealthShareTypes.all,
                                                            read: HealthTypes().readTypes.filter { !($0 is HKPrescriptionType) })
    }
}
