import AppIntents
import Foundation

// Compiled into the app and the widget extension: the widget needs the types for its buttons, and the system runs
// a LiveActivityIntent's `perform()` in the app, where `WorkoutActivityActions` reaches the live session.

/// `+30 s` on the workout Live Activity.
struct ExtendRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add 30 Seconds of Rest"
    static let isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        WorkoutActivityActions.extendRest(by: 30)
        return .result()
    }
}

/// `Skip rest` on the workout Live Activity.
struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Rest"
    static let isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        WorkoutActivityActions.skipRest()
        return .result()
    }
}
