import Foundation

/// The extension's half of the shared Live Activity intents: never called, since the system runs their
/// `perform()` in the app (see `Vitalis/Intents/WorkoutActivityIntents.swift`).
@MainActor
enum WorkoutActivityActions {
    static func extendRest(by seconds: TimeInterval) {}
    static func skipRest() {}
}
