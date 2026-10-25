import AppIntents
import Foundation

/// Opens the workout start sheet through the same deep link the app already handles (`vitalis://workout/start`).
struct StartWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Workout"
    static let description = IntentDescription("Opens Vitalis on the workout start sheet.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "vitalis://workout/start")!))
    }
}

/// Opens Eat → add (`vitalis://eat/add`).
struct LogFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Food"
    static let description = IntentDescription("Opens Vitalis on Eat, ready to add food.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "vitalis://eat/add")!))
    }
}
