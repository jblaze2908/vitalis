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
        WindowGroup { WatchRootView(model: WorkoutModel.shared) }
    }
}
