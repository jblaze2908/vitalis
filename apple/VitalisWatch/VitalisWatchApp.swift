import SwiftUI
import VitalisKit
import VitalisUI

@main
struct VitalisWatchApp: App {
    #if os(watchOS)
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    #endif
    init() { VFont.register() }
    var body: some Scene {
        WindowGroup { WatchRootView(model: Self.model) }
    }

    private static let model: WorkoutModel = {
        #if DEBUG
        // Simulator screenshots: `-VitalisDemo setEntry` (or rest, summaryServer, …) runs a fixture workout, no phone.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-VitalisDemo") {
            let name = args.indices.contains(i + 1) ? args[i + 1] : "start"
            let states: [String: WorkoutModel.PreviewState] = ["start": .start, "setEntry": .setEntry, "rest": .rest,
                                                               "handoff": .handoff, "summary": .summaryServer]
            return .preview(states[name] ?? .start)
        }
        #endif
        return .shared
    }()
}
