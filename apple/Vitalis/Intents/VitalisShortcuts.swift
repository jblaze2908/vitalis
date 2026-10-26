import AppIntents

/// Siri phrases and Shortcuts tiles; available as soon as the app is installed.
struct VitalisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWorkoutIntent(), phrases: [
            "Start a workout in \(.applicationName)",
            "Start my workout with \(.applicationName)",
            "\(.applicationName) start workout",
        ], shortTitle: "Start Workout", systemImageName: "figure.strengthtraining.traditional")
        AppShortcut(intent: LogWeightIntent(), phrases: [
            "Log my weight in \(.applicationName)",
            "Log weight in \(.applicationName)",
            "Record my weight in \(.applicationName)",
        ], shortTitle: "Log Weight", systemImageName: "scalemass")
        AppShortcut(intent: LogFoodIntent(), phrases: [
            "Log food in \(.applicationName)",
            "Log a meal in \(.applicationName)",
            "Add food to \(.applicationName)",
        ], shortTitle: "Log Food", systemImageName: "fork.knife")
        AppShortcut(intent: LogSavedMealIntent(), phrases: [
            "Log \(\.$meal) in \(.applicationName)",
            "Add \(\.$meal) to \(.applicationName)",
            "Log a saved meal in \(.applicationName)",
        ], shortTitle: "Log Saved Meal", systemImageName: "bookmark")
        AppShortcut(intent: HowDidISleepIntent(), phrases: [
            "How did I sleep in \(.applicationName)",
            "Ask \(.applicationName) how I slept",
            "What's my sleep score in \(.applicationName)",
        ], shortTitle: "How Did I Sleep", systemImageName: "bed.double")
        AppShortcut(intent: RecoveryIntent(), phrases: [
            "What's my recovery in \(.applicationName)",
            "What's my readiness in \(.applicationName)",
            "Ask \(.applicationName) about my recovery",
        ], shortTitle: "Recovery", systemImageName: "heart.text.square")
    }
}
