#if os(watchOS)
import HealthKit
import WatchKit

/// Phone-started workouts and crash relaunches (spec 21 §4).
@MainActor final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// WatchConnectivity first, so the model's launch resend and queued phone transfers find a live session.
    func applicationDidFinishLaunching() {
        WatchSessionDelegate.shared.activate()
    }

    /// `HKHealthStore.startWatchApp(with:)` from the phone's start-choice sheet: skip Start, log the sent plan.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task {
            await WatchSessionDelegate.shared.awaitActivation()
            await WorkoutModel.shared.startFromPhone()
        }
    }

    /// The system relaunched us mid-workout; reattach the session and reload the local file.
    func handleActiveWorkoutRecovery() {
        Task { await WorkoutModel.shared.bootstrap() }
    }
}
#endif
